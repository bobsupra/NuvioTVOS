import Foundation

/// Builds the Continue Watching row from the raw `WatchProgressLedger`.
///
/// Metadata resolution lives here rather than in the sync pull, and it is
/// deliberately non-destructive: a title whose metadata cannot be fetched right
/// now is simply not rendered this pass, and is retried on the next rebuild.
/// The account's history stays in the ledger either way. This mirrors
/// `resolveRemoteMetadata()` in the phone app, where `meta == null` skips a card
/// instead of deleting the entry.
///
/// The row is paged like a catalog row. Only the first page is persisted:
/// every stored item carries its episode guide, so keeping a large account's
/// whole history in the file would push megabytes through `JSONDecoder` on each
/// `ContinueWatchingStore.items()` call — and that runs on every Home refresh,
/// resume lookup and Top Shelf write. Later pages live in memory for the
/// session, exactly as a catalog row's later pages do.
enum ContinueWatchingBuilder {
    /// Long-lived so its in-memory metadata cache survives across rebuilds.
    private static let repository = CinemetaCatalogRepository()

    /// Matches the persisted row cap, so the first page is exactly what a cold
    /// start shows before any scrolling.
    static let pageSize = 20
    /// Initial resolution budget matching Android TV (HomeNextUpInitialResolutionLimit = 32)
    /// to resolve series seeds and New Episode drops on cold start without requiring scroll.
    static let initialResolutionLimit = 36
    private static let metadataConcurrency = 4

    private static let lock = NSLock()
    private static var rebuildTask: Task<Void, Never>?
    private static var generation: UInt = 0

