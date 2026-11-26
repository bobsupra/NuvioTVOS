import XCTest
@testable import NuvioTV

final class TorrentStreamTests: XCTestCase {
    private var testStore: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.torrent.stream.\(UUID().uuidString)"
        testStore = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testStore.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStreamTorrentDetection() {
        let torrentStream = NuvioStream(
            url: nil,
            name: "Torrentio 4K",
            description: "4K | 12.5 GB",
            addonName: "Torrentio",
            infoHash: "0123456789abcdef0123456789abcdef01234567"
        )
        XCTAssertTrue(torrentStream.isTorrentStream)
        XCTAssertTrue(torrentStream.isDebridResolvable)

        let directStream = NuvioStream(
            url: "https://example.com/video.mp4",
            name: "Direct Stream",
            description: "1080p",
            addonName: "HTTP"
        )
        XCTAssertFalse(directStream.isTorrentStream)
        XCTAssertFalse(directStream.isDebridResolvable)

        let emptyUrlStream = NuvioStream(
            url: "",
            name: "Empty URL",
            description: "No URL or hash",
            addonName: nil
        )
        XCTAssertFalse(emptyUrlStream.isTorrentStream)
    }

    func testTorrentSettingsDefaultsAndMutations() {
        XCTAssertFalse(TorrentSettings.isEnabled(store: testStore))
        XCTAssertFalse(TorrentSettings.hasConsent(store: testStore))
        XCTAssertFalse(TorrentSettings.hideStats(store: testStore))
        XCTAssertEqual(TorrentSettings.cacheLimitGB(store: testStore), TorrentSettings.defaultCacheLimitGB)

        TorrentSettings.setEnabled(false, store: testStore)
        XCTAssertFalse(TorrentSettings.isEnabled(store: testStore))

        TorrentSettings.setEnabled(true, store: testStore)
        XCTAssertFalse(TorrentSettings.isEnabled(store: testStore), "P2P must stay disabled until consent is accepted")

        TorrentSettings.setConsentAccepted(true, store: testStore)
        XCTAssertTrue(TorrentSettings.isEnabled(store: testStore))

        TorrentSettings.setHideStats(true, store: testStore)
        XCTAssertTrue(TorrentSettings.hideStats(store: testStore))

        TorrentSettings.setCacheLimitGB(8.0, store: testStore)
        XCTAssertEqual(TorrentSettings.cacheLimitGB(store: testStore), 8.0)
    }

    func testTorrentCacheLimitBoundsRestoredValuesWithoutRewritingThem() {
        let cases: [(stored: Double, expected: Double)] = [
            (-1, TorrentSettings.defaultCacheLimitGB),
            (0, TorrentSettings.defaultCacheLimitGB),
            (0.5, 2),
            (2, 2),
            (8.5, 8.5),
            (40, 40),
            (41, 40),
            (.greatestFiniteMagnitude, 40)
        ]

        for sample in cases {
            testStore.set(sample.stored, forKey: SettingsKey.p2pCacheLimitGB)
            XCTAssertEqual(TorrentSettings.cacheLimitGB(store: testStore), sample.expected)
            XCTAssertEqual(testStore.double(forKey: SettingsKey.p2pCacheLimitGB), sample.stored)
        }
    }

    func testTorrentSourceParserNormalizesMagnetAndTorrentURLs() {
        let hash = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"

        let magnet = TorrentSourceParser.parse(
            url: "magnet:?xt=urn:btih:\(hash)&index=4",
            infoHash: nil,
            fileIdx: nil
        )
        XCTAssertNil(magnet.directURL)
        XCTAssertEqual(magnet.infoHash, hash.lowercased())
        XCTAssertEqual(magnet.fileIdx, 4)

        let torrent = TorrentSourceParser.parse(
            url: "torrent://\(hash)/2",
            infoHash: nil,
            fileIdx: nil
        )
        XCTAssertNil(torrent.directURL)
        XCTAssertEqual(torrent.infoHash, hash.lowercased())
        XCTAssertEqual(torrent.fileIdx, 2)

        let direct = TorrentSourceParser.parse(
            urls: ["magnet:?xt=urn:btih:\(hash)", "https://example.com/video.mkv"],
            infoHash: nil,
            fileIdx: nil
        )
        XCTAssertEqual(direct.directURL, "https://example.com/video.mkv")
        XCTAssertEqual(direct.infoHash, hash.lowercased())
    }

