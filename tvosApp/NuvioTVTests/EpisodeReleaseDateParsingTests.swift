import XCTest
@testable import NuvioTV

/// The hand-written reader for addon air dates gives what the system's date formatters give.
final class EpisodeReleaseDateParsingTests: XCTestCase {
    private func iso(_ value: String, fractional: Bool) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }

    func testTimestampsMatchTheSystemFormatters() throws {
        for value in ["2008-01-20T19:00:00Z", "1999-12-31T23:59:59Z", "2024-02-29T05:06:07Z", "1970-01-01T00:00:00Z"] {
            let expected = try XCTUnwrap(iso(value, fractional: false), value)
            XCTAssertEqual(EpisodeReleasePolicy.fastUTCDate(value), expected, value)
        }
        for value in ["2008-01-20T19:00:00.000Z", "2026-11-11T20:34:05.250Z", "2001-03-01T00:00:00.5Z"] {
            let expected = try XCTUnwrap(iso(value, fractional: true), value)
            let parsed = try XCTUnwrap(EpisodeReleasePolicy.fastUTCDate(value), value)
            XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0005, value)
        }
    }

    func testADayAloneIsMidnightUTC() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2015, month: 7, day: 4)))
        XCTAssertEqual(EpisodeReleasePolicy.fastUTCDate("2015-07-04"), expected)
    }

    func testOtherShapesAreLeftToTheFormatters() {
        XCTAssertNil(EpisodeReleasePolicy.fastUTCDate("2008-01-20T19:00:00+02:00"))
        XCTAssertNil(EpisodeReleasePolicy.fastUTCDate("2008-01-20 19:00"))
        XCTAssertNil(EpisodeReleasePolicy.fastUTCDate("2008-1-20"))
        XCTAssertNil(EpisodeReleasePolicy.fastUTCDate("2008-13-01"))
        XCTAssertNil(EpisodeReleasePolicy.fastUTCDate("2008-01-20T19:00:00.Z"))
        XCTAssertNil(EpisodeReleasePolicy.fastUTCDate("TBA"))
    }

    func testReleaseDateStillReadsOffsets() throws {
        let expected = try XCTUnwrap(iso("2008-01-20T17:00:00Z", fractional: false))
        XCTAssertEqual(EpisodeReleasePolicy.releaseDate(for: "2008-01-20T19:00:00+02:00"), expected)
    }
}
