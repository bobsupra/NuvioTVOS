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
struct JellyfinMediaItem: Equatable {
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

/// Thin REST client for one Jellyfin server. Stateless beyond the
/// credentials it's constructed with; `JellyfinSessionManager` owns the
/// actual per-server connection lifecycle. See the [Jellyfin API
/// docs](https://api.jellyfin.org) for the endpoints used here.
struct JellyfinClient {
    let baseURL: URL
    let accessToken: String

    private static let deviceId = "NuvioTV-AppleTV"
    private static let authorizationHeader = "MediaBrowser Client=\"Nuvio\", Device=\"Apple TV\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
    private static let itemFields = "Overview,ProductionYear,PremiereDate,CommunityRating,OfficialRating,Genres,RunTimeTicks,ProviderIds,MediaSources,ParentIndexNumber,IndexNumber,SeriesId,People"

    struct AuthResult {
        let userId: String
        let accessToken: String
    }

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Authentication (no instance needed yet)

    static func authenticate(baseURL: URL, username: String, password: String) async throws -> AuthResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])

        let (data, response) = try await URLSession.shared.data(for: request)
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
    /// needs it. An API key authenticates as whichever account generated it.
    static func currentUserId(baseURL: URL, apiKey: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("Users/Me"))
        request.setValue(apiKey, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        struct Payload: Decodable { let Id: String }
        return try JSONDecoder().decode(Payload.self, from: data).Id
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

    /// Every movie, series, and episode under one library, with every field
    /// `JellyfinLibraryResolver` needs to build display metadata and a
    /// playable file locally — no second request per title. Jellyfin
    /// returns the whole recursive listing in one response — no paging loop
    /// needed for libraries in the size a home NAS/server realistically hosts.
    func items(userId: String, libraryId: String) async throws -> [JellyfinMediaItem] {
        let (data, response) = try await get("Users/\(userId)/Items", query: [
            "ParentId": libraryId,
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,Episode",
            "Fields": Self.itemFields,
            "EnableImages": "true"
        ])
        try Self.validate(response, data: data)

        struct Payload: Decodable {
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
                let ItemType: String
            }
            let Items: [Item]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.Items.map { item in
            JellyfinMediaItem(
                id: item.Id,
                name: item.Name,
                type: item.ItemType,
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
                seriesId: item.SeriesId,
                parentIndexNumber: item.ParentIndexNumber,
                indexNumber: item.IndexNumber,
                container: item.MediaSources?.first?.Container,
                sizeBytes: item.MediaSources?.first?.Size
            )
        }
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
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        return try await URLSession.shared.data(for: request)
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
