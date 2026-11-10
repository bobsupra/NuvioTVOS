import Foundation

/// Which AniList entry and episode an episode of a Cinemeta series (or a Cinemeta film) is,
/// found the way the calendar finds broadcast times, with nothing downloaded ahead:
///
/// 0. The offline tables (Fribb, anibridge) first, with no request at all.
/// 1. arm-server turns the title's TMDB or IMDb id into the AniList entries of the show. No
///    answer from arm means it isn't anime, and nothing is written.
/// 2. Entries newer than arm knows (its ids come from a database that stopped in 2026) are
///    found through AniList's sequel relations.
/// 3. The episode is matched by its air date, the same on IMDb, TMDB and AniList whatever
///    their numbering: against ani.zip's air days, else AniList's broadcast schedule.
/// 4. Without dates, by TheTVDB's season and episode numbers that ani.zip gives each AniList
///    episode.
///
/// Titles are never looked up by name. An episode that matches two ways is left alone.
enum AniListMatcher {
    struct Match: Equatable {
        let entryID: Int
        let episode: Int
        let entryTitle: String
    }

    /// One AniList episode a Cinemeta episode might be.
    struct Candidate: Equatable {
        let entryID: Int
        let episode: Int
        let airDay: String?
        let tvdbSeason: Int?
        let tvdbEpisode: Int?
    }

