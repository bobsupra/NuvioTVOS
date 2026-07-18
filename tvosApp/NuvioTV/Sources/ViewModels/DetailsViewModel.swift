//
//  DetailsViewModel.swift
//  NuvioTV
//
//  Created by Claude Code
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
    private var observedRequestKey: String?

    init(repository: CatalogRepository) {
        self.repository = repository
        self.usesSharedStreamDiscovery = !(repository is MockCatalogRepository)
    }

    func loadDetails(id: String, type: String) {
        Task {
            uiState = DetailsUiState(isLoading: true, error: nil)

            do {
                let meta = try await repository.getMetadata(id: id, type: type)
                uiState.meta = meta
                uiState.isInWatchlist = LibraryStore.contains(metaId: meta.id, type: meta.type)
                uiState.isWatched = WatchedStore.contains(metaId: meta.id, type: meta.type)
                uiState.isLoading = false

                // Movies stream off the title id; series stream per episode, loaded
                // on demand when the user picks one (see prepareStreams).
                if !meta.isSeries {
                    prepareStreams(forId: id, type: meta.type)
                }
            } catch {
                uiState.isLoading = false
                uiState.error = error.localizedDescription
            }
        }
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

        uiState.streamGroups = snapshot.groups
        uiState.streams = snapshot.allStreams
        uiState.streamsRevision = snapshot.revision
        uiState.isLoadingStreams = snapshot.isAnyLoading || !snapshot.hasResolvedTargets
        uiState.streamsEmptyReason = snapshot.emptyStateReason
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
        uiState.isInWatchlist = LibraryStore.toggle(meta: meta)
    }

    func toggleWatched() {
        guard let meta = uiState.meta else { return }
        uiState.isWatched = WatchedStore.toggle(meta: meta)
    }

}