    private static func nextGeneration() -> UInt {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    private static func currentGen() -> UInt {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private static func isCurrentGeneration(_ gen: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation
    }

    /// One entry per title to render, newest first. `isSeed` marks a finished
    /// episode that becomes a "Next Up" card rather than resume progress.
    struct PlanEntry: Equatable, Sendable {
        let record: WatchProgressRecord
        let isSeed: Bool
    }

    /// Orders the row and the metadata spend that feeds it.
    ///
    /// A title with both a resume and a completion seed appears once, using the
    /// newer activity. Equal timestamps favor the seed that represents a
    /// just-finished episode. The result is newest-first, which is also the
    /// order pages are filled in — so the first page is always most recent.
    static func planEntries(
        candidates: [WatchProgressRecord],
        seeds: [WatchProgressRecord]
    ) -> [PlanEntry] {
        var candidateById: [String: WatchProgressRecord] = [:]
        for candidate in candidates {
            if let current = candidateById[candidate.contentId],
               current.lastWatchedAt >= candidate.lastWatchedAt {
                continue
            }
            candidateById[candidate.contentId] = candidate
        }

        var seedById: [String: WatchProgressRecord] = [:]
        for seed in seeds {
            if let current = seedById[seed.contentId],
               current.lastWatchedAt >= seed.lastWatchedAt {
                continue
            }
            seedById[seed.contentId] = seed
        }

        let contentIds = Set(candidateById.keys).union(seedById.keys)
        let entries = contentIds.compactMap { contentId -> PlanEntry? in
            switch (candidateById[contentId], seedById[contentId]) {
            case let (candidate?, seed?):
                // A genuinely newer resume remains the visible card. At equal
                // timestamps the completion seed wins, since it represents the
                // episode that was just finished.
                return PlanEntry(
                    record: candidate.lastWatchedAt > seed.lastWatchedAt ? candidate : seed,
                    isSeed: candidate.lastWatchedAt <= seed.lastWatchedAt
                )
            case let (candidate?, nil):
                return PlanEntry(record: candidate, isSeed: false)
            case let (nil, seed?):
                return PlanEntry(record: seed, isSeed: true)
            case (nil, nil):
                return nil
            }
        }
        return entries.sorted { $0.record.lastWatchedAt > $1.record.lastWatchedAt }
    }

    @MainActor private static var plan: [PlanEntry] = []
    @MainActor private static var materialized: [ContinueWatchingItem] = []
    @MainActor private static var consumedEntries = 0
    @MainActor private static var isLoadingPage = false
    /// Exact identities written by the initial `replaceAll(page.items)` call.
    /// `ContinueWatchingStore` can reorder those items by release recency, so
    /// their membership cannot be recovered by slicing `materialized`.
    @MainActor private static var persistedFirstPageIDs: Set<String> = []
    /// Whose history `plan` and `materialized` describe.
    ///
    /// This state is static while the profile it belongs to is not, and Home
    /// merges `pagedItems` with the store on every refresh. A switch re-points
    /// the store immediately, so without an owner to check against, the outgoing
    /// profile's cards keep rendering under the new profile's name until some
    /// later rebuild happens to replace them.
    @MainActor private static var materializedProfileId: String?

    /// Every item built so far, including pages beyond the persisted first one —
    /// empty unless they belong to the profile that is active now.
    @MainActor
    static var pagedItems: [ContinueWatchingItem] {
        materializedProfileId == WatchProgressLedger.activeProfileId ? materialized : []
    }

    /// Items materialized after the persisted page. Home merges these with the
    /// current store snapshot, which remains authoritative for titles that were
    /// updated or removed after materialization.
    @MainActor
    static var memoryOnlyPagedItems: [ContinueWatchingItem] {
        guard materializedProfileId == WatchProgressLedger.activeProfileId else { return [] }
        return memoryOnlyItems(from: materialized, persistedItemIDs: persistedFirstPageIDs)
    }

    /// Pure membership filter kept separate from view state so page membership
    /// remains stable even when the store's recency ordering differs.
    static func memoryOnlyItems(
        from items: [ContinueWatchingItem],
        persistedItemIDs: Set<String>
    ) -> [ContinueWatchingItem] {
        items.filter { !persistedItemIDs.contains($0.meta.id) }
    }

    /// Merge later in-memory pages first and the current persisted snapshot
    /// second, so a newer store value wins and a removed first-page title cannot
    /// be resurrected from the builder cache.
    static func mergeMemoryOnlyItems(
        _ memoryOnlyItems: [ContinueWatchingItem],
        with storedItems: [ContinueWatchingItem]
    ) -> [ContinueWatchingItem] {
        var byId: [String: ContinueWatchingItem] = [:]
        for item in memoryOnlyItems {
            byId[item.meta.id] = item
        }
        for item in storedItems {
            byId[item.meta.id] = item
        }
        return Array(byId.values)
    }

    /// True while the ledger still holds titles that have not been rendered.
    @MainActor
    static var canLoadMore: Bool {
        materializedProfileId == WatchProgressLedger.activeProfileId
            && consumedEntries < plan.count
    }

    /// Last outcome, for the on-screen sync diagnostic.
    @MainActor
    static private(set) var diagnostic = "not built"

    /// Coalesces rebuild requests; the newest request wins. Debounced slightly by default to avoid duplicate builds.
    static func scheduleRebuild(reason: String, delayMs: UInt64 = 150) {
        lock.lock()
        rebuildTask?.cancel()
        generation &+= 1
        let gen = generation
        let task = Task.detached(priority: .utility) {
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            await rebuild(reason: reason, expectedGeneration: gen)
        }
        rebuildTask = task
        lock.unlock()
    }

    /// Invalidates deferred and in-flight builds when their account or profile
    /// context is no longer current.
    static func cancelScheduledRebuild() {
        lock.lock()
        rebuildTask?.cancel()
        rebuildTask = nil
        generation &+= 1
        lock.unlock()
    }

    static func rebuild(reason: String) async {
        let gen = nextGeneration()
        await rebuild(reason: reason, expectedGeneration: gen)
    }

    private static func rebuild(reason: String, expectedGeneration: UInt) async {
        guard !Task.isCancelled, isCurrentGeneration(expectedGeneration) else { return }
        let rebuildStarted = TVHomeDebugTrace.now()
        TVHomeDebugTrace.log("cw.builder.rebuild.begin reason=\(reason)")
        print("[ContinueWatchingBuilder] rebuild started: reason=\(reason)")
        // With Trakt or Simkl driving the row, Home renders that provider's list
        // and this derived one is never shown. Keep syncing rows into the ledger,
        // but do not spend metadata requests rendering something invisible.
        guard !RemoteTrackingState.isProgressSourceAuthenticated else {
            print("[ContinueWatchingBuilder] rebuild: skipped because remote progress source is authenticated")
            await MainActor.run {
                diagnostic = "\(reason): skipped, remote progress source active"
            }
            return
        }

        guard !Task.isCancelled, isCurrentGeneration(expectedGeneration) else { return }
        let profileId = WatchProgressLedger.activeProfileId
        // Metadata resolution below suspends. Keep the exact ledger input so a
        // playback save that lands while it is in flight cannot be overwritten
        // by this older derived row.
        let ledgerSnapshot = WatchProgressLedger.records()

        let candidates = WatchProgressLedger.continueWatchingCandidates()
        let seeds = ContinueWatchingFeatureFlags.nextUpCardsEnabled
            ? mergedSeedRecords(
                WatchProgressLedger.upNextSeeds(),
                watchedHistorySeeds()
            )
            : []
        print("[ContinueWatchingBuilder] rebuild: profile=\(profileId ?? "nil"), ledger records=\(ledgerSnapshot.count), candidates=\(candidates.count) (\(candidates.map(\.progressKey))), seeds=\(seeds.count) (\(seeds.map(\.progressKey)))")
        guard !candidates.isEmpty || !seeds.isEmpty else {
            print("[ContinueWatchingBuilder] rebuild: ledger empty -> setting empty CW store")
            guard !Task.isCancelled, isCurrentGeneration(expectedGeneration), profileId == WatchProgressLedger.activeProfileId else { return }
            await MainActor.run {
                guard isCurrentGeneration(expectedGeneration), profileId == WatchProgressLedger.activeProfileId else { return }
                diagnostic = "\(reason): ledger empty"
                plan = []
                materialized = []
                consumedEntries = 0
                persistedFirstPageIDs = []
                materializedProfileId = profileId
                ContinueWatchingStore.replaceAll([])
            }
            return
        }

        let currentPlan = planEntries(candidates: candidates, seeds: seeds)
        let existingItems = ContinueWatchingStore.items()
        print("[ContinueWatchingBuilder] rebuild: plan count=\(currentPlan.count)")

        let targetCount = min(max(currentPlan.count, pageSize), initialResolutionLimit)
        let page = await materializePage(
            from: currentPlan,
            startingAt: 0,
            targetCount: targetCount,
            existingItems: existingItems,
            generation: expectedGeneration,
            profileId: profileId
        )
        guard !Task.isCancelled, isCurrentGeneration(expectedGeneration), profileId == WatchProgressLedger.activeProfileId else {
            print("[ContinueWatchingBuilder] rebuild: generation outdated or profile changed -> cancelling this pass")
            return
        }

        // Finishing an episode writes its completed ledger row and then saves a
        // display-only Next Up card. A rebuild that began before those writes
        // used to finish afterward, filter its stale resume row as watched, and
        // replace the freshly saved card with an empty page. Leave the newer
        // store untouched and derive it again from the completed ledger row.
        guard rebuildInputIsCurrent(ledgerSnapshot, profileId: profileId) else {
            print("[ContinueWatchingBuilder] rebuild: ledger snapshot changed during materializeSlice! Retrying...")
            await MainActor.run {
                diagnostic = "\(reason): ledger changed while building, retrying"
            }
            scheduleRebuild(reason: "\(reason) (ledger changed)")
            return
        }

        print("[ContinueWatchingBuilder] rebuild: materialization finished, updating ContinueWatchingStore with \(page.items.count) items (failed lookups: \(page.failedLookups))")

        let diagText = "\(reason): ledger \(WatchProgressLedger.records().count), "
            + "candidates \(candidates.count), seeds \(seeds.count), plan \(currentPlan.count), "
            + "page 1 built \(page.items.count), showing \(page.items.count), "
            + "lookups failed \(page.failedLookups)"

        await MainActor.run {
            guard isCurrentGeneration(expectedGeneration), profileId == WatchProgressLedger.activeProfileId else { return }
            plan = currentPlan
            materialized = page.items
            consumedEntries = page.consumed
            materializedProfileId = profileId
            diagnostic = diagText
            // Only the first page is persisted; it is what a cold start renders.
            ContinueWatchingStore.replaceAll(page.items)
            persistedFirstPageIDs = Set(ContinueWatchingStore.items().map(\.meta.id))
        }

        TVHomeDebugTrace.log(
            "cw.builder.rebuild.end page=\(page.items.count) plan=\(currentPlan.count) "
                + "failed=\(page.failedLookups) "
                + "ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: rebuildStarted))"
        )
    }

    /// Visible for regression coverage of the stale-rebuild commit gate.
    static func rebuildInputIsCurrent(
        _ snapshot: [WatchProgressRecord],
        profileId: String?
    ) -> Bool {
        profileId == WatchProgressLedger.activeProfileId
            && WatchProgressLedger.records() == snapshot
    }

    /// Renders the next page of titles. Returns every item built so far so the
    /// caller can replace its row wholesale rather than reconcile an append.
    @MainActor
    @discardableResult
    static func loadNextPage() async -> [ContinueWatchingItem] {
        guard !isLoadingPage, canLoadMore else { return materialized }
        isLoadingPage = true
        defer { isLoadingPage = false }

        let currentGeneration = currentGen()
        let profileId = WatchProgressLedger.activeProfileId
        let currentConsumed = consumedEntries
        guard currentConsumed < plan.count else { return materialized }

        let existingItems = ContinueWatchingStore.items() + materialized
        let planSnapshot = plan

        let page = await Task.detached(priority: .utility) {
            await materializePage(
                from: planSnapshot,
                startingAt: currentConsumed,
                targetCount: pageSize,
                existingItems: existingItems,
                generation: currentGeneration,
                profileId: profileId
            )
        }.value

        guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
              profileId == WatchProgressLedger.activeProfileId else {
            return materialized
        }

        consumedEntries += page.consumed
        materialized = retainingUnwatched(materialized + page.items)
        return materialized
    }

    private struct MaterializePageResult: Sendable {
        let items: [ContinueWatchingItem]
        let consumed: Int
        let failedLookups: Int
    }

    private static func materializePage(
        from plan: [PlanEntry],
        startingAt startIndex: Int,
        targetCount: Int,
        existingItems: [ContinueWatchingItem],
        generation currentGeneration: UInt,
        profileId: String?
    ) async -> MaterializePageResult {
        var cursor = startIndex
        var accumulatedItems: [ContinueWatchingItem] = []
        var totalFailedLookups = 0
        var currentExisting = existingItems

        // Examine plan entries in batches until we reach targetCount items
        // or exhaust the plan. Cap the iteration budget to prevent runaway scans.
        let maxBatchScan = min(plan.count, startIndex + 60)

        while accumulatedItems.count < targetCount, cursor < plan.count, cursor < maxBatchScan {
            guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
                  profileId == WatchProgressLedger.activeProfileId else { break }
            let needed = targetCount - accumulatedItems.count
            let batchSize = max(needed, min(10, plan.count - cursor))
            let sliceEnd = min(cursor + batchSize, plan.count)
            let slice = Array(plan[cursor..<sliceEnd])
            cursor = sliceEnd

            let result = await materializeSlice(
                slice: slice,
                existingItems: currentExisting,
                generation: currentGeneration,
                profileId: profileId
            )
            guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
                  profileId == WatchProgressLedger.activeProfileId else { break }

            accumulatedItems.append(contentsOf: result.items)
            totalFailedLookups += result.failedLookups
            currentExisting += result.items

            if accumulatedItems.count >= targetCount {
                break
            }
        }

        return MaterializePageResult(
            items: accumulatedItems,
            consumed: cursor - startIndex,
            failedLookups: totalFailedLookups
        )
    }

    private struct PageResult: Sendable {
        let items: [ContinueWatchingItem]
        let failedLookups: Int
    }

    /// Resolves metadata for the slice of planned titles and appends the
    /// ones that could be rendered. TMDB episode enrichments are fetched concurrently.
    private static func materializeSlice(
        slice: [PlanEntry],
        existingItems: [ContinueWatchingItem],
        generation currentGeneration: UInt,
        profileId: String?
    ) async -> PageResult {
        let pageStarted = TVHomeDebugTrace.now()
        guard !slice.isEmpty else { return PageResult(items: [], failedLookups: 0) }
        guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
              profileId == WatchProgressLedger.activeProfileId else {
            return PageResult(items: [], failedLookups: 0)
        }

        // Already-rendered rows double as the metadata cache — they persist full
        // metadata including the episode guide.
        var metaById: [String: NuvioMeta] = [:]
        var existingById: [String: ContinueWatchingItem] = [:]
        for item in existingItems {
            metaById[item.meta.id] = item.meta
            existingById[item.meta.id] = item
        }

        var needsFetch: [(id: String, type: String, needsVideos: Bool)] = []
        var requested: Set<String> = []
        for entry in slice {
            let record = entry.record
            guard !requested.contains(record.contentId) else { continue }
            let cached = metaById[record.contentId]
            // A seed needs a real episode guide to find the next episode, so a
            // cached entry without videos still has to be refetched.
            let needsVideos = record.isSeries
            let hasUsableCache = cached != nil && (!needsVideos || cached?.videos?.isEmpty == false)
            guard !hasUsableCache else { continue }
            requested.insert(record.contentId)
            needsFetch.append((record.contentId, record.contentType, needsVideos))
        }

        let fetched = await fetchMetadata(
            needsFetch,
            generation: currentGeneration,
            profileId: profileId
        )
        TVHomeDebugTrace.log(
            "cw.builder.page slice=\(slice.count) metadataRequests=\(needsFetch.count) "
                + "resolved=\(fetched.count) "
                + "fetchMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: pageStarted))"
        )
        guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
              profileId == WatchProgressLedger.activeProfileId else {
            return PageResult(items: [], failedLookups: 0)
        }
        metaById.merge(fetched) { _, new in new }

        struct ItemSpec {
            let entry: PlanEntry
            let meta: NuvioMeta?
            let existing: ContinueWatchingItem?
            let season: Int?
            let episode: Int?
            let video: NuvioVideo?
            let isSeed: Bool
            let currentSeedSeason: Int?
        }

        var specs: [ItemSpec] = []
        var failedLookups = 0

        struct EnrichmentRequest {
            let specIndex: Int
            let meta: NuvioMeta
            let season: Int
            let episode: Int
        }
        var enrichmentRequests: [EnrichmentRequest] = []

        for entry in slice {
            let record = entry.record
            let existing = existingById[record.contentId]
            guard let meta = metaById[record.contentId] else {
                failedLookups += 1
                specs.append(ItemSpec(
                    entry: entry,
                    meta: nil,
                    existing: existing,
                    season: nil,
                    episode: nil,
                    video: nil,
                    isSeed: entry.isSeed,
                    currentSeedSeason: nil
                ))
                continue
            }

            if entry.isSeed {
                guard meta.isSeries else { continue }
                let current: (season: Int, episode: Int)?
                if let season = record.season, let episode = record.episode {
                    current = (season, episode)
                } else {
                    current = latestEpisodeForTitleSeed(
                        in: meta,
                        watchedAt: record.lastWatchedAt
                    )
                }
                let next: NuvioVideo?
                if let current {
                    next = nextEpisode(after: current, in: meta, seedWatchedAt: record.lastWatchedAt)
                } else {
                    next = firstReleasedEpisode(in: meta, seedWatchedAt: record.lastWatchedAt)
                }
                guard let next else {
                    specs.append(ItemSpec(
                        entry: entry,
                        meta: meta,
                        existing: shouldKeepCachedUpNext(existing, after: current) ? existing : nil,
                        season: nil,
                        episode: nil,
                        video: nil,
                        isSeed: true,
                        currentSeedSeason: nil
                    ))
                    continue
                }

                let specIndex = specs.count
                specs.append(ItemSpec(
                    entry: entry,
                    meta: meta,
                    existing: existing,
                    season: next.season,
                    episode: next.episode,
                    video: next,
                    isSeed: true,
                    currentSeedSeason: current?.season ?? next.season
                ))
                enrichmentRequests.append(EnrichmentRequest(
                    specIndex: specIndex,
                    meta: meta,
                    season: next.season,
                    episode: next.episode
                ))
                continue
            }

            let video = episode(in: meta, season: record.season, episode: record.episode)
            let specIndex = specs.count
            specs.append(ItemSpec(
                entry: entry,
                meta: meta,
                existing: existing,
                season: record.season,
                episode: record.episode,
                video: video,
                isSeed: false,
                currentSeedSeason: nil
            ))
            if let season = record.season, let ep = record.episode {
                enrichmentRequests.append(EnrichmentRequest(
                    specIndex: specIndex,
                    meta: meta,
                    season: season,
                    episode: ep
                ))
            }
        }

        // Concurrent TMDB Episode enrichment
        var tmdbEpisodesBySpecIndex: [Int: EpisodeMetadataEnrichment.Episode] = [:]
        if !enrichmentRequests.isEmpty && !Task.isCancelled && isCurrentGeneration(currentGeneration) && profileId == WatchProgressLedger.activeProfileId {
            await withTaskGroup(of: (Int, EpisodeMetadataEnrichment.Episode?).self) { group in
                var index = 0
                var inFlight = 0
                func addNext() {
                    guard index < enrichmentRequests.count else { return }
                    guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
                          profileId == WatchProgressLedger.activeProfileId else { return }
                    let req = enrichmentRequests[index]
                    index += 1
                    inFlight += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (req.specIndex, nil) }
                        let ep = await EpisodeMetadataEnrichment.fetch(
                            meta: req.meta,
                            season: req.season,
                            episode: req.episode
                        )
                        return (req.specIndex, ep)
                    }
                }
                for _ in 0..<min(6, enrichmentRequests.count) { addNext() }
                while inFlight > 0 {
                    guard let (idx, ep) = await group.next() else { break }
                    inFlight -= 1
                    if let ep { tmdbEpisodesBySpecIndex[idx] = ep }
                    if !Task.isCancelled && isCurrentGeneration(currentGeneration) && profileId == WatchProgressLedger.activeProfileId {
                        addNext()
                    } else {
                        group.cancelAll()
                    }
                }
            }
        }

        guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
              profileId == WatchProgressLedger.activeProfileId else {
            return PageResult(items: [], failedLookups: failedLookups)
        }

        // Assemble page items
        var page: [ContinueWatchingItem] = []
        for (idx, spec) in specs.enumerated() {
            guard let meta = spec.meta else {
                if let existing = spec.existing { page.append(existing) }
                continue
            }
            let tmdbEpisode = tmdbEpisodesBySpecIndex[idx]
            let existing = spec.existing
            let record = spec.entry.record

            if spec.isSeed {
                guard let season = spec.season, let ep = spec.episode, let next = spec.video else {
                    if let existing, existing.isUpNextEntry { page.append(existing) }
                    continue
                }
                page.append(
                    ContinueWatchingItem(
                        meta: meta,
                        streamUrl: "",
                        position: 1,
                        duration: max(record.duration, 120),
                        lastWatchedAt: record.lastWatchedAt,
                        season: season,
                        episode: ep,
                        released: tmdbEpisode?.released ?? next.released,
                        episodeTitleOverride: tmdbEpisode?.title ?? nonPlaceholder(next.title),
                        episodeOverviewOverride: tmdbEpisode?.overview ?? nonEmpty(next.overview),
                        episodeThumbnailOverride: tmdbEpisode?.thumbnail ?? next.thumbnail,
                        isUpNext: true,
                        upNextSeedSeason: spec.currentSeedSeason ?? season
                    )
                )
            } else {
                let sameEpisode = existing?.season == record.season && existing?.episode == record.episode
                let video = spec.video
                page.append(
                    ContinueWatchingItem(
                        meta: meta,
                        streamUrl: sameEpisode ? (existing?.streamUrl ?? "") : "",
                        position: record.position,
                        duration: record.duration,
                        lastWatchedAt: record.lastWatchedAt,
                        season: record.season,
                        episode: record.episode,
                        released: tmdbEpisode?.released ?? video?.released ?? (sameEpisode ? existing?.released : nil),
                        episodeTitleOverride: tmdbEpisode?.title
                            ?? nonPlaceholder(video?.title)
                            ?? (sameEpisode ? existing?.episodeTitleOverride : nil),
                        episodeOverviewOverride: tmdbEpisode?.overview
                            ?? nonEmpty(video?.overview)
                            ?? (sameEpisode ? existing?.episodeOverviewOverride : nil),
                        episodeThumbnailOverride: tmdbEpisode?.thumbnail
                            ?? video?.thumbnail
                            ?? (sameEpisode ? existing?.episodeThumbnailOverride : nil)
                    )
                )
            }
        }

        let filtered = retainingUnwatched(page)
        TVHomeDebugTrace.log(
            "cw.builder.page.end rendered=\(filtered.count) total=\(filtered.count) "
                + "ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: pageStarted))"
        )
        return PageResult(items: filtered, failedLookups: failedLookups)
    }

