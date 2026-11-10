import Foundation

/// The calendar's "Anime from AniList" option: anime straight from AniList's broadcast schedule,
/// under AniList's titles, covers and episode numbers, at the exact time.
///
/// Which titles:
/// - the AniList titles Nuvio follows (manual follows, watched, Continue Watching), with their
///   later seasons, as a TMDB show brings all its seasons;
/// - the viewer's AniList list: Watching always, and the premieres (first episodes) of Planning
///   with "Premieres from Planning".
///
/// Anime the library has as a Cinemeta/TMDB title stay as they are (`covered`); AniList only adds
/// what is followed through AniList alone. An entry opens the AniList title, where its progress is.
///
/// Entries carry the negative AniList id as their `tmdbId`, so they never meet a TMDB show's.
struct CalendarAniList: Sendable {
    typealias Query = @Sendable (_ query: String, _ variables: [String: Any?], _ ttl: TimeInterval) async throws -> Data
    /// The viewer's AniList list: status per AniList id; nil when not logged in.
    typealias ListLoader = @Sendable () async -> [Int: String]?

    var query: Query
    var listIDs: ListLoader
    var includesPlanning: Bool
    var language: AniListSettings.TitleLanguage
    var timeZone: TimeZone = .current

    static let maxPages = 10
    /// Later seasons followed from a library title: S1 in the library, S3 airing.
    static let sequelSteps = 3
    static let mediaTTL: TimeInterval = 12 * 3600
    static let scheduleTTL: TimeInterval = 3600

    /// The option as set in `store`; nil when it is off (AniList titles then go to TMDB as before).
    static func live(in store: UserDefaults = ProfileSettings.current) -> CalendarAniList? {
        guard CalendarOptions.aniList(in: store) else { return nil }
        return CalendarAniList(
            query: { query, variables, ttl in
                try await AniListClient.shared.query(query, variables: variables, ttl: ttl, notesStatus: false)
            },
            listIDs: {
                guard let entries = await AniListAccount.entries(statuses: ["CURRENT", "REPEATING", "PLANNING", "PAUSED"]) else { return nil }
                var statuses: [Int: String] = [:]
                for entry in entries { statuses[entry.mediaId] = entry.status ?? "" }
                return statuses
            },
            includesPlanning: CalendarOptions.aniListPlanning(in: store),
            language: AniListSettings.titleLanguage
        )
    }

    /// The library titles this source takes from TMDB: AniList series.
    static func handles(_ item: CalendarItem) -> Bool {
        item.kind == .series && AniListMetaBuilder.isAniListID(item.id)
    }

    /// The key a followed AniList title is listed under, matching its entries' "series:<tmdbId>".
    static func followKey(mediaID: Int) -> String { "series:\(-mediaID)" }

    struct Found: Sendable {
        var entries: [CalendarEntry] = []
        /// Per followed library item ("anilist:21"): the key of the season whose episodes stand for it.
        var followKeys: [String: String] = [:]
        /// AniList didn't answer: nothing was added.
        var failed = false
    }

    func load(followed: [CalendarItem], covered: Set<Int>, first: CalendarDay, last: CalendarDay) async -> Found {
        let libraryIDs = followed.compactMap { AniListMetaBuilder.aniListID(from: $0.id) }
        let statuses = await listIDs() ?? [:]
        let watching = statuses.filter { $0.value == "CURRENT" || $0.value == "REPEATING" }.map { $0.key }
        // Planning brings premieres only, unless the title is followed anyway.
        let planning = includesPlanning ? statuses.filter { $0.value == "PLANNING" }.map { $0.key } : []
        let premieresOnly = Set(planning).subtracting(libraryIDs)
        let listed = watching + planning
        var found = Found()
        guard !libraryIDs.isEmpty || !listed.isEmpty else { return found }

        // 1. The titles and their later seasons. `origin`: which library title brought a season in.
        var origin: [Int: Int] = [:]
        for id in libraryIDs { origin[id] = id }
        var media: [Int: AniListMedia] = [:]
        var pending = Array(Set(libraryIDs + listed)).sorted()
        do {
            for step in 0...Self.sequelSteps where !pending.isEmpty {
                var next: [Int] = []
                for item in try await mediaInfo(ids: pending) {
                    media[item.id] = item
                    guard step < Self.sequelSteps, let from = origin[item.id] else { continue }
                    for sequel in Self.sequels(of: item) where media[sequel] == nil && origin[sequel] == nil {
                        origin[sequel] = from
                        next.append(sequel)
                    }
                }
                pending = next
            }
        } catch {
            found.failed = true
            return found
        }

        // 2. Their broadcasts in the period, for what isn't in the library as a Cinemeta title.
        let airing = media.values
            .filter { ($0.status == "RELEASING" || $0.status == "NOT_YET_RELEASED") && !Self.isCovered($0, by: covered) }
            .map(\.id)
        if !airing.isEmpty {
            let from = first.adding(days: -1).startDate(in: timeZone)
            let to = last.adding(days: 2).startDate(in: timeZone)
            do {
                let airings = try await schedule(mediaIds: airing, from: from, to: to)
                found.entries = Self.entries(
                    airings: airings.filter { !premieresOnly.contains($0.mediaId) || $0.episode == 1 },
                    media: media, language: language, timeZone: timeZone, first: first, last: last
                )
            } catch {
                found.failed = true
                return found
            }
        }

        // 3. Each followed title is listed under its first season with something on.
        let firstAiring = Dictionary(
            found.entries.map { (-$0.tmdbId, $0.date) },
            uniquingKeysWith: { min($0, $1) }
        )
        for item in followed {
            guard let id = AniListMetaBuilder.aniListID(from: item.id) else { continue }
            let seasons = origin.filter { $0.value == id }.map { $0.key }
            let shown = seasons
                .compactMap { season in firstAiring[season].map { (season, $0) } }
                .min { $0.1 < $1.1 }?.0
            found.followKeys[item.id] = Self.followKey(mediaID: shown ?? id)
        }
        return found
    }

