import Foundation

/// Nuvio's server for plugins on this Apple TV, at
/// `http://127.0.0.1:8766/<token>/` — only apps on the Apple TV itself can
/// reach it:
///
/// - `resolve/<provider>/<name>?p=<payload>` — a stream the plugin resolves
///   when it is played: its result had `resolve` instead of `url`, the player
///   opens this address, the plugin's `resolveStream(payload)` returns the
///   real URL and the player is redirected there. Links that expire or cost
///   a request (file hosts, debrid) are made only for what is played.
/// - `plugin/<provider>/<path>` — the plugin's own routes (`handleRequest`),
///   e.g. a playlist it builds or subtitles it converts for the player.
///
/// The token stays the same between launches, so a stream saved for Continue
/// Watching still works later.
final class PluginLoopbackServer: @unchecked Sendable {
    static let shared = PluginLoopbackServer()
    static let host = "127.0.0.1"
    static let preferredPort: UInt16 = 8766
    /// Base64 of the JSON `resolve` value; bigger ones are not used.
    static let maxPayloadBytes = 6_000
    private static let tokenKey = "plugins.loopback.token"

    let token: String
    private let lock = NSLock()
    private var core: PluginHTTPServerCore?
    private var readyURL: URL?

    init(token: String? = nil) {
        if let token {
            self.token = token
        } else if let saved = UserDefaults.standard.string(forKey: Self.tokenKey), saved.count >= 8 {
            self.token = saved
        } else {
            let created = PluginWebServer.makeToken()
            UserDefaults.standard.set(created, forKey: Self.tokenKey)
            self.token = created
        }
    }

