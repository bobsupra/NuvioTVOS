import XCTest
@testable import NuvioTV

final class SidebarClockFormatTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testUnknownStoredValueFallsBackToAutomatic() {
        XCTAssertEqual(SidebarClockFormat.fromStored("unknown"), .automatic)
        XCTAssertEqual(SidebarClockFormat.fromStored("12 hours"), .twelveHour)
        XCTAssertEqual(SidebarClockFormat.fromStored("24 hours"), .twentyFourHour)
    }

    func testMidnightUsesTwelveAMAndZeroHour() {
        let value = date("2026-10-17T00:05:00Z")
        XCTAssertEqual(SidebarClockFormat.twelveHour.formatter(timeZone: utc).string(from: value), "12:05 AM")
        XCTAssertEqual(SidebarClockFormat.twentyFourHour.formatter(timeZone: utc).string(from: value), "00:05")
    }

    func testNoonUsesTwelvePMAndTwelveHour() {
        let value = date("2026-10-17T12:05:00Z")
        XCTAssertEqual(SidebarClockFormat.twelveHour.formatter(timeZone: utc).string(from: value), "12:05 PM")
        XCTAssertEqual(SidebarClockFormat.twentyFourHour.formatter(timeZone: utc).string(from: value), "12:05")
    }

    func testExplicitHourCycleDoesNotFollowTheSuppliedLocale() {
        let value = date("2026-10-17T17:05:00Z")
        let twelve = SidebarClockFormat.twelveHour.formatter(locale: Locale(identifier: "en_GB"), timeZone: utc)
        let twentyFour = SidebarClockFormat.twentyFourHour.formatter(locale: Locale(identifier: "en_US"), timeZone: utc)
        XCTAssertEqual(twelve.string(from: value), "5:05 PM")
        XCTAssertEqual(twentyFour.string(from: value), "17:05")
    }

    func testTimeZoneUsesSummerAndWinterOffsets() {
        let formatter = SidebarClockFormat.twentyFourHour.formatter(timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(formatter.string(from: date("2026-10-17T21:05:00Z")), "17:05")
        XCTAssertEqual(formatter.string(from: date("2026-01-17T21:05:00Z")), "16:05")
    }

    func testUpdatesAlignToMinuteBoundaries() {
        XCTAssertEqual(SidebarClockFormat.secondsUntilNextMinute(after: Date(timeIntervalSince1970: 0)), 60)
        XCTAssertEqual(SidebarClockFormat.secondsUntilNextMinute(after: Date(timeIntervalSince1970: 61)), 59)
        XCTAssertEqual(SidebarClockFormat.secondsUntilNextMinute(after: Date(timeIntervalSince1970: 119.5)), 0.5)
        XCTAssertEqual(SidebarClockFormat.secondsUntilNextMinute(after: Date(timeIntervalSince1970: -0.5)), 0.5)
    }
}
