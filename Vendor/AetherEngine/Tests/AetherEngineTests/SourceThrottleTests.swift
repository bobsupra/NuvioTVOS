import XCTest
@testable import AetherEngine

final class SourceThrottleTests: XCTestCase {

    func testCostNsDisabledOrEmpty() {
        XCTAssertEqual(SourceThrottle.costNs(bytes: 125_000, kbps: 0), 0)
        XCTAssertEqual(SourceThrottle.costNs(bytes: 0, kbps: 1000), 0)
    }

    func testCostNs1000kbpsDelivers125kBPerSecond() {
        // 1000 kbit/s = 125000 byte/s, so 125000 bytes should cost exactly 1 second.
        XCTAssertEqual(SourceThrottle.costNs(bytes: 125_000, kbps: 1000), 1_000_000_000)
        // Half the bytes -> half the time.
        XCTAssertEqual(SourceThrottle.costNs(bytes: 62_500, kbps: 1000), 500_000_000)
    }

    func testCostNsScalesInverselyWithRate() {
        // Same payload at 2x the rate costs half the time.
        let slow = SourceThrottle.costNs(bytes: 1_000_000, kbps: 1000)
        let fast = SourceThrottle.costNs(bytes: 1_000_000, kbps: 2000)
        XCTAssertEqual(fast, slow / 2)
    }

    func testAdvanceSteadyStateSleepsOneChunkCost() {
        // Caught up (vclock == now): a 125 kB chunk at 1000 kbps must sleep ~1s.
        var vclock: UInt64 = 1_000_000_000
        let sleep = SourceThrottle.advance(
            vclockNs: &vclock, nowNs: 1_000_000_000, deliveredBytes: 125_000, kbps: 1000)
        XCTAssertEqual(sleep, 1_000_000_000)
        XCTAssertEqual(vclock, 2_000_000_000)   // virtual clock advanced by the chunk cost
    }

    func testAdvanceBacklogAccumulates() {
        // Two back-to-back chunks at the same `now` (producer reading fast): the second must wait
        // behind the first's virtual deadline, not deliver immediately.
        var vclock: UInt64 = 0
        let now: UInt64 = 0
        let s1 = SourceThrottle.advance(vclockNs: &vclock, nowNs: now, deliveredBytes: 125_000, kbps: 1000)
        let s2 = SourceThrottle.advance(vclockNs: &vclock, nowNs: now, deliveredBytes: 125_000, kbps: 1000)
        XCTAssertEqual(s1, 1_000_000_000)
        XCTAssertEqual(s2, 2_000_000_000)       // queued behind chunk 1
        XCTAssertEqual(vclock, 2_000_000_000)
    }

    func testAdvanceIdleGapDoesNotBankCredit() {
        // After delivering one chunk (vclock at 1s), a long real gap (now jumps to 10s) must not let
        // the next chunk deliver "for free" or bank negative sleep; base resets to now.
        var vclock: UInt64 = 1_000_000_000
        let sleep = SourceThrottle.advance(
            vclockNs: &vclock, nowNs: 10_000_000_000, deliveredBytes: 125_000, kbps: 1000)
        XCTAssertEqual(sleep, 1_000_000_000)            // just one chunk cost, no burst credit
        XCTAssertEqual(vclock, 11_000_000_000)          // rebased to now + cost
    }

    func testAdvanceDisabledReturnsZero() {
        var vclock: UInt64 = 0
        XCTAssertEqual(
            SourceThrottle.advance(vclockNs: &vclock, nowNs: 0, deliveredBytes: 125_000, kbps: 0), 0)
        XCTAssertEqual(vclock, 0)
    }
}
