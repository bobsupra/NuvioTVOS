//
//  Ported from SwiftNZB (https://github.com/valentinlehmann/swiftnzb), MIT License,
//  Copyright (c) 2026 Valentin Lehmann. Adapted for streaming in Nuvio: renamed with a
//  Usenet prefix, rate limiting removed.
//

import Foundation
import Network

enum UsenetNNTPError: Error, Sendable, Equatable {
    case notConnected
    case connectionFailed(String)
    case timeout
    case cancelled
    /// Server greeting wasn't a 200/201.
    case badGreeting(Int)
    /// AUTHINFO USER/PASS rejected.
    case authenticationFailed(Int)
    /// BODY/ARTICLE returned a 4xx/5xx — typically 430 (no such article / taken down).
    case articleUnavailable(code: Int)
    /// The server closed the stream mid-response.
    case connectionClosed
    case protocolError(String)

    /// Whether a fresh attempt (possibly on a new connection) might succeed.
    var isTransient: Bool {
        switch self {
        case .timeout, .connectionClosed, .connectionFailed, .notConnected: return true
        case .articleUnavailable, .authenticationFailed, .badGreeting, .protocolError, .cancelled: return false
        }
    }
}

/// A parsed NNTP status response, e.g. "222 0 <id> body follows" → code 222.
struct UsenetNNTPStatus: Equatable {
    var code: Int
    var text: String

    /// First digit class: 1 info, 2 success, 3 continue, 4 transient error, 5 permanent error.
    var isSuccess: Bool { (200..<300).contains(code) }
    var isContinue: Bool { (300..<400).contains(code) }
    var isError: Bool { code >= 400 }

    init?(line: Data) {
        guard let s = String(data: line, encoding: .utf8) ?? String(data: line, encoding: .isoLatin1) else {
            return nil
        }
        self.init(string: s)
    }

    init?(string s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3,
              let code = Int(trimmed.prefix(3)),
              trimmed.prefix(3).allSatisfy(\.isNumber) else { return nil }
        self.code = code
        self.text = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }
}

/// One line of a multi-line response body after dot-processing.
enum UsenetNNTPBodyLine: Equatable {
    /// The terminating "." line — the multi-line block is complete.
    case terminator
    /// A content line with dot-stuffing removed (a leading ".." becomes ".").
    case content(Data)
}

enum UsenetNNTP {
    private static let dot: UInt8 = 0x2E  // '.'

    /// Apply RFC 3977 dot-unstuffing / terminator detection to a raw (CRLF-stripped) body line.
    static func processBodyLine(_ line: Data) -> UsenetNNTPBodyLine {
        if line.count == 1, line.first == dot {
            return .terminator
        }
        if line.first == dot {
            // Remove exactly one leading stuffing dot.
            return .content(Data(line.dropFirst()))
        }
        return .content(line)
    }

    private static let terminatorBytes = Data([0x0D, 0x0A, 0x2E, 0x0D, 0x0A]) // CRLF "." CRLF

    /// Where a multi-line body ends in `buffer`: the body is `0..<bodyEnd`
    /// (without its last CRLF) and the next response starts at `restStart`.
    /// `from` lets the caller skip what it already searched.
    static func bodyTerminator(in buffer: Data, from: Int) -> (bodyEnd: Int, restStart: Int)? {
        let base = buffer.startIndex
        if buffer.count >= 3, buffer[base] == 0x2E, buffer[base + 1] == 0x0D, buffer[base + 2] == 0x0A {
            return (0, 3)  // empty body
        }
        let lower = base + max(0, min(from, buffer.count))
        guard let range = buffer.range(of: terminatorBytes, in: lower..<buffer.endIndex) else { return nil }
        return (range.lowerBound - base, range.upperBound - base)
    }

    /// Encode a command for sending (CRLF-terminated, ASCII/Latin-1).
    static func command(_ text: String) -> Data {
        Data((text + "\r\n").utf8)
    }
}

struct UsenetLineFramer {
    private var buffer = Data()

    /// Append freshly-read bytes and return every complete line now available.
    /// A trailing partial line (no terminator yet) stays buffered for the next append.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        return drainCompleteLines()
    }

    /// Bytes buffered that haven't been terminated by a newline yet.
    var pending: Data { buffer }

    /// Hands over the unterminated bytes and empties the buffer.
    mutating func takePending() -> Data {
        defer { buffer = Data() }
        return buffer
    }
    var pendingCount: Int { buffer.count }

    /// Scan the buffer once, emitting each complete line, then drop the whole consumed prefix in a
    /// single copy. (Compacting after every line is O(n²) over a large article body.)
    private mutating func drainCompleteLines() -> [Data] {
        let lf: UInt8 = 0x0A
        let cr: UInt8 = 0x0D
        var lines: [Data] = []
        var consumedUpTo = 0

        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            let n = bytes.count
            var i = 0
            while i < n {
                if bytes[i] == lf {
                    var end = i
                    if end > lineStart, bytes[end - 1] == cr { end -= 1 }
                    lines.append(Data(bytes[lineStart..<end]))
                    lineStart = i + 1
                }
                i += 1
            }
            consumedUpTo = lineStart
        }

        // Keep only the unterminated tail; done once instead of per line.
        if consumedUpTo > 0 {
            buffer = consumedUpTo < buffer.count
                ? Data(buffer[(buffer.startIndex + consumedUpTo)...])
                : Data()
        }
        return lines
    }
}