    // MARK: - Metadata

    private static func fetchMetadata(
        _ requests: [(id: String, type: String, needsVideos: Bool)],
        generation currentGeneration: UInt,
        profileId: String?
    ) async -> [String: NuvioMeta] {
        guard !requests.isEmpty else { return [:] }
        var resolved: [String: NuvioMeta] = [:]

        await withTaskGroup(of: (String, NuvioMeta?).self) { group in
            var index = 0
            var inFlight = 0

            func addNext() {
                guard index < requests.count else { return }
                guard !Task.isCancelled, isCurrentGeneration(currentGeneration),
                      profileId == WatchProgressLedger.activeProfileId else { return }
                let request = requests[index]
                index += 1
                inFlight += 1
                group.addTask {
                    guard !Task.isCancelled else { return (request.id, nil) }
                    // A seed needs a real episode guide, so bypass the cache for
                    // those; a plain resume row is happy with whatever is cached.
                    let rawMeta = request.needsVideos
                        ? try? await repository.refreshMetadata(id: request.id, type: request.type)
                        : try? await repository.getMetadata(id: request.id, type: request.type)
                    if let rawMeta {
                        guard !Task.isCancelled else { return (request.id, nil) }
                        let localized = await TmdbDetailsService.localizedMetadata(for: rawMeta)
                        return (request.id, localized)
                    }
                    return (request.id, nil)
                }
            }

            for _ in 0..<min(metadataConcurrency, requests.count) { addNext() }
            while inFlight > 0 {
                guard let (id, meta) = await group.next() else { break }
                inFlight -= 1
                if let meta { resolved[id] = meta }
                if !Task.isCancelled && isCurrentGeneration(currentGeneration) && profileId == WatchProgressLedger.activeProfileId {
                    addNext()
                } else {
                    group.cancelAll()
                }
            }
        }
        return resolved
    }

