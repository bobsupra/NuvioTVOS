import Foundation
import OSLog

let usenetLog = Logger(subsystem: "com.nuvio.tv", category: "Usenet")

/// Token bucket for the optional speed cap: hands out bytes at a steady rate
/// with a small burst, so requests are spread out instead of fired at once.
struct UsenetTokenBucket {
    let bytesPerSecond: Double
    let capacity: Double
    private(set) var tokens: Double
    private var last: ContinuousClock.Instant

    init(megabitsPerSecond: Int, now: ContinuousClock.Instant) {
        bytesPerSecond = Double(max(1, megabitsPerSecond)) * 1_000_000 / 8
        capacity = max(1_048_576, bytesPerSecond / 2)
        tokens = capacity
        last = now
    }

    /// Takes `bytes` and returns how long the caller has to wait before using them.
    mutating func take(_ bytes: Int, now: ContinuousClock.Instant) -> Duration {
        let elapsed = now - last
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(capacity, tokens + max(0, seconds) * bytesPerSecond)
        last = now
        tokens -= Double(bytes)
        guard tokens < 0 else { return .zero }
        return .seconds(-tokens / bytesPerSecond)
    }

    /// Gives back bytes that were taken but never downloaded.
    mutating func refund(_ bytes: Int) {
        tokens = min(capacity, tokens + Double(bytes))
    }
}

/// The speed cap shared by every connection of one stream.
actor UsenetRateLimiter {
    private var bucket: UsenetTokenBucket

    init?(megabitsPerSecond: Int) {
        guard megabitsPerSecond > 0 else { return nil }
        bucket = UsenetTokenBucket(megabitsPerSecond: megabitsPerSecond, now: .now)
    }

    /// Waits until `bytes` fit under the cap. A wait cut short by a seek
    /// gives its bytes back, so it doesn't slow the reads after the seek.
    func consume(_ bytes: Int) async throws {
        let wait = bucket.take(bytes, now: .now)
        guard wait > .zero else { return }
        do {
            try await Task.sleep(for: wait)
        } catch {
            bucket.refund(bytes)
            throw error
        }
    }

    /// Counts bytes without waiting: the player is waiting for them, and the
    /// read-ahead after them still keeps to the cap.
    func charge(_ bytes: Int) {
        _ = bucket.take(bytes, now: .now)
    }

    func refund(_ bytes: Int) {
        bucket.refund(bytes)
    }
}

/// Fetches waiting for a connection: what the player waits for goes first.
struct UsenetWaitQueue<Element> {
    private var urgent: [Element] = []
    private var normal: [Element] = []

    var isEmpty: Bool { urgent.isEmpty && normal.isEmpty }

    mutating func append(_ element: Element, urgent isUrgent: Bool) {
        if isUrgent { urgent.append(element) } else { normal.append(element) }
    }

    mutating func popFirst() -> Element? {
        if !urgent.isEmpty { return urgent.removeFirst() }
        if !normal.isEmpty { return normal.removeFirst() }
        return nil
    }

    mutating func removeAll() -> [Element] {
        defer {
            urgent = []
            normal = []
        }
        return urgent + normal
    }
}

