import Foundation

/// One library section on a Plex Media Server: Movies, TV Shows, etc.
struct PlexLibrary: Identifiable, Equatable {
    let id: String
    let name: String
    /// `"movie"` or `"show"`. Other section types (music, photos) are listed
    /// by the server but never synced.
    let type: String
    /// Changes whenever the library's contents do (items added, removed, or
    /// re-matched), so an unchanged library needn't be listed again.
    var changeMarker: String? = nil
}

/// One Plex Media Server the signed-in account can reach, as plex.tv's
/// resources endpoint describes it.
struct PlexResource: Equatable {
    struct Connection: Equatable {
        let uri: String
        let address: String
        let port: Int
        let protocolName: String
        let isLocal: Bool
        let isRelay: Bool
    }

    let name: String
    /// The server's machine identifier. Stable across restarts and address
    /// changes, so it doubles as Nuvio's server id.
    let clientIdentifier: String
    /// Token for this server. Equal to the account token for servers the
    /// account owns; a separate token for servers shared with it.
    let accessToken: String?
    let isOwned: Bool
    let connections: [Connection]
}

/// One playable file of a movie or episode. An item has several when the
/// library holds more than one version (4K and 1080p) or a split file.
struct PlexFile: Codable, Equatable {
    /// `/library/parts/<id>/<ts>/file.<ext>`.
    let partKey: String
    let container: String?
    let sizeBytes: Int64?
    /// What sets this file apart, for the stream list: "4K · 18.2 Mbps", "Part 2 of 2".
    let label: String?
    /// What Plex knows about the file's video and audio, for the stream list.
    var details: PlexFileDetails? = nil
}

/// A file's format as Plex's library listing reports it.
struct PlexFileDetails: Codable, Equatable {
    /// `"1080"`, `"4k"`, `"sd"`.
    var videoResolution: String? = nil
    var videoCodec: String? = nil
    var audioCodec: String? = nil
    var audioChannels: Int? = nil
    var bitrateKbps: Int? = nil
    /// The file's name on the server, without its folders.
    var fileName: String? = nil
    /// Set on parts of a split file: "Part 2 of 2".
    var part: String? = nil
}

/// One movie, show, or episode from a section listing. Plex returns all three
/// through the same `Metadata` shape with type-dependent fields left `nil`.
struct PlexMediaItem: Codable, Equatable {
    let ratingKey: String
    /// `"movie"`, `"show"`, or `"episode"`.
    let type: String
    let title: String
    let summary: String?
    let year: Int?
    let originallyAvailableAt: String?
    let rating: Double?
    let contentRating: String?
    let durationMs: Int64?
    let thumb: String?
    let art: String?
    let genres: [String]?
    let cast: [String]?
    let directors: [String]?
    let imdbId: String?
    let tmdbId: Int?
    /// Episodes only: the parent show's rating key, season, and episode number.
    let showRatingKey: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    /// The first playable file: `/library/parts/<id>/<ts>/file.<ext>`.
    let partKey: String?
    let container: String?
    let sizeBytes: Int64?
    /// The account's watch state: resume position, play count, and when it was
    /// last played (Unix seconds). Absent fields mean unwatched.
    var viewOffsetMs: Int64? = nil
    var viewCount: Int? = nil
    var lastViewedAt: Int64? = nil
    /// Every file of the item, the first one included.
    var files: [PlexFile] = []
}

/// Thin client for plex.tv (sign-in, server discovery) and for one Plex Media
/// Server (libraries, items, playback state). Stateless beyond the base URL and
/// token it's constructed with; `PlexSessionManager` owns connection lifecycle.
struct PlexClient {
    let baseURL: URL
    let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    struct ClientError: LocalizedError {
        let message: String
        /// The token was refused: the user has to sign in again.
        var isUnauthorized = false
        /// The library holds more items than one listing reads
        /// (`syncItemLimit`).
        var isLibraryTooLarge = false
        /// How many items the server said the library holds, when it said.
        var itemCount: Int? = nil
        var errorDescription: String? { message }
    }

