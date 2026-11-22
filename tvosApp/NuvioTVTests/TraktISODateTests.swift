import XCTest
@testable import NuvioTV

final class TraktISODateTests: XCTestCase {
    func testParsesWithAndWithoutFractionalSeconds() {
        XCTAssertEqual(TraktISODate.parse("2026-11-20T04:15:46.000Z")?.timeIntervalSince1970, 1_795_148_146)
        XCTAssertEqual(TraktISODate.parse("2026-11-20T04:15:46Z")?.timeIntervalSince1970, 1_795_148_146)
        XCTAssertEqual(TraktISODate.parse("2026-11-20T04:15:46.250Z")!.timeIntervalSince1970, 1_795_148_146.25, accuracy: 0.001)
    }

    func testRejectsEmptyAndMalformed() {
        XCTAssertNil(TraktISODate.parse(nil))
        XCTAssertNil(TraktISODate.parse(""))
        XCTAssertNil(TraktISODate.parse("not a date"))
    }

    func testSafeFromManyThreads() {
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            XCTAssertNotNil(TraktISODate.parse("2026-11-\(String(format: "%02d", i % 28 + 1))T10:00:00.000Z"))
        }
    }
}
