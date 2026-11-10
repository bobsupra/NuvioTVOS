import Foundation

/// Moves Japanese anime onto the local day they actually air and adds the
/// broadcast time. TMDB dates anime by the Japanese broadcast day, so late
/// night shows land a day late here.
///
/// TMDB/IMDb id → AniList ids via arm-server (all seasons of the show), then
/// one AniList query for the airing schedule of all of them. Episodes are
/// matched by date, not number: AniList numbers each cour on its own while
/// TMDB counts per season. Anything that doesn't match keeps its TMDB date.
struct CalendarAnimeTimes: Sendable {
    let http: CalendarAnimeHTTPClient
    var timeZone: TimeZone = .current
    var cache: AniListIdCache = .shared
    static let maxConcurrent = 4
    static let maxPages = 20

    init(http: CalendarAnimeHTTPClient = CalendarAnimeURLSessionClient(),
         timeZone: TimeZone = .current,
         cache: AniListIdCache = .shared) {
        self.http = http
        self.timeZone = timeZone
        self.cache = cache
    }

    /// AniList ids per TMDB show, kept for the app session.
    actor AniListIdCache {
        static let shared = AniListIdCache()
        private var values: [Int: [Int]] = [:]
        func get(_ tmdbId: Int) -> [Int]? { values[tmdbId] }
        func set(_ tmdbId: Int, _ ids: [Int]) { values[tmdbId] = ids }
    }

    struct Airing: Hashable, Sendable {
        let mediaId: Int
        let episode: Int?
        let at: Date
    }

    func apply(to entries: [CalendarEntry], imdbByTmdb: [Int: String], first: CalendarDay, last: CalendarDay) async -> [CalendarEntry] {
        let animeShows = Set(entries.filter { $0.isAnime && $0.kind == .series }.map(\.tmdbId))
        guard !animeShows.isEmpty else { return entries }

        let anilist = await anilistIds(for: Array(animeShows), imdbByTmdb: imdbByTmdb)
        var showByMedia: [Int: Int] = [:]
        for (tmdb, ids) in anilist {
            for id in ids where showByMedia[id] == nil { showByMedia[id] = tmdb }
        }
        guard !showByMedia.isEmpty else { return entries }

        // One day of margin on both sides of the period.
        let from = first.adding(days: -1).startDate(in: timeZone)
        let to = last.adding(days: 2).startDate(in: timeZone)
        guard let airings = try? await schedule(mediaIds: Array(showByMedia.keys), from: from, to: to) else {
            return entries
        }
        var byShow: [Int: [Airing]] = [:]
        for airing in airings {
            if let tmdb = showByMedia[airing.mediaId] { byShow[tmdb, default: []].append(airing) }
        }
        return Self.match(entries, airings: byShow, timeZone: timeZone)
    }

    /// For each anime episode take an unused airing of the same show on the
    /// TMDB day or the day before (Japan is ahead of Europe and America),
    /// preferring the same episode number, then the closer day.
    static func match(_ entries: [CalendarEntry], airings: [Int: [Airing]], timeZone: TimeZone) -> [CalendarEntry] {
        var used = Set<Airing>()
        var result = entries
        let order = result.indices
            .filter { result[$0].isAnime && airings[result[$0].tmdbId] != nil }
            .sorted { (result[$0].date, result[$0].episodeNumber ?? 0) < (result[$1].date, result[$1].episodeNumber ?? 0) }
        for index in order {
            let entry = result[index]
            let candidates = (airings[entry.tmdbId] ?? []).filter { airing in
                guard !used.contains(airing) else { return false }
                let local = CalendarDay(date: airing.at, timeZone: timeZone)
                return local == entry.date || local == entry.date.adding(days: -1)
            }
            let best = candidates.min { a, b in
                let aSame = a.episode == entry.episodeNumber
                let bSame = b.episode == entry.episodeNumber
                if aSame != bSame { return aSame }
                let aDay = CalendarDay(date: a.at, timeZone: timeZone) == entry.date
                let bDay = CalendarDay(date: b.at, timeZone: timeZone) == entry.date
                if aDay != bDay { return aDay }
                return a.at < b.at
            }
            guard let best else { continue }
            used.insert(best)
            result[index].date = CalendarDay(date: best.at, timeZone: timeZone)
            result[index].airTime = best.at
            result[index].airTimeSource = .anilist
        }
        return result
    }

    // MARK: - arm-server

