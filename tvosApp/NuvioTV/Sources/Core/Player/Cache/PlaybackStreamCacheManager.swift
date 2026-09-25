import CryptoKit
import Foundation
import OSLog

struct StreamProbeResult: Sendable {
    let supportsRange: Bool
    let contentLength: Int64
    let etag: String?
    let lastModified: String?
    let resolvedURL: URL?

    init(
        supportsRange: Bool,
        contentLength: Int64,
        etag: String?,
        lastModified: String?,
        resolvedURL: URL? = nil
    ) {
        self.supportsRange = supportsRange
        self.contentLength = contentLength
        self.etag = etag
        self.lastModified = lastModified
        self.resolvedURL = resolvedURL
    }
}

struct PlaybackStreamCacheContentRange: Sendable {
    let start: Int64
    let end: Int64
    let total: Int64?

    static func parse(_ contentRange: String) -> PlaybackStreamCacheContentRange? {
        let value = contentRange.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count == 2, components[0].lowercased() == "bytes" else { return nil }

        let rangeAndTotal = components[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = decimalInt64(bounds[0]),
              let end = decimalInt64(bounds[1]),
              start <= end else { return nil }

        let total: Int64?
        if rangeAndTotal[1] == "*" {
            total = nil
        } else {
            guard let parsedTotal = decimalInt64(rangeAndTotal[1]), parsedTotal > end else { return nil }
            total = parsedTotal
        }
        return PlaybackStreamCacheContentRange(start: start, end: end, total: total)
    }

    private static func decimalInt64(_ value: Substring) -> Int64? {
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int64(value)
    }
}

enum PlaybackStreamCacheRedirectPolicy {
    static func redirectedRequest(
        _ request: URLRequest,
        response: HTTPURLResponse,
        originalURL: URL?,
        range: String?,
        customHeaders: [String: String]
    ) -> URLRequest {
        var updated = request
        if response.url != nil, sameOrigin(originalURL, request.url) {
            for (name, value) in customHeaders {
                updated.setValue(value, forHTTPHeaderField: name)
            }
        } else {
            for name in customHeaders.keys {
                updated.setValue(nil, forHTTPHeaderField: name)
            }
        }
        if let range {
            updated.setValue(range, forHTTPHeaderField: "Range")
        }
        return updated
    }

    private static func sameOrigin(_ source: URL?, _ destination: URL?) -> Bool {
        guard let source, let destination,
              let sourceScheme = source.scheme?.lowercased(),
              let destinationScheme = destination.scheme?.lowercased(),
              let sourceHost = source.host?.lowercased(),
              let destinationHost = destination.host?.lowercased(),
              sourceScheme == destinationScheme,
              sourceHost == destinationHost,
              let sourcePort = effectivePort(for: source, scheme: sourceScheme),
              let destinationPort = effectivePort(for: destination, scheme: destinationScheme) else {
            return false
        }
        return sourcePort == destinationPort
    }

    private static func effectivePort(for url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

private final class RangeProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let originalURL: URL
    private let customHeaders: [String: String]
    private let lock = NSLock()
    private var storedResolvedURL: URL?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse)?, Error>?
    private var task: URLSessionDataTask?
    private var finished = false

    var resolvedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedResolvedURL
    }

    init(originalURL: URL, customHeaders: [String: String]) {
        self.originalURL = originalURL
        self.customHeaders = customHeaders
    }

    func load(in session: URLSession, request: URLRequest) async throws -> (Data, HTTPURLResponse)? {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            task.delegate = self
            lock.lock()
            self.continuation = continuation
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let updated = PlaybackStreamCacheRedirectPolicy.redirectedRequest(
            request,
            response: response,
            originalURL: originalURL,
            range: "bytes=0-1",
            customHeaders: customHeaders
        )
        lock.lock()
        storedResolvedURL = updated.url
        lock.unlock()
        completionHandler(updated)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let parsedRange = PlaybackStreamCacheContentRange.parse(contentRange),
              parsedRange.start == 0,
              parsedRange.end == 1,
              let total = parsedRange.total,
              total >= 2,
              http.expectedContentLength < 0 || http.expectedContentLength == 2 else {
            completionHandler(.cancel)
            finish(returning: nil)
            return
        }

        lock.lock()
        self.response = http
        storedResolvedURL = http.url
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let exceedsExpectedBody = body.count + data.count > 2
        if !exceedsExpectedBody { body.append(data) }
        let task = self.task
        lock.unlock()

        if exceedsExpectedBody {
            finish(returning: nil)
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(throwing: error)
            return
        }
        lock.lock()
        let result: (Data, HTTPURLResponse)?
        if body.count == 2, let response {
            result = (body, response)
        } else {
            result = nil
        }
        lock.unlock()
        finish(returning: result)
    }

