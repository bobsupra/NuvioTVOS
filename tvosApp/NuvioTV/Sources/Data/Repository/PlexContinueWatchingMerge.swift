import Foundation

/// Puts what Plex has in progress into Home's Continue Watching row, so a
/// title started in another Plex app can be picked up here. One card per
/// title, as for every other source:
///
/// - A title already in the row keeps its card. When Plex has newer progress
///   for it (watched in the Plex app or Infuse since), the card moves to
///   Plex's episode and position.
/// - A title only Plex knows about gets a card of its own.
/// - Cards Plex added are retired once Plex no longer has the title in
///   progress (finished, or not played for 16 weeks).
/// - A dismissed card stays dismissed, whichever id it was dismissed under.
///
/// Home merges on the main actor and keeps the Plex cards it used, so the Top
/// Shelf feed, written off the main actor, shows the same row.
enum PlexContinueWatchingMerge {
    /// One Plex title in progress, with its card at Plex's position.
    struct Candidate: Sendable {
        /// Ids the title answers to: its Plex content id, IMDb id, and TMDB id.
        let ids: Set<String>
        let card: ContinueWatchingItem

        var contentId: String { card.meta.id }
    }

    /// What Plex has in progress, as Home last merged it.
    struct Snapshot: Sendable {
        /// Every title Plex has in progress, including ones without a card.
        let inProgressIDs: Set<String>
        let candidates: [Candidate]
    }

    struct MergeInput: Sendable {
        let inProgress: [PlexLibraryIndex.InProgress]
        let serverAccessByID: [String: PlexServerAccess]
        let episodeTitleTemplate: String
        let locale: Locale
    }

    private static let lock = NSLock()
    /// Nil until Home has merged for the active profile.
    private static var latest: Snapshot?

    @MainActor
    static func captureMergeInput() -> MergeInput {
        let index = PlexLibraryIndex.shared
        let inProgress = index.inProgress()
        let serverIDs = Set(inProgress.map(\.title.serverID))
        return MergeInput(
            inProgress: inProgress,
            serverAccessByID: serverIDs.isEmpty ? [:] : index.serverAccessSnapshot(for: serverIDs),
            episodeTitleTemplate: L10n.resolvedFormatTemplate("jellyfin_episode_fallback_title", fallback: "Episode %d"),
            locale: AppLocaleManager.shared.locale
        )
    }

    /// Computes Home's Plex-merged Continue Watching list and snapshot off the
    /// main actor from pre-captured index/server inputs.
    nonisolated static func prepareMerge(
        into items: [ContinueWatchingItem],
        input: MergeInput,
        displayable: (ContinueWatchingItem) -> Bool
    ) -> (merged: [ContinueWatchingItem], snapshot: Snapshot) {
        let current = currentSnapshot(from: input)
        let snapshot = Snapshot(
            inProgressIDs: current.inProgressIDs,
            candidates: current.candidates.filter { displayable($0.card) }
        )
        let mergedItems = merged(
            into: items,
            snapshot: snapshot,
            dismissedKeys: ContinueWatchingDismissStore.keys()
        )
        return (mergedItems, snapshot)
    }

    nonisolated static func commitLatestSnapshot(_ snapshot: Snapshot) {
        lock.lock()
        latest = snapshot
        lock.unlock()
    }