    func anilistIds(for shows: [Int], imdbByTmdb: [Int: String]) async -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        var pending: [Int] = []
        for show in shows {
            if let cached = await cache.get(show) { result[show] = cached } else { pending.append(show) }
        }
        await withTaskGroup(of: (Int, [Int]?).self) { group in
            var index = 0
            while index < min(Self.maxConcurrent, pending.count) {
                let show = pending[index]
                let imdb = imdbByTmdb[show]
                group.addTask { (show, await lookup(tmdbId: show, imdbId: imdb)) }
                index += 1
            }
            while let pair = await group.next() {
                if let ids = pair.1 {
                    result[pair.0] = ids
                    await cache.set(pair.0, ids)
                }
                if index < pending.count {
                    let show = pending[index]
                    let imdb = imdbByTmdb[show]
                    group.addTask { (show, await lookup(tmdbId: show, imdbId: imdb)) }
                    index += 1
                }
            }
        }
        return result
    }

    /// The AniList offline tables first (no request; anibridge knows new seasons arm doesn't),
    /// then arm-server. nil = arm didn't answer (try again next load); [] = arm doesn't know it.
    func lookup(tmdbId: Int, imdbId: String?) async -> [Int]? {
        let offline = await AniListOfflineMaps.shared.aniListIDs(tmdbTV: tmdbId, imdb: imdbId.flatMap(NuvioMeta.canonicalImdbID(from:)))
        if !offline.isEmpty { return offline }
        let byTmdb = await armIds(path: "themoviedb", id: String(tmdbId))
        if let byTmdb, !byTmdb.isEmpty { return byTmdb }
        guard let imdbId, imdbId.hasPrefix("tt") else { return byTmdb }
        let byImdb = await armIds(path: "imdb", id: imdbId)
        if let byImdb { return byImdb }
        return byTmdb
    }

    private func armIds(path: String, id: String) async -> [Int]? {
        var components = URLComponents(string: "https://arm.haglund.dev/api/v2/\(path)")!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url,
              let response = try? await http.getWithoutRedirect(url, headers: ["Accept": "application/json"]) else {
            return nil
        }
        if response.1 == 404 { return [] }
        guard (200..<300).contains(response.1) else { return nil }
        return Self.parseArmIds(response.0)
    }

    /// AniList ids from an arm answer: an array of mapping objects (or one).
    static func parseArmIds(_ data: Data) -> [Int] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        let list: [[String: Any]]
        if let array = object as? [[String: Any]] {
            list = array
        } else if let single = object as? [String: Any] {
            list = [single]
        } else {
            return []
        }
        var seen = Set<Int>()
        return list.compactMap { $0["anilist"] as? Int }.filter { seen.insert($0).inserted }
    }

    // MARK: - AniList

    static let query = """
    query ($page: Int, $ids: [Int], $from: Int, $to: Int) {
      Page(page: $page, perPage: 50) {
        pageInfo { hasNextPage }
        airingSchedules(mediaId_in: $ids, airingAt_greater: $from, airingAt_lesser: $to, sort: TIME) {
          airingAt
          episode
          mediaId
        }
      }
    }
    """

    struct ScheduleResponse: Decodable {
        struct DataBlock: Decodable { let Page: PageBlock? }
        struct PageBlock: Decodable {
            let pageInfo: PageInfo?
            let airingSchedules: [Item]?
        }
        struct PageInfo: Decodable { let hasNextPage: Bool? }
        struct Item: Decodable {
            let airingAt: Int
            let episode: Int?
            let mediaId: Int
        }
        let data: DataBlock?
    }

    func schedule(mediaIds: [Int], from: Date, to: Date) async throws -> [Airing] {
        var result: [Airing] = []
        for page in 1...Self.maxPages {
            let variables: [String: Any] = [
                "page": page,
                "ids": mediaIds.sorted(),
                "from": Int(from.timeIntervalSince1970) - 1,
                "to": Int(to.timeIntervalSince1970),
            ]
            let body = try JSONSerialization.data(withJSONObject: ["query": Self.query, "variables": variables])
            let (data, status) = try await http.post(CalendarAnimeToday.AniList.endpoint, json: body)
            guard (200..<300).contains(status) else { throw CalendarTmdbError.http(status) }
            let decoded = try JSONDecoder().decode(ScheduleResponse.self, from: data)
            let block = decoded.data?.Page
            for item in block?.airingSchedules ?? [] {
                result.append(Airing(mediaId: item.mediaId, episode: item.episode,
                                     at: Date(timeIntervalSince1970: TimeInterval(item.airingAt))))
            }
            if block?.pageInfo?.hasNextPage != true { break }
        }
        return result
    }
}
