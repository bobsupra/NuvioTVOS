import Foundation

/// Tenrai (a Jikan v4–compatible API over MyAnimeList, `MALEpisodeRatings.baseURL`) for MAL
/// titles. Tenrai lets one address ask 60 times a minute and 3 times a second; this asks at most
/// 50 a minute and 2 a second, the viewer's requests (`AniListClient.isInteractive`) ahead of the
/// rest, and nothing while a 429 or 503 says to wait (Retry-After). Answers are kept on disk in
/// Caches/MyAnimeList; a saved answer stands in when Tenrai can't answer.
actor TenraiClient {
    static let shared = TenraiClient()

    enum Failure: Error, Equatable {
        /// Tenrai's limit (or ours) holds the request back.
        case rateLimited
        case status(Int)
        case network
        /// MAL's own API needs the viewer's Client ID.
        case noClientID
    }

    static let perMinute = 50
    static let backgroundPerMinute = 35
    /// Two a second at most.
    static let minimumGap: TimeInterval = 0.5
    static let longestWait: TimeInterval = 20
    static let longestBackgroundWait: TimeInterval = 60
    static let defaultRetry: TimeInterval = 30

    struct Status: Sendable {
        var requests = 0
        var savedAnswers = 0
        var lastSuccess: Date?
        var lastFailure: Date?
        var lastFailureMessage: String?
    }

    private(set) var status = Status()
    private var sentAt: [Date] = []
    private var blockedUntil: Date?
    private var interactiveWaiting = 0
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let cache: AniListDiskCache
    private let session: URLSession

    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("MyAnimeList", isDirectory: true)
    }

    init(session: URLSession = .shared, cache: AniListDiskCache = AniListDiskCache(directory: TenraiClient.cacheDirectory)) {
        self.session = session
        self.cache = cache
    }

    /// The answer at `path` (`anime/5114/full`): from disk while younger than `ttl`, else asked,
    /// one request per address at a time.
    func get(_ path: String, query: [(String, String)] = [], ttl: TimeInterval) async throws -> Data {
        guard let url = Self.url(path, query) else { throw Failure.status(400) }
        return try await get(url: url, ttl: ttl)
    }

    /// The answer at a whole Tenrai address (MAL Catalogs' rows).
    func get(url: URL, ttl: TimeInterval) async throws -> Data {
        let key = AniListClient.cacheKey(for: Data(url.absoluteString.utf8))
        if ttl > 0, let fresh = cache.read(key: key, maxAge: ttl) { return fresh }
        let interactive = AniListClient.isInteractive
        let task: Task<Data, Error>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { try await self.fetch(url, key: key, interactive: interactive) }
            inFlight[key] = task
        }
        do {
            let data = try await task.value
            inFlight[key] = nil
            return data
        } catch {
            inFlight[key] = nil
            if let stale = cache.read(key: key, maxAge: .infinity) {
                status.savedAnswers += 1
                return stale
            }
            throw error
        }
    }

    /// Saved on disk, however old (for what doesn't need a fresh answer).
    func saved(_ path: String, query: [(String, String)] = []) -> (data: Data, age: TimeInterval)? {
        guard let url = Self.url(path, query) else { return nil }
        return cache.readWithAge(key: AniListClient.cacheKey(for: Data(url.absoluteString.utf8)))
    }

    func clearCache() {
        cache.removeAll()
    }

    func noteFailure(_ message: String) {
        status.lastFailure = Date()
        status.lastFailureMessage = message
    }

    static func url(_ path: String, _ query: [(String, String)]) -> URL? {
        guard var components = URLComponents(
            url: MALEpisodeRatings.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url
    }

    private func fetch(_ url: URL, key: String, interactive: Bool) async throws -> Data {
        try await waitForSlot(interactive: interactive)
        sentAt.append(Date())
        status.requests += 1
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            noteFailure("No answer from Tenrai: \(error.localizedDescription)")
            throw Failure.network
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        switch code {
        case 200..<300:
            cache.write(data, key: key)
            status.lastSuccess = Date()
            return data
        case 429, 503:
            let seconds = Self.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
            blockedUntil = Date().addingTimeInterval(seconds)
            noteFailure("Tenrai \(code): waiting \(Int(seconds)) s")
            throw Failure.rateLimited
        default:
            if code != 404 { noteFailure("Tenrai answered \(code)") }
            throw Failure.status(code)
        }
    }

    static func retryAfter(_ header: String?) -> TimeInterval {
        let seconds = header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? defaultRetry
        return min(max(seconds, 1), 3600)
    }

    private func waitForSlot(interactive: Bool) async throws {
        let deadline = Date().addingTimeInterval(interactive ? Self.longestWait : Self.longestBackgroundWait)
        if interactive { interactiveWaiting += 1 }
        defer { if interactive { interactiveWaiting -= 1 } }
        while true {
            let now = Date()
            sentAt.removeAll { now.timeIntervalSince($0) >= 60 }
            let readyAt = Self.readyTime(
                sent: sentAt,
                now: now,
                blockedUntil: blockedUntil,
                interactive: interactive,
                othersWaiting: interactiveWaiting > 0
            )
            if readyAt <= now { return }
            guard readyAt <= deadline else { throw Failure.rateLimited }
            try await Task.sleep(nanoseconds: UInt64(readyAt.timeIntervalSince(now) * 1_000_000_000) + 20_000_000)
        }
    }

    /// When the next request may go: under the minute's limit (a lower one for requests nobody
    /// waits on), half a second after the last, after a 429's wait, and for a background
    /// request only once no viewer's request is waiting.
    static func readyTime(sent: [Date], now: Date, blockedUntil: Date?, interactive: Bool, othersWaiting: Bool) -> Date {
        var readyAt = max(now, blockedUntil ?? now)
        readyAt = max(readyAt, AniListClient.slotTime(sent: sent, now: now, limit: interactive ? perMinute : backgroundPerMinute))
        if let last = sent.last {
            readyAt = max(readyAt, last.addingTimeInterval(minimumGap))
        }
        if !interactive, othersWaiting {
            readyAt = max(readyAt, now.addingTimeInterval(0.5))
        }
        return readyAt
    }
}

