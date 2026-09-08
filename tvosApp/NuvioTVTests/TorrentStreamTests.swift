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
        let registry = PieceWaiterRegistry()
        var hasPiece0 = false

        let task = Task {
            await registry.wait(0) { _ in hasPiece0 }
            return true
        }

        // Initially not completed
        try? await Task.sleep(nanoseconds: 20_000_000)
        hasPiece0 = true
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
}
