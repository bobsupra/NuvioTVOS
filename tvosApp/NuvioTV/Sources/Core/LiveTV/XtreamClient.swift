import Foundation

/// Minimal Xtream Codes API client (`player_api.php`), the same calls TiviMate
/// and NuvioPlusIPTV use for live TV.
struct XtreamClient: Sendable {
    let server: String
    let username: String
    let password: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Many panels reject unknown clients; a common player User-Agent is the
    /// most compatible default.
    static let userAgent = "VLC/3.0.20 LibVLC/3.0.20"

    init(account: XtreamAccount, password: String) {
        self.server = account.server
        self.username = account.username
        self.password = password
    }

    init(server: String, username: String, password: String) {
        self.server = XtreamAccount.normaliseServer(server)
        self.username = username
        self.password = password
    }

    // MARK: API

    func login() async throws -> XtreamUserInfo {
        let data = try await get(action: nil)
        guard let response = try? JSONDecoder().decode(XtreamLoginResponse.self, from: data),
              let info = response.userInfo else {
            throw XtreamError.authenticationFailed
        }
        guard info.auth == 1 else { throw XtreamError.authenticationFailed }
        if let status = info.status, status.lowercased() != "active" {
            throw XtreamError.accountInactive(status)
        }
        return info
    }

    func liveCategories() async throws -> [XtreamCategory] {
        let data = try await get(action: "get_live_categories")
        guard let categories = try? JSONDecoder().decode([XtreamCategory].self, from: data) else {
            // Some panels answer `{}` or `null` when there are no categories.
            return []
        }
        return categories.filter { !$0.id.isEmpty }
    }

    func liveChannels() async throws -> [XtreamLiveChannel] {
        let data = try await get(action: "get_live_streams")
        guard let channels = try? JSONDecoder().decode([XtreamLiveChannel].self, from: data) else {
            throw XtreamError.invalidResponse
        }
        return channels.filter { $0.streamID >= 0 }
    }

    // MARK: Links

    /// `{server}/live/{user}/{pass}/{id}.{ext}`
    func liveURL(streamID: Int, format: XtreamStreamFormat, allowedFormats: [String]) -> URL? {
        let ext = Self.fileExtension(for: format, allowedFormats: allowedFormats)
        return URL(string: "\(server)/live/\(Self.pathEncode(username))/\(Self.pathEncode(password))/\(streamID).\(ext)")
    }

    static func fileExtension(for format: XtreamStreamFormat, allowedFormats: [String]) -> String {
        switch format {
        case .ts: return "ts"
        case .hls: return "m3u8"
        case .auto:
            // Some providers only allow HLS; asking for .ts then fails on every
            // channel. Prefer HLS when allowed, fall back to TS otherwise.
            if allowedFormats.isEmpty || allowedFormats.contains("m3u8") { return "m3u8" }
            return allowedFormats.contains("ts") ? "ts" : "m3u8"
        }
    }

    var httpHeaders: [String: String] { ["User-Agent": Self.userAgent] }

    // MARK: Transport

    private func get(action: String?) async throws -> Data {
        guard var components = URLComponents(string: "\(server)/player_api.php"),
              components.host?.isEmpty == false else {
            throw XtreamError.invalidServer
        }
        var items = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        components.queryItems = items
        // URLComponents leaves "+" unescaped, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw XtreamError.invalidServer }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw XtreamError.authenticationFailed }
            throw XtreamError.badStatus(http.statusCode)
        }
        return data
    }

    private static func pathEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
