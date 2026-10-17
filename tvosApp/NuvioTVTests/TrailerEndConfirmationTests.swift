import XCTest
@testable import NuvioTV

final class TrailerEndConfirmationTests: XCTestCase {
    private func observe(
        _ probe: inout TrailerEndConfirmation,
        at uptime: TimeInterval,
        isTrailer: Bool = true, usesMPV: Bool = true,
        eof: Bool = true, stable: Bool = true,
        position: Double = 119.98, duration: Double = 120,
        generation: UInt64 = 1
    ) -> Bool {
        probe.observe(
            isTrailer: isTrailer, usesMPV: usesMPV,
            reachedEOF: eof, isStable: stable,
            position: position, duration: duration,
            loadGeneration: generation, uptime: uptime
        )
    }

    func testStableTrailerEOFConfirmsAfterTheSettlingWindow() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10))
        XCTAssertFalse(observe(&probe, at: 10.25))
        XCTAssertTrue(observe(&probe, at: 10.5))
    }

    func testPausedNearEndWithoutEOFNeverCompletes() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10, eof: false))
        XCTAssertFalse(observe(&probe, at: 10.5, eof: false))
        XCTAssertFalse(observe(&probe, at: 11, eof: false))
    }

    func testNormalContentAndOtherBackendsAreExcluded() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10, isTrailer: false))
        XCTAssertFalse(observe(&probe, at: 10.5, isTrailer: false))
        XCTAssertFalse(observe(&probe, at: 11, usesMPV: false))
        XCTAssertFalse(observe(&probe, at: 11.5, usesMPV: false))
    }

    func testTransientEOFOrUnstablePlaybackRestartsConfirmation() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10))
        XCTAssertFalse(observe(&probe, at: 10.25, stable: false))
        XCTAssertFalse(observe(&probe, at: 10.5))
        XCTAssertFalse(observe(&probe, at: 10.75))
        XCTAssertTrue(observe(&probe, at: 11))
        XCTAssertFalse(observe(&probe, at: 11.25, eof: false))
        XCTAssertFalse(observe(&probe, at: 11.5))
    }

    func testEarlyEOFAndInvalidClocksNeverComplete() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10, position: 30))
        XCTAssertFalse(observe(&probe, at: 10.5, position: 30))
        XCTAssertFalse(observe(&probe, at: 11, position: .nan))
        XCTAssertFalse(observe(&probe, at: 11.5, duration: .infinity))
        XCTAssertFalse(observe(&probe, at: 12, position: 0, duration: 0))
        XCTAssertFalse(observe(&probe, at: 12.5, position: 125))
    }

    func testNewLoadCannotInheritThePreviousTrailerEOF() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10, generation: 1))
        XCTAssertFalse(observe(&probe, at: 10.5, generation: 2))
        XCTAssertFalse(observe(&probe, at: 10.75, generation: 2))
        XCTAssertTrue(observe(&probe, at: 11, generation: 2))
    }

    func testPollingGapRequiresFreshConfirmation() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10))
        XCTAssertFalse(observe(&probe, at: 20))
        XCTAssertFalse(observe(&probe, at: 20.25))
        XCTAssertTrue(observe(&probe, at: 20.5))
    }

    func testExplicitResetDiscardsThePendingEOF() {
        var probe = TrailerEndConfirmation()
        XCTAssertFalse(observe(&probe, at: 10))
        probe.reset()
        XCTAssertFalse(observe(&probe, at: 10.5))
        XCTAssertFalse(observe(&probe, at: 10.75))
        XCTAssertTrue(observe(&probe, at: 11))
    }
}
