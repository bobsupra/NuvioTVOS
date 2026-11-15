import XCTest
@testable import NuvioTV

final class IPTVGuideRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func programme(endingIn hours: Double) -> IPTVProgramme {
        IPTVProgramme(channelID: "c", title: "Show", start: now, end: now.addingTimeInterval(hours * 3600))
    }
    private func hours(_ date: Date) -> Double { date.timeIntervalSince(now) / 3600 }

    func testRefreshesAWhileBeforeTheSuppliedScheduleRunsOut() {
        // A provider that only supplies 6 hours ahead: refresh 2 h before they run out.
        XCTAssertEqual(hours(IPTVGuideRefreshPolicy.nextRefresh(after: [programme(endingIn: 6)], loadedAt: now)), 4, accuracy: 0.001)
    }

    func testALongScheduleIsStillRefreshedWithinTheMaximumAge() {
        let next = IPTVGuideRefreshPolicy.nextRefresh(after: [programme(endingIn: 200)], loadedAt: now)
        XCTAssertEqual(hours(next), 12, accuracy: 0.001)
    }

    func testNeverRefreshesSoonerThanTheMinimumInterval() {
        // Almost nothing ahead, or nothing at all: still not fetched again for 30 minutes.
        XCTAssertEqual(hours(IPTVGuideRefreshPolicy.nextRefresh(after: [programme(endingIn: 0.5)], loadedAt: now)), 0.5, accuracy: 0.001)
        XCTAssertEqual(hours(IPTVGuideRefreshPolicy.nextRefresh(after: [], loadedAt: now)), 0.5, accuracy: 0.001)
    }

    func testTheLoadedWindowBoundsTheSchedule() {
        // Programmes beyond the 48 h window were never loaded.
        let next = IPTVGuideRefreshPolicy.nextRefresh(after: [programme(endingIn: 60)], loadedAt: now)
        XCTAssertEqual(hours(next), 12, accuracy: 0.001)
        let window = IPTVGuideRefreshPolicy.window(around: now)
        XCTAssertEqual(hours(window.lowerBound), -6, accuracy: 0.001)
        XCTAssertEqual(hours(window.upperBound), 48, accuracy: 0.001)
    }

    func testFailuresBackOffAndAreCapped() {
        let minutes = (1...8).map { IPTVGuideRefreshPolicy.retry(afterFailures: $0, at: now).timeIntervalSince(now) / 60 }
        XCTAssertEqual(minutes, [2, 5, 15, 30, 60, 60, 60, 60])
        XCTAssertEqual(IPTVGuideRefreshPolicy.retry(afterFailures: 0, at: now).timeIntervalSince(now) / 60, 2)
    }

    func testTheMinuteClockIsNeverAFetchEveryMinute() {
        // The shortest wait between any two fetches is the first retry, two minutes.
        let shortest = min(IPTVGuideRefreshPolicy.minInterval, IPTVGuideRefreshPolicy.retryDelays.min()!)
        XCTAssertGreaterThanOrEqual(shortest, 120)
    }
}