    func testTorrentSourceParserStripsTrackerPrefixesAndInvalidHints() {
        XCTAssertEqual(
            TorrentSourceParser.normalizedTrackers([
                "tracker:udp://tracker.example/announce",
                "https://tracker.example/http",
                "dht://router.example",
                "tracker:udp://tracker.example/announce"
            ]),
            ["udp://tracker.example/announce", "https://tracker.example/http"]
        )
    }

    func testStreamDTOUsesClientResolveTorrentMetadata() throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let payload = """
            {
              "clientResolve": {
                "magnetUri": "magnet:?xt=urn:btih:\(hash)",
                "fileIdx": 3,
                "sources": ["tracker:udp://tracker.example/announce"],
                "filename": "Episode.mkv"
              }
            }
            """
        let data = Data(payload.utf8)

        let raw = try JSONDecoder().decode(StreamAddonStreamDTO.self, from: data)
        let stream = try XCTUnwrap(raw.toNuvioStream(addonName: "Resolver"))

        XCTAssertNil(stream.url)
        XCTAssertEqual(stream.infoHash, hash)
        XCTAssertEqual(stream.fileIdx, 3)
        XCTAssertEqual(stream.sources, ["udp://tracker.example/announce"])
        XCTAssertEqual(stream.filename, "Episode.mkv")
        XCTAssertTrue(stream.isTorrentStream)
    }

    func testSwarmStatsFormatting() {
        var stats = SwarmStats()
        stats.downloadRate = 500
        XCTAssertEqual(stats.downloadRateFormatted, "500 B/s")

        stats.downloadRate = 512 * 1024
        XCTAssertEqual(stats.downloadRateFormatted, "512 KB/s")

        stats.downloadRate = 5.5 * 1024 * 1024
        XCTAssertEqual(stats.downloadRateFormatted, "5.5 MB/s")
    }

    func testPieceWaiterRegistry() async {
        final class PieceState: @unchecked Sendable {
            private let lock = NSLock()
            private var _hasPiece = false
            var hasPiece: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _hasPiece }
                set { lock.lock(); defer { lock.unlock() }; _hasPiece = newValue }
            }
        }

        let registry = PieceWaiterRegistry()
        let state = PieceState()

        let task = Task {
            await registry.wait(0) { _ in state.hasPiece }
            return true
        }

        // Initially not completed
        try? await Task.sleep(nanoseconds: 20_000_000)
        state.hasPiece = true
        registry.fulfill(0)

        let result = await task.value
        XCTAssertTrue(result)
    }

    func testStreamPickerIncludesTorrentWhenP2PEnabled() {
        let torrentStream = NuvioStream(
            url: nil,
            name: "Torrentio 1080p",
            description: "1080p | 3.2 GB",
            addonName: "Torrentio",
            infoHash: "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        )

        let streams = [torrentStream]

        // When P2P is disabled (includeDebrid is false)
        let excluded = SmartPlaybackSelector.playableStreams(from: streams, includeDebrid: false)
        XCTAssertEqual(excluded.count, 0)

        // When P2P is enabled (includeDebrid is true)
        let included = SmartPlaybackSelector.playableStreams(from: streams, includeDebrid: true)
        XCTAssertEqual(included.count, 1)
        XCTAssertEqual(included.first?.infoHash, "abcdefabcdefabcdefabcdefabcdefabcdefabcd")
    }

    func testTorrentStartupWatchdogExtendsWhilePiecesArriveAndCapsAtCeiling() {
        var tracker = TorrentStartupWatchdogTracker(
            initialDownloadedBytes: 0,
            maxTotalTimeoutSeconds: 120
        )

        var activeStats = SwarmStats()
        activeStats.connectedSeeds = 17
        activeStats.connectedPeers = 19
        activeStats.downloadRate = 629.5 * 1024
        activeStats.downloadedBytes = 12 * 1024 * 1024

        // Window 1 (30s): pieces actively downloading -> keep waiting.
        if case .waitAnotherWindow = tracker.evaluateWindow(windowSeconds: 30, stats: activeStats) {
            // expected
        } else {
            XCTFail("Expected active swarm to receive another watchdog window at 30s")
        }

        // Window 2 (60s): momentary 0 B/s rate, but total downloaded bytes grew -> keep waiting.
        activeStats.downloadRate = 0
        activeStats.downloadedBytes = 28 * 1024 * 1024
        if case .waitAnotherWindow = tracker.evaluateWindow(windowSeconds: 30, stats: activeStats) {
            // expected
        } else {
            XCTFail("Expected byte progress to keep watchdog waiting at 60s")
        }

        // Window 3 (90s): still downloading blocks inside a large piece (rate > 0, bytes unchanged) -> keep waiting.
        activeStats.downloadRate = 300 * 1024
        if case .waitAnotherWindow = tracker.evaluateWindow(windowSeconds: 30, stats: activeStats) {
            // expected
        } else {
            XCTFail("Expected positive download rate to keep watchdog waiting at 90s")
        }

        // Window 4 (120s): hits maxTotalTimeoutSeconds ceiling -> time out.
        XCTAssertEqual(tracker.evaluateWindow(windowSeconds: 30, stats: activeStats), .timeOut)
    }

    func testTorrentStartupWatchdogTimesOutDeadSwarmImmediatelyAndStalledConnectedSwarmAfterOneGraceWindow() {
        var deadTracker = TorrentStartupWatchdogTracker(initialDownloadedBytes: 0)
        XCTAssertEqual(
            deadTracker.evaluateWindow(windowSeconds: 30, stats: SwarmStats()),
            .timeOut,
            "A swarm with 0 peers, 0 seeds, 0 bytes, and 0 B/s must time out at 30s"
        )

        var connectedTracker = TorrentStartupWatchdogTracker(initialDownloadedBytes: 0)
        var connectedNoBytes = SwarmStats()
        connectedNoBytes.connectedSeeds = 5
        connectedNoBytes.connectedPeers = 8

        // First window with connected peers still unchoking gets one grace window.
        if case .waitAnotherWindow = connectedTracker.evaluateWindow(windowSeconds: 30, stats: connectedNoBytes) {
            // expected
        } else {
            XCTFail("Expected connected swarm to receive one grace window for peer unchoking")
        }

        // Second consecutive window with 0 bytes and 0 rate times out.
        XCTAssertEqual(
            connectedTracker.evaluateWindow(windowSeconds: 30, stats: connectedNoBytes),
            .timeOut,
            "Connected peers delivering zero bytes for two consecutive windows must time out"
        )

        var completeTracker = TorrentStartupWatchdogTracker(initialDownloadedBytes: 500_000_000)
        var completeStats = SwarmStats()
        completeStats.downloadedBytes = 500_000_000
        completeStats.isComplete = true

        // Completed file gets one probe grace window, then times out if player still never starts.
        if case .waitAnotherWindow = completeTracker.evaluateWindow(windowSeconds: 30, stats: completeStats) {
            // expected
        } else {
            XCTFail("Expected completed torrent on disk to receive one probe grace window")
        }
        XCTAssertEqual(completeTracker.evaluateWindow(windowSeconds: 30, stats: completeStats), .timeOut)
    }

    func testTorrentIdentityExclusionAndActiveSessionReuse() {
        let hashUpper = "0123456789ABCDEF0123456789ABCDEF01234567"
        let hashLower = hashUpper.lowercased()
        let otherHash = "fedcba9876543210fedcba9876543210fedcba98"

        let movieIdentity = TorrentStreamIdentity(infoHash: hashUpper, fileIdx: nil, filename: "Movie.1080p.mkv")
        let sameMovieNormalized = TorrentStreamIdentity(infoHash: hashLower, fileIdx: nil, filename: " movie.1080p.mkv ")
        let episode1 = TorrentStreamIdentity(infoHash: hashLower, fileIdx: 0, filename: "Show.S01E01.mkv")
        let episode2 = TorrentStreamIdentity(infoHash: hashLower, fileIdx: 1, filename: "Show.S01E02.mkv")
        let otherMovie = TorrentStreamIdentity(infoHash: otherHash, fileIdx: nil, filename: "Movie.1080p.mkv")

        XCTAssertEqual(movieIdentity, sameMovieNormalized)
        XCTAssertNotEqual(episode1, episode2)
        XCTAssertNotEqual(movieIdentity, otherMovie)

        let playbackURL = URL(string: "http://127.0.0.1:8888/stream/\(UUID().uuidString)")!
        TorrentEngineManager.remember(identity: episode1, playbackURL: playbackURL.absoluteString)

        XCTAssertTrue(
            TorrentEngineManager.isExcluded(
                infoHash: hashUpper,
                fileIdx: 0,
                filename: "Show.S01E01.mkv",
                excludedPlaybackURLs: [playbackURL.absoluteString]
            ),
            "Failed local playback URL must exclude the matching torrent identity on failover"
        )
        XCTAssertFalse(
            TorrentEngineManager.isExcluded(
                infoHash: hashUpper,
                fileIdx: 1,
                filename: "Show.S01E02.mkv",
                excludedPlaybackURLs: [playbackURL.absoluteString]
            ),
            "Excluding one file in a season pack must not exclude another episode in the same torrent"
        )
        XCTAssertFalse(
            TorrentEngineManager.isExcluded(
                infoHash: otherHash,
                fileIdx: 0,
                filename: "Show.S01E01.mkv",
                excludedPlaybackURLs: [playbackURL.absoluteString]
            )
        )

        XCTAssertEqual(
            TorrentEngineManager.shouldReuseActiveSession(
                isStreaming: true,
                hasActiveSession: true,
                activeIdentity: movieIdentity,
                activeStreamURL: playbackURL,
                requestedIdentity: sameMovieNormalized
            ),
            playbackURL,
            "Restarting the exact same active torrent must preserve the existing swarm session"
        )
        XCTAssertNil(
            TorrentEngineManager.shouldReuseActiveSession(
                isStreaming: true,
                hasActiveSession: true,
                activeIdentity: movieIdentity,
                activeStreamURL: playbackURL,
                requestedIdentity: otherMovie
            ),
            "A different torrent must start a fresh session"
        )
        XCTAssertNil(
            TorrentEngineManager.shouldReuseActiveSession(
                isStreaming: false,
                hasActiveSession: true,
                activeIdentity: movieIdentity,
                activeStreamURL: playbackURL,
                requestedIdentity: sameMovieNormalized
            ),
            "An inactive manager must not report a reusable URL"
        )
    }

    @MainActor
    func testPlayerWatchdogKeepsWaitingWhileActiveP2PTorrentDownloadsAndFailsOverWhenDead() async throws {
        let localTorrentURL = URL(string: "http://127.0.0.1:8888/stream/test-active-torrent")!

        // 1. Active torrent making progress across multiple windows must NOT fail over.
        do {
            let coordinator = PlaybackSessionCoordinator(
                engineSettingProvider: { "MPVKit" },
                loadDispatcher: { _, _, _ in }
            )
            let model = PlayerViewModel(sessionCoordinator: coordinator)
            defer { model.shutdown() }

            var pollCount = 0
            var reloadCalls = 0
            model.loadWatchdogSleepNanosecondsOverride = 25_000_000 // 25ms per 30s window
            model.loadWatchdogMaxTorrentTimeoutSeconds = 120
            model.activeTorrentWatchdogStatsProvider = { urlString in
                guard urlString == localTorrentURL.absoluteString else { return nil }
                pollCount += 1
                var stats = SwarmStats()
                stats.connectedSeeds = 17
                stats.connectedPeers = 19
                stats.downloadRate = 629.5 * 1024
                stats.downloadedBytes = Int64(pollCount) * 8 * 1024 * 1024
                return stats
            }
            model.reloadCurrentStream = { _, _ in
                reloadCalls += 1
                return nil
            }

            model.load(
                url: localTorrentURL,
                meta: NuvioMeta(id: "tt6910001", name: "Active Torrent Test", type: "movie"),
                subtitle: "",
                resumeFrom: nil
            )

            // Wait past two 30s windows (60s simulated) — still well below 120s cap.
            try await Task.sleep(nanoseconds: 70_000_000)
            XCTAssertEqual(reloadCalls, 0, "Active P2P torrent must not trigger failover at 30s or 60s")
            XCTAssertGreaterThanOrEqual(pollCount, 3, "Watchdog should have polled active swarm progress across windows")
        }

        // 2. Dead torrent (0 seeds, 0 peers, 0 bytes) must time out after one window and exclude its URL.
        do {
            let coordinator = PlaybackSessionCoordinator(
                engineSettingProvider: { "MPVKit" },
                loadDispatcher: { _, _, _ in }
            )
            let model = PlayerViewModel(sessionCoordinator: coordinator)
            defer { model.shutdown() }

            var excludedOnReload: [String] = []
            let reloadTriggered = expectation(description: "Dead torrent triggers failover")
            model.loadWatchdogSleepNanosecondsOverride = 20_000_000
            model.activeTorrentWatchdogStatsProvider = { urlString in
                guard urlString == localTorrentURL.absoluteString else { return nil }
                return SwarmStats()
            }
            model.reloadCurrentStream = { _, excluded in
                excludedOnReload = excluded
                reloadTriggered.fulfill()
                return nil
            }

            model.load(
                url: localTorrentURL,
                meta: NuvioMeta(id: "tt6910002", name: "Dead Torrent Test", type: "movie"),
                subtitle: "",
                resumeFrom: nil
            )

            await fulfillment(of: [reloadTriggered], timeout: 2.0)
            XCTAssertTrue(excludedOnReload.contains(localTorrentURL.absoluteString))
        }
    }
}
