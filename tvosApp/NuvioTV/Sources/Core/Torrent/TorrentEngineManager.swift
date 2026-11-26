import Foundation
import Combine
import OSLog

@MainActor
final class TorrentEngineManager: ObservableObject {
    static let shared = TorrentEngineManager()

    @Published private(set) var activeStats = SwarmStats()
    @Published private(set) var activeDiagnostics: TorrentSwarmDiagnostics?
    @Published private(set) var startupStage: String?
    @Published private(set) var isStreaming = false
    @Published private(set) var currentInfoHash: String?

    private var activeSession: TorrentSession?
    private(set) var activeStreamURL: URL?
    private(set) var activeIdentity: TorrentStreamIdentity?
    private var statsTimer: AnyCancellable?
    private var startGeneration = 0

    private nonisolated static let historyLock = NSLock()
    private nonisolated(unsafe) static var identityByPlaybackURL: [String: TorrentStreamIdentity] = [:]

    private init() {}

    func isActiveStreamURL(_ urlString: String?) -> Bool {
        guard isStreaming, let urlString, let activeStreamURL else { return false }
        return activeStreamURL.absoluteString == urlString
    }

    nonisolated static func shouldReuseActiveSession(
        isStreaming: Bool,
        hasActiveSession: Bool,
        activeIdentity: TorrentStreamIdentity?,
        activeStreamURL: URL?,
        requestedIdentity: TorrentStreamIdentity
    ) -> URL? {
        guard isStreaming,
              hasActiveSession,
              let activeStreamURL,
              activeIdentity == requestedIdentity else {
            return nil
        }
        return activeStreamURL
    }

    nonisolated static func remember(identity: TorrentStreamIdentity, playbackURL: String) {
        historyLock.lock()
        defer { historyLock.unlock() }
        if identityByPlaybackURL.count > 64 { identityByPlaybackURL.removeAll() }
        identityByPlaybackURL[playbackURL] = identity
    }

    /// Failover excludes the local playback URLs that failed; each torrent
    /// start gets a fresh session token URL, so match them back to the torrent identity.
    nonisolated static func isExcluded(
        infoHash: String,
        fileIdx: Int?,
        filename: String?,
        excludedPlaybackURLs: Set<String>
    ) -> Bool {
        guard !excludedPlaybackURLs.isEmpty else { return false }
        let identity = TorrentStreamIdentity(infoHash: infoHash, fileIdx: fileIdx, filename: filename)
        historyLock.lock()
        defer { historyLock.unlock() }
        return excludedPlaybackURLs.contains { identityByPlaybackURL[$0] == identity }
    }

    /// Starts or resumes a torrent streaming session, returning the local HTTP streaming URL.
    func startStream(
        infoHash: String,
        fileIdx: Int? = nil,
        trackers: [String]? = nil,
        filename: String? = nil,
        timeout: TimeInterval = 40
    ) async throws -> URL {
        let requestedIdentity = TorrentStreamIdentity(
            infoHash: infoHash,
            fileIdx: fileIdx,
            filename: filename
        )
        if let existingURL = Self.shouldReuseActiveSession(
            isStreaming: isStreaming,
            hasActiveSession: activeSession != nil,
            activeIdentity: activeIdentity,
            activeStreamURL: activeStreamURL,
            requestedIdentity: requestedIdentity
        ) {
            startGeneration &+= 1
            Self.remember(identity: requestedIdentity, playbackURL: existingURL.absoluteString)
            torrentLog.notice("[Watchdog:Reuse] Keeping active torrent session for hash=\(requestedIdentity.infoHash)")
            return existingURL
        }

        startGeneration &+= 1
        let generation = startGeneration

        // Stop any currently active stream without invalidating this start.
        await stopCurrentSession()
        guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }

        // Check and prune cache if exceeding configured limit
        pruneCacheIfNeeded()

        currentInfoHash = requestedIdentity.infoHash
        isStreaming = true
        activeStats = SwarmStats()
        activeDiagnostics = nil
        startupStage = "Initializing torrent engine..."

        do {
            let (session, streamURL) = try await TorrentSession.start(
                infoHash: infoHash,
                fileIdx: fileIdx,
                trackers: trackers,
                timeout: timeout,
                filename: filename,
                onStatusUpdate: { [weak self] stage in
                    Task { @MainActor [weak self] in
                        guard let self, self.startGeneration == generation else { return }
                        self.startupStage = stage
                    }
                }
            )
            guard generation == startGeneration, !Task.isCancelled else {
                await session.stop()
                throw CancellationError()
            }
            self.activeSession = session
            self.activeStreamURL = streamURL
            self.activeIdentity = requestedIdentity
            Self.remember(identity: requestedIdentity, playbackURL: streamURL.absoluteString)
            self.startupStage = "Buffering stream..."

            // Start polling stats
            startStatsPolling(for: session)

            return streamURL
        } catch {
            if generation == startGeneration {
                await stopCurrentSession()
            }
            throw error
        }
    }

    /// A delayed player exit may only stop its own server, never a newer one.
    /// Each TorrentStreamServer URL contains its unique session token.
    func stopActiveStream(for sourceURL: URL) async {
        guard activeStreamURL == sourceURL else { return }
        startGeneration &+= 1
        await stopCurrentSession()
    }

    private func stopCurrentSession() async {
        statsTimer?.cancel()
        statsTimer = nil

        let session = activeSession
        activeSession = nil
        activeStreamURL = nil
        activeIdentity = nil
        isStreaming = false
        currentInfoHash = nil
        activeStats = SwarmStats()
        activeDiagnostics = nil
        startupStage = nil

        if let session {
            await session.stop()
        }
    }

    private func startStatsPolling(for session: TorrentSession) {
        statsTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    let stats = await session.currentStats()
                    let diags = await session.currentDiagnostics()
                    await MainActor.run {
                        guard self.activeSession === session else { return }
                        self.activeStats = stats
                        self.activeDiagnostics = diags
                    }
                }
            }
    }

    /// Ensures the torrent cache does not exceed the user-configured quota.
    private func pruneCacheIfNeeded() {
        let maxBytes = Int64(TorrentSettings.cacheLimitGB() * 1024 * 1024 * 1024)
        let currentBytes = TorrentSettings.currentCacheSizeBytes()
        guard currentBytes > maxBytes else { return }

        torrentLog.notice("Cache (\(currentBytes / 1_048_576)MB) exceeds limit (\(maxBytes / 1_048_576)MB), pruning oldest files")
        let dir = TorrentSettings.torrentCacheDirectory
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Sort by oldest modification date
        let sorted = items.sorted {
            let date0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let date1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return date0 < date1
        }

        var prunedBytes: Int64 = 0
        let targetReclaim = currentBytes - maxBytes + (500 * 1024 * 1024) // Reclaim extra 500MB headroom
        for item in sorted {
            guard prunedBytes < targetReclaim else { break }
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try? fm.removeItem(at: item)
            prunedBytes += Int64(size)
        }
    }
}
