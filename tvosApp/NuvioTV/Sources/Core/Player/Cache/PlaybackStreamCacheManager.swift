import CryptoKit
import Foundation
import OSLog

struct StreamProbeResult: Sendable {
    let supportsRange: Bool
    let contentLength: Int64
    let etag: String?
    let lastModified: String?
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

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
                let length = http.expectedContentLength
                let etag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let lastMod = http.value(forHTTPHeaderField: "Last-Modified")?.trimmingCharacters(in: .whitespacesAndNewlines)
                if length > 0 && acceptRanges {
                    return StreamProbeResult(supportsRange: true, contentLength: length, etag: etag, lastModified: lastMod)
                }
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                return StreamProbeResult(supportsRange: false, contentLength: 0, etag: nil, lastModified: nil)
            }
        } catch {
            diskCacheLog.warning("HEAD probe failed for \(url.absoluteString): \(error.localizedDescription)")
        }

        // Some providers reject HEAD while supporting byte ranges. Keep the
        // legacy probe, but trust it only when the response is a complete 206
        // for bytes 0-1 with a numeric total.
        var rangeReq = URLRequest(url: url)
        rangeReq.httpMethod = "GET"
        for (k, v) in headers { rangeReq.setValue(v, forHTTPHeaderField: k) }
        rangeReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: rangeReq)
            if let http = response as? HTTPURLResponse, http.statusCode == 206,
               data.count == 2,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
                let bounds = contentRange.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
                if bounds.count == 4, bounds[0].lowercased() == "bytes",
                   bounds[1] == "0", bounds[2] == "1", let total = Int64(bounds[3]), total > 0 {
                    return StreamProbeResult(
                        supportsRange: true, contentLength: total,
                        etag: http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
                        lastModified: http.value(forHTTPHeaderField: "Last-Modified")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
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
            targetLeadSeconds: targetLeadSeconds ?? 150.0,
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