    // MARK: - Watched retirement

    /// Drops rows a durable watched mark has superseded. This filters the
    /// rendered list only — the ledger keeps the row so a later rewatch still
    /// has its resume point.
    private static func retainingUnwatched(_ items: [ContinueWatchingItem]) -> [ContinueWatchingItem] {
        let watched = WatchedStore.items()
        guard !watched.isEmpty else { return items }
        let newestByIdentity = WatchedStore.newestWatchedDatesByIdentity(watched)

        return items.filter { item in
            guard item.isUpNextEntry else { return true }
            let keys = WatchedStore.watchedIdentityKeys(
                metaId: item.meta.id,
                imdbId: item.meta.imdbId,
                tmdbId: item.meta.tmdbId,
                contentType: item.meta.type,
                season: item.meta.isSeries ? item.season : nil,
                episode: item.meta.isSeries ? item.episode : nil
            )
            let isSuperseded = keys.contains {
                newestByIdentity[$0].map { $0 >= item.lastWatchedAt } ?? false
            }
            if isSuperseded {
                print("[ContinueWatchingBuilder] retainingUnwatched: filtered out \(item.meta.id) S\(item.season.map(String.init) ?? "nil")E\(item.episode.map(String.init) ?? "nil") (item lastWatchedAt=\(item.lastWatchedAt) <= watchedAt)")
            }
            return !isSuperseded
        }
    }

