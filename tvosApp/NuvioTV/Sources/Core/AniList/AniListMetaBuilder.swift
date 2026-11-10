import Foundation

/// Turns AniList entries into Nuvio titles, keeping AniList's ids and episode numbers.
///
/// - A film (format MOVIE) is a movie with the id `anilist:ID`.
/// - Everything else is a series whose episodes have the ids `anilist:ENTRY:EP`, numbered as on
///   AniList, even when there is only one episode.
/// - With "One Title", the TV / TV short / ONA entries joined by AniList's prequel and sequel
///   relations become one series with a tab per entry, under the id of the first entry. The tab
///   is the episode's season number. Films, OVAs and specials stay titles of their own and show
///   in a Related row.
enum AniListMetaBuilder {
    static let idPrefix = "anilist:"
    static let ratingSource = "anilist"
    static let ratingIcon = "https://anilist.co/img/icons/android-chrome-512x512.png"

    /// Formats that become tabs of one series.
    static let tabFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]
    /// Relations shown in the Related row. Adaptations and sources are manga or novels.
    static let relatedTypes: [String] = [
        "PREQUEL", "SEQUEL", "PARENT", "SIDE_STORY", "SPIN_OFF", "ALTERNATIVE", "SUMMARY", "COMPILATION", "OTHER", "CHARACTER",
    ]

    // MARK: Ids

    static func metaID(_ id: Int) -> String { "\(idPrefix)\(id)" }

    static func episodeID(entry: Int, episode: Int) -> String { "\(idPrefix)\(entry):\(episode)" }

    /// The AniList id in `anilist:123`, `anilist:123:4` or `ANILIST:123`.
    static func aniListID(from id: String) -> Int? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(idPrefix) else { return nil }
        let rest = trimmed.dropFirst(idPrefix.count)
        guard let first = rest.split(separator: ":").first, let value = Int(first), value > 0 else { return nil }
        return value
    }

    static func isAniListID(_ id: String) -> Bool { aniListID(from: id) != nil }

    // MARK: Text

    static func title(_ title: AniListTitle?, language: AniListSettings.TitleLanguage) -> String {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let romaji = clean(title?.romaji)
        let english = clean(title?.english)
        let native = clean(title?.native)
        switch language {
        case .romaji: return romaji ?? english ?? native ?? "Unknown"
        case .english: return english ?? romaji ?? native ?? "Unknown"
        case .native: return native ?? romaji ?? english ?? "Unknown"
        }
    }

    /// AniList descriptions carry a little HTML (`<br>`, `<i>`) and entities.
    static func plainText(_ html: String?) -> String? {
        guard var text = html, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func formatLabel(_ format: String?) -> String? {
        switch format {
        case "TV": return "TV"
        case "TV_SHORT": return "TV Short"
        case "MOVIE": return "Movie"
        case "SPECIAL": return "Special"
        case "OVA": return "OVA"
        case "ONA": return "ONA"
        case "MUSIC": return "Music"
        default: return nil
        }
    }

    static func isMovie(_ media: AniListMedia) -> Bool { media.format == "MOVIE" }

    static func contentType(_ media: AniListMedia) -> String { isMovie(media) ? "movie" : "series" }

    static func isTab(_ media: AniListMedia) -> Bool { media.format.map { tabFormats.contains($0) } ?? false }

    static func year(_ media: AniListMedia) -> Int? { media.seasonYear ?? media.startDate?.year }

    static func isoDate(_ date: AniListDate?) -> String? {
        guard let year = date?.year else { return nil }
        return String(format: "%04d-%02d-%02dT00:00:00Z", year, date?.month ?? 1, date?.day ?? 1)
    }

    static func isoDate(airingAt: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(airingAt)))
    }

    static func status(_ status: String?) -> String? {
        switch status {
        case "RELEASING": return "Continuing"
        case "FINISHED": return "Ended"
        case "NOT_YET_RELEASED": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return nil
        }
    }

    // MARK: Cards

    /// A title card for Home, Search and See All.
    static func card(_ media: AniListMedia, language: AniListSettings.TitleLanguage) -> NuvioMeta {
        NuvioMeta(
            id: metaID(media.id),
            name: title(media.title, language: language),
            description: plainText(media.description),
            posterUrl: media.coverImage?.extraLarge ?? media.coverImage?.large,
            backgroundUrl: media.bannerImage,
            type: contentType(media),
            year: year(media),
            genres: media.genres,
            releaseInfo: year(media).map { String($0) },
            country: media.countryOfOrigin,
            language: "ja",
            status: status(media.status),
            trailerYtIds: youTubeTrailer(media).map { [$0] },
            externalRatings: rating(media).map { [$0] }
        )
    }

    /// An entry's trailer when it is on YouTube, which Nuvio plays; Dailymotion's are left out.
    static func youTubeTrailer(_ media: AniListMedia) -> String? {
        guard media.trailer?.site?.lowercased() == "youtube",
              let id = media.trailer?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id
    }

    /// The name shown under the logo of an AniList title: its logo is the series', so it can't
    /// tell a second season from the first. In details only with "Each Entry", where a title is
    /// one season; with "One Title" it is the whole series.
    static func nameUnderLogo(_ meta: NuvioMeta, inDetails: Bool = false) -> String? {
        guard aniListID(from: meta.id) != nil, !meta.name.isEmpty else { return nil }
        if inDetails, AniListSettings.seasonMode != .separate { return nil }
        return meta.name
    }

    /// A card with TheTVDB's background and logo in place of AniList's banner, for Home's hero.
    static func applying(_ artwork: Artwork, to card: NuvioMeta) -> NuvioMeta {
        NuvioMeta(
            id: card.id,
            name: card.name,
            description: card.description,
            posterUrl: card.posterUrl,
            backgroundUrl: artwork.background ?? card.backgroundUrl,
            logoUrl: artwork.logo ?? card.logoUrl,
            imdbId: card.imdbId,
            tmdbId: card.tmdbId,
            type: card.type,
            year: card.year,
            genres: card.genres,
            rating: card.rating,
            releaseInfo: card.releaseInfo,
            runtime: card.runtime,
            cast: card.cast,
            director: card.director,
            writer: card.writer,
            certification: card.certification,
            country: card.country,
            language: card.language,
            released: card.released,
            status: card.status,
            videos: card.videos,
            trailerYtIds: card.trailerYtIds,
            externalRatings: card.externalRatings,
            posterShape: card.posterShape,
            isFromAddon: card.isFromAddon,
            landscapePosterUrl: card.landscapePosterUrl
        )
    }

    static func rating(_ media: AniListMedia) -> NuvioExternalRating? {
        guard let score = media.averageScore, score > 0 else { return nil }
        return NuvioExternalRating(
            source: ratingSource,
            value: Double(score),
            url: "https://anilist.co/anime/\(media.id)",
            name: "AniList",
            iconUrl: ratingIcon,
            max: 100
        )
    }

    static func relatedTitle(_ media: AniListMedia, relation: String?, language: AniListSettings.TitleLanguage) -> RelatedTitle {
        let label = [relation.flatMap(relationLabel) ?? formatLabel(media.format), year(media).map { String($0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return RelatedTitle(
            id: metaID(media.id),
            type: contentType(media),
            name: title(media.title, language: language),
            posterURL: media.coverImage?.extraLarge ?? media.coverImage?.large,
            year: label.isEmpty ? nil : label,
            rating: media.averageScore.map { Double($0) / 10 },
            overview: plainText(media.description),
            backdropURL: media.bannerImage
        )
    }

    static func relationLabel(_ relation: String) -> String? {
        switch relation {
        case "PREQUEL": return "Prequel"
        case "SEQUEL": return "Sequel"
        case "PARENT": return "Parent"
        case "SIDE_STORY": return "Side Story"
        case "SPIN_OFF": return "Spin-off"
        case "ALTERNATIVE": return "Alternative"
        case "SUMMARY": return "Summary"
        case "COMPILATION": return "Compilation"
        case "CHARACTER": return "Characters"
        default: return nil
        }
    }

    // MARK: Franchise

    /// The tabs of a series, first to last: from `start`, back along the prequels and forward
    /// along the sequels, through TV / TV short / ONA entries only. `missing` are the next
    /// entries to fetch before the chain is complete.
    static func chain(from start: Int, entries: [Int: AniListMedia]) -> (ids: [Int], missing: [Int]) {
        guard let first = entries[start], isTab(first) else { return ([start], []) }
        var ids = [start]
        var seen: Set<Int> = [start]
        var missing: [Int] = []

        func step(from media: AniListMedia, relation: String, latest: Bool) -> AniListMedia? {
            let candidates = (media.relations?.edges ?? []).compactMap { edge -> AniListMedia? in
                guard edge.relationType == relation, let node = edge.node, isTab(node), node.type != "MANGA" else { return nil }
                return node
            }
            let ordered = candidates.sorted { lhs, rhs in
                let left = sortKey(lhs), right = sortKey(rhs)
                return latest ? left > right : left < right
            }
            return ordered.first { !seen.contains($0.id) }
        }

        var cursor = first
        while let previous = step(from: cursor, relation: "PREQUEL", latest: true) {
            seen.insert(previous.id)
            guard let full = entries[previous.id] else {
                missing.append(previous.id)
                break
            }
            ids.insert(full.id, at: 0)
            cursor = full
        }
        cursor = first
        while let next = step(from: cursor, relation: "SEQUEL", latest: false) {
            seen.insert(next.id)
            guard let full = entries[next.id] else {
                missing.append(next.id)
                break
            }
            ids.append(full.id)
            cursor = full
        }
        return (ids, missing)
    }

    /// The season before `media`: its latest prequel that is a series (TV, TV Short or ONA).
    /// A film before it is not a season, and its pictures would be the film's.
    static func previousSeason(of media: AniListMedia) -> Int? {
        (media.relations?.edges ?? [])
            .compactMap { edge -> AniListMedia? in
                guard edge.relationType == "PREQUEL", let node = edge.node, node.id != media.id,
                      node.type == nil || node.type == "ANIME", isTab(node) else { return nil }
                return node
            }
            .max { sortKey($0) < sortKey($1) }?
            .id
    }

    private static func sortKey(_ media: AniListMedia) -> Int {
        let date = media.startDate
        return (date?.year ?? 9999) * 10_000 + (date?.month ?? 12) * 100 + (date?.day ?? 31)
    }

    // MARK: Episode labels

    /// An episode's label: "E5" for an AniList title's first entry (AniList numbers each entry
    /// on its own, so a first season says nothing), "S2 E5" from a second entry on (One Title),
    /// and "S1 E5" for any other title. `separator` goes between the season and the episode.
    static func episodeCode(id: String, season: Int, episode: Int, separator: String = " ") -> String {
        if isAniListID(id), season <= 1 { return "E\(episode)" }
        return "S\(season)\(separator)E\(episode)"
    }

    static func episodeCode(_ video: NuvioVideo, separator: String = " ") -> String {
        episodeCode(id: video.id, season: video.season, episode: video.episode, separator: separator)
    }

    /// "Season 2 · Episode 4" over the stream list, or "Episode 4" for an AniList title's first
    /// entry (AniList numbers each season on its own).
    static func episodeHeading(_ video: NuvioVideo) -> String {
        if isAniListID(video.id), video.season <= 1 {
            // "Episode %d" in every language ("details_episode_number" is the upper-case label).
            return L10n.format("jellyfin_episode_fallback_title", fallback: "Episode %d", video.episode)
        }
        return L10n.format("details_season_episode", fallback: "Season %1$d · Episode %2$d", video.season, video.episode)
    }

    /// The player's episode line ("S1, E5 • Title") as "E5 • Title" for an AniList title's
    /// first entry. Only what is shown changes: the line handed to the player stays as it is.
    static func playerEpisodeLine(_ line: String, titleID: String?) -> String {
        guard let titleID, isAniListID(titleID), line.hasPrefix("S1, E") else { return line }
        return String(line.dropFirst("S1, ".count))
    }

    // MARK: Episodes

    /// The episodes of one entry: its count from AniList (or what has aired so far), air dates
    /// from its schedule, titles and pictures from ani.zip or AniList's streaming episodes.
    static func episodes(
        of media: AniListMedia,
        season: Int,
        aniZip: [String: AniZipEpisode] = [:],
        now: Date = Date()
    ) -> [NuvioVideo] {
        let nowSeconds = Int(now.timeIntervalSince1970)
        var airing: [Int: Int] = [:]
        for node in media.airingSchedule?.nodes ?? [] {
            airing[node.episode] = node.airingAt
        }
        if let next = media.nextAiringEpisode {
            airing[next.episode] = next.airingAt
        }

        let streaming = streamingEpisodes(media.streamingEpisodes ?? [])
        let count: Int
        if let total = media.episodes, total > 0 {
            count = total
        } else if let next = media.nextAiringEpisode {
            // Still airing with no known total: what has aired, and the next one.
            count = next.episode
        } else if let lastAired = airing.filter({ $0.value <= nowSeconds }).keys.max() {
            count = lastAired
        } else if !streaming.isEmpty {
            count = streaming.keys.max() ?? streaming.count
        } else if media.status == "FINISHED" || media.status == "RELEASING" {
            count = 1
        } else {
            count = 0
        }
        guard count > 0 else { return [] }

        return (1...count).map { number in
            let zip = aniZip[String(number)]
            let stream = streaming[number]
            let title = zip?.englishTitle ?? stream?.title ?? "Episode \(number)"
            let released = airing[number].map(isoDate(airingAt:))
                ?? zip?.airDateUtc
                ?? (number == 1 ? isoDate(media.startDate) : nil)
            return NuvioVideo(
                id: episodeID(entry: media.id, episode: number),
                title: title,
                released: released,
                season: season,
                episode: number,
                thumbnail: zip?.image ?? stream?.thumbnail,
                overview: zip?.overview ?? zip?.summary
            )
        }
    }

    /// AniList lists streaming episodes as "Episode 5 - Title" in no fixed order.
    static func streamingEpisodes(_ items: [AniListStreamingEpisode]) -> [Int: (title: String?, thumbnail: String?)] {
        var result: [Int: (title: String?, thumbnail: String?)] = [:]
        let pattern = try? NSRegularExpression(pattern: "^\\s*Episode\\s+(\\d+)\\s*[-–:]?\\s*(.*)$", options: [.caseInsensitive])
        for item in items {
            guard let raw = item.title else { continue }
            let range = NSRange(raw.startIndex..., in: raw)
            guard let match = pattern?.firstMatch(in: raw, range: range),
                  let numberRange = Range(match.range(at: 1), in: raw),
                  let number = Int(raw[numberRange]) else { continue }
            let rest = Range(match.range(at: 2), in: raw).map { String(raw[$0]).trimmingCharacters(in: .whitespaces) }
            if result[number] == nil {
                result[number] = (rest?.isEmpty == false ? rest : nil, item.thumbnail)
            }
        }
        return result
    }

    // MARK: Titles

    /// Pictures of a whole title beside AniList's own: TheTVDB's background and logo by way of
    /// api.ani.zip.
    struct Artwork: Equatable {
        var background: String? = nil
        var logo: String? = nil

        static let empty = Artwork()

        var isComplete: Bool { background != nil && logo != nil }

        /// These pictures, with what is missing taken from `other`.
        func filled(by other: Artwork) -> Artwork {
            Artwork(background: background ?? other.background, logo: logo ?? other.logo)
        }

        init(background: String? = nil, logo: String? = nil) {
            self.background = background
            self.logo = logo
        }

        /// The first entry that has each picture, in tab order.
        init(tabs: [AniListMedia], aniZip: [Int: AniZipMappingsResponse]) {
            background = tabs.lazy.compactMap { aniZip[$0.id]?.fanart }.first
            logo = tabs.lazy.compactMap { aniZip[$0.id]?.clearLogo }.first
        }
    }

    /// The background of a title: TheTVDB's 16:9 fanart first, AniList's banner (a thin strip)
    /// when there is none. Without either, the details screen shows the poster.
    static func background(tabs: [AniListMedia], artwork: Artwork) -> String? {
        artwork.background ?? tabs.first?.bannerImage ?? tabs.lazy.compactMap(\.bannerImage).first
    }

    /// A whole title: `tabs` are the entries of the series in order (one for a film, an OVA or
    /// "Each Entry"), `episodes` their episodes by entry id.
    static func meta(
        tabs: [AniListMedia],
        episodes: [Int: [NuvioVideo]],
        language: AniListSettings.TitleLanguage,
        artwork: Artwork = .empty
    ) -> NuvioMeta? {
        guard let root = tabs.first else { return nil }
        let isFilm = tabs.count == 1 && Self.isMovie(root)
        let last = tabs.last ?? root
        let videos = isFilm ? nil : tabs.flatMap { episodes[$0.id] ?? [] }

        let startYear = year(root)
        let endYear = last.endDate?.year
        let releaseInfo: String?
        if let startYear {
            if isFilm {
                releaseInfo = String(startYear)
            } else if last.status == "RELEASING" || last.status == "NOT_YET_RELEASED" {
                releaseInfo = "\(startYear)–"
            } else if let endYear, endYear != startYear {
                releaseInfo = "\(startYear)–\(endYear)"
            } else {
                releaseInfo = String(startYear)
            }
        } else {
            releaseInfo = nil
        }

        let trailer = tabs.compactMap(youTubeTrailer)

        return NuvioMeta(
            id: metaID(root.id),
            name: title(root.title, language: language),
            description: plainText(root.description),
            posterUrl: root.coverImage?.extraLarge ?? root.coverImage?.large,
            backgroundUrl: background(tabs: tabs, artwork: artwork),
            logoUrl: artwork.logo,
            type: isFilm ? "movie" : "series",
            year: startYear,
            genres: root.genres,
            releaseInfo: releaseInfo,
            runtime: root.duration.map { "\($0) min" },
            country: root.countryOfOrigin,
            language: "ja",
            released: isoDate(root.startDate),
            status: status(last.status),
            videos: videos,
            trailerYtIds: trailer.isEmpty ? nil : Array(trailer.prefix(3)),
            externalRatings: rating(root).map { [$0] }
        )
    }

    /// The Related row: relations of the title's entries that aren't tabs of it.
    static func related(
        tabs: [AniListMedia],
        language: AniListSettings.TitleLanguage
    ) -> [RelatedTitle] {
        let tabIDs = Set(tabs.map(\.id))
        var seen = tabIDs
        var items: [(order: Int, date: Int, title: RelatedTitle)] = []
        for media in tabs {
            for edge in media.relations?.edges ?? [] {
                guard let node = edge.node,
                      node.type == "ANIME",
                      let relation = edge.relationType,
                      let order = relatedTypes.firstIndex(of: relation),
                      !seen.contains(node.id) else { continue }
                seen.insert(node.id)
                items.append((order: order, date: sortKey(node), title: relatedTitle(node, relation: relation, language: language)))
            }
        }
        return items
            .sorted { ($0.order, $0.date) < ($1.order, $1.date) }
            .map(\.title)
    }

    /// Names of the tabs, by season number.
    /// The tabs' names: each entry's own, without what it shares with the first ("Shingeki no
    /// Kyojin Season 3 Part 2" → "Season 3 Part 2 · 2019"), the first by its format ("TV ·
    /// 2013"). A title of one entry says what it is: "TV · 12 episodes · 2023". Never "Season N":
    /// AniList's entries aren't seasons.
    static func tabTitles(_ tabs: [AniListMedia], language: AniListSettings.TitleLanguage) -> [Int: String] {
        let names = tabs.map { title($0.title, language: language) }
        guard let base = names.first else { return [:] }
        if tabs.count == 1, let only = tabs.first {
            return [1: singleTitle(only)]
        }
        var titles: [Int: String] = [:]
        for (index, media) in tabs.enumerated() {
            let short = index == 0 ? "" : shortName(names[index], base: base)
            let label = short.isEmpty ? (formatLabel(media.format) ?? names[index]) : short
            titles[index + 1] = [label, year(media).map { String($0) }].compactMap { $0 }.joined(separator: " · ")
        }
        return titles
    }

    static func singleTitle(_ media: AniListMedia) -> String {
        var parts: [String] = [formatLabel(media.format) ?? "TV"]
        if let count = media.episodes, count > 1 { parts.append("\(count) episodes") }
        if let year = year(media) { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    /// `name` without the words it shares with `base` at its start; all of it when they share
    /// fewer than four letters, or it would be left empty for another reason.
    static func shortName(_ name: String, base: String) -> String {
        let a = Array(name), b = Array(base)
        var shared = 0
        while shared < a.count, shared < b.count, a[shared].lowercased() == b[shared].lowercased() { shared += 1 }
        // Back to the end of a word: "Naruto" doesn't cut "Narutoverse".
        if shared < a.count, shared > 0, a[shared].isLetter || a[shared].isNumber, a[shared - 1].isLetter || a[shared - 1].isNumber {
            while shared > 0, a[shared - 1].isLetter || a[shared - 1].isNumber { shared -= 1 }
        }
        guard shared >= 4 else { return name }
        let rest = String(a[shared...]).trimmingCharacters(in: CharacterSet(charactersIn: " :-–—~,.!?").union(.whitespaces))
        return rest.isEmpty ? "" : rest
    }
}
