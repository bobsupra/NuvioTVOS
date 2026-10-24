import Foundation
import Combine

/// Live numbers for the loading overlay and the playback HUD.
struct UsenetStreamStats: Equatable, Sendable {
    var downloadRate: Double = 0
    var busyConnections = 0
    var totalConnections = 0
    var bufferedAheadBytes: Int64 = 0
    var cacheHitRate: Double?
    var missingArticles = 0
    var fallbackArticles = 0
    var server = ""
    var serverCount = 0
    var fileName = ""
    var kind = ""
    var fileSize: Int64 = 0
    var speedLimitMbps = 0

    var downloadRateFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(downloadRate), countStyle: .file) + "/s"
    }

    var bufferedFormatted: String {
        ByteCountFormatter.string(fromByteCount: bufferedAheadBytes, countStyle: .memory)
    }

    var connectionsText: String { "\(busyConnections)/\(totalConnections)" }

    /// HUD line 1: where the articles come from and how fast.
    var connectionLine: String {
        let host = server.isEmpty ? "Usenet" : server + (serverCount > 1 ? " +\(serverCount - 1)" : "")
        var parts = [host, "\(connectionsText) conn", downloadRateFormatted]
        if speedLimitMbps > 0 { parts.append("max \(speedLimitMbps) Mbit/s") }
        return parts.joined(separator: " · ")
    }

    /// HUD line 2: what the article cache holds and what went missing.
    var cacheLine: String {
        var parts = ["ahead \(bufferedFormatted)"]
        if let cacheHitRate { parts.append("hit \(Int((cacheHitRate * 100).rounded()))%") }
        parts.append("missing \(missingArticles)")
        if fallbackArticles > 0 { parts.append("backup \(fallbackArticles)") }
        return parts.joined(separator: " · ")
    }

    var summary: String { connectionLine + " · " + cacheLine }
}

/// Starts and stops the one active Usenet stream, the way
/// `TorrentEngineManager` does for torrents.
@MainActor
final class UsenetEngineManager: ObservableObject {
    static let shared = UsenetEngineManager()

    @Published private(set) var isStreaming = false
    @Published private(set) var lastError: String?
    @Published private(set) var activeStats = UsenetStreamStats()
    /// Set when the playing release turns out too damaged; the player then
    /// switches to another source at the current position.
    @Published private(set) var damagedStreamURL: URL?
    private var damagedGeneration: Int?

    private var session: UsenetStreamSession?
    private var server: UsenetStreamServer?
    private var pool: UsenetConnectionPool?
    private var statsTask: Task<Void, Never>?
    private(set) var activeStreamURL: URL?
    private var generation = 0

    private init() {}

