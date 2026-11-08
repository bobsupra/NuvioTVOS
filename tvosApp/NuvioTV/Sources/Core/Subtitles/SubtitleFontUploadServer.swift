import Darwin
import Foundation
import Network

/// The page another device opens to send fonts to this Apple TV (Settings → Subtitles → Custom
/// Fonts). It listens only while that screen is open, on the home network, at an address with a
/// key (kept or new each time, see `SubtitleFontPageKey`), and takes nothing but font files and links.
final class SubtitleFontUploadServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped, starting, ready(URL), failed
    }

    struct Head: Equatable, Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let contentLength: Int
    }

    enum Route: Equatable, Sendable {
        case page, list, upload(name: String), link, delete(id: String), notFound
    }

    struct Response: Sendable {
        let status: Int
        let contentType: String
        let body: Data

        static func json(_ object: [String: Any], status: Int = 200) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json; charset=utf-8", body: body)
        }

        static func text(_ text: String, status: Int) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (Route, Data) async -> Response

    static let preferredPort: UInt16 = 47812
    private static let headerLimit = 16_384
    /// Open at once. Browsers also open spare connections they may never use.
    private static let connectionLimit = 16
    private static let connectionTimeout: TimeInterval = 300
    /// A connection that hasn't sent its request by then is closed, so idle spares don't hold slots.
    private static let requestTimeout: TimeInterval = 20
    private static let lifetime: TimeInterval = 30 * 60

    private let queue = DispatchQueue(label: "nuvio.subtitle-font-upload", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var heads: [UUID: Head] = [:]
    private var generation = UUID()
    private var expiry: DispatchWorkItem?
    private var callback: (@Sendable (State) -> Void)?
    private var key = ""
    private var host = ""
    private var boundPort: UInt16?

    func start(key: String, handler: @escaping Handler, changed: @escaping @Sendable (State) -> Void) {
        queue.async {
            self.stopOnQueue()
            self.callback = changed
            self.key = key
            changed(.starting)
            guard let host = Self.localIPv4Address() else {
                changed(.failed)
                return
            }
            self.host = host
            self.listen(port: NWEndpoint.Port(rawValue: Self.preferredPort) ?? .any, attempt: 0, handler: handler)
        }
    }

    /// A new key for the running page (Keep the Same Address, New Address): the old address
    /// stops working at once, the port stays.
    func change(key: String) {
        queue.async {
            self.key = key
            guard self.listener != nil, let port = self.boundPort, let url = self.pageURL(port: port) else { return }
            self.callback?(.ready(url))
        }
    }

    func stop() {
        queue.async {
            let callback = self.callback
            self.stopOnQueue()
            callback?(.stopped)
        }
    }

    private func pageURL(port: UInt16) -> URL? {
        URL(string: "http://\(host):\(port)/fonts/\(key)")
    }

    private func listen(port: NWEndpoint.Port, attempt: Int, handler: @escaping Handler) {
        let current = UUID()
        generation = current
        // The usual port can still be held by the page that just closed: tried again a few
        // times before any free port is taken (the QR code carries it, a bookmark wouldn't).
        let retry: () -> Void = { [weak self] in
            guard let self, self.generation == current else { return }
            self.listener?.cancel()
            self.listener = nil
            if port != .any, attempt < 3 {
                self.queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.listen(port: port, attempt: attempt + 1, handler: handler)
                }
            } else if port != .any {
                self.listen(port: .any, attempt: 0, handler: handler)
            } else {
                let callback = self.callback
                self.stopOnQueue()
                callback?(.failed)
            }
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.generation == current else { return }
                switch state {
                case .ready:
                    guard let bound = listener?.port?.rawValue, let url = self.pageURL(port: bound) else {
                        let callback = self.callback
                        self.stopOnQueue()
                        callback?(.failed)
                        return
                    }
                    self.boundPort = bound
                    self.callback?(.ready(url))
                case .failed:
                    retry()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == current, self.connections.count < Self.connectionLimit else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: self.queue)
                self.receive(connection, id: id, handler: handler)
                self.queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
                    guard let self, self.heads[id] == nil else { return }
                    self.finish(id)
                }
                self.queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak self] in
                    self?.finish(id)
                }
            }
            if expiry == nil {
                let expiry = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let callback = self.callback
                    self.stopOnQueue()
                    callback?(.stopped)
                }
                self.expiry = expiry
                queue.asyncAfter(deadline: .now() + Self.lifetime, execute: expiry)
            }
            listener.start(queue: queue)
        } catch {
            retry()
        }
    }

    private func stopOnQueue() {
        generation = UUID()
        expiry?.cancel()
        expiry = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        buffers.removeAll()
        heads.removeAll()
        callback = nil
        boundPort = nil
    }

    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        buffers.removeValue(forKey: id)
        heads.removeValue(forKey: id)
    }

    private func receive(_ connection: NWConnection, id: UUID, handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            guard error == nil else {
                self.finish(id)
                return
            }
            if let data, !data.isEmpty {
                self.buffers[id, default: Data()].append(data)
            }

            if self.heads[id] == nil {
                let buffer = self.buffers[id] ?? Data()
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > Self.headerLimit || complete {
                        self.send(.text("Bad request", status: 400), on: connection, id: id)
                    } else {
                        self.receive(connection, id: id, handler: handler)
                    }
                    return
                }
                guard let head = Self.parseHead(Data(buffer[buffer.startIndex..<end.lowerBound])) else {
                    self.send(.text("Bad request", status: 400), on: connection, id: id)
                    return
                }
                guard head.contentLength <= SubtitleFontLimits.downloadBytes else {
                    self.send(.json(["error": SubtitleFontError.tooLarge(SubtitleFontLimits.downloadBytes).errorDescription ?? ""], status: 413), on: connection, id: id)
                    return
                }
                self.heads[id] = head
                var body = Data(buffer[end.upperBound...])
                body.reserveCapacity(head.contentLength)
                self.buffers[id] = body
            }

            guard let head = self.heads[id] else { return }
            let received = self.buffers[id]?.count ?? 0
            if received < head.contentLength {
                if complete {
                    self.finish(id)
                } else {
                    self.receive(connection, id: id, handler: handler)
                }
                return
            }
            let body = Data((self.buffers[id] ?? Data()).prefix(head.contentLength))
            self.buffers[id] = nil
            let route = Self.route(head, key: self.key)
            Task {
                let response = await handler(route, body)
                self.queue.async {
                    guard self.connections[id] != nil else { return }
                    self.send(response, on: connection, id: id)
                }
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection, id: UUID) {
        let head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finish(id)
        })
    }

    // MARK: Requests

    /// The request line and headers (without the blank line that ends them). Chunked bodies
    /// aren't taken: browsers send a length with a file.
    static func parseHead(_ data: Data) -> Head? {
        guard data.count <= headerLimit, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/"),
              let components = URLComponents(string: "http://tv" + String(parts[1])) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        var length = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { return nil }
            if name == "content-length" {
                guard let parsed = Int(value), parsed >= 0 else { return nil }
                length = parsed
            }
        }
        return Head(method: String(parts[0]), path: components.path, query: query, contentLength: length)
    }

    static func route(_ head: Head, key: String) -> Route {
        let base = "/fonts/" + key
        let path = head.path.hasSuffix("/") && head.path.count > 1 ? String(head.path.dropLast()) : head.path
        switch head.method {
        case "GET":
            if path == base { return .page }
            if path == base + "/list" { return .list }
        case "PUT", "POST":
            if path == base + "/upload", let name = head.query["name"], !name.isEmpty {
                return .upload(name: (name as NSString).lastPathComponent)
            }
            if head.method == "POST", path == base + "/link" { return .link }
            if head.method == "POST", path == base + "/delete", let id = head.query["id"], !id.isEmpty {
                return .delete(id: id)
            }
        default:
            break
        }
        return .notFound
    }

    /// Six characters that can't be mistaken for each other when typed from the screen.
    static func makeKey() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Content"
        default: return "Error"
        }
    }

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

