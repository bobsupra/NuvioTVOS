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

        // Check if full metadata is already in memory so we can render frame 0 instantly without showing a spinner.
        // For movies, any cached catalog entry already has the title, artwork, rating, and description needed for frame 0,
        // since movies don't require an episode guide.
        let canRenderInstantly: Bool = {
            guard let cinemetaRepo = repository as? CinemetaCatalogRepository,
                  let cached = cinemetaRepo.cachedMetadata(for: id) else { return false }
            if cinemetaRepo.isCachedFullMetadata(id: id) { return true }
            return !cached.isSeries && !cached.name.isEmpty
        }()

        if canRenderInstantly,
           let cinemetaRepo = repository as? CinemetaCatalogRepository,
           let cached = cinemetaRepo.cachedMetadata(for: id) {
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
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            TVHomeDebugTrace.log("details.enrich.begin id=\(meta.id)")
            self.uiState.isLoadingEnrichment = true
            defer {
                if !Task.isCancelled {
                    self.uiState.isLoadingEnrichment = false
                }
            }

            await withTaskGroup(of: Void.self) { group in
                // 1. Credits & Cast (TMDB) -> Apply immediately when ready (~200ms)
                group.addTask {
                    let credits = await TmdbDetailsService.fetchCredits(for: meta)
                    await self.applyCredits(credits, for: meta.id)
                }

                // 2. Production & Networks (TMDB) -> Apply immediately when ready (~200ms)
                group.addTask {
                    let companies = await TmdbDetailsService.fetchCompanies(for: meta)
                    await self.applyCompanies(companies, for: meta.id)
                }

                // 3. More Like This (TMDB / Trakt / Simkl) -> Progressive load & hydrate
                group.addTask {
                    await self.loadMoreLikeThis(for: meta)
                }

                // 4. Trakt Comments -> Apply immediately when ready
                group.addTask {
                    let comments = await TraktDetailsService.fetchTopComments(for: meta)
                    await self.applyComments(comments, for: meta.id)
                }

                // 5. Simkl Ratings -> Apply immediately when ready
                group.addTask {
                    let simkl = await SimklDetailsService.fetchDetails(for: meta)
                    await self.applySimklRatings(simkl?.ratings, for: meta.id)
                }

                // 6. External Ratings (MDBList) -> Apply immediately when ready
                group.addTask {
                    let mdbRatings = await MdbListDetailsService.fetchRatings(for: meta)
                    await self.applyMdbRatings(mdbRatings, for: meta.id)
                }

                // 7. TMDB Episodes (Series only!) -> Runs in background without blocking cast/production
                let isSeries = meta.isSeries || NuvioMeta.isSeriesType(meta.type)
                if isSeries {
                    group.addTask {
                        let tmdbEpisodes = await TmdbDetailsService.fetchEpisodes(for: meta)
                        await self.applyTmdbEpisodes(tmdbEpisodes, for: meta.id)
                    }
                }
            }
        }
    }

    private func applyCredits(_ credits: TmdbCreditMetadata?, for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        if let credits, !credits.isEmpty {
            if let currentMeta = uiState.meta {
                uiState.meta = credits.applying(to: currentMeta)
            }
            uiState.people = credits.people
        }
    }

    private func applyCompanies(_ companies: [MetaCompany], for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        if !companies.isEmpty {
            uiState.companies = companies
        }
    }

    private func applyComments(_ comments: [TraktCommentReview], for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        if !comments.isEmpty {
            uiState.comments = comments
        }
    }

    private func applySimklRatings(_ ratings: SimklTitleRatings?, for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        if let ratings {
            uiState.simklRatings = ratings
        }
    }

    private func applyMdbRatings(_ ratings: [NuvioExternalRating], for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        if !ratings.isEmpty, let currentMeta = uiState.meta {
            uiState.meta = currentMeta.withExternalRatings(ratings)
        }
    }

    private func applyTmdbEpisodes(_ episodes: [NuvioVideo]?, for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        if let episodes, !episodes.isEmpty, let currentMeta = uiState.meta {
            let mergedVideos = Self.mergeEpisodes(
                existing: currentMeta.videos,
                fromTmdb: episodes,
                parentId: currentMeta.id
            )
            uiState.meta = currentMeta.withVideos(mergedVideos)
        }
    }

    private func applyMoreLikeThis(_ items: [RelatedTitle], for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        uiState.moreLikeThis = items
    }

    private func applyInitialMoreLikeThisIfEmpty(_ items: [RelatedTitle], preferredSource: TraktMoreLikeThisSource, for metaId: String) {
        guard !Task.isCancelled, uiState.meta?.id == metaId else { return }
        if uiState.moreLikeThis.isEmpty || preferredSource == .tmdb {
            uiState.moreLikeThis = items
        }
    }

    private func loadMoreLikeThis(for meta: NuvioMeta) async {
        let preferredSource = TraktSettingsStore.moreLikeThisSource

        async let tmdbTask = TmdbDetailsService.fetchMoreLikeThis(for: meta)
        async let traktTask: [RelatedTitle] = (preferredSource == .trakt || TraktAuthStore.state.isAuthenticated)
            ? TraktDetailsService.fetchRelated(for: meta)
            : []
        async let simklTask: SimklTitleDetails? = (preferredSource == .simkl || SimklDetailsService.isConfigured)
            ? SimklDetailsService.fetchDetails(for: meta)
            : nil

        // If TMDB returns quickly, populate More Like This immediately:
        let tmdbRelated = await tmdbTask
        if !tmdbRelated.isEmpty {
            await self.applyInitialMoreLikeThisIfEmpty(tmdbRelated, preferredSource: preferredSource, for: meta.id)
        }

        let traktRelated = await traktTask
        let simklRelated = (await simklTask)?.related ?? []

        let preferred: [RelatedTitle]
        switch preferredSource {
        case .trakt: preferred = traktRelated
        case .tmdb: preferred = tmdbRelated
        case .simkl: preferred = simklRelated
        }
        let resolved = [preferred, tmdbRelated, traktRelated, simklRelated].first { !$0.isEmpty } ?? []

        guard !resolved.isEmpty else { return }

        await self.applyMoreLikeThis(resolved, for: meta.id)

        // Trakt's related endpoint commonly omits usable artwork even with
        // `extended=images`. Resolve those IMDb ids through Cinemeta so the
        // row gets the same poster data as Home. Keep the initial titles on
        // screen while these independent artwork requests finish.
        let hydrated = await hydrateRelatedArtwork(in: resolved)
        await self.applyMoreLikeThis(hydrated, for: meta.id)
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
        let cached = StreamsRepository.shared.state
        if !forceRefresh, cached.requestKey == key {
            applyDiscoveryState(cached, expectedKey: key)
        } else {
            var nextState = uiState
            nextState.streamGroups = []
            nextState.streams = []
            nextState.streamsRevision &+= 1
            nextState.isLoadingStreams = true
            nextState.streamsEmptyReason = nil
            uiState = nextState
        }

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
                let tmdbTitle = nonEmpty(tmdb.title)
                let titleToUse: String
                if let tmdbTitle, !tmdbTitle.hasPrefix("Episode ") {
                    titleToUse = tmdbTitle
                } else if !ex.title.isEmpty && !ex.title.hasPrefix("Episode ") {
                    titleToUse = ex.title
                } else {
                    titleToUse = tmdbTitle ?? ex.title
                }

                let overviewToUse = nonEmpty(tmdb.overview) ?? nonEmpty(ex.overview)

                result.append(NuvioVideo(
                    id: ex.id,
                    title: titleToUse,
                    season: ex.season,
                    episode: ex.episode,
                    thumbnail: tmdb.thumbnail ?? ex.thumbnail,
                    overview: overviewToUse,
                    released: tmdb.released ?? ex.released,
                    rating: tmdb.rating ?? ex.rating
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season == 0 ? Int.max : season
    }
}
