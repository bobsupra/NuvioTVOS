import Foundation

/// Plex's watch state as Nuvio's watched badges read it, and Nuvio's watched
/// toggles as Plex receives them. Like the AniList overlay, this is read
/// alongside Nuvio's own watched history and never written into it, so it
/// cannot create Trakt or account-sync history on its own.
///
/// Reads are lock-protected and callable from any thread: watched lookups run
/// off the main actor.
enum PlexWatched {
    private struct Snapshot {
        /// Watched "season:episode" keys per title key.
        var episodeKeys: [String: Set<String>] = [:]
        /// Title keys whose every synced file is watched.
        var watchedTitles: Set<String> = []
    }

    private static let lock = NSLock()
    private static var snapshot = Snapshot()

    /// Keys a Plex title answers to: its own content id and any IMDb or TMDB id.
    private static func keys(for title: PlexIndexedTitle) -> [String] {
        var keys = [title.contentId]
        if let imdb = title.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:)) { keys.append(imdb) }
        if let tmdb = title.tmdbId { keys.append("tmdb:\(tmdb)") }
        return keys
    }

    private static func keys(for meta: NuvioMeta) -> [String] {
        var keys = [meta.id]
        if let imdb = NuvioMeta.canonicalImdbID(from: meta.id) ?? meta.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:)) {
            keys.append(imdb)
        }
        if let tmdb = meta.tmdbId, tmdb > 0 { keys.append("tmdb:\(tmdb)") }
        return keys
    }

    /// Rebuilt by `PlexLibraryIndex` whenever titles or watch states change.
    static func rebuild(titles: [String: [PlexIndexedTitle]], states: [String: [String: PlexWatchState]]) {
        var next = Snapshot()
        for (serverID, serverTitles) in titles {
            guard let serverStates = states[serverID] else { continue }
            for title in serverTitles {
                var watchedEpisodes = Set<String>()
                var allWatched = !title.items.isEmpty
                for item in title.items {
                    let watched = serverStates[item.ratingKey]?.isWatched ?? false
                    if !watched { allWatched = false }
                    if watched, let season = item.season, let episode = item.episode {
                        watchedEpisodes.insert("\(season):\(episode)")
                    }
                }
                for key in keys(for: title) {
                    if !watchedEpisodes.isEmpty { next.episodeKeys[key, default: []].formUnion(watchedEpisodes) }
                    if allWatched { next.watchedTitles.insert(key) }
                }
            }
        }
        lock.lock()
        snapshot = next
        lock.unlock()
    }

    /// "season:episode" keys of the episodes Plex has as watched.
    static func watchedEpisodeKeys(meta: NuvioMeta) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshot.episodeKeys.isEmpty else { return [] }
        return keys(for: meta).reduce(into: Set<String>()) { $0.formUnion(snapshot.episodeKeys[$1] ?? []) }
    }

    /// A movie Plex has as watched, or a show whose every synced episode is.
    static func isWatched(meta: NuvioMeta) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshot.watchedTitles.isEmpty else { return false }
        return keys(for: meta).contains { snapshot.watchedTitles.contains($0) }
    }

    // MARK: - Nuvio's toggles, sent to Plex

    /// A whole title was marked watched or unwatched in Nuvio.
    static func markTitle(meta: NuvioMeta, watched: Bool) {
        mark(meta: meta, watched: watched) { _ in true }
    }

    static func markEpisode(meta: NuvioMeta, video: NuvioVideo, watched: Bool) {
        mark(meta: meta, watched: watched) { $0.season == video.season && $0.episode == video.episode }
    }

    static func markEpisodes(meta: NuvioMeta, videos: [NuvioVideo], watched: Bool) {
        let wanted = Set(videos.map { "\($0.season):\($0.episode)" })
        mark(meta: meta, watched: watched) { item in
            guard let season = item.season, let episode = item.episode else { return false }
            return wanted.contains("\(season):\(episode)")
        }
    }

    private static func mark(meta: NuvioMeta, watched: Bool, where matches: @escaping (PlexIndexedItem) -> Bool) {
        let metaKeys = keys(for: meta)
        Task { @MainActor in
            let index = PlexLibraryIndex.shared
            let titles = index.titles().filter { title in keys(for: title).contains(where: metaKeys.contains) }
            for title in titles {
                guard let client = PlexSessionManager.shared.client(forServerID: title.serverID) else { continue }
                let items = title.items.filter(matches)
                guard !items.isEmpty else { continue }
                // A whole show or movie is one request on its own rating key.
                let ratingKeys = items.count == title.items.count ? [title.ratingKey] : items.map(\.ratingKey)
                var updated: [String: PlexWatchState] = [:]
                for item in items {
                    var state = index.watchState(serverID: title.serverID, ratingKey: item.ratingKey) ?? PlexWatchState()
                    state.viewCount = watched ? max(state.viewCount, 1) : 0
                    state.viewOffsetMs = 0
                    updated[item.ratingKey] = state
                }
                if index.watchStatesByServerID[title.serverID] != nil {
                    index.setWatchStates(updated, forServerID: title.serverID, merging: true)
                }
                Task.detached(priority: .utility) {
                    for ratingKey in ratingKeys {
                        try? await client.setWatched(watched, ratingKey: ratingKey)
                    }
                }
            }
        }
    }
}