// MARK: - The page's address

/// The key in the page's address. Kept on this Apple TV while Keep the Same Address is on (the
/// default), so the address can be bookmarked; otherwise new each time the screen opens.
enum SubtitleFontPageKey {
    static let keepAddressKey = "nuvio.tv.subtitleFonts.keepAddress"
    private static let savedKey = "nuvio.tv.subtitleFonts.addressKey"
    private static let alphabet = "abcdefghjkmnpqrstuvwxyz23456789"

    static var keepsAddress: Bool {
        UserDefaults.standard.object(forKey: keepAddressKey) == nil ? true : UserDefaults.standard.bool(forKey: keepAddressKey)
    }

    static func current() -> String {
        guard keepsAddress else { return SubtitleFontUploadServer.makeKey() }
        if let saved = UserDefaults.standard.string(forKey: savedKey), isValid(saved) { return saved }
        return renew()
    }

    /// A new kept key (New Address): the old address stops working.
    @discardableResult
    static func renew() -> String {
        let key = SubtitleFontUploadServer.makeKey()
        UserDefaults.standard.set(key, forKey: savedKey)
        return key
    }

    static func isValid(_ key: String) -> Bool {
        key.count == 6 && key.allSatisfy { alphabet.contains($0) }
    }
}

// MARK: - What the page asks

