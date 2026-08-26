import XCTest
@testable import AetherEngine

/// #368: the timeline-rebase math shared by live program boundaries and sequential chunk seams.
/// The wrap case pins the exact device trace of the field failure: an IPTV timeshift archive whose
/// chunk restarts near PTS 0, which libavformat's 33-bit wrap correction turns into a +2^33 leap.
final class TimelineRebaseMathTests: XCTestCase {

    func testChunkSeamWrapContinuesOneFramePastLastOutput() {
        // Device trace: seam-preceding dts 363524400, seam packet wrap-corrected to exactly 2^33
        // (movenc rejected the inferred duration 8226410192; 363524400 + 8226410192 = 2^33).
        let lastSrcDts: Int64 = 363_524_400
        let srcDts: Int64 = 8_589_934_592
        XCTAssertEqual(srcDts - lastSrcDts, 8_226_410_192)
        XCTAssertEqual(srcDts, Int64(1) << 33)

        let (newShift, continuationDts) = HLSSegmentProducer.rebasedVideoShift(
            srcDts: srcDts,
            lastSrcDts: lastSrcDts,
            oldShift: 363_049_200,        // trace: video gate open shift
            fallbackDurationPts: 1800     // 50 fps in 1/90000
        )
        // Output continuity: the seam packet lands exactly one frame past the last output dts.
        let lastOutputDts: Int64 = 363_524_400 - 363_049_200
        XCTAssertEqual(continuationDts, lastOutputDts + 1800)
        XCTAssertEqual(srcDts - newShift, continuationDts)
    }

    func testBackwardChunkRestartContinuesForward() {
        // The SW-host precedent trace: an 89 s chunk ends at raw 2717.9 s, the next starts at 0.04 s.
        let (newShift, continuationDts) = HLSSegmentProducer.rebasedVideoShift(
            srcDts: 3600,                 // 0.04 s @ 90 kHz
            lastSrcDts: 244_611_000,      // 2717.9 s
            oldShift: 100_000,
            fallbackDurationPts: 1800
        )
        XCTAssertEqual(continuationDts, (244_611_000 - 100_000) + 1800)
        XCTAssertEqual(3600 - newShift, continuationDts)   // output keeps moving forward
        XCTAssertLessThan(newShift, 0)                     // backward seam => negative shift
    }

    func testLiveScaleJumpMatchesLegacyInlineMath() {
        // A +30 s SSAI-scale jump: pins that the extraction changed nothing for live sessions.
        let (newShift, continuationDts) = HLSSegmentProducer.rebasedVideoShift(
            srcDts: 92_700_000,
            lastSrcDts: 90_000_000,
            oldShift: 0,
            fallbackDurationPts: 1800
        )
        XCTAssertEqual(continuationDts, 90_001_800)
        XCTAssertEqual(newShift, 92_700_000 - 90_001_800)
    }

    func testZeroFallbackStillAdvancesOneTick() {
        let (newShift, continuationDts) = HLSSegmentProducer.rebasedVideoShift(
            srcDts: 500,
            lastSrcDts: 100,
            oldShift: 0,
            fallbackDurationPts: 0
        )
        XCTAssertEqual(continuationDts, 101)
        XCTAssertEqual(500 - newShift, 101)
    }
}
