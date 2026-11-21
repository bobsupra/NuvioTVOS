import Foundation

/// Settings → Anime Integrations → Kitsu → Kitsu Catalogs: Kitsu's catalogs (trending, airing,
/// popular, top rated, seasons, types, genres) and the viewer's Kitsu lists as Home rows of
/// Kitsu's titles (`kitsu:ID`), under AniList's add-on id like MAL's.
enum KitsuCatalogs {
    static let idPrefix = "kitsu-"
    static let addonName = "Kitsu"
    static let rowSize = KitsuSource.pageSize
    static let keepFor: TimeInterval = 3 * 3600

    static func chosen(in store: UserDefaults = ProfileSettings.current) -> [AnimeCatalogChoice] {
        AnimeCatalogSelection.chosen(key: SettingsKey.kitsuCatalogs, fallback: defaultChoices, in: store)
    }

    static let defaultChoices = [
        AnimeCatalogChoice(id: idPrefix + "trending", title: "Kitsu Trending"),
        AnimeCatalogChoice(id: idPrefix + "airing", title: "Kitsu Top Airing"),
    ]

    static func save(_ choices: [AnimeCatalogChoice]) {
        AnimeCatalogSelection.save(choices, key: SettingsKey.kitsuCatalogs)
    }

    static func signature() -> String {
        AnimeCatalogSelection.signature(chosen()) + (KitsuAccount.isLoggedIn ? "+me" : "")
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
        guard KitsuSettings.isEnabled else { return [] }
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
        return chosen().filter { choice in
            !disabled.contains(settingsKey(choice.id)) && (!isList(choice.id) || KitsuAccount.isLoggedIn)
        }
    }

    static func homeCatalogs() async -> [NuvioCatalog] {
        var catalogs: [NuvioCatalog] = []
        for choice in visibleChoices() {
            let page = await items(catalogId: choice.id, page: 1)
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
        guard KitsuSettings.isEnabled else { return CatalogPage(items: [], hasMore: false, page: 1) }
        let page = max(skip, 0) / rowSize + 1
        let result = await items(catalogId: catalogId, page: page)
        return CatalogPage(items: result.items, hasMore: result.hasMore, page: page, nextSkip: skip + result.items.count)
    }

    static func isList(_ catalogId: String) -> Bool {
        catalogId.hasPrefix(idPrefix + "list-")
    }

    /// A page of a catalog as Kitsu cards.
    static func items(catalogId: String, page: Int) async -> (items: [NuvioMeta], hasMore: Bool) {
        let language = AniListSettings.titleLanguage
        if isList(catalogId) {
            guard page == 1 else { return ([], false) }
            let status = String(catalogId.dropFirst((idPrefix + "list-").count))
            return (KitsuSource.cards(await KitsuAccount.list(status: status), language: language), false)
        }
        guard let request = Self.request(for: catalogId, page: page),
              let data = try? await KitsuClient.shared.get(request.path, query: request.query, ttl: keepFor),
              let document = KitsuSource.document(data) else { return ([], false) }
        let cards = KitsuSource.cards(document.data, language: language)
        let hasMore = request.path != "trending/anime" && document.data.count >= rowSize
        return (cards, hasMore)
    }

    /// The Kitsu request of a catalog page; nil for an id this build doesn't know.
    static func request(for catalogId: String, page: Int) -> (path: String, query: [(String, String)])? {
        guard catalogId.hasPrefix(idPrefix) else { return nil }
        let id = String(catalogId.dropFirst(idPrefix.count))
        if id == "trending" {
            guard page == 1 else { return nil }
            return ("trending/anime", [("limit", String(rowSize))])
        }
        var query: [(String, String)] = []
        var subtype = KitsuSource.subtypes
        var sort = "-user_count"
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "airing":
            query.append(("filter[status]", "current"))
        case "popular":
            break
        case "rated":
            sort = "-average_rating"
        case "upcoming":
            query.append(("filter[status]", "upcoming"))
        case "season":
            guard parts.count == 2 else { return nil }
            let season: (season: String, year: Int)
            switch parts[1] {
            case "now": season = AniListSeason.current()
            case "next": season = AniListSeason.next()
            case "last": season = AniListSeason.previous()
            default: return nil
            }
            query.append(("filter[season]", season.season.lowercased()))
            query.append(("filter[seasonYear]", String(season.year)))
        case "type":
            guard parts.count == 2, types.contains(where: { $0.value == parts[1] }) else { return nil }
            subtype = parts[1]
        case "genre":
            guard parts.count == 2 else { return nil }
            query.append(("filter[genres]", parts[1]))
        default:
            return nil
        }
        query.append(("filter[subtype]", subtype))
        query.append(("sort", sort))
        query.append(("page[limit]", String(rowSize)))
        query.append(("page[offset]", String(max(page - 1, 0) * rowSize)))
        return ("anime", query)
    }

    // MARK: The catalog window

    static let types: [(value: String, title: String)] = [
        ("TV", "TV Series"), ("movie", "Movies"), ("OVA", "OVAs"), ("ONA", "ONAs"), ("special", "Specials"),
    ]

    static let genres = [
        "Action", "Adventure", "Comedy", "Drama", "Sci-Fi", "Space", "Mystery", "Magic", "Supernatural", "Police",
        "Fantasy", "Sports", "Romance", "Slice of Life", "Racing", "Horror", "Psychological", "Thriller",
        "Martial Arts", "Super Power", "School", "Vampire", "Historical", "Military", "Mecha", "Demons", "Samurai",
        "Harem", "Music", "Parody", "Game", "Kids", "Mahou Shoujo", "Cooking", "Medical", "Political", "Crime",
        "Zombies", "Family", "Friendship", "Workplace", "Youth",
    ]

    static let adultGenres = ["Ecchi", "Hentai"]

    static let lists: [(value: String, title: String)] = [
        ("current", "Watching"), ("planned", "Plan to Watch"), ("completed", "Completed"),
        ("on_hold", "On Hold"), ("dropped", "Dropped"),
    ]

    static func sections(loggedIn: Bool, adult: Bool) -> [AnimeCatalogSection] {
        func choices(_ items: [(String, String)]) -> [AnimeCatalogChoice] {
            items.map { AnimeCatalogChoice(id: idPrefix + $0.0, title: $0.1) }
        }
        var sections: [AnimeCatalogSection] = []
        if loggedIn {
            sections.append(AnimeCatalogSection(id: "lists", title: "My Kitsu", choices: choices(lists.map { ("list-\($0.value)", "My \($0.title)") })))
        }
        sections.append(AnimeCatalogSection(id: "top", title: "Top Lists", choices: choices([
            ("trending", "Kitsu Trending"), ("airing", "Kitsu Top Airing"), ("popular", "Kitsu Most Popular"),
            ("rated", "Kitsu Highest Rated"), ("upcoming", "Kitsu Upcoming"),
        ])))
        sections.append(AnimeCatalogSection(id: "season", title: "Seasons", choices: choices([
            ("season-now", "This Season"), ("season-next", "Next Season"), ("season-last", "Last Season"),
        ])))
        sections.append(AnimeCatalogSection(id: "type", title: "Types", choices: choices(types.map { ("type-\($0.value)", $0.title) })))
        sections.append(AnimeCatalogSection(id: "genre", title: "Genres", choices: choices(
            (genres + (adult ? adultGenres : [])).map { ("genre-\($0)", $0) }
        )))
        return sections
    }
}
