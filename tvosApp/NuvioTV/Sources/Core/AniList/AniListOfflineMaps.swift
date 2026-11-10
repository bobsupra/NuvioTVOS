import Foundation

/// Offline tables that turn AniList entries into other catalogues' ids and numbering on this Apple
/// TV, so most conversions need no request:
///
/// - Fribb's anime-lists (the mini file, the same data as the full one without its spacing): the
///   MAL, AniDB, Kitsu, IMDb, TMDB and TheTVDB ids of each AniList entry, with its default TheTVDB
///   season and episode offset.
/// - anibridge (generated daily): which TheTVDB season and episodes each AniList episode is, cours,
///   absolute numbering and specials included. Anime-Lists' hand-written rules for specials are in
///   it already.
///
/// Both come straight from GitHub (no server of Nuvio's own) and are refreshed weekly. From them one
/// small index is built and kept in the cache. tvOS may clear the cache; the tables are then
/// fetched again, and online sources (ani.zip, arm-server) stand in meanwhile.
actor AniListOfflineMaps {
    static let shared = AniListOfflineMaps()

    static let fribbURL = URL(string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-mini.json")!
    static let anibridgeURL = URL(string: "https://github.com/anibridge/anibridge-mappings/releases/download/v3/mappings.min.json")!
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// After a failed download, how long before trying again.
    static let retryAfter: TimeInterval = 6 * 3600
    /// 2: Fribb's episode offset is `{"tvdb": N, "tmdb": M}`, version 1 read it as nothing.
    static let formatVersion = 2

    /// What the tables know of one AniList entry.
    struct Entry: Codable, Equatable, Sendable {
        var mal: Int? = nil
        var anidb: Int? = nil
        var kitsu: Int? = nil
        var imdb: String? = nil
        var tmdbTV: Int? = nil
        var tmdbMovie: Int? = nil
        var tvdb: Int? = nil
        /// Fribb's default TheTVDB season and episode offset of the entry.
        var tvdbSeason: Int? = nil
        var episodeOffset: Int? = nil
        var type: String? = nil
        /// anibridge: AniList episodes → episodes of a TheTVDB season.
        var ranges: [EpisodeRange]? = nil

        enum CodingKeys: String, CodingKey {
            case mal = "m", anidb = "a", kitsu = "k", imdb = "i", tmdbTV = "t", tmdbMovie = "f"
            case tvdb = "v", tvdbSeason = "s", episodeOffset = "o", type = "y", ranges = "r"
        }

        var isFilm: Bool { type?.uppercased() == "MOVIE" }
    }

    /// AniList episodes `source` ("1-13", "14-", "542") are episodes `target` of TheTVDB season
    /// `season` ("1-13", "41-", "1-15,17-22").
    struct EpisodeRange: Codable, Equatable, Sendable {
        var tvdb: Int
        var season: Int
        var source: String
        var target: String

        enum CodingKeys: String, CodingKey { case tvdb = "v", season = "s", source = "a", target = "b" }
    }

    struct Index: Codable, Sendable {
        var version: Int
        var builtAt: Date
        var anibridgeGenerated: String?
        var entries: [Int: Entry]
    }

    /// TheTVDB's season and episode of an AniList episode, the numbering IMDb add-ons expect.
    struct SeasonEpisode: Equatable, Sendable {
        let tvdb: Int
        let season: Int
        let episode: Int
    }

    enum Status: Equatable, Sendable {
        case notLoaded
        case downloading
        case ready(titles: Int, builtAt: Date)
        case failed(String)
    }

    private let directory: URL
    private let session: URLSession
    private var index: Index?
    private var triedDisk = false
    private var refreshing: Task<Void, Never>?
    private var lastFailure: Date?
    private(set) var status: Status = .notLoaded
    private var byIMDb: [String: [Int]] = [:]
    private var byTMDBShow: [Int: [Int]] = [:]
    private var byTMDBMovie: [Int: [Int]] = [:]
    private var byTVDB: [Int: [Int]] = [:]
    private var byMAL: [Int: Int] = [:]

    init(directory: URL? = nil, session: URLSession = .shared) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? caches.appendingPathComponent("AniListOffline", isDirectory: true)
        self.session = session
    }

    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    // MARK: Lookups

    /// What the tables know of an AniList entry, or nil (not in them, or not downloaded yet; a
    /// download then starts in the background).
    func entry(aniListID: Int) async -> Entry? {
        await ready()?.entries[aniListID]
    }

    /// The AniList entry of a MyAnimeList one (MAL titles open as AniList titles).
    func aniListID(mal: Int) async -> Int? {
        guard await ready() != nil else { return nil }
        return byMAL[mal]
    }

    /// The IMDb id of an AniList entry: its own, else the one the other entries of its TheTVDB
    /// show carry (a new season the tables know only by TheTVDB's numbering: STEEL BALL RUN 2nd
    /// STAGE is season 6 of TheTVDB's JoJo, which IMDb has as one title).
    func imdb(aniListID: Int) async -> String? {
        guard let index = await ready(), let entry = index.entries[aniListID] else { return nil }
        if let imdb = entry.imdb { return imdb }
        guard !entry.isFilm else { return nil }
        var shows = Set(entry.ranges?.map(\.tvdb) ?? [])
        if let tvdb = entry.tvdb { shows.insert(tvdb) }
        var counts: [String: Int] = [:]
        for show in shows {
            for id in byTVDB[show] ?? [] where id != aniListID {
                guard let other = index.entries[id], !other.isFilm, let imdb = other.imdb else { continue }
                counts[imdb, default: 0] += 1
            }
        }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    /// TheTVDB's season and episode of episode `episode` of AniList entry `aniListID`: by
    /// anibridge's ranges, else by Fribb's default season and offset. nil when neither knows.
    ///
    /// Past the end of its ranges: when the entry is the last window of its show (the season still
    /// airing; anibridge lists the episodes known so far), the episode continues from that window.
    func seasonEpisode(aniListID: Int, episode: Int) async -> SeasonEpisode? {
        guard let index = await ready(), let entry = index.entries[aniListID] else { return nil }
        if let found = Self.seasonEpisode(of: entry, episode: episode) { return found }
        guard !entry.isFilm else { return nil }
        for tvdb in Set((entry.ranges ?? []).map(\.tvdb)).sorted() {
            if let found = Self.continuing(aniListID: aniListID, episode: episode, tvdb: tvdb, windows: windows(ofTVDB: tvdb, in: index)) {
                return found
            }
        }
        return nil
    }

    /// TheTVDB's regular seasons of `tvdb` and their lengths, where every window is closed.
    func seasonLengths(tvdb: Int) async -> [Int: Int] {
        guard let index = await ready() else { return [:] }
        return Self.seasonLengths(windows(ofTVDB: tvdb, in: index))
    }

    private func windows(ofTVDB tvdb: Int, in index: Index) -> [Window] {
        Self.windows(ofTVDB: tvdb, entries: (byTVDB[tvdb] ?? []).compactMap { id in index.entries[id].map { (id, $0) } })
    }

    /// The AniList entry and episode of TheTVDB season `season` episode `episode` of the show IMDb
    /// knows as `imdb` (or TMDB as `tmdbTV`). nil when the tables don't know it or two entries fit.
    func aniListEpisode(imdb: String?, tmdbTV: Int?, season: Int, episode: Int) async -> (aniListID: Int, episode: Int)? {
        guard let index = await ready() else { return nil }
        var shows = Set<Int>()
        for id in (imdb.map { byIMDb[$0] ?? [] } ?? []) + (tmdbTV.map { byTMDBShow[$0] ?? [] } ?? []) {
            if let tvdb = index.entries[id]?.tvdb { shows.insert(tvdb) }
            for range in index.entries[id]?.ranges ?? [] { shows.insert(range.tvdb) }
        }
        var found: [(Int, Int)] = []
        for tvdb in shows {
            for id in byTVDB[tvdb] ?? [] {
                guard let entry = index.entries[id] else { continue }
                if let number = Self.aniListEpisode(of: entry, tvdb: tvdb, season: season, episode: episode),
                   !found.contains(where: { $0 == (id, number) }) {
                    found.append((id, number))
                }
            }
        }
        if found.isEmpty {
            // Past the end of the season: the show's last, airing window, or IMDb's season of several cours.
            for tvdb in shows.sorted() {
                if let hit = Self.pastSeasonEnd(season: season, episode: episode, windows: windows(ofTVDB: tvdb, in: index)),
                   !found.contains(where: { $0 == (hit.aniListID, hit.episode) }) {
                    found.append((hit.aniListID, hit.episode))
                }
            }
        }
        guard found.count == 1 else { return nil }
        return (found[0].0, found[0].1)
    }

    /// The AniList film IMDb knows as `imdb` (or TMDB as `tmdbMovie`), when exactly one fits.
    func film(imdb: String?, tmdbMovie: Int?) async -> Int? {
        guard let index = await ready() else { return nil }
        var ids = Set<Int>()
        for id in (imdb.map { byIMDb[$0] ?? [] } ?? []) + (tmdbMovie.map { byTMDBMovie[$0] ?? [] } ?? []) {
            if index.entries[id]?.isFilm == true { ids.insert(id) }
        }
        return ids.count == 1 ? ids.first : nil
    }

    /// The AniList entries of a TMDB show, every season of it: for the calendar's broadcast times.
    func aniListIDs(tmdbTV: Int?, imdb: String?) async -> [Int] {
        guard await ready() != nil else { return [] }
        var ids = Set<Int>()
        if let tmdbTV { ids.formUnion(byTMDBShow[tmdbTV] ?? []) }
        if ids.isEmpty, let imdb { ids.formUnion(byIMDb[imdb] ?? []) }
        return ids.sorted()
    }

    // MARK: Loading

    /// The index: in memory, else from the cache, else nil while it is downloaded. A stale index
    /// is used while a fresh one is fetched.
    private func ready() async -> Index? {
        if index == nil, !triedDisk {
            triedDisk = true
            if let data = try? Data(contentsOf: indexFile),
               let saved = try? JSONDecoder().decode(Index.self, from: data),
               saved.version == Self.formatVersion {
                use(saved)
            }
        }
        refreshIfStale()
        return index
    }

    /// Starts a download when the tables are missing or a week old (and AniList is on).
    func refreshIfStale(force: Bool = false) {
        guard AniListSettings.needsOfflineTables, refreshing == nil else { return }
        if !force {
            if let index, Date().timeIntervalSince(index.builtAt) < Self.maxAge { return }
            if let lastFailure, Date().timeIntervalSince(lastFailure) < Self.retryAfter { return }
        }
        status = .downloading
        refreshing = Task { [weak self] in
            await self?.download()
        }
    }

    /// Waits for a download running now, for Settings' "Update".
    func refreshNow() async {
        if index == nil, !triedDisk { _ = await ready() }
        refreshIfStale(force: true)
        await refreshing?.value
    }

    private func download() async {
        defer { refreshing = nil }
        do {
            async let fribb = fetch(Self.fribbURL)
            async let anibridge = fetch(Self.anibridgeURL)
            let built = try Self.build(fribb: try await fribb, anibridge: try await anibridge)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(built).write(to: indexFile, options: .atomic)
            use(built)
            lastFailure = nil
        } catch {
            lastFailure = Date()
            status = index.map { .ready(titles: $0.entries.count, builtAt: $0.builtAt) } ?? .failed(error.localizedDescription)
        }
    }

    nonisolated private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AniListClient.ClientError.badResponse(code) }
        return data
    }

    private func use(_ built: Index) {
        index = built
        var imdb: [String: [Int]] = [:], shows: [Int: [Int]] = [:], movies: [Int: [Int]] = [:], tvdb: [Int: [Int]] = [:]
        var mal: [Int: Int] = [:]
        for (id, entry) in built.entries {
            if let value = entry.mal, mal[value].map({ id < $0 }) ?? true { mal[value] = id }
            if let value = entry.imdb { imdb[value, default: []].append(id) }
            if let value = entry.tmdbTV { shows[value, default: []].append(id) }
            if let value = entry.tmdbMovie { movies[value, default: []].append(id) }
            var tvdbShows = Set(entry.ranges?.map(\.tvdb) ?? [])
            if let value = entry.tvdb { tvdbShows.insert(value) }
            for show in tvdbShows { tvdb[show, default: []].append(id) }
        }
        byIMDb = imdb
        byTMDBShow = shows
        byTMDBMovie = movies
        byTVDB = tvdb
        byMAL = mal
        status = .ready(titles: built.entries.count, builtAt: built.builtAt)
    }

    // MARK: Building (static, for tests)

    enum BuildError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\(name) couldn't be read"
            }
        }
    }

    /// One index from Fribb's mini file and anibridge's mappings. Fribb's ids come first;
    /// anibridge fills what Fribb lacks (it is daily, so it knows newer entries) and adds the ranges.
    static func build(fribb: Data, anibridge: Data, now: Date = Date()) throws -> Index {
        guard let list = (try? JSONSerialization.jsonObject(with: fribb)) as? [[String: Any]] else {
            throw BuildError.unreadable("Fribb's anime-lists")
        }
        guard let mappings = (try? JSONSerialization.jsonObject(with: anibridge)) as? [String: Any] else {
            throw BuildError.unreadable("anibridge")
        }
        var entries: [Int: Entry] = [:]

        for item in list {
            guard let id = int(item["anilist_id"]), id > 0 else { continue }
            var entry = entries[id] ?? Entry()
            entry.mal = entry.mal ?? int(item["mal_id"])
            entry.anidb = entry.anidb ?? int(item["anidb_id"])
            entry.kitsu = entry.kitsu ?? int(item["kitsu_id"])
            entry.imdb = entry.imdb ?? imdbID(item["imdb_id"])
            if let tmdb = item["themoviedb_id"] as? [String: Any] {
                entry.tmdbTV = entry.tmdbTV ?? int(tmdb["tv"])
                entry.tmdbMovie = entry.tmdbMovie ?? int(tmdb["movie"])
            }
            entry.tvdb = entry.tvdb ?? int(item["tvdb_id"])
            if let season = item["season"] as? [String: Any] {
                entry.tvdbSeason = entry.tvdbSeason ?? int(season["tvdb"])
            }
            if let offsets = item["episode_offset"] as? [String: Any] {
                entry.episodeOffset = entry.episodeOffset ?? int(offsets["tvdb"])
            } else {
                entry.episodeOffset = entry.episodeOffset ?? int(item["episode_offset"])
            }
            entry.type = entry.type ?? (item["type"] as? String)
            entries[id] = entry
        }

        for (key, value) in mappings where key.hasPrefix("anilist:") {
            guard let id = Int(key.dropFirst("anilist:".count)), id > 0,
                  let targets = value as? [String: Any] else { continue }
            var entry = entries[id] ?? Entry()
            var ranges: [EpisodeRange] = []
            for (target, spans) in targets {
                let parts = target.split(separator: ":").map(String.init)
                guard parts.count >= 2 else { continue }
                switch parts[0] {
                case "tvdb_show":
                    guard let show = Int(parts[1]) else { continue }
                    entry.tvdb = entry.tvdb ?? show
                    guard parts.count >= 3, parts[2].hasPrefix("s"), let season = Int(parts[2].dropFirst()),
                          let spans = spans as? [String: Any] else { continue }
                    for (sourceSpec, targetSpec) in spans {
                        guard let targetText = targetSpec as? String else { continue }
                        ranges.append(EpisodeRange(tvdb: show, season: season, source: sourceSpec, target: targetText))
                    }
                case "mal": entry.mal = entry.mal ?? Int(parts[1])
                case "anidb": entry.anidb = entry.anidb ?? Int(parts[1])
                case "tmdb_show": entry.tmdbTV = entry.tmdbTV ?? Int(parts[1])
                case "tmdb_movie": entry.tmdbMovie = entry.tmdbMovie ?? Int(parts[1])
                case "imdb_movie": entry.imdb = entry.imdb ?? imdbID(parts[1])
                default: break
                }
            }
            if !ranges.isEmpty {
                // Regular seasons first, then by where in the season they start.
                entry.ranges = ranges.sorted {
                    let a = ($0.season == 0 ? Int.max : $0.season), b = ($1.season == 0 ? Int.max : $1.season)
                    return a != b ? a < b : (segments($0.target)?.first?.from ?? 0) < (segments($1.target)?.first?.from ?? 0)
                }
            }
            if entry.type == nil, targets.keys.contains(where: { $0.hasPrefix("tmdb_movie:") || $0.hasPrefix("imdb_movie:") || $0.hasPrefix("tvdb_movie:") }),
               !targets.keys.contains(where: { $0.hasPrefix("tvdb_show:") || $0.hasPrefix("tmdb_show:") }) {
                entry.type = "MOVIE"
            }
            entries[id] = entry
        }

        let generated = (mappings["$meta"] as? [String: Any])?["generated_on"] as? String
        return Index(version: formatVersion, builtAt: now, anibridgeGenerated: generated, entries: entries)
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func imdbID(_ value: Any?) -> String? {
        let candidates: [String]
        switch value {
        case let list as [String]: candidates = list
        case let list as [Any]: candidates = list.compactMap { $0 as? String }
        case let text as String: candidates = [text]
        default: candidates = []
        }
        for candidate in candidates {
            let id = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if id.hasPrefix("tt"), id.count > 2, id.dropFirst(2).allSatisfy(\.isNumber) { return id }
        }
        return nil
    }

    // MARK: Episode ranges (static, for tests)

    /// A run of episode numbers; `to` nil = open (still airing).
    struct Segment: Equatable {
        let from: Int
        let to: Int?
    }

    /// "1-13" / "41-" / "542" / "1-15,17-22". nil for a spec with a ratio ("1-102|-2": one AniList
    /// episode is two TheTVDB ones), whose single episodes can't be told apart.
    static func segments(_ spec: String) -> [Segment]? {
        guard !spec.contains("|") else { return nil }
        var result: [Segment] = []
        for part in spec.split(separator: ",") {
            let text = part.trimmingCharacters(in: .whitespaces)
            if let dash = text.firstIndex(of: "-") {
                guard let from = Int(text[..<dash]) else { return nil }
                let rest = text[text.index(after: dash)...]
                if rest.isEmpty {
                    result.append(Segment(from: from, to: nil))
                } else {
                    guard let to = Int(rest), to >= from else { return nil }
                    result.append(Segment(from: from, to: to))
                }
            } else {
                guard let single = Int(text) else { return nil }
                result.append(Segment(from: single, to: single))
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Where `number` is in the runs (0 = the first episode they list).
    static func position(of number: Int, in segments: [Segment]) -> Int? {
        var passed = 0
        for segment in segments {
            if number >= segment.from, segment.to.map({ number <= $0 }) ?? true {
                return passed + (number - segment.from)
            }
            guard let to = segment.to else { return nil }
            passed += to - segment.from + 1
        }
        return nil
    }

    /// The episode at `position` in the runs.
    static func number(at position: Int, in segments: [Segment]) -> Int? {
        var left = position
        for segment in segments {
            guard let to = segment.to else { return segment.from + left }
            let length = to - segment.from + 1
            if left < length { return segment.from + left }
            left -= length
        }
        return nil
    }

    /// TheTVDB season and episode of an AniList episode of `entry`.
    static func seasonEpisode(of entry: Entry, episode: Int) -> SeasonEpisode? {
        for range in entry.ranges ?? [] {
            guard let source = segments(range.source), let target = segments(range.target),
                  let at = position(of: episode, in: source),
                  let number = number(at: at, in: target) else { continue }
            return SeasonEpisode(tvdb: range.tvdb, season: range.season, episode: number)
        }
        // Without ranges: Fribb's default season, with its episode offset. Not for films.
        guard entry.ranges == nil, !entry.isFilm, let tvdb = entry.tvdb, let season = entry.tvdbSeason, season >= 0 else { return nil }
        return SeasonEpisode(tvdb: tvdb, season: season, episode: episode + (entry.episodeOffset ?? 0))
    }

    /// The AniList episode of `entry` that is TheTVDB season `season` episode `episode`.
    static func aniListEpisode(of entry: Entry, tvdb: Int, season: Int, episode: Int) -> Int? {
        if let ranges = entry.ranges {
            for range in ranges where range.tvdb == tvdb && range.season == season {
                guard let source = segments(range.source), let target = segments(range.target),
                      let at = position(of: episode, in: target),
                      let number = number(at: at, in: source) else { continue }
                return number
            }
            return nil
        }
        guard !entry.isFilm, entry.tvdb == tvdb, entry.tvdbSeason == season else { return nil }
        let number = episode - (entry.episodeOffset ?? 0)
        return number >= 1 ? number : nil
    }

    // MARK: Windows of a show (static, for tests)

    /// One AniList entry's episodes in one regular TheTVDB season: AniList's `source`, TheTVDB's `target`.
    struct Window: Equatable {
        let aniListID: Int
        let season: Int
        let source: [Segment]
        let target: [Segment]

        var targetFirst: Int { target.first?.from ?? 0 }
        /// nil = open (still airing, every later episode is in it).
        var targetLast: Int? { target.last?.to }
        var sourceLast: Int? { source.last?.to }
    }

    /// The windows of TheTVDB show `tvdb` in its regular seasons, by season and first episode.
    static func windows(ofTVDB tvdb: Int, entries: [(Int, Entry)]) -> [Window] {
        var result: [Window] = []
        for (id, entry) in entries {
            for range in entry.ranges ?? [] where range.tvdb == tvdb && range.season >= 1 {
                guard let source = segments(range.source), let target = segments(range.target) else { continue }
                result.append(Window(aniListID: id, season: range.season, source: source, target: target))
            }
        }
        return result.sorted { ($0.season, $0.targetFirst, $0.aniListID) < ($1.season, $1.targetFirst, $1.aniListID) }
    }

    /// Season → episodes, for the seasons whose windows are all closed.
    static func seasonLengths(_ windows: [Window]) -> [Int: Int] {
        var lengths: [Int: Int] = [:]
        for season in Set(windows.map(\.season)) {
            let ends = windows.filter { $0.season == season }.map(\.targetLast)
            guard !ends.contains(where: { $0 == nil }), let end = ends.compactMap({ $0 }).max() else { continue }
            lengths[season] = end
        }
        return lengths
    }

    /// AniList episode `episode` of entry `aniListID` past the end of its window, when that window is
    /// the show's last one (the season still airing): it continues from where the window ends
    /// (Yozakura 2nd Season Part 2: anibridge ends at S2E14, its next episode is S2E15).
    static func continuing(aniListID: Int, episode: Int, tvdb: Int, windows: [Window]) -> SeasonEpisode? {
        guard let last = windows.last, last.aniListID == aniListID,
              let sourceLast = last.sourceLast, let targetLast = last.targetLast, episode > sourceLast else { return nil }
        return SeasonEpisode(tvdb: tvdb, season: last.season, episode: targetLast + (episode - sourceLast))
    }

    /// The AniList entry and episode of TheTVDB `season` `episode`, past the season's last window:
    /// - the show's last window (the season still airing): that window's entry, continued;
    /// - a finished season (more windows follow): IMDb and Cinemeta run several cours as one season
    ///   (Seihantai tt36034547 S1E25 = TheTVDB S2E13 = the 2nd season's 13th episode), so the
    ///   episodes past its end are the next seasons'. From season 1 on through the later seasons;
    ///   from a later season only into the one right after (beyond that it is another numbering).
    static func pastSeasonEnd(season: Int, episode: Int, windows: [Window]) -> (aniListID: Int, episode: Int)? {
        guard season >= 1 else { return nil }
        let inSeason = windows.filter { $0.season == season }
        guard let lastInSeason = inSeason.last else { return nil }
        let lengths = seasonLengths(windows)
        guard let end = lengths[season], episode > end else { return nil }
        if lastInSeason == windows.last {
            guard let sourceLast = lastInSeason.sourceLast, let targetLast = lastInSeason.targetLast else { return nil }
            return (lastInSeason.aniListID, sourceLast + (episode - targetLast))
        }
        var left = episode - end
        let later = Array(Set(windows.map(\.season).filter { $0 > season })).sorted()
        for (step, next) in later.enumerated() {
            if season >= 2, step > 0 { return nil }
            let nextWindows = windows.filter { $0.season == next }
            for window in nextWindows {
                if let at = position(of: left, in: window.target), let number = number(at: at, in: window.source) {
                    return (window.aniListID, number)
                }
            }
            guard let nextEnd = lengths[next], left > nextEnd else { return nil }
            if let lastNext = nextWindows.last, lastNext == windows.last,
               let sourceLast = lastNext.sourceLast, let targetLast = lastNext.targetLast {
                return (lastNext.aniListID, sourceLast + (left - targetLast))
            }
            left -= nextEnd
        }
        return nil
    }

    // MARK: Settings

    /// "20,906 titles · updated 6 Nov, 20:40", for Settings.
    func statusText() async -> String {
        _ = await ready()
        switch status {
        case .notLoaded: return "Not downloaded yet"
        case .downloading: return index == nil ? "Downloading…" : "Updating…"
        case .ready(let titles, let builtAt):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let count = NumberFormatter.localizedString(from: NSNumber(value: titles), number: .decimal)
            return "\(count) titles · updated \(formatter.string(from: builtAt))"
        case .failed(let message): return "Couldn't download: \(message)"
        }
    }
}
