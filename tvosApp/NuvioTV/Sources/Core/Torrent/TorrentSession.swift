import Foundation
import OSLog

actor TorrentSession {
    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "webm", "mov", "ts", "wmv", "flv", "iso", "img"
    ]

    static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://tracker.coppersurfer.tk:6969/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.moeking.me:6969/announce",
        "udp://p4p.arenabg.com:1337/announce",
    ]

    private let engine: TorrentEngine
    private let saveDirectory: URL
    private let preferredFileIndex: Int?
    private let preferredFilename: String?
    private let waiters = PieceWaiterRegistry()

    private var streamFile: TKFile?
    private var server: TorrentStreamServer?
    private var teardown: Task<Void, Never>?

    private init(
        saveDirectory: URL,
        maxPeers: Int,
        extraTrackers: [String],
        preferredFileIndex: Int?,
        preferredFilename: String?
    ) {
        self.saveDirectory = saveDirectory
        self.preferredFileIndex = preferredFileIndex
        self.preferredFilename = preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackers = Array(Set(TorrentSourceParser.normalizedTrackers(extraTrackers) + Self.defaultTrackers))
        self.engine = TorrentEngine(
            saveDirectory: saveDirectory.path,
            maxPeers: maxPeers,
            extraTrackers: trackers
        )
    }

    static func buildMagnetURI(infoHash: String, trackers: [String]?) -> String {
        var magnet = "magnet:?xt=urn:btih:\(infoHash.lowercased())"
        let allTrackers = TorrentSourceParser.normalizedTrackers((trackers ?? []) + defaultTrackers)
        for tracker in allTrackers {
            if let encoded = tracker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                magnet += "&tr=\(encoded)"
            }
        }
        return magnet
    }

    static func start(
        infoHash: String,
        fileIdx: Int? = nil,
        trackers: [String]? = nil,
        timeout: TimeInterval = 40,
        maxPeers: Int = TorrentSettings.defaultMaxPeers,
        filename: String? = nil,
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> (session: TorrentSession, streamURL: URL) {
        let dir = TorrentSettings.torrentCacheDirectory
        let session = TorrentSession(
            saveDirectory: dir,
            maxPeers: maxPeers,
            extraTrackers: trackers ?? [],
            preferredFileIndex: fileIdx,
            preferredFilename: filename
        )
        let magnetURI = buildMagnetURI(infoHash: infoHash, trackers: trackers)
        do {
            try await session.begin(
                magnetURI: magnetURI,
                timeout: timeout,
                infoHash: infoHash,
                trackerCount: (trackers?.count ?? 0) + defaultTrackers.count,
                onStatusUpdate: onStatusUpdate
            )
            try Task.checkCancellation()
            let streamURL = try await session.startStreaming(onStatusUpdate: onStatusUpdate)
            try Task.checkCancellation()
            return (session, streamURL)
        } catch {
            await session.stop()
            throw error
        }
    }

    private func begin(
        magnetURI: String,
        timeout: TimeInterval,
        infoHash: String,
        trackerCount: Int,
        onStatusUpdate: (@Sendable (String) -> Void)?
    ) async throws {
        let startedAt = Date()
        var lastWatchdogLog = Date()
        torrentLog.notice("[Watchdog:Start] Launching magnet hash=\(infoHash) trackers=\(trackerCount)")
        onStatusUpdate?("Connecting to trackers & DHT...")

        engine.onPieceFinished = { [waiters] index in
            waiters.fulfill(index)
        }
        engine.startMagnet(magnetURI, resumeData: nil)
        guard engine.isActive else {
            torrentLog.error("[Watchdog:Start:Failed] Torrent engine rejected magnet URI")
            throw TorrentEngineError.failedToStart
        }

        let deadline = Date().addingTimeInterval(timeout)
        var lastDiscoveryRetry = Date()

        while !engine.hasMetadata {
            try await Task.sleep(nanoseconds: 200_000_000)
            let now = Date()
            let elapsed = now.timeIntervalSince(startedAt)

            if now.timeIntervalSince(lastWatchdogLog) >= 2.0 {
                lastWatchdogLog = now
                let diag = engine.diagnostics()
                let status = "Resolving metadata (\(String(format: "%.1f", elapsed))s · DHT: \(diag.dhtNodes) nodes · Peers: \(diag.numPeers))"
                onStatusUpdate?(status)
                torrentLog.notice("[Watchdog:Metadata] elapsed=\(String(format: "%.1f", elapsed))s dhtNodes=\(diag.dhtNodes) candidates=\(diag.connectCandidates) listPeers=\(diag.listPeers) outgoing=\(diag.outgoingAttempts) failures=\(diag.connectFailures) peers=\(diag.numPeers) seeds=\(diag.numSeeds) lastPeerSource=\(diag.lastPeerSource)")
                if elapsed >= 10.0 && Int(elapsed) % 6 == 0 {
                    torrentLog.warning("[Watchdog:Metadata:Slow] Swarm discovery slow (elapsed: \(String(format: "%.1f", elapsed))s). Candidates: \(diag.connectCandidates), Failures: \(diag.connectFailures). Verify tracker connectivity or DNS.")
                }
            }

            if Date().timeIntervalSince(lastDiscoveryRetry) >= 12 {
                torrentLog.notice("[Watchdog:Metadata] Retrying metadata discovery...")
                engine.retryMetadataDiscovery()
                lastDiscoveryRetry = Date()
            }
            if Date() > deadline {
                let diag = engine.diagnostics()
                var disconnectSummary = ""
                let dict = diag.disconnectReasons
                if !dict.isEmpty {
                    disconnectSummary = dict.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                }
                torrentLog.error("[Watchdog:Metadata:Timeout] Timed out after \(timeout)s. DHT: \(diag.dhtNodes), Outgoing: \(diag.outgoingAttempts), Failures: \(diag.connectFailures), Reasons: \(disconnectSummary)")
                throw TorrentEngineError.metadataTimeout
            }
        }
        let metadataElapsed = Date().timeIntervalSince(startedAt)
        torrentLog.notice("[Watchdog:Metadata:Ready] Acquired in \(String(format: "%.2f", metadataElapsed))s")
        onStatusUpdate?("Metadata acquired, selecting file...")
        try selectStreamFile()
    }

    private func selectStreamFile() throws {
        let files = engine.files()
        guard !files.isEmpty else { throw TorrentEngineError.noPlayableFile }

        let chosen: TKFile = {
            if let filename = preferredFilename, !filename.isEmpty {
                let basename = (filename as NSString).lastPathComponent
                if let exact = files.first(where: {
                    URL(fileURLWithPath: $0.path).lastPathComponent
                        .caseInsensitiveCompare(basename) == .orderedSame
                }) {
                    return exact
                }
                if let contains = files.first(where: {
                    $0.path.range(of: filename, options: .caseInsensitive) != nil
                }) {
                    return contains
                }
            }

            if let index = preferredFileIndex, index >= 0 {
                if let indexed = files.first(where: { $0.index == index }) {
                    return indexed
                }
                if files.indices.contains(index) {
                    return files[index]
                }
            }

            let videoFiles = files.filter { Self.videoExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
            return videoFiles.max(by: { $0.length < $1.length })
                ?? files.max(by: { $0.length < $1.length })
                ?? files[0]
        }()
        streamFile = chosen
        engine.selectFile(chosen.index)
        let sizeMB = chosen.length / (1024 * 1024)
        torrentLog.notice("[Watchdog:FileSelected] '\(chosen.path)' (index: \(chosen.index), size: \(sizeMB) MB)")
    }

    private func startStreaming(
        port: UInt16 = 8888,
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard let file = streamFile else { throw TorrentEngineError.noPlayableFile }
        engine.prepareStreaming(forFile: file.index)
        let server = TorrentStreamServer(
            engine: engine,
            filePath: file.path,
            fileOffset: file.offset,
            fileLength: file.length,
            waiters: waiters,
            pieceLength: engine.pieceLength,
            port: port
        )
        self.server = server
        onStatusUpdate?("Priming playback buffer (head & tail)...")
        torrentLog.notice("[Watchdog:Prebuffer] Priming head and tail pieces...")
        await server.primeHeadAndTail()
        await server.updatePlayhead(absoluteOffset: file.offset)
        let streamURL = try await server.start()
        onStatusUpdate?("Local stream server ready")
        torrentLog.notice("[Watchdog:StreamReady] Stream server ready at \(streamURL.absoluteString)")
        return streamURL
    }

    func currentStats() -> SwarmStats {
        let snapshot = engine.stats()
        var stats = SwarmStats()
        stats.downloadRate = snapshot.downloadRate
        stats.connectedPeers = snapshot.numPeers
        stats.connectedSeeds = snapshot.numSeeds
        stats.progress = snapshot.progress
        stats.downloadedBytes = snapshot.downloadedBytes
        stats.isComplete = snapshot.progress >= 1.0
        return stats
    }

    func currentDiagnostics() -> TorrentSwarmDiagnostics {
        let diag = engine.diagnostics()
        var reasons: [String] = []
        let dict = diag.disconnectReasons
        for (key, count) in dict.sorted(by: { $0.value.intValue > $1.value.intValue }).prefix(3) {
            reasons.append("\(key): \(count)")
        }
        return TorrentSwarmDiagnostics(
            dhtNodes: diag.dhtNodes,
            connectCandidates: diag.connectCandidates,
            listPeers: diag.listPeers,
            outgoingAttempts: diag.outgoingAttempts,
            connectFailures: diag.connectFailures,
            lastPeerSource: (diag.lastPeerSource as String?) ?? "",
            disconnectSummary: reasons.joined(separator: ", ")
        )
    }

    func stop() async {
        if let server {
            await server.stop()
        }
        server = nil
        waiters.fulfillAll()
        let engine = self.engine
        teardown = Task.detached {
            engine.stop()
        }
        await teardown?.value
    }
}
