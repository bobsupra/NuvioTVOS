import Foundation

/// Finds one title in a Plex library too large to sync. The server is asked
/// for titles by name, and a result counts when its IMDb or TMDB id matches.
/// A result with no id to compare counts when its name and year match.
enum PlexLargeLibraryLookup {
    /// The title a stream list was opened for.
    struct Target: Equatable {
        let name: String
        let year: Int?
        let imdbId: String?
        let tmdbId: Int?

        init(name: String, year: Int?, imdbId: String?, tmdbId: Int?) {
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.year = year
            self.imdbId = imdbId.flatMap(NuvioMeta.canonicalImdbID(from:))
            self.tmdbId = tmdbId
        }

        /// The ids in `contentId` (`tt…` or `tmdb:…`) win over the metadata's.
        init(contentId: String, meta: NuvioMeta) {
            let id = PlexLibraryIndex.normalizedContentId(contentId)
            self.init(
                name: meta.name,
                year: meta.year ?? meta.releaseInfo.flatMap { Int($0.prefix(4)) },
                imdbId: id.lowercased().hasPrefix("tt") ? id : meta.imdbId,
                tmdbId: id.hasPrefix("tmdb:") ? Int(id.dropFirst(5)) : meta.tmdbId
            )
        }
    }

    /// One title search to send to the server.
    struct Search: Equatable {
        let title: String
        /// Only names equal to `title`, rather than names that contain it.
        var exact = false
        var year: Int? = nil
    }

    /// What a lookup found in one library.
    struct Found: Equatable {
        var titles: [PlexIndexedTitle] = []
        /// The account's watch state for each movie or episode found, by
        /// rating key, so playback resumes where Plex says.
        var states: [String: PlexWatchState] = [:]
    }

    /// Movies or shows in `library` that are `target`, each show with all its
    /// episodes. Tries `searches(name:year:)` in order and stops at the first
    /// one that finds a match.
    static func find(
        _ target: Target,
        in library: PlexLibrary,
        serverID: String,
        client: PlexClient
    ) async throws -> Found {
        let type: PlexClient.ItemType = library.type == "movie" ? .movie : .show
        var refusal: Error?
        for search in searches(name: target.name, year: target.year) {
            try Task.checkCancellation()
            let candidates: [PlexMediaItem]
            do {
                candidates = try await client.search(
                    libraryID: library.id, type: type, title: search.title, exact: search.exact, year: search.year
                )
            } catch let error as PlexClient.ClientError where !error.isUnauthorized {
                // A server that refuses one search, an exact name say, is
                // still asked the next one.
                refusal = error
                continue
            }
            let matched = candidates.filter { matches($0, target) }
            guard !matched.isEmpty else { continue }
            var found = Found()
            guard type == .show else {
                found.titles = PlexLibraryResolver.resolve(movies: matched, shows: [], episodes: [], serverID: serverID, library: library)
                for movie in matched { found.states[movie.ratingKey] = PlexWatchState(movie) }
                return found
            }
            for show in matched {
                let episodes = try await client.episodes(showRatingKey: show.ratingKey)
                found.titles += PlexLibraryResolver.resolve(movies: [], shows: [show], episodes: episodes, serverID: serverID, library: library)
                for episode in episodes { found.states[episode.ratingKey] = PlexWatchState(episode) }
            }
            return found
        }
        // Not found, but a search was refused: ask again next time.
        if let refusal { throw refusal }
        return Found()
    }

    /// The searches to try, in order: the exact name in any year, so a short
    /// name ("Up") isn't lost among the many that contain it; then names
    /// containing it in the title's year, and in any year, as NuvioDesktop's
    /// Plex lookup searches; last, the name before ":" or " - " in the
    /// title's year ("Mission: Impossible - Fallout" as "Mission").
    static func searches(name: String, year: Int?) -> [Search] {
        let whole = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        var result = [Search(title: whole, exact: true)]
        if let year { result.append(Search(title: whole, year: year)) }
        result.append(Search(title: whole))
        let heads = [":", " - "].compactMap { separator -> String? in
            guard let range = whole.range(of: separator) else { return nil }
            let head = whole[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return head.count >= 2 ? head : nil
        }
        if let head = heads.min(by: { $0.count < $1.count }), head != whole {
            result.append(Search(title: head, year: year))
        }
        return result
    }

    /// An id both sides have decides. Without one, the name (ignoring case,
    /// accents and punctuation) and the year, give or take one, must match.
    static func matches(_ item: PlexMediaItem, _ target: Target) -> Bool {
        if let imdb = target.imdbId, let itemImdb = item.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:)) {
            return imdb == itemImdb
        }
        if let tmdb = target.tmdbId, let itemTmdb = item.tmdbId {
            return tmdb == itemTmdb
        }
        guard let year = target.year, let itemYear = item.year, abs(year - itemYear) <= 1 else { return false }
        let name = comparable(target.name)
        return !name.isEmpty && comparable(item.title) == name
    }

    private static func comparable(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