    static let armTTL: TimeInterval = 7 * 24 * 3600
    static let franchiseTTL: TimeInterval = 7 * 24 * 3600
    /// Formats Cinemeta lists as seasons of a series.
    static let seriesFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]

    private static let lock = NSLock()
    private static var matches: [String: Match] = [:]

    static func match(meta: NuvioMeta, season: Int?, episode: Int?, released: String?, videoID: String? = nil) async -> Match? {
        let key = "\(meta.id)|\(season ?? -1)|\(episode ?? -1)"
        if let known = lock.withLock({ matches[key] }) { return known }
        guard let found = await findMatch(meta: meta, season: season, episode: episode, released: released, videoID: videoID) else { return nil }
        lock.withLock { matches[key] = found }
        return found
    }

    private static func findMatch(meta: NuvioMeta, season: Int?, episode: Int?, released: String?, videoID: String?) async -> Match? {
        let imdb = NuvioMeta.canonicalImdbID(from: meta.imdbId ?? "") ?? NuvioMeta.canonicalImdbID(from: meta.id)
        if let found = await offlineMatch(meta: meta, imdb: imdb, season: season, episode: episode, videoID: videoID) {
            return found
        }
        guard let known = await armEntries(imdbID: imdb, tmdbID: meta.tmdbId), !known.isEmpty else { return nil }
        let language = AniListSettings.titleLanguage

        if !meta.isSeries {
            // A film: the one AniList film arm names.
            let entries = await franchise(ids: known)
            guard let film = entries.first(where: { $0.format == "MOVIE" }) ?? (entries.count == 1 ? entries.first : nil) else { return nil }
            return Match(entryID: film.id, episode: 1, entryTitle: AniListMetaBuilder.title(film.title, language: language))
        }
        guard let season, season > 0, let episode, episode > 0 else { return nil }

        let entries = await chain(startingWith: known)
        var candidates: [Candidate] = []
        for entry in entries {
            candidates += await Self.candidates(of: entry)
        }
        guard let picked = pick(from: candidates, airDay: day(of: released), season: season, episode: episode),
              let entry = entries.first(where: { $0.id == picked.entryID }) else { return nil }
        return Match(entryID: picked.entryID, episode: picked.episode, entryTitle: AniListMetaBuilder.title(entry.title, language: language))
    }

    /// From the offline tables, with no request: a film by its IMDb or TMDB id; an episode by
    /// TheTVDB's numbering, which Cinemeta follows. Only when the episode's own id is Cinemeta's
    /// `tt…:season:episode` with the same numbers: with TMDB's episode list shown instead, the
    /// numbers may be TMDB's, and the air-day match below sorts those out.
    private static func offlineMatch(meta: NuvioMeta, imdb: String?, season: Int?, episode: Int?, videoID: String?) async -> Match? {
        if !meta.isSeries {
            guard let id = await AniListOfflineMaps.shared.film(imdb: imdb, tmdbMovie: meta.tmdbId) else { return nil }
            return Match(entryID: id, episode: 1, entryTitle: meta.name)
        }
        guard let season, season >= 0, let episode, episode > 0, isCinemetaNumbering(videoID, season: season, episode: episode),
              let found = await AniListOfflineMaps.shared.aniListEpisode(imdb: imdb, tmdbTV: meta.tmdbId, season: season, episode: episode)
        else { return nil }
        return Match(entryID: found.aniListID, episode: found.episode, entryTitle: meta.name)
    }

    /// `tt…:season:episode` with these numbers.
    static func isCinemetaNumbering(_ videoID: String?, season: Int, episode: Int) -> Bool {
        guard let parts = videoID?.split(separator: ":"), parts.count == 3,
              NuvioMeta.canonicalImdbID(from: String(parts[0])) != nil else { return false }
        return Int(parts[1]) == season && Int(parts[2]) == episode
    }

    /// The AniList episode a Cinemeta episode is: the one that aired that day (a day either
    /// way, for time zones), else the one TheTVDB numbers the same. nil when none or several.
    static func pick(from candidates: [Candidate], airDay: String?, season: Int, episode: Int) -> Candidate? {
        let byNumber = candidates.filter { $0.tvdbSeason == season && $0.tvdbEpisode == episode }
        if let airDay {
            for distance in 0...1 {
                let sameDay = candidates.filter { candidate in
                    guard let other = candidate.airDay, let gap = daysBetween(airDay, other) else { return false }
                    return abs(gap) == distance
                }
                if sameDay.count == 1 { return sameDay[0] }
                if sameDay.count > 1 {
                    // Two episodes that day: TheTVDB's numbers tell them apart.
                    let both = sameDay.filter { byNumber.contains($0) }
                    return both.count == 1 ? both[0] : nil
                }
            }
        }
        return byNumber.count == 1 ? byNumber[0] : nil
    }

    // MARK: Sources

    /// arm-server's AniList ids for a TMDB or IMDb title: nil when arm didn't answer, [] when
    /// it knows nothing (not anime).
    static func armEntries(imdbID: String?, tmdbID: Int?) async -> [Int]? {
        var answered = false
        for (path, id) in [("themoviedb", tmdbID.map(String.init)), ("imdb", imdbID)] {
            guard let id, !id.isEmpty,
                  var components = URLComponents(string: "https://arm.haglund.dev/api/v2/\(path)") else { continue }
            components.queryItems = [URLQueryItem(name: "id", value: id)]
            guard let url = components.url else { continue }
            do {
                let data = try await AniListClient.shared.get(url, ttl: armTTL)
                answered = true
                let ids = CalendarAnimeTimes.parseArmIds(data)
                if !ids.isEmpty { return ids }
            } catch AniListClient.ClientError.badResponse(404) {
                answered = true
            } catch {
                continue
            }
        }
        return answered ? [] : nil
    }

    /// AniList entries by id, with their relations and schedules (kept a week).
    static func franchise(ids: [Int]) async -> [AniListMedia] {
        guard !ids.isEmpty else { return [] }
        let ids = Array(ids.prefix(50))
        guard let data = try? await AniListClient.shared.query(
            AniListQueries.franchise, variables: ["ids": ids, "perPage": ids.count], ttl: franchiseTTL
        ) else { return [] }
        return (try? JSONDecoder().decode(AniListPageResponse.self, from: data).data?.Page?.media) ?? []
    }

    /// The show's series entries in order of airing: the ones arm knows, and the sequels after
    /// them that it doesn't yet.
    static func chain(startingWith known: [Int]) async -> [AniListMedia] {
        var byID: [Int: AniListMedia] = [:]
        var pending = known
        var rounds = 0
        while !pending.isEmpty, rounds < 6 {
            rounds += 1
            for media in await franchise(ids: pending) {
                byID[media.id] = media
            }
            pending = byID.values.flatMap { media in
                (media.relations?.edges ?? []).compactMap { edge -> Int? in
                    guard edge.relationType == "SEQUEL", let node = edge.node,
                          node.type == nil || node.type == "ANIME",
                          node.format.map(seriesFormats.contains) ?? false,
                          byID[node.id] == nil else { return nil }
                    return node.id
                }
            }
            pending = Array(Set(pending)).sorted()
        }
        return byID.values
            .filter { $0.format.map(seriesFormats.contains) ?? false }
            .sorted { sortKey($0) < sortKey($1) }
    }

    /// Every episode of an entry with its air day and TheTVDB numbers: from ani.zip, the days
    /// AniList's schedule adds where ani.zip has none.
    static func candidates(of entry: AniListMedia) async -> [Candidate] {
        let aniZip = await AniListService.aniZipMappings(entryID: entry.id, finished: entry.status == "FINISHED")
        var scheduled: [Int: String] = [:]
        for node in entry.airingSchedule?.nodes ?? [] {
            scheduled[node.episode] = utcDay(of: node.airingAt)
        }
        var numbers = Set(scheduled.keys)
        for key in (aniZip?.episodes ?? [:]).keys {
            if let number = Int(key) { numbers.insert(number) }
        }
        if let total = entry.episodes, total > 0 {
            numbers.formUnion(1...total)
        }
        return numbers.sorted().map { number in
            let zip = aniZip?.episodes?[String(number)]
            return Candidate(
                entryID: entry.id,
                episode: number,
                airDay: zip?.airDay ?? scheduled[number],
                tvdbSeason: zip?.seasonNumber,
                tvdbEpisode: zip?.episodeNumber
            )
        }
    }

    // MARK: Days

    /// "yyyy-MM-dd" of an ISO date ("2016-01-14T00:00:00.000Z" or "2016-01-14").
    static func day(of iso: String?) -> String? {
        guard let iso = iso?.trimmingCharacters(in: .whitespacesAndNewlines), iso.count >= 10 else { return nil }
        let day = String(iso.prefix(10))
        return parse(day) == nil ? nil : day
    }

    static func daysBetween(_ first: String, _ second: String) -> Int? {
        guard let a = parse(first), let b = parse(second) else { return nil }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    static func utcDay(of seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private static func parse(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private static func sortKey(_ media: AniListMedia) -> Int {
        let date = media.startDate
        return (date?.year ?? 9999) * 10_000 + (date?.month ?? 12) * 100 + (date?.day ?? 31)
    }
}

/// Writes what the viewer watched to their AniList list: AniList titles by their own ids, and
/// (when turned on) anime from Cinemeta through `AniListMatcher`.
enum AniListScrobbler {
    struct Target: Equatable {
        let entryID: Int
        let episode: Int
        let label: String
    }

    /// The AniList entry and episode of what is playing or shown.
    static func target(meta: NuvioMeta, video: NuvioVideo?, season: Int?, episode: Int?) async -> Target? {
        if AniListMetaBuilder.isAniListID(meta.id) {
            if let video, let entryID = AniListMetaBuilder.aniListID(from: video.id),
               let number = AniListAccount.episodeNumber(in: video.id) {
                return Target(entryID: entryID, episode: number, label: "E\(number)")
            }
            if !meta.isSeries, let entryID = AniListMetaBuilder.aniListID(from: meta.id) {
                return Target(entryID: entryID, episode: 1, label: meta.name)
            }
            return nil
        }
        guard AniListSettings.scrobblesCinemeta || MALSettings.scrobbles else { return nil }
        guard let match = await AniListMatcher.match(
            meta: meta,
            season: video?.season ?? season,
            episode: video?.episode ?? episode,
            released: video?.released,
            videoID: video?.id
        ) else { return nil }
        return Target(entryID: match.entryID, episode: match.episode, label: "\(match.entryTitle) E\(match.episode)")
    }

    /// After an episode or film is watched to the end in the player.
    static func recordPlayback(meta: NuvioMeta, video: NuvioVideo?, season: Int?, episode: Int?) {
        guard AniListSettings.scrobbles || MALSettings.scrobbles else { return }
        Task.detached(priority: .utility) {
            guard let target = await target(meta: meta, video: video, season: season, episode: episode) else {
                if !AniListMetaBuilder.isAniListID(meta.id), AniListSettings.scrobblesCinemeta, meta.isAnime {
                    AniListDiagnostics.note(.account, "\(meta.name): not found on AniList, nothing written")
                }
                return
            }
            if AniListSettings.scrobbles {
                await AniListAccount.perform(.watched(episode: target.episode, byPlaying: true), entryID: target.entryID, reason: "Watched \(target.label)")
            }
            // And on MyAnimeList, when logged in there too.
            await MALAccount.watched(aniListID: target.entryID, episode: target.episode)
        }
    }

    /// An episode marked watched or unwatched in details ("up to" marks the same: AniList
    /// counts episodes, so everything before is watched too).
    static func markEpisode(meta: NuvioMeta, video: NuvioVideo, watched: Bool) {
        guard AniListSettings.scrobbles || MALSettings.scrobbles else { return }
        Task.detached(priority: .utility) {
            guard let target = await target(meta: meta, video: video, season: video.season, episode: video.episode) else { return }
            let action: AniListAccount.Action = watched
                ? .watched(episode: target.episode, byPlaying: false)
                : .unwatched(episode: target.episode)
            if AniListSettings.scrobbles {
                await AniListAccount.perform(action, entryID: target.entryID, reason: watched ? "Marked \(target.label) watched" : "Marked \(target.label) unwatched")
            }
            if watched {
                await MALAccount.watched(aniListID: target.entryID, episode: target.episode)
            } else {
                await MALAccount.unwatched(aniListID: target.entryID, episode: target.episode)
            }
        }
    }

    /// A whole season marked: each AniList entry in it goes to its last (or before its first)
    /// episode in that season.
    static func markSeason(meta: NuvioMeta, videos: [NuvioVideo], watched: Bool) {
        guard AniListSettings.scrobbles || MALSettings.scrobbles, !videos.isEmpty else { return }
        Task.detached(priority: .utility) {
            var byEntry: [Int: [Int]] = [:]
            for video in videos.sorted(by: { $0.episode < $1.episode }) {
                guard let target = await target(meta: meta, video: video, season: video.season, episode: video.episode) else { continue }
                byEntry[target.entryID, default: []].append(target.episode)
            }
            for (entryID, episodes) in byEntry {
                guard let first = episodes.min(), let last = episodes.max() else { continue }
                let action: AniListAccount.Action = watched
                    ? .watched(episode: last, byPlaying: false)
                    : .unwatched(episode: first)
                if AniListSettings.scrobbles {
                    await AniListAccount.perform(action, entryID: entryID, reason: watched ? "Marked a season watched" : "Marked a season unwatched")
                }
                if watched {
                    await MALAccount.watched(aniListID: entryID, episode: last)
                } else {
                    await MALAccount.unwatched(aniListID: entryID, episode: first)
                }
            }
        }
    }
}
