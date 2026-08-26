//
//  DetailsViewModel.swift
//  NuvioTV
//
//  ViewModel for content details screen
//

import Foundation
import Combine

@MainActor
class DetailsViewModel: ObservableObject {
    @Published private(set) var uiState = DetailsUiState()

    private let repository: CatalogRepository
    /// When false (MockCatalogRepository tests), stream loading uses the
    /// repository's progressive API instead of the shared discovery service.
    private let usesSharedStreamDiscovery: Bool
    private var streamObserveTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var deferredLoadTask: Task<Void, Never>?
    private var observedRequestKey: String?
    private var lastAppliedStreamsRequestKey: String?
    private var lastAppliedStreamsRevision: UInt64?

    init(repository: CatalogRepository) {
        self.repository = repository
        self.usesSharedStreamDiscovery = !(repository is MockCatalogRepository)
    }

    func loadDetails(id: String, type: String) {
        TVHomeDebugTrace.log("details.load.begin id=\(id) type=\(type)")
        deferredLoadTask?.cancel()
        streamObserveTask?.cancel()
        enrichmentTask?.cancel()

        // Check if full metadata is already in memory so we can render frame 0 instantly without showing a spinner
        if let cached = (repository as? CinemetaCatalogRepository)?.cachedMetadata(for: id),
           CinemetaCatalogRepository.isFullMetadata(cached) {
            uiState = DetailsUiState(
                isLoading: false,
                meta: cached,
                error: nil,
                isInWatchlist: LibraryStore.contains(metaId: cached.id, type: cached.type),
                isWatched: WatchedStore.contains(meta: cached)
            )
        } else if uiState.meta?.id != id {
            uiState = DetailsUiState(isLoading: true, error: nil)
        }

        Task {
            do {
                let meta = try await repository.getMetadata(id: id, type: type)
                
                var primaryState = uiState
                primaryState.meta = meta
                primaryState.isInWatchlist = LibraryStore.contains(metaId: meta.id, type: meta.type)
                primaryState.isWatched = WatchedStore.contains(meta: meta)
                primaryState.isLoading = false
                primaryState.error = nil
                uiState = primaryState

                // Present primary metadata immediately for instant smooth transition.
                // Defer streams & heavy secondary enrichment until the screen transition
                // has completed (350ms). If the user quickly backs out, zero heavy work
                // or image decompression is performed!
                deferredLoadTask?.cancel()
                deferredLoadTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled, uiState.meta?.id == meta.id else { return }

                    if !meta.isSeries {
                        prepareStreams(forId: meta.streamId, type: meta.type)
                    }
                    loadEnrichment(for: meta)
                }
            } catch {
                if uiState.meta == nil {
                    uiState.isLoading = false
                    uiState.error = error.localizedDescription
                }
            }
        }
    }

    func cancelAllTasks() {
        TVHomeDebugTrace.log("details.cancelAllTasks")
        deferredLoadTask?.cancel()
        deferredLoadTask = nil
        streamObserveTask?.cancel()
        streamObserveTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
    }

    /// Loads More Like This, Production companies, and top Trakt comments
    /// after the primary metadata is on screen.
    private func loadEnrichment(for meta: NuvioMeta) {
        enrichmentTask?.cancel()
        enrichmentTask = Task {
            TVHomeDebugTrace.log("details.enrich.begin id=\(meta.id)")
            uiState.isLoadingEnrichment = true
            defer {
                if !Task.isCancelled {
                    uiState.isLoadingEnrichment = false
                }
            }

            async let companiesTask = TmdbDetailsService.fetchCompanies(for: meta)
            async let creditsTask = TmdbDetailsService.fetchCredits(for: meta)
            async let tmdbRelatedTask = TmdbDetailsService.fetchMoreLikeThis(for: meta)
            async let traktRelatedTask = TraktDetailsService.fetchRelated(for: meta)
            async let commentsTask = TraktDetailsService.fetchTopComments(for: meta)
            async let simklTask = SimklDetailsService.fetchDetails(for: meta)
            async let mdbRatingsTask = MdbListDetailsService.fetchRatings(for: meta)
            async let tmdbEpisodesTask = meta.isSeries ? TmdbDetailsService.fetchEpisodes(for: meta) : nil

            let companies = await companiesTask
            let credits = await creditsTask
            let tmdbRelated = await tmdbRelatedTask
            let traktRelated = await traktRelatedTask
            let comments = await commentsTask
            let simkl = await simklTask
            let mdbRatings = await mdbRatingsTask
            let tmdbEpisodes = await tmdbEpisodesTask

            let simklRelated = simkl?.related ?? []
            let preferred: [RelatedTitle]
            switch TraktSettingsStore.moreLikeThisSource {
            case .trakt: preferred = traktRelated
            case .tmdb: preferred = tmdbRelated
            case .simkl: preferred = simklRelated
            }
            let moreLikeThis = [preferred, tmdbRelated, traktRelated, simklRelated]
                .first { !$0.isEmpty } ?? []

            guard !Task.isCancelled, uiState.meta?.id == meta.id else {
                return
            }

            var next = uiState
            next.companies = companies
            if let credits, !credits.isEmpty, let currentMeta = next.meta {
                next.meta = credits.applying(to: currentMeta)
                next.people = credits.people
            }
            if let currentMeta = next.meta {
                next.meta = currentMeta.withExternalRatings(mdbRatings)
            }
            if let tmdbEpisodes, !tmdbEpisodes.isEmpty, let currentMeta = next.meta {
                let mergedVideos = Self.mergeEpisodes(
                    existing: currentMeta.videos,
                    fromTmdb: tmdbEpisodes,
                    parentId: currentMeta.id
                )
                next.meta = currentMeta.withVideos(mergedVideos)
            }
            next.moreLikeThis = moreLikeThis
            next.comments = comments
            next.simklRatings = simkl?.ratings
            uiState = next

            // Trakt's related endpoint commonly omits usable artwork even with
            // `extended=images`. Resolve those IMDb ids through Cinemeta so the
            // row gets the same poster data as Home. Keep the initial titles on
            // screen while these independent artwork requests finish.
            let hydrated = await hydrateRelatedArtwork(in: moreLikeThis)
            guard !Task.isCancelled, uiState.meta?.id == meta.id else { return }
            uiState.moreLikeThis = hydrated
        }
    }

    private func hydrateRelatedArtwork(in items: [RelatedTitle]) async -> [RelatedTitle] {
        var hydrated = items
        await withTaskGroup(of: (Int, RelatedTitle).self) { group in
            for (index, item) in items.enumerated() {
                guard item.posterURL?.isEmpty != false else { continue }
                group.addTask {
                    let repository = CinemetaCatalogRepository()
                    guard let meta = try? await repository.getMetadata(id: item.id, type: item.type) else {
                        return (index, item)
                    }
                    return (
                        index,
                        RelatedTitle(
                            id: meta.id,
                            type: meta.type,
                            name: meta.name.isEmpty ? item.name : meta.name,
                            posterURL: meta.posterUrl ?? meta.backgroundUrl,
                            year: meta.releaseInfo ?? meta.year.map(String.init) ?? item.year,
                            rating: meta.rating ?? item.rating,
                            overview: meta.description ?? item.overview
                        )
                    )
                }
            }

            for await (index, item) in group {
                guard hydrated.indices.contains(index) else { continue }
                hydrated[index] = item
            }
        }
        return hydrated
    }

    /// Load the playable streams for a given title/episode id.
    ///
    /// Production uses `StreamsRepository.shared` so:
    /// - every compatible add-on appears immediately as a loading group
    /// - results update per add-on as they arrive
    /// - returning from playback reuses the same request key without re-fetching
    /// - cancelling observation (leaving Details / opening player) does **not**
    ///   cancel the shared search
    ///
    /// `forceRefresh` restarts discovery for the same key (explicit refresh).
    func prepareStreams(forId streamId: String, type: String, forceRefresh: Bool = false) {
        streamObserveTask?.cancel()

        if usesSharedStreamDiscovery {
            prepareSharedStreams(forId: streamId, type: type, forceRefresh: forceRefresh)
        } else {
            prepareRepositoryStreams(forId: streamId, type: type)
        }
    }

    private func prepareSharedStreams(forId streamId: String, type: String, forceRefresh: Bool) {
        let se = StreamsRepository.seasonEpisode(fromVideoId: streamId)
        let key = StreamsRepository.requestKey(
            type: type,
            videoId: streamId,
            season: se.season,
            episode: se.episode
        )
        observedRequestKey = key
        lastAppliedStreamsRequestKey = nil
        lastAppliedStreamsRevision = nil

        StreamsRepository.shared.load(
            type: type,
            videoId: streamId,
            season: se.season,
            episode: se.episode,
            forceRefresh: forceRefresh
        )

        // Seed UI from cache immediately (return-from-playback reuse).
        applyDiscoveryState(StreamsRepository.shared.state, expectedKey: key)

        streamObserveTask = Task { [weak self] in
            guard let self else { return }
            // Poll shared state; Combine is heavier and this keeps observation
            // cancel independent of the discovery job.
            while !Task.isCancelled {
                let snapshot = StreamsRepository.shared.state
                if snapshot.requestKey == key || (snapshot.requestKey == nil && snapshot.groups.isEmpty) {
                    self.applyDiscoveryState(snapshot, expectedKey: key)
                }
                if snapshot.requestKey == key, snapshot.hasResolvedTargets, !snapshot.isAnyLoading {
                    break
                }
                // Another key replaced ours after we finished applying cache —
                // stop observing but leave shared job alone.
                if let active = snapshot.requestKey, active != key, snapshot.hasResolvedTargets {
                    break
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    private func applyDiscoveryState(_ snapshot: StreamsDiscoveryState, expectedKey: String) {
        guard observedRequestKey == expectedKey else { return }
        // Accept cached/completed state for our key, or empty transitional state.
        if let key = snapshot.requestKey, key != expectedKey { return }
        guard snapshot.requestKey != lastAppliedStreamsRequestKey
                || snapshot.revision != lastAppliedStreamsRevision else { return }

        lastAppliedStreamsRequestKey = snapshot.requestKey
        lastAppliedStreamsRevision = snapshot.revision

        // Publish one coherent state change per repository revision. Mutating
        // five members of the @Published struct separately caused five complete
        // details-tree invalidations on every 80 ms observer poll.
        var nextState = uiState
        nextState.streamGroups = snapshot.groups
        nextState.streams = snapshot.allStreams
        nextState.streamsRevision = snapshot.revision
        nextState.isLoadingStreams = snapshot.isAnyLoading || !snapshot.hasResolvedTargets
        nextState.streamsEmptyReason = snapshot.emptyStateReason
        uiState = nextState
    }

    private func prepareRepositoryStreams(forId streamId: String, type: String) {
        streamObserveTask = Task {
            uiState.streams = []
            uiState.streamGroups = []
            uiState.streamsRevision &+= 1
            uiState.streamsEmptyReason = nil
            uiState.isLoadingStreams = true
            for await streams in repository.streamsProgressively(id: streamId, type: type) {
                if Task.isCancelled { return }
                uiState.streams = streams
                uiState.streamGroups = [
                    AddonStreamGroup(
                        addonId: "mock",
                        displayName: streams.first?.addonName ?? "Streams",
                        streams: streams,
                        isLoading: false
                    )
                ]
                uiState.streamsRevision &+= 1
            }
            if !Task.isCancelled {
                uiState.isLoadingStreams = false
                if uiState.streams.isEmpty {
                    uiState.streamsEmptyReason = .noStreamsFound
                }
            }
        }
    }

    func toggleWatchlist() {
        guard let meta = uiState.meta else { return }
        if TraktSettingsStore.librarySourceMode == .local {
            uiState.isInWatchlist = LibraryStore.toggle(meta: meta)
            return
        }

        // A Trakt-selected library must never silently fall back to Nuvio
        // Sync. Without a live Trakt session, leave the state unchanged.
        guard SelectedLibraryService.isSelectedAndAuthenticated else { return }

        // Keep Details responsive, then let LibraryViewModel refresh the
        // Trakt-backed list from the notification posted after the mutation.
        let desiredMembership = !uiState.isInWatchlist
        uiState.isInWatchlist = desiredMembership
        Task {
            let succeeded = await SelectedLibraryService.setWatchlist(
                meta,
                isInWatchlist: desiredMembership
            )
            guard !Task.isCancelled, uiState.meta?.id == meta.id else { return }
            if !succeeded {
                uiState.isInWatchlist = !desiredMembership
            }
        }
    }

    func toggleWatched() {
        guard let meta = uiState.meta else { return }
        uiState.isWatched = WatchedStore.toggle(meta: meta)
    }

    static func mergeEpisodes(
        existing: [NuvioVideo]?,
        fromTmdb tmdbVideos: [NuvioVideo]?,
        parentId: String
    ) -> [NuvioVideo]? {
        guard let tmdbVideos, !tmdbVideos.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return tmdbVideos }

        var bySeasonEp: [String: NuvioVideo] = [:]
        for video in existing {
            bySeasonEp["\(video.season):\(video.episode)"] = video
        }

        var result: [NuvioVideo] = []
        for tmdb in tmdbVideos {
            let key = "\(tmdb.season):\(tmdb.episode)"
            if let ex = bySeasonEp.removeValue(forKey: key) {
                result.append(NuvioVideo(
                    id: ex.id,
                    title: (ex.title.hasPrefix("Episode ") || ex.title.isEmpty) ? tmdb.title : ex.title,
                    season: ex.season,
                    episode: ex.episode,
                    thumbnail: ex.thumbnail ?? tmdb.thumbnail,
                    overview: (ex.overview == nil || ex.overview?.isEmpty == true) ? tmdb.overview : ex.overview,
                    released: ex.released ?? tmdb.released,
                    rating: ex.rating ?? tmdb.rating
                ))
            } else {
                result.append(tmdb)
            }
        }

        for remaining in bySeasonEp.values {
            result.append(remaining)
        }

        return result.sorted {
            (seasonSortKey($0.season), $0.episode) < (seasonSortKey($1.season), $1.episode)
        }
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season == 0 ? Int.max : season
    }
}
