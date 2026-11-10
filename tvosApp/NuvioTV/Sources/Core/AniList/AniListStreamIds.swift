import Foundation

/// The ids an AniList title is asked by from add-ons that don't know `anilist:` ids (Settings →
/// AniList → "Ask Other Add-ons"):
///
/// 1. `kitsu:ID:episode`, `mal:ID:episode`, `anidb:ID:episode`: they keep a separate entry per
///    season, as AniList does, so the episode number stays as on AniList.
/// 2. `tt…:season:episode`: IMDb with Cinemeta's numbering, the one Stremio add-ons go by.
/// 3. `tmdb:ID:season:episode`: TMDB with TheTVDB's numbering.
///
/// And the other way (`cinemetaAlternatives`): a Cinemeta anime episode for add-ons that take
/// only anime ids.
///
/// The offline tables (Fribb, anibridge) answer first, in TheTVDB's numbering. Only what they
/// don't know is asked online: ani.zip for ids and TheTVDB numbers; for a season too new for any
/// of them, what it takes from the seasons before it (the IMDb id, and where it starts: the
/// Cinemeta episode released when it started on AniList); last, the episode's air day against
/// Cinemeta's episode list. Where Cinemeta numbers an episode otherwise than TheTVDB (IMDb runs
/// several cours as one season), Cinemeta's numbering is asked. An episode nothing places is not
/// asked by IMDb: no streams beat another episode's.
enum AniListStreamIds {
    private static let lock = NSLock()
    private static var known: [String: [String]] = [:]

    /// The ids to try, best first, for an add-on that doesn't take `videoId`. [] for ids that
    /// aren't AniList's, or with the setting off.
    static func alternatives(for videoId: String) async -> [String] {
        guard AniListSettings.asksOtherAddons else { return [] }
        return await ids(for: videoId)
    }

    /// The IMDb episode id (`tt…:season:episode`) of an AniList episode, for its ratings from the
    /// rating add-ons. nil for other ids, a film, or an episode nothing places.
    static func imdbEpisodeID(for videoId: String) async -> String? {
        guard AniListAccount.episodeNumber(in: videoId) != nil else { return nil }
        return await ids(for: videoId).first { $0.hasPrefix("tt") && $0.contains(":") }
    }

    private static func ids(for videoId: String) async -> [String] {
        guard AniListSettings.opensTitles, let entryID = AniListMetaBuilder.aniListID(from: videoId) else { return [] }
        if let cached = lock.withLock({ known[videoId] }) { return cached }
        let ids = await find(entryID: entryID, episode: AniListAccount.episodeNumber(in: videoId))
        if !ids.isEmpty { lock.withLock { known[videoId] = ids } }
        return ids
    }