@MainActor
enum SubtitleFontWebAPI {
    static func respond(to route: SubtitleFontUploadServer.Route, body: Data) async -> SubtitleFontUploadServer.Response {
        let library = SubtitleFontLibrary.shared
        switch route {
        case .page:
            return SubtitleFontUploadServer.Response(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(SubtitleFontUploadPage.html.utf8)
            )
        case .list:
            await library.load()
            let fonts: [[String: Any]] = library.fonts.map { font in
                [
                    "id": font.id,
                    "name": font.displayName,
                    "family": font.family,
                    "bytes": font.bytes,
                    "link": font.link ?? "",
                    "missing": library.isMissing(font),
                ]
            }
            return .json(["fonts": fonts])
        case let .upload(name):
            do {
                let added = try await library.add(data: body, fileName: name, link: nil)
                return .json(["added": added.map(\.displayName)])
            } catch {
                return .json(["error": SubtitleFontError.message(for: error)], status: 422)
            }
        case .link:
            do {
                let added = try await library.add(link: String(decoding: body, as: UTF8.self))
                return .json(["added": added.map(\.displayName)])
            } catch {
                return .json(["error": SubtitleFontError.message(for: error)], status: 422)
            }
        case let .delete(id):
            library.delete(id: id)
            return .json(["ok": true])
        case .notFound:
            return .text("Not found", status: 404)
        }
    }
}

// MARK: - The page

