import Foundation

// MARK: - Settings

extension SettingsKey {
    static let kitsuEnabled = "nuvio.tv.settings.integrations.kitsuEnabled"
    static let kitsuCatalogs = "nuvio.tv.settings.integrations.kitsuCatalogs"
    static let kitsuSearch = "nuvio.tv.settings.integrations.kitsuSearch"
    static let kitsuAdult = "nuvio.tv.settings.integrations.kitsuAdult"
    static let kitsuScrobble = "nuvio.tv.settings.integrations.kitsuScrobble"
    static let kitsuDetailsButton = "nuvio.tv.settings.integrations.kitsuDetailsButton"
    static let kitsuScore = "nuvio.tv.settings.integrations.kitsuScore"
    static let kitsuFindInMenu = "nuvio.tv.settings.integrations.kitsuFindInMenu"
}

/// Settings → Anime Integrations → Kitsu: Kitsu's catalogs, search and titles (`kitsu:ID`), built
/// by the AniList engine from Kitsu's data, and the viewer's Kitsu account.
enum KitsuSettings {
    static var isEnabled: Bool { isEnabled(in: ProfileSettings.current) }

    static func isEnabled(in store: UserDefaults) -> Bool {
        store.bool(forKey: SettingsKey.kitsuEnabled)
    }

    /// Kitsu's titles open with Kitsu's data whenever Kitsu is on.
    static var opensTitles: Bool { isEnabled }

    static var searchesKitsu: Bool { isEnabled && flag(SettingsKey.kitsuSearch) }
    static var showsAdult: Bool { ProfileSettings.current.bool(forKey: SettingsKey.kitsuAdult) }
    static var scrobbles: Bool { isEnabled && flag(SettingsKey.kitsuScrobble) }
    static var showsDetailsButton: Bool { KitsuAccount.isLoggedIn && flag(SettingsKey.kitsuDetailsButton) }
    static var findsInMenu: Bool { isEnabled && flag(SettingsKey.kitsuFindInMenu) }

    /// Kitsu's average score beside the others, for anime from Cinemeta, AniList and MyAnimeList
    /// too. Works with Kitsu (and MyAnimeList) off; never switched, it follows Kitsu being on.
    static var showsScore: Bool { showsScore(in: ProfileSettings.current) }

    static func showsScore(in store: UserDefaults) -> Bool {
        store.object(forKey: SettingsKey.kitsuScore) == nil ? isEnabled(in: store) : store.bool(forKey: SettingsKey.kitsuScore)
    }

    private static func flag(_ key: String) -> Bool {
        let store = ProfileSettings.current
        return store.object(forKey: key) == nil || store.bool(forKey: key)
    }
}

// MARK: - Client