    private static func find(entryID: Int, episode: Int?) async -> [String] {
        let maps = AniListOfflineMaps.shared
        let offline = await maps.entry(aniListID: entryID)
        var kitsu = offline?.kitsu
        var imdb = await maps.imdb(aniListID: entryID)
        // TheTVDB's numbering (`tvdb`: its show, for the lengths of its seasons), or Cinemeta's own.
        var numbering: (season: Int, episode: Int)? = nil
        var tvdb: Int? = offline?.tvdb ?? offline?.ranges?.first?.tvdb
        if let episode, let found = await maps.seasonEpisode(aniListID: entryID, episode: episode) {
            numbering = (found.season, found.episode)
            tvdb = found.tvdb
        }

        // Online, only for what the tables don't know.
        var airDay: String? = nil
        if kitsu == nil || imdb == nil || (episode != nil && numbering == nil) {
            let zip = await AniListService.aniZipMappings(entryID: entryID, finished: false)
            kitsu = kitsu ?? zip?.mappings?.kitsuID
            imdb = imdb ?? zip?.mappings?.imdbID
            if let episode, let zipEpisode = zip?.episodes?[String(episode)] {
                if numbering == nil, let season = zipEpisode.seasonNumber, let number = zipEpisode.episodeNumber {
                    numbering = (season, number)
                }
                airDay = zipEpisode.airDay
            }
        }

        var ids: [String] = []
        if let kitsu {
            ids.append(episode.map { "kitsu:\(kitsu):\($0)" } ?? "kitsu:\(kitsu)")
        }
        // MyAnimeList and AniDB keep a separate entry per season too: AniList's episode number.
        if let mal = await MALEpisodeRatings.malID(aniListID: entryID) {
            ids.append(episode.map { "mal:\(mal):\($0)" } ?? "mal:\(mal)")
        }
        if let anidb = offline?.anidb {
            ids.append(episode.map { "anidb:\(anidb):\($0)" } ?? "anidb:\(anidb)")
        }
        let tmdbShow = offline?.tmdbTV
        let tmdbMovie = offline?.tmdbMovie
        guard let episode else {
            // A film: its IMDb id, and TMDB's.
            if let imdb { ids.append(imdb) }
            if let tmdbMovie { ids.append("tmdb:\(tmdbMovie)") }
            return ids
        }

        // A season too new for the tables and ani.zip: what it takes from the seasons before it.
        if imdb == nil || numbering == nil, let earlier = await inherited(entryID: entryID) {
            if imdb == nil { imdb = earlier.imdb }
            if numbering == nil, imdb == earlier.imdb, let season = earlier.season {
                numbering = (season, earlier.episodesBefore + episode)
                tvdb = nil
            }
        }
        // TMDB by TheTVDB's season and episode (TMDB mostly numbers anime as TheTVDB does).
        var tmdb: [String] = []
        if let tmdbShow, let numbering, numbering.season > 0 {
            tmdb.append("tmdb:\(tmdbShow):\(numbering.season):\(numbering.episode)")
        }
        guard let imdb else { return ids + tmdb }

        let videos = await cinemetaVideos(imdb: imdb)
        if numbering == nil {
            // Last: the episode Cinemeta lists for the day it aired.
            if airDay == nil { airDay = await aniListAirDay(entryID: entryID, episode: episode) }
            if let airDay { numbering = Self.episode(in: videos, airDay: airDay) }
        } else if let current = numbering, current.season > 0, !videos.isEmpty,
                  !videos.contains(where: { $0.season == current.season && $0.episode == current.episode }) {
            // Cinemeta numbers it otherwise; Stremio add-ons go by Cinemeta.
            if airDay == nil { airDay = await aniListAirDay(entryID: entryID, episode: episode) }
            var lengths: [Int: Int] = [:]
            if let tvdb { lengths = await maps.seasonLengths(tvdb: tvdb) }
            numbering = cinemetaNumbering(current, videos: videos, airDay: airDay, tvdbLengths: lengths)
        }
        if let numbering {
            ids.append("\(imdb):\(numbering.season):\(numbering.episode)")
        }
        return ids + tmdb
    }

    // MARK: Cinemeta anime for anime add-ons

    /// The other way: a Cinemeta anime episode (`tt…:season:episode`, TheTVDB's numbering as the
    /// offline tables have it) for add-ons that take only anime ids: `anilist:`, `kitsu:`,
    /// `mal:`, `anidb:` with the entry's own episode number. A film by its entry alone. [] for
    /// anything the tables don't know as anime, or with the setting off.
    static func cinemetaAlternatives(for videoId: String) async -> [String] {
        guard AniListSettings.opensTitles, AniListSettings.asksOtherAddons else { return [] }
        let key = "cinemeta|" + videoId
        if let cached = lock.withLock({ known[key] }) { return cached }
        let maps = AniListOfflineMaps.shared
        let entryID: Int
        let episode: Int?
        if let parsed = MALEpisodeRatings.cinemetaEpisode(videoId) {
            guard let found = await maps.aniListEpisode(imdb: parsed.imdb, tmdbTV: nil, season: parsed.season, episode: parsed.episode),
                  found.episode > 0 else { return [] }
            entryID = found.aniListID
            episode = found.episode
        } else if videoId.hasPrefix("tt"), !videoId.contains(":"), let film = await maps.film(imdb: videoId, tmdbMovie: nil) {
            entryID = film
            episode = nil
        } else {
            return []
        }
        let offline = await maps.entry(aniListID: entryID)
        func id(_ prefix: String, _ value: Int?) -> String? {
            guard let value else { return nil }
            return episode.map { "\(prefix):\(value):\($0)" } ?? "\(prefix):\(value)"
        }
        let ids = [
            id("anilist", entryID),
            id("kitsu", offline?.kitsu),
            id("mal", offline?.mal),
            id("anidb", offline?.anidb),
        ].compactMap { $0 }
        lock.withLock { known[key] = ids }
        return ids
    }

    // MARK: New seasons

    /// What a season too new for the tables takes from the seasons before it (as the indexer does):
    /// `imdb`, and where it starts in Cinemeta: `season`, with `episodesBefore` of it before
    /// (0 for a new season, 13 for a Part 2 that continues a season). `season` nil = not placed.
    struct Inherited: Equatable {
        let imdb: String
        let season: Int?
        let episodesBefore: Int
    }

    private static var inheritedKnown: [Int: Inherited] = [:]
    private static var tmdbKnown: [Int: String] = [:]

