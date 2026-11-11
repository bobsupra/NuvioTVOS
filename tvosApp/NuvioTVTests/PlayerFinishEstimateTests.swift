import XCTest
@testable import NuvioTV

final class PlayerFinishEstimateTests: XCTestCase {
    func testEstimateUsesRemainingDurationAndPlaybackSpeed() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(PlayerFinishEstimate.date(now: now, position: 600, duration: 4_200, speed: 1), now.addingTimeInterval(3_600))
        XCTAssertEqual(PlayerFinishEstimate.date(now: now, position: 600, duration: 4_200, speed: 2), now.addingTimeInterval(1_800))
    }

    func testEstimateRejectsUnknownOrInvalidTimes() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(PlayerFinishEstimate.date(now: now, position: 0, duration: 0, speed: 1))
        XCTAssertNil(PlayerFinishEstimate.date(now: now, position: .nan, duration: 60, speed: 1))
        XCTAssertNil(PlayerFinishEstimate.date(now: now, position: 0, duration: 60, speed: 0))
        XCTAssertEqual(PlayerFinishEstimate.date(now: now, position: 80, duration: 60, speed: 1), now)
    }
}
