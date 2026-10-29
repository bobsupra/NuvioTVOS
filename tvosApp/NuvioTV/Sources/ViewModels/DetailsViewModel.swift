//
//  DetailsViewModel.swift
//  NuvioTV
//
//  ViewModel for content details screen
//

import Foundation
import Combine
import AetherEngine

struct DetailsBackgroundResolutionIdentity: Equatable {
    let streamID: String
    let episodeID: String?
    let candidate: NuvioStream

    static func == (lhs: DetailsBackgroundResolutionIdentity, rhs: DetailsBackgroundResolutionIdentity) -> Bool {
        let left = lhs.candidate
        let right = rhs.candidate
        guard lhs.streamID == rhs.streamID,
              lhs.episodeID == rhs.episodeID,
              left.id == right.id,
              left.directURL == right.directURL,
              (left.httpHeaders ?? [:]) == (right.httpHeaders ?? [:]) else {
            return false
        }
        guard left.directURL == nil else { return true }
        return left.effectiveInfoHash == right.effectiveInfoHash
            && left.effectiveFileIdx == right.effectiveFileIdx
            && left.sources == right.sources
            && left.filename == right.filename
    }
}

struct DetailsSavedPlaybackTarget: Equatable {
    let url: URL
    let httpHeaders: [String: String]
}

enum DetailsSavedPlaybackTargetResolver {
    typealias Lookup = (String, Int?, Int?, String?) -> (url: String, httpHeaders: [String: String])?

    static func resolve(
        metaID: String,
        episode: NuvioVideo?,
        profileID: String?,
        reuseEnabled: Bool,
        manualPicker: Bool,
        lookup: Lookup
    ) -> DetailsSavedPlaybackTarget? {
        guard reuseEnabled, !manualPicker,
              let saved = lookup(metaID, episode?.season, episode?.episode, profileID),
              let url = URL(string: saved.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        if scheme == "http" || scheme == "https" {
            guard url.host != nil else { return nil }
        }
        return DetailsSavedPlaybackTarget(url: url, httpHeaders: saved.httpHeaders)
    }
}

enum DetailsPlaybackPrewarmPolicy {
    static func shouldPrewarm(
        url: URL?,
        backend: PlayerBackendKind,
        backgroundStreamPreFetchEnabled: Bool,
        smartStreamSelectionEnabled: Bool,
        usesExternalPlayer: Bool,
        isPlayableMovieOrEpisode: Bool,
        isLiveOrSports: Bool,
        isSavedPlaybackTarget: Bool = false
    ) -> Bool {
        guard let url,
              backgroundStreamPreFetchEnabled,
              smartStreamSelectionEnabled || isSavedPlaybackTarget,
              !usesExternalPlayer,
              isPlayableMovieOrEpisode,
              !isLiveOrSports,
              backend == .aether,
              PlaybackBackendPolicy.isRemoteHTTP(url.absoluteString),
              !PlaybackBackendPolicy.isHLS(url.absoluteString),
              let host = url.host?.lowercased(),
              host != "::1",
              !host.hasPrefix("127."),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              host != "googlevideo.com",
              !host.hasSuffix(".googlevideo.com") else {
            return false
        }
        return true
    }
}

private final class DetailsPlaybackWarmOperationState: @unchecked Sendable {
    enum Status { case running, prepared, claimed, cancelled }

    private let lock = NSLock()
    private var storedStatus = Status.running

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return storedStatus
    }

    var isClaimed: Bool { status == .claimed }

    func markPrepared() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard storedStatus == .running else { return false }
        storedStatus = .prepared
        return true
    }

    func claimPrepared() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard storedStatus == .prepared else { return false }
        storedStatus = .claimed
        return true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if storedStatus != .claimed { storedStatus = .cancelled }
    }
}

/// Owns the one Details prewarm and serializes replacement cleanup so a late
/// canceled fetch cannot discard a newer warm for the same URL.
@MainActor
final class DetailsPlaybackPrewarmer {
    typealias WarmSource = @Sendable (URL, [String: String]) async -> Void
    typealias DiscardSource = @Sendable (URL) -> Void
    typealias WarmRangeProbe = @Sendable (URL, [String: String], String, UUID) async -> Void
    typealias DiscardRangeProbe = @Sendable (UUID) -> Void
    typealias PreparedWarmHook = @Sendable () async -> Void

