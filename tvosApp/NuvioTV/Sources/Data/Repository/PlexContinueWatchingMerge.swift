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
@MainActor
enum PlexContinueWatchingMerge {
    static func merged(
        into items: [ContinueWatchingItem],
        displayable: (ContinueWatchingItem) -> Bool
    ) -> [ContinueWatchingItem] {
        let index = PlexLibraryIndex.shared
        let candidates = index.inProgress()
        let candidateIDs = Set(candidates.map(\.title.contentId))
        // Plex's own cards from an earlier merge: drop those no longer in progress.
        var result = items.filter { item in
            !item.meta.id.hasPrefix("plex-") || candidateIDs.contains(item.meta.id)
        }
        guard !candidates.isEmpty else { return result }
        let dismissedKeys = ContinueWatchingDismissStore.keys()

        for candidate in candidates {
            let ids = identifiers(of: candidate.title)
            let season = candidate.item.season
            let episode = candidate.item.episode
            if isDismissed(ids: ids, season: season, episode: episode, keys: dismissedKeys) { continue }
            guard let meta = index.meta(for: candidate.title),
                  let card = card(for: candidate, meta: meta, keeping: nil),
                  displayable(card) else { continue }

            if let position = result.firstIndex(where: { matches($0.meta, ids: ids) }) {
                let existing = result[position]
                let plexPlayedAt = Date(timeIntervalSince1970: TimeInterval(candidate.state.lastViewedAt))
                // Same moment within a couple of seconds: the existing card
                // already reflects this play (Nuvio reports to Plex as it saves).
                guard plexPlayedAt.timeIntervalSince(existing.lastWatchedAt) > 2 else { continue }
                if existing.meta.id == candidate.title.contentId {
                    result[position] = card
                } else if let moved = self.card(for: candidate, meta: existing.meta, keeping: existing) {
                    result[position] = moved
                }
            } else {
                result.append(card)
            }
        }
        return result
    }

    /// A Continue Watching card at Plex's position. `keeping` is an existing
    /// card for the same title whose metadata and artwork are kept.
    private static func card(
        for candidate: PlexLibraryIndex.InProgress,
        meta: NuvioMeta,
        keeping existing: ContinueWatchingItem?
    ) -> ContinueWatchingItem? {
        guard let server = PlexServerStore.shared.server(id: candidate.title.serverID),
              let baseURL = server.baseURL,
              let stream = PlexClient.streamURL(baseURL: baseURL, partKey: candidate.item.partKey) else { return nil }
        let durationMs = candidate.item.durationMs ?? candidate.title.durationMs ?? 0
        guard durationMs > 0 else { return nil }
        let sameEpisode = existing?.season == candidate.item.season && existing?.episode == candidate.item.episode
        return ContinueWatchingItem(
            meta: meta,
            streamUrl: stream.absoluteString,
            position: candidate.state.resumeSeconds,
            duration: Double(durationMs) / 1000,
            lastWatchedAt: Date(timeIntervalSince1970: TimeInterval(candidate.state.lastViewedAt)),
            season: candidate.item.season,
            episode: candidate.item.episode,
            released: candidate.item.episodePremiereDate,
            episodeTitleOverride: sameEpisode ? existing?.episodeTitleOverride : candidate.item.episodeName,
            episodeOverviewOverride: sameEpisode ? existing?.episodeOverviewOverride : candidate.item.episodeOverview,
            episodeThumbnailOverride: sameEpisode ? existing?.episodeThumbnailOverride : nil
        )
    }

    /// Ids a Plex title answers to: its Plex content id, IMDb id, and TMDB id.
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