    /// - The IMDb id: the nearest earlier season's (TV, TV_SHORT or ONA, up to five steps back)
    ///   that the tables or ani.zip know, unless the tables put this entry on another TheTVDB show
    ///   than that season (a restart: its own show, whose IMDb id comes from TMDB).
    /// - The start: the Cinemeta episode released within three days of the entry's start on AniList.
    static func inherited(entryID: Int) async -> Inherited? {
        if let cached = lock.withLock({ inheritedKnown[entryID] }) { return cached }
        // Only a series' season (TV, TV_SHORT, ONA): a film or a special isn't the show.
        guard let media = await AniListService.prequels(of: entryID), AniListMetaBuilder.isTab(media) else { return nil }
        let maps = AniListOfflineMaps.shared
        let own = await maps.entry(aniListID: entryID)
        let ownTVDB = own?.tvdb ?? own?.ranges?.first?.tvdb

        var current = media
        var earlier: (imdb: String?, tvdb: Int?)? = nil
        for _ in 0..<5 {
            guard let previous = AniListMetaBuilder.previousSeason(of: current) else { break }
            let entry = await maps.entry(aniListID: previous)
            var imdb = await maps.imdb(aniListID: previous)
            if imdb == nil { imdb = await AniListService.aniZipMappings(entryID: previous, finished: true)?.mappings?.imdbID }
            let tvdb = entry?.tvdb ?? entry?.ranges?.first?.tvdb
            if imdb != nil || tvdb != nil {
                earlier = (imdb, tvdb)
                break
            }
            guard let next = await AniListService.prequels(of: previous) else { break }
            current = next
        }

        var imdb: String? = nil
        if let ownTVDB, let earlierTVDB = earlier?.tvdb, ownTVDB != earlierTVDB {
            imdb = await tmdbIMDb(tvdb: ownTVDB)
        } else if let earlier {
            imdb = earlier.imdb
            if imdb == nil, let show = ownTVDB ?? earlier.tvdb { imdb = await tmdbIMDb(tvdb: show) }
        } else if let ownTVDB {
            imdb = await tmdbIMDb(tvdb: ownTVDB)
        }
        guard let imdb else { return nil }

        var start: (season: Int, episode: Int)? = nil
        if let day = isoDay(media.startDate) {
            start = startEpisode(in: await cinemetaVideos(imdb: imdb), startDay: day)
        }
        let found = Inherited(imdb: imdb, season: start?.season, episodesBefore: max(0, (start?.episode ?? 1) - 1))
        // Not placed yet (Cinemeta doesn't list it yet): asked again next time.
        if start != nil { lock.withLock { inheritedKnown[entryID] = found } }
        return found
    }