    /// Settings → Media Servers → Plex → Import watch progress. Off leaves
    /// the row as it is stored: nothing is added and nothing is removed.
    static var isEnabled: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.plexImportWatchProgress) as? Bool ?? true
    }

    /// Home's row with Plex's titles merged in.
    @MainActor
    static func merged(
        into items: [ContinueWatchingItem],
        displayable: (ContinueWatchingItem) -> Bool
    ) -> [ContinueWatchingItem] {
        guard isEnabled else {
            reset()
            return items
        }
        let prepared = prepareMerge(into: items, input: captureMergeInput(), displayable: displayable)
        commitLatestSnapshot(prepared.snapshot)
        return prepared.merged
    }

    /// `items` merged with Plex's state as it is now, without changing what
    /// Home merged last. For a Top Shelf link, which can arrive before Home has
    /// merged.
    @MainActor
    static func mergedNow(into items: [ContinueWatchingItem]) -> [ContinueWatchingItem] {
        guard isEnabled else { return items }
        return merged(
            into: items,
            snapshot: currentSnapshot(from: captureMergeInput()),
            dismissedKeys: ContinueWatchingDismissStore.keys()
        )
    }

    /// `items` merged with the Plex cards Home used last, or unchanged before
    /// Home has merged. Safe off the main actor.
    static func mergedWithLatest(into items: [ContinueWatchingItem]) -> [ContinueWatchingItem] {
        guard isEnabled else { return items }
        lock.lock()
        let snapshot = latest
        lock.unlock()
        guard let snapshot else { return items }
        return merged(into: items, snapshot: snapshot, dismissedKeys: ContinueWatchingDismissStore.keys())
    }

    /// Forgets what Home merged: the next profile has its own Plex state.
    static func reset() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    static func merged(
        into items: [ContinueWatchingItem],
        snapshot: Snapshot,
        dismissedKeys: Set<String>
    ) -> [ContinueWatchingItem] {
        // Plex's own cards from an earlier merge: drop those no longer in progress.
        var result = items.filter { item in
            !item.meta.id.hasPrefix("plex-") || snapshot.inProgressIDs.contains(item.meta.id)
        }
        let candidates = snapshot.candidates
        for candidate in candidates {
            let card = candidate.card
            if isDismissed(ids: candidate.ids, season: card.season, episode: card.episode, keys: dismissedKeys) { continue }
            if let position = result.firstIndex(where: { matches($0.meta, ids: candidate.ids) }) {
                let existing = result[position]
                // Same moment within a couple of seconds: the existing card
                // already reflects this play (Nuvio reports to Plex as it saves).
                guard card.lastWatchedAt.timeIntervalSince(existing.lastWatchedAt) > 2 else { continue }
                result[position] = existing.meta.id == candidate.contentId ? card : moved(card, onto: existing)
            } else {
                result.append(card)
            }
        }
        return result
    }

    /// Plex's titles in progress, with a card for each one Nuvio can play.
    nonisolated private static func currentSnapshot(from input: MergeInput) -> Snapshot {
        let candidates = input.inProgress.compactMap { candidate -> Candidate? in
            guard let meta = PlexLibraryIndex.meta(
                for: candidate.title,
                serverAccessByID: input.serverAccessByID,
                episodeTitleTemplate: input.episodeTitleTemplate,
                locale: input.locale
            ),
            let card = card(for: candidate, meta: meta, serverAccessByID: input.serverAccessByID) else { return nil }
            return Candidate(ids: identifiers(of: candidate.title), card: card)
        }
        return Snapshot(inProgressIDs: Set(input.inProgress.map(\.title.contentId)), candidates: candidates)
    }

    nonisolated private static func card(
        for candidate: PlexLibraryIndex.InProgress,
        meta: NuvioMeta,
        serverAccessByID: [String: PlexServerAccess]
    ) -> ContinueWatchingItem? {
        guard let access = serverAccessByID[candidate.title.serverID],
              let stream = PlexClient.streamURL(baseURL: access.baseURL, partKey: candidate.item.partKey) else { return nil }
        let durationMs = candidate.item.durationMs ?? candidate.title.durationMs ?? 0
        guard durationMs > 0 else { return nil }
        return ContinueWatchingItem(
            meta: meta,
            streamUrl: stream.absoluteString,
            position: candidate.state.resumeSeconds,
            duration: Double(durationMs) / 1000,
            lastWatchedAt: Date(timeIntervalSince1970: TimeInterval(candidate.state.lastViewedAt)),
            season: candidate.item.season,
            episode: candidate.item.episode,
            released: candidate.item.episodePremiereDate,
            episodeTitleOverride: candidate.item.episodeName,
            episodeOverviewOverride: candidate.item.episodeOverview,
            episodeThumbnailOverride: nil
        )
    }

    /// Plex's position on an existing card for the same title, keeping the
    /// card's metadata and artwork, and its episode details while the episode
    /// is the same.
    static func moved(_ card: ContinueWatchingItem, onto existing: ContinueWatchingItem) -> ContinueWatchingItem {
        let sameEpisode = existing.season == card.season && existing.episode == card.episode
        return ContinueWatchingItem(
            meta: existing.meta,
            streamUrl: card.streamUrl,
            position: card.position,
            duration: card.duration,
            lastWatchedAt: card.lastWatchedAt,
            season: card.season,
            episode: card.episode,
            released: card.released,
            episodeTitleOverride: sameEpisode ? existing.episodeTitleOverride : card.episodeTitleOverride,
            episodeOverviewOverride: sameEpisode ? existing.episodeOverviewOverride : card.episodeOverviewOverride,
            episodeThumbnailOverride: sameEpisode ? existing.episodeThumbnailOverride : nil
        )
    }

    private static func identifiers(of title: PlexIndexedTitle) -> Set<String> {
        var ids: Set<String> = [title.contentId]
        if let imdb = title.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:)) { ids.insert(imdb) }
        if let tmdb = title.tmdbId { ids.insert("tmdb:\(tmdb)") }
        return ids
    }

    private static func matches(_ meta: NuvioMeta, ids: Set<String>) -> Bool {
        if ids.contains(meta.id) { return true }
        if let imdb = (NuvioMeta.canonicalImdbID(from: meta.id) ?? meta.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:))),
           ids.contains(imdb) { return true }
        if let tmdb = meta.tmdbId, tmdb > 0, ids.contains("tmdb:\(tmdb)") { return true }
        return false
    }

    private static func isDismissed(ids: Set<String>, season: Int?, episode: Int?, keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        return ids.contains { id in
            keys.contains(id)
                || keys.contains(ContinueWatchingDismissStore.key(contentId: id, season: season, episode: episode))
                || keys.contains(ContinueWatchingDismissStore.key(contentId: id, season: nil, episode: nil))
        }
    }
}