    /// Downloads and parses the NZB, connects to the servers, works out the
    /// file (also inside stored RAR sets and obfuscated releases), checks the
    /// release is complete and returns the local playback URL.
    func startStream(_ spec: UsenetStreamSpec) async throws -> URL {
        generation &+= 1
        let current = generation
        await stopCurrent()
        lastError = nil

        let servers = UsenetSettings.servers(for: spec)
        guard !servers.isEmpty else {
            lastError = UsenetError.noServers.localizedDescription
            throw UsenetError.noServers
        }

        let pool = UsenetConnectionPool(servers: servers, speedLimitMbps: UsenetSettings.speedLimitMbps())
        do {
            let nzb = try await Self.loadNZB(spec.nzbURL)
            let resolver = UsenetReleaseResolver(nzb: nzb, pool: pool, mustInclude: spec.fileMustInclude, fileIdx: spec.fileIdx)
            let source = try await resolver.resolve()
            try Task.checkCancellation()

            let health = try await UsenetHealthCheck.check(source, pool: pool)
            usenetLog.notice("usenet: \(source.name, privacy: .public) [\(source.kind.rawValue, privacy: .public)] — \(source.volumes.count) file(s), \(health.missing)/\(health.checked) sampled articles missing")
            guard UsenetHealthCheck.isPlayable(health) else { throw UsenetError.releaseIncomplete }

            let session = UsenetStreamSession(source: source, pool: pool, profile: UsenetSettings.profile()) { [weak self] in
                Task { @MainActor in self?.reportDamage(generation: current) }
            }
            try await session.prepare()
            guard current == generation, !Task.isCancelled else {
                await session.stop()
                throw CancellationError()
            }
            let server = UsenetStreamServer(session: session, fileName: source.name, fileLength: source.totalSize)
            let url = try await server.start()
            self.session = session
            self.server = server
            self.pool = pool
            self.activeStreamURL = url
            activeStats = UsenetStreamStats(
                totalConnections: pool.totalConnections,
                server: servers.first?.host ?? "",
                serverCount: servers.count,
                fileName: source.name,
                kind: source.kind.rawValue,
                fileSize: source.totalSize,
                speedLimitMbps: pool.speedLimitMbps
            )
            isStreaming = true
            Self.remember(source: spec.url.absoluteString, playback: url.absoluteString)
            if damagedGeneration == current { damagedStreamURL = url }
            startStatsLoop(session: session, pool: pool, generation: current)
            return url
        } catch is CancellationError {
            await pool.shutdown()
            throw CancellationError()
        } catch {
            await pool.shutdown()
            if (error as? UsenetError) == .nzbUnreadable { UsenetNZBCache.remove(spec.nzbURL) }
            lastError = error.localizedDescription
            usenetLog.error("usenet: start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// A delayed player exit only stops its own stream, never a newer one.
    func stopActiveStream(for sourceURL: URL) async {
        guard activeStreamURL == sourceURL else { return }
        generation &+= 1
        await stopCurrent()
    }

    func stopAll() async {
        generation &+= 1
        await stopCurrent()
    }

    /// Errors where another release of the same title may well work, so the
    /// caller can move on to the next Usenet stream.
    nonisolated static func isReleaseProblem(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let usenet = error as? UsenetError else { return true }
        switch usenet {
        case .noServers, .serverRejected: return false
        default: return true
        }
    }

    private func stopCurrent() async {
        statsTask?.cancel()
        statsTask = nil
        let session = self.session
        let server = self.server
        self.session = nil
        self.server = nil
        self.pool = nil
        activeStreamURL = nil
        isStreaming = false
        activeStats = UsenetStreamStats()
        damagedStreamURL = nil
        damagedGeneration = nil
        await server?.stop()
        await session?.stop()
    }

    private func reportDamage(generation: Int) {
        guard generation == self.generation else { return }
        damagedGeneration = generation
        if let activeStreamURL { damagedStreamURL = activeStreamURL }
    }

    // MARK: - Which add-on stream a playback URL came from

    private nonisolated static let historyLock = NSLock()
    private nonisolated(unsafe) static var sourceByPlaybackURL: [String: String] = [:]

    /// The add-on stream URL in one canonical form (nil for non-Usenet URLs).
    nonisolated static func canonicalSource(_ string: String) -> String? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let spec = UsenetStreamSpec(url: url) else { return nil }
        return spec.url.absoluteString
    }

    nonisolated static func remember(source: String, playback: String) {
        guard let canonical = canonicalSource(source) else { return }
        historyLock.lock()
        defer { historyLock.unlock() }
        if sourceByPlaybackURL.count > 64 { sourceByPlaybackURL.removeAll() }
        sourceByPlaybackURL[playback] = canonical
    }

    /// Failover excludes the local playback URLs that failed; each Usenet
    /// start gets a new one, so match them back to the add-on stream.
    nonisolated static func isExcluded(sourceURL: String, excludedPlaybackURLs: Set<String>) -> Bool {
        guard let canonical = canonicalSource(sourceURL), !excludedPlaybackURLs.isEmpty else { return false }
        if excludedPlaybackURLs.contains(where: { canonicalSource($0) == canonical }) { return true }
        historyLock.lock()
        defer { historyLock.unlock() }
        return excludedPlaybackURLs.contains { sourceByPlaybackURL[$0] == canonical }
    }

    private func startStatsLoop(session: UsenetStreamSession, pool: UsenetConnectionPool, generation: Int) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var lastBytes: Int64 = 0
            var lastTime = Date()
            var rate: Double = 0
            while !Task.isCancelled {
                let sessionStats = await session.stats()
                let poolStats = await pool.stats()
                let now = Date()
                let elapsed = max(0.25, now.timeIntervalSince(lastTime))
                let instant = Double(max(0, sessionStats.downloadedBytes - lastBytes)) / elapsed
                rate = rate == 0 ? instant : rate * 0.6 + instant * 0.4
                lastBytes = sessionStats.downloadedBytes
                lastTime = now
                guard let self, self.generation == generation else { return }
                let lookups = sessionStats.cacheHits + sessionStats.cacheMisses
                var stats = self.activeStats
                stats.downloadRate = rate
                stats.busyConnections = poolStats.busyConnections
                stats.totalConnections = poolStats.totalConnections
                stats.fallbackArticles = poolStats.fallbackArticles
                stats.bufferedAheadBytes = sessionStats.bufferedAheadBytes
                stats.missingArticles = sessionStats.missingArticles
                stats.cacheHitRate = lookups > 0 ? Double(sessionStats.cacheHits) / Double(lookups) : nil
                if stats != self.activeStats { self.activeStats = stats }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The NZB from the disk cache, else from the indexer (then cached).
    nonisolated static func loadNZB(_ url: URL) async throws -> UsenetNZB {
        if let data = UsenetNZBCache.cached(url) {
            if let nzb = try? UsenetNZB.parse(data) { return nzb }
            UsenetNZBCache.remove(url)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/x-nzb, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UsenetError.nzbDownloadFailed(status) }
        let nzb = try UsenetNZB.parse(data)
        UsenetNZBCache.store(data, for: url)
        return nzb
    }
}