    /// "2026-09-24" for a whole AniList date.
    static func isoDay(_ date: AniListDate?) -> String? {
        guard let year = date?.year, let month = date?.month, let day = date?.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The Cinemeta episode released within three days of `startDay`, the closest first, then the
    /// lower season and episode: where a season starts on Cinemeta.
    static func startEpisode(in videos: [CinemetaSeries.Video], startDay: String) -> (season: Int, episode: Int)? {
        let near = videos.compactMap { video -> (gap: Int, season: Int, episode: Int)? in
            guard let season = video.season, season > 0, let number = video.episode,
                  let day = AniListMatcher.day(of: video.released),
                  let gap = AniListMatcher.daysBetween(startDay, day), abs(gap) <= 3 else { return nil }
            return (abs(gap), season, number)
        }
        guard let best = near.min(by: { ($0.gap, $0.season, $0.episode) < ($1.gap, $1.season, $1.episode) }) else { return nil }
        return (best.season, best.episode)
    }

    /// The IMDb id TMDB has for TheTVDB show `tvdb`, with TMDB set up in Settings.
    private static func tmdbIMDb(tvdb: Int) async -> String? {
        if let cached = lock.withLock({ tmdbKnown[tvdb] }) { return cached }
        guard CalendarLibrarySource.isTmdbConfigured else { return nil }
        let client = CalendarLibrarySource.makeClient()
        guard let show = try? await client.tvId(forTvdb: tvdb),
              let imdb = try? await client.imdbId(tmdbId: show, kind: .series) else { return nil }
        lock.withLock { tmdbKnown[tvdb] = imdb }
        return imdb
    }

    // MARK: Cinemeta

    /// The day AniList's broadcast schedule gives an episode.
    private static func aniListAirDay(entryID: Int, episode: Int) async -> String? {
        guard let media = await AniListMatcher.franchise(ids: [entryID]).first(where: { $0.id == entryID }),
              let node = media.airingSchedule?.nodes?.first(where: { $0.episode == episode }) else { return nil }
        return AniListMatcher.utcDay(of: node.airingAt)
    }

    /// Cinemeta's episodes of IMDb series `imdb` (kept six hours); [] when it can't be read.
    static func cinemetaVideos(imdb: String) async -> [CinemetaSeries.Video] {
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/series/\(imdb).json"),
              let data = try? await AniListClient.shared.get(url, ttl: 6 * 3600),
              let response = try? JSONDecoder().decode(CinemetaSeries.self, from: data) else { return [] }
        return response.meta?.videos ?? []
    }

    /// Cinemeta's season and episode that aired on `airDay` (a day either way, for time zones),
    /// when exactly one did.
    static func cinemetaEpisode(imdb: String, airDay: String) async -> (season: Int, episode: Int)? {
        episode(in: await cinemetaVideos(imdb: imdb), airDay: airDay)
    }

    static func episode(in videos: [CinemetaSeries.Video], airDay: String) -> (season: Int, episode: Int)? {
        for distance in 0...1 {
            let matches = videos.filter { video in
                guard let season = video.season, season > 0, video.episode != nil,
                      let day = AniListMatcher.day(of: video.released),
                      let gap = AniListMatcher.daysBetween(airDay, day) else { return false }
                return abs(gap) == distance
            }
            if matches.count == 1, let season = matches[0].season, let number = matches[0].episode {
                return (season, number)
            }
            if matches.count > 1 { return nil }
        }
        return nil
    }

    /// An episode numbered by TheTVDB as Cinemeta numbers it, which Stremio add-ons go by:
    /// - as it is when Cinemeta lists it (or lists nothing);
    /// - else the episode Cinemeta lists for the day it aired;
    /// - else, when Cinemeta has no such season at all (IMDb runs several cours as one season:
    ///   Seihantai's TheTVDB S2E13 is Cinemeta's S1E25), the same place counted through Cinemeta's
    ///   seasons, from TheTVDB's season lengths;
    /// - else as it is.
    static func cinemetaNumbering(
        _ numbering: (season: Int, episode: Int),
        videos: [CinemetaSeries.Video],
        airDay: String?,
        tvdbLengths: [Int: Int]
    ) -> (season: Int, episode: Int) {
        let regular = videos.filter { ($0.season ?? 0) > 0 && $0.episode != nil }
        guard numbering.season > 0, !regular.isEmpty,
              !regular.contains(where: { $0.season == numbering.season && $0.episode == numbering.episode }) else { return numbering }
        if let airDay, let found = episode(in: regular, airDay: airDay) { return found }
        guard !regular.contains(where: { $0.season == numbering.season }) else { return numbering }

        var place = numbering.episode
        for season in 1..<numbering.season {
            guard let length = tvdbLengths[season] else { return numbering }
            place += length
        }
        var lengths: [Int: Int] = [:]
        for video in regular {
            if let season = video.season, let number = video.episode { lengths[season] = max(lengths[season] ?? 0, number) }
        }
        var before = 0
        for season in lengths.keys.sorted() {
            let length = lengths[season] ?? 0
            if place <= before + length { return (season, place - before) }
            before += length
        }
        return numbering
    }

    struct CinemetaSeries: Decodable {
        struct Meta: Decodable {
            let videos: [Video]?
        }
        struct Video: Decodable {
            let season: Int?
            let episode: Int?
            let released: String?

            init(season: Int?, episode: Int?, released: String?) {
                self.season = season
                self.episode = episode
                self.released = released
            }

            enum CodingKeys: String, CodingKey { case season, episode, number, released }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                season = try? container.decode(Int.self, forKey: .season)
                episode = (try? container.decode(Int.self, forKey: .episode)) ?? (try? container.decode(Int.self, forKey: .number))
                released = try? container.decode(String.self, forKey: .released)
            }
        }
        let meta: Meta?
    }

    /// Which id add-on `manifest` is asked by for `resource`: `videoId` when it takes it, else the
    /// first alternative it does. nil = it takes none.
    static func requestID(
        for manifest: StreamAddonManifest,
        resource: String,
        type: String,
        videoId: String,
        alternatives: [String]
    ) -> String? {
        if manifest.supportsResource(resource, type: type, id: videoId) { return videoId }
        return alternatives.first { manifest.supportsResource(resource, type: type, id: $0) }
    }

    /// For tests.
    static func forget() {
        lock.withLock {
            known.removeAll()
            inheritedKnown.removeAll()
            tmdbKnown.removeAll()
        }
    }
}