    /// `http://127.0.0.1:<port>/<token>/` — the preferred port until the
    /// server has started.
    var baseURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return readyURL ?? URL(string: "http://\(Self.host):\(Self.preferredPort)/\(token)/")!
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readyURL != nil
    }

    /// Starts the server unless it runs; it restarts the next time after the
    /// system stopped it (e.g. in the background).
    func ensureRunning() {
        lock.lock()
        guard core == nil else {
            lock.unlock()
            return
        }
        let core = PluginHTTPServerCore(token: token, idleTimeout: nil) { request in
            await PluginRoutes.handleLocal(request)
        }
        self.core = core
        lock.unlock()
        core.start(
            preferredPort: Self.preferredPort,
            host: Self.host,
            onState: { [weak self] state in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.core === core else { return }
                switch state {
                case .ready(let url):
                    self.readyURL = url
                case .failed, .stopped:
                    self.core = nil
                    self.readyURL = nil
                }
            },
            onActivity: {}
        )
    }

    func stop() {
        lock.lock()
        let running = core
        core = nil
        readyURL = nil
        lock.unlock()
        running?.stop()
    }

    /// Starts the server and waits (up to two seconds) until it listens.
    func waitUntilReady() async {
        ensureRunning()
        for _ in 0..<40 where !isReady {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The address the player opens for a stream with `resolve`; nil when the
    /// payload is not JSON or too big.
    func resolveURL(scraperID: String, payload: Any, filename: String? = nil) -> String? {
        guard let json = PluginRuntime.jsonLiteral(payload) else { return nil }
        let encoded = PluginRoutes.base64URL(Data(json.utf8))
        guard encoded.count <= Self.maxPayloadBytes else { return nil }
        let name = PluginRoutes.safeFileName(filename) ?? "stream"
        return baseURL.absoluteString + "resolve/\(PluginAddonRegistry.key(for: scraperID))/\(name)?p=\(encoded)"
    }

    /// `NUVIO.server.url(path)`: the plugin's `handleRequest` for the player.
    func routeURL(scraperID: String, path: String) -> String {
        let trimmed = path.drop { $0 == "/" }
        return baseURL.absoluteString + "plugin/\(PluginAddonRegistry.key(for: scraperID))/" + trimmed
    }
}

/// Requests that reach a plugin's code: `handleRequest` (its own pages and
/// routes) and `resolveStream` (a stream resolved on play).
enum PluginRoutes {
    typealias Request = PluginHTTPServerCore.Request
    typealias Response = PluginHTTPServerCore.Response

    static let routeTimeout: TimeInterval = 30
    static let resolveTimeout: TimeInterval = 30
    /// What a plugin page served to the setup page may do: it runs sandboxed,
    /// so its scripts can't reach the setup page's own API.
    static let setupPagePolicy = "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads"

    // MARK: - Entry points

    /// The on-device server (``PluginLoopbackServer``).
    static func handleLocal(_ request: Request) async -> Response {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else { return text("Not found", status: 404) }
        switch segments[0] {
        case "resolve":
            return await resolve(key: segments[1], payload: request.query["p"] ?? "")
        case "stremio":
            // Plugins as add-ons for AIOStreams in Nuvio.
            return await PluginAIOBridge.handle(request)
        case "plugin":
            let base = PluginLoopbackServer.shared.baseURL.absoluteString + "plugin/\(segments[1])/"
            return await handlePlugin(
                key: segments[1],
                path: path(after: 2, in: request.path),
                request: request,
                origin: "device",
                baseURL: base
            )
        default:
            return text("Not found", status: 404)
        }
    }

    /// `/plugin/<provider>/…` on the setup page's server: a plugin's own
    /// configuration page ("Configure" on the page).
    static func handleSetupPage(_ request: Request) async -> Response {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else { return text("Not found", status: 404) }
        let host = request.headers["host"].map { "http://\($0)" } ?? ""
        let base = "\(host)\(request.basePath)/plugin/\(segments[1])/"
        var response = await handlePlugin(
            key: segments[1],
            path: path(after: 2, in: request.path),
            request: request,
            origin: "setup",
            baseURL: base
        )
        response.headers["Content-Security-Policy"] = setupPagePolicy
        response.headers["Access-Control-Allow-Origin"] = "*"
        return response
    }

    // MARK: - handleRequest

    static func handlePlugin(key: String, path: String, request: Request, origin: String, baseURL: String) async -> Response {
        if request.method == "OPTIONS" {
            var response = Response(status: 204, contentType: "text/plain; charset=utf-8", body: Data())
            response.headers["Access-Control-Allow-Origin"] = "*"
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
            response.headers["Access-Control-Allow-Headers"] = "Content-Type"
            return response
        }
        guard let scraper = await scraper(forKey: key) else { return text("Unknown provider", status: 404) }
        guard let code = await PluginStore.shared.code(for: scraper) else {
            return text("The provider's code is not available.", status: 502)
        }
        let settings = PluginSettingsVault.settings(scraperID: scraper.id)
        do {
            let value = try await PluginRuntime.call(
                code: code,
                scraperId: scraper.id,
                settings: settings,
                function: "handleRequest",
                arguments: [requestObject(request, path: path, origin: origin, baseURL: baseURL)],
                timeout: routeTimeout,
                keepAlive: scraper.keepAlive == true
            )
            return response(from: value)
        } catch PluginRuntimeError.missingFunction {
            return text("This provider has no pages.", status: 404)
        } catch {
            PluginLogStore.shared.append(scraper.id, level: .error, message: "handleRequest failed: \(error.localizedDescription)")
            return text(error.localizedDescription, status: 502)
        }
    }

    /// What `handleRequest(request)` receives.
    static func requestObject(_ request: Request, path: String, origin: String, baseURL: String) -> [String: Any] {
        var object: [String: Any] = [
            "method": request.method,
            "path": path.isEmpty ? "/" : path,
            "query": request.query,
            "headers": request.headers.filter { $0.key != "cookie" && $0.key != "authorization" },
            "baseUrl": baseURL,
            "origin": origin
        ]
        if let body = String(data: request.body, encoding: .utf8) {
            object["body"] = body
            let type = request.headers["content-type"]?.lowercased() ?? ""
            if type.hasPrefix("application/x-www-form-urlencoded") {
                var form: [String: String] = [:]
                let spaced = body.replacingOccurrences(of: "+", with: "%20")
                for item in URLComponents(string: "?" + spaced)?.queryItems ?? [] {
                    form[item.name] = item.value ?? ""
                }
                object["form"] = form
            } else if type.hasPrefix("application/json"),
                      let json = try? JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed]) {
                object["json"] = json
            }
        } else {
            object["body"] = ""
            object["bodyBase64"] = request.body.base64EncodedString()
        }
        return object
    }

    /// A string is an HTML page; an object may give `status`, `headers`,
    /// `contentType`, `redirect`, and `json`, `body` or `bodyBase64`.
    static func response(from value: Any) -> Response {
        if let html = value as? String {
            return Response(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        }
        guard let object = value as? [String: Any] else { return text("Not found", status: 404) }
        var status = (object["status"] as? NSNumber)?.intValue ?? 200
        if !(100...599).contains(status) { status = 200 }
        var headers: [String: String] = [:]
        var contentType: String?
        for (name, raw) in (object["headers"] as? [String: Any]) ?? [:] {
            guard let value = PluginJSON.text(raw) else { continue }
            switch name.lowercased() {
            case "content-type": contentType = value
            case "content-length", "connection", "transfer-encoding", "content-security-policy": continue
            default: headers[name] = value
            }
        }
        if let type = object["contentType"] as? String, !type.isEmpty { contentType = type }
        if let location = object["redirect"] as? String, !location.isEmpty {
            headers["Location"] = location
            if !(300..<400).contains(status) { status = 302 }
        }
        var body = Data()
        if let json = object["json"], !(json is NSNull) {
            body = (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            contentType = contentType ?? "application/json; charset=utf-8"
        } else if let base64 = object["bodyBase64"] as? String {
            body = Data(base64Encoded: base64) ?? Data()
            contentType = contentType ?? "application/octet-stream"
        } else if let text = object["body"].flatMap(PluginJSON.text) {
            body = Data(text.utf8)
        }
        var response = Response(status: status, contentType: contentType ?? "text/html; charset=utf-8", body: body)
        response.headers = headers
        return response
    }

    // MARK: - resolveStream

    static func resolve(key: String, payload encoded: String) async -> Response {
        guard let scraper = await scraper(forKey: key) else { return text("Unknown provider", status: 404) }
        guard let data = data(fromBase64URL: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return text("Bad stream", status: 400)
        }
        let cacheKey = key + "|" + encoded
        if let cached = await PluginResolveCache.shared.url(for: cacheKey) {
            return redirect(to: cached)
        }
        guard let code = await PluginStore.shared.code(for: scraper) else {
            return text("The provider's code is not available.", status: 502)
        }
        let settings = PluginSettingsVault.settings(scraperID: scraper.id)
        do {
            let value = try await PluginRuntime.call(
                code: code,
                scraperId: scraper.id,
                settings: settings,
                function: "resolveStream",
                arguments: [payload, ["platform": PluginTypes.platform]],
                timeout: resolveTimeout,
                keepAlive: scraper.keepAlive == true
            )
            guard let url = resolvedURL(from: value, scraperID: scraper.id) else {
                PluginLogStore.shared.append(scraper.id, level: .error, message: "resolveStream gave no http(s) URL.")
                return text("The provider found no link for this stream.", status: 502)
            }
            await PluginResolveCache.shared.store(url, for: cacheKey)
            PluginLogStore.shared.append(scraper.id, level: .info, message: "resolveStream → \(PluginNetworkLog.redact(URL(string: url)!))")
            return redirect(to: url)
        } catch {
            PluginLogStore.shared.append(scraper.id, level: .error, message: "resolveStream failed: \(error.localizedDescription)")
            return text(error.localizedDescription, status: 502)
        }
    }

    /// A URL string, or `{ url }`.
    static func resolvedURL(from value: Any, scraperID: String) -> String? {
        var text: String?
        if let string = value as? String {
            text = string
        } else if let object = value as? [String: Any] {
            text = object["url"].flatMap(PluginJSON.text)
            if let headers = object["headers"] as? [String: Any], !headers.isEmpty {
                PluginLogStore.shared.append(
                    scraperID,
                    level: .warn,
                    message: "resolveStream headers are not sent; give them on the stream (headers) instead."
                )
            }
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return trimmed
    }

    // MARK: - Helpers

    @MainActor
    private static func scraperOnMain(key: String) -> PluginScraperRecord? {
        let store = PluginStore.shared
        store.ensureLoaded()
        return store.state.scrapers.first { PluginAddonRegistry.key(for: $0.id) == key }
    }

    static func scraper(forKey key: String) async -> PluginScraperRecord? {
        await MainActor.run { scraperOnMain(key: key) }
    }

    /// The path after the first `count` segments, decoded, starting with `/`.
    static func path(after count: Int, in fullPath: String) -> String {
        var rest = Substring(fullPath)
        for _ in 0..<count {
            rest = rest.drop { $0 == "/" }
            if let slash = rest.firstIndex(of: "/") {
                rest = rest[slash...]
            } else {
                return "/"
            }
        }
        let decoded = String(rest).removingPercentEncoding ?? String(rest)
        return decoded.isEmpty ? "/" : decoded
    }

    private static func redirect(to url: String) -> Response {
        var response = Response(status: 302, contentType: "text/plain; charset=utf-8", body: Data())
        response.headers["Location"] = url
        return response
    }

    private static func text(_ message: String, status: Int) -> Response {
        Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(fromBase64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    /// Letters, digits, `.`, `-` and `_` only, at most 80 characters; nil when
    /// nothing is left.
    static func safeFileName(_ name: String?) -> String? {
        guard let name else { return nil }
        let mapped = name.map { (character: Character) -> Character in
            let allowed = character.isASCII
                && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
            return allowed ? character : "_"
        }
        let cleaned = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return cleaned.isEmpty ? nil : String(cleaned.suffix(80))
    }
}

/// Resolved stream links for 10 minutes, so a player that opens the address
/// again (seeking, retrying) doesn't make the plugin resolve it again.
actor PluginResolveCache {
    static let shared = PluginResolveCache()
    static let lifetime: TimeInterval = 10 * 60

    private var entries: [String: (url: String, date: Date)] = [:]

    func url(for key: String) -> String? {
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.date) < Self.lifetime else {
            entries[key] = nil
            return nil
        }
        return entry.url
    }

    func store(_ url: String, for key: String) {
        if entries.count > 200 {
            let limit = Date().addingTimeInterval(-Self.lifetime)
            entries = entries.filter { $0.value.date > limit }
        }
        entries[key] = (url, Date())
    }

    func removeAll() {
        entries.removeAll()
    }
}