    private func finish(returning result: (Data, HTTPURLResponse)?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// A task delegate that preserves caller-supplied Range and headers across HTTP redirect hops
/// and records the final resolved resource URL.
private final class ProbeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var resolvedURL: URL?
    private let originalRange: String?
    private let customHeaders: [String: String]

    init(originalRange: String?, customHeaders: [String: String]) {
        self.originalRange = originalRange
        self.customHeaders = customHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let target = request.url {
            self.resolvedURL = target
        }
        let updated = PlaybackStreamCacheRedirectPolicy.redirectedRequest(
            request,
            response: response,
            originalURL: task.originalRequest?.url,
            range: originalRange,
            customHeaders: customHeaders
        )
        completionHandler(updated)
    }
}

/// Manages active HTTP stream disk cache servers for playback sessions.
actor PlaybackStreamCacheManager {
    static let shared = PlaybackStreamCacheManager()

    private var activeServer: PlaybackStreamCacheServer?
    private var activeSessionURL: URL?

    private init() {}

    /// Checks if a remote stream supports HTTP Range requests and resolves its total file length and HTTP validators.
    func probeRangeSupport(
        url: URL,
        headers: [String: String] = [:],
        sessionConfiguration: URLSessionConfiguration? = nil
    ) async -> StreamProbeResult {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
        }

        let session = sessionConfiguration.map { URLSession(configuration: $0) } ?? URLSession.shared

        // 1. Gather metadata with HEAD, but verify range support with a Range GET below.
        let headDelegate = ProbeRedirectDelegate(originalRange: nil, customHeaders: headers)
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        var headETag: String?
        var headLastModified: String?
        do {
            let (_, response) = try await session.data(for: req, delegate: headDelegate)
            if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 206) {
                headETag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines)
                headLastModified = http.value(forHTTPHeaderField: "Last-Modified")?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
            }
        } catch {
            diskCacheLog.warning("HEAD probe failed for \(url.absoluteString): \(error.localizedDescription)")
        }

        // 2. Some providers reject HEAD or require byte ranges. Send Range GET with redirect-aware delegate.
        let rangeDelegate = RangeProbeDelegate(originalURL: url, customHeaders: headers)
        var rangeReq = URLRequest(url: url)
        rangeReq.httpMethod = "GET"
        for (k, v) in headers { rangeReq.setValue(v, forHTTPHeaderField: k) }
        rangeReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        do {
            if let (data, http) = try await rangeDelegate.load(in: session, request: rangeReq),
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let parsedRange = PlaybackStreamCacheContentRange.parse(contentRange),
               parsedRange.start == 0,
               parsedRange.end == 1,
               let total = parsedRange.total,
               total >= 2,
               data.count == 2 {
                return StreamProbeResult(
                    supportsRange: true, contentLength: total,
                    etag: http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? headETag,
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? headLastModified,
                    resolvedURL: rangeDelegate.resolvedURL ?? http.url
                )
            }
        } catch {
            diskCacheLog.warning("Range probe failed for \(url.absoluteString): \(error.localizedDescription)")
        }

        return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
    }

    /// Reuse is scoped to the exact request URL and its validator snapshot. A title,
    /// filename, Last-Modified date, or ETag shared by different resources is not
    /// proof that their bytes are interchangeable. Renewed URLs remain isolated until
    /// the source supplies a trusted immutable file identity.
    private func resolveVerifiedSession(
        for remoteURL: URL,
        probe: StreamProbeResult,
        headers: [String: String],
        cacheFileIdentity: PlaybackCacheFileIdentity?,
        canonicalMediaKey: String?,
        filename: String?,
        cacheRoot: URL
    ) -> (sessionID: String, manifest: PlaybackStreamManifest) {
        let requestIdentityKey = Self.requestIdentityKey(
            for: remoteURL, headers: headers, probe: probe
        )
        if let cacheFileIdentity {
            let identity = "\(cacheFileIdentity.cacheKey):\(probe.contentLength)"
            let hash = SHA256.hash(data: Data(identity.utf8))
            let candidate = "content_v1_" + hash.prefix(16).map { String(format: "%02x", $0) }.joined()
            let directory = cacheRoot.appendingPathComponent(candidate, isDirectory: true)
            if var existing = PlaybackStreamDiskCache.readManifest(in: directory),
               existing.sessionID == candidate,
               existing.fileLength == probe.contentLength,
               existing.cacheFileIdentity == cacheFileIdentity.cacheKey {
                existing.requestIdentityKey = requestIdentityKey
                existing.etag = probe.etag
                existing.lastModified = probe.lastModified
                existing.normalizedURLPath = remoteURL.absoluteString.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                existing.lastAccessedAt = Date()
                PlaybackStreamDiskCache.writeManifest(existing, to: directory)
                return (candidate, existing)
            }
            let chosenID = FileManager.default.fileExists(atPath: directory.path)
                ? candidate + "_" + UUID().uuidString : candidate
            return (chosenID, PlaybackStreamManifest(
                sessionID: chosenID, fileLength: probe.contentLength, etag: probe.etag,
                lastModified: probe.lastModified, canonicalMediaKey: canonicalMediaKey,
                cacheFileIdentity: cacheFileIdentity.cacheKey, requestIdentityKey: requestIdentityKey,
                filename: filename ?? remoteURL.lastPathComponent,
                normalizedURLPath: remoteURL.absoluteString.components(separatedBy: "?")[0].components(separatedBy: "#")[0],
                createdAt: Date(), lastAccessedAt: Date()
            ))
        }

        // Preserve validators verbatim, including weak prefixes. They can invalidate
        // an exact-URL entry, but are never treated as a cross-resource content hash.
        let candidate = requestIdentityKey
        // Version the namespace to avoid trusting caches created by heuristic URL matching.
        let directory = cacheRoot.appendingPathComponent(candidate, isDirectory: true)
        if var existing = PlaybackStreamDiskCache.readManifest(in: directory),
           existing.sessionID == candidate,
           existing.fileLength == probe.contentLength,
           existing.etag == probe.etag,
           existing.lastModified == probe.lastModified,
           (existing.requestIdentityKey == requestIdentityKey || existing.requestIdentityKey == nil) {
            existing.lastAccessedAt = Date()
            PlaybackStreamDiskCache.writeManifest(existing, to: directory)
            return (candidate, existing)
        }

        // A typed identity may have created the content namespace before a later
        // exact-URL reopen loses torrent metadata. Reuse only a manifest carrying
        // the complete exact request signature and matching validators/length.
        if !FileManager.default.fileExists(atPath: directory.path),
           let entries = try? FileManager.default.contentsOfDirectory(
                at: cacheRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
           ) {
            for entry in entries {
                guard var existing = PlaybackStreamDiskCache.readManifest(in: entry),
                      entry.lastPathComponent == existing.sessionID,
                      existing.requestIdentityKey == requestIdentityKey,
                      existing.fileLength == probe.contentLength,
                      existing.etag == probe.etag,
                      existing.lastModified == probe.lastModified else { continue }
                existing.lastAccessedAt = Date()
                PlaybackStreamDiskCache.writeManifest(existing, to: entry)
                return (existing.sessionID, existing)
            }
        }

        // A missing/corrupt manifest cannot authorize reuse of orphaned chunks.
        let chosenID = FileManager.default.fileExists(atPath: directory.path)
            ? candidate + "_" + UUID().uuidString
            : candidate
        let manifest = PlaybackStreamManifest(
            sessionID: chosenID,
            fileLength: probe.contentLength,
            etag: probe.etag,
            lastModified: probe.lastModified,
            canonicalMediaKey: canonicalMediaKey,
            cacheFileIdentity: nil,
            requestIdentityKey: requestIdentityKey,
            filename: filename ?? remoteURL.lastPathComponent,
            normalizedURLPath: remoteURL.absoluteString.components(separatedBy: "?")[0].components(separatedBy: "#")[0],
            createdAt: Date(),
            lastAccessedAt: Date()
        )
        return (chosenID, manifest)
    }

    private static func requestIdentityKey(
        for remoteURL: URL, headers: [String: String], probe: StreamProbeResult
    ) -> String {
        var identity: [String?] = [remoteURL.absoluteString, String(probe.contentLength), probe.etag, probe.lastModified]
        for key in headers.keys.sorted() {
            identity.append(key.lowercased())
            identity.append(headers[key])
        }
        let identityData = (try? JSONEncoder().encode(identity)) ?? Data(remoteURL.absoluteString.utf8)
        let hash = SHA256.hash(data: identityData)
        return "url_v2_" + hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Prepares a hybrid disk cache server for a remote stream URL if Range requests are supported and caching is enabled.
    func prepareCacheServer(
        for remoteURL: URL,
        headers: [String: String] = [:],
        canonicalMediaKey: String? = nil,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        filename: String? = nil,
        durationSeconds: Double? = nil,
        customLimitGB: Int? = nil,
        targetLeadSeconds: Double? = nil,
        cacheRoot: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        freeSpaceProvider: PlaybackStreamDiskCache.FreeSpaceProvider? = nil
    ) async -> URL? {
        await stopActiveSession()

        let probe = await probeRangeSupport(url: remoteURL, headers: headers, sessionConfiguration: sessionConfiguration)
        guard probe.supportsRange, (probe.contentLength > 10 * 1024 * 1024 || cacheRoot != nil) else {
            diskCacheLog.info("Stream does not support range requests or length is unknown. Bypassing disk cache proxy.")
            return nil
        }

        let storedLimit = ProfileSettings.current.integer(forKey: SettingsKey.hybridDiskCacheLimitGB)
        let limitGB = customLimitGB ?? (storedLimit > 0 ? storedLimit : 20)
        let limitBytes = Int64(limitGB) * 1024 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = cacheRoot ?? caches.appendingPathComponent("PlaybackStreamCache", isDirectory: true)

        let (sessionID, manifest) = resolveVerifiedSession(
            for: remoteURL,
            probe: probe,
            headers: headers,
            cacheFileIdentity: cacheFileIdentity,
            canonicalMediaKey: canonicalMediaKey,
            filename: filename,
            cacheRoot: root
        )

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL,
            fileLength: probe.contentLength,
            customHeaders: headers,
            sessionID: sessionID,
            maxDiskCacheSizeBytes: limitBytes,
            targetLeadSeconds: targetLeadSeconds ?? 600.0,
            cacheRoot: root,
            manifest: manifest,
            sessionConfiguration: sessionConfiguration,
            freeSpaceProvider: freeSpaceProvider
        )
        if let durationSeconds, durationSeconds > 0 {
            await server.updateTimeline(playheadOffset: 0, durationSeconds: durationSeconds)
        }

        do {
            let localURL = try await server.start()
            activeServer = server
            activeSessionURL = remoteURL
            diskCacheLog.notice("Hybrid Disk Cache engaged for \(remoteURL.lastPathComponent) [session=\(sessionID)] -> \(localURL.absoluteString)")
            return localURL
        } catch {
            diskCacheLog.error("Failed to start PlaybackStreamCacheServer: \(error.localizedDescription)")
            return nil
        }
    }

    func stopActiveSession() async {
        if let server = activeServer {
            await server.stop()
            activeServer = nil
            activeSessionURL = nil
        }
    }

    func currentCachedFraction() async -> Double {
        if let server = activeServer {
            return await server.cachedFraction()
        }
        return 0
    }

    func activeStreamMetrics() async -> (cachedBytes: Int64, totalBytes: Int64)? {
        guard let server = activeServer else { return nil }
        let total = await server.fileLength
        let cached = await server.currentCachedBytes
        return (cachedBytes: cached, totalBytes: total)
    }

    func currentCachedRanges() async -> [Range<Int64>] {
        if let server = activeServer {
            return await server.cachedByteRanges()
        }
        return []
    }

    func notifySeek(for sourceURL: URL, playheadSeconds: Double, totalDuration: Double) async {
        guard activeSessionURL == sourceURL, let server = activeServer,
              totalDuration.isFinite, totalDuration > 0, playheadSeconds.isFinite else { return }
        let fraction = min(1, max(0, playheadSeconds / totalDuration))
        let length = await server.fileLength
        let offset = fraction >= 1 ? length : Int64(fraction * Double(length))
        await server.updateTimeline(playheadOffset: offset, durationSeconds: totalDuration, isSeek: true)
    }

    func updateTimeline(playheadSeconds: Double, totalDuration: Double) async {
        guard let server = activeServer, totalDuration > 0, playheadSeconds >= 0 else { return }
        let totalBytes = await server.fileLength
        guard totalBytes > 0 else { return }
        let playheadByte = min(totalBytes, max(0, Int64((playheadSeconds / totalDuration) * Double(totalBytes))))
        await server.updateTimeline(playheadOffset: playheadByte, durationSeconds: totalDuration)
    }

    func contiguousCachedForwardSeconds(playheadSeconds: Double, totalDuration: Double) async -> Double {
        guard let server = activeServer, totalDuration > 0, playheadSeconds >= 0 else { return 0 }
        let totalBytes = await server.fileLength
        guard totalBytes > 0 else { return 0 }
        let playheadByte = min(totalBytes, max(0, Int64((playheadSeconds / totalDuration) * Double(totalBytes))))
        await server.updateTimeline(playheadOffset: playheadByte, durationSeconds: totalDuration)
        let bytesAhead = await server.contiguousCachedBytesAhead(of: playheadByte)
        guard bytesAhead > 0 else { return 0 }
        let fractionAhead = Double(bytesAhead) / Double(totalBytes)
        return fractionAhead * totalDuration
    }
}