    private struct Key: Equatable, Sendable {
        let url: URL
        let headers: [String: String]
        let hybridProfileID: String?

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.url.absoluteString == rhs.url.absoluteString
                && lhs.headers == rhs.headers
                && lhs.hybridProfileID == rhs.hybridProfileID
        }
    }

    private let warmSource: WarmSource
    private let discardSource: DiscardSource
    private let warmRangeProbe: WarmRangeProbe?
    private let discardRangeProbe: DiscardRangeProbe?
    private let afterWarmPrepared: PreparedWarmHook
    private var requestedKey: Key?
    private var activeKey: Key?
    private var completedKey: Key?
    private var activeGeneration: UInt64?
    private var activeWarmID: UUID?
    private var completedWarmID: UUID?
    private var activeOperationState: DetailsPlaybackWarmOperationState?
    private var completedOperationState: DetailsPlaybackWarmOperationState?
    private var detachedWarmTask: Task<Void, Never>?
    private var settlementTask: Task<Void, Never>?
    private var nextGeneration: UInt64 = 0
    private var isContextActive = true
    private var didHandOff = false

    init(
        warm: @escaping WarmSource,
        discard: @escaping DiscardSource,
        warmRangeProbe: WarmRangeProbe? = nil,
        discardRangeProbe: DiscardRangeProbe? = nil,
        afterWarmPrepared: @escaping PreparedWarmHook = {}
    ) {
        warmSource = warm
        discardSource = discard
        self.warmRangeProbe = warmRangeProbe
        self.discardRangeProbe = discardRangeProbe
        self.afterWarmPrepared = afterWarmPrepared
    }

    static func engineBacked() -> DetailsPlaybackPrewarmer {
        DetailsPlaybackPrewarmer(
            warm: { url, headers in
                _ = await AetherEngine.prewarm(url: url, httpHeaders: headers)
            },
            discard: { url in
                AetherEngine.discardPrewarmedSource(url: url)
            },
            warmRangeProbe: { url, headers, profileID, token in
                _ = await PlaybackStreamCacheManager.shared.warmRangeProbeMemo(
                    url: url, headers: headers, profileID: profileID, token: token
                )
            },
            discardRangeProbe: { token in
                PlaybackStreamCacheManager.discardRangeProbeMemo(token: token)
            }
        )
    }

    func activateContext() {
        didHandOff = false
        isContextActive = true
    }

    func warm(url: URL, headers: [String: String], hybridProfileID: String? = nil) {
        guard isContextActive, !didHandOff else { return }
        let key = Key(url: url, headers: headers, hybridProfileID: hybridProfileID)
        if requestedKey == key || completedKey == key { return }

        if let completedKey {
            if let completedWarmID, completedOperationState?.isClaimed != true {
                completedOperationState?.cancel()
                discardWarm(completedKey, token: completedWarmID)
            }
            self.completedKey = nil
            self.completedWarmID = nil
            self.completedOperationState = nil
        }
        requestedKey = key

        if let activeKey {
            if activeKey != key {
                activeOperationState?.cancel()
                detachedWarmTask?.cancel()
                if let activeWarmID { discardWarm(activeKey, token: activeWarmID) }
            }
            return
        }
        beginWarm(key)
    }

    /// Cancel the current warm while keeping this Details context available for
    /// another candidate, such as when selection changes to a non-HTTP source.
    func discardCurrent() {
        guard !didHandOff else { return }
        requestedKey = nil
        if let completedKey {
            if let completedWarmID, completedOperationState?.isClaimed != true {
                completedOperationState?.cancel()
                discardWarm(completedKey, token: completedWarmID)
            }
            self.completedKey = nil
            self.completedWarmID = nil
            self.completedOperationState = nil
        }
        activeOperationState?.cancel()
        detachedWarmTask?.cancel()
        if let activeKey, let activeWarmID { discardWarm(activeKey, token: activeWarmID) }
    }

    /// Ends Details work. A successfully matched handoff already transferred
    /// ownership to playback and is intentionally retained for engine adoption.
    func endContext() {
        guard !didHandOff else { return }
        isContextActive = false
        discardCurrent()
    }

    @discardableResult
    func handOff(urlString: String, headers: [String: String], retainOnlyIf allowed: Bool) -> Bool {
        guard !didHandOff else { return false }
        let actualURL = URL(string: urlString)
        let requestMatches = allowed
            && actualURL?.absoluteString == completedKey?.url.absoluteString
            && headers == completedKey?.headers

        let claimedCompletedWarm = requestMatches && completedOperationState?.claimPrepared() == true
        let claimedActiveWarm = !claimedCompletedWarm
            && allowed
            && actualURL?.absoluteString == activeKey?.url.absoluteString
            && headers == activeKey?.headers
            && activeOperationState?.claimPrepared() == true
        let matchedWarm = claimedCompletedWarm || claimedActiveWarm

        isContextActive = false
        didHandOff = true
        requestedKey = nil
        if matchedWarm {
            if claimedCompletedWarm {
                completedKey = nil
                completedWarmID = nil
                completedOperationState = nil
            } else {
                // Release actor-owned state so a returned Details context can
                // warm a new candidate before this operation's settlement runs.
                activeKey = nil
                activeWarmID = nil
                activeOperationState = nil
                activeGeneration = nil
            }
            // A claimed active operation may still be awaiting MainActor settlement.
            // Its operation state now owns the bytes through deinit and settlement.
            return true
        }

        activeOperationState?.cancel()
        detachedWarmTask?.cancel()
        if let activeKey, let activeWarmID {
            discardWarm(activeKey, token: activeWarmID)
        }
        if let completedKey, let completedWarmID {
            completedOperationState?.cancel()
            discardWarm(completedKey, token: completedWarmID)
            self.completedKey = nil
            self.completedWarmID = nil
            self.completedOperationState = nil
        }
        return false
    }

    deinit {
        if !didHandOff, activeOperationState?.isClaimed != true {
            activeOperationState?.cancel()
            detachedWarmTask?.cancel()
        }
        if !didHandOff, activeOperationState?.isClaimed != true, let activeKey, let activeWarmID {
            discardSource(activeKey.url)
            discardRangeProbe?(activeWarmID)
        }
        if !didHandOff, completedOperationState?.isClaimed != true, let completedKey, let completedWarmID {
            discardSource(completedKey.url)
            discardRangeProbe?(completedWarmID)
        }
    }

    /// Test seam that waits for the current bounded operation to settle.
    func waitForCurrentOperation() async {
        while true {
            let generation = nextGeneration
            let task = settlementTask
            await task?.value
            if nextGeneration == generation { return }
        }
    }

    func settlementTaskForTesting() -> Task<Void, Never>? { settlementTask }

    private func beginWarm(_ key: Key) {
        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        activeKey = key
        let warmID = UUID()
        activeWarmID = warmID
        let operationState = DetailsPlaybackWarmOperationState()
        activeOperationState = operationState

        let operation = Task.detached(priority: .utility) { [warmSource, discardSource, warmRangeProbe, discardRangeProbe, afterWarmPrepared] in
            guard !Task.isCancelled else {
                operationState.cancel()
                discardSource(key.url)
                discardRangeProbe?(warmID)
                return
            }
            async let sourceWarm: Void = warmSource(key.url, key.headers)
            if let profileID = key.hybridProfileID, let warmRangeProbe {
                async let cacheProbe: Void = warmRangeProbe(key.url, key.headers, profileID, warmID)
                _ = await (sourceWarm, cacheProbe)
            } else {
                await sourceWarm
            }
            guard operationState.markPrepared() else {
                discardSource(key.url)
                discardRangeProbe?(warmID)
                return
            }
            await afterWarmPrepared()
            if operationState.status == .cancelled {
                discardSource(key.url)
                discardRangeProbe?(warmID)
            }
        }
        detachedWarmTask = operation
        settlementTask = Task { @MainActor [weak self] in
            await operation.value
            self?.finishWarm(
                key, token: warmID, generation: generation,
                wasCancelled: operation.isCancelled, operationState: operationState
            )
        }
    }

    private func finishWarm(
        _ key: Key,
        token: UUID,
        generation: UInt64,
        wasCancelled: Bool,
        operationState: DetailsPlaybackWarmOperationState
    ) {
        guard activeGeneration == generation else { return }

        if operationState.isClaimed {
            activeKey = nil
            activeWarmID = nil
            activeOperationState = nil
            activeGeneration = nil
            detachedWarmTask = nil
            return
        }

        let isStale = wasCancelled || operationState.status == .cancelled || !isContextActive || requestedKey != key
        if isStale {
            operationState.cancel()
            // This runs before any replacement starts, so an old same-URL fetch
            // cannot remove bytes written by the replacement. Duplicate per-URL
            // take after the operation's own late-cancel cleanup is harmless.
            discardWarm(key, token: token)
        } else {
            completedKey = key
            completedWarmID = token
            completedOperationState = operationState
        }

        activeKey = nil
        activeWarmID = nil
        activeOperationState = nil
        activeGeneration = nil
        detachedWarmTask = nil

        guard isContextActive, !didHandOff, let requestedKey else { return }
        if requestedKey != key || isStale {
            beginWarm(requestedKey)
        }
    }

    private func discardWarm(_ key: Key, token: UUID) {
        discardSource(key.url)
        discardRangeProbe?(token)
    }
}

