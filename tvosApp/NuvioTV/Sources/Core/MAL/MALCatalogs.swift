import Foundation

/// Settings → Anime Integrations → MyAnimeList → MAL Catalogs: MyAnimeList's catalogs from Tenrai
/// (`MALEpisodeRatings.baseURL`), the viewer's MAL lists from MAL itself. Each title opens as the
/// AniList title it maps to (offline tables, else AniList's `idMal`), so it has AniList's
/// details, episodes and streams; a title AniList doesn't know is left out.
enum MALCatalogs {
    static let idPrefix = "mal-"
    static let addonName = "MyAnimeList"
    static let rowSize = 25
    static let keepFor: TimeInterval = 3 * 3600

    static func chosen(in store: UserDefaults = ProfileSettings.current) -> [AnimeCatalogChoice] {
        AnimeCatalogSelection.chosen(key: SettingsKey.malCatalogs, fallback: [], in: store)
    }

    static func save(_ choices: [AnimeCatalogChoice]) {
        AnimeCatalogSelection.save(choices, key: SettingsKey.malCatalogs)
    }

    static func signature() -> String {
        AnimeCatalogSelection.signature(chosen()) + (MALAccount.isLoggedIn ? "+me" : "")
    }

    // MARK: Home

    static func settingsKey(_ catalogId: String) -> String {
        TVHomeCatalogOrder.catalogSettingsKey(addonId: AniListService.addonID, contentType: AniListService.homeContentType, catalogId: catalogId)
    }

    static func rowID(_ catalogId: String) -> String {
        "addon_\(AniListService.addonID)_\(AniListService.homeContentType)_\(catalogId)"
    }

    static func displayTitle(_ choice: AnimeCatalogChoice) -> String {
        let showType = ProfileSettings.current.object(forKey: SettingsKey.homeCatalogShowType) as? Bool ?? true
        return TVHomeCatalogOrder.catalogDisplayTitle(
            choice.title,
            contentType: AniListService.homeContentType,
            showType: showType,
            addonName: addonName,
            customTitle: TVHomeCatalogOrder.customCatalogTitles()[settingsKey(choice.id)]
        )
    }

    /// The rows Home shows: the chosen ones Layout doesn't hide (lists only when logged in).
    static func visibleChoices() -> [AnimeCatalogChoice] {
        guard MALSettings.isEnabled else { return [] }
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
        return chosen().filter { choice in
            !disabled.contains(settingsKey(choice.id)) && (!isList(choice.id) || MALAccount.isLoggedIn)
        }
    }

    static func homeCatalogs() async -> [NuvioCatalog] {
        var catalogs: [NuvioCatalog] = []
        for choice in visibleChoices() {
            let page = await items(catalogId: choice.id, page: 1, limit: rowSize)
            guard !page.items.isEmpty else { continue }
            let title = displayTitle(choice)
            catalogs.append(NuvioCatalog(
                id: rowID(choice.id),
                name: title,
                description: title,
                itemIds: page.items.map(\.id),
                items: page.items,
                contentType: AniListService.homeContentType,
                catalogId: choice.id,
                addonId: AniListService.addonID,
                addonName: addonName
            ))
        }
        return catalogs
    }

    static func browse(catalogId: String, skip: Int) async -> CatalogPage {
        guard MALSettings.isEnabled else { return CatalogPage(items: [], hasMore: false, page: 1) }
        let page = max(skip, 0) / rowSize + 1
        let result = await items(catalogId: catalogId, page: page, limit: rowSize)
        return CatalogPage(items: result.items, hasMore: result.hasMore, page: page, nextSkip: skip + result.items.count)
    }

    static func isList(_ catalogId: String) -> Bool {
        catalogId.hasPrefix(idPrefix + "list-")
    }

    /// A page of a catalog as AniList cards.
    static func items(catalogId: String, page: Int, limit: Int) async -> (items: [NuvioMeta], hasMore: Bool) {
        if isList(catalogId) {
            guard page == 1 else { return ([], false) }
            let status = String(catalogId.dropFirst((idPrefix + "list-").count))
            let anime = await MALAccount.list(status: status)
            return (await cards(anime), false)
        }
        guard let url = await Self.url(for: catalogId, page: page, limit: limit),
              let data = await TenraiPages.shared.data(url) else { return ([], false) }
        if catalogId == idPrefix + "recommended" {
            let anime = recommendations(from: data)
            return (await cards(anime), !anime.isEmpty)
        }
        guard let list = try? JSONDecoder().decode(TenraiList.self, from: data) else { return ([], false) }
        return (await cards(list.data ?? []), list.pagination?.hasNextPage ?? false)
    }