    // MARK: - Helpers

    /// The next episode worth surfacing, honouring the same release policy the
    /// rest of the app uses. Without this check the row filled with Next Up cards
    /// for episodes that have not aired, which then consumed slots in the capped
    /// list and — with "hide unreleased" on — were dropped again before display,
    /// leaving far fewer visible entries than the account actually had.
    private static func nextEpisode(
        after current: (season: Int, episode: Int),
        in meta: NuvioMeta,
        seedWatchedAt: Date
    ) -> NuvioVideo? {
        let allVideos = (meta.videos ?? []).sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        let mainSeasonVideos = allVideos.filter { $0.season > 0 }
        let videos = mainSeasonVideos.isEmpty ? allVideos : mainSeasonVideos

        return videos
            .filter { candidate in
                guard let watchedAt = WatchedStore.watchedAt(
                    meta: meta,
                    season: candidate.season,
                    episode: candidate.episode
                ) else { return true }
                return watchedAt < seedWatchedAt
            }
            .first { candidate in
                guard (candidate.season, candidate.episode) > (current.season, current.episode) else {
                    return false
                }
                return EpisodeReleasePolicy.shouldSurfaceNextEpisode(
                    watchedSeason: current.season,
                    candidateSeason: candidate.season,
                    released: candidate.released
                )
            }
    }

