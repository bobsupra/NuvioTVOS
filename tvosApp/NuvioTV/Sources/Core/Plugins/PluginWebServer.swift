import Foundation
import Network
import Darwin
import Security

/// Settings → Plugins → "Set Up from a Computer": a small web server on the
/// Apple TV's local network address, so plugin repositories, providers and
/// their settings (API keys) can be managed from a browser on a computer or
/// phone instead of the Siri Remote keyboard.
///
/// It runs only while that screen is open and stops after 15 minutes without
/// a request. Every address carries a random token, it answers on the local
/// network interface only, and saved passwords are never sent back in full.
@MainActor
final class PluginWebServer: ObservableObject {
    enum Phase: Equatable {
        case stopped
        case starting
        case ready(URL)
        case failed(String)
    }

    static let shared = PluginWebServer()
    static let idleTimeout: TimeInterval = 15 * 60
    /// Tried first so the address stays short and the same; any free port
    /// is used when it is taken.
    static let preferredPort: UInt16 = 8765
    private static let keepAddressKey = "plugins.web.keepAddress"

    @Published private(set) var phase: Phase = .stopped
    /// When the last request arrived (the screen shows "connected").
    @Published private(set) var lastActivity: Date?
    /// "Keep the Same Address": the token is saved on this Apple TV and
    /// reused, so the page can be bookmarked.
    @Published private(set) var keepsAddress: Bool

    private var core: PluginHTTPServerCore?
    private var currentToken: String?

    private init() {
        keepsAddress = UserDefaults.standard.bool(forKey: Self.keepAddressKey)
    }

    func start() {
        guard core == nil else { return }
        phase = .starting
        lastActivity = nil
        let token = keepsAddress ? PluginWebAddressStore.token() : Self.makeToken()
        currentToken = token
        let core = PluginHTTPServerCore(
            token: token,
            idleTimeout: Self.idleTimeout,
            handler: { request in await PluginWebAPI.handle(request) }
        )
        self.core = core
        core.start(
            preferredPort: Self.preferredPort,
            onState: { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.core === core else { return }
                    switch state {
                    case .ready(let url): self.phase = .ready(url)
                    case .failed(let message):
                        self.phase = .failed(message)
                        self.core = nil
                    case .stopped:
                        self.phase = .stopped
                        self.core = nil
                    }
                }
            },
            onActivity: { [weak self] in
                Task { @MainActor [weak self] in self?.lastActivity = Date() }
            }
        )
    }

    func stop() {
        core?.stop()
        core = nil
        phase = .stopped
    }

    /// Turning it on keeps the address that is on screen now.
    func setKeepsAddress(_ keep: Bool) {
        guard keep != keepsAddress else { return }
        keepsAddress = keep
        UserDefaults.standard.set(keep, forKey: Self.keepAddressKey)
        if keep {
            PluginWebAddressStore.save(currentToken ?? Self.makeToken())
        } else {
            PluginWebAddressStore.remove()
        }
    }

    /// A new code in the address (when someone else knows the old one).
    func makeNewAddress() {
        if keepsAddress { PluginWebAddressStore.save(Self.makeToken()) }
        let wasRunning = core != nil
        stop()
        guard wasRunning else { return }
        phase = .starting
        // Give the old listener a moment to let go of the port.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            // Not when the screen was closed meanwhile (stop() resets the phase).
            guard let self, self.phase == .starting, self.core == nil else { return }
            self.start()
        }
    }

    nonisolated static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 10)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = bytes.map { _ in UInt8.random(in: 0...255) }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