actor UsenetNNTPConnection {
    private let config: UsenetServerConfig
    private static let queue = DispatchQueue(label: "nuvio.usenet.nntp", attributes: .concurrent)

    /// Bounds connect + greeting + auth so an unreachable host or a silent server can't hang a
    /// worker (or the "Test Connection" probe) forever.
    private static let openTimeout: Double = 20
    /// Hard cap on a single line so a misbehaving server that never sends a newline can't grow
    /// memory without bound. NNTP status/yEnc lines are short; 4 MB is a very generous ceiling.
    private static let maxLineBytes = 4 * 1024 * 1024

    private var connection: NWConnection?
    private var framer = UsenetLineFramer()
    private var lineQueue: [Data] = []
    private var lineCursor = 0
    private(set) var isClosed = false
    init(config: UsenetServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// Establish the TCP/TLS connection, read the greeting, and authenticate. Bounded by
    /// `openTimeout`; cancels the socket on any failure so nothing is left half-open.
    func open() async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in try await performOpen() }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.openTimeout))
                    throw UsenetNNTPError.timeout
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            close()
            throw error
        }
    }

    private func performOpen() async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: config.port) ?? 0) else {
            throw UsenetNNTPError.connectionFailed("invalid port \(config.port)")
        }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params: NWParameters = config.useSSL
            ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)

        let connection = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: params)
        self.connection = connection

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = UsenetResumeOnce(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.success(()))
                case .failed(let error):
                    once.resume(.failure(UsenetNNTPError.connectionFailed(String(describing: error))))
                case .cancelled:
                    once.resume(.failure(UsenetNNTPError.cancelled))
                case .waiting(let error):
                    // DNS failure, connection refused, or an unreachable host surface here and
                    // NWConnection would otherwise retry internally forever. We manage our own
                    // retries/backoff, so fail fast instead of hanging.
                    once.resume(.failure(UsenetNNTPError.connectionFailed(String(describing: error))))
                default:
                    break
                }
            }
            connection.start(queue: Self.queue)
        }
        // Once connected, demote the handler so later state changes don't try to resume again.
        connection.stateUpdateHandler = { _ in }

        let greeting = try await readStatus()
        guard greeting.code == 200 || greeting.code == 201 else {
            throw UsenetNNTPError.badGreeting(greeting.code)
        }

        if let username = config.username, !username.isEmpty {
            try await authenticate(user: username, password: config.password)
        }
    }

    /// Cancel the socket. Safe to call while a `fetchBody` read is in flight — it unblocks it.
    func close() {
        isClosed = true
        connection?.cancel()
        connection = nil
    }

    // MARK: - Commands

    /// Fetch an article body as one raw block (CRLF lines, still dot-stuffed), ready for
    /// `UsenetYEnc.decode(body:)`. Throws `.articleUnavailable` only for the codes that mean
    /// the article is genuinely gone.
    func fetchBody(messageID: String) async throws -> Data {
        // The message-ID comes from untrusted NZB XML. A CR/LF (or space/bracket) would let a
        // crafted ID inject a second command onto the wire or desync request/response pairing,
        // so reject anything that isn't a well-formed ID before sending.
        guard Self.isValidMessageID(messageID) else {
            throw UsenetNNTPError.articleUnavailable(code: 430)
        }
        try await send("BODY <\(messageID)>")
        let status = try await readStatus()
        switch status.code {
        case 222:
            return try await readBodyRaw()
        case 420, 423, 430:
            // No such article / no article with that number — genuinely, permanently missing.
            throw UsenetNNTPError.articleUnavailable(code: status.code)
        case 480, 481, 482, 483, 502:
            // Authentication or permission problem — a per-segment retry won't help; surface it
            // so the job fails cleanly instead of silently punching holes.
            throw UsenetNNTPError.authenticationFailed(status.code)
        case 400, 500:
            // Service temporarily unavailable / shutting down / internal — transient, retry on a
            // fresh connection.
            throw UsenetNNTPError.connectionClosed
        default:
            throw UsenetNNTPError.protocolError("unexpected BODY response \(status.code)")
        }
    }

    /// Whether the server still has an article, without downloading it (`STAT`).
    func stat(messageID: String) async throws -> Bool {
        guard Self.isValidMessageID(messageID) else { return false }
        try await send("STAT <\(messageID)>")
        let status = try await readStatus()
        switch status.code {
        case 223:
            return true
        case 420, 423, 430:
            return false
        case 480, 481, 482, 483, 502:
            throw UsenetNNTPError.authenticationFailed(status.code)
        case 400, 500:
            throw UsenetNNTPError.connectionClosed
        default:
            throw UsenetNNTPError.protocolError("unexpected STAT response \(status.code)")
        }
    }

    /// A syntactically safe message-ID: no whitespace/control bytes and no angle brackets (we add
    /// our own), non-empty, and length-bounded.
    static func isValidMessageID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 1000 else { return false }
        for scalar in id.unicodeScalars {
            if scalar.value < 0x21 || scalar.value > 0x7E { return false }   // printable ASCII only
            if scalar == "<" || scalar == ">" { return false }
        }
        return true
    }

    // MARK: - Auth

    private func authenticate(user: String, password: String?) async throws {
        try await send("AUTHINFO USER \(user)")
        let r1 = try await readStatus()
        if r1.code == 281 { return }                 // accepted, no password needed
        guard r1.code == 381 else { throw UsenetNNTPError.authenticationFailed(r1.code) }
        guard let password else { throw UsenetNNTPError.authenticationFailed(r1.code) }
        try await send("AUTHINFO PASS \(password)")
        let r2 = try await readStatus()
        guard r2.code == 281 else { throw UsenetNNTPError.authenticationFailed(r2.code) }
    }

    // MARK: - Wire I/O

    private func send(_ command: String) async throws {
        guard let connection else { throw UsenetNNTPError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: UsenetNNTP.command(command), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: UsenetNNTPError.connectionFailed(String(describing: error)))
                } else {
                    cont.resume(returning: ())
                }
            })
        }
    }

    private func readStatus() async throws -> UsenetNNTPStatus {
        let line = try await nextLine()
        guard let status = UsenetNNTPStatus(line: line) else {
            throw UsenetNNTPError.protocolError("malformed status line")
        }
        return status
    }

    /// Hard cap on one article body (they are under 1 MB in practice).
    private static let maxBodyBytes = 64 * 1024 * 1024

    /// The body up to the terminating "." line, read in large chunks and
    /// searched for the terminator instead of being split into lines.
    private func readBodyRaw() async throws -> Data {
        var buffer = Data()
        // Lines the framer already split off after the status line, then its partial line.
        while lineCursor < lineQueue.count {
            buffer.append(lineQueue[lineCursor])
            buffer.append(contentsOf: [0x0D, 0x0A])
            lineCursor += 1
        }
        lineQueue.removeAll(keepingCapacity: true)
        lineCursor = 0
        buffer.append(framer.takePending())

        var searchFrom = 0
        while true {
            if let end = UsenetNNTP.bodyTerminator(in: buffer, from: searchFrom) {
                if end.restStart < buffer.count {
                    // Anything after the terminator belongs to the next response.
                    lineQueue.append(contentsOf: framer.append(buffer.subdata(in: end.restStart..<buffer.count)))
                }
                buffer.removeSubrange(end.bodyEnd..<buffer.count)
                return buffer
            }
            guard buffer.count < Self.maxBodyBytes else {
                throw UsenetNNTPError.protocolError("article body exceeded \(Self.maxBodyBytes) bytes")
            }
            searchFrom = max(0, buffer.count - 4)
            buffer.append(try await receiveChunk())
        }
    }

    private func nextLine() async throws -> Data {
        while lineCursor >= lineQueue.count {
            // Reset the buffer between refills so the cursor doesn't retain drained lines.
            lineQueue.removeAll(keepingCapacity: true)
            lineCursor = 0
            let chunk = try await receiveChunk()
            lineQueue.append(contentsOf: framer.append(chunk))
            if framer.pendingCount > Self.maxLineBytes {
                throw UsenetNNTPError.protocolError("line exceeded \(Self.maxLineBytes) bytes without a terminator")
            }
        }
        defer { lineCursor += 1 }
        return lineQueue[lineCursor]
    }

    private func receiveChunk() async throws -> Data {
        try await rawReceive()
    }

    private func rawReceive() async throws -> Data {
        guard let connection else { throw UsenetNNTPError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: UsenetNNTPError.connectionFailed(String(describing: error)))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: UsenetNNTPError.connectionClosed)
                } else {
                    cont.resume(throwing: UsenetNNTPError.connectionClosed)
                }
            }
        }
    }
}

/// Guards a continuation so it resumes exactly once, even though `stateUpdateHandler` may fire
/// multiple times off the actor's executor.
private final class UsenetResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        guard let c else { return }
        switch result {
        case .success: c.resume()
        case .failure(let error): c.resume(throwing: error)
        }
    }
}

