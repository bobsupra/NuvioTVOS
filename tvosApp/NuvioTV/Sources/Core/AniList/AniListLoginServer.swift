import Darwin
import Foundation
import Network

/// Logs in to AniList without copying the token. The AniList client's Redirect URL is this Apple
/// TV's address in the home network; after "Authorize", AniList sends the phone's browser here,
/// and the page served here passes the token on. The token is in the address's fragment, which
/// browsers never send, so the page's script posts it back to this Apple TV, which checks it with
/// AniList and keeps it. Nuvio needs no server of its own: the phone and the Apple TV only have
/// to be on the same network. The listener runs only while logging in, for ten minutes at most.
final class AniListLoginServer: @unchecked Sendable {
    static let port: UInt16 = 47811
    static let path = "/anilist"
    /// MyAnimeList sends the phone here with `?code=…&state=…`; the Apple TV trades the code for
    /// the login itself (`exchange`), so this route needs no script.
    static let malPath = "/mal"
    static let lifetime: TimeInterval = 600

    enum State: Equatable, Sendable {
        case stopped
        /// Listening at this Redirect URL.
        case waiting(URL)
        case loggingIn
        case loggedIn(String)
        case failed(String)
    }

    static let shared = AniListLoginServer()

    private let queue = DispatchQueue(label: "nuvio.anilist-login", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var generation = UUID()
    private var expiry: DispatchWorkItem?
    private var expectedState = ""
    private var busy = false
    private var session: UUID?
    private var callback: (@Sendable (State) -> Void)?
    private var exchange: (@Sendable (String) async throws -> String)?

    /// The Redirect URL to give AniList: this Apple TV's address in the home network.
    static func redirectURL(path: String = AniListLoginServer.path) -> URL? {
        localIPv4Address().flatMap { URL(string: "http://\($0):\(port)\(path)") }
    }

    /// Listens for the phone. `expectedState` is the `state` of the address the QR code opens; a
    /// token coming back with another one was asked for elsewhere and is refused. `session`
    /// names this start, so a late `stop` of an earlier one leaves it running.
    /// `exchange` makes this a MyAnimeList login: the code MAL returns is given to it, and the
    /// name it answers is who logged in.
    func start(
        session: UUID,
        expectedState: String,
        exchange: (@Sendable (String) async throws -> String)? = nil,
        changed: @escaping @Sendable (State) -> Void
    ) {
        queue.async {
            self.stopOnQueue()
            self.session = session
            self.callback = changed
            self.expectedState = expectedState
            self.exchange = exchange
            guard let redirect = Self.redirectURL(path: exchange == nil ? Self.path : Self.malPath), let port = NWEndpoint.Port(rawValue: Self.port) else {
                changed(.failed("This Apple TV isn't on a home network."))
                return
            }
            let current = UUID()
            self.generation = current
            let expiry = DispatchWorkItem { [weak server = self] in
                guard let server, server.generation == current else { return }
                server.stopOnQueue()
                changed(.stopped)
            }
            self.expiry = expiry
            self.queue.asyncAfter(deadline: .now() + Self.lifetime, execute: expiry)
            self.listen(on: port, redirect: redirect, current: current, changed: changed, attempt: 1)
        }
    }

    /// Opens the port; the listener of a moment ago may still hold it, so a failure is tried
    /// again twice, a second apart.
    private func listen(on port: NWEndpoint.Port, redirect: URL, current: UUID, changed: @escaping @Sendable (State) -> Void, attempt: Int) {
        guard generation == current else { return }
        func failed() {
            listener?.cancel()
            listener = nil
            if attempt < 3 {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.listen(on: port, redirect: redirect, current: current, changed: changed, attempt: attempt + 1)
                }
            } else {
                stopOnQueue()
                changed(.failed("Port \(Self.port) is taken on this Apple TV."))
            }
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionLimit = 8
            self.listener = listener
            listener.stateUpdateHandler = { [weak server = self, weak listener] state in
                guard let server, server.generation == current, server.listener === listener else { return }
                switch state {
                case .ready:
                    changed(.waiting(redirect))
                case .failed:
                    failed()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak server = self] connection in
                guard let server, server.generation == current, server.connections.count < 4 else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                server.connections[id] = connection
                connection.start(queue: server.queue)
                server.receive(connection, id: id, buffered: Data())
                server.queue.asyncAfter(deadline: .now() + 45) { [weak server] in server?.finish(id) }
            }
            listener.start(queue: queue)
        } catch {
            failed()
        }
    }

