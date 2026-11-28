import XCTest
@testable import NuvioTV

@MainActor
final class TraktOpenPlaybackRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "trakt-open-playback-\(UUID().uuidString)")!
        TraktOpenPlaybackRecovery.defaults = defaults
    }

    override func tearDown() {
        TraktOpenPlaybackRecovery.defaults = .standard
        defaults = nil
        super.tearDown()
    }

    private func meta(id: String = "tt0499549") -> NuvioMeta {
        let json = #"{"id":"\#(id)","name":"Avatar","type":"movie"}"#
        return try! JSONDecoder().decode(NuvioMeta.self, from: Data(json.utf8))
    }

    /// Rewrites the stored note as if an earlier launch had written it.
    private func markAsEarlierLaunch() {
        var note = TraktOpenPlaybackRecovery.read()!
        note.launch = "earlier"
        defaults.set(try! JSONEncoder().encode(note), forKey: TraktOpenPlaybackRecovery.key)
    }

    func testThisLaunchsOwnSessionIsNotRecovered() {
        TraktOpenPlaybackRecovery.update(meta: meta(), position: 2600, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", force: true)
        XCTAssertNil(TraktOpenPlaybackRecovery.pending(activeProfileID: "1"))
    }

    func testAnEarlierLaunchsSessionIsRecoveredOnlyForItsProfile() {
        let now = Date()
        TraktOpenPlaybackRecovery.update(meta: meta(), position: 2600, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", force: true, now: now)
        markAsEarlierLaunch()
        XCTAssertNil(TraktOpenPlaybackRecovery.pending(activeProfileID: "2", now: now))
        XCTAssertEqual(TraktOpenPlaybackRecovery.pending(activeProfileID: "1", now: now)?.position, 2600)
    }

    func testAnOldOrNearlyFinishedSessionIsDropped() {
        let now = Date()
        TraktOpenPlaybackRecovery.update(meta: meta(), position: 2600, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", force: true, now: now)
        markAsEarlierLaunch()
        XCTAssertNil(TraktOpenPlaybackRecovery.pending(activeProfileID: "1", now: now.addingTimeInterval(4 * 86_400)))
        XCTAssertNil(TraktOpenPlaybackRecovery.read())

        TraktOpenPlaybackRecovery.update(meta: meta(), position: 10500, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", force: true, now: now)
        markAsEarlierLaunch()
        XCTAssertNil(TraktOpenPlaybackRecovery.pending(activeProfileID: "1", now: now))
        XCTAssertNil(TraktOpenPlaybackRecovery.read())
    }

    func testOnlyAPauseOrStopForTheSameTitleClearsTheNote() {
        TraktOpenPlaybackRecovery.update(meta: meta(), position: 600, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", force: true)
        TraktOpenPlaybackRecovery.clear(metaID: "tt0000001")
        XCTAssertNotNil(TraktOpenPlaybackRecovery.read())
        TraktOpenPlaybackRecovery.clear(metaID: "tt0499549")
        XCTAssertNil(TraktOpenPlaybackRecovery.read())
    }

    func testUpdatesAreThrottledUnlessForced() {
        let now = Date()
        TraktOpenPlaybackRecovery.update(meta: meta(), position: 600, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", force: true, now: now)
        TraktOpenPlaybackRecovery.update(meta: meta(), position: 610, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", now: now.addingTimeInterval(10))
        XCTAssertEqual(TraktOpenPlaybackRecovery.read()?.position, 600)
        TraktOpenPlaybackRecovery.update(meta: meta(), position: 640, duration: 10709, season: nil, episode: nil,
                                         profileID: "1", now: now.addingTimeInterval(40))
        XCTAssertEqual(TraktOpenPlaybackRecovery.read()?.position, 640)
    }
}
