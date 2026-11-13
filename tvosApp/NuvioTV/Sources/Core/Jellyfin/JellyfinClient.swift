import Foundation

/// One library ("View") on a Jellyfin server — Movies, TV Shows, etc.
struct JellyfinLibrary: Identifiable, Equatable {
    let id: String
    let name: String
    let collectionType: String?
}

/// One item returned by a library items query. Jellyfin returns `Movie`,
/// `Series`, and `Episode` items through the same shape, with type-dependent
/// fields left `nil` — a `Series` carries the poster/overview/rating shown on
/// its card but no `MediaSources`; an `Episode` carries the playable file
/// but usually has neither its own rich overview nor a poster worth using
/// over its series'. `JellyfinLibraryResolver` groups these locally; nothing
/// here is looked up against any other metadata source — the whole point of
/// fetching this many fields directly is that Jellyfin never needs to be.
struct JellyfinMediaItem: Codable, Equatable {
    let id: String
    let name: String
    /// `"Movie"`, `"Series"`, or `"Episode"`.
    let type: String
    let overview: String?
    let productionYear: Int?
    let premiereDate: String?
    let communityRating: Double?
    let officialRating: String?
    let genres: [String]?
    /// 100ns units, straight from the API; converted to minutes for display
    /// where it's used.
    let runTimeTicks: Int64?
    let imdbId: String?
    let tmdbId: Int?
    let primaryImageTag: String?
    let backdropImageTag: String?
    let cast: [String]?
    let directors: [String]?
    /// Set only on `Episode` items — the parent `Series`' id, so an episode
    /// can be attached to its series' title without a second round trip.
    let seriesId: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let container: String?
    let sizeBytes: Int64?
}

struct JellyfinItemsPage {
    let items: [JellyfinMediaItem]
    let startIndex: Int
    let nextStartIndex: Int
    let totalRecordCount: Int?
}

/// Thin REST client for one Jellyfin server. Stateless beyond the
/// credentials it's constructed with; `JellyfinSessionManager` owns the
/// actual per-server connection lifecycle. See the [Jellyfin API
/// docs](https://api.jellyfin.org) for the endpoints used here.
struct JellyfinClient {
    let baseURL: URL
    let accessToken: String
    private let session: URLSession

    private static let deviceId = "NuvioTV-AppleTV"
    private static let itemFields = "Overview,ProductionYear,PremiereDate,CommunityRating,OfficialRating,Genres,RunTimeTicks,ProviderIds,MediaSources,ParentIndexNumber,IndexNumber,SeriesId,People"