    /// A manually watched episode has no playback row to seed Next Up. Keep the
    /// watched history as a lightweight seed so a show that left Continue
    /// Watching can return when a later episode (especially a new-season
    /// premiere) appears in the refreshed guide.
    static func watchedHistorySeeds() -> [WatchProgressRecord] {
        let watched = WatchedStore.visibleItems()
        var selectedByContentId: [String: WatchProgressRecord] = [:]
        var hasEpisodeSeed: Set<String> = []

        for item in watched where item.meta.isSeries {
            guard let season = item.season,
                  let episode = item.episode,
                  season > 0,
                  episode > 0 else {
                continue
            }
            let record = WatchProgressRecord(
                progressKey: WatchProgressLedger.progressKey(
                    contentId: item.meta.id,
                    season: season,
                    episode: episode
                ),
                contentId: item.meta.id,
                contentType: "series",
                videoId: WatchProgressLedger.videoId(
                    contentId: item.meta.id,
                    season: season,
                    episode: episode
                ),
                season: season,
                episode: episode,
                // This record is only a display seed; it is never uploaded as
                // playback progress and its runtime is intentionally unknown.
                position: 1,
                duration: 1,
                lastWatchedAt: item.watchedAt
            )
            hasEpisodeSeed.insert(item.meta.id)
            if let current = selectedByContentId[item.meta.id],
               !UpNextEpisodeSelectionPolicy.prefers(
                   candidateSeason: season,
                   candidateEpisode: episode,
                   candidateWatchedAt: item.watchedAt,
                   over: current.season ?? 0,
                   currentEpisode: current.episode ?? 0,
                   currentWatchedAt: current.lastWatchedAt,
                   preferFurthestEpisode: UpNextEpisodeSelectionPolicy.prefersFurthestEpisode
               ) {
                continue
            }
            selectedByContentId[item.meta.id] = record
        }

        // Older title-only marks do not carry episode rows. They can still seed
        // a later season once metadata is refreshed; materialization resolves
        // their last episode from the guide using the marker's watch date.
        for item in watched where item.meta.isSeries && item.season == nil && item.episode == nil {
            guard !hasEpisodeSeed.contains(item.meta.id), selectedByContentId[item.meta.id] == nil else {
                continue
            }
            selectedByContentId[item.meta.id] = WatchProgressRecord(
                progressKey: WatchProgressLedger.progressKey(
                    contentId: item.meta.id,
                    season: nil,
                    episode: nil
                ),
                contentId: item.meta.id,
                contentType: "series",
                videoId: item.meta.id,
                season: nil,
                episode: nil,
                position: 1,
                duration: 1,
                lastWatchedAt: item.watchedAt
            )
        }

        return selectedByContentId.values.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    /// Merge playback-completion and watched-history seeds without producing a
    /// duplicate title. Furthest-episode preference matches the existing ledger
    /// and remote-provider Continue Watching policies.
    private static func mergedSeedRecords(
        _ first: [WatchProgressRecord],
        _ second: [WatchProgressRecord]
    ) -> [WatchProgressRecord] {
        var selectedByContentId: [String: WatchProgressRecord] = [:]
        for candidate in first + second {
            guard let current = selectedByContentId[candidate.contentId] else {
                selectedByContentId[candidate.contentId] = candidate
                continue
            }
            let candidateHasEpisode = candidate.season != nil && candidate.episode != nil
            let currentHasEpisode = current.season != nil && current.episode != nil
            if candidateHasEpisode != currentHasEpisode {
                if candidateHasEpisode { selectedByContentId[candidate.contentId] = candidate }
                continue
            }
            guard UpNextEpisodeSelectionPolicy.prefers(
                candidateSeason: candidate.season ?? 0,
                candidateEpisode: candidate.episode ?? 0,
                candidateWatchedAt: candidate.lastWatchedAt,
                over: current.season ?? 0,
                currentEpisode: current.episode ?? 0,
                currentWatchedAt: current.lastWatchedAt,
                preferFurthestEpisode: UpNextEpisodeSelectionPolicy.prefersFurthestEpisode
            ) else { continue }
            selectedByContentId[candidate.contentId] = candidate
        }
        return selectedByContentId.values.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    private static func latestEpisodeForTitleSeed(
        in meta: NuvioMeta,
        watchedAt: Date
    ) -> (season: Int, episode: Int)? {
        let watchedDay = Calendar.current.startOfDay(for: watchedAt)
        return (meta.videos ?? [])
            .filter { video in
                guard video.season > 0, video.episode > 0 else { return false }
                // A title mark only proves what was available before that day.
                // Treating the marker's own day as watched would hide a new
                // episode dated today, which is exactly the alert this row is
                // meant to surface.
                guard let releaseDate = EpisodeReleasePolicy.releaseDate(for: video.released) else {
                    return true
                }
                return releaseDate < watchedDay
            }
            .max { ($0.season, $0.episode) < ($1.season, $1.episode) }
            .map { ($0.season, $0.episode) }
    }

    private static func episode(in meta: NuvioMeta, season: Int?, episode: Int?) -> NuvioVideo? {
        guard let season, let episode else { return nil }
        return meta.videos?.first { $0.season == season && $0.episode == episode }
    }

    private static func firstReleasedEpisode(in meta: NuvioMeta, seedWatchedAt: Date) -> NuvioVideo? {
        if let titleWatchedAt = WatchedStore.watchedAt(meta: meta), titleWatchedAt >= seedWatchedAt {
            return nil
        }
        let allVideos = (meta.videos ?? []).sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        let mainSeasonVideos = allVideos.filter { $0.season > 0 }
        let videos = mainSeasonVideos.isEmpty ? allVideos : mainSeasonVideos

        return videos
            .filter { candidate in
                guard let watchedAt = WatchedStore.watchedAt(
                    meta: meta,
                    season: candidate.season,
                    episode: candidate.episode
                ) else { return true }
                return watchedAt < seedWatchedAt
            }
            .first { video in
                EpisodeReleasePolicy.hasAired(video.released)
                    || EpisodeReleasePolicy.isAiringToday(video.released)
                    || EpisodeReleasePolicy.showUnairedNextUp
            }
    }

    /// A resolved seed can invalidate a previously cached Up Next episode when
    /// watched history advances. Keep that cache only when it still points
    /// strictly beyond the seed; metadata failures use their separate fallback.
    static func shouldKeepCachedUpNext(
        _ existing: ContinueWatchingItem?,
        after current: (season: Int, episode: Int)?
    ) -> Bool {
        guard let existing,
              existing.isUpNextEntry,
              let current,
              let season = existing.season,
              let episode = existing.episode else {
            return false
        }
        return (season, episode) > (current.season, current.episode)
    }

    private static func nonPlaceholder(_ value: String?) -> String? {
        guard let value = nonEmpty(value), value.caseInsensitiveCompare("TBA") != .orderedSame else {
            return nil
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
