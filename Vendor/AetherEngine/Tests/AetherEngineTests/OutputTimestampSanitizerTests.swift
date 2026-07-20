import XCTest
@testable import AetherEngine

final class OutputTimestampSanitizerTests: XCTestCase {

    // MARK: - Healthy content is untouched

    func testMonotonicAudioPassThroughUnchanged() {
        var s = OutputTimestampSanitizer()
        for i in 0..<5 {
            let t = Int64(1000 + i * 1024)
            let out = s.sanitize(streamIndex: 1, pts: t, dts: t)
            XCTAssertEqual(out.dts, t)
            XCTAssertEqual(out.pts, t)
        }
    }

    func testVideoBFramePtsAboveDtsPreserved() {
        var s = OutputTimestampSanitizer()
        let out = s.sanitize(streamIndex: 0, pts: 2000, dts: 1000)
        XCTAssertEqual(out.dts, 1000)
        XCTAssertEqual(out.pts, 2000)
    }

    // MARK: - The SSAI ad-boundary failure (exact device-log values)

    func testAudioPtsBelowDtsIsLiftedToDts() {
        // Device log (Beverly Hills 90210 Pluto ad boundary):
        //   pts (6391809) < dts (6679426) in stream 1
        // Audio carries no reordering, so the fix is pts := dts.
        var s = OutputTimestampSanitizer()
        _ = s.sanitize(streamIndex: 1, pts: 6679425, dts: 6679425) // prior packet
        let out = s.sanitize(streamIndex: 1, pts: 6391809, dts: 6679426)
        XCTAssertEqual(out.dts, 6679426)
        XCTAssertEqual(out.pts, 6679426, "audio pts must be lifted to dts (no reordering)")
        XCTAssertGreaterThanOrEqual(out.pts, out.dts)
    }

    func testEqualDtsCollisionIsBumped() {
        // Device log: "non monotonically increasing dts ... 6679425 >= 6679425"
        var s = OutputTimestampSanitizer()
        _ = s.sanitize(streamIndex: 1, pts: 6679425, dts: 6679425)
        let out = s.sanitize(streamIndex: 1, pts: 6679425, dts: 6679425)
        XCTAssertEqual(out.dts, 6679426, "colliding dts must be bumped past the last written")
        XCTAssertEqual(out.pts, 6679426)
    }

    func testBackwardDtsResetIsForcedMonotonic() {
        // SSAI creative restarts source clock at 2^33; rescaled dts can land far below the last written value.
        var s = OutputTimestampSanitizer()
        _ = s.sanitize(streamIndex: 1, pts: 10_000, dts: 10_000)
        let out = s.sanitize(streamIndex: 1, pts: 2_000, dts: 2_000)
        XCTAssertEqual(out.dts, 10_001)
        XCTAssertEqual(out.pts, 10_001)
    }

    func testWholeAdBurstStaysMonotonicAndPtsGEDts() {
        // Replays the Beverly Hills 90210 / Pluto stall shape: dts collides/regresses, pts trails dts; both pathologies at once.
        var s = OutputTimestampSanitizer()
        _ = s.sanitize(streamIndex: 1, pts: 6679425, dts: 6679425)
        var lastDts = Int64.min
        for i in 0..<200 {
            let pts = Int64(6391809 + i * 1024)
            let dts = Int64(6679425) // constant, colliding
            let out = s.sanitize(streamIndex: 1, pts: pts, dts: dts)
            XCTAssertGreaterThan(out.dts, lastDts, "dts must strictly increase")
            XCTAssertGreaterThanOrEqual(out.pts, out.dts, "pts must be >= dts")
            lastDts = out.dts
        }
    }

    // MARK: - Per-stream independence

    func testStreamsTrackedIndependently() {
        var s = OutputTimestampSanitizer()
        let a = s.sanitize(streamIndex: 1, pts: 5000, dts: 5000)
        let v = s.sanitize(streamIndex: 0, pts: 100, dts: 100)
        XCTAssertEqual(a.dts, 5000)
        XCTAssertEqual(v.dts, 100, "video stream is independent of audio's high-water mark")
    }

    func testNoptsDtsPassedThrough() {
        var s = OutputTimestampSanitizer()
        let out = s.sanitize(streamIndex: 0, pts: 123, dts: Int64.min)
        XCTAssertEqual(out.dts, Int64.min)
        XCTAssertEqual(out.pts, 123)
    }
}
