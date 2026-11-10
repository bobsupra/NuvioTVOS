import Foundation

enum CalendarLoadError: Error, Equatable, Sendable {
    case tmdbNotConfigured
    case invalidApiKey
}

/// Loads the calendar for manual follows and automatic watch sources.
///
/// Read-only: it never changes follows, watched state or sync. A failure
/// for one title is recorded as skipped and does not stop the others; only a
/// missing or rejected TMDB key fails the whole load. Titles with nothing in
/// the period are simply absent.
struct CalendarService: Sendable {
    typealias IdResolver = @Sendable (CalendarItem) async -> Int?

    let client: CalendarTmdb.Client
    let resolveTmdbId: IdResolver
    var maxConcurrent: Int
    var region: String
    /// Broadcast times for anime (AniList); nil leaves TMDB dates as they are.
    var animeTimes: CalendarAnimeTimes?
    /// Anime straight from AniList (calendar option); nil leaves AniList titles to TMDB.
    var aniList: CalendarAniList?

    init(client: CalendarTmdb.Client, maxConcurrent: Int = 6, region: String,
         animeTimes: CalendarAnimeTimes? = nil, aniList: CalendarAniList? = nil,
         resolveTmdbId: @escaping IdResolver) {
        self.client = client
        self.resolveTmdbId = resolveTmdbId
        self.maxConcurrent = max(1, maxConcurrent)
        self.region = region
        self.animeTimes = animeTimes
        self.aniList = aniList
    }

    enum Outcome: Sendable {
        case entries([CalendarEntry], resolvedItem: CalendarItem)
        case skipped(CalendarSkipReason)
        case authFailure
    }

    func load(
        items: [CalendarItem],
        first: CalendarDay,
        last: CalendarDay,
        manualFollowItemIDs: Set<String>? = nil,
        automaticFollowItemIDs: Set<String> = []
    ) async throws -> CalendarResult {
        guard !client.apiKey.isEmpty else { throw CalendarLoadError.tmdbNotConfigured }

        // AniList series go to AniList itself when that option is on, not to TMDB.
        // Movies released more than a year before the period cannot have a
        // release inside it; don't spend a request on each of them.
        let (aniListFollows, items) = (
            aniList == nil ? [] : items.filter(CalendarAniList.handles),
            items.filter { item in
                if aniList != nil, CalendarAniList.handles(item) { return false }
                guard item.kind == .movie, let year = item.year else { return true }
                return year >= first.year - 1
            }
        )

        // 1. Resolve ids, then drop duplicates (the same title saved twice
        //    under different ids).
        let resolutions = await concurrentMap(items) { item in
            (item, await resolveTmdbId(item))
        }

        var skipped: [CalendarSkippedItem] = []
        var targets: [(item: CalendarItem, tmdbId: Int, key: String)] = []
        var seenTargets = Set<String>()
        var manualFollowKeys = Set<String>()
        var manualFollowItems: [String: CalendarItem] = [:]
        var automaticFollowItems: [String: CalendarItem] = [:]
        for (item, tmdbId) in resolutions {
            let isManualFollow = manualFollowItemIDs?.contains(item.sourceIdentityKey) ?? true
            let isAutomaticFollow = automaticFollowItemIDs.contains(item.sourceIdentityKey)
            guard let tmdbId else {
                if isManualFollow {
                    skipped.append(CalendarSkippedItem(item: item, reason: .unsupportedId))
                }
                continue
            }
            let key = "\(item.kind.rawValue):\(tmdbId)"
            if seenTargets.insert(key).inserted {
                targets.append((item, tmdbId, key))
            }
            if isManualFollow {
                manualFollowKeys.insert(key)
                if manualFollowItems[key] == nil { manualFollowItems[key] = item }
            }
            if isAutomaticFollow, automaticFollowItems[key] == nil {
                automaticFollowItems[key] = item
            }
        }

        // 2. Fetch episodes / releases inside the period.
        let outcomes = await concurrentMap(targets) { target in
            (target, await fetch(item: target.item, tmdbId: target.tmdbId, first: first, last: last))
        }

        var entries: [CalendarEntry] = []
        for (target, outcome) in outcomes {
            switch outcome {
            case .entries(let found, let resolvedItem):
                entries.append(contentsOf: found)
                if manualFollowItems[target.key] != nil { manualFollowItems[target.key] = resolvedItem }
                if automaticFollowItems[target.key] != nil { automaticFollowItems[target.key] = resolvedItem }
            case .skipped(let reason):
                if manualFollowKeys.contains(target.key) {
                    skipped.append(CalendarSkippedItem(item: manualFollowItems[target.key] ?? target.item, reason: reason))
                }
            case .authFailure:
                throw CalendarLoadError.invalidApiKey
            }
        }

        if let animeTimes, entries.contains(where: \.isAnime) {
            var imdbByTmdb: [Int: String] = [:]
            for target in targets where target.item.kind == .series && target.item.id.hasPrefix("tt") {
                imdbByTmdb[target.tmdbId] = String(target.item.id.prefix { $0 != ":" })
            }
            entries = await animeTimes.apply(to: entries, imdbByTmdb: imdbByTmdb, first: first, last: last)
        }

        if let aniList {
            let shows = targets.filter { $0.item.kind == .series }.map { target in
                (tmdb: target.tmdbId, imdb: NuvioMeta.canonicalImdbID(from: target.item.imdbId ?? target.item.id))
            }
            let covered = await CalendarAniList.covered(shows: shows, cache: animeTimes?.cache ?? .shared)
            let found = await aniList.load(followed: aniListFollows, covered: covered, first: first, last: last)
            entries += found.entries
            for item in aniListFollows {
                let isManualFollow = manualFollowItemIDs?.contains(item.sourceIdentityKey) ?? true
                let isAutomaticFollow = automaticFollowItemIDs.contains(item.sourceIdentityKey)
                if found.failed {
                    if isManualFollow {
                        skipped.append(CalendarSkippedItem(item: item, reason: .failed("AniList didn't answer")))
                    }
                    continue
                }
                guard let key = found.followKeys[item.id] else { continue }
                if isManualFollow {
                    manualFollowKeys.insert(key)
                    if manualFollowItems[key] == nil { manualFollowItems[key] = item }
                }
                if isAutomaticFollow, automaticFollowItems[key] == nil {
                    automaticFollowItems[key] = item
                }
            }
        }

        return CalendarResult(
            firstDay: first,
            lastDay: last,
            days: CalendarBuilder.groupByDay(entries),
            skipped: skipped,
            manualFollowKeys: manualFollowKeys,
            manualFollowItems: manualFollowItems,
            automaticFollowItems: automaticFollowItems
        )
    }

