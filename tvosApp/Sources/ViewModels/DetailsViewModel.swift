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
    private var observedRequestKey: String?
    private var lastAppliedStreamsRequestKey: String?
    private var lastAppliedStreamsRevision: UInt64?

    init(repository: CatalogRepository) {
        self.repository = repository
        self.usesSharedStreamDiscovery = !(repository is MockCatalogRepository)
    }

    func loadDetails(id: String, type: String) {
        streamObserveTask?.cancel()
        enrichmentTask?.cancel()
        Task {
            uiState = DetailsUiState(isLoading: true, error: nil)

            do {
                let meta = try await repository.getMetadata(id: id, type: type)
                uiState.meta = meta
                uiState.isInWatchlist = LibraryStore.contains(metaId: meta.id, type: meta.type)
                uiState.isWatched = WatchedStore.contains(meta: meta)
                uiState.isLoading = false

                // Movies stream off the title id; series stream per episode, loaded
                // on demand when the user picks one (see prepareStreams).
                if !meta.isSeries {
                    prepareStreams(forId: id, type: meta.type)
                }
                loadEnrichment(for: meta)
            } catch {
                uiState.isLoading = false
                uiState.error = error.localizedDescription
            }
        }
    }

    /// Loads More Like This, Production companies, and top Trakt comments
    /// after the primary metadata is on screen.
    private func loadEnrichment(for meta: NuvioMeta) {
        enrichmentTask?.cancel()
        enrichmentTask = Task {
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

            let companies = await companiesTask
            let credits = await creditsTask
            let tmdbRelated = await tmdbRelatedTask
            let traktRelated = await traktRelatedTask
            let comments = await commentsTask
            let simkl = await simklTask
            let mdbRatings = await mdbRatingsTask

            guard !Task.isCancelled, uiState.meta?.id == meta.id else { return }

            // Use the source the user picked, then fall back through the others
            // so the row still fills when their choice returns nothing.
            let simklRelated = simkl?.related ?? []
            let preferred: [RelatedTitle]
            switch TraktSettingsStore.moreLikeThisSource {
            case .trakt: preferred = traktRelated
            case .tmdb: preferred = tmdbRelated
            case .simkl: preferred = simklRelated
            }
            let moreLikeThis = [preferred, tmdbRelated, traktRelated, simklRelated]
                .first { !$0.isEmpty } ?? []

            uiState.companies = companies
            if let credits, !credits.isEmpty, let currentMeta = uiState.meta {
                uiState.meta = credits.applying(to: currentMeta)
                uiState.people = credits.people
            }
            if let currentMeta = uiState.meta {
                uiState.meta = currentMeta.withExternalRatings(mdbRatings)
            }
            uiState.moreLikeThis = moreLikeThis
            uiState.comments = comments
            uiState.simklRatings = simkl?.ratings

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

}