/// The HTTP side: an `NWListener` on the local IPv4 address (or loopback)
/// with tiny, request-per-connection HTTP/1.1 handling. Requests outside
/// `/<token>/` get a 404 without reaching the handler.
final class PluginHTTPServerCore: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
        /// Header names lowercased.
        var headers: [String: String] = [:]
        /// `/<token>`: what the server cut off `path`, for absolute links.
        var basePath: String = ""

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        var headers: [String: String] = [:]

        static func json(_ object: [String: Any], status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json; charset=utf-8", body: data)
        }

        static func error(_ message: String, status: Int = 400) -> Response {
            json(["ok": false, "error": message], status: status)
        }
    }

    enum State: Sendable {
        case ready(URL)
        case failed(String)
        case stopped
    }

    /// Room for provider code uploaded from the setup page.
    static let maxRequestBytes = 8 << 20

    private let token: String
    private let idleTimeout: TimeInterval?
    private let handler: @Sendable (Request) async -> Response
    private let queue = DispatchQueue(label: "nuvio.plugins.web", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var idleTimer: DispatchWorkItem?
    private var onState: (@Sendable (State) -> Void)?
    private var onActivity: (@Sendable () -> Void)?
    private var stopped = false

    init(token: String, idleTimeout: TimeInterval?, handler: @escaping @Sendable (Request) async -> Response) {
        self.token = token
        self.idleTimeout = idleTimeout
        self.handler = handler
    }

    /// - Parameter host: the address to listen on; the local network
    ///   address when nil.
    func start(
        preferredPort: UInt16?,
        host fixedHost: String? = nil,
        onState: @escaping @Sendable (State) -> Void,
        onActivity: @escaping @Sendable () -> Void
    ) {
        queue.async {
            self.onState = onState
            self.onActivity = onActivity
            guard let host = fixedHost ?? Self.localIPv4Address() else {
                self.finish(.failed("The Apple TV has no local network address. Is it connected to Wi-Fi or Ethernet?"))
                return
            }
            self.listen(host: host, port: preferredPort)
        }
    }

    /// Listens on `host`; when `port` is taken, tries again on any free port.
    private func listen(host: String, port: UInt16?) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let localPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: localPort)
            let listener = try NWListener(using: parameters)
            listener.newConnectionLimit = 32
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, !self.stopped, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let boundPort = listener.port,
                          let url = URL(string: "http://\(host):\(boundPort.rawValue)/\(self.token)/") else {
                        self.finish(.failed("The server could not start."))
                        return
                    }
                    self.resetIdleTimer()
                    self.onState?(.ready(url))
                case .failed(let error), .waiting(let error):
                    if port != nil {
                        listener.cancel()
                        self.listener = nil
                        self.listen(host: host, port: nil)
                    } else if case .failed = state {
                        self.finish(.failed(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            if port != nil {
                listen(host: host, port: nil)
            } else {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 16 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, buffered: Data())
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.close(id) }
    }

    func stop() {
        queue.async { self.finish(.stopped) }
    }

    private func finish(_ state: State) {
        guard !stopped else { return }
        stopped = true
        idleTimer?.cancel()
        idleTimer = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        onState?(state)
        onState = nil
        onActivity = nil
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        guard let idleTimeout else { return }
        let timer = DispatchWorkItem { [weak self] in self?.finish(.stopped) }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: timer)
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var request = buffered
            if let data { request.append(data) }
            guard error == nil, request.count <= Self.maxRequestBytes else {
                self.close(id)
                return
            }
            switch Self.parse(request) {
            case .incomplete:
                if complete { self.close(id) } else { self.receive(connection, id: id, buffered: request) }
            case .invalid:
                self.send(Response.error("Bad request"), on: connection, id: id)
            case .complete(let parsed):
                self.route(parsed, connection: connection, id: id)
            }
        }
    }

    private func route(_ request: Request, connection: NWConnection, id: UUID) {
        let prefix = "/\(token)"
        guard request.path == prefix || request.path.hasPrefix(prefix + "/") else {
            send(Response(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8)), on: connection, id: id)
            return
        }
        resetIdleTimer()
        onActivity?()
        if request.path == prefix {
            var redirect = Response(status: 301, contentType: "text/plain; charset=utf-8", body: Data())
            redirect.headers["Location"] = prefix + "/"
            send(redirect, on: connection, id: id)
            return
        }
        let inner = Request(
            method: request.method,
            path: String(request.path.dropFirst(prefix.count)),
            query: request.query,
            body: request.body,
            headers: request.headers,
            basePath: prefix
        )
        let handler = self.handler
        let isHead = request.method == "HEAD"
        Task {
            let response = await handler(inner)
            self.queue.async { self.send(response, on: connection, id: id, withBody: !isHead) }
        }
    }

    private func send(_ response: Response, on connection: NWConnection, id: UUID, withBody: Bool = true) {
        guard connections[id] != nil else { return }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        let custom = Set(response.headers.keys.map { $0.lowercased() })
        if !custom.contains("cache-control") { head += "Cache-Control: no-store\r\n" }
        head += "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        for (name, value) in response.headers {
            // No header injection through a plugin's values.
            let cleanName = name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let cleanValue = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            guard !cleanName.isEmpty else { continue }
            head += "\(cleanName): \(cleanValue)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if withBody { data.append(response.body) }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.close(id) }
        })
    }

    // MARK: - Parsing

    enum ParseResult {
        case incomplete
        case invalid
        case complete(Request)
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16_384 ? .invalid : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }
        var contentLength = 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if headers.count < 64 { headers[name] = value }
            if name == "content-length" {
                guard let length = Int(value), length >= 0, length <= maxRequestBytes else { return .invalid }
                contentLength = length
            } else if name == "transfer-encoding" {
                return .invalid
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(Request(
            method: String(parts[0]).uppercased(),
            path: components?.percentEncodedPath ?? target,
            query: query,
            body: body,
            headers: headers
        ))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 504: return "Gateway Timeout"
        default: return status < 400 ? "OK" : "Error"
        }
    }

    static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var next = interfaces
        while let item = next {
            defer { next = item.pointee.ifa_next }
            let info = item.pointee
            guard let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  info.ifa_flags & UInt32(IFF_UP) != 0,
                  info.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  String(cString: info.ifa_name).hasPrefix("en") else { continue }
            let result: String? = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ip = pointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let result { return result }
        }
        return nil
    }
}

/// The saved token for "Keep the Same Address", in Keychain on this Apple TV
/// only (not synced, not per profile).
enum PluginWebAddressStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.nuvio.tv.plugins.web",
        kSecAttrAccount as String: "address-token"
    ]

    /// The saved token, or a new one that is saved right away.
    static func token() -> String {
        var lookup = query
        lookup[kSecReturnData as String] = kCFBooleanTrue
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let token = String(data: data, encoding: .utf8), token.count >= 8 {
            return token
        }
        let token = PluginWebServer.makeToken()
        save(token)
        return token
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