    // MARK: Tenrai addresses

    /// The Tenrai address of a catalog page; nil for an id this build doesn't know.
    static func url(for catalogId: String, page: Int, limit: Int) async -> URL? {
        guard catalogId.hasPrefix(idPrefix) else { return nil }
        let id = String(catalogId.dropFirst(idPrefix.count))
        guard !id.isEmpty else { return nil }
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        let kind = parts[0]
        let value = parts.count > 1 ? parts[1] : ""
        var path = "anime"
        var query: [(String, String)] = []
        let byPopularity = [("order_by", "members"), ("sort", "desc")]
        switch kind {
        case "top":
            path = "top/anime"
            switch value {
            case "all": break
            case "airing", "upcoming", "bypopularity", "favorite": query.append(("filter", value))
            default:
                guard topTypes.contains(where: { $0.value == value }) else { return nil }
                query.append(("type", value))
            }
        case "season":
            switch value {
            case "now": path = "seasons/now"
            case "next": path = "seasons/upcoming"
            case "last":
                let last = AniListSeason.previous()
                path = "seasons/\(last.year)/\(last.season.lowercased())"
            default: return nil
            }
        case "day":
            guard weekdays.contains(where: { $0.value == value }) || value == "today" || value == "tomorrow" else { return nil }
            query += [("broadcast_day", value), ("status", "airing")] + byPopularity
        case "genre":
            guard Int(value) != nil else { return nil }
            query += [("genres", value)] + byPopularity
        case "studio":
            guard let producer = await producerID(name: value) else { return nil }
            query += [("producers", String(producer))] + byPopularity
        case "source":
            guard sources.contains(where: { $0.value == value }) else { return nil }
            query += [("source", value)] + byPopularity
        case "dub":
            guard dubs.contains(where: { $0.value == value }) else { return nil }
            query += [("voice_language", value)] + byPopularity
        case "stream":
            guard !value.isEmpty else { return nil }
            query += [("streaming_service", value)] + byPopularity
        case "added":
            query += [("order_by", "added"), ("sort", "desc")]
        case "recommended":
            path = "recommendations/anime"
            return address(path, [("page", String(page))])
        default:
            return nil
        }
        query += [("page", String(page)), ("limit", String(limit))]
        if !MALSettings.showsAdult { query.append(("sfw", "true")) }
        return address(path, query)
    }

    static func address(_ path: String, _ query: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: MALEpisodeRatings.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url
    }

    /// A studio's MAL producer id, found by name once and kept.
    static func producerID(name: String) async -> Int? {
        let key = "nuvio.tv.mal.producer." + name.lowercased()
        if let known = UserDefaults.standard.object(forKey: key) as? Int { return known }
        guard let url = address("producers", [("q", name), ("order_by", "count"), ("sort", "desc"), ("limit", "5")]),
              let data = await TenraiPages.shared.data(url),
              let found = try? JSONDecoder().decode(TenraiProducers.self, from: data).data else { return nil }
        let wanted = name.lowercased()
        let match = found.first { ($0.titles ?? []).contains { $0.title?.lowercased() == wanted } } ?? found.first
        guard let id = match?.malID else { return nil }
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: Cards

    /// AniList cards of MAL titles, in their order; titles AniList doesn't know are left out.
    static func cards(_ anime: [TenraiAnime]) async -> [NuvioMeta] {
        var aniList: [Int: Int] = [:]
        var missing: [Int] = []
        for item in anime {
            if let id = await AniListOfflineMaps.shared.aniListID(mal: item.malID) {
                aniList[item.malID] = id
            } else {
                missing.append(item.malID)
            }
        }
        if !missing.isEmpty {
            aniList.merge(await aniListIDs(mal: missing)) { known, _ in known }
        }
        let language = AniListSettings.titleLanguage
        // AniList's own cards where it answers: banner, AniList score and trailer as in AniList's
        // catalogs; Tenrai's otherwise.
        let media = await aniListMedia(ids: Array(Set(aniList.values)))
        var seen = Set<Int>()
        return anime.compactMap { item in
            guard let id = aniList[item.malID], seen.insert(id).inserted else { return nil }
            if let found = media[id] {
                return AniListMetaBuilder.card(found, language: language)
            }
            return card(item, aniListID: id, language: language)
        }
    }

    /// AniList's media of these entries, 50 a request, kept six hours.
    static func aniListMedia(ids: [Int]) async -> [Int: AniListMedia] {
        let query = "query ($ids: [Int]) { Page(perPage: 50) { media(id_in: $ids, type: ANIME) { \(AniListQueries.cardFields) } } }"
        var found: [Int: AniListMedia] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = Array(ids.sorted()[start..<min(start + 50, ids.count)])
            guard let data = try? await AniListClient.shared.query(query, variables: ["ids": chunk], ttl: 6 * 3600, notesStatus: false),
                  let page = try? JSONDecoder().decode(AniListPageResponse.self, from: data).data?.Page else { continue }
            for media in page.media ?? [] { found[media.id] = media }
        }
        return found
    }

