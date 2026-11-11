import Foundation

// Xtream endpoint structure informed by OpenIPTV's XtreamAPIService at
// ec9c1a5e94555179a5d57926057e1287d9cc090f. See ThirdParty/OpenIPTV-LICENSE.txt.
enum IPTVXtreamOutput: String, Codable, CaseIterable { case mpegTS = "ts", hls = "m3u8" }

struct IPTVXtreamCredentials: Equatable {
    let server: URL
    let username: String
    let password: String
    var output: IPTVXtreamOutput = .mpegTS
}

enum IPTVXtreamError: Error, Equatable {
    case invalidConfiguration
    case invalidResponse
    case httpStatus(Int)
    case authenticationFailed
    case tooLarge
}

struct IPTVXtreamClient {
    private let session: URLSession
    private static let maxBytes = 16 * 1024 * 1024

    init(session: URLSession = IPTVAuthenticatedSession.shared) { self.session = session }

    func loadChannels(credentials: IPTVXtreamCredentials, sourceID: String) async throws -> [IPTVChannel] {
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IPTVXtreamError.invalidConfiguration }
        let authData = try await request(credentials: credentials, action: nil)
        let auth = try JSONDecoder().decode(Authentication.self, from: authData)
        guard auth.userInfo.auth.value == "1" else { throw IPTVXtreamError.authenticationFailed }
        // Categories enrich the channel list; an unavailable category endpoint
        // should not hide otherwise playable channels.
        var categoryNames: [String: String] = [:]
        do {
            let categories = try await request(credentials: credentials, action: "get_live_categories")
            let decoded = try JSONDecoder().decode([Lossy<Category>].self, from: categories)
            for category in decoded.compactMap(\.value) {
                if let id = category.id.value, let name = category.name, !name.isEmpty { categoryNames[id] = name }
            }
        } catch {
            try Task.checkCancellation()
        }
        let data = try await request(credentials: credentials, action: "get_live_streams")
        let entries = try JSONDecoder().decode([Lossy<LiveStream>].self, from: data)
        try Task.checkCancellation()
        let source = sourceID
        let streams = entries.compactMap(\.value).compactMap { entry -> IPTVPlaylistParser.Stream? in
            guard let id = entry.streamID.value, !id.isEmpty,
                  let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let url = Self.liveURL(credentials: credentials, streamID: id) else { return nil }
            var stream = IPTVPlaylistParser.Stream(title: name, url: url.absoluteString,
                                                    tvgLogo: entry.icon, tvgID: entry.guideID,
                                                    tvgName: nil, groupTitle: entry.categoryID.flatMap { $0.value }.flatMap { categoryNames[$0] })
            stream.providerID = id
            return stream
        }
        let playlist = IPTVPlaylistParser.Playlist(tvgURL: nil, imageURL: nil, xTvgURL: nil, tvgLogo: nil, streams: streams)
        return IPTVChannelImporter.channels(from: [playlist], sourceID: source, baseURL: nil)
    }

    private func request(credentials: IPTVXtreamCredentials, action: String?) async throws -> Data {
        guard let url = Self.apiURL(credentials: credentials, action: action) else { throw IPTVXtreamError.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("NuvioTV", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw IPTVXtreamError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw IPTVXtreamError.httpStatus(http.statusCode) }
        guard http.expectedContentLength <= Int64(Self.maxBytes) else { throw IPTVXtreamError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard data.count < Self.maxBytes else { throw IPTVXtreamError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    static func apiURL(credentials: IPTVXtreamCredentials, action: String?) -> URL? {
        guard valid(credentials), var components = URLComponents(url: credentials.server, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([prefix, "player_api.php"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = [URLQueryItem(name: "username", value: credentials.username), URLQueryItem(name: "password", value: credentials.password)]
        if let action { components.queryItems?.append(URLQueryItem(name: "action", value: action)) }
        return components.url
    }

    /// Xtream XMLTV uses the same account as the API; keep the URL private and
    /// use the authenticated session's same-origin redirect policy.
    static func guideURL(credentials: IPTVXtreamCredentials) -> URL? {
        guard valid(credentials), var components = URLComponents(url: credentials.server, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([prefix, "xmltv.php"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = [URLQueryItem(name: "username", value: credentials.username), URLQueryItem(name: "password", value: credentials.password)]
        return components.url
    }

    static func liveURL(credentials: IPTVXtreamCredentials, streamID: String) -> URL? {
        guard valid(credentials), !streamID.isEmpty,
              streamID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              var components = URLComponents(url: credentials.server, resolvingAgainstBaseURL: false) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let user = credentials.username.addingPercentEncoding(withAllowedCharacters: allowed),
              let password = credentials.password.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([prefix, "live", user, password, "\(streamID).\(credentials.output.rawValue)"].filter { !$0.isEmpty }.joined(separator: "/"))
        return components.url
    }

    private static func valid(_ credentials: IPTVXtreamCredentials) -> Bool {
        guard let c = URLComponents(url: credentials.server, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { return false }
        return !credentials.username.isEmpty && !credentials.password.isEmpty
    }

    private struct Authentication: Decodable {
        let userInfo: UserInfo
        enum CodingKeys: String, CodingKey { case userInfo = "user_info" }
        struct UserInfo: Decodable { let auth: FlexibleValue }
    }

    private struct FlexibleValue: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let text = try? c.decode(String.self) { value = text }
            else if let number = try? c.decode(Int.self) { value = String(number) }
            else { value = nil }
        }
    }

    private struct LiveStream: Decodable {
        let streamID: FlexibleValue
        let name: String?
        let icon: String?
        let guideID: String?
        let categoryID: FlexibleValue?
        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id", name, icon = "stream_icon", guideID = "epg_channel_id", categoryID = "category_id"
        }
    }

    private struct Category: Decodable {
        let id: FlexibleValue
        let name: String?
        enum CodingKeys: String, CodingKey { case id = "category_id", name = "category_name" }
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