    // MARK: - Client identity

    static let product = "Nuvio"
    private static let clientIdentifierKey = "nuvio.tv.plex.clientIdentifier"

    /// Plex ties a sign-in to a client identifier, and lists the device under
    /// the account's Authorized Devices. Device-wide, not per profile, so the
    /// Apple TV shows up once however many profiles sign in.
    static var clientIdentifier: String {
        if let existing = UserDefaults.standard.string(forKey: clientIdentifierKey), !existing.isEmpty {
            return existing
        }
        let created = "nuvio-tvos-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(created, forKey: clientIdentifierKey)
        return created
    }

    static func identityHeaders(token: String? = nil) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Platform": "tvOS",
            "X-Plex-Device": "Apple TV",
            "X-Plex-Device-Name": "Nuvio (Apple TV)",
            "X-Plex-Model": "Apple TV"
        ]
        if let token, !token.isEmpty {
            headers["X-Plex-Token"] = token
        }
        return headers
    }

    // MARK: - plex.tv sign-in (PIN / plex.tv/link)

    struct Pin: Equatable {
        let id: Int
        let code: String
        let expiresAt: Date
    }

    private static let plexTV = URL(string: "https://plex.tv/api/v2/")!

    /// Starts a link-code sign-in. The user enters `code` at plex.tv/link on
    /// any device, which also covers Google, Apple, and Facebook accounts that
    /// have no Plex password to type on the Apple TV.
    static func createPin(session: URLSession = .shared) async throws -> Pin {
        var request = URLRequest(url: plexTV.appendingPathComponent("pins"))
        request.httpMethod = "POST"
        apply(identityHeaders(), to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        struct Payload: Decodable {
            let id: Int
            let code: String
            let expiresIn: Int?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Pin(
            id: payload.id,
            code: payload.code,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn ?? 900))
        )
    }

    /// The account token once the code has been entered, `nil` while waiting.
    static func checkPin(_ pin: Pin, session: URLSession = .shared) async throws -> String? {
        var request = URLRequest(url: plexTV.appendingPathComponent("pins/\(pin.id)"))
        apply(identityHeaders(), to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        struct Payload: Decodable { let authToken: String? }
        let token = try JSONDecoder().decode(Payload.self, from: data).authToken
        return (token?.isEmpty == false) ? token : nil
    }

    /// The signed-in account's display name, for the Settings row.
    static func accountName(token: String, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: plexTV.appendingPathComponent("user"))
        apply(identityHeaders(token: token), to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        struct Payload: Decodable {
            let username: String?
            let title: String?
            let friendlyName: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return [payload.friendlyName, payload.title, payload.username]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "Plex"
    }

    // MARK: - Plex Home

    /// One member of the account's Plex Home, each with their own watch state
    /// and library access.
    struct HomeUser: Identifiable, Equatable {
        /// The user's uuid.
        let id: String
        let name: String
        let isProtected: Bool
        let isAdmin: Bool
    }

    static func homeUsers(accountToken: String, session: URLSession = .shared) async throws -> [HomeUser] {
        var request = URLRequest(url: plexClients.appendingPathComponent("home/users"))
        apply(identityHeaders(token: accountToken), to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        struct Payload: Decodable {
            struct User: Decodable {
                let uuid: String
                let title: String?
                let friendlyName: String?
                let username: String?
                let protected: Bool?
                let admin: Bool?
            }
            let users: [User]?
        }
        return (try JSONDecoder().decode(Payload.self, from: data).users ?? []).map { user in
            HomeUser(
                id: user.uuid,
                name: [user.friendlyName, user.title, user.username].compactMap { $0 }.first { !$0.isEmpty } ?? "Plex",
                isProtected: user.protected ?? false,
                isAdmin: user.admin ?? false
            )
        }
    }

    /// A token that acts as `user`. `pin` is required for protected users.
    static func switchHomeUser(_ user: HomeUser, pin: String?, accountToken: String, session: URLSession = .shared) async throws -> String {
        var components = URLComponents(url: plexClients.appendingPathComponent("home/users/\(user.id)/switch"), resolvingAgainstBaseURL: false)!
        if let pin, !pin.isEmpty { components.queryItems = [URLQueryItem(name: "pin", value: pin)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        apply(identityHeaders(token: accountToken), to: &request)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw ClientError(message: L10n.string("plex_home_wrong_pin", fallback: "That PIN isn't right for this user."))
        }
        try validate(response)
        struct Payload: Decodable { let authToken: String? }
        guard let token = try JSONDecoder().decode(Payload.self, from: data).authToken, !token.isEmpty else {
            throw ClientError(message: L10n.string("plex_home_switch_failed", fallback: "Plex didn't switch to that user."))
        }
        return token
    }

    /// Plex documents resource discovery on this host rather than plex.tv.
    private static let plexClients = URL(string: "https://clients.plex.tv/api/v2/")!

    /// Every Plex Media Server the account owns or has been shared.
    static func servers(accountToken: String, session: URLSession = .shared) async throws -> [PlexResource] {
        var components = URLComponents(url: plexClients.appendingPathComponent("resources"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        apply(identityHeaders(token: accountToken), to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)

        struct Payload: Decodable {
            struct Connection: Decodable {
                let uri: String
                let address: String?
                let port: Int?
                let scheme: String?

                enum CodingKeys: String, CodingKey {
                    case uri, address, port, local, relay
                    case scheme = "protocol"
                }
                let local: Bool?
                let relay: Bool?
            }
            let name: String
            let product: String?
            let provides: String?
            let clientIdentifier: String
            let accessToken: String?
            let owned: Bool?
            let connections: [Connection]?
        }
        let payload = try JSONDecoder().decode([Payload].self, from: data)
        return payload
            .filter { resource in
                let provides = (resource.provides ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return provides.contains("server") || resource.product == "Plex Media Server"
            }
            .map { resource in
                PlexResource(
                    name: resource.name,
                    clientIdentifier: resource.clientIdentifier,
                    accessToken: resource.accessToken,
                    isOwned: resource.owned ?? false,
                    connections: (resource.connections ?? []).map {
                        PlexResource.Connection(
                            uri: $0.uri,
                            address: $0.address ?? "",
                            port: $0.port ?? 32400,
                            protocolName: $0.scheme ?? "https",
                            isLocal: $0.local ?? false,
                            isRelay: $0.relay ?? false
                        )
                    }
                )
            }
    }

    // MARK: - Connection selection

    /// Candidate base URLs in preference order. Plex advertises local servers
    /// as `https://<ip-with-dashes>.<hash>.plex.direct:32400`, and some routers
    /// (DNS rebinding protection, ad-blocking DNS) answer those names with
    /// `0.0.0.0`. Plex's own apps cope; clients that rely on system DNS fail
    /// with nothing reachable. So each local HTTPS address is followed by the
    /// same server over plain HTTP on its LAN IP, which Plex serves unless
    /// "Secure connections" is set to Required. Relays come last: they work
    /// from anywhere but Plex caps their bandwidth.
    static func candidateBaseURLs(for resource: PlexResource) -> [URL] {
        var ordered: [String] = []
        func add(_ value: String) {
            if !ordered.contains(value) { ordered.append(value) }
        }
        let local = resource.connections.filter { $0.isLocal && !$0.isRelay }
        let remote = resource.connections.filter { !$0.isLocal && !$0.isRelay }
        let relays = resource.connections.filter(\.isRelay)
        for connection in local {
            add(connection.uri)
            if !connection.address.isEmpty {
                add("http://\(connection.address):\(connection.port)")
            }
        }
        for connection in remote { add(connection.uri) }
        for connection in relays { add(connection.uri) }
        return ordered.compactMap(URL.init(string:))
    }

    /// Tries every candidate at once and returns the most preferred one that
    /// answers `/identity` as this server. Checking the machine identifier
    /// guards against a `0.0.0.0` answer landing on some other local service.
    static func reachableBaseURL(for resource: PlexResource, session: URLSession = .shared) async -> URL? {
        let candidates = candidateBaseURLs(for: resource)
        guard !candidates.isEmpty else { return nil }
        let results = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    (index, await PlexClient.isServer(url, machineIdentifier: resource.clientIdentifier, session: session))
                }
            }
            var reachable: [Int: Bool] = [:]
            for await (index, ok) in group { reachable[index] = ok }
            return reachable
        }
        guard let best = results.filter(\.value).keys.min() else { return nil }
        return candidates[best]
    }

    static func isServer(_ baseURL: URL, machineIdentifier: String, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("identity"))
        request.timeoutInterval = 5
        apply(identityHeaders(), to: &request)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        struct Payload: Decodable {
            struct Container: Decodable { let machineIdentifier: String? }
            let MediaContainer: Container
        }
        guard let identifier = (try? JSONDecoder().decode(Payload.self, from: data))?.MediaContainer.machineIdentifier else {
            return false
        }
        return identifier == machineIdentifier
    }

    // MARK: - Server calls

    func libraries() async throws -> [PlexLibrary] {
        let data = try await get("library/sections")
        struct Payload: Decodable {
            struct Container: Decodable {
                struct DirectoryDTO: Decodable {
                    let key: String
                    let title: String
                    let type: String
                    let contentChangedAt: Int64?
                    let updatedAt: Int64?
                }
                let Directory: [DirectoryDTO]?
            }
            let MediaContainer: Container
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.MediaContainer.Directory ?? [])
            .filter { $0.type == "movie" || $0.type == "show" }
            .map { directory in
                PlexLibrary(
                    id: directory.key,
                    name: directory.title,
                    type: directory.type,
                    changeMarker: "\(directory.contentChangedAt ?? 0)-\(directory.updatedAt ?? 0)"
                )
            }
    }

    /// Plex's numeric item types for `/library/sections/<id>/all?type=`.
    enum ItemType: Int {
        case movie = 1
        case show = 2
        case episode = 4
    }

    /// The most items one listing reads. A library with more is too large to
    /// keep on the Apple TV, so its titles are looked up one at a time
    /// (`search`) when a stream list opens.
    static let syncItemLimit = 500_000

    /// Every item of one type in a section. A single request per page covers a
    /// whole library (episodes included), so syncs need no per-show requests.
    /// - Parameter viewedSince: only items played at or after this time (Unix
    ///   seconds), for refreshing watch state without listing the library.
    /// - Throws: an error with `isLibraryTooLarge` set when the section holds
    ///   more than `maxItems`, after the first page when the server reports
    ///   its size.
    func items(
        libraryID: String,
        type: ItemType,
        viewedSince: Int64? = nil,
        maxItems: Int = PlexClient.syncItemLimit,
        onPageFetched: ((Int, Int?) -> Void)? = nil
    ) async throws -> [PlexMediaItem] {
        var all: [PlexMediaItem] = []
        var start = 0
        let pageSize = 500
        for _ in 0...(maxItems / pageSize) {
            try Task.checkCancellation()
            var query = [
                "type": String(type.rawValue),
                "includeGuids": "1",
                "X-Plex-Container-Start": String(start),
                "X-Plex-Container-Size": String(pageSize)
            ]
            if let viewedSince {
                // Plex filter syntax: `lastViewedAt>=N` is the key `lastViewedAt>`
                // with value `N`.
                query["lastViewedAt>"] = String(viewedSince)
            }
            let data = try await get("library/sections/\(libraryID)/all", query: query)
            let page = try JSONDecoder().decode(ItemsPayload.self, from: data).MediaContainer
            if let total = page.totalSize, total > maxItems {
                throw Self.libraryTooLarge(itemCount: total)
            }
            let metadata = page.Metadata ?? []
            all.append(contentsOf: metadata.map(Self.mapItem))
            start += metadata.count
            onPageFetched?(all.count, page.totalSize)
            if metadata.isEmpty { return all }
            if let total = page.totalSize, start >= total { return all }
            if page.totalSize == nil, metadata.count < pageSize { return all }
            // Without a total, one more page tells a library of exactly
            // `maxItems` (an empty page) from a larger one.
            if start > maxItems { break }
        }
        throw Self.libraryTooLarge(itemCount: nil)
    }

    private static func libraryTooLarge(itemCount: Int?) -> ClientError {
        ClientError(
            message: L10n.string("plex_library_too_large", fallback: "This library is too large to sync."),
            isLibraryTooLarge: true,
            itemCount: itemCount
        )
    }

    /// Titles of one type in a section named `title`, for libraries too large
    /// to sync: exactly that name when `exact`, otherwise any name that
    /// contains it. `year` narrows the search when the title's year is known.
    func search(
        libraryID: String,
        type: ItemType,
        title: String,
        exact: Bool = false,
        year: Int? = nil,
        limit: Int = 50
    ) async throws -> [PlexMediaItem] {
        var query = [
            "type": String(type.rawValue),
            "includeGuids": "1",
            "X-Plex-Container-Start": "0",
            "X-Plex-Container-Size": String(limit)
        ]
        // Plex filter syntax: `title=N` matches names that contain N, and
        // `title==N` (the key `title=` with value `N`) only the name N.
        query[exact ? "title=" : "title"] = title
        if let year { query["year"] = String(year) }
        let data = try await get("library/sections/\(libraryID)/all", query: query)
        return (try JSONDecoder().decode(ItemsPayload.self, from: data).MediaContainer.Metadata ?? []).map(Self.mapItem)
    }

    /// Every episode of one show, with its files.
    func episodes(showRatingKey: String) async throws -> [PlexMediaItem] {
        let data = try await get("library/metadata/\(showRatingKey)/allLeaves", query: ["includeGuids": "1"])
        return (try JSONDecoder().decode(ItemsPayload.self, from: data).MediaContainer.Metadata ?? []).map(Self.mapItem)
    }

    /// Current resume position and watch count for one item, read live so a
    /// position saved by another Plex app since the last sync wins.
    func playbackState(ratingKey: String) async throws -> (viewOffsetMs: Int64?, viewCount: Int?) {
        let data = try await get("library/metadata/\(ratingKey)")
        let item = try JSONDecoder().decode(ItemsPayload.self, from: data).MediaContainer.Metadata?.first
        return (item?.viewOffset, item?.viewCount)
    }

    /// A span Plex detected in a file: an intro or credits. Plex finds these
    /// when the library has intro or credits detection turned on.
    struct Marker: Equatable {
        let type: String
        let startTimeOffset: Int64
        let endTimeOffset: Int64
        /// Set on the credits marker after which the file has nothing more.
        let final: Bool?
    }

    /// The intro and credits markers of an episode or movie.
    func markers(ratingKey: String) async throws -> [Marker] {
        struct Payload: Decodable {
            struct Container: Decodable { let Metadata: [Item]? }
            struct Item: Decodable { let Marker: [Marker]? }
            let MediaContainer: Container
        }
        let data = try await get("library/metadata/\(ratingKey)", query: ["includeMarkers": "1"])
        return try JSONDecoder().decode(Payload.self, from: data).MediaContainer.Metadata?.first?.Marker ?? []
    }

    enum TimelineState: String {
        case playing, paused, stopped
    }

    /// Tells the server where playback is. Plex saves this as the resume point
    /// for every app on the account, and marks the item watched once a stop
    /// lands past its watched threshold (90% by default).
    func reportTimeline(ratingKey: String, state: TimelineState, timeMs: Int64, durationMs: Int64) async throws {
        _ = try await get(
            ":/timeline",
            query: [
                "ratingKey": ratingKey,
                "key": "/library/metadata/\(ratingKey)",
                "state": state.rawValue,
                "time": String(max(0, timeMs)),
                "duration": String(max(0, durationMs)),
                "hasMDE": "1"
            ]
        )
    }

    /// Marks an item (a movie, an episode, or a whole show) watched or unwatched.
    func setWatched(_ watched: Bool, ratingKey: String) async throws {
        _ = try await get(watched ? ":/scrobble" : ":/unscrobble", query: [
            "key": ratingKey,
            "identifier": "com.plexapp.plugins.library"
        ])
    }

    /// Subtitle files Plex keeps beside the video (not inside it).
    struct ExternalSubtitle: Equatable {
        let key: String
        let languageCode: String
        let title: String
    }

    /// The video, audio and subtitle tracks of one file, named as Plex names them.
    struct PartTracks: Equatable {
        /// "Main 10", from the video track's profile.
        var videoProfile: String? = nil
        /// "Dolby Vision", "HDR10" or "HLG"; nil for SDR.
        var dynamicRange: String? = nil
        /// "English (EAC3 5.1)", one per audio track.
        var audio: [String] = []
        /// "English", "English SDH", one per subtitle track, without repeats.
        var subtitles: [String] = []
    }

    /// An item's tracks by file (`/library/parts/...` key), and the subtitle
    /// files Plex keeps beside the video.
    struct ItemTracks: Equatable {
        var parts: [String: PartTracks] = [:]
        var externalSubtitles: [ExternalSubtitle] = []
    }

    func tracks(ratingKey: String) async throws -> ItemTracks {
        try Self.decodeTracks(try await get("library/metadata/\(ratingKey)"))
    }

    static func decodeTracks(_ data: Data) throws -> ItemTracks {
        struct Payload: Decodable {
            struct Container: Decodable { let Metadata: [Item]? }
            struct Item: Decodable { let Media: [MediaDTO]? }
            struct MediaDTO: Decodable { let Part: [PartDTO]? }
            struct PartDTO: Decodable {
                let key: String?
                let Stream: [StreamDTO]?
            }
            struct StreamDTO: Decodable {
                let streamType: Int?
                let key: String?
                let languageCode: String?
                let displayTitle: String?
                let profile: String?
                let colorTrc: String?
                let DOVIPresent: Bool?
            }
            let MediaContainer: Container
        }
        let parts = try JSONDecoder().decode(Payload.self, from: data)
            .MediaContainer.Metadata?.first?.Media?.flatMap { $0.Part ?? [] } ?? []
        var result = ItemTracks()
        for part in parts {
            var tracks = PartTracks()
            for stream in part.Stream ?? [] {
                switch stream.streamType {
                case 1 where tracks.videoProfile == nil && tracks.dynamicRange == nil:
                    tracks.videoProfile = stream.profile.map { $0.capitalized }
                    if stream.DOVIPresent == true {
                        tracks.dynamicRange = "Dolby Vision"
                    } else if stream.colorTrc == "smpte2084" {
                        tracks.dynamicRange = "HDR10"
                    } else if stream.colorTrc == "arib-std-b67" {
                        tracks.dynamicRange = "HLG"
                    }
                case 2:
                    if let title = stream.displayTitle, !title.isEmpty { tracks.audio.append(title) }
                case 3:
                    if let title = stream.displayTitle, !title.isEmpty, !tracks.subtitles.contains(title) {
                        tracks.subtitles.append(title)
                    }
                    if let key = stream.key, !key.isEmpty {
                        result.externalSubtitles.append(ExternalSubtitle(
                            key: key,
                            languageCode: stream.languageCode ?? "und",
                            title: stream.displayTitle ?? "Plex"
                        ))
                    }
                default:
                    break
                }
            }
            if let key = part.key { result.parts[key] = tracks }
        }
        return result
    }

    /// Ends a conversion started through `transcodeURL`, freeing the server.
    func stopTranscode(session: String) async {
        _ = try? await get("video/:/transcode/universal/stop", query: ["session": session])
    }

    // MARK: - Media URLs

    static let transcodePath = "/video/:/transcode/universal/start.m3u8"

    /// An HLS stream the server converts on the fly, for files the player
    /// can't decode. Video is converted to 1080p H.264 only when needed
    /// (`directStream`), audio likewise.
    static func transcodeURL(baseURL: URL, ratingKey: String, session: String) -> URL? {
        url(baseURL: baseURL, path: transcodePath, query: [
            "path": "/library/metadata/\(ratingKey)",
            "mediaIndex": "0",
            "partIndex": "0",
            "protocol": "hls",
            "directPlay": "0",
            "directStream": "1",
            "fastSeek": "1",
            "videoResolution": "1920x1080",
            "maxVideoBitrate": "20000",
            "videoQuality": "100",
            "session": session,
            "X-Plex-Session-Identifier": session,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": product,
            "X-Plex-Platform": "tvOS"
        ])
    }

    /// The rating key a `transcodeURL` plays.
    static func transcodedRatingKey(_ url: URL) -> (ratingKey: String, session: String?)? {
        guard url.path == transcodePath,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/library/metadata/") else { return nil }
        return (String(path.dropFirst("/library/metadata/".count)), items.first { $0.name == "session" }?.value)
    }

    /// A sidecar subtitle file. Subtitle loaders fetch a plain URL, so this
    /// one carries the token; it is used for the play in progress and not stored.
    static func subtitleURL(baseURL: URL, key: String, token: String) -> URL? {
        url(baseURL: baseURL, path: key, query: [tokenHeader: token])
    }

    static let tokenHeader = "X-Plex-Token"

    /// A direct-play URL for one file. Plex serves the original bytes over
    /// HTTP range requests, so the player seeks without any transcoding. The
    /// token is not part of the URL: requests carry it in `tokenHeader`, so a
    /// stored or logged link never contains a credential.
    static func streamURL(baseURL: URL, partKey: String) -> URL? {
        url(baseURL: baseURL, path: partKey, query: [:])
    }

    /// Artwork resized by the server, so Home doesn't download full-size art.
    static func imageURL(baseURL: URL, path: String?, token: String, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return url(baseURL: baseURL, path: "/photo/:/transcode", query: [
            "url": path,
            "width": String(width),
            "height": String(height),
            "minSize": "1",
            "upscale": "1",
            "X-Plex-Token": token
        ])
    }

    private static func url(baseURL: URL, path: String, query: [String: String]) -> URL? {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: base + normalizedPath) else { return nil }
        guard !query.isEmpty else { return components.url }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" as is, and servers read it as a space
        // ("Romeo + Juliet" would be searched as "Romeo   Juliet").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    // MARK: - Decoding

    private struct ItemsPayload: Decodable {
        struct Container: Decodable {
            let totalSize: Int?
            let Metadata: [Item]?
        }
        struct TagDTO: Decodable { let tag: String }
        struct GuidDTO: Decodable { let id: String }
        struct PartDTO: Decodable {
            let key: String?
            let size: Int64?
            let container: String?
            let file: String?
        }
        struct MediaDTO: Decodable {
            let container: String?
            let videoResolution: String?
            let videoCodec: String?
            let audioCodec: String?
            let audioChannels: Int?
            let bitrate: Int?
            let Part: [PartDTO]?
        }
        struct Item: Decodable {
            let ratingKey: String
            let type: String?
            let title: String?
            let summary: String?
            let year: Int?
            let originallyAvailableAt: String?
            let rating: Double?
            let audienceRating: Double?
            let contentRating: String?
            let duration: Int64?
            let thumb: String?
            let art: String?
            let grandparentRatingKey: String?
            let parentIndex: Int?
            let index: Int?
            let viewOffset: Int64?
            let viewCount: Int?
            let lastViewedAt: Int64?
            let Genre: [TagDTO]?
            let Role: [TagDTO]?
            let Director: [TagDTO]?
            let Guid: [GuidDTO]?
            let Media: [MediaDTO]?
        }
        let MediaContainer: Container
    }

    private static func mapItem(_ item: ItemsPayload.Item) -> PlexMediaItem {
        let guids = (item.Guid ?? []).map(\.id)
        let imdb = guids.first { $0.hasPrefix("imdb://") }.map { String($0.dropFirst("imdb://".count)) }
        let tmdb = guids.first { $0.hasPrefix("tmdb://") }.flatMap { Int($0.dropFirst("tmdb://".count)) }
        let media = item.Media?.first
        let part = media?.Part?.first
        var files: [PlexFile] = []
        for version in item.Media ?? [] {
            let parts = (version.Part ?? []).filter { $0.key != nil }
            for (index, filePart) in parts.enumerated() {
                var labels: [String] = []
                if let resolution = version.videoResolution, !resolution.isEmpty {
                    labels.append(resolution.lowercased() == "4k" ? "4K" : (Int(resolution) != nil ? "\(resolution)p" : resolution.uppercased()))
                }
                if let bitrate = version.bitrate, bitrate > 0 {
                    labels.append(String(format: "%.1f Mbps", Double(bitrate) / 1000))
                }
                if parts.count > 1 {
                    labels.append("Part \(index + 1) of \(parts.count)")
                }
                files.append(PlexFile(
                    partKey: filePart.key ?? "",
                    container: filePart.container ?? version.container,
                    sizeBytes: filePart.size,
                    label: labels.isEmpty ? nil : labels.joined(separator: " · "),
                    details: PlexFileDetails(
                        videoResolution: version.videoResolution,
                        videoCodec: version.videoCodec,
                        audioCodec: version.audioCodec,
                        audioChannels: version.audioChannels,
                        bitrateKbps: version.bitrate,
                        fileName: filePart.file.map { ($0 as NSString).lastPathComponent },
                        part: parts.count > 1 ? "Part \(index + 1) of \(parts.count)" : nil
                    )
                ))
            }
        }
        return PlexMediaItem(
            ratingKey: item.ratingKey,
            type: item.type ?? "movie",
            title: item.title ?? "",
            summary: item.summary,
            year: item.year,
            originallyAvailableAt: item.originallyAvailableAt,
            rating: item.audienceRating ?? item.rating,
            contentRating: item.contentRating,
            durationMs: item.duration,
            thumb: item.thumb,
            art: item.art,
            genres: item.Genre?.map(\.tag),
            cast: item.Role?.map(\.tag),
            directors: item.Director?.map(\.tag),
            imdbId: imdb,
            tmdbId: tmdb,
            showRatingKey: item.grandparentRatingKey,
            seasonNumber: item.parentIndex,
            episodeNumber: item.index,
            partKey: part?.key,
            container: part?.container ?? media?.container,
            sizeBytes: part?.size,
            viewOffsetMs: item.viewOffset,
            viewCount: item.viewCount,
            lastViewedAt: item.lastViewedAt,
            files: files
        )
    }

    // MARK: - Plumbing

    private func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        guard let url = Self.url(baseURL: baseURL, path: path, query: query) else {
            throw ClientError(message: "Invalid request URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        Self.apply(Self.identityHeaders(token: token), to: &request)
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 429 || http.statusCode == 503,
               attempt < 5 {
                let delay = Self.retryDelay(retryAfter: http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt)
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            try Self.validate(response)
            return data
        }
    }

    /// The server's `Retry-After` when it sends one, otherwise 1, 2, 4, 8, 16 s, capped at 30 s.
    static func retryDelay(retryAfter: String?, attempt: Int) -> TimeInterval {
        if let retryAfter, let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(seconds, 30)
        }
        return min(pow(2, Double(attempt)), 30)
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError(message: "No response from server")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw ClientError(
                    message: L10n.string("plex_error_unauthorized", fallback: "Plex sign-in expired. Sign in again."),
                    isUnauthorized: true
                )
            }
            throw ClientError(message: L10n.format("plex_error_status", fallback: "Plex returned status %d", http.statusCode))
        }
    }
}

extension PlexClient.Marker: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, startTimeOffset, endTimeOffset, final
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        startTimeOffset = try container.decode(Int64.self, forKey: .startTimeOffset)
        endTimeOffset = try container.decode(Int64.self, forKey: .endTimeOffset)
        // `true` in JSON from current servers; accept 1 / 0 as well.
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .final) {
            final = flag
        } else if let flag = try? container.decodeIfPresent(Int.self, forKey: .final) {
            final = flag != 0
        } else {
            final = nil
        }
    }
}