/// Long-lived authenticated NNTP connections to one or more providers.
///
/// Each server gets up to its `maxConnections`. An article is tried on the
/// servers in order: a missing article (430) moves on to the next server, a
/// dropped connection is replaced and retried, a rejected login stops.
/// A server that turns away one more connection while others are open has
/// reached the plan's limit: the stream keeps to the connections it has.
actor UsenetConnectionPool {
    private struct ServerState {
        let config: UsenetServerConfig
        /// Connections this stream may open: `maxConnections`, lowered when
        /// the server turns one away.
        var limit: Int
        var idle: [UsenetNNTPConnection] = []
        var open = 0
        /// Each waiter is handed a released connection directly, or nil when
        /// a slot frees up (or the pool closes) and it should try again.
        var waiters = UsenetWaitQueue<CheckedContinuation<UsenetNNTPConnection?, Never>>()

        init(config: UsenetServerConfig) {
            self.config = config
            self.limit = config.maxConnections
        }
    }

    private var servers: [ServerState]
    private var closed = false
    private let limiter: UsenetRateLimiter?

    /// Connections across all servers, the limit for concurrent fetches.
    nonisolated let totalConnections: Int
    /// The speed cap in Mbit/s, 0 for none.
    nonisolated let speedLimitMbps: Int

    init(servers: [UsenetServerConfig], speedLimitMbps: Int = 0) {
        self.servers = servers.map { ServerState(config: $0) }
        self.totalConnections = max(1, servers.reduce(0) { $0 + $1.maxConnections })
        self.speedLimitMbps = max(0, speedLimitMbps)
        self.limiter = UsenetRateLimiter(megabitsPerSecond: speedLimitMbps)
    }

    enum FetchOutcome: Sendable {
        case body(Data)
        /// No server has the article (taken down or never fully posted).
        case missing
    }

    /// Who an article is for, which decides its place in line and the speed cap.
    enum FetchPriority: Sendable {
        /// Working out the release before playback: not limited.
        case startup
        /// The player is waiting for it: first in line for a connection,
        /// counted towards the cap but never held back by it.
        case playback
        /// Read-ahead right after the playhead, needed in a moment: counted
        /// towards the cap but never held back by it.
        case next
        /// The rest of the read-ahead: waits for the cap.
        case readAhead
    }

    /// How far a fetch got, for callers that may want to move it up.
    enum FetchProgress: Sendable {
        /// Past the speed cap, now waiting for a connection.
        case passedCap
        /// Has a connection (or is opening one): it will download.
        case connected
    }

    /// Fetches an article body, trying every server before giving up.
    func fetch(messageID: String, expectedBytes: Int = 0, priority: FetchPriority = .startup,
               onProgress: (@Sendable (FetchProgress) -> Void)? = nil) async throws -> FetchOutcome {
        var charged = 0
        if let limiter, expectedBytes > 0 {
            switch priority {
            case .startup:
                break
            case .playback, .next:
                await limiter.charge(expectedBytes)
                charged = expectedBytes
            case .readAhead:
                try await limiter.consume(expectedBytes)
                charged = expectedBytes
            }
        }
        onProgress?(.passedCap)
        var onConnected: (@Sendable () -> Void)?
        if let onProgress { onConnected = { @Sendable in onProgress(.connected) } }
        do {
            switch try await run(messageID: messageID, statOnly: false, urgent: priority == .playback,
                                 onConnected: onConnected) {
            case .body(let body): return .body(body)
            case .exists, .missing: return .missing
            }
        } catch is CancellationError {
            // Cancelled before it got a connection (the player seeked away):
            // nothing was downloaded, so give the bytes back.
            if charged > 0 { await limiter?.refund(charged) }
            throw CancellationError()
        }
    }

    /// Whether any server still has the article (`STAT`, nothing downloaded).
    func exists(messageID: String) async throws -> Bool {
        switch try await run(messageID: messageID, statOnly: true, urgent: false) {
        case .exists, .body: return true
        case .missing: return false
        }
    }

    struct Stats: Equatable, Sendable {
        var busyConnections = 0
        var openConnections = 0
        /// What the servers accept: the settings, or less once a server
        /// turned a connection away.
        var totalConnections = 0
        /// What the settings ask for.
        var configuredConnections = 0
        /// Articles a later server had after the first one didn't.
        var fallbackArticles = 0
        var primaryHost = ""
        var serverCount = 0
    }

    func stats() -> Stats {
        Stats(
            busyConnections: servers.reduce(0) { $0 + max(0, $1.open - $1.idle.count) },
            openConnections: servers.reduce(0) { $0 + $1.open },
            totalConnections: servers.reduce(0) { $0 + $1.limit },
            configuredConnections: totalConnections,
            fallbackArticles: fallbackArticles,
            primaryHost: servers.first?.config.host ?? "",
            serverCount: servers.count
        )
    }

    private var fallbackArticles = 0

    private enum Answer {
        case body(Data)
        case exists
        case missing
    }

    private func run(messageID: String, statOnly: Bool, urgent: Bool,
                     onConnected: (@Sendable () -> Void)? = nil) async throws -> Answer {
        var authError: UsenetNNTPError?
        // Every server turning the connection away (all connections in use,
        // maybe by another device) is not a missing article.
        var refusal: UsenetNNTPError?
        var answered = false
        for index in servers.indices {
            var attempt = 0
            while attempt < 3 {
                attempt += 1
                try Task.checkCancellation()
                let connection: UsenetNNTPConnection
                do {
                    connection = try await acquire(index, urgent: urgent, onConnected: onConnected)
                } catch let error as UsenetNNTPError {
                    if case .authenticationFailed = error { authError = error; break }
                    if case .badGreeting = error { refusal = error; break }
                    if error.isTransient, attempt < 3 { continue }
                    break
                }
                do {
                    if statOnly {
                        let found = try await connection.stat(messageID: messageID)
                        release(connection, to: index)
                        if found { return .exists }
                        answered = true
                        attempt = 3          // next server
                    } else {
                        let body = try await connection.fetchBody(messageID: messageID)
                        release(connection, to: index)
                        if index > 0 { fallbackArticles += 1 }
                        return .body(body)
                    }
                } catch let error as UsenetNNTPError {
                    switch error {
                    case .articleUnavailable:
                        release(connection, to: index)
                        answered = true
                        attempt = 3          // next server
                    case .authenticationFailed:
                        discard(connection, from: index)
                        authError = error
                        attempt = 3
                    default:
                        discard(connection, from: index)
                        if !error.isTransient { attempt = 3 }
                    }
                } catch {
                    discard(connection, from: index)
                    throw error
                }
            }
        }
        if let authError {
            throw UsenetError.serverRejected(Self.describe(authError))
        }
        if let refusal, !answered {
            throw UsenetError.serverRejected(Self.describe(refusal))
        }
        return .missing
    }

    /// Takes one connection to the first server out of the pool for seek previews, for the rest
    /// of the stream. The pool then keeps to one fewer, so the provider never sees more than the
    /// configured count. nil when the server allows only one connection: playback needs it.
    func reservePreviewConnection() async throws -> UsenetNNTPConnection? {
        guard !closed, let index = servers.indices.first, servers[index].limit > 1 else { return nil }
        let connection = try await acquire(index, urgent: false)
        guard !closed else {
            Task { await connection.close() }
            throw CancellationError()
        }
        servers[index].open = max(0, servers[index].open - 1)
        servers[index].limit = max(1, servers[index].limit - 1)
        return connection
    }

    /// A replacement for a reserved preview connection the server closed: the slot stays reserved.
    func reopenPreviewConnection() async throws -> UsenetNNTPConnection {
        guard !closed, let config = servers.first?.config else { throw CancellationError() }
        let connection = UsenetNNTPConnection(config: config)
        try await connection.open()
        return connection
    }

    func shutdown() {
        closed = true
        for index in servers.indices {
            let connections = servers[index].idle
            servers[index].idle = []
            servers[index].open = 0
            let waiters = servers[index].waiters.removeAll()
            waiters.forEach { $0.resume(returning: nil) }
            Task { for connection in connections { await connection.close() } }
        }
    }

    // MARK: - Connections

    /// `onConnected` runs as soon as the fetch has a connection or a slot to
    /// open one: from then on it will download and isn't worth moving up.
    private func acquire(_ index: Int, urgent: Bool,
                         onConnected: (@Sendable () -> Void)? = nil) async throws -> UsenetNNTPConnection {
        while true {
            guard !closed else { throw CancellationError() }
            if let connection = servers[index].idle.popLast() {
                if await connection.isClosed {
                    servers[index].open -= 1
                    continue
                }
                onConnected?()
                return connection
            }
            if servers[index].open < servers[index].limit {
                servers[index].open += 1
                onConnected?()
                let connection = UsenetNNTPConnection(config: servers[index].config)
                do {
                    try await connection.open()
                    return connection
                } catch {
                    servers[index].open -= 1
                    if let limit = Self.limitAfterRefusal(error, open: servers[index].open, limit: servers[index].limit) {
                        // The plan's limit: wait for one of the connections it accepted.
                        if limit < servers[index].limit {
                            let host = servers[index].config.host
                            let configured = servers[index].config.maxConnections
                            usenetLog.info("usenet: \(host, privacy: .public) turned away a connection, using \(limit) of \(configured)")
                        }
                        servers[index].limit = limit
                        continue
                    }
                    wakeOne(index)
                    throw error
                }
            }
            let handed = await withCheckedContinuation { (continuation: CheckedContinuation<UsenetNNTPConnection?, Never>) in
                servers[index].waiters.append(continuation, urgent: urgent)
            }
            // A read-ahead cancelled while it waited (the player seeked away)
            // passes its turn on instead of downloading.
            if Task.isCancelled {
                if let handed { release(handed, to: index) } else { wakeOne(index) }
                throw CancellationError()
            }
            guard let handed else { continue }      // a slot freed up: try again
            if await handed.isClosed {
                servers[index].open -= 1
                continue
            }
            onConnected?()
            return handed
        }
    }

    /// What a new connection the server turned away means. While other
    /// connections of this stream are open (or still opening), a refusal at
    /// the greeting or the login (providers differ) means the plan's
    /// connection limit is reached: returns the limit to keep to, the
    /// connections still open. A refusal with none left to wait for is a real
    /// failure, such as a wrong password: nil. Refusals at the greeting
    /// arrive before the accepted connections finish logging in, so "open"
    /// counts those too.
    static func limitAfterRefusal(_ error: Error, open: Int, limit: Int) -> Int? {
        guard open > 0, let error = error as? UsenetNNTPError else { return nil }
        switch error {
        case .badGreeting, .authenticationFailed:
            return min(limit, open)
        default:
            return nil
        }
    }

    /// Hands a finished connection straight to the first waiter, so a fetch
    /// arriving meanwhile can't take it from the player's read.
    private func release(_ connection: UsenetNNTPConnection, to index: Int) {
        guard !closed else {
            Task { await connection.close() }
            return
        }
        if let waiter = servers[index].waiters.popFirst() {
            waiter.resume(returning: connection)
        } else {
            servers[index].idle.append(connection)
        }
    }

    private func discard(_ connection: UsenetNNTPConnection, from index: Int) {
        Task { await connection.close() }
        servers[index].open = max(0, servers[index].open - 1)
        wakeOne(index)
    }

    /// A slot freed up (a connection closed or failed to open): the first
    /// waiter may open a new one.
    private func wakeOne(_ index: Int) {
        servers[index].waiters.popFirst()?.resume(returning: nil)
    }

    static func describe(_ error: UsenetNNTPError) -> String {
        switch error {
        case .authenticationFailed(let code):
            return L10n.format("usenet_error_auth", fallback: "Your Usenet server rejected the login (%d).", code)
        case .badGreeting(let code):
            return L10n.format("usenet_error_greeting", fallback: "The Usenet server refused the connection (%d).", code)
        case .connectionFailed(let message):
            return L10n.format("usenet_error_connect", fallback: "Couldn't connect to the Usenet server: %@", message)
        case .timeout:
            return L10n.string("usenet_error_timeout", fallback: "The Usenet server didn't answer in time.")
        default:
            return L10n.string("usenet_error_generic", fallback: "The Usenet server returned an error.")
        }
    }
}
