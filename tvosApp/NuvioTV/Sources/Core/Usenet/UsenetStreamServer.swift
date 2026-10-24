import Foundation
import Network

/// Local HTTP range server on 127.0.0.1 that hands the player bytes of one
/// Usenet file, the same way `TorrentStreamServer` does for torrents.
actor UsenetStreamServer {
    private let session: UsenetStreamSession
    private let fileName: String
    private let fileLength: Int64
    private let queue = DispatchQueue(label: "nuvio.usenet.stream.http")
    private var listener: NWListener?
    private var task: Task<Void, Never>?

    /// The newest playback read; an older one stops when the player seeks.
    private var playbackGeneration = 0
    private var playbackConnection: NWConnection?
    private var lastOffset: Int64 = -1

    private static let chunkBytes = 256 * 1024

    private(set) var port: UInt16 = 0
    nonisolated let token = UUID().uuidString
    nonisolated var path: String { "/usenet/\(token)/\(Self.safeName(fileName))" }
    var url: URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    init(session: UsenetStreamSession, fileName: String, fileLength: Int64) {
        self.session = session
        self.fileName = fileName
        self.fileLength = fileLength
    }

    func start() async throws -> URL {
        if let listener, listener.state == .ready { return url }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let incoming = AsyncStream<NWConnection> { continuation in
            listener.newConnectionHandler = { continuation.yield($0) }
            continuation.onTermination = { _ in listener.cancel() }
        }
        let ready = await Self.bind(listener, on: queue)
        guard ready, let actual = listener.port?.rawValue else {
            listener.cancel()
            throw UsenetError.serverRejected(L10n.string("usenet_error_local_server", fallback: "Couldn't start the local stream."))
        }
        self.listener = listener
        self.port = actual
        usenetLog.notice("stream: listening on 127.0.0.1:\(actual)")
        task = Task { await self.acceptLoop(incoming) }
        return url
    }

    func stop() {
        task?.cancel()
        task = nil
        listener?.cancel()
        listener = nil
        playbackConnection?.cancel()
        playbackConnection = nil
    }

    private nonisolated static func bind(_ listener: NWListener, on queue: DispatchQueue) async -> Bool {
        let gate = OnceGate<Bool>()
        return await withCheckedContinuation { continuation in
            gate.arm(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume(true)
                case .failed, .cancelled: gate.resume(false)
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { gate.resume(false) }
        }
    }

    private func acceptLoop(_ incoming: AsyncStream<NWConnection>) async {
        await withDiscardingTaskGroup { group in
            for await connection in incoming {
                group.addTask { await self.serve(connection) }
            }
        }
    }

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        var buffer = Data()
        do {
            try await NetworkIO.start(connection, on: queue)
            while !Task.isCancelled {
                let (head, rest) = try await readRequestHead(connection, buffer: buffer)
                buffer = rest
                guard try await respond(to: head, on: connection) else { return }
            }
        } catch {
        }
    }

    private func readRequestHead(_ connection: NWConnection, buffer: Data) async throws -> (head: String, rest: Data) {
        var buffer = buffer
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let end = buffer.range(of: terminator) {
                let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
                return (head, Data(buffer[end.upperBound...]))
            }
            guard buffer.count < 64 * 1024 else { throw NetworkIO.Failure.closed }
            buffer.append(try await NetworkIO.receive(connection, atMost: 8192))
        }
    }

    /// Parsed `Range:` header: nil for a whole-file request.
    nonisolated static func parseRange(_ header: String?, fileLength: Int64) -> ClosedRange<Int64>?? {
        guard let header else { return .some(nil) }
        let spec = header.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "bytes=", with: "")
        let first = spec.split(separator: ",").first.map(String.init) ?? spec
        let parts = first.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        var start: Int64
        var end = fileLength - 1
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            start = max(0, fileLength - suffix)
        } else {
            guard let value = Int64(parts[0]) else { return nil }
            start = value
            if let last = Int64(parts[1]) { end = min(last, fileLength - 1) }
        }
        start = max(0, start)
        guard start <= end, start < fileLength else { return nil }
        return .some(start...end)
    }

    private func respond(to request: String, on connection: NWConnection) async throws -> Bool {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }
        let parts = first.components(separatedBy: " ")
        let method = parts.first ?? "GET"
        let requested = parts.count > 1 ? String(parts[1].prefix { $0 != "?" && $0 != "#" }) : ""
        guard requested == path else {
            try await sendHead(connection, "404 Not Found", ["Content-Length": "0", "Connection": "close"])
            return false
        }

        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)) }
        guard let parsed = Self.parseRange(rangeHeader, fileLength: fileLength) else {
            try await sendHead(connection, "416 Range Not Satisfiable",
                               ["Content-Range": "bytes */\(fileLength)", "Connection": "close"])
            return false
        }
        let range = parsed ?? 0...(fileLength - 1)
        var headers = [
            "Content-Type": Self.mimeType(for: fileName),
            "Accept-Ranges": "bytes",
            "Content-Length": "\(range.upperBound - range.lowerBound + 1)",
            "Connection": "keep-alive",
        ]
        var status = "200 OK"
        if parsed != nil {
            status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileLength)"
        }
        try await sendHead(connection, status, headers)
        guard method != "HEAD" else { return true }

        // A read far from the last one is a seek: let it take over, so the old
        // read doesn't keep pulling articles the player no longer wants.
        // Reads of the last 16 MB are index lookups (MKV Cues) next to playback,
        // not seeks, so they never take over.
        let isTailRead = range.lowerBound >= max(0, fileLength - 16 * 1024 * 1024) && lastOffset >= 0
        let isSeek = !isTailRead && (lastOffset < 0 || abs(range.lowerBound - lastOffset) > 4 * 1024 * 1024)
        if isSeek {
            if let stale = playbackConnection, stale !== connection { stale.cancel() }
            playbackConnection = connection
            playbackGeneration &+= 1
        }
        let generation = playbackGeneration
        if !isTailRead { lastOffset = range.lowerBound }

        var position = range.lowerBound
        while position <= range.upperBound {
            try Task.checkCancellation()
            if connection === playbackConnection, generation != playbackGeneration { return false }
            let wanted = Int(min(Int64(Self.chunkBytes), range.upperBound - position + 1))
            let chunk = try await session.read(offset: position, maxLength: wanted, updatesPlayhead: !isTailRead)
            guard !chunk.isEmpty else { throw NetworkIO.Failure.closed }
            try await NetworkIO.send(connection, chunk)
            position += Int64(chunk.count)
            if connection === playbackConnection { lastOffset = position }
        }
        return true
    }

    private func sendHead(_ connection: NWConnection, _ status: String, _ headers: [String: String]) async throws {
        var text = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        try await NetworkIO.send(connection, Data(text.utf8))
    }

    nonisolated static func mimeType(for name: String) -> String {
        TorrentStreamServer.mimeType(for: name)
    }

    /// A URL-safe file name, so players that sniff the extension see `.mkv`.
    nonisolated static func safeName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let cleanExt = ext.allSatisfy { $0.isLetter || $0.isNumber } && !ext.isEmpty ? ext : "bin"
        return "video.\(cleanExt)"
    }
}
