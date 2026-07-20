// Tests/AetherEngineTests/SSAIAudioRebaseTests.swift
//
// Guards HLSSegmentProducer.seamDerivedAudioShift across SSAI boundaries. Pluto amux ad creatives
// use a different source clock for audio vs video (audio restarts near 2^33, video at 0); copying the
// video shift verbatim offsets audio ~26 h into the future. Values from the device freeze log.
import XCTest
@testable import AetherEngine

final class SSAIAudioRebaseTests: XCTestCase {

    private let ptsModulus: Int64 = 8_589_934_592 // 2^33, MPEG-TS wrap

    private func audioOutput(srcDts: Int64, shift: Int64) -> Int64 {
        srcDts - shift
    }

    // Bumper -> amux ad creative: video seam at 15_675_000 (90 kHz), audio boundary at 2^33.
    func testAmuxAdAudioLandsOnVideoSeamDespiteDifferentBase() {
        let videoSeamOut: Int64 = 15_675_000
        let audioBoundarySrcDts = ptsModulus // 8_589_934_592, the amux base

        let shift = HLSSegmentProducer.seamDerivedAudioShift(
            audioBoundarySrcDts: audioBoundarySrcDts,
            seamOutAudioTb: videoSeamOut
        )
        let out = audioOutput(srcDts: audioBoundarySrcDts, shift: shift)

        XCTAssertEqual(out, videoSeamOut)
    }

    // Regression: copying video shift verbatim (-15_675_000) offset audio ~2^33 ticks ahead, hanging the renderer.
    func testCopyingVideoShiftVerbatimWouldHangAudio() {
        let videoShift: Int64 = -15_675_000 // from the device log
        let audioBoundarySrcDts = ptsModulus

        let brokenOut = audioOutput(srcDts: audioBoundarySrcDts, shift: videoShift)

        // ~8.6 billion ticks (~26.5 h at 90 kHz) ahead: the hang.
        XCTAssertGreaterThan(brokenOut, ptsModulus)
        let fixedShift = HLSSegmentProducer.seamDerivedAudioShift(
            audioBoundarySrcDts: audioBoundarySrcDts,
            seamOutAudioTb: 15_675_000
        )
        let fixedOut = audioOutput(srcDts: audioBoundarySrcDts, shift: fixedShift)
        XCTAssertLessThan(abs(fixedOut - 15_675_000), 90_000) // within 1 s
    }

    // Shared-base case (content -> bumper, both at 2^33): fix must reproduce legacy result. Log: srcDts 8_590_024_592, seam 15_231_000, old shift 8_574_793_592.
    func testSharedBaseMatchesLegacyShift() {
        let audioBoundarySrcDts: Int64 = 8_590_024_592
        let videoSeamOut: Int64 = 15_231_000

        let shift = HLSSegmentProducer.seamDerivedAudioShift(
            audioBoundarySrcDts: audioBoundarySrcDts,
            seamOutAudioTb: videoSeamOut
        )
        XCTAssertEqual(shift, 8_574_793_592)
        XCTAssertEqual(audioOutput(srcDts: audioBoundarySrcDts, shift: shift), videoSeamOut)
    }
}