/// Kitsu's API (kitsu.app/api/edge, JSON:API). Kitsu publishes no limit; this asks at most 40
/// times a minute and twice a second, the viewer's requests (`AniListClient.isInteractive`) ahead
/// of the rest, nothing while a 429 says to wait, and keeps answers on disk in Caches/Kitsu (a
/// saved answer stands in when Kitsu can't answer).
actor KitsuClient {
    static let shared = KitsuClient()

    static let baseURL = URL(string: "https://kitsu.app/api/edge")!
    static let perMinute = 40
    static let backgroundPerMinute = 28
    static let minimumGap: TimeInterval = 0.5
    static let longestWait: TimeInterval = 20
    static let longestBackgroundWait: TimeInterval = 60

    private(set) var requests = 0
    private(set) var savedAnswers = 0
    private(set) var lastSuccess: Date?
    private(set) var lastFailure: Date?
    private(set) var lastFailureMessage: String?
    private var sentAt: [Date] = []
    private var blockedUntil: Date?
    private var interactiveWaiting = 0
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let cache: AniListDiskCache

    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Kitsu", isDirectory: true)
    }

    init(cache: AniListDiskCache = AniListDiskCache(directory: KitsuClient.cacheDirectory)) {
        self.cache = cache
    }

    static func url(_ path: String, _ query: [(String, String)] = []) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url
    }

    /// The answer at `path`: from disk while younger than `ttl`, else asked (one request per
    /// address at a time). `token` asks as the viewer (their library), never kept on disk.
    func get(_ path: String, query: [(String, String)] = [], ttl: TimeInterval, token: String? = nil) async throws -> Data {
        guard let url = Self.url(path, query) else { throw TenraiClient.Failure.status(400) }
        let key = AniListClient.cacheKey(for: Data(url.absoluteString.utf8))
        if token == nil, ttl > 0, let fresh = cache.read(key: key, maxAge: ttl) { return fresh }
        let interactive = AniListClient.isInteractive
        let flight = token == nil ? key : key + "|me"
        let task: Task<Data, Error>
        if let running = inFlight[flight] {
            task = running
        } else {
            task = Task { try await self.send(url: url, method: "GET", body: nil, token: token, interactive: interactive) }
            inFlight[flight] = task
        }
        do {
            let data = try await task.value
            inFlight[flight] = nil
            if token == nil { cache.write(data, key: key) }
            return data
        } catch {
            inFlight[flight] = nil
            if token == nil, let stale = cache.read(key: key, maxAge: .infinity) {
                savedAnswers += 1
                return stale
            }
            throw error
        }
    }

    /// Saved on disk, however old.
    func saved(_ path: String, query: [(String, String)] = []) -> (data: Data, age: TimeInterval)? {
        guard let url = Self.url(path, query) else { return nil }
        return cache.readWithAge(key: AniListClient.cacheKey(for: Data(url.absoluteString.utf8)))
    }

    /// A change to the viewer's library (POST, PATCH, DELETE), as the viewer.
    func change(_ path: String, method: String, body: Data?, token: String) async throws -> Data {
        guard let url = Self.url(path) else { throw TenraiClient.Failure.status(400) }
        return try await send(url: url, method: method, body: body, token: token, interactive: true)
    }

    func clearCache() {
        cache.removeAll()
    }

    private func send(url: URL, method: String, body: Data?, token: String?, interactive: Bool) async throws -> Data {
        try await waitForSlot(interactive: interactive)
        sentAt.append(Date())
        requests += 1
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            note("No answer from Kitsu: \(error.localizedDescription)")
            throw TenraiClient.Failure.network
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        switch code {
        case 200..<300:
            lastSuccess = Date()
            return data
        case 429, 503:
            let seconds = TenraiClient.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
            blockedUntil = Date().addingTimeInterval(seconds)
            note("Kitsu \(code): waiting \(Int(seconds)) s")
            throw TenraiClient.Failure.rateLimited
        default:
            if code != 404 { note("Kitsu answered \(code)") }
            throw TenraiClient.Failure.status(code)
        }
    }

    private func note(_ message: String) {
        lastFailure = Date()
        lastFailureMessage = message
    }

    private func waitForSlot(interactive: Bool) async throws {
        let deadline = Date().addingTimeInterval(interactive ? Self.longestWait : Self.longestBackgroundWait)
        if interactive { interactiveWaiting += 1 }
        defer { if interactive { interactiveWaiting -= 1 } }
        while true {
            let now = Date()
            sentAt.removeAll { now.timeIntervalSince($0) >= 60 }
            var readyAt = max(now, blockedUntil ?? now)
            readyAt = max(readyAt, AniListClient.slotTime(sent: sentAt, now: now, limit: interactive ? Self.perMinute : Self.backgroundPerMinute))
            if let last = sentAt.last { readyAt = max(readyAt, last.addingTimeInterval(Self.minimumGap)) }
            if !interactive, interactiveWaiting > 0 { readyAt = max(readyAt, now.addingTimeInterval(0.5)) }
            if readyAt <= now { return }
            guard readyAt <= deadline else { throw TenraiClient.Failure.rateLimited }
            try await Task.sleep(nanoseconds: UInt64(readyAt.timeIntervalSince(now) * 1_000_000_000) + 20_000_000)
        }
    }
}

// MARK: - JSON:API

struct KitsuDocument: Decodable, Sendable {
    var data: [KitsuResource] = []
    var included: [KitsuResource] = []
    var count: Int?

    enum CodingKeys: String, CodingKey { case data, included, meta }