    static func card(_ item: TenraiAnime, aniListID: Int, language: AniListSettings.TitleLanguage) -> NuvioMeta {
        let name: String
        switch language {
        case .english: name = item.titleEnglish ?? item.title ?? ""
        case .native: name = item.titleJapanese ?? item.title ?? ""
        case .romaji: name = item.title ?? item.titleEnglish ?? ""
        }
        let year = item.year ?? item.aired?.prop?.from?.year
        return NuvioMeta(
            id: AniListMetaBuilder.metaID(aniListID),
            name: name,
            description: item.synopsis,
            posterUrl: item.images?.jpg?.largeImageURL ?? item.images?.jpg?.imageURL,
            backgroundUrl: nil,
            type: item.type == "Movie" ? "movie" : "series",
            year: year,
            genres: item.genres?.compactMap(\.name),
            releaseInfo: year.map { String($0) },
            country: nil,
            language: "ja",
            status: nil,
            trailerYtIds: item.trailer?.youtubeID.map { [$0] },
            externalRatings: item.score.flatMap { $0 > 0 ? [NuvioExternalRating(source: MdbListDetailsService.providerMyAnimeList, value: $0)] : nil }
        )
    }

    /// AniList ids of MAL titles the offline tables don't have yet (new seasons), from AniList.
    static func aniListIDs(mal: [Int]) async -> [Int: Int] {
        let query = "query ($ids: [Int]) { Page(perPage: 50) { media(idMal_in: $ids, type: ANIME) { id idMal } } }"
        guard let data = try? await AniListClient.shared.query(query, variables: ["ids": Array(mal.prefix(50))], ttl: 24 * 3600, notesStatus: false),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = ((root["data"] as? [String: Any])?["Page"] as? [String: Any])?["media"] as? [[String: Any]] else { return [:] }
        var found: [Int: Int] = [:]
        for item in media {
            if let id = item["id"] as? Int, let mal = item["idMal"] as? Int, found[mal] == nil { found[mal] = id }
        }
        return found
    }

    static func recommendations(from data: Data) -> [TenraiAnime] {
        struct Response: Decodable {
            struct Item: Decodable { var entry: [TenraiAnime]? = nil }
            var data: [Item]? = nil
        }
        var seen = Set<Int>()
        let all = (try? JSONDecoder().decode(Response.self, from: data))?.data?.flatMap { $0.entry ?? [] } ?? []
        return all.filter { seen.insert($0.malID).inserted }
    }

    // MARK: The series' MAL score

    /// The MAL score of a title straight from MAL (Tenrai), when MyAnimeList is on: an AniList
    /// title's own entry, a Cinemeta anime's first season. nil leaves MDBList's copy in place.
    static func seriesScore(for meta: NuvioMeta) async -> NuvioExternalRating? {
        guard MALSettings.usesOwnScore else { return nil }
        let entry: Int?
        if let id = AniListMetaBuilder.aniListID(from: meta.id) {
            entry = id
        } else {
            entry = await AniListService.mappedEntry(for: meta)
        }
        guard let entry, let mal = await MALEpisodeRatings.malID(aniListID: entry),
              let url = address("anime/\(mal)", []),
              let data = await TenraiPages.shared.data(url),
              let score = score(fromDetails: data) else { return nil }
        return NuvioExternalRating(source: MdbListDetailsService.providerMyAnimeList, value: score)
    }

    static func score(fromDetails data: Data) -> Double? {
        struct Response: Decodable { var data: TenraiAnime? = nil }
        guard let score = (try? JSONDecoder().decode(Response.self, from: data))?.data?.score, score > 0 else { return nil }
        return score
    }

    // MARK: The catalog window

    static let topTypes: [(value: String, title: String)] = [
        ("tv", "Top TV"), ("movie", "Top Movies"), ("ova", "Top OVA"), ("ona", "Top ONA"),
        ("special", "Top Specials"), ("tv_special", "Top TV Specials"), ("music", "Top Music"),
    ]

    static let weekdays: [(value: String, title: String)] = [
        ("monday", "Mondays"), ("tuesday", "Tuesdays"), ("wednesday", "Wednesdays"), ("thursday", "Thursdays"),
        ("friday", "Fridays"), ("saturday", "Saturdays"), ("sunday", "Sundays"),
    ]

