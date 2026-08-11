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
@MainActor
enum ContinueWatchingBuilder {
    /// Long-lived so its in-memory metadata cache survives across rebuilds.
    private static let repository = CinemetaCatalogRepository()

    /// Matches the persisted row cap, so the first page is exactly what a cold
    /// start shows before any scrolling.
    static let pageSize = 20
    private static let metadataConcurrency = 4

    private static var rebuildTask: Task<Void, Never>?
    private static var generation: UInt = 0

    /// One entry per title to render, newest first. `isSeed` marks a finished
    /// episode that becomes a "Next Up" card rather than resume progress.
    struct PlanEntry: Equatable {
        let record: WatchProgressRecord
        let isSeed: Bool
    }

    /// Orders the row and the metadata spend that feeds it.
    ///
    /// Real playback outranks a Next Up suggestion for the same title, so a seed
    /// whose show already has progress is dropped rather than rendered twice.
    /// The result is newest-first, which is also the order pages are filled in —
    /// so the first page is always the most recent activity.
    static func planEntries(
        candidates: [WatchProgressRecord],
        seeds: [WatchProgressRecord]
    ) -> [PlanEntry] {
        let candidateIds = Set(candidates.map(\.contentId))
        return (
            candidates.map { PlanEntry(record: $0, isSeed: false) }
                + seeds
                .filter { !candidateIds.contains($0.contentId) }
                .map { PlanEntry(record: $0, isSeed: true) }
        ).sorted { $0.record.lastWatchedAt > $1.record.lastWatchedAt }
    }

    private static var plan: [PlanEntry] = []
    private static var materialized: [ContinueWatchingItem] = []
    private static var consumedEntries = 0
    private static var isLoadingPage = false
    /// Whose history `plan` and `materialized` describe.
    ///
    /// This state is static while the profile it belongs to is not, and Home
    /// merges `pagedItems` with the store on every refresh. A switch re-points
    /// the store immediately, so without an owner to check against, the outgoing
    /// profile's cards keep rendering under the new profile's name until some
    /// later rebuild happens to replace them.
    private static var materializedProfileId: String?

    /// Every item built so far, including pages beyond the persisted first one —
    /// empty unless they belong to the profile that is active now.
    static var pagedItems: [ContinueWatchingItem] {
        materializedProfileId == WatchProgressLedger.activeProfileId ? materialized : []
    }

    /// True while the ledger still holds titles that have not been rendered.
    static var canLoadMore: Bool {
        materializedProfileId == WatchProgressLedger.activeProfileId
            && consumedEntries < plan.count
    }

    /// Last outcome, for the on-screen sync diagnostic.
    static private(set) var diagnostic = "not built"