    struct Meta: Decodable { var count: Int? = nil }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let many = try? container.decode([KitsuResource].self, forKey: .data) {
            data = many
        } else if let one = try? container.decode(KitsuResource.self, forKey: .data) {
            data = [one]
        }
        included = (try? container.decode([KitsuResource].self, forKey: .included)) ?? []
        count = (try? container.decode(Meta.self, forKey: .meta))?.count
    }

    var first: KitsuResource? { data.first }

    /// Included resources by type and id.
    var lookup: KitsuLookup { KitsuLookup(included + data) }
}

struct KitsuLookup: Sendable {
    private var byKey: [String: KitsuResource] = [:]

    init(_ resources: [KitsuResource] = []) {
        for resource in resources { byKey[resource.type + ":" + resource.id] = resource }
    }

    func resource(_ ref: KitsuRef) -> KitsuResource? { byKey[ref.type + ":" + ref.id] }

    func related(_ resource: KitsuResource?, _ name: String) -> [KitsuResource] {
        (resource?.relationships?[name]?.data ?? []).compactMap { self.resource($0) }
    }
}

struct KitsuResource: Decodable, Sendable {
    let id: String
    let type: String
    var attributes: KitsuAttributes?
    var relationships: [String: KitsuRelationship]?
}

struct KitsuRef: Decodable, Hashable, Sendable {
    let id: String
    let type: String
}

struct KitsuRelationship: Decodable, Sendable {
    var data: [KitsuRef] = []

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let many = try? container.decode([KitsuRef].self, forKey: .data) {
            data = many
        } else if let one = try? container.decode(KitsuRef.self, forKey: .data) {
            data = [one]
        }
    }
}

struct KitsuTitles: Decodable, Sendable {
    var en: String?
    var enJP: String?
    var enUS: String?
    var jaJP: String?

    enum CodingKeys: String, CodingKey {
        case en, enJP = "en_jp", enUS = "en_us", jaJP = "ja_jp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        en = try? container.decodeIfPresent(String.self, forKey: .en)
        enJP = try? container.decodeIfPresent(String.self, forKey: .enJP)
        enUS = try? container.decodeIfPresent(String.self, forKey: .enUS)
        jaJP = try? container.decodeIfPresent(String.self, forKey: .jaJP)
    }
}

struct KitsuImage: Decodable, Sendable {
    var tiny: String?
    var small: String?
    var medium: String?
    var large: String?
    var original: String?

    enum CodingKeys: String, CodingKey { case tiny, small, medium, large, original }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tiny = try? container.decodeIfPresent(String.self, forKey: .tiny)
        small = try? container.decodeIfPresent(String.self, forKey: .small)
        medium = try? container.decodeIfPresent(String.self, forKey: .medium)
        large = try? container.decodeIfPresent(String.self, forKey: .large)
        original = try? container.decodeIfPresent(String.self, forKey: .original)
    }
}

/// The attributes of every resource this reads (anime, genres, media relationships, characters,
/// people, library entries, users), each read on its own so one odd value spoils nothing.
struct KitsuAttributes: Decodable, Sendable {
    var canonicalTitle: String?
    var titles: KitsuTitles?
    var abbreviatedTitles: [String]?
    var synopsis: String?
    var description: String?
    var averageRating: Double?
    var startDate: String?
    var endDate: String?
    var subtype: String?
    var status: String?
    var posterImage: KitsuImage?
    var coverImage: KitsuImage?
    var image: KitsuImage?
    var episodeCount: Int?
    var episodeLength: Int?
    var youtubeVideoId: String?
    var ageRating: String?
    var nsfw: Bool?
    var name: String?
    var canonicalName: String?
    var names: KitsuTitles?
    var title: String?
    var role: String?
    var locale: String?
    var progress: Int?
    var ratingTwenty: Int?
    var slug: String?
    /// A character's or person's MyAnimeList id.
    var malId: Int?

