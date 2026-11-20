import Foundation

/// The page a cast card of an AniList title opens, laid out like a TMDB person's: the
/// character's Japanese voice actor (photo, name in both scripts, birthday, home town, what
/// AniList says of them) with their anime roles, or the character itself when AniList knows no
/// voice actor. One AniList request on the click, kept a day on disk and for the session in memory.
enum AniListPeople {
    struct Page: Equatable {
        let detail: ScenePersonDetail
        /// The name in its own script (花江夏樹), when it isn't the name shown.
        let nativeName: String?
        let rails: [TmdbNetworkBrowseRail]
        /// The banner of the best known title, behind the page.
        let backdropURL: URL?
    }

    static let ttl: TimeInterval = 24 * 3600
    /// Past this many pages, the memory starts again.
    static let limit = 100

    private static let lock = NSLock()
    private static var pages: [String: Page] = [:]
    private static let decoder = JSONDecoder()

    // MARK: Before the page loads

    /// The line above the name: "Voice actor · as Tanjiro Kamado", or "Character".
    static func category(for person: TmdbPersonMetadata) -> String? {
        if person.aniListStaffID != nil { return "Voice actor · as \(person.name)" }
        if person.aniListCharacterID != nil { return "Character" }
        return nil
    }

    /// The voice actor's name, which the card shows under the character's.
    static func name(for person: TmdbPersonMetadata) -> String? {
        person.aniListStaffID == nil ? nil : person.role
    }

    /// The voice actor's photo (the card shows the character's).
    static func portrait(for person: TmdbPersonMetadata) -> URL? {
        guard person.aniListStaffID != nil else { return nil }
        return person.aniListStaffImage.flatMap(URL.init(string:))
    }

    // MARK: The page