    // MARK: Building

    /// Calendar entries for AniList broadcasts that fall on a local day of the period.
    static func entries(
        airings: [CalendarAnimeTimes.Airing],
        media: [Int: AniListMedia],
        language: AniListSettings.TitleLanguage,
        timeZone: TimeZone,
        first: CalendarDay,
        last: CalendarDay
    ) -> [CalendarEntry] {
        var seen = Set<String>()
        return airings.compactMap { airing -> CalendarEntry? in
            guard let item = media[airing.mediaId], let episode = airing.episode, episode > 0 else { return nil }
            let day = CalendarDay(date: airing.at, timeZone: timeZone)
            guard day >= first, day <= last else { return nil }
            let cover = item.coverImage?.extraLarge ?? item.coverImage?.large
            var entry = CalendarEntry(
                itemId: AniListMetaBuilder.metaID(item.id),
                itemType: "series",
                kind: .series,
                tmdbId: -item.id,
                title: AniListMetaBuilder.title(item.title, language: language),
                date: day,
                releaseKind: releaseKind(episode: episode, of: item),
                seasonNumber: 1,
                episodeNumber: episode,
                posterURL: cover.flatMap(URL.init(string:))
            )
            guard seen.insert(entry.id).inserted else { return nil }
            entry.isAnime = true
            entry.airTime = airing.at
            entry.airTimeSource = .anilist
            return entry
        }
    }

    /// The first episode is a premiere (of the series, or of a season when an earlier season
    /// exists), the last one of a known count the finale.
    static func releaseKind(episode: Int, of media: AniListMedia) -> CalendarReleaseKind {
        if episode == 1 {
            return AniListMetaBuilder.previousSeason(of: media) == nil ? .seriesPremiere : .seasonPremiere
        }
        if let total = media.episodes, total > 1, episode == total { return .seasonFinale }
        return .episode
    }

    /// Later seasons: SEQUEL relations that are series themselves (no films or specials).
    static func sequels(of media: AniListMedia) -> [Int] {
        (media.relations?.edges ?? []).compactMap { edge in
            guard edge.relationType == "SEQUEL", let node = edge.node, node.id != media.id,
                  node.type == nil || node.type == "ANIME", AniListMetaBuilder.isTab(node) else { return nil }
            return node.id
        }
    }

    /// In the library as a Cinemeta/TMDB title: the entry itself, or the season before it (a new
    /// season the offline tables don't know yet).
    static func isCovered(_ media: AniListMedia, by covered: Set<Int>) -> Bool {
        guard !covered.isEmpty else { return false }
        if covered.contains(media.id) { return true }
        return (media.relations?.edges ?? []).contains { edge in
            edge.relationType == "PREQUEL" && edge.node.map { covered.contains($0.id) } == true
        }
    }

    /// The AniList ids of the library's Cinemeta/TMDB series: the offline tables, and what
    /// `CalendarAnimeTimes` found on arm-server for them during this load.
    static func covered(
        shows: [(tmdb: Int, imdb: String?)],
        cache: CalendarAnimeTimes.AniListIdCache = .shared
    ) async -> Set<Int> {
        var ids = Set<Int>()
        for show in shows {
            ids.formUnion(await AniListOfflineMaps.shared.aniListIDs(tmdbTV: show.tmdb, imdb: show.imdb))
            ids.formUnion(await cache.get(show.tmdb) ?? [])
        }
        return ids
    }

    // MARK: AniList

    static let mediaQuery = """
    query ($page: Int, $ids: [Int]) {
      Page(page: $page, perPage: 50) {
        pageInfo { hasNextPage }
        media(id_in: $ids, type: ANIME) {
          id type format status episodes
          title { romaji english native }
          coverImage { extraLarge large }
          relations { edges { relationType node { id type format status startDate { year month day } } } }
        }
      }
    }
    """

    func mediaInfo(ids: [Int]) async throws -> [AniListMedia] {
        var result: [AniListMedia] = []
        for page in 1...Self.maxPages {
            let data = try await query(Self.mediaQuery, ["page": page, "ids": ids], Self.mediaTTL)
            let block = try JSONDecoder().decode(AniListPageResponse.self, from: data).data?.Page
            result += block?.media ?? []
            if block?.pageInfo?.hasNextPage != true { break }
        }
        return result
    }

    func schedule(mediaIds: [Int], from: Date, to: Date) async throws -> [CalendarAnimeTimes.Airing] {
        var result: [CalendarAnimeTimes.Airing] = []
        for page in 1...Self.maxPages {
            let variables: [String: Any?] = [
                "page": page,
                "ids": mediaIds.sorted(),
                "from": Int(from.timeIntervalSince1970) - 1,
                "to": Int(to.timeIntervalSince1970),
            ]
            let data = try await query(CalendarAnimeTimes.query, variables, Self.scheduleTTL)
            let block = try JSONDecoder().decode(CalendarAnimeTimes.ScheduleResponse.self, from: data).data?.Page
            for item in block?.airingSchedules ?? [] {
                result.append(CalendarAnimeTimes.Airing(
                    mediaId: item.mediaId, episode: item.episode,
                    at: Date(timeIntervalSince1970: TimeInterval(item.airingAt))
                ))
            }
            if block?.pageInfo?.hasNextPage != true { break }
        }
        return result
    }
}
