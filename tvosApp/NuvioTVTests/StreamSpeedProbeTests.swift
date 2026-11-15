import XCTest
@testable import NuvioTV

final class StreamSpeedProbeTests: XCTestCase {
    private func stream(_ id: String) -> NuvioStream {
        NuvioStream(url: "https://cdn.example.com/\(id).mkv", name: id, description: nil, addonName: "Test")
    }

    func testClassifiesSpeedAgainstResolution() {
        XCTAssertEqual(StreamSpeedVerdict.classify(mbps: 60, resolution: 2160), .fast)
        XCTAssertEqual(StreamSpeedVerdict.classify(mbps: 30, resolution: 2160), .ok)
        XCTAssertEqual(StreamSpeedVerdict.classify(mbps: 20, resolution: 2160), .slow)
        XCTAssertEqual(StreamSpeedVerdict.classify(mbps: 20, resolution: 1080), .fast)
        XCTAssertEqual(StreamSpeedVerdict.classify(mbps: 6, resolution: 720), .ok)
        XCTAssertEqual(StreamSpeedVerdict.classify(mbps: 2, resolution: 480), .slow)
    }

    func testTopPickStaysUnlessItIsSlow() {
        let a = stream("a"), b = stream("b"), c = stream("c")
        XCTAssertEqual(StreamSpeedRanking.overallPick(ranked: [a, b, c], verdicts: [:])?.id, a.id)
        XCTAssertEqual(StreamSpeedRanking.overallPick(ranked: [a, b, c], verdicts: [a.id: .ok])?.id, a.id)
        XCTAssertEqual(StreamSpeedRanking.overallPick(ranked: [a, b, c], verdicts: [b.id: .fast])?.id, a.id)
    }

    func testSlowTopPickGivesWayToTheBestCheckedAlternative() {
        let a = stream("a"), b = stream("b"), c = stream("c")
        XCTAssertEqual(
            StreamSpeedRanking.overallPick(ranked: [a, b, c], verdicts: [a.id: .slow, b.id: .slow, c.id: .ok])?.id,
            c.id
        )
        XCTAssertEqual(
            StreamSpeedRanking.overallPick(ranked: [a, b, c], verdicts: [a.id: .slow, b.id: .fast, c.id: .fast])?.id,
            b.id
        )
    }

    func testSlowTopPickStaysWhenNoAlternativeWasCheckedFaster() {
        let a = stream("a"), b = stream("b")
        XCTAssertEqual(StreamSpeedRanking.overallPick(ranked: [a, b], verdicts: [a.id: .slow])?.id, a.id)
        XCTAssertNil(StreamSpeedRanking.overallPick(ranked: [], verdicts: [:]))
    }

    func testSourcesAreNeverOpenedToJudgeThem() {
        // A cached-looking AIOStreams / TorBox link resolves on request; judging
        // it must not open it, so with nothing to go by there is no verdict.
        let cached = NuvioStream(
            url: "https://aiostreams.example.com/api/v1/debrid/playback/abc/file.mkv",
            name: "⚡ [TB] 1080p", description: "Movie.1080p.mkv", addonName: "AIOStreams"
        )
        XCTAssertNil(StreamSpeedProbe.verdict(for: cached, resolution: 1080))
        XCTAssertNil(StreamSpeedProbe.verdict(for: stream("direct"), resolution: 1080))
    }

    private func torrent(_ description: String) -> NuvioStream {
        NuvioStream(
            url: nil, name: "Torrentio 1080p", description: description, addonName: "Torrentio",
            infoHash: "abcdef0123456789abcdef0123456789abcdef01"
        )
    }

    func testReadsSeedersFromTheSourceText() {
        XCTAssertEqual(StreamSpeedProbe.seeders(in: torrent("Movie.1080p\n👤 188 💾 27.9 GB")), 188)
        XCTAssertEqual(StreamSpeedProbe.seeders(in: torrent("Seeders: 1,204")), 1204)
        XCTAssertEqual(StreamSpeedProbe.seeders(in: torrent("seeds 7 | 2.1 GB")), 7)
        XCTAssertNil(StreamSpeedProbe.seeders(in: torrent("Movie.1080p 💾 2 GB")))
    }

    func testTorrentsAreJudgedBySeedersForTheirResolution() {
        XCTAssertEqual(StreamSpeedProbe.seederVerdict(for: torrent("👤 60"), resolution: 2160), .fast)
        XCTAssertEqual(StreamSpeedProbe.seederVerdict(for: torrent("👤 20"), resolution: 2160), .ok)
        XCTAssertEqual(StreamSpeedProbe.seederVerdict(for: torrent("👤 5"), resolution: 2160), .slow)
        XCTAssertEqual(StreamSpeedProbe.seederVerdict(for: torrent("👤 5"), resolution: 720), .ok)
        XCTAssertNil(StreamSpeedProbe.seederVerdict(for: torrent("no count"), resolution: 1080))
    }

    func testDirectLinksAreNotJudgedBySeeders() {
        let direct = NuvioStream(url: "https://cdn.example.com/a.mkv", name: "a", description: "👤 3", addonName: "Test")
        XCTAssertNil(StreamSpeedProbe.seederVerdict(for: direct, resolution: 1080))
    }
}
