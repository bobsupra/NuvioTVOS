import XCTest
@testable import NuvioTV

final class RemoteContinueWatchingRowCacheTests: XCTestCase {
    private var profile = ""

    override func setUp() {
        super.setUp()
        profile = "cache-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        RemoteContinueWatchingRowCache.removeAll()
        super.tearDown()
    }

    private func item(_ id: String) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: NuvioMeta(id: id, name: id, type: "movie"),
            streamUrl: "", position: 60, duration: 600, lastWatchedAt: Date()
        )
    }

    func testSavedRowComesBackForTheSameProfileAndSource() async {
        await RemoteContinueWatchingRowCache.save([item("tt1"), item("tt2")], profileId: profile, source: "TRAKT").value

        let saved = RemoteContinueWatchingRowCache.load(profileId: profile, source: "TRAKT")

        XCTAssertEqual(saved.map(\.id), ["tt1", "tt2"])
    }

    func testRowIsNotShownToAnotherProfileOrSource() async {
        await RemoteContinueWatchingRowCache.save([item("tt1")], profileId: profile, source: "TRAKT").value

        XCTAssertTrue(RemoteContinueWatchingRowCache.load(profileId: profile + "-other", source: "TRAKT").isEmpty)
        XCTAssertTrue(RemoteContinueWatchingRowCache.load(profileId: profile, source: "SIMKL").isEmpty)
    }

    func testRowOlderThanTheLimitIsIgnored() async {
        let saved = Date()
        await RemoteContinueWatchingRowCache.save(
            [item("tt1")], profileId: profile, source: "TRAKT", now: saved
        ).value

        let justInside = saved.addingTimeInterval(RemoteContinueWatchingRowCache.maxAge - 1)
        let justOutside = saved.addingTimeInterval(RemoteContinueWatchingRowCache.maxAge + 1)

        XCTAssertEqual(RemoteContinueWatchingRowCache.load(profileId: profile, source: "TRAKT", now: justInside).count, 1)
        XCTAssertTrue(RemoteContinueWatchingRowCache.load(profileId: profile, source: "TRAKT", now: justOutside).isEmpty)
    }

    func testSavingAnEmptyRowRemovesTheCopy() async {
        await RemoteContinueWatchingRowCache.save([item("tt1")], profileId: profile, source: "TRAKT").value
        await RemoteContinueWatchingRowCache.save([], profileId: profile, source: "TRAKT").value

        XCTAssertTrue(RemoteContinueWatchingRowCache.load(profileId: profile, source: "TRAKT").isEmpty)
    }

    func testAnAccountChangeForgetsEveryRow() async {
        await RemoteContinueWatchingRowCache.save([item("tt1")], profileId: profile, source: "TRAKT").value
        await RemoteContinueWatchingRowCache.save([item("tt2")], profileId: profile, source: "SIMKL").value

        RemoteContinueWatchingRowCache.removeAll()

        XCTAssertTrue(RemoteContinueWatchingRowCache.load(profileId: profile, source: "TRAKT").isEmpty)
        XCTAssertTrue(RemoteContinueWatchingRowCache.load(profileId: profile, source: "SIMKL").isEmpty)
    }
}
