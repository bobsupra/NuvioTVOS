import Foundation

/// Settings → Anime Integrations → AniList → AniList Catalogs: every catalog AniList can give,
/// switched on one by one. A catalog's id says how it is asked for, so a chosen one needs nothing
/// else: `genre-Action`, `tag-Isekai`, `format-MOVIE`, `studio-MAPPA`, `list-completed`…
enum AniListCatalogs {
    static let favouritesRowID = "list-favourites"
    static let customListPrefix = "list-custom-"

    /// Only the viewer's Watching and Planning until something else is chosen.
    static let defaultChoices = [
        AnimeCatalogChoice(id: "list-watching", title: "Watching"),
        AnimeCatalogChoice(id: "list-planning", title: "Planning"),
    ]

    static func chosen(in store: UserDefaults = ProfileSettings.current) -> [AnimeCatalogChoice] {
        AnimeCatalogSelection.chosen(key: SettingsKey.aniListCatalogs, fallback: defaultChoices, in: store)
    }

    static func save(_ choices: [AnimeCatalogChoice]) {
        AnimeCatalogSelection.save(choices, key: SettingsKey.aniListCatalogs)
    }

    /// The chosen catalogs that are AniList searches (not the viewer's lists).
    static func chosenRows(in store: UserDefaults = ProfileSettings.current) -> [AniListHomeRow] {
        chosen(in: store).compactMap { choice in
            choice.id.hasPrefix("list-") ? nil : row(id: choice.id, title: choice.title)
        }
    }

    static func hasLists(in store: UserDefaults = ProfileSettings.current) -> Bool {
        chosen(in: store).contains { $0.id.hasPrefix("list-") }
    }

    /// The statuses each of the viewer's lists shows (Favourites and custom lists apart).
    static let listStatuses: [String: [String]] = [
        "list-watching": ["CURRENT", "REPEATING"],
        "list-planning": ["PLANNING"],
        "list-paused": ["PAUSED"],
        "list-completed": ["COMPLETED"],
        "list-dropped": ["DROPPED"],
        "list-repeating": ["REPEATING"],
        favouritesRowID: [],
    ]

    // MARK: Rows

    static let popular = "sort: [POPULARITY_DESC]"

    /// The row a catalog id stands for; nil for an id this build doesn't know.
    static func row(id: String, title: String?) -> AniListHomeRow? {
        if let standard = AniListHomeRow.standard.first(where: { $0.id == id }) {
            return AniListHomeRow(
                id: standard.id, title: title ?? standard.title, arguments: standard.arguments,
                usesSeason: standard.usesSeason, usesNextSeason: standard.usesNextSeason
            )
        }
        if let overview = overview.first(where: { $0.id == id }) {
            return AniListHomeRow(id: id, title: title ?? overview.title, arguments: overview.arguments)
        }
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let value = parts[1]
        let name = title ?? value
        switch parts[0] {
        case "format":
            guard formats.contains(where: { $0.value == value }) else { return nil }
            return AniListHomeRow(id: id, title: name, arguments: "format: \(value), \(popular)")
        case "genre":
            return AniListHomeRow(id: id, title: name, arguments: "genre: \(AniListQueries.quoted(value)), \(popular)")
        case "tag":
            return AniListHomeRow(id: id, title: name, arguments: "tag: \(AniListQueries.quoted(value)), minimumTagRank: 60, \(popular)")
        case "country":
            guard countries.contains(where: { $0.value == value }) else { return nil }
            return AniListHomeRow(id: id, title: name, arguments: "countryOfOrigin: \(AniListQueries.quoted(value)), \(popular)")
        case "source":
            guard sources.contains(where: { $0.value == value }) else { return nil }
            return AniListHomeRow(id: id, title: name, arguments: "source: \(value), \(popular)")
        case "studio":
            return AniListHomeRow(id: id, title: name, studio: value)
        default:
            return nil
        }
    }

    /// Overview rows beyond the five standard ones; last season is written in, as it changes.
    static var overview: [(id: String, title: String, arguments: String)] {
        let last = AniListSeason.previous()
        return [
            ("airing", "Airing Now", "status: RELEASING, \(popular)"),
            ("lastseason", "Popular Last Season", "season: \(last.season), seasonYear: \(last.year), \(popular)"),
            ("finished", "Recently Finished", "status: FINISHED, sort: [END_DATE_DESC], popularity_greater: 10000"),
            ("favourited", "Most Favourited", "sort: [FAVOURITES_DESC]"),
            ("newest", "Newly Added", "sort: [ID_DESC]"),
            ("announced", "Announced", "status: NOT_YET_RELEASED, \(popular)"),
        ]
    }

    static let formats: [(value: String, title: String)] = [
        ("TV", "TV"), ("TV_SHORT", "TV Short"), ("MOVIE", "Movie"), ("SPECIAL", "Special"),
        ("OVA", "OVA"), ("ONA", "ONA"), ("MUSIC", "Music Video"),
    ]

    static let genres = [
        "Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy", "Hentai", "Horror", "Mahou Shoujo",
        "Mecha", "Music", "Mystery", "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports",
        "Supernatural", "Thriller",
    ]
    static let adultGenres: Set<String> = ["Ecchi", "Hentai"]

    /// The most used tags, shown without opening the whole list.
    static let commonTags = [
        "Isekai", "Iyashikei", "Shounen", "Seinen", "Josei", "Shoujo", "Time Travel", "Reincarnation",
        "Super Power", "Magic", "Martial Arts", "School", "Military", "Space", "Cyberpunk",
        "Post-Apocalyptic", "Survival", "Video Games", "Idol", "Cute Girls Doing Cute Things",
        "Revenge", "Gore", "Vampire", "Female Protagonist", "Anti-Hero",
    ]