/// Selects where Details gets its progressive stream results. Keeping this
/// decision at composition time makes the view model independent of concrete
/// repository types and lets tests use deterministic repository streams.
enum DetailsStreamDiscoveryMode: Equatable {
    case shared
    case repository
}

@MainActor
class DetailsViewModel: ObservableObject {
    typealias AsyncDelay = () async throws -> Void
    typealias EnrichmentStarter = @MainActor (NuvioMeta, UInt64) -> Void

    @Published private(set) var uiState = DetailsUiState()
    private(set) var didLoadMetadataSuccessfully = false
    private(set) var metadataLoadError: String?
    private(set) var prefetchedStreamId: String?
    private(set) var prefetchedEpisode: NuvioVideo?
    private(set) var prefetchStartTime: Date?
    private(set) var requestedStreamId: String?

    private let repository: CatalogRepository
    private let streamDiscoveryMode: DetailsStreamDiscoveryMode
    private var metadataTask: Task<Void, Never>?
    private var streamObserveTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var deferredLoadTask: Task<Void, Never>?
    private(set) var watchlistMutationTask: Task<Void, Never>?
    /// Invalidates every asynchronous completion from an older details load.
    /// This is intentionally separate from the content id: the same title can
    /// be refreshed while its previous request is still in flight.
    private var detailsRequestGeneration: UInt64 = 0
    private var watchlistMutationGeneration: UInt64 = 0
    private var observedRequestKey: String?
    private var lastAppliedStreamsRequestKey: String?
    private var lastAppliedStreamsRevision: UInt64?
    private let deferredPreparationDelay: AsyncDelay
    private let injectedEnrichmentStarter: EnrichmentStarter?
    private let watchlistContext: @MainActor () -> SelectedLibraryMutationContext?
    private let remoteWatchlistMutation: @MainActor (NuvioMeta, Bool) async -> Bool