    enum CodingKeys: String, CodingKey {
        case canonicalTitle, titles, abbreviatedTitles, synopsis, description, averageRating, startDate, endDate
        case subtype, status, posterImage, coverImage, image, episodeCount, episodeLength, youtubeVideoId
        case ageRating, nsfw, name, canonicalName, names, title, role, locale, progress, ratingTwenty, slug, malId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        canonicalTitle = value(.canonicalTitle)
        titles = value(.titles)
        abbreviatedTitles = value(.abbreviatedTitles)
        synopsis = value(.synopsis)
        description = value(.description)
        let ratingText: String? = value(.averageRating)
        let ratingNumber: Double? = value(.averageRating)
        averageRating = ratingNumber ?? ratingText.flatMap(Double.init)
        startDate = value(.startDate)
        endDate = value(.endDate)
        subtype = value(.subtype)
        status = value(.status)
        posterImage = value(.posterImage)
        coverImage = value(.coverImage)
        image = value(.image)
        episodeCount = value(.episodeCount)
        episodeLength = value(.episodeLength)
        youtubeVideoId = value(.youtubeVideoId)
        ageRating = value(.ageRating)
        nsfw = value(.nsfw)
        name = value(.name)
        canonicalName = value(.canonicalName)
        names = value(.names)
        title = value(.title)
        role = value(.role)
        locale = value(.locale)
        progress = value(.progress)
        ratingTwenty = value(.ratingTwenty)
        slug = value(.slug)
        malId = value(.malId)
    }
}

// MARK: - Kitsu as a source

/// Kitsu's titles for the engine: Kitsu entries turned into the media AniList answers with, so
/// seasons (Kitsu's prequels and sequels, with their formats), episodes (ani.zip through the
/// AniList entry it maps to), pictures, streams and the account work as for AniList.
enum KitsuSource {
    static let decoder = JSONDecoder()
    /// Every type but music videos.
    static let subtypes = "TV,OVA,ONA,movie,special"
    static let peopleTTL: TimeInterval = 24 * 3600
    static let pageSize = 20
    /// The Anime Kitsu add-on's title index: Kitsu's own search finds far less.
    static let searchIndexURL = URL(string: "https://anime-kitsu.strem.fun/search/")!

    static func document(_ data: Data) -> KitsuDocument? {
        try? decoder.decode(KitsuDocument.self, from: data)
    }

    // MARK: Entries

    /// Kitsu entries by id as media, one after another. Throws when none could be read.
    static func entries(_ ids: [Int]) async throws -> [AniListMedia] {
        var found: [AniListMedia] = []
        var failure: Error?
        var seen = Set<Int>()
        for id in ids where seen.insert(id).inserted {
            if Task.isCancelled { break }
            do {
                found.append(try await entry(id))
            } catch {
                failure = error
            }
        }
        if found.isEmpty, let failure { throw failure }
        return found
    }

    static let entryQuery: [(String, String)] = [("include", "genres,mediaRelationships.destination")]

    /// One Kitsu entry with its genres and its relations (and theirs formats, dates and
    /// pictures): the saved answer while fresh (a week finished, an hour airing), else Kitsu.
    static func entry(_ id: Int) async throws -> AniListMedia {
        let path = "anime/\(id)"
        if let saved = await KitsuClient.shared.saved(path, query: entryQuery),
           let document = Self.document(saved.data), let anime = document.first {
            let built = media(anime, lookup: document.lookup)
            let finished = built.status == "FINISHED" || built.status == "CANCELLED"
            if saved.age < (finished ? AniListService.finishedTTL : AniListService.airingTTL) {
                SourceLog.record(id, "Kitsu (saved)")
                return built
            }
        }
        let data = try await KitsuClient.shared.get(path, query: entryQuery, ttl: 0)
        guard let document = Self.document(data), let anime = document.first else { throw TenraiClient.Failure.status(0) }
        SourceLog.record(id, "Kitsu")
        return media(anime, lookup: document.lookup)
    }

    // MARK: Into AniList's shape

    static func format(_ subtype: String?) -> String? {
        switch subtype?.lowercased() {
        case "tv": return "TV"
        case "movie": return "MOVIE"
        case "ova": return "OVA"
        case "ona": return "ONA"
        case "special": return "SPECIAL"
        case "music": return "MUSIC"
        default: return nil
        }
    }

    static func status(_ text: String?) -> String? {
        switch text?.lowercased() {
        case "finished": return "FINISHED"
        case "current": return "RELEASING"
        case "upcoming", "unreleased", "tba": return "NOT_YET_RELEASED"
        default: return nil
        }
    }