    static let countries: [(value: String, title: String)] = [
        ("JP", "Japan"), ("CN", "China (Donghua)"), ("KR", "South Korea"), ("TW", "Taiwan"),
    ]

    static let sources: [(value: String, title: String)] = [
        ("ORIGINAL", "Original"), ("MANGA", "Manga"), ("LIGHT_NOVEL", "Light Novel"), ("WEB_NOVEL", "Web Novel"),
        ("NOVEL", "Novel"), ("VISUAL_NOVEL", "Visual Novel"), ("VIDEO_GAME", "Video Game"), ("COMIC", "Comic (Manhwa, Manhua)"),
        ("DOUJINSHI", "Doujinshi"), ("PICTURE_BOOK", "Picture Book"), ("MULTIMEDIA_PROJECT", "Multimedia Project"),
        ("LIVE_ACTION", "Live Action"),
    ]

    static let studios = [
        "MAPPA", "ufotable", "Kyoto Animation", "Bones", "Wit Studio", "Madhouse", "Production I.G", "Trigger",
        "CloverWorks", "A-1 Pictures", "Toei Animation", "Sunrise", "Shaft", "David Production", "J.C.Staff",
        "Studio Ghibli", "Science SARU", "P.A. Works", "Doga Kobo", "Pierrot", "TMS Entertainment",
    ]

    static let lists: [(id: String, title: String)] = [
        ("list-watching", "Watching"), ("list-planning", "Planning"), ("list-paused", "Paused"),
        ("list-completed", "Completed"), ("list-dropped", "Dropped"), ("list-repeating", "Rewatching"),
        (favouritesRowID, "Favourites"),
    ]

    // MARK: The catalog window

    static func sections(loggedIn: Bool, adult: Bool) -> [AnimeCatalogSection] {
        var sections: [AnimeCatalogSection] = []
        if loggedIn {
            sections.append(AnimeCatalogSection(
                id: "lists", title: "My AniList",
                choices: lists.map { AnimeCatalogChoice(id: $0.id, title: $0.title) },
                more: AnimeCatalogMore(title: "Custom Lists…", subtitle: "Your own lists on AniList") {
                    let names = await AniListAccount.customListNames()
                    return [AnimeCatalogSection(
                        id: "custom", title: "Custom Lists",
                        subtitle: names.isEmpty ? "No custom lists on your AniList" : nil,
                        choices: names.map { AnimeCatalogChoice(id: customListPrefix + $0, title: $0) }
                    )]
                }
            ))
        }
        sections.append(AnimeCatalogSection(
            id: "overview", title: "Overview",
            choices: AniListHomeRow.standard.map { AnimeCatalogChoice(id: $0.id, title: $0.title) }
                + overview.map { AnimeCatalogChoice(id: $0.id, title: $0.title) }
        ))
        sections.append(AnimeCatalogSection(
            id: "format", title: "Format",
            choices: formats.map { AnimeCatalogChoice(id: "format-\($0.value)", title: $0.title) }
        ))
        sections.append(AnimeCatalogSection(
            id: "genre", title: "Genres",
            choices: genres.filter { adult || !adultGenres.contains($0) }.map { AnimeCatalogChoice(id: "genre-\($0)", title: $0) }
        ))
        sections.append(AnimeCatalogSection(
            id: "tag", title: "Tags", subtitle: "Titles the tag fits at least 60 %",
            choices: commonTags.map { AnimeCatalogChoice(id: "tag-\($0)", title: $0) },
            more: AnimeCatalogMore(title: "All Tags…", subtitle: "About 400 tags from AniList, by category") {
                await allTags(adult: adult)
            }
        ))
        sections.append(AnimeCatalogSection(
            id: "country", title: "Country of Origin",
            choices: countries.map { AnimeCatalogChoice(id: "country-\($0.value)", title: $0.title) }
        ))
        sections.append(AnimeCatalogSection(
            id: "source", title: "Source",
            choices: sources.map { AnimeCatalogChoice(id: "source-\($0.value)", title: $0.title) }
        ))
        sections.append(AnimeCatalogSection(
            id: "studio", title: "Studios", subtitle: "Their main titles",
            choices: studios.map { AnimeCatalogChoice(id: "studio-\($0)", title: $0) }
        ))
        return sections
    }

    struct Tag: Decodable, Sendable {
        let name: String
        var category: String? = nil
        var isAdult: Bool? = nil
        var isGeneralSpoiler: Bool? = nil
    }

    /// Every tag by its category, without spoilers, adult ones only with Adult Titles on.
    static func allTags(adult: Bool) async -> [AnimeCatalogSection] {
        struct Response: Decodable {
            struct DataField: Decodable { var MediaTagCollection: [Tag]? = nil }
            var data: DataField? = nil
        }
        guard let data = try? await AniListClient.shared.query(AniListQueries.tags, ttl: 7 * 24 * 3600, notesStatus: false),
              let tags = (try? JSONDecoder().decode(Response.self, from: data))?.data?.MediaTagCollection else { return [] }
        return tagSections(tags, adult: adult)
    }

    static func tagSections(_ tags: [Tag], adult: Bool) -> [AnimeCatalogSection] {
        var order: [String] = []
        var byCategory: [String: [AnimeCatalogChoice]] = [:]
        for tag in tags where tag.isGeneralSpoiler != true && (adult || tag.isAdult != true) {
            let category = tag.category ?? "Other"
            if byCategory[category] == nil { order.append(category) }
            byCategory[category, default: []].append(AnimeCatalogChoice(id: "tag-\(tag.name)", title: tag.name))
        }
        return order.sorted().map { category in
            AnimeCatalogSection(
                id: "tags-\(category)", title: category,
                choices: (byCategory[category] ?? []).sorted { $0.title < $1.title }
            )
        }
    }
}