    static func page(for person: TmdbPersonMetadata) async -> Page? {
        let language = AniListSettings.titleLanguage
        let showsAdult = AniListSettings.showsAdult
        let collapses = AniListSettings.seasonMode == .merged
        let kind: String
        if let id = person.aniListStaffID {
            kind = "staff:\(id)"
        } else if let id = person.aniListCharacterID {
            kind = "character:\(id)"
        } else {
            return nil
        }
        let key = [kind, language.rawValue, showsAdult ? "adult" : "safe", collapses ? "merged" : "each"].joined(separator: "|")
        if let cached = kept(key) { return cached }

        let page: Page?
        if let id = person.aniListStaffID {
            page = await fetchStaff(id).map {
                staffPage($0, fallbackName: person.role ?? person.name, language: language, showsAdult: showsAdult, collapsesSeasons: collapses)
            }
        } else if let id = person.aniListCharacterID {
            page = await fetchCharacter(id).map {
                characterPage($0, fallbackName: person.name, language: language, showsAdult: showsAdult, collapsesSeasons: collapses)
            }
        } else {
            page = nil
        }
        if let page { keep(page, key) }
        return page
    }

    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        pages.removeAll()
    }

    private static func kept(_ key: String) -> Page? {
        lock.lock()
        defer { lock.unlock() }
        return pages[key]
    }

    private static func keep(_ page: Page, _ key: String) {
        lock.lock()
        defer { lock.unlock() }
        if pages.count >= limit { pages.removeAll() }
        pages[key] = page
    }

    private static func fetchStaff(_ id: Int) async -> AniListStaff? {
        guard let data = try? await AniListClient.shared.query(AniListQueries.staff, variables: ["id": id], ttl: ttl) else { return nil }
        return try? decoder.decode(AniListStaffResponse.self, from: data).data?.Staff
    }

    private static func fetchCharacter(_ id: Int) async -> AniListCharacter? {
        guard let data = try? await AniListClient.shared.query(AniListQueries.character, variables: ["id": id], ttl: ttl) else { return nil }
        return try? decoder.decode(AniListCharacterResponse.self, from: data).data?.Character
    }

    // MARK: Building (apart from the requests, for tests)

    /// A voice actor's page; each role says whom they voice in it ("Tanjiro Kamado · 2019").
    static func staffPage(
        _ staff: AniListStaff,
        fallbackName: String,
        language: AniListSettings.TitleLanguage,
        showsAdult: Bool,
        collapsesSeasons: Bool
    ) -> Page {
        let roles: [Role] = (staff.characterMedia?.edges ?? []).compactMap { edge in
            guard let media = edge.node else { return nil }
            let characters = (edge.characters ?? [])
                .compactMap { $0.name?.full?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Role(media: media, label: characters.joined(separator: ", "))
        }
        let name = clean(staff.name?.full) ?? fallbackName
        let built = rails(roles, language: language, showsAdult: showsAdult, collapsesSeasons: collapsesSeasons)
        return Page(
            detail: ScenePersonDetail(
                id: staff.id,
                name: name,
                biography: biography(staff.description),
                birthday: birthday(staff.dateOfBirth),
                deathday: fullDate(staff.dateOfDeath),
                placeOfBirth: clean(staff.homeTown),
                profileURL: clean(staff.image?.large).flatMap(URL.init(string:))
            ),
            nativeName: nativeName(staff.name, shown: name),
            rails: built.rails,
            backdropURL: built.backdrop
        )
    }

    /// A character's page; each title says the character's role in it ("Main · 2019").
    static func characterPage(
        _ character: AniListCharacter,
        fallbackName: String,
        language: AniListSettings.TitleLanguage,
        showsAdult: Bool,
        collapsesSeasons: Bool
    ) -> Page {
        let roles: [Role] = (character.media?.edges ?? []).compactMap { edge in
            guard let media = edge.node else { return nil }
            return Role(media: media, label: roleLabel(edge.characterRole) ?? "")
        }
        let name = clean(character.name?.full) ?? fallbackName
        let built = rails(roles, language: language, showsAdult: showsAdult, collapsesSeasons: collapsesSeasons)
        return Page(
            detail: ScenePersonDetail(
                id: character.id,
                name: name,
                biography: biography(character.description),
                birthday: birthday(character.dateOfBirth),
                profileURL: clean(character.image?.large).flatMap(URL.init(string:))
            ),
            nativeName: nativeName(character.name, shown: name),
            rails: built.rails,
            backdropURL: built.backdrop
        )
    }

    struct Role {
        let media: AniListMedia
        /// Whom they voice, or the character's role; empty when unknown.
        let label: String
    }

    /// Series and Movies rails, as on a TMDB person's page, in AniList's order (the best known
    /// first). Manga, adult titles (unless shown) and repeats are left out; with "One Title", a
    /// later season with the same role as an earlier card is too, as that card opens the series.
    static func rails(
        _ roles: [Role],
        language: AniListSettings.TitleLanguage,
        showsAdult: Bool,
        collapsesSeasons: Bool
    ) -> (rails: [TmdbNetworkBrowseRail], backdrop: URL?) {
        var seen = Set<Int>()
        var series: [RelatedTitle] = []
        var films: [RelatedTitle] = []
        var shownSeries: [(name: String, label: String)] = []
        var backdrop: URL?
        for role in roles {
            let media = role.media
            guard media.type == nil || media.type == "ANIME",
                  showsAdult || media.isAdult != true,
                  seen.insert(media.id).inserted else { continue }
            let name = AniListMetaBuilder.title(media.title, language: language)
            if collapsesSeasons, AniListMetaBuilder.isTab(media) {
                let isLaterSeason = shownSeries.contains { shown in
                    shown.label == role.label && AniListMetaBuilder.shortName(name, base: shown.name) != name
                }
                if isLaterSeason { continue }
                shownSeries.append((name: name, label: role.label))
            }
            if backdrop == nil, let banner = clean(media.bannerImage) {
                backdrop = URL(string: banner)
            }
            let year = AniListMetaBuilder.year(media).map { String($0) }
            let caption = [role.label, year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let title = RelatedTitle(
                id: AniListMetaBuilder.metaID(media.id),
                type: AniListMetaBuilder.contentType(media),
                name: name,
                posterURL: media.coverImage?.extraLarge ?? media.coverImage?.large,
                year: year,
                rating: nil,
                overview: nil,
                caption: caption.isEmpty ? nil : caption
            )
            if AniListMetaBuilder.isMovie(media) {
                films.append(title)
            } else {
                series.append(title)
            }
        }
        var rails: [TmdbNetworkBrowseRail] = []
        if !series.isEmpty {
            rails.append(TmdbNetworkBrowseRail(
                id: "anilist-series",
                title: L10n.format("details_series_count", fallback: "Series • %d", series.count),
                items: series
            ))
        }
        if !films.isEmpty {
            rails.append(TmdbNetworkBrowseRail(
                id: "anilist-movies",
                title: L10n.format("details_movies_count", fallback: "Movies • %d", films.count),
                items: films
            ))
        }
        return (rails, backdrop)
    }

    static func roleLabel(_ role: String?) -> String? {
        switch role {
        case "MAIN": return "Main"
        case "SUPPORTING": return "Supporting"
        case "BACKGROUND": return "Background"
        default: return nil
        }
    }

    /// AniList's description of a person or character, in its markdown: spoilers (`~!…!~`),
    /// pictures and videos left out, links and bold kept as plain text.
    static func biography(_ markdown: String?) -> String? {
        guard var text = markdown, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "~![\\s\\S]*?!~", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(img|youtube|webm)\\d*%?\\([^)]*\\)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\*\\*|__|~~~", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^#+[ \\t]*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        return AniListMetaBuilder.plainText(text)
    }

    /// A birthday for `ScenePersonDetail.birthInfo`: "1991-06-26" when whole (it then adds the
    /// age), else what AniList knows ("Jun 26", "Jun 1991", "1991").
    static func birthday(_ date: AniListDate?) -> String? {
        guard let date else { return nil }
        if let whole = fullDate(date) { return whole }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let monthName = date.month.flatMap { (1...12).contains($0) ? months[$0 - 1] : nil }
        switch (date.year, monthName, date.day) {
        case let (_, month?, day?): return "\(month) \(day)"
        case let (year?, month?, nil): return "\(month) \(year)"
        case let (year?, nil, _): return String(year)
        default: return nil
        }
    }

    static func fullDate(_ date: AniListDate?) -> String? {
        guard let year = date?.year, let month = date?.month, let day = date?.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func nativeName(_ name: AniListName?, shown: String) -> String? {
        guard let native = clean(name?.native), native != shown else { return nil }
        return native
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