    /// Kitsu's synopsis without its "(Source: …)" line and notes.
    static func synopsis(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let range = text.range(of: "\n\n(Source:") ?? text.range(of: "\n\n[Written by") ?? text.range(of: "\n\nNote:") {
            text = String(text[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func picture(_ image: KitsuImage?) -> String? {
        image?.large ?? image?.medium ?? image?.original ?? image?.small
    }

    /// An entry; `lookup` gives its genres and relations (without, a card's fields only).
    static func media(_ resource: KitsuResource, lookup: KitsuLookup = KitsuLookup(), relations: Bool = true) -> AniListMedia {
        let attributes = resource.attributes
        var media = AniListMedia(id: Int(resource.id) ?? 0)
        let isManga = resource.type == "manga"
        media.type = isManga ? "MANGA" : "ANIME"
        media.format = isManga ? nil : format(attributes?.subtype)
        media.status = status(attributes?.status)
        media.episodes = attributes?.episodeCount.flatMap { $0 > 0 ? $0 : nil }
        media.duration = attributes?.episodeLength.flatMap { $0 > 0 ? $0 : nil }
        media.averageScore = attributes?.averageRating.flatMap { $0 > 0 ? Int($0.rounded()) : nil }
        media.synonyms = attributes?.abbreviatedTitles
        media.isAdult = attributes?.nsfw == true || attributes?.ageRating == "R18"
        let titles = attributes?.titles
        media.title = AniListTitle(
            romaji: titles?.enJP ?? attributes?.canonicalTitle,
            english: titles?.en ?? titles?.enUS,
            native: titles?.jaJP
        )
        media.coverImage = AniListCoverImage(large: picture(attributes?.posterImage))
        media.description = synopsis(attributes?.synopsis ?? attributes?.description)
        media.startDate = MALSource.date(attributes?.startDate)
        media.endDate = MALSource.date(attributes?.endDate)
        media.seasonYear = media.startDate?.year
        media.trailer = attributes?.youtubeVideoId.flatMap { $0.isEmpty ? nil : AniListTrailer(id: $0, site: "youtube") }
        let genres = lookup.related(resource, "genres").compactMap { $0.attributes?.name ?? $0.attributes?.title }
        if !genres.isEmpty { media.genres = genres }
        if relations {
            let edges = lookup.related(resource, "mediaRelationships").compactMap { relationship -> AniListRelationEdge? in
                guard let destination = lookup.related(relationship, "destination").first else { return nil }
                let node = Self.media(destination, lookup: lookup, relations: false)
                return AniListRelationEdge(relationType: MALSource.relationType(relationship.attributes?.role), node: node)
            }
            media.relations = AniListRelationConnection(edges: edges)
        }
        return media
    }

    /// Kitsu cards (catalogs, search, lists), in their order, each title once.
    static func cards(_ resources: [KitsuResource], language: AniListSettings.TitleLanguage) -> [NuvioMeta] {
        var seen = Set<String>()
        let unique = resources.filter { $0.type == "anime" && seen.insert($0.id).inserted }
        let adult = KitsuSettings.showsAdult
        return AnimeSource.$current.withValue(.kitsu) {
            unique.map { media($0, relations: false) }
                .filter { adult || $0.isAdult != true }
                .map { AniListMetaBuilder.card($0, language: language) }
        }
    }

    // MARK: Search

    /// Kitsu's results for Search: the Anime Kitsu add-on's title index, else Kitsu's own search.
    static func search(_ query: String) async -> AniListService.SearchResult {
        guard KitsuSettings.searchesKitsu else { return .empty }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let quoted = "“\(trimmed)”"
        var resources: [KitsuResource] = []
        var answeredBy = "Anime Kitsu index"
        do {
            let ids = try await indexIDs(trimmed)
            if !ids.isEmpty {
                let data = try await AniListClient.$isInteractive.withValue(true) {
                    try await KitsuClient.shared.get(
                        "anime",
                        query: [("filter[id]", ids.joined(separator: ",")), ("page[limit]", String(pageSize))],
                        ttl: AniListService.searchTTL
                    )
                }
                let byID = Dictionary((document(data)?.data ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                resources = ids.compactMap { byID[$0] }
            }
        } catch {
            answeredBy = "Kitsu"
            do {
                let data = try await AniListClient.$isInteractive.withValue(true) {
                    try await KitsuClient.shared.get(
                        "anime",
                        query: [("filter[text]", trimmed), ("filter[subtype]", subtypes), ("page[limit]", String(pageSize))],
                        ttl: AniListService.searchTTL
                    )
                }
                resources = document(data)?.data ?? []
            } catch {
                AniListDiagnostics.note(.kitsu, "Search \(quoted): failed · \(MALSource.describe(error))")
                return .failure
            }
        }
        let language = AniListSettings.titleLanguage
        let items = cards(resources, language: language)
        AniListDiagnostics.note(.kitsu, "Search \(quoted): \(items.count) results · \(answeredBy)")
        var names: [(name: String, year: Int?)] = []
        for resource in resources {
            let entry = media(resource, relations: false)
            let year = AniListMetaBuilder.year(entry)
            for title in [entry.title?.romaji, entry.title?.english, entry.title?.native, resource.attributes?.canonicalTitle] {
                let key = AniListService.matchKey(title ?? "")
                if !key.isEmpty { names.append((name: key, year: year)) }
            }
        }
        return AniListService.SearchResult(items: items, names: names)
    }

    /// The Kitsu ids the Anime Kitsu add-on's index finds, best first. Throws when it can't answer.
    static func indexIDs(_ query: String) async throws -> [String] {
        struct Answer: Decodable { var ids: [String]? = nil }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))),
              let url = URL(string: searchIndexURL.absoluteString + encoded + ".json") else { throw TenraiClient.Failure.status(400) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw TenraiClient.Failure.status(0) }
        return Array((answer.ids ?? []).prefix(pageSize))
    }

    // MARK: Cast and recommendations

    /// Characters with their Japanese voice actors from Kitsu (with MyAnimeList's pictures of
    /// them), and MyAnimeList's recommendations (Kitsu has none) as Kitsu titles, through the
    /// offline tables.
    static func extras(entryID id: Int, language: AniListSettings.TitleLanguage) async -> (people: [TmdbPersonMetadata], recommendations: [RelatedTitle]) {
        async let pictures = malPictures(kitsuEntry: id)
        let data = try? await AniListClient.$isInteractive.withValue(true) {
            try await KitsuClient.shared.get(
                "anime/\(id)/characters",
                query: [("include", "character,voices.person"), ("page[limit]", String(pageSize))],
                ttl: peopleTTL
            )
        }
        let malFound = await pictures
        let cast = data.flatMap { Self.document($0) }.map { people(from: $0, malPictures: malFound) } ?? []
        return (cast, await recommendations(entryID: id))
    }

    /// MyAnimeList's pictures of a title's characters and voice actors, by their MAL ids.
    struct MALPictures: Sendable {
        var characters: [Int: String] = [:]
        var people: [Int: String] = [:]
    }

    /// The pictures of the cast of the MAL entry a Kitsu entry maps to (one request, kept a day):
    /// Kitsu's own are often missing (a blank figure) or pale, MAL's are the ones AniList and MAL
    /// titles show.
    static func malPictures(kitsuEntry id: Int) async -> MALPictures {
        let maps = AniListOfflineMaps.shared
        guard let aniList = await maps.aniListID(kitsu: id),
              let mal = await maps.entry(aniListID: aniList)?.mal, mal > 0,
              let data = try? await AniListClient.$isInteractive.withValue(true, operation: {
                  try await TenraiClient.shared.get("anime/\(mal)/characters", ttl: MALSource.peopleTTL)
              }) else { return MALPictures() }
        return malPictures(from: data)
    }

    static func malPictures(from data: Data) -> MALPictures {
        let roles = (try? MALSource.decoder.decode(TenraiMany<TenraiCharacterRole>.self, from: data).data) ?? []
        func real(_ images: TenraiImages?) -> String? {
            // MAL's "no picture" stand-ins.
            guard let url = MALSource.picture(images), !url.contains("questionmark"), !url.contains("apple-touch-icon") else { return nil }
            return url
        }
        var pictures = MALPictures()
        for role in roles {
            if let character = role.character, let url = real(character.images) {
                pictures.characters[character.malId] = url
            }
            for actor in role.voiceActors ?? [] {
                if let person = actor.person, let url = real(person.images) {
                    pictures.people[person.malId] = url
                }
            }
        }
        return pictures
    }

    /// The cast of `anime/{id}/characters`: main characters first, each with their Japanese
    /// voice actor, whose Kitsu page the card opens; MyAnimeList's pictures where it has them.
    static func people(from document: KitsuDocument, malPictures: MALPictures = MALPictures()) -> [TmdbPersonMetadata] {
        let lookup = document.lookup
        let roles = document.data.filter { $0.type == "mediaCharacters" }
        let ordered = roles.filter { $0.attributes?.role == "main" } + roles.filter { $0.attributes?.role != "main" }
        return ordered.compactMap { role -> TmdbPersonMetadata? in
            guard let character = lookup.related(role, "character").first,
                  let name = characterName(character) else { return nil }
            let voices = lookup.related(role, "voices")
            let voice = voices.first { $0.attributes?.locale == "ja_jp" } ?? voices.first
            let actor = lookup.related(voice, "person").first
            let actorName = actor?.attributes?.name
            let characterPicture = character.attributes?.malId.flatMap { malPictures.characters[$0] }
            let actorPicture = actor?.attributes?.malId.flatMap { malPictures.people[$0] }
            var person = TmdbPersonMetadata(
                name: name,
                role: actorName ?? (role.attributes?.role == "main" ? "Main" : "Supporting"),
                profileURL: characterPicture ?? picture(character.attributes?.image),
                tmdbId: nil,
                aniListCharacterID: Int(character.id),
                aniListStaffID: actorName == nil ? nil : actor.flatMap { Int($0.id) },
                aniListStaffImage: actorPicture ?? picture(actor?.attributes?.image)
            )
            person.peopleSource = AnimeSource.kitsu.rawValue
            return person
        }
    }

    static func characterName(_ character: KitsuResource) -> String? {
        let attributes = character.attributes
        let name = attributes?.canonicalName ?? attributes?.names?.en ?? attributes?.name
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// MyAnimeList's recommendations for the MAL entry this one maps to, as Kitsu titles.
    static func recommendations(entryID id: Int) async -> [RelatedTitle] {
        let maps = AniListOfflineMaps.shared
        guard let aniList = await maps.aniListID(kitsu: id),
              let mal = await maps.entry(aniListID: aniList)?.mal,
              let data = try? await AniListClient.$isInteractive.withValue(true, operation: {
                  try await TenraiClient.shared.get("anime/\(mal)/recommendations", ttl: MALSource.peopleTTL)
              }) else { return [] }
        var titles: [RelatedTitle] = []
        for ref in MALSource.recommendationRefs(from: data).prefix(30) {
            guard let entry = await maps.aniListID(mal: ref.malId) else { continue }
            let offline = await maps.entry(aniListID: entry)
            guard let kitsu = offline?.kitsu else { continue }
            let isMovie = offline?.type?.uppercased() == "MOVIE"
            titles.append(RelatedTitle(
                id: AnimeSource.kitsu.prefix + String(kitsu),
                type: isMovie ? "movie" : "series",
                name: ref.title ?? "",
                posterURL: MALSource.picture(ref.images),
                year: nil,
                rating: nil,
                overview: nil
            ))
            if titles.count >= 20 { break }
        }
        return titles
    }

    // MARK: People

    /// A voice actor as AniList's people page reads one: their roles from Kitsu.
    static func staff(_ id: Int) async -> AniListStaff? {
        guard let data = try? await AniListClient.$isInteractive.withValue(true, operation: {
            try await KitsuClient.shared.get(
                "people/\(id)",
                query: [("include", "voices.mediaCharacter.media,voices.mediaCharacter.character")],
                ttl: peopleTTL
            )
        }), let document = Self.document(data), let person = document.first else { return nil }
        let lookup = document.lookup
        var order: [String] = []
        var byMedia: [String: (media: KitsuResource, characters: [String])] = [:]
        for voice in lookup.related(person, "voices") where voice.attributes?.locale == nil || voice.attributes?.locale == "ja_jp" {
            guard let role = lookup.related(voice, "mediaCharacter").first,
                  let anime = lookup.related(role, "media").first, anime.type == "anime" else { continue }
            if byMedia[anime.id] == nil {
                guard order.count < 150 else { continue }
                order.append(anime.id)
                byMedia[anime.id] = (anime, [])
            }
            if let character = lookup.related(role, "character").first, let name = characterName(character),
               byMedia[anime.id]?.characters.contains(name) == false {
                byMedia[anime.id]?.characters.append(name)
            }
        }
        let edges = order.compactMap { key -> AniListRoleEdge? in
            guard let found = byMedia[key] else { return nil }
            return AniListRoleEdge(
                characterRole: nil,
                characters: found.characters.map { AniListPerson(name: AniListName(full: $0)) },
                node: media(found.media, relations: false)
            )
        }
        return AniListStaff(
            id: Int(person.id) ?? id,
            name: AniListName(full: person.attributes?.name, native: nil),
            image: AniListImage(large: picture(person.attributes?.image)),
            description: person.attributes?.description,
            characterMedia: AniListRoleConnection(edges: edges)
        )
    }

    /// A character as AniList's people page reads one: the anime they are in, from Kitsu.
    static func character(_ id: Int) async -> AniListCharacter? {
        guard let data = try? await AniListClient.$isInteractive.withValue(true, operation: {
            try await KitsuClient.shared.get("characters/\(id)", query: [("include", "mediaCharacters.media")], ttl: peopleTTL)
        }), let document = Self.document(data), let character = document.first else { return nil }
        let lookup = document.lookup
        let edges = lookup.related(character, "mediaCharacters").compactMap { role -> AniListRoleEdge? in
            guard let anime = lookup.related(role, "media").first, anime.type == "anime" else { return nil }
            return AniListRoleEdge(characterRole: role.attributes?.role?.uppercased(), characters: nil, node: media(anime, relations: false))
        }
        return AniListCharacter(
            id: Int(character.id) ?? id,
            name: AniListName(full: characterName(character), native: character.attributes?.names?.jaJP),
            image: AniListImage(large: picture(character.attributes?.image)),
            description: character.attributes?.description,
            media: AniListRoleConnection(edges: edges)
        )
    }

    // MARK: Status

    enum SourceLog {
        private static let lock = NSLock()
        private static var sources: [Int: String] = [:]

        static func record(_ id: Int, _ source: String) {
            lock.lock()
            defer { lock.unlock() }
            if sources.count > 500 { sources.removeAll() }
            sources[id] = source
        }

        static func summary(_ ids: [Int]) -> String {
            lock.lock()
            let known = ids.compactMap { sources[$0] }
            lock.unlock()
            var counts: [String: Int] = [:]
            for source in known { counts[source, default: 0] += 1 }
            guard !counts.isEmpty else { return "kept in memory" }
            return counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        }
    }

    static func statusText() async -> String {
        let client = KitsuClient.shared
        let requests = await client.requests
        let saved = await client.savedAnswers
        let success = await client.lastSuccess
        let failure = await client.lastFailure
        let message = await client.lastFailureMessage
        func at(_ date: Date) -> String {
            DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        var parts = ["Kitsu: \(requests) requests"]
        if saved > 0 { parts.append("\(saved) saved answers used") }
        if let success { parts.append("last answer \(at(success))") }
        if let failure, failure > (success ?? .distantPast) { parts.append("error at \(at(failure)): \(message ?? "?")") }
        return parts.joined(separator: " · ")
    }

    /// Asks the Anime Kitsu index and Kitsu for Frieren now, past the saved answers.
    static func testConnection() async -> String {
        var lines: [String] = []
        do {
            let ids = try await indexIDs("Frieren")
            lines.append("Anime Kitsu index OK · \(ids.count) results")
        } catch {
            lines.append("Anime Kitsu index failed: \(MALSource.describe(error))")
        }
        do {
            let data = try await AniListClient.$isInteractive.withValue(true) {
                try await KitsuClient.shared.get("anime", query: [("filter[text]", "Frieren"), ("page[limit]", "5")], ttl: 0)
            }
            lines.append("Kitsu OK · \(document(data)?.data.count ?? 0) results")
        } catch {
            lines.append("Kitsu failed: \(MALSource.describe(error))")
        }
        return lines.joined(separator: " · ")
    }

    static func clearCache() async {
        await KitsuClient.shared.clearCache()
    }
}
