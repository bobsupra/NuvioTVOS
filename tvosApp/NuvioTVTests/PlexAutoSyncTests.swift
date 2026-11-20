import XCTest
@testable import NuvioTV

final class PlexAutoSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverSyncedServerIsDue() {
        XCTAssertTrue(PlexSessionManager.isSyncDue(lastSyncDate: nil, minimumInterval: 300, now: now))
    }

    func testSyncIsDueOnceTheIntervalHasPassed() {
        let interval = PlexSessionManager.streamListAutoSyncInterval
        XCTAssertFalse(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-(interval - 1)), minimumInterval: interval, now: now))
        XCTAssertTrue(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-interval), minimumInterval: interval, now: now))
    }

    func testReturningToTheAppLooksForNewTitlesWithinMinutes() {
        XCTAssertEqual(PlexSessionManager.foregroundAutoSyncInterval, 15 * 60)
        XCTAssertTrue(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-16 * 60),
            minimumInterval: PlexSessionManager.foregroundAutoSyncInterval,
            now: now))
    }

    func testAFailedSyncWaitsAsLongAsAFinishedOne() {
        let interval = PlexSessionManager.streamListAutoSyncInterval
        // Last finished a day ago, but an attempt failed a minute ago.
        XCTAssertFalse(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-86_400),
            lastAttemptDate: now.addingTimeInterval(-60),
            minimumInterval: interval,
            now: now))
        // Never finished: still waits after an attempt.
        XCTAssertFalse(PlexSessionManager.isSyncDue(
            lastSyncDate: nil, lastAttemptDate: now.addingTimeInterval(-60), minimumInterval: interval, now: now))
        XCTAssertTrue(PlexSessionManager.isSyncDue(
            lastSyncDate: nil, lastAttemptDate: now.addingTimeInterval(-interval), minimumInterval: interval, now: now))
    }

    func testStreamListWaitStaysShort() {
        XCTAssertLessThanOrEqual(PlexSessionManager.streamListSyncWait, 2)
        XCTAssertLessThan(PlexSessionManager.streamListAutoSyncInterval, PlexSessionManager.foregroundAutoSyncInterval)
    }
}
