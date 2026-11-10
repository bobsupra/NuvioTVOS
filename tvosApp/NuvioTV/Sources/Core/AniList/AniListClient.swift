import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Talks to graphql.anilist.co (and api.ani.zip) from this Apple TV.
///
/// AniList allows 90 requests a minute per address and lately only 30, so every answer is
/// kept on disk for a while (`ttl`), the same request asked twice at once is sent once, and
/// requests wait for a free slot. When AniList says to slow down, or the request fails, the
/// last answer on disk is used even if it is old. Answers saved by another build of the app
/// are dropped when this one first asks.
actor AniListClient {
    static let shared = AniListClient(dropsAnswersFromOtherBuilds: true)

    enum ClientError: Error {
        case rateLimited
        case badResponse(Int)
        /// A failure status with AniList's own words for it ("Invalid token", "Not Found.").
        case refused(Int, String)
        /// AniList answered 200 with only an error in it.
        case answeredWithError(String)
    }

    /// An answer, and whether it was saved earlier rather than given by AniList just now.
    struct Answer {
        let data: Data
        let isSaved: Bool
    }

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    /// Below the current limit of 30 a minute, so a burst never trips it.
    private static let requestsPerMinute = 25
    /// Longest wait for a free slot before an old answer, or an error, is returned instead.
    private static let longestWait: TimeInterval = 20

    /// The last answer AniList gave, for the status in Settings → Integrations → AniList.
    struct Status {
        var lastSuccess: Date?
        var lastFailure: Date?
        var lastFailureMessage: String?
    }

    private let session: URLSession
    private let cache: AniListDiskCache
    private(set) var status = Status()
    private var sentAt: [Date] = []
    private var blockedUntil: Date?
    private var inFlight: [String: Task<Answer, Error>] = [:]

    init(session: URLSession? = nil, cache: AniListDiskCache = AniListDiskCache(), dropsAnswersFromOtherBuilds: Bool = false) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.cache = cache
        if dropsAnswersFromOtherBuilds {
            cache.removeAllIfWritten(byAnotherBuildThan: AniListDiskCache.currentBuild)
        }
    }

    /// The JSON answer to a GraphQL query, from disk when it is younger than `ttl`.
    func query(_ query: String, variables: [String: Any?] = [:], ttl: TimeInterval, notesStatus: Bool = true) async throws -> Data {
        try await answer(query, variables: variables, ttl: ttl, notesStatus: notesStatus).data
    }

    /// `query`, telling whether the answer was saved earlier. `notesStatus: false` leaves the
    /// status in Settings alone (Test Connection).
    ///
    /// `token` asks as the viewer's AniList account; its answers are saved apart from anyone
    /// else's. `saves: false` is for changes (mutations) and answers that must be current: the
    /// answer is neither read from disk nor kept, and an old one never stands in for it.
    func answer(
        _ query: String,
        variables: [String: Any?] = [:],
        ttl: TimeInterval,
        notesStatus: Bool = true,
        token: String? = nil,
        saves: Bool = true
    ) async throws -> Answer {
        let body = try Self.body(query: query, variables: variables)
        var keyed = body
        if let token {
            keyed.append(Data("|viewer:\(Self.cacheKey(for: Data(token.utf8)))".utf8))
        }
        let key = Self.cacheKey(for: keyed)
        if saves, let fresh = cache.read(key: key, maxAge: ttl) {
            return Answer(data: fresh, isSaved: true)
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let task = Task { try await self.send(body: body, key: key, notesStatus: notesStatus, token: token, saves: saves) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Forgets the saved answers of one query, so the next ask reaches AniList (a list after
    /// the viewer changed it).
    func forget(_ query: String, variables: [String: Any?] = [:], token: String? = nil) {
        guard let body = try? Self.body(query: query, variables: variables) else { return }
        var keyed = body
        if let token {
            keyed.append(Data("|viewer:\(Self.cacheKey(for: Data(token.utf8)))".utf8))
        }
        cache.remove(key: Self.cacheKey(for: keyed))
    }

    /// The answer on disk and how old it is, without asking AniList.
    func cached(_ query: String, variables: [String: Any?] = [:]) -> (data: Data, age: TimeInterval)? {
        guard let body = try? Self.body(query: query, variables: variables) else { return nil }
        return cache.readWithAge(key: Self.cacheKey(for: body))
    }

    /// A plain GET (api.ani.zip), kept on disk for `ttl`. It has no AniList rate limit.
    func get(_ url: URL, ttl: TimeInterval) async throws -> Data {
        let key = Self.cacheKey(for: Data(url.absoluteString.utf8))
        if let fresh = cache.read(key: key, maxAge: ttl) {
            return fresh
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw ClientError.badResponse(code) }
            cache.write(data, key: key)
            return data
        } catch {
            if let stale = cache.read(key: key, maxAge: .infinity) { return stale }
            throw error
        }
    }

    func clearCache() {
        cache.removeAll()
    }

    /// How long whether a picture exists is remembered.
    private static let imageCheckTTL: TimeInterval = 7 * 24 * 3600

    /// Whether a picture answers at `url`. Metahub answers 404 for a title it has no logo of,
    /// and a missing logo must leave the title's name in its place. Kept a week; a network
    /// failure is not kept.
    func imageExists(_ url: URL) async -> Bool {
        let key = Self.cacheKey(for: Data("exists \(url.absoluteString)".utf8))
        if let saved = cache.read(key: key, maxAge: Self.imageCheckTTL) {
            return saved == Data([1])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let head = try? await session.data(for: request) else { return false }
        var response = head.1
        if (response as? HTTPURLResponse)?.statusCode == 405 {
            // No HEAD there: ask for the first byte.
            var get = URLRequest(url: url)
            get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            guard let firstByte = try? await session.data(for: get) else { return false }
            response = firstByte.1
        }
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let exists = (200..<300).contains(http?.statusCode ?? 0) && (type.isEmpty || type.hasPrefix("image/"))
        cache.write(Data([exists ? 1 : 0]), key: key)
        return exists
    }

    /// Whether the picture at `url` is a title logo: letters on a see-through background. A still
    /// or a poster in its place sits in the hero's title as a miniature. Kept a week; a network
    /// failure is not kept.
    func isLogo(_ url: URL) async -> Bool {
        let key = Self.cacheKey(for: Data("logo \(url.absoluteString)".utf8))
        if let saved = cache.read(key: key, maxAge: Self.imageCheckTTL) {
            return saved == Data([1])
        }
        guard let answer = try? await session.data(from: url) else { return false }
        let code = (answer.1 as? HTTPURLResponse)?.statusCode ?? 0
        let isLogo = (200..<300).contains(code) && Self.looksLikeLogo(answer.0)
        cache.write(Data([isLogo ? 1 : 0]), key: key)
        return isLogo
    }

    /// A logo is not taller than wide, and at least a twentieth of it is see-through. A JPEG,
    /// or a PNG without transparency, is a picture.
    static func looksLikeLogo(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, height <= width * 1.5 else { return false }
        if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool, !hasAlpha { return false }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        let side = 32
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: side * side * 4) else { return false }
        var clear = 0
        for index in stride(from: 3, to: side * side * 4, by: 4) where pixels[index] < 26 {
            clear += 1
        }
        return Double(clear) / Double(side * side) >= 0.05
    }

    private func send(body: Data, key: String, notesStatus: Bool, token: String? = nil, saves: Bool = true) async throws -> Answer {
        do {
            try await waitForSlot()
        } catch {
            if notesStatus { noteFailure("Waiting for AniList's rate limit") }
            if saves, let stale = cache.read(key: key, maxAge: .infinity) { return Answer(data: stale, isSaved: true) }
            throw error
        }
        sentAt.append(Date())

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            noteLimits(from: http)
            let code = http?.statusCode ?? 0
            guard code == 200 else {
                let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
                if notesStatus { noteFailure("HTTP \(code) \(snippet)") }
                if code == 429 { throw ClientError.rateLimited }
                if let message = Self.errorMessage(in: data) { throw ClientError.refused(code, message) }
                throw ClientError.badResponse(code)
            }
            if let message = Self.errorMessage(in: data) {
                // An error sent as 200. It is never saved, so the next ask reaches AniList.
                if notesStatus { noteFailure("AniList: \(message)") }
                if Self.hasData(data) { return Answer(data: data, isSaved: false) }
                throw ClientError.answeredWithError(message)
            }
            if notesStatus { status.lastSuccess = Date() }
            if saves { cache.write(data, key: key) }
            return Answer(data: data, isSaved: false)
        } catch {
            // Bad answers are noted above with their body; this is the network failing.
            if notesStatus, !(error is ClientError) {
                noteFailure(error.localizedDescription)
            }
            if saves, let stale = cache.read(key: key, maxAge: .infinity) { return Answer(data: stale, isSaved: true) }
            throw error
        }
    }

    func noteFailure(_ message: String) {
        status.lastFailure = Date()
        status.lastFailureMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForSlot() async throws {
        let deadline = Date().addingTimeInterval(Self.longestWait)
        while true {
            let now = Date()
            sentAt.removeAll { now.timeIntervalSince($0) >= 60 }
            var readyAt = now
            if let blockedUntil, blockedUntil > readyAt {
                readyAt = blockedUntil
            }
            if sentAt.count >= Self.requestsPerMinute, let oldest = sentAt.first {
                readyAt = max(readyAt, oldest.addingTimeInterval(60))
            }
            if readyAt <= now { return }
            guard readyAt <= deadline else { throw ClientError.rateLimited }
            try await Task.sleep(nanoseconds: UInt64(readyAt.timeIntervalSince(now) * 1_000_000_000) + 50_000_000)
        }
    }

    private func noteLimits(from response: HTTPURLResponse?) {
        guard let response else { return }
        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 60
            blockedUntil = Date().addingTimeInterval(retryAfter)
            return
        }
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap({ Int($0) }),
           remaining <= 0 {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { TimeInterval($0) }
            blockedUntil = reset.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(60)
        }
    }

    /// A variable without a value is left out, so its argument is left out too. AniList reads an
    /// explicit null as a filter: `isAdult: null` finds nothing, `season: null` nothing either.
    static func body(query: String, variables: [String: Any?]) throws -> Data {
        var cleaned: [String: Any] = [:]
        for (name, value) in variables {
            if let value, let present = unwrapped(value) {
                cleaned[name] = present
            }
        }
        return try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": cleaned],
            options: [.sortedKeys]
        )
    }

    /// The value inside however many optionals hold it (a `Bool?` passed as `Any?`), or nil.
    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first?.value else { return nil }
        return unwrapped(wrapped)
    }

    /// AniList's own error in an answer it sent as 200, joined into one line, or nil.
    static func errorMessage(in data: Data) -> String? {
        // Cheap look before parsing: nearly every answer has no errors.
        guard data.range(of: Data("\"errors\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]], !errors.isEmpty else { return nil }
        let messages = errors.compactMap { ($0["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return messages.isEmpty ? "unknown error" : messages.joined(separator: "; ")
    }

    /// Whether an answer with errors still carries some data (one of several pages, say).
    static func hasData(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any] else { return false }
        return payload.values.contains { !($0 is NSNull) }
    }

    static func cacheKey(for body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}

/// Answers from AniList and ani.zip, one file each in Caches/AniList.
struct AniListDiskCache {
    let directory: URL

    /// Raised when what is saved has to be read differently, so older answers are dropped.
    static let formatVersion = 2
    private static let buildMarker = ".build"

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches.appendingPathComponent("AniList", isDirectory: true)
        }
    }

    /// This copy of the app: its version and build, and when it was installed. Test builds can
    /// share a version and build, so the install time tells them apart.
    static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var installed = "?"
        if let executable = Bundle.main.executableURL,
           let modified = (try? FileManager.default.attributesOfItem(atPath: executable.path))?[.modificationDate] as? Date {
            installed = String(Int(modified.timeIntervalSince1970))
        }
        return "\(formatVersion)|\(version)|\(build)|\(installed)"
    }

    func read(key: String, maxAge: TimeInterval) -> Data? {
        let url = directory.appendingPathComponent(key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        guard maxAge == .infinity || Date().timeIntervalSince(modified) < maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    func readWithAge(key: String) -> (data: Data, age: TimeInterval)? {
        let url = directory.appendingPathComponent(key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, Date().timeIntervalSince(modified))
    }

    func write(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func remove(key: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key))
    }

    /// Drops every saved answer written by another build than `build`, then notes `build`.
    /// True when answers were dropped (or there was nothing noted yet).
    @discardableResult
    func removeAllIfWritten(byAnotherBuildThan build: String) -> Bool {
        let marker = directory.appendingPathComponent(Self.buildMarker)
        if let noted = try? String(contentsOf: marker, encoding: .utf8), noted == build {
            return false
        }
        removeAll()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(build.utf8).write(to: marker, options: .atomic)
        return true
    }
}
