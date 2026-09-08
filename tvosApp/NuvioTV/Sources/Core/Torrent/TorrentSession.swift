import Foundation
import OSLog

actor TorrentSession {
    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "webm", "mov", "ts", "wmv", "flv"
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
        filename: String? = nil
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
        try await session.begin(magnetURI: magnetURI, timeout: timeout)
        let streamURL = try await session.startStreaming()
        return (session, streamURL)
    }

    private func begin(magnetURI: String, timeout: TimeInterval) async throws {
        engine.onPieceFinished = { [waiters] index in
            waiters.fulfill(index)
        }
        engine.startMagnet(magnetURI, resumeData: nil)
        guard engine.isActive else { throw TorrentEngineError.failedToStart }

        let deadline = Date().addingTimeInterval(timeout)
        var lastDiscoveryRetry = Date()

        while !engine.hasMetadata {
            try await Task.sleep(nanoseconds: 200_000_000)
            if Date().timeIntervalSince(lastDiscoveryRetry) >= 12 {
                engine.retryMetadataDiscovery()
                lastDiscoveryRetry = Date()
            }
            if Date() > deadline {
                throw TorrentEngineError.metadataTimeout
            }
        }
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
    }

    private func startStreaming(port: UInt16 = 8888) async throws -> URL {
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
        await server.primeHeadAndTail()
        await server.updatePlayhead(absoluteOffset: file.offset)
        let url = try await server.start()
        self.server = server
        return url
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