    static let genres: [(id: Int, title: String)] = [
        (1, "Action"), (2, "Adventure"), (5, "Avant Garde"), (46, "Award Winning"), (28, "Boys Love"),
        (4, "Comedy"), (8, "Drama"), (10, "Fantasy"), (26, "Girls Love"), (47, "Gourmet"), (14, "Horror"),
        (7, "Mystery"), (22, "Romance"), (24, "Sci-Fi"), (36, "Slice of Life"), (30, "Sports"),
        (37, "Supernatural"), (41, "Suspense"),
    ]
    static let explicitGenres: [(id: Int, title: String)] = [(9, "Ecchi"), (49, "Erotica"), (12, "Hentai")]
    static let demographics: [(id: Int, title: String)] = [(27, "Shounen"), (42, "Seinen"), (25, "Shoujo"), (43, "Josei"), (15, "Kids")]

    static let sources: [(value: String, title: String)] = [
        ("original", "Original"), ("manga", "Manga"), ("light_novel", "Light Novel"), ("web_novel", "Web Novel"),
        ("novel", "Novel"), ("visual_novel", "Visual Novel"), ("game", "Game"), ("web_manga", "Web Manga"),
        ("4_koma_manga", "4-koma Manga"),
    ]

    static let dubs: [(value: String, title: String)] = [
        ("english", "English Dub"), ("german", "German Dub"), ("spanish", "Spanish Dub"), ("french", "French Dub"),
        ("italian", "Italian Dub"), ("portuguese_br", "Portuguese (BR) Dub"), ("korean", "Korean Dub"), ("mandarin", "Mandarin Dub"),
    ]

    static let streaming = ["Crunchyroll", "Netflix", "HIDIVE", "Prime Video", "Disney Plus"]

    static let lists: [(value: String, title: String)] = [
        ("watching", "Watching"), ("completed", "Completed"), ("on_hold", "On-Hold"),
        ("dropped", "Dropped"), ("plan_to_watch", "Plan to Watch"),
    ]

    static func sections(loggedIn: Bool, adult: Bool) -> [AnimeCatalogSection] {
        func choices(_ items: [(String, String)]) -> [AnimeCatalogChoice] {
            items.map { AnimeCatalogChoice(id: idPrefix + $0.0, title: $0.1) }
        }
        var sections: [AnimeCatalogSection] = []
        if loggedIn {
            sections.append(AnimeCatalogSection(id: "lists", title: "My MAL", choices: choices(lists.map { ("list-\($0.value)", $0.title) })))
        }
        sections.append(AnimeCatalogSection(id: "top", title: "Top Lists", choices: choices([
            ("top-all", "Top Anime"), ("top-airing", "Top Airing"), ("top-upcoming", "Top Upcoming"),
            ("top-bypopularity", "Most Popular"), ("top-favorite", "Most Favorited"),
        ] + topTypes.map { ("top-\($0.value)", $0.title) })))
        sections.append(AnimeCatalogSection(id: "season", title: "Seasons", choices: choices([
            ("season-now", "This Season"), ("season-next", "Next Season"), ("season-last", "Last Season"),
        ])))
        sections.append(AnimeCatalogSection(id: "day", title: "Airing", subtitle: "By the day they air in Japan", choices: choices(
            [("day-today", "Airing Today"), ("day-tomorrow", "Airing Tomorrow")] + weekdays.map { ("day-\($0.value)", "Airing \($0.title)") }
        )))
        sections.append(AnimeCatalogSection(id: "genre", title: "Genres", choices: choices(
            (genres + (adult ? explicitGenres : [])).map { ("genre-\($0.id)", $0.title) }
        )))
        sections.append(AnimeCatalogSection(
            id: "theme", title: "Themes", subtitle: "Isekai, Iyashikei, Mecha, School…", choices: [],
            more: AnimeCatalogMore(title: "Themes…", subtitle: "Every MyAnimeList theme") { await themes() }
        ))
        sections.append(AnimeCatalogSection(id: "demographic", title: "Demographics", choices: choices(demographics.map { ("genre-\($0.id)", $0.title) })))
        sections.append(AnimeCatalogSection(id: "studio", title: "Studios", choices: choices(AniListCatalogs.studios.map { ("studio-\($0)", $0) })))
        sections.append(AnimeCatalogSection(id: "source", title: "Source", choices: choices(sources.map { ("source-\($0.value)", $0.title) })))
        sections.append(AnimeCatalogSection(id: "dub", title: "Dubs", subtitle: "A credited dub, not that it streams", choices: choices(dubs.map { ("dub-\($0.value)", $0.title) })))
        sections.append(AnimeCatalogSection(id: "stream", title: "Streaming Services", choices: choices(streaming.map { ("stream-\($0)", "On \($0)") })))
        sections.append(AnimeCatalogSection(id: "other", title: "Other", choices: choices([
            ("added", "Recently Added on MAL"), ("recommended", "Recently Recommended"),
        ])))
        return sections
    }