    init(baseURL: URL, accessToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    struct AuthResult {
        let userId: String
        let accessToken: String
    }

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Headers

    private static func authorizationHeader(token: String? = nil) -> String {
        var header = "MediaBrowser Client=\"Nuvio\", Device=\"Apple TV\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
        if let token, !token.isEmpty {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    // MARK: - Authentication (no instance needed yet)

    static func authenticate(baseURL: URL, username: String, password: String, session: URLSession = .shared) async throws -> AuthResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        struct Payload: Decodable {
            struct User: Decodable { let Id: String }
            let User: User
            let AccessToken: String
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return AuthResult(userId: payload.User.Id, accessToken: payload.AccessToken)
    }

    /// Resolves the user id for a raw API key, since every other endpoint
    /// needs it. Jellyfin API keys are server-level tokens (not user-bound),
    /// so we first check `/Users/Me` (Emby / session token behavior) and
    /// fallback to `/Users` to find the server admin or matching user.
    static func currentUserId(baseURL: URL, apiKey: String, username: String? = nil, session: URLSession = .shared) async throws -> String {
        // 1. Try `/Users/Me` first (standard for Emby or user-bound tokens).
        var meRequest = URLRequest(url: baseURL.appendingPathComponent("Users/Me"))
        meRequest.setValue(authorizationHeader(token: apiKey), forHTTPHeaderField: "Authorization")
        if let (data, response) = try? await session.data(for: meRequest),
           let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                throw ClientError(message: L10n.string("jellyfin_error_unauthorized", fallback: "Invalid API key or credentials"))
            }
            if (200...299).contains(http.statusCode) {
                struct MePayload: Decodable { let Id: String }
                if let payload = try? JSONDecoder().decode(MePayload.self, from: data), !payload.Id.isEmpty {
                    return payload.Id
                }
            }
        }

        // 2. Fallback to `/Users` (Jellyfin admin API keys).
        var usersRequest = URLRequest(url: baseURL.appendingPathComponent("Users"))
        usersRequest.setValue(authorizationHeader(token: apiKey), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: usersRequest)
        try Self.validate(response, data: data)

        struct UserPayload: Decodable {
            struct Policy: Decodable {
                let IsAdministrator: Bool?
            }
            let Id: String
            let Name: String?
            let Policy: Policy?
        }
        let users = try JSONDecoder().decode([UserPayload].self, from: data)
        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty,
           let matched = users.first(where: { $0.Name?.localizedCaseInsensitiveCompare(username) == .orderedSame }) {
            return matched.Id
        }
        if let adminUser = users.first(where: { $0.Policy?.IsAdministrator == true }) {
            return adminUser.Id
        }
        if let firstUser = users.first {
            return firstUser.Id
        }
        throw ClientError(message: L10n.string("jellyfin_error_no_users", fallback: "No users found on server"))
    }

    // MARK: - Instance calls

    /// Round-trips `/System/Info` so a silently invalid token or unreachable
    /// host surfaces as a failure rather than a stale "Connected" state.
    func ping() async throws {
        let (data, response) = try await get("System/Info")
        try Self.validate(response, data: data)
    }

    func libraries(userId: String) async throws -> [JellyfinLibrary] {
        let (data, response) = try await get("Users/\(userId)/Views")
        try Self.validate(response, data: data)
        struct Payload: Decodable {
            struct Item: Decodable {
                let Id: String
                let Name: String
                let CollectionType: String?
            }
            let Items: [Item]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.Items.map { JellyfinLibrary(id: $0.Id, name: $0.Name, collectionType: $0.CollectionType) }
    }

    private struct ItemsPayload: Decodable {
        struct ProviderIds: Decodable {
            let Imdb: String?
            let Tmdb: String?
        }
        struct MediaSource: Decodable {
            let Container: String?
            let Size: Int64?
        }
        struct Person: Decodable {
            let Name: String
            let PersonType: String?
        }
        struct ImageTags: Decodable {
            let Primary: String?
        }
        struct Item: Decodable {
            let Id: String
            let Name: String
            let Overview: String?
            let ProductionYear: Int?
            let PremiereDate: String?
            let CommunityRating: Double?
            let OfficialRating: String?
            let Genres: [String]?
            let RunTimeTicks: Int64?
            let ProviderIds: ProviderIds?
            let MediaSources: [MediaSource]?
            let ParentIndexNumber: Int?
            let IndexNumber: Int?
            let SeriesId: String?
            let People: [Person]?
            let ImageTags: ImageTags?
            let BackdropImageTags: [String]?

            enum CodingKeys: String, CodingKey {
                case Id, Name, Overview, ProductionYear, PremiereDate, CommunityRating, OfficialRating
                case Genres, RunTimeTicks, ProviderIds, MediaSources, ParentIndexNumber, IndexNumber
                case SeriesId, People, ImageTags, BackdropImageTags
                case ItemType = "Type"
            }
            let ItemType: String?
        }

        let Items: [Item]
        let TotalRecordCount: Int?
        let StartIndex: Int?

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                Items = try container.decode([Item].self, forKey: .Items)
                TotalRecordCount = try container.decodeIfPresent(Int.self, forKey: .TotalRecordCount)
                StartIndex = try container.decodeIfPresent(Int.self, forKey: .StartIndex)
            } else {
                let singleContainer = try decoder.singleValueContainer()
                Items = try singleContainer.decode([Item].self)
                // A bare array has no pagination metadata. Its length is only
                // this response's page size, not the server's full result count.
                TotalRecordCount = nil
                StartIndex = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case Items, TotalRecordCount, StartIndex
        }
    }

    private static func mapMediaItem(
        _ item: ItemsPayload.Item,
        fallbackSeriesId: String? = nil,
        fallbackType: String = "Movie"
    ) -> JellyfinMediaItem {
        let rawType = item.ItemType ?? fallbackType
        let normalizedType: String
        if rawType.caseInsensitiveCompare("Series") == .orderedSame {
            normalizedType = "Series"
        } else if rawType.caseInsensitiveCompare("Episode") == .orderedSame {
            normalizedType = "Episode"
        } else if rawType.caseInsensitiveCompare("Movie") == .orderedSame {
            normalizedType = "Movie"
        } else {
            normalizedType = rawType
        }

        return JellyfinMediaItem(
            id: item.Id,
            name: item.Name,
            type: normalizedType,
            overview: item.Overview,
            productionYear: item.ProductionYear,
            premiereDate: item.PremiereDate,
            communityRating: item.CommunityRating,
            officialRating: item.OfficialRating,
            genres: item.Genres,
            runTimeTicks: item.RunTimeTicks,
            imdbId: item.ProviderIds?.Imdb,
            tmdbId: item.ProviderIds?.Tmdb.flatMap(Int.init),
            primaryImageTag: item.ImageTags?.Primary,
            backdropImageTag: item.BackdropImageTags?.first,
            cast: item.People?.filter { $0.PersonType == "Actor" }.map(\.Name),
            directors: item.People?.filter { $0.PersonType == "Director" }.map(\.Name),
            seriesId: item.SeriesId ?? fallbackSeriesId,
            parentIndexNumber: item.ParentIndexNumber,
            indexNumber: item.IndexNumber,
            container: item.MediaSources?.first?.Container,
            sizeBytes: item.MediaSources?.first?.Size
        )
    }

    /// Every movie, series, and episode under one library, with every field
    /// `JellyfinLibraryResolver` needs to build display metadata and a
    /// playable file locally — no second request per title.
    /// Paginates through all results using `StartIndex` and `Limit` so servers
    /// with default page sizes (such as Silo or paginated Jellyfin instances)
    /// import complete libraries rather than only the first page.
    func items(
        userId: String,
        libraryId: String,
        onPageFetched: ((Int) -> Void)? = nil
    ) async throws -> [JellyfinMediaItem] {
        try await fetchItems(userId: userId, libraryId: libraryId, startingAt: 0, seenItemIDs: []) { page in
            onPageFetched?(page.nextStartIndex)
        }
    }

    /// Fetches pages starting at a saved server offset. The callback runs
    /// after each response page has been decoded and mapped, so callers can
    /// durably record it before another request begins.
    func items(
        userId: String,
        libraryId: String,
        startingAt: Int,
        seenItemIDs: Set<String> = [],
        onPageFetched: ((JellyfinItemsPage) throws -> Void)? = nil
    ) async throws -> [JellyfinMediaItem] {
        try await fetchItems(userId: userId, libraryId: libraryId, startingAt: startingAt, seenItemIDs: seenItemIDs, onPageFetched: onPageFetched)
    }

    private func fetchItems(
        userId: String,
        libraryId: String,
        startingAt initialStartIndex: Int,
        seenItemIDs initialSeenItemIDs: Set<String>,
        onPageFetched: ((JellyfinItemsPage) throws -> Void)?
    ) async throws -> [JellyfinMediaItem] {
        var allItems: [JellyfinMediaItem] = []
        var seenIds = initialSeenItemIDs
        var startIndex = max(0, initialStartIndex)
        let pageSize = 100

        for _ in 0..<500 {
            try Task.checkCancellation()

            let (data, response) = try await get("Users/\(userId)/Items", query: [
                "ParentId": libraryId,
                "Recursive": "true",
                "IncludeItemTypes": "Movie,Series,Episode",
                "Fields": Self.itemFields,
                "EnableImages": "true",
                "StartIndex": String(startIndex),
                "Limit": String(pageSize)
            ])
            try Self.validate(response, data: data)

            let payload = try JSONDecoder().decode(ItemsPayload.self, from: data)
            if let reportedStartIndex = payload.StartIndex, reportedStartIndex != startIndex {
                throw ClientError(message: "The server returned a library page for the wrong offset")
            }
            if payload.Items.isEmpty {
                return allItems
            }

            let pageItems = payload.Items.compactMap { item -> JellyfinMediaItem? in
                guard !seenIds.contains(item.Id) else { return nil }
                seenIds.insert(item.Id)
                return Self.mapMediaItem(item)
            }

            guard !pageItems.isEmpty else {
                throw ClientError(message: "The server repeated a library page without advancing results")
            }

            allItems.append(contentsOf: pageItems)
            let nextStartIndex = startIndex + payload.Items.count
            try onPageFetched?(JellyfinItemsPage(
                items: pageItems,
                startIndex: startIndex,
                nextStartIndex: nextStartIndex,
                totalRecordCount: payload.TotalRecordCount
            ))
            startIndex = nextStartIndex

            if let total = payload.TotalRecordCount, startIndex >= total {
                return allItems
            }
        }

        throw ClientError(message: "The server library exceeded the 500-page sync limit")
    }

    /// All episodes under one TV series, fetched hierarchically.
    /// Paginates results to handle large series and servers (such as Silo)
    /// that do not return Episode items in the top-level recursive library query.
    func episodes(
        seriesId: String,
        userId: String? = nil,
        onPageFetched: ((Int) -> Void)? = nil
    ) async throws -> [JellyfinMediaItem] {
        try await fetchEpisodes(seriesId: seriesId, userId: userId, startingAt: 0, seenItemIDs: []) { page in
            onPageFetched?(page.nextStartIndex)
        }
    }

    func episodes(
        seriesId: String,
        userId: String? = nil,
        startingAt: Int,
        seenItemIDs: Set<String> = [],
        onPageFetched: ((JellyfinItemsPage) throws -> Void)? = nil
    ) async throws -> [JellyfinMediaItem] {
        try await fetchEpisodes(seriesId: seriesId, userId: userId, startingAt: startingAt, seenItemIDs: seenItemIDs, onPageFetched: onPageFetched)
    }

    private func fetchEpisodes(
        seriesId: String,
        userId: String?,
        startingAt initialStartIndex: Int,
        seenItemIDs initialSeenItemIDs: Set<String>,
        onPageFetched: ((JellyfinItemsPage) throws -> Void)?
    ) async throws -> [JellyfinMediaItem] {
        var allEpisodes: [JellyfinMediaItem] = []
        var seenIds = initialSeenItemIDs
        var startIndex = max(0, initialStartIndex)
        let pageSize = 100

        for _ in 0..<500 {
            try Task.checkCancellation()

            var query: [String: String] = [
                "Fields": Self.itemFields,
                "EnableImages": "true",
                "StartIndex": String(startIndex),
                "Limit": String(pageSize)
            ]
            if let userId, !userId.isEmpty {
                query["userId"] = userId
            }

            let (data, response) = try await get("Shows/\(seriesId)/Episodes", query: query)
            try Self.validate(response, data: data)

            let payload = try JSONDecoder().decode(ItemsPayload.self, from: data)
            if let reportedStartIndex = payload.StartIndex, reportedStartIndex != startIndex {
                throw ClientError(message: "The server returned an episode page for the wrong offset")
            }
            if payload.Items.isEmpty {
                return allEpisodes
            }

            let pageItems = payload.Items.compactMap { item -> JellyfinMediaItem? in
                guard !seenIds.contains(item.Id) else { return nil }
                seenIds.insert(item.Id)
                return Self.mapMediaItem(item, fallbackSeriesId: seriesId, fallbackType: "Episode")
            }

            guard !pageItems.isEmpty else {
                throw ClientError(message: "The server repeated an episode page without advancing results")
            }

            allEpisodes.append(contentsOf: pageItems)
            let nextStartIndex = startIndex + payload.Items.count
            try onPageFetched?(JellyfinItemsPage(
                items: pageItems,
                startIndex: startIndex,
                nextStartIndex: nextStartIndex,
                totalRecordCount: payload.TotalRecordCount
            ))
            startIndex = nextStartIndex

            if let total = payload.TotalRecordCount, startIndex >= total {
                return allEpisodes
            }
        }

        throw ClientError(message: "The server episode list exceeded the 500-page sync limit")
    }

    // MARK: - Media URLs

    /// `{baseURL}/Items/{itemId}/Images/{type}?tag=...&api_key=...` — the
    /// same image Jellyfin's own web/TV clients show, so a poster the user
    /// picked manually in Jellyfin is exactly what appears on Home too.
    static func imageURL(baseURL: URL, itemId: String, imageType: String, tag: String?, accessToken: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("Items/\(itemId)/Images/\(imageType)"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "api_key", value: accessToken)]
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        components?.queryItems = query
        return components?.url
    }

    // MARK: - Plumbing

    private func get(_ path: String, query: [String: String] = [:]) async throws -> (Data, URLResponse) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw ClientError(message: "Invalid request URL")
        }
        var request = URLRequest(url: url)
        request.setValue(Self.authorizationHeader(token: accessToken), forHTTPHeaderField: "Authorization")
        return try await session.data(for: request)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError(message: "No response from server")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw ClientError(message: L10n.string("jellyfin_error_unauthorized", fallback: "Invalid API key or credentials"))
            }
            throw ClientError(message: L10n.format("jellyfin_error_status", fallback: "Server returned status %d", http.statusCode))
        }
    }
}
