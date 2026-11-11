import Foundation

struct IPTVStalkerPlayback: Sendable {
    let url: URL
    let headers: [String: String]
}

/// One portal session. The token remains in memory and is never persisted.
actor IPTVStalkerClient {
    private let portal: URL
    private let mac: String
    private let session: URLSession
    private var token: String?
    private var generation = 0
    private static let maxBytes = 16 * 1024 * 1024

    init(portal: URL, mac: String, session: URLSession? = nil) throws {
        guard IPTVStalkerProtocol.requestURL(portal: portal, type: "stb", action: "handshake") != nil else { throw IPTVStalkerError.invalidPortal }
        guard let normalized = IPTVStalkerProtocol.normalizedMAC(mac) else { throw IPTVStalkerError.invalidMAC }
        self.portal = portal
        self.mac = normalized
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: IPTVStalkerRedirectGuard(portal: portal), delegateQueue: nil)
    }

    func loadChannels() async throws -> [IPTVStalkerChannel] {
        generation &+= 1
        let attempt = generation
        token = nil
        try await refreshToken(attempt: attempt)
        do {
            let list = try await request(type: "itv", action: "get_all_channels", authorized: true)
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            let channels = try IPTVStalkerProtocol.channels(from: list)
            if !channels.isEmpty { return try await enrichCategories(channels, attempt: attempt) }
        } catch {
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
        }
        let channels = try await loadOrderedChannels(attempt: attempt)
        return try await enrichCategories(channels, attempt: attempt)
    }

    private func enrichCategories(_ channels: [IPTVStalkerChannel], attempt: Int) async throws -> [IPTVStalkerChannel] {
        guard !channels.isEmpty else { return channels }
        do {
            let data = try await request(type: "itv", action: "get_genres", authorized: true)
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            let names = try IPTVStalkerProtocol.categoryNames(from: data)
            return channels.map { channel in
                var channel = channel
                if let id = channel.categoryID { channel.categoryName = names[id] }
                return channel
            }
        } catch {
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            return channels
        }
    }

    private func loadOrderedChannels(attempt: Int) async throws -> [IPTVStalkerChannel] {
        var channels: [IPTVStalkerChannel] = []
        var seen = Set<String>()
        // A hard ceiling prevents an endpoint that repeats pages from running forever.
        for page in 1...200 {
            let data = try await request(type: "itv", action: "get_ordered_list", extra: [URLQueryItem(name: "p", value: String(page))], authorized: true)
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            let response = try IPTVStalkerProtocol.page(from: data)
            if response.rawCount == 0 { return channels }
            guard !response.channels.isEmpty else { throw IPTVStalkerError.invalidResponse }
            let fresh = response.channels.filter { seen.insert($0.id).inserted }
            // Repeated pages are an incomplete result, not a valid end marker.
            guard !fresh.isEmpty else { throw IPTVStalkerError.invalidResponse }
            channels.append(contentsOf: fresh)
        }
        throw IPTVStalkerError.tooLarge
    }

    private func refreshToken(attempt: Int) async throws {
        let data = try await request(type: "stb", action: "handshake", extra: [URLQueryItem(name: "token", value: "")], authorized: false)
        let newToken = try IPTVStalkerProtocol.handshakeToken(from: data)
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        token = newToken
        // Some portals require a profile request before listing channels.
        // Others do not implement it, so a failed optional request is not fatal.
        do { _ = try await request(type: "stb", action: "get_profile", authorized: true) }
        catch { try Task.checkCancellation() }
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
    }

    func resolve(_ channel: IPTVStalkerChannel) async throws -> IPTVStalkerPlayback {
        let attempt = generation
        let data: Data
        do {
            data = try await request(type: "itv", action: "create_link", extra: [URLQueryItem(name: "cmd", value: channel.command)], authorized: true)
        } catch IPTVStalkerError.httpStatus(let status) where status == 401 || status == 403 {
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            token = nil
            try await refreshToken(attempt: attempt)
            data = try await request(type: "itv", action: "create_link", extra: [URLQueryItem(name: "cmd", value: channel.command)], authorized: true)
        }
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        let url = try IPTVStalkerProtocol.playbackURL(from: data)
        // Playback backends may follow redirects independently of URLSession.
        // Do not pass portal credentials to them: a redirect could expose them.
        return IPTVStalkerPlayback(url: url, headers: Self.playbackHeaders())
    }

    private func request(type: String, action: String, extra: [URLQueryItem] = [], authorized: Bool) async throws -> Data {
        if authorized && token == nil { throw IPTVStalkerError.invalidResponse }
        var parameters = extra
        if authorized, let token { parameters.append(URLQueryItem(name: "token", value: token)) }
        guard let url = IPTVStalkerProtocol.requestURL(portal: portal, type: type, action: action, extra: parameters) else { throw IPTVStalkerError.invalidPortal }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.deviceAgent, forHTTPHeaderField: "X-User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if authorized, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw IPTVStalkerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw IPTVStalkerError.httpStatus(http.statusCode) }
        guard http.expectedContentLength <= Int64(Self.maxBytes) else { throw IPTVStalkerError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard data.count < Self.maxBytes else { throw IPTVStalkerError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    private static let userAgent = "Mozilla/5.0 (QtEmbedded; Linux; C) AppleWebKit/533.3 MAG200"
    private static let deviceAgent = "Model: MAG250; Link: Ethernet"
    private var cookie: String { "mac=\(mac); stb_lang=en; timezone=UTC" }

    nonisolated static func playbackHeaders() -> [String: String] {
        ["User-Agent": userAgent, "X-User-Agent": deviceAgent]
    }
}

/// MAC and bearer headers must never follow redirects to another origin.
final class IPTVStalkerRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let portal: URL
    init(portal: URL) { self.portal = portal }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.sameOrigin(portal, url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            if let explicit = url.port { return explicit }
            switch url.scheme?.lowercased() { case "https": return 443; case "http": return 80; default: return nil }
        }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && port(a) == port(b)
    }
}
