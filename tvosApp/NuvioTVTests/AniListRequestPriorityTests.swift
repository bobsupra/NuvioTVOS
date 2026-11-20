import XCTest
@testable import NuvioTV

/// AniList's rate limit: what the viewer waits on goes first, background work leaves it room.
final class AniListRequestPriorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBackgroundWorkLeavesSlotsForTheViewer() {
        // 17 sent in the last half minute, as Home rows and lists do after a start.
        let sent = (0..<17).map { now.addingTimeInterval(Double($0) - 30) }
        XCTAssertEqual(
            AniListClient.slotTime(sent: sent, now: now, limit: AniListClient.requestsPerMinute),
            now,
            "a search goes at once"
        )
        XCTAssertEqual(
            AniListClient.slotTime(sent: sent, now: now, limit: AniListClient.backgroundPerMinute),
            sent[0].addingTimeInterval(60),
            "the next row waits for the oldest to leave the minute"
        )
    }

    func testTheViewerWaitsOnlyWhenTheWholeMinuteIsUsed() {
        let sent = (0..<25).map { now.addingTimeInterval(Double($0) - 50) }
        XCTAssertEqual(AniListClient.slotTime(sent: sent, now: now, limit: 25), sent[0].addingTimeInterval(60))
        XCTAssertEqual(AniListClient.slotTime(sent: sent, now: now, limit: 17), sent[8].addingTimeInterval(60))
        XCTAssertEqual(AniListClient.slotTime(sent: [], now: now, limit: 17), now)
    }

    func testTheViewersLaneIsSetAroundTheRequest() {
        XCTAssertFalse(AniListClient.isInteractive, "background by default")
        let inside = AniListClient.$isInteractive.withValue(true) { AniListClient.isInteractive }
        XCTAssertTrue(inside)
        XCTAssertFalse(AniListClient.isInteractive)
        XCTAssertLessThan(AniListClient.backgroundPerMinute, AniListClient.requestsPerMinute)
    }
}