/// MyAnimeList's own API (api.myanimelist.net/v2) with the viewer's Client ID
/// (`MALSettings.clientID`): what MAL titles fall back to when Tenrai doesn't answer. MAL
/// publishes no limit; this asks at most once a second, and after a 403 (MAL turning requests
/// away) not for ten minutes. Answers are kept on disk beside Tenrai's.
actor MALOfficialClient {
    static let shared = MALOfficialClient()

    static let baseURL = URL(string: "https://api.myanimelist.net/v2")!
    static let gap: TimeInterval = 1
    static let pauseAfterRefusal: TimeInterval = 600
    static let longestWait: TimeInterval = 20

    private var lastSent: Date?
    private var blockedUntil: Date?
    private(set) var requests = 0
    private(set) var lastFailureMessage: String?
    private let cache = AniListDiskCache(directory: TenraiClient.cacheDirectory.appendingPathComponent("Official", isDirectory: true))

    static var isAvailable: Bool { !MALSettings.clientID.isEmpty }

    func get(_ path: String, query: [(String, String)] = [], ttl: TimeInterval) async throws -> Data {
        let clientID = MALSettings.clientID
        guard !clientID.isEmpty else { throw TenraiClient.Failure.noClientID }
        guard var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw TenraiClient.Failure.status(400)
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw TenraiClient.Failure.status(400) }
        let key = AniListClient.cacheKey(for: Data(url.absoluteString.utf8))
        if ttl > 0, let fresh = cache.read(key: key, maxAge: ttl) { return fresh }
        do {
            return try await fetch(url, key: key, clientID: clientID)
        } catch {
            if let stale = cache.read(key: key, maxAge: .infinity) { return stale }
            throw error
        }
    }

    func clearCache() {
        cache.removeAll()
    }

    private func fetch(_ url: URL, key: String, clientID: String) async throws -> Data {
        let deadline = Date().addingTimeInterval(Self.longestWait)
        while true {
            let now = Date()
            var readyAt = max(now, blockedUntil ?? now)
            if let lastSent { readyAt = max(readyAt, lastSent.addingTimeInterval(Self.gap)) }
            if readyAt <= now { break }
            guard readyAt <= deadline else { throw TenraiClient.Failure.rateLimited }
            try await Task.sleep(nanoseconds: UInt64(readyAt.timeIntervalSince(now) * 1_000_000_000) + 20_000_000)
        }
        lastSent = Date()
        requests += 1
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            lastFailureMessage = "No answer from MAL: \(error.localizedDescription)"
            throw TenraiClient.Failure.network
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        switch code {
        case 200..<300:
            cache.write(data, key: key)
            return data
        case 403:
            blockedUntil = Date().addingTimeInterval(Self.pauseAfterRefusal)
            lastFailureMessage = "MAL answered 403: paused for 10 minutes"
            throw TenraiClient.Failure.rateLimited
        case 429:
            blockedUntil = Date().addingTimeInterval(TenraiClient.retryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
            lastFailureMessage = "MAL answered 429"
            throw TenraiClient.Failure.rateLimited
        default:
            lastFailureMessage = "MAL answered \(code)"
            throw TenraiClient.Failure.status(code)
        }
    }
}
