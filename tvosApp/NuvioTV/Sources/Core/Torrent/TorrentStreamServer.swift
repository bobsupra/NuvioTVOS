import Foundation
import Network
import OSLog

actor TorrentStreamServer {
    private let engine: TorrentEngine
    private let filePath: String
    private let fileOffset: Int64
    private let fileLength: Int64
    private let pieceLength: Int64
    private let waiters: PieceWaiterRegistry

    private let preferredPort: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nuvio.torrent.stream.http")
    private var task: Task<Void, Never>?
    private var reprimeTask: Task<Void, Never>?

    private let urgentBytes: Int64 = 8 * 1024 * 1024
    private let readaheadBytes: Int64 = 96 * 1024 * 1024
    private let minCorePieces = 2
    private let minReadaheadPieces = 16
    private let tailBytes: Int64 = 16 * 1024 * 1024

    private let topPriority = 7
    private let readaheadPriority = 5
    private let backgroundPriority = 0

    private var playbackConnection: NWConnection?
    private var playbackGeneration = 0
    private var lastPlayhead: Int64 = -1
    private var deadlineWindow: ClosedRange<Int>?

    private(set) var port: UInt16 = 0
    nonisolated let token = UUID().uuidString
    nonisolated var path: String { "/stream/\(token)" }
    var url: URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    init(
        engine: TorrentEngine,
        filePath: String,
        fileOffset: Int64,
        fileLength: Int64,
        waiters: PieceWaiterRegistry,
        pieceLength: Int,
        port: UInt16 = 8888
    ) {
        self.engine = engine
        self.filePath = filePath
        self.fileOffset = fileOffset
        self.fileLength = fileLength
        self.pieceLength = Int64(pieceLength)
        self.waiters = waiters
        self.preferredPort = port
    }

    func start() async throws -> URL {
        if let listener, listener.state == .ready { return url }
        var bound: (NWListener, AsyncStream<NWConnection>)?
        for candidate in [preferredPort, 0] {
            let listener = try Self.makeListener(port: candidate)
            let incoming = AsyncStream<NWConnection> { continuation in
                listener.newConnectionHandler = { continuation.yield($0) }
                continuation.onTermination = { _ in listener.cancel() }
            }
            if await Self.bind(listener, on: queue) {
                bound = (listener, incoming)
                break
            }
            listener.cancel()
            torrentLog.notice("stream: port \(candidate) unavailable, trying ephemeral port")
        }
        guard let (listener, incoming) = bound, let actual = listener.port?.rawValue else {
            throw TorrentEngineError.failedToStart
        }
        self.listener = listener
        self.port = actual
        torrentLog.notice("stream: listening on 127.0.0.1:\(actual)")

        task = Task { await self.acceptLoop(incoming) }
        reprimeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.reprimeUntilHeadLands() { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        return url
    }

    private nonisolated static func makeListener(port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        return try NWListener(using: params)
    }

    private nonisolated static func bind(_ listener: NWListener, on queue: DispatchQueue) async -> Bool {
        let gate = OnceGate<Bool>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
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
        } onCancel: {
            gate.resume(false)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        reprimeTask?.cancel()
        reprimeTask = nil
        listener?.cancel()
        listener = nil
    }

    @discardableResult
    func updatePlayhead(absoluteOffset: Int64) -> Bool {
        let fileEnd = fileOffset + fileLength - 1
        let tailStart = max(fileOffset, fileEnd + 1 - tailBytes)
        if absoluteOffset >= tailStart && absoluteOffset <= fileEnd { return false }

        let lastPiece = Int(fileEnd / pieceLength)
        let playPiece = Int(absoluteOffset / pieceLength)

        var coreEnd = min(lastPiece, max(Int(min(absoluteOffset + urgentBytes, fileEnd) / pieceLength),
                                         playPiece + minCorePieces))
        var readaheadEnd = min(lastPiece, max(Int(min(absoluteOffset + readaheadBytes, fileEnd) / pieceLength),
                                              playPiece + minReadaheadPieces))
        if lastPiece - playPiece <= minReadaheadPieces {
            coreEnd = lastPiece
            readaheadEnd = lastPiece
        }
        guard readaheadEnd >= playPiece else { lastPlayhead = absoluteOffset; return true }

        let newWindow = playPiece...readaheadEnd
        if let old = deadlineWindow {
            for p in old where !newWindow.contains(p) {
                engine.setPiecePriority(p, priority: backgroundPriority)
                engine.clearPieceDeadline(p)
            }
        }
        var step = 0
        for p in newWindow {
            let isCore = p <= coreEnd
            engine.setPiecePriority(p, priority: isCore ? topPriority : readaheadPriority)
            if isCore {
                engine.setPieceDeadline(p, milliseconds: step * 80)
            } else {
                engine.clearPieceDeadline(p)
            }
            step += 1
        }
        deadlineWindow = newWindow
        lastPlayhead = absoluteOffset
        return true
    }

    private func reprimeUntilHeadLands() -> Bool {
        let fileEnd = fileOffset + fileLength - 1
        let headEnd = Int(min(fileOffset + min(2 * 1024 * 1024, fileLength) - 1, fileEnd) / pieceLength)
        let firstPiece = Int(fileOffset / pieceLength)
        let lastPiece = Int(fileEnd / pieceLength)
        let tailStartPiece = Int(max(fileOffset, fileEnd + 1 - tailBytes) / pieceLength)
        let headDone = (firstPiece...max(firstPiece, headEnd)).allSatisfy { engine.hasPiece($0) }
        let tailDone = (min(tailStartPiece, lastPiece)...lastPiece).allSatisfy { engine.hasPiece($0) }
        if headDone && tailDone { return true }
        primeHeadAndTail()
        if lastPlayhead >= 0 { updatePlayhead(absoluteOffset: lastPlayhead) }
        return false
    }

    func primeHeadAndTail() {
        let fileEnd = fileOffset + fileLength - 1
        let headEnd = Int(min(fileOffset + min(2 * 1024 * 1024, fileLength) - 1, fileEnd) / pieceLength)
        let firstPiece = Int(fileOffset / pieceLength)
        let lastPiece = Int(fileEnd / pieceLength)
        let tailStartPiece = Int(max(fileOffset, fileEnd + 1 - tailBytes) / pieceLength)
        if firstPiece <= headEnd {
            for p in firstPiece...headEnd {
                engine.setPiecePriority(p, priority: topPriority)
                engine.setPieceDeadline(p, milliseconds: 0)
            }
        }
        if tailStartPiece <= lastPiece {
            for p in tailStartPiece...lastPiece {
                engine.setPiecePriority(p, priority: topPriority)
                engine.setPieceDeadline(p, milliseconds: 500)
            }
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

    private func respond(to request: String, on connection: NWConnection) async throws -> Bool {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }
        let requestParts = first.components(separatedBy: " ")
        let method = requestParts.first ?? "GET"
        var requestedPath = requestParts.count > 1
            ? String(requestParts[1].prefix { $0 != "?" && $0 != "#" }) : ""
        if requestedPath.hasPrefix("http"), let range = requestedPath.range(of: "://") {
            let afterScheme = requestedPath[range.upperBound...]
            requestedPath = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        guard requestedPath == path else {
            try await sendHead(connection, "404 Not Found", ["Content-Length": "0", "Connection": "close"])
            return false
        }

        var rangeStart: Int64 = 0
        var rangeEnd: Int64 = fileLength - 1
        var isRange = false
        for line in lines where line.lowercased().hasPrefix("range:") {
            isRange = true
            let spec = line.dropFirst("range:".count)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.components(separatedBy: "-")
            if parts.count == 2 {
                if let start = Int64(parts[0]) { rangeStart = start }
                if let end = Int64(parts[1]), !parts[1].isEmpty { rangeEnd = min(end, fileLength - 1) }
                if parts[0].isEmpty, let suffix = Int64(parts[1]) {
                    rangeStart = max(0, fileLength - suffix)
                    rangeEnd = fileLength - 1
                }
            }
        }
        guard rangeStart <= rangeEnd, rangeStart < fileLength else {
            try await sendHead(connection, "416 Range Not Satisfiable",
                               ["Content-Range": "bytes */\(fileLength)", "Connection": "close"])
            return false
        }

        let length = rangeEnd - rangeStart + 1
        var headers: [String: String] = [
            "Content-Type": Self.mimeType(for: filePath),
            "Accept-Ranges": "bytes",
            "Content-Length": "\(length)",
            "Connection": "keep-alive",
        ]
        var status = "200 OK"
        if isRange {
            status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(rangeStart)-\(rangeEnd)/\(fileLength)"
        }
        try await sendHead(connection, status, headers)
        guard method != "HEAD" else { return true }

        let absoluteStart = fileOffset + rangeStart
        let previousPlayhead = lastPlayhead
        let isPlaybackRead = updatePlayhead(absoluteOffset: absoluteStart)
        var generation: Int? = nil
        if isPlaybackRead {
            let isSeek = previousPlayhead < 0 || abs(absoluteStart - previousPlayhead) > pieceLength
            if isSeek {
                if let stale = playbackConnection, stale !== connection {
                    stale.cancel()
                }
                playbackConnection = connection
                playbackGeneration &+= 1
            }
            generation = playbackGeneration
        }
        try await streamBody(connection, from: rangeStart, to: rangeEnd, generation: generation)
        return true
    }

    private func streamBody(_ connection: NWConnection, from start: Int64, to end: Int64, generation: Int?) async throws {
        var position = start
        while position <= end {
            try Task.checkCancellation()
            if let generation, generation != playbackGeneration { return }
            let absolute = fileOffset + position
            let pieceIndex = Int(absolute / pieceLength)

            await waiters.wait(pieceIndex) { [engine] piece in engine.hasPiece(piece) }
            guard engine.hasPiece(pieceIndex) else { throw CancellationError() }

            let pieceStart = Int64(pieceIndex) * pieceLength
            let pieceEnd = pieceStart + pieceLength
            let offsetInPiece = Int(absolute - pieceStart)
            let chunkLength = Int(min(pieceEnd - absolute, end - position + 1))
            let chunk = try await readChunk(piece: pieceIndex, offsetInPiece: offsetInPiece,
                                            length: chunkLength, absoluteOffset: absolute)

            try await NetworkIO.send(connection, chunk)
            position += Int64(chunk.count)
            if generation == nil || generation == playbackGeneration {
                updatePlayhead(absoluteOffset: fileOffset + position)
            }
        }
    }

    private func readChunk(piece: Int, offsetInPiece: Int, length: Int, absoluteOffset: Int64) async throws -> Data {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            if let data = await readPiece(piece), data.count >= offsetInPiece + length {
                return data.subdata(in: offsetInPiece..<(offsetInPiece + length))
            }
            try? await Task.sleep(nanoseconds: UInt64(120_000_000 * (attempt + 1)))
        }
        let path = filePath
        let fileRelativeOffset = absoluteOffset - fileOffset
        for _ in 0..<40 {
            try Task.checkCancellation()
            let data = await Task.detached(priority: .userInitiated) {
                Self.readFromDisk(path: path, offset: fileRelativeOffset, length: length)
            }.value
            if !data.isEmpty { return data }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        throw NetworkIO.Failure.closed
    }

    private func readPiece(_ index: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            engine.readPiece(index) { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func readFromDisk(path: String, offset: Int64, length: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return Data() }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return Data() }
        return handle.readData(ofLength: length)
    }

    private func sendHead(_ connection: NWConnection, _ status: String, _ headers: [String: String]) async throws {
        var text = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        try await NetworkIO.send(connection, Data(text.utf8))
    }

    nonisolated static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}

nonisolated private final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