enum SubtitleFontUploadPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Nuvio · Subtitle Fonts</title>
    <style>
    :root { color-scheme: dark; --bg: #0f1115; --panel: #181b22; --line: #2c313d; --fg: #eef0f5; --muted: #9aa1b2; --accent: #f0a63a; --ok: #4cc27f; --bad: #ff7676; }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; padding: 24px 16px 48px; }
    main { max-width: 640px; margin: 0 auto; display: grid; gap: 16px; }
    h1 { font-size: 26px; margin: 0 0 4px; }
    h2 { font-size: 17px; margin: 0; }
    p { margin: 0; color: var(--muted); }
    section { background: var(--panel); border: 1px solid var(--line); border-radius: 14px; padding: 16px; display: grid; gap: 12px; }
    #drop { border: 2px dashed var(--line); border-radius: 12px; padding: 22px 12px; text-align: center; display: grid; gap: 10px; justify-items: center; }
    #drop.over { border-color: var(--accent); background: #2a2112; }
    button, .button { font: inherit; font-weight: 600; border: 0; border-radius: 10px; padding: 10px 18px; background: var(--fg); color: var(--bg); cursor: pointer; }
    button.ghost { background: transparent; color: var(--muted); border: 1px solid var(--line); padding: 6px 12px; font-weight: 500; flex: none; }
    .hidden-input { position: absolute; width: 1px; height: 1px; opacity: 0; pointer-events: none; }
    input[type=text] { font: inherit; width: 100%; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--line); background: var(--bg); color: var(--fg); }
    .row { display: flex; gap: 8px; }
    .row input { flex: 1; min-width: 0; }
    progress { width: 100%; accent-color: var(--accent); }
    #log { display: grid; gap: 4px; font-size: 14px; }
    #log:empty { display: none; }
    .ok { color: var(--ok); } .bad { color: var(--bad); }
    ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
    li { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 12px; border-radius: 10px; background: var(--bg); }
    li div { min-width: 0; }
    li b { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; }
    li small { color: var(--muted); }
    </style>
    </head>
    <body>
    <main>
      <header>
        <h1>Subtitle Fonts</h1>
        <p>Fonts you add here go straight to Nuvio on your Apple TV. Keep Custom Fonts open on the TV while you do.</p>
      </header>

      <section>
        <h2>Send font files</h2>
        <div id="drop">
          <p>TTF, OTF or TTC files, or a ZIP with fonts in it</p>
          <label class="button" for="files">Choose files</label>
          <input id="files" class="hidden-input" type="file" multiple accept=".ttf,.otf,.ttc,.zip">
          <p>or drop them here</p>
        </div>
        <progress id="bar" max="1" value="0" hidden></progress>
      </section>

      <section>
        <h2>Add from a link</h2>
        <p>A font file or a ZIP, or a GitHub, Dropbox, Google Drive or Google Fonts link. The Apple TV downloads it itself.</p>
        <form id="linkForm" class="row">
          <input id="link" type="text" inputmode="url" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="https://…">
          <button>Add</button>
        </form>
      </section>

      <div id="log" aria-live="polite"></div>

      <section>
        <h2>Fonts on the Apple TV</h2>
        <ul id="list"></ul>
        <p id="empty" hidden>No fonts yet.</p>
      </section>
    </main>
    <script>
    const base = location.pathname.replace(/\/+$/, '');
    const logBox = document.getElementById('log');
    function log(text, kind) {
      const line = document.createElement('div');
      line.textContent = text;
      if (kind) line.className = kind;
      logBox.prepend(line);
    }
    function size(bytes) {
      return bytes >= 1e6 ? (bytes / 1e6).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1e3)) + ' KB';
    }
    async function refresh() {
      try {
        const response = await fetch(base + '/list', { cache: 'no-store' });
        const json = await response.json();
        const list = document.getElementById('list');
        list.textContent = '';
        document.getElementById('empty').hidden = json.fonts.length > 0;
        for (const font of json.fonts) {
          const item = document.createElement('li');
          const text = document.createElement('div');
          const name = document.createElement('b');
          name.textContent = font.name;
          const details = document.createElement('small');
          const source = font.missing ? 'missing, add it again' : (font.link ? 'from a link' : 'sent from a device');
          details.textContent = [font.family, size(font.bytes), source].join(' · ');
          text.append(name, details);
          const remove = document.createElement('button');
          remove.className = 'ghost';
          remove.textContent = 'Delete';
          remove.onclick = async () => {
            await fetch(base + '/delete?id=' + encodeURIComponent(font.id), { method: 'POST' });
            refresh();
          };
          item.append(text, remove);
          list.append(item);
        }
      } catch (error) {
        log('The Apple TV isn’t answering. Is Custom Fonts still open there?', 'bad');
      }
    }
    function upload(file) {
      return new Promise(resolve => {
        const request = new XMLHttpRequest();
        const bar = document.getElementById('bar');
        request.open('PUT', base + '/upload?name=' + encodeURIComponent(file.name));
        bar.hidden = false;
        bar.value = 0;
        request.upload.onprogress = event => { if (event.lengthComputable) bar.value = event.loaded / event.total; };
        request.onload = () => {
          bar.hidden = true;
          let json = {};
          try { json = JSON.parse(request.responseText); } catch (error) {}
          if (request.status === 200) log(file.name + ': added ' + (json.added || []).join(', '), 'ok');
          else log(file.name + ': ' + (json.error || 'not added'), 'bad');
          resolve();
        };
        request.onerror = () => {
          bar.hidden = true;
          log(file.name + ': the Apple TV isn’t answering', 'bad');
          resolve();
        };
        request.send(file);
      });
    }
    async function send(files) {
      for (const file of files) await upload(file);
      refresh();
    }
    document.getElementById('files').addEventListener('change', event => {
      send(Array.from(event.target.files));
      event.target.value = '';
    });
    const drop = document.getElementById('drop');
    ['dragenter', 'dragover'].forEach(type => drop.addEventListener(type, event => { event.preventDefault(); drop.classList.add('over'); }));
    ['dragleave', 'drop'].forEach(type => drop.addEventListener(type, event => { event.preventDefault(); drop.classList.remove('over'); }));
    drop.addEventListener('drop', event => send(Array.from(event.dataTransfer.files)));
    document.getElementById('linkForm').addEventListener('submit', async event => {
      event.preventDefault();
      const input = document.getElementById('link');
      const link = input.value.trim();
      if (!link) return;
      log('Downloading ' + link + ' …');
      try {
        const response = await fetch(base + '/link', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: link });
        const json = await response.json();
        if (response.ok) { log('Added ' + (json.added || []).join(', '), 'ok'); input.value = ''; }
        else log(json.error || 'Not added', 'bad');
      } catch (error) {
        log('The Apple TV isn’t answering.', 'bad');
      }
      refresh();
    });
    refresh();
    </script>
    </body>
    </html>
    """#
}
