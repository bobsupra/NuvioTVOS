import Foundation
import Combine

/// Live numbers for the loading overlay and the playback HUD.
struct UsenetStreamStats: Equatable, Sendable {
    var downloadRate: Double = 0
    var busyConnections = 0
    /// What the servers accept, fewer than `configuredConnections` once a
    /// server turned a connection away.
    var totalConnections = 0
    var configuredConnections = 0
    var bufferedAheadBytes: Int64 = 0
    /// The same in seconds of video, once the player knows the duration.
    var bufferedAheadSeconds: Double?
    /// Articles kept on disk (Read Ahead on Disk), what they may use now and what tvOS
    /// reports free (-1: unknown).
    var diskBytes: Int64 = 0
    var diskBudgetBytes: Int64 = 0
    var diskFreeBytes: Int64 = -1
    var cacheHitRate: Double?
    var missingArticles = 0
    var fallbackArticles = 0
    /// Connections closed and opened again (idle too long, or dropped).
    var reconnects = 0
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
        let bytes = ByteCountFormatter.string(fromByteCount: bufferedAheadBytes, countStyle: .memory)
        guard let bufferedAheadSeconds, bufferedAheadSeconds.isFinite else { return bytes }
        return bytes + " (\(Int(bufferedAheadSeconds.rounded())) s)"
    }

    var connectionsText: String { "\(busyConnections)/\(totalConnections)" }

    /// HUD line 1: where the articles come from and how fast.
    var connectionLine: String {
        let host = server.isEmpty ? "Usenet" : server + (serverCount > 1 ? " +\(serverCount - 1)" : "")
        var connections = "\(connectionsText) conn"
        if configuredConnections > totalConnections { connections += " (\(configuredConnections) set)" }
        var parts = [host, connections, downloadRateFormatted]
        if speedLimitMbps > 0 { parts.append("max \(speedLimitMbps) Mbit/s") }
        return parts.joined(separator: " · ")
    }

    /// HUD line 2: what the article cache holds and what went missing.
    var cacheLine: String {
        var parts = ["ahead \(bufferedFormatted)"]
        if let cacheHitRate { parts.append("hit \(Int((cacheHitRate * 100).rounded()))%") }
        parts.append("missing \(missingArticles)")
        if fallbackArticles > 0 { parts.append("backup \(fallbackArticles)") }
        if reconnects > 0 { parts.append("reconnect \(reconnects)") }
        return parts.joined(separator: " · ")
    }

    /// HUD line 3 with Read Ahead on Disk: what it holds, what it may use now and what tvOS
    /// reports free; nil when it is off.
    var diskLine: String? {
        guard diskBudgetBytes > 0 || diskBytes > 0 else { return nil }
        var line = ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file)
            + " of " + ByteCountFormatter.string(fromByteCount: diskBudgetBytes, countStyle: .file)
        if diskFreeBytes >= 0 {
            line += " · tvOS free " + ByteCountFormatter.string(fromByteCount: diskFreeBytes, countStyle: .file)
        }
        return line
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
    /// The playing stream's servers, so a preparation for the same ones shares its pool.
    private var activeServers: [UsenetServerConfig] = []
    /// A stream got ready ahead (`prepare`): starting it skips the NZB, the file and the check.
    private var preparedStart: PreparedStart?
    private var generation = 0
    /// The duration last passed to the session.
    private var reportedDuration: Double = 0

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
        let prepared = takePrepared(spec)
        do {
            let source: UsenetStreamSource
            if let prepared {
                source = prepared
                usenetLog.notice("usenet: \(source.name, privacy: .public) — got ready ahead, starting at once")
            } else {
                source = try await Self.readyRelease(spec, pool: pool)
            }
            try Task.checkCancellation()

            // Off the main thread: it clears what an earlier stream left on disk.
            let diskBytes = UsenetSettings.diskReadAheadBytes()
            let diskReadAhead = await Task.detached(priority: .userInitiated) {
                UsenetDiskReadAhead.make(sizeBytes: diskBytes)
            }.value
            let session = UsenetStreamSession(
                source: source, pool: pool, profile: UsenetSettings.profile(), diskReadAhead: diskReadAhead
            ) { [weak self] in
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
            self.activeServers = servers
            activeStats = UsenetStreamStats(
                totalConnections: pool.totalConnections,
                configuredConnections: pool.totalConnections,
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

    /// The NZB read, the file worked out and the release checked: what a start waits for
    /// before the session opens.
    private static func readyRelease(_ spec: UsenetStreamSpec, pool: UsenetConnectionPool) async throws -> UsenetStreamSource {
        let nzb = try await loadNZB(spec.nzbURL)
        let resolver = UsenetReleaseResolver(nzb: nzb, pool: pool, mustInclude: spec.fileMustInclude, fileIdx: spec.fileIdx)
        let source = try await resolver.resolve()
        try Task.checkCancellation()
        let health = try await UsenetHealthCheck.check(source, pool: pool)
        usenetLog.notice("usenet: \(source.name, privacy: .public) [\(source.kind.rawValue, privacy: .public)] — \(source.volumes.count) file(s), \(health.missing)/\(health.checked) sampled articles missing")
        guard UsenetHealthCheck.isPlayable(health) else { throw UsenetError.releaseIncomplete }
        return source
    }

    // MARK: - Getting a stream ready ahead

    private struct PreparedStart {
        let url: URL
        let source: UsenetStreamSource
        let at: Date
    }

    /// How long a stream got ready ahead may wait to be started; the check is redone after.
    static let preparedLifetime: TimeInterval = 30 * 60
    /// Connections a preparation opens when it can't share the playing stream's.
    static let preparationConnections = 2

    /// Gets `spec` ready while another stream plays (the next episode): reads its NZB, works
    /// out its file and checks the release, without stopping or slowing the playing stream.
    /// It shares the playing stream's connections when the servers are the same (no more
    /// connections than the plan allows), else opens two of its own. `startStream(spec)` then
    /// skips all that. Throws what a start would (an incomplete release, say).
    func prepare(_ spec: UsenetStreamSpec) async throws {
        if let preparedStart, preparedStart.url == spec.url,
           Date().timeIntervalSince(preparedStart.at) < Self.preparedLifetime { return }
        let servers = UsenetSettings.servers(for: spec)
        guard !servers.isEmpty else { throw UsenetError.noServers }
        let shared = servers == activeServers ? self.pool : nil
        let preparationPool = shared ?? UsenetConnectionPool(servers: servers.map {
            UsenetServerConfig(host: $0.host, port: $0.port, useSSL: $0.useSSL, username: $0.username,
                               password: $0.password, maxConnections: min($0.maxConnections, Self.preparationConnections))
        })
        do {
            let source = try await Self.readyRelease(spec, pool: preparationPool)
            if shared == nil { await preparationPool.shutdown() }
            preparedStart = PreparedStart(url: spec.url, source: source, at: Date())
        } catch {
            if shared == nil { await preparationPool.shutdown() }
            usenetLog.notice("usenet: couldn't get the next stream ready: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The release `prepare` got ready for `spec`, once: nil when there is none or it waited too long.
    private func takePrepared(_ spec: UsenetStreamSpec) -> UsenetStreamSource? {
        guard let preparedStart, preparedStart.url == spec.url else { return nil }
        self.preparedStart = nil
        guard Date().timeIntervalSince(preparedStart.at) < Self.preparedLifetime else { return nil }
        return preparedStart.source
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
        activeServers = []
        reportedDuration = 0
        isStreaming = false
        activeStats = UsenetStreamStats()
        damagedStreamURL = nil
        damagedGeneration = nil
        await server?.stop()
        await session?.stop()
    }

    /// The player's duration for the playing Usenet stream, once (and when it
    /// changes): the session sizes its read-ahead in seconds of video.
    func reportDuration(_ duration: Double, playbackURL: String?) {
        guard let session, let activeStreamURL, playbackURL == activeStreamURL.absoluteString,
              duration.isFinite, duration > 60, abs(duration - reportedDuration) > 1 else { return }
        reportedDuration = duration
        Task { await session.setDuration(duration) }
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
                stats.configuredConnections = poolStats.configuredConnections
                stats.fallbackArticles = poolStats.fallbackArticles
                stats.reconnects = poolStats.reconnects
                stats.bufferedAheadBytes = sessionStats.bufferedAheadBytes
                stats.bufferedAheadSeconds = sessionStats.bufferedAheadSeconds
                stats.diskBytes = sessionStats.diskBytes
                stats.diskBudgetBytes = sessionStats.diskBudgetBytes
                stats.diskFreeBytes = sessionStats.diskFreeBytes
                stats.missingArticles = sessionStats.missingArticles
                stats.cacheHitRate = lookups > 0 ? Double(sessionStats.cacheHits) / Double(lookups) : nil
                if stats != self.activeStats { self.activeStats = stats }
                // Twice a second: the seek bar draws the read-ahead from these, and a seek
                // changes it at once.
                try? await Task.sleep(for: .milliseconds(500))
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

/// While on (`UsenetPreparation.$isAhead.withValue(true) { … }`), a Usenet stream picked for
/// playback is only got ready (`UsenetEngineManager.prepare`), not started, and its
/// `nuvio-usenet://` URL comes back: the stream playing now keeps going. The player starts it
/// when the next episode begins.
enum UsenetPreparation {
    @TaskLocal static var isAhead = false
}