    func stop(session: UUID) {
        queue.async {
            guard self.session == session else { return }
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        session = nil
        generation = UUID()
        expiry?.cancel()
        expiry = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        callback = nil
        exchange = nil
        busy = false
    }

    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    // MARK: Requests

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var request = buffered
            if let data { request.append(data) }
            guard request.count <= Self.maximumRequestBytes, error == nil else { self.finish(id); return }
            switch Self.parse(request) {
            case .incomplete:
                if complete { self.finish(id) } else { self.receive(connection, id: id, buffered: request) }
            case .invalid:
                self.send(Self.response(status: "400 Bad Request", type: "text/plain", body: Data()), on: connection, id: id)
            case .page:
                self.send(Self.response(status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8)), on: connection, id: id)
            case .notFound:
                self.send(Self.response(status: "404 Not Found", type: "text/plain", body: Data()), on: connection, id: id)
            case .token(let token, let state):
                self.logIn(token: token, state: state, connection: connection, id: id)
            case .code(let code, let state):
                self.trade(code: code, state: state, connection: connection, id: id)
            case .codeRefused(let message):
                self.sendPage(ok: false, message: message, connection: connection, id: id)
            }
        }
    }

    private func logIn(token: String, state: String?, connection: NWConnection, id: UUID) {
        if let state, !state.isEmpty, state != expectedState {
            answer(ok: false, message: "This login was started on another device. Scan the QR code on your Apple TV again.", connection: connection, id: id)
            return
        }
        guard !busy else {
            answer(ok: false, message: "Your Apple TV is already logging in.", connection: connection, id: id)
            return
        }
        busy = true
        let current = generation
        callback?(.loggingIn)
        Task { [weak self] in
            let ok: Bool
            let message: String
            let outcome: State
            do {
                let login = try await AniListAccount.logIn(pasted: token)
                ok = true
                message = "Logged in as \(login.viewerName). You can close this page."
                outcome = .loggedIn(login.viewerName)
            } catch {
                ok = false
                message = error.localizedDescription
                outcome = .failed(error.localizedDescription)
            }
            guard let self else { return }
            self.queue.async {
                guard self.generation == current else { return }
                self.busy = false
                let callback = self.callback
                self.answer(ok: ok, message: message, connection: connection, id: id) {
                    // Logged in: nothing more to wait for.
                    if ok, self.generation == current { self.stopOnQueue() }
                }
                callback?(outcome)
            }
        }
    }

    /// MyAnimeList's code, traded for the login by `exchange`; the phone gets a page saying how it went.
    private func trade(code: String, state: String?, connection: NWConnection, id: UUID) {
        guard let exchange else {
            sendPage(ok: false, message: "Start the MyAnimeList login on your Apple TV first.", connection: connection, id: id)
            return
        }
        guard state == expectedState else {
            sendPage(ok: false, message: "This login was started on another device. Scan the QR code on your Apple TV again.", connection: connection, id: id)
            return
        }
        guard !busy else {
            sendPage(ok: false, message: "Your Apple TV is already logging in.", connection: connection, id: id)
            return
        }
        busy = true
        let current = generation
        callback?(.loggingIn)
        Task { [weak self] in
            let ok: Bool
            let message: String
            let outcome: State
            do {
                let name = try await exchange(code)
                ok = true
                message = "Logged in to MyAnimeList as \(name). You can close this page."
                outcome = .loggedIn(name)
            } catch {
                ok = false
                message = error.localizedDescription
                outcome = .failed(error.localizedDescription)
            }
            guard let self else { return }
            self.queue.async {
                guard self.generation == current else { return }
                self.busy = false
                let callback = self.callback
                self.sendPage(ok: ok, message: message, connection: connection, id: id) {
                    if ok, self.generation == current { self.stopOnQueue() }
                }
                callback?(outcome)
            }
        }
    }

    private func sendPage(ok: Bool, message: String, connection: NWConnection, id: UUID, then: (() -> Void)? = nil) {
        let body = Data(Self.resultPage(ok: ok, message: message).utf8)
        send(Self.response(status: "200 OK", type: "text/html; charset=utf-8", body: body), on: connection, id: id, then: then)
    }

    static func resultPage(ok: Bool, message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Nuvio · MyAnimeList</title>
        <style>body{font:18px -apple-system,system-ui,sans-serif;background:#101114;color:#eee;margin:0;padding:48px 24px;text-align:center}
        h1{font-size:24px;margin:0 0 16px}p{line-height:1.45}.ok{color:#7ddc8a}.err{color:#ff8a80}</style></head>
        <body><h1>Nuvio · MyAnimeList</h1><p class="\(ok ? "ok" : "err")">\(escaped)</p></body></html>
        """
    }

    private func answer(ok: Bool, message: String, connection: NWConnection, id: UUID, then: (() -> Void)? = nil) {
        let body = (try? JSONSerialization.data(withJSONObject: ["ok": ok, "message": message])) ?? Data()
        send(Self.response(status: "200 OK", type: "application/json", body: body), on: connection, id: id, then: then)
    }

    private func send(_ response: Data, on connection: NWConnection, id: UUID, then: (() -> Void)? = nil) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.queue.async {
                self?.finish(id)
                then?()
            }
        })
    }

    // MARK: Parsing (static, for tests)

    static let maximumRequestBytes = 16_384

    enum Request: Equatable {
        case incomplete
        case invalid
        /// The page AniList sends the phone to.
        case page
        case notFound
        /// The token the page posts back, with the `state` AniList returned, if it did.
        case token(String, state: String?)
        /// MyAnimeList's code and `state`.
        case code(String, state: String?)
        /// MyAnimeList said no (the viewer cancelled, or the client is set up wrong).
        case codeRefused(String)
    }

    static func parse(_ request: Data) -> Request {
        guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: request[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .invalid }
        let method = String(parts[0])
        let target = String(parts[1])
        let route = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        var contentLength = 0
        for line in lines.dropFirst() {
            let field = line.split(separator: ":", maxSplits: 1)
            guard field.count == 2 else { continue }
            let name = field[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = field[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { return .invalid }
            if name == "content-length" {
                guard let length = Int(value), length >= 0, length <= maximumRequestBytes else { return .invalid }
                contentLength = length
            }
        }
        switch (method, route) {
        case ("GET", path), ("GET", path + "/"):
            return .page
        case ("GET", malPath), ("GET", malPath + "/"):
            let query = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let fields = formFields(query)
            if let code = fields["code"], !code.isEmpty {
                return .code(code, state: fields["state"])
            }
            let reason = fields["error_description"] ?? fields["message"] ?? fields["error"] ?? "No login arrived."
            return .codeRefused("MyAnimeList: \(reason)")
        case ("POST", path + "/token"):
            let body = request[headerEnd.upperBound...]
            guard body.count >= contentLength else { return .incomplete }
            let form = formFields(String(decoding: body.prefix(contentLength), as: UTF8.self))
            guard let token = form["access_token"], !token.isEmpty else { return .invalid }
            return .token(token, state: form["state"])
        default:
            return .notFound
        }
    }

    static func formFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = field.first else { continue }
            let value = field.count > 1 ? field[1] : ""
            func decoded(_ text: String) -> String {
                text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
            }
            fields[decoded(name)] = decoded(value)
        }
        return fields
    }

    static func response(status: String, type: String, body: Data) -> Data {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(type)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'",
            "Connection: close",
        ].joined(separator: "\r\n")
        var response = Data((headers + "\r\n\r\n").utf8)
        response.append(body)
        return response
    }

    /// Reads the token from the address AniList sent the phone to, takes it out of the address
    /// bar and the history, and posts it to this Apple TV.
    static let page = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Nuvio · AniList</title>
    <style>
    body{font:18px -apple-system,system-ui,sans-serif;background:#101114;color:#eee;margin:0;padding:48px 24px;text-align:center}
    h1{font-size:24px;margin:0 0 16px}p{color:#b8b8c0;line-height:1.45}.ok{color:#7ddc8a}.err{color:#ff8a80}
    </style></head>
    <body><h1>Nuvio · AniList</h1><p id="m">Sending the login to your Apple TV…</p>
    <script>
    (function(){
      var m=document.getElementById('m');
      var h=new URLSearchParams(location.hash.slice(1)), q=new URLSearchParams(location.search);
      var token=h.get('access_token'), state=h.get('state')||q.get('state');
      var error=h.get('error')||q.get('error'), detail=h.get('error_description')||q.get('error_description');
      try{history.replaceState(null,'',location.pathname)}catch(e){}
      function show(ok,text){m.className=ok?'ok':'err';m.textContent=text}
      if(!token){show(false,error?('AniList: '+(detail||error)):'No login arrived. Scan the QR code on your Apple TV again.');return}
      var body=new URLSearchParams();body.set('access_token',token);if(state){body.set('state',state)}
      fetch('\(path)/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body.toString()})
        .then(function(r){return r.json()})
        .then(function(j){show(!!j.ok,j.message||'')})
        .catch(function(){show(false,'Your Apple TV did not answer. Is the phone on the same Wi-Fi?')});
    })();
    </script></body></html>
    """

    // MARK: Address

    private static func localIPv4Address() -> String? {
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