    init(
        repository: CatalogRepository,
        streamDiscoveryMode: DetailsStreamDiscoveryMode = .shared,
        deferredPreparationDelay: @escaping AsyncDelay = {
            try await Task.sleep(nanoseconds: 350_000_000)
        },
        enrichmentStarter: EnrichmentStarter? = nil,
        watchlistContext: @escaping @MainActor () -> SelectedLibraryMutationContext? = {
            SelectedLibraryMutationContext()
        },
        remoteWatchlistMutation: @escaping @MainActor (NuvioMeta, Bool) async -> Bool = { meta, membership in
            await SelectedLibraryService.setWatchlist(meta, isInWatchlist: membership)
        }
    ) {
        self.repository = repository
        self.streamDiscoveryMode = streamDiscoveryMode
        self.deferredPreparationDelay = deferredPreparationDelay
        self.injectedEnrichmentStarter = enrichmentStarter
        self.watchlistContext = watchlistContext
        self.remoteWatchlistMutation = remoteWatchlistMutation
    }

    @discardableResult
    func loadDetails(id: String, type: String) -> Task<Void, Never> {
        TVHomeDebugTrace.log("details.load.begin id=\(id) type=\(type)")
        didLoadMetadataSuccessfully = false
        metadataLoadError = nil
        metadataTask?.cancel()
        deferredLoadTask?.cancel()
        streamObserveTask?.cancel()
        enrichmentTask?.cancel()
        uiState.isLoadingEnrichment = false
        prefetchedStreamId = nil
        prefetchedEpisode = nil
        prefetchStartTime = nil
        requestedStreamId = nil
        detailsRequestGeneration &+= 1
        let requestGeneration = detailsRequestGeneration

        // Check if metadata is already in memory so we can render frame 0 instantly without showing a spinner.
        // Any cached catalog entry already has the title, artwork, rating, and description needed for frame 0,
        // allowing the details screen to appear immediately while full details and episode guides load in the background.
        var cachedHadImdbId = false
        if let cached = repository.cachedMetadata(for: id),
           !cached.name.isEmpty {
            cachedHadImdbId = NuvioMeta.canonicalImdbID(from: cached.imdbId ?? "") != nil
                || NuvioMeta.canonicalImdbID(from: cached.id) != nil
            uiState = DetailsUiState(
                isLoading: false,
                meta: seedingCachedRatings(into: cached),
                error: nil,
                isInWatchlist: LibraryStore.contains(metaId: cached.id, type: cached.type),
                isWatched: WatchedStore.contains(meta: cached)
            )
            if let enrichmentStarter = injectedEnrichmentStarter {
                enrichmentStarter(cached, requestGeneration)
            } else {
                loadEnrichment(for: cached, generation: requestGeneration)
            }
        } else if uiState.meta?.id != id {
            uiState = DetailsUiState(isLoading: true, error: nil)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let meta = try await repository.getMetadata(id: id, type: type)
                guard !Task.isCancelled,
                      self.detailsRequestGeneration == requestGeneration else { return }
                self.didLoadMetadataSuccessfully = true
                self.metadataLoadError = nil
                
                let resolvedMeta = self.seedingCachedRatings(
                    into: meta.preservingEnrichment(from: self.uiState.meta)
                )
                var primaryState = self.uiState
                primaryState.meta = resolvedMeta
                primaryState.isInWatchlist = LibraryStore.contains(metaId: resolvedMeta.id, type: resolvedMeta.type)
                primaryState.isWatched = WatchedStore.contains(meta: resolvedMeta)
                primaryState.isLoading = false
                primaryState.error = nil
                self.uiState = primaryState

                // Present primary metadata immediately for instant smooth transition.
                // Defer streams & heavy secondary enrichment until the screen transition
                // has completed (350ms). If the user quickly backs out, zero heavy work
                // or image decompression is performed!
                deferredLoadTask?.cancel()
                deferredLoadTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.deferredPreparationDelay()
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          self.detailsRequestGeneration == requestGeneration,
                          self.uiState.meta?.id == meta.id else { return }

                    self.triggerStreamPreFetch(for: meta)
                    let metaHasImdbId = NuvioMeta.canonicalImdbID(from: meta.imdbId ?? "") != nil
                        || NuvioMeta.canonicalImdbID(from: meta.id) != nil
                    let needsEnrichmentRetry = !cachedHadImdbId && metaHasImdbId
                    if self.enrichmentTask == nil || needsEnrichmentRetry {
                        if let enrichmentStarter = self.injectedEnrichmentStarter {
                            enrichmentStarter(meta, requestGeneration)
                        } else {
                            self.loadEnrichment(for: meta, generation: requestGeneration)
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.detailsRequestGeneration == requestGeneration else { return }
                self.didLoadMetadataSuccessfully = false
                self.metadataLoadError = error.localizedDescription
                if self.uiState.meta == nil {
                    self.uiState.isLoading = false
                    self.uiState.error = error.localizedDescription
                }
            }
        }
        metadataTask = task
        return task
    }

    func cancelAllTasks() {
        TVHomeDebugTrace.log("details.cancelAllTasks")
        detailsRequestGeneration &+= 1
        metadataTask?.cancel()
        metadataTask = nil
        deferredLoadTask?.cancel()
        deferredLoadTask = nil
        streamObserveTask?.cancel()
        streamObserveTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        uiState.isLoadingEnrichment = false
        prefetchedStreamId = nil
        prefetchedEpisode = nil
        prefetchStartTime = nil
        requestedStreamId = nil
    }

    func resolveDefaultPlayTarget(for meta: NuvioMeta) -> (streamId: String, episode: NuvioVideo?)? {
        if meta.isSeries || NuvioMeta.isSeriesType(meta.type) {
            guard let videos = meta.videos, !videos.isEmpty else {
                return nil
            }
            let continueItem: ContinueWatchingItem? = {
                if RemoteTrackingState.isProgressSourceAuthenticated {
                    return TraktProgressService.currentContinueWatchingItem(for: meta)
                }
                return ContinueWatchingStore.item(for: meta) ?? ContinueWatchingStore.item(for: meta.id)
            }()
            let watchedKeys = WatchedStore.currentSnapshot().watchedEpisodeKeys(meta: meta)
            let playTarget = TvDetailsPlayTargetBuilder.makePlayTarget(
                episodes: videos,
                continueItem: continueItem,
                watchedKeys: watchedKeys
            )
            if let episode = playTarget.episode {
                let streamId = meta.canonicalEpisodeStreamId(for: episode)
                return (streamId, episode)
            }
            return nil
        } else {
            return (meta.streamId, nil)
        }
    }

    func triggerStreamPreFetch(for meta: NuvioMeta) {
        let prefetchEnabled = (ProfileSettings.current.object(forKey: SettingsKey.backgroundStreamPreFetch) as? Bool) ?? true
        guard prefetchEnabled else { return }
        guard prefetchedStreamId == nil else { return }

        guard let (targetStreamId, targetEpisode) = resolveDefaultPlayTarget(for: meta) else {
            return
        }
        prefetchedStreamId = targetStreamId
        prefetchedEpisode = targetEpisode
        prefetchStartTime = Date()
        let contentType = (meta.isSeries || NuvioMeta.isSeriesType(meta.type)) ? "series" : meta.type
        if let targetEpisode {
            print("[PreFetch] 🚀 Started background stream pre-fetch for series \"\(meta.name)\" S\(targetEpisode.season)E\(targetEpisode.episode) (streamId: \(targetStreamId))")
        } else {
            print("[PreFetch] 🚀 Started background stream pre-fetch for \"\(meta.name)\" (streamId: \(targetStreamId))")
        }
        prepareStreams(forId: targetStreamId, type: contentType)
    }

    /// Loads More Like This, Production companies, and top Trakt comments
    /// progressively and concurrently as soon as each returns.
    private func loadEnrichment(for meta: NuvioMeta, generation: UInt64) {
        enrichmentTask?.cancel()
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            guard self.detailsRequestGeneration == generation,
                  self.uiState.meta?.id == meta.id else { return }
            TVHomeDebugTrace.log("details.enrich.begin id=\(meta.id)")
            self.uiState.isLoadingEnrichment = true
            defer {
                if self.detailsRequestGeneration == generation {
                    self.uiState.isLoadingEnrichment = false
                }
            }

            let isSeries = meta.isSeries || NuvioMeta.isSeriesType(meta.type)
            let preferredSource = TraktSettingsStore.moreLikeThisSource
            let isTraktAuth = TraktAuthStore.isAuthenticated
            let isSimklConfigured = SimklDetailsService.isConfigured
            let isMdbListMode = TraktSettingsStore.librarySourceMode == .mdblist && MdbListRuntimeSession.isAuthenticated()
            let isWeTrakrMode = TraktSettingsStore.librarySourceMode == .wetrakr && WeTrakrRuntimeSession.isAuthenticated()

            await withTaskGroup(of: Void.self) { group in
                // 1. TMDB Credits (Cast & Crew) - fast ~100ms
                group.addTask {
                    let credits = await TmdbDetailsService.fetchCredits(for: meta)
                    await MainActor.run { [weak self] in
                        self?.applyCredits(credits, for: meta.id, generation: generation)
                    }
                }

                // 2. TMDB Companies & Networks - fast ~100ms
                group.addTask {
                    let companies = await TmdbDetailsService.fetchCompanies(for: meta)
                    await MainActor.run { [weak self] in
                        self?.applyCompanies(companies, for: meta.id, generation: generation)
                    }
                }

                // 3. TMDB Episodes (TV series)
                if isSeries {
                    group.addTask {
                        let episodes = await TmdbDetailsService.fetchEpisodes(for: meta)
                        await MainActor.run { [weak self] in
                            self?.applyTmdbEpisodes(episodes, for: meta.id, generation: generation)
                        }
                    }
                }

                // 3b. TMDB Certification (Content Rating)
                if meta.certification == nil || meta.certification?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    group.addTask {
                        let cert = await TmdbDetailsService.fetchCertification(for: meta)
                        await MainActor.run { [weak self] in
                            self?.applyCertification(cert, for: meta.id, generation: generation)
                        }
                    }
                }

                // 4. External Ratings (MDBList & Add-ons)
                group.addTask {
                    async let mdbTask = MdbListDetailsService.fetchRatings(for: meta)
                    async let addonTask = AddonRatingsService.fetchRatings(for: meta)
                    let (mdbRatings, addonRatings) = await (mdbTask, addonTask)
                    let combinedRatings = mdbRatings + addonRatings
                    await MainActor.run { [weak self] in
                        self?.applyMdbRatings(combinedRatings, for: meta.id, generation: generation)
                    }
                }

                // 5. MDBList Watchlist
                if isMdbListMode {
                    group.addTask {
                        if let isInWatchlist = await MdbListLibraryService.isInWatchlist(meta) {
                            await MainActor.run { [weak self] in
                                self?.applyMdbListWatchlistMembership(isInWatchlist, for: meta.id, generation: generation)
                            }
                        }
                    }
                }

                // 5b. WeTrakr Watchlist
                if isWeTrakrMode {
                    group.addTask {
                        if let isInWatchlist = await WeTrakrLibraryService.isInWatchlist(meta) {
                            await MainActor.run { [weak self] in
                                self?.applyMdbListWatchlistMembership(isInWatchlist, for: meta.id, generation: generation)
                            }
                        }
                    }
                }

                // 6. Simkl Details & Ratings
                if isSimklConfigured {
                    group.addTask {
                        let simkl = await SimklDetailsService.fetchDetails(for: meta)
                        await MainActor.run { [weak self] in
                            self?.applySimklRatings(simkl?.ratings, for: meta.id, generation: generation)
                        }
                    }
                }

                // 7. Trakt Comments
                group.addTask {
                    let comments = await TraktDetailsService.fetchTopComments(for: meta)
                    await MainActor.run { [weak self] in
                        self?.applyComments(comments, for: meta.id, generation: generation)
                    }
                }

                // 8. More Like This
                group.addTask {
                    let moreLikeThis = await Self.fetchAndHydrateMoreLikeThis(
                        for: meta,
                        preferredSource: preferredSource,
                        isTraktAuth: isTraktAuth,
                        isSimklConfigured: isSimklConfigured
                    )
                    await MainActor.run { [weak self] in
                        self?.applyMoreLikeThis(moreLikeThis, for: meta.id, generation: generation)
                    }
                }
            }
        }
    }

    private func isCurrentRequest(metaId: String, generation: UInt64) -> Bool {
        !Task.isCancelled && detailsRequestGeneration == generation && uiState.meta?.id == metaId
    }



    private func applyCredits(_ credits: TmdbCreditMetadata?, for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        if let credits, !credits.isEmpty {
            if let currentMeta = uiState.meta {
                uiState.meta = credits.applying(to: currentMeta)
            }
            uiState.people = credits.people
        }
    }

    private func applyCompanies(_ companies: [MetaCompany], for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        if !companies.isEmpty {
            uiState.companies = companies
        }
    }

    private func applyComments(_ comments: [TraktCommentReview], for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        if !comments.isEmpty {
            uiState.comments = comments
        }
    }

    private func applySimklRatings(_ ratings: SimklTitleRatings?, for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        if let ratings {
            uiState.simklRatings = ratings
        }
    }

    private func applyMdbRatings(_ ratings: [NuvioExternalRating], for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        if !ratings.isEmpty, let currentMeta = uiState.meta {
            uiState.meta = currentMeta.withExternalRatings(ratings)
            // The Home hero shows the same row; reuse this answer there.
            AddonRatingsService.storeHomeHeroRatings(ratings, for: currentMeta)
        }
    }

    /// Ratings the Home hero already fetched for this title, so the Details
    /// ratings row is there on the first frame instead of popping in.
    private func seedingCachedRatings(into meta: NuvioMeta) -> NuvioMeta {
        guard meta.externalRatings?.isEmpty ?? true,
              let cached = AddonRatingsService.cachedHomeHeroRatings(for: meta),
              !cached.isEmpty else { return meta }
        return meta.withExternalRatings(cached)
    }

    private func applyCertification(_ certification: String?, for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        guard let cert = certification?.trimmingCharacters(in: .whitespacesAndNewlines), !cert.isEmpty else { return }
        guard let currentMeta = uiState.meta else { return }
        if currentMeta.certification == nil || currentMeta.certification?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            uiState.meta = currentMeta.withCertification(cert)
        }
    }

    private func applyMdbListUserRating(_ rating: Int?, for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        uiState.mdbListUserRating = rating
    }

    private func applyMdbListWatchlistMembership(
        _ membership: Bool,
        for metaId: String,
        generation: UInt64
    ) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        uiState.isInWatchlist = membership
    }

    private func applyTmdbEpisodes(_ episodes: [NuvioVideo]?, for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        if let episodes, !episodes.isEmpty, let currentMeta = uiState.meta {
            let mergedVideos = Self.mergeEpisodes(
                existing: currentMeta.videos,
                fromTmdb: episodes,
                parentId: currentMeta.id
            )
            let updatedMeta = currentMeta.withVideos(mergedVideos)
            uiState.meta = updatedMeta
            if (updatedMeta.isSeries || NuvioMeta.isSeriesType(updatedMeta.type)) && prefetchedStreamId == nil {
                triggerStreamPreFetch(for: updatedMeta)
            }
        }
    }

    private func applyMoreLikeThis(_ items: [RelatedTitle], for metaId: String, generation: UInt64) {
        guard isCurrentRequest(metaId: metaId, generation: generation) else { return }
        uiState.moreLikeThis = items
    }

    private static func fetchAndHydrateMoreLikeThis(
        for meta: NuvioMeta,
        preferredSource: TraktMoreLikeThisSource,
        isTraktAuth: Bool,
        isSimklConfigured: Bool
    ) async -> [RelatedTitle] {
        async let tmdbTask = TmdbDetailsService.fetchMoreLikeThis(for: meta)
        async let traktTask: [RelatedTitle] = (preferredSource == .trakt || isTraktAuth)
            ? TraktDetailsService.fetchRelated(for: meta)
            : []
        async let simklTask: SimklTitleDetails? = (preferredSource == .simkl || isSimklConfigured)
            ? SimklDetailsService.fetchDetails(for: meta)
            : nil

        let tmdbRelated = await tmdbTask
        let traktRelated = await traktTask
        let simklRelated = (await simklTask)?.related ?? []

        let preferred: [RelatedTitle]
        switch preferredSource {
        case .trakt: preferred = traktRelated
        case .tmdb: preferred = tmdbRelated
        case .simkl: preferred = simklRelated
        }
        let resolved = [preferred, tmdbRelated, traktRelated, simklRelated].first { !$0.isEmpty } ?? []

        guard !resolved.isEmpty else { return [] }

        return await hydrateRelatedArtwork(in: resolved)
    }

    private static func hydrateRelatedArtwork(in items: [RelatedTitle]) async -> [RelatedTitle] {
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
        requestedStreamId = streamId
        streamObserveTask?.cancel()

        if streamDiscoveryMode == .shared {
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
        uiState.streams = []
        uiState.streamGroups = []
        uiState.streamsRevision &+= 1
        uiState.streamsEmptyReason = nil
        uiState.isLoadingStreams = true
        streamObserveTask = Task {
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

    /// Refreshes local watchlist and watched state without reloading metadata,
    /// stream groups, or enrichment from the network.
    func refreshWatchlistAndWatchedStatus() {
        guard let meta = uiState.meta else { return }
        var updatedState = uiState
        updatedState.isInWatchlist = LibraryStore.contains(metaId: meta.id, type: meta.type)
        updatedState.isWatched = WatchedStore.contains(meta: meta)
        uiState = updatedState
    }

    func toggleWatchlist() {
        guard let meta = uiState.meta else { return }
        if TraktSettingsStore.librarySourceMode == .local {
            watchlistMutationGeneration &+= 1
            uiState.isInWatchlist = LibraryStore.toggle(meta: meta)
            return
        }

        // Capture the selected account before waiting; a later login must never
        // inherit this intent. Token refresh keeps the same account binding.
        guard let context = watchlistContext() else { return }

        // Keep Details responsive, then let LibraryViewModel refresh the
        // Trakt-backed list from the notification posted after the mutation.
        let desiredMembership = !uiState.isInWatchlist
        watchlistMutationGeneration &+= 1
        let mutationGeneration = watchlistMutationGeneration
        let requestGeneration = detailsRequestGeneration
        uiState.isInWatchlist = desiredMembership
        let previousMutation = watchlistMutationTask
        watchlistMutationTask = Task { @MainActor in
            if let previousMutation { await previousMutation.value }
            guard !Task.isCancelled, context.isCurrent else { return }
            let succeeded = await remoteWatchlistMutation(meta, desiredMembership)
            guard !Task.isCancelled, context.isCurrent,
                  watchlistMutationGeneration == mutationGeneration,
                  detailsRequestGeneration == requestGeneration,
                  uiState.meta?.id == meta.id,
                  uiState.meta?.type == meta.type else { return }
            if !succeeded, uiState.isInWatchlist == desiredMembership {
                uiState.isInWatchlist = !desiredMembership
            }
        }
    }

    func toggleWatched(libraryContext: LibraryWatchedContext? = nil) {
        guard let meta = uiState.meta else { return }
        if let libraryContext {
            guard libraryContext.isCurrent else { return }
            let desiredState = !WatchedStore.isWatchedForLibrary(
                meta: meta,
                source: libraryContext.source,
                profileId: libraryContext.profileId
            )
            _ = libraryContext.setWatched(meta, isWatched: desiredState)
            uiState.isWatched = WatchedStore.isWatchedForLibrary(
                meta: meta,
                source: libraryContext.source,
                profileId: libraryContext.profileId
            )
        } else {
            uiState.isWatched = WatchedStore.toggle(meta: meta)
        }
    }

    func setMdbListUserRating(_ rating: Int?) {
        uiState.mdbListUserRating = rating
    }

    func applyMdbRatingsForTesting(_ ratings: [NuvioExternalRating], for metaId: String) {
        applyMdbRatings(ratings, for: metaId, generation: detailsRequestGeneration)
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