    func fetch(item: CalendarItem, tmdbId: Int, first: CalendarDay, last: CalendarDay) async -> Outcome {
        do {
            switch item.kind {
            case .series:
                let details = try await client.tvDetails(tmdbId)
                let resolvedItem = self.item(
                    filling: item,
                    tmdbId: tmdbId,
                    name: details.readableName ?? details.name,
                    posterPath: details.posterPath
                )
                let seasons = CalendarBuilder.seasonsToFetch(for: details, first: first, last: last)
                var episodes: [CalendarTmdb.Episode] = []
                for number in seasons {
                    do {
                        episodes += try await client.season(tmdbId, number: number).episodes ?? []
                    } catch {
                        if Self.isAuthError(error) { return .authFailure }
                        // A missing season page should not hide the rest;
                        // fall back to the episodes the show page names.
                        for known in [details.lastEpisodeToAir, details.nextEpisodeToAir].compactMap({ $0 })
                        where known.seasonNumber == number {
                            episodes.append(known)
                        }
                    }
                }
                return .entries(
                    CalendarBuilder.episodeEntries(
                        item: resolvedItem, details: details, episodes: episodes, first: first, last: last
                    ),
                    resolvedItem: resolvedItem
                )
            case .movie:
                let details = try await client.movieDetails(tmdbId)
                let resolvedItem = self.item(
                    filling: item,
                    tmdbId: tmdbId,
                    name: details.title,
                    posterPath: details.posterPath
                )
                return .entries(
                    CalendarBuilder.movieEntries(
                        item: resolvedItem, details: details, region: region, first: first, last: last
                    ),
                    resolvedItem: resolvedItem
                )
            }
        } catch {
            if Self.isAuthError(error) { return .authFailure }
            return .skipped(.failed(Self.describe(error)))
        }
    }

    private func item(filling item: CalendarItem, tmdbId: Int, name: String?, posterPath: String?) -> CalendarItem {
        let existingName = CalendarText.readableLibraryTitle(item.name)
        return CalendarItem(
            id: item.id,
            kind: item.kind,
            type: item.type,
            name: existingName ?? name,
            posterURL: item.posterURL ?? CalendarTmdb.imageURL(posterPath, size: "w342")?.absoluteString,
            year: item.year,
            imdbId: item.imdbId,
            tmdbId: item.tmdbId ?? tmdbId
        )
    }

    /// Runs `transform` over `input` with at most `maxConcurrent` calls in
    /// flight, keeping the input order.
    func concurrentMap<T: Sendable, R: Sendable>(_ input: [T], _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
        guard !input.isEmpty else { return [] }
        var results = [R?](repeating: nil, count: input.count)
        await withTaskGroup(of: (Int, R).self) { group in
            var next = 0
            while next < min(maxConcurrent, input.count) {
                let index = next
                group.addTask { (index, await transform(input[index])) }
                next += 1
            }
            while let finished = await group.next() {
                results[finished.0] = finished.1
                if next < input.count {
                    let index = next
                    group.addTask { (index, await transform(input[index])) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    static func isAuthError(_ error: Error) -> Bool {
        guard let tmdb = error as? CalendarTmdbError else { return false }
        return tmdb == .unauthorized || tmdb == .missingApiKey
    }

    static func describe(_ error: Error) -> String {
        if let tmdb = error as? CalendarTmdbError {
            switch tmdb {
            case .http(let code): return "HTTP \(code)"
            case .decoding: return "Invalid TMDB response"
            case .notFound: return "Not found on TMDB"
            case .unauthorized, .missingApiKey: return "TMDB key rejected"
            }
        }
        return error.localizedDescription
    }
}