    /// MAL's themes from Tenrai.
    static func themes() async -> [AnimeCatalogSection] {
        struct Response: Decodable {
            struct Genre: Decodable {
                let malID: Int
                let name: String
                enum CodingKeys: String, CodingKey { case malID = "mal_id", name }
            }
            var data: [Genre]? = nil
        }
        guard let url = address("genres/anime", [("filter", "themes")]),
              let data = await TenraiPages.shared.data(url),
              let themes = (try? JSONDecoder().decode(Response.self, from: data))?.data, !themes.isEmpty else {
            return [AnimeCatalogSection(id: "themes", title: "Themes", subtitle: "Tenrai didn't answer. Try again later.", choices: [])]
        }
        return [AnimeCatalogSection(
            id: "themes", title: "Themes",
            choices: themes.sorted { $0.name < $1.name }.map { AnimeCatalogChoice(id: "\(idPrefix)genre-\($0.malID)", title: $0.name) }
        )]
    }
}

// MARK: - Tenrai answers

struct TenraiAnime: Decodable, Sendable {
    let malID: Int
    var title: String? = nil
    var titleEnglish: String? = nil
    var titleJapanese: String? = nil
    var images: Images? = nil
    var synopsis: String? = nil
    var type: String? = nil
    var year: Int? = nil
    var score: Double? = nil
    var genres: [Named]? = nil
    var aired: Aired? = nil
    var trailer: Trailer? = nil

    enum CodingKeys: String, CodingKey {
        case malID = "mal_id", title, titleEnglish = "title_english", titleJapanese = "title_japanese"
        case images, synopsis, type, year, score, genres, aired, trailer
    }

    struct Images: Decodable, Sendable {
        var jpg: Picture? = nil
    }

    struct Picture: Decodable, Sendable {
        var imageURL: String? = nil
        var largeImageURL: String? = nil
        enum CodingKeys: String, CodingKey { case imageURL = "image_url", largeImageURL = "large_image_url" }
    }

    struct Named: Decodable, Sendable {
        var name: String? = nil
    }

    struct Aired: Decodable, Sendable {
        var prop: Prop? = nil
        struct Prop: Decodable, Sendable { var from: Day? = nil }
        struct Day: Decodable, Sendable { var year: Int? = nil }
    }

    struct Trailer: Decodable, Sendable {
        var youtubeID: String? = nil
        enum CodingKeys: String, CodingKey { case youtubeID = "youtube_id" }
    }
}

struct TenraiList: Decodable {
    var data: [TenraiAnime]? = nil
    var pagination: Pagination? = nil

    struct Pagination: Decodable {
        var hasNextPage: Bool? = nil
        enum CodingKeys: String, CodingKey { case hasNextPage = "has_next_page" }
    }
}

struct TenraiProducers: Decodable {
    struct Producer: Decodable {
        let malID: Int
        var titles: [Title]? = nil
        enum CodingKeys: String, CodingKey { case malID = "mal_id", titles }
    }
    struct Title: Decodable { var title: String? = nil }
    var data: [Producer]? = nil
}

/// Tenrai's answers kept three hours in memory; nothing asked while Tenrai says to wait.
actor TenraiPages {
    static let shared = TenraiPages()

    private var kept: [URL: (data: Data, until: Date)] = [:]
    private var waitUntil: Date?

    func data(_ url: URL, now: Date = Date()) async -> Data? {
        if let hit = kept[url], hit.until > now { return hit.data }
        if let waitUntil, waitUntil > now { return kept[url]?.data }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let reply = try? await URLSession.shared.data(for: request),
              let http = reply.1 as? HTTPURLResponse else { return kept[url]?.data }
        switch http.statusCode {
        case 200..<300:
            kept[url] = (reply.0, now.addingTimeInterval(MALCatalogs.keepFor))
            if kept.count > 400 { kept = kept.filter { $0.value.until > now } }
            return reply.0
        case 429, 503:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 60
            waitUntil = now.addingTimeInterval(min(max(seconds, 1), 3600))
            return kept[url]?.data
        default:
            return kept[url]?.data
        }
    }
}