    /// Coalesces rebuild requests; the newest request wins.
    static func scheduleRebuild(reason: String) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            await rebuild(reason: reason)
        }
    }

    static func rebuild(reason: String) async {
        // With Trakt or Simkl driving the row, Home renders that provider's list
        // and this derived one is never shown. Keep syncing rows into the ledger,
        // but do not spend metadata requests rendering something invisible.
        guard !RemoteTrackingState.isProgressSourceAuthenticated else {
            diagnostic = "\(reason): skipped, remote progress source active"
            return
        }

        generation &+= 1
        let currentGeneration = generation
        let profileId = WatchProgressLedger.activeProfileId
        // Metadata resolution below suspends. Keep the exact ledger input so a
        // playback save that lands while it is in flight cannot be overwritten
        // by this older derived row.
        let ledgerSnapshot = WatchProgressLedger.records()

        let candidates = WatchProgressLedger.continueWatchingCandidates()
        let seeds = WatchProgressLedger.upNextSeeds()
        guard !candidates.isEmpty || !seeds.isEmpty else {
            diagnostic = "\(reason): ledger empty"
            plan = []
            materialized = []
            consumedEntries = 0
            materializedProfileId = profileId
            return
        }

        plan = planEntries(candidates: candidates, seeds: seeds)
        materialized = []
        consumedEntries = 0
        materializedProfileId = profileId

        let page = await materializeNextPage(
            generation: currentGeneration,
            profileId: profileId
        )
        guard !Task.isCancelled, currentGeneration == generation else { return }

        // Finishing an episode writes its completed ledger row and then saves a
        // display-only Next Up card. A rebuild that began before those writes
        // used to finish afterward, filter its stale resume row as watched, and
        // replace the freshly saved card with an empty page. Leave the newer
        // store untouched and derive it again from the completed ledger row.
        guard rebuildInputIsCurrent(ledgerSnapshot) else {
            diagnostic = "\(reason): ledger changed while building, retrying"
            scheduleRebuild(reason: "\(reason) (ledger changed)")
            return
        }

        // Only the first page is persisted; it is what a cold start renders.
        ContinueWatchingStore.replaceAll(page.items)
        diagnostic = "\(reason): ledger \(WatchProgressLedger.records().count), "
            + "candidates \(candidates.count), seeds \(seeds.count), plan \(plan.count), "
            + "page 1 built \(page.items.count), showing \(ContinueWatchingStore.items().count), "
            + "lookups failed \(page.failedLookups)"
    }

    /// Visible for regression coverage of the stale-rebuild commit gate.
    static func rebuildInputIsCurrent(_ snapshot: [WatchProgressRecord]) -> Bool {
        WatchProgressLedger.records() == snapshot
    }

    /// Renders the next page of titles. Returns every item built so far so the
    /// caller can replace its row wholesale rather than reconcile an append.
    @discardableResult
    static func loadNextPage() async -> [ContinueWatchingItem] {
        guard !isLoadingPage, canLoadMore else { return materialized }
        isLoadingPage = true
        defer { isLoadingPage = false }

        let currentGeneration = generation
        let profileId = WatchProgressLedger.activeProfileId
        _ = await materializeNextPage(generation: currentGeneration, profileId: profileId)
        return materialized
    }

    private struct PageResult {
        let items: [ContinueWatchingItem]
        let failedLookups: Int
    }

    /// Resolves metadata for the next `pageSize` planned titles and appends the
    /// ones that could be rendered. A title whose metadata cannot be fetched is
    /// skipped for this pass and retried on the next rebuild — it stays in the
    /// ledger regardless.
    private static func materializeNextPage(
        generation currentGeneration: UInt,
        profileId: String?
    ) async -> PageResult {
        let slice = Array(plan.dropFirst(consumedEntries).prefix(pageSize))
        guard !slice.isEmpty else { return PageResult(items: materialized, failedLookups: 0) }

        // Already-rendered rows double as the metadata cache — they persist full
        // metadata including the episode guide.
        var metaById: [String: NuvioMeta] = [:]
        var existingById: [String: ContinueWatchingItem] = [:]
        for item in ContinueWatchingStore.items() + materialized {
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

        let fetched = await fetchMetadata(needsFetch)
        guard !Task.isCancelled, currentGeneration == generation,
              profileId == WatchProgressLedger.activeProfileId else {
            return PageResult(items: materialized, failedLookups: 0)
        }
        metaById.merge(fetched) { _, new in new }

        var page: [ContinueWatchingItem] = []
        var failedLookups = 0

        for entry in slice {
            let record = entry.record
            guard let meta = metaById[record.contentId] else {
                failedLookups += 1
                continue
            }
            let existing = existingById[record.contentId]

            if entry.isSeed {
                guard meta.isSeries,
                      let season = record.season,
                      let episodeNumber = record.episode else { continue }
                guard let next = nextEpisode(after: (season, episodeNumber), in: meta) else {
                    // Caught up, or the guide could not be loaded this pass. A
                    // card already on screen must not disappear for the latter.
                    if let existing, existing.isUpNextEntry { page.append(existing) }
                    continue
                }
                let tmdbEpisode = await EpisodeMetadataEnrichment.fetch(
                    meta: meta,
                    season: next.season,
                    episode: next.episode
                )
                page.append(
                    ContinueWatchingItem(
                        meta: meta,
                        streamUrl: "",
                        position: 1,
                        // Reuse the finished episode's runtime as the estimate.
                        duration: max(record.duration, 120),
                        lastWatchedAt: record.lastWatchedAt,
                        season: next.season,
                        episode: next.episode,
                        released: tmdbEpisode?.released ?? next.released,
                        episodeTitleOverride: tmdbEpisode?.title ?? nonPlaceholder(next.title),
                        episodeOverviewOverride: tmdbEpisode?.overview ?? nonEmpty(next.overview),
                        episodeThumbnailOverride: tmdbEpisode?.thumbnail ?? next.thumbnail,
                        isUpNext: true,
                        upNextSeedSeason: season
                    )
                )
                continue
            }

            let sameEpisode = existing?.season == record.season && existing?.episode == record.episode
            let video = episode(in: meta, season: record.season, episode: record.episode)
            page.append(
                ContinueWatchingItem(
                    meta: meta,
                    streamUrl: sameEpisode ? (existing?.streamUrl ?? "") : "",
                    position: record.position,
                    duration: record.duration,
                    lastWatchedAt: record.lastWatchedAt,
                    season: record.season,
                    episode: record.episode,
                    released: video?.released ?? (sameEpisode ? existing?.released : nil),
                    episodeTitleOverride: nonPlaceholder(video?.title)
                        ?? (sameEpisode ? existing?.episodeTitleOverride : nil),
                    episodeOverviewOverride: nonEmpty(video?.overview)
                        ?? (sameEpisode ? existing?.episodeOverviewOverride : nil),
                    episodeThumbnailOverride: video?.thumbnail
                        ?? (sameEpisode ? existing?.episodeThumbnailOverride : nil)
                )
            )
        }

        consumedEntries += slice.count
        materialized = retainingUnwatched(materialized + page)
        return PageResult(items: materialized, failedLookups: failedLookups)
    }

    // MARK: - Metadata

    private static func fetchMetadata(
        _ requests: [(id: String, type: String, needsVideos: Bool)]
    ) async -> [String: NuvioMeta] {
        guard !requests.isEmpty else { return [:] }
        var resolved: [String: NuvioMeta] = [:]

        await withTaskGroup(of: (String, NuvioMeta?).self) { group in
            var index = 0
            var inFlight = 0

            func addNext() {
                guard index < requests.count else { return }
                let request = requests[index]
                index += 1
                inFlight += 1
                group.addTask {
                    // A seed needs a real episode guide, so bypass the cache for
                    // those; a plain resume row is happy with whatever is cached.
                    let meta = request.needsVideos
                        ? try? await repository.refreshMetadata(id: request.id, type: request.type)
                        : try? await repository.getMetadata(id: request.id, type: request.type)
                    return (request.id, meta)
                }
            }

            for _ in 0..<min(metadataConcurrency, requests.count) { addNext() }
            while inFlight > 0 {
                guard let (id, meta) = await group.next() else { break }
                inFlight -= 1
                if let meta { resolved[id] = meta }
                addNext()
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
            let keys = WatchedStore.watchedIdentityKeys(
                metaId: item.meta.id,
                imdbId: item.meta.imdbId,
                tmdbId: item.meta.tmdbId,
                contentType: item.meta.type,
                season: item.meta.isSeries ? item.season : nil,
                episode: item.meta.isSeries ? item.episode : nil
            )
            return !keys.contains {
                newestByIdentity[$0].map { $0 >= item.lastWatchedAt } ?? false
            }
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
        in meta: NuvioMeta
    ) -> NuvioVideo? {
        (meta.videos ?? [])
            .filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
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

    private static func episode(in meta: NuvioMeta, season: Int?, episode: Int?) -> NuvioVideo? {
        guard let season, let episode else { return nil }
        return meta.videos?.first { $0.season == season && $0.episode == episode }
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
