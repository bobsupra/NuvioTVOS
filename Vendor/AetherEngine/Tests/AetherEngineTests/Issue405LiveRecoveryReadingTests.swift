import XCTest
@testable import AetherEngine

/// #405 (Syravo device trace, tvOS 26.6): a live MPEG-TS channel behind a one-slot Xtream host
/// froze twice in a minute. The origin caused both freezes; what the trace showed is where the
/// engine's READING of the situation differed from what the origin did, and cost ~12 s and eleven
/// replayed seconds of recovery. This file covers the pure decisions behind those readings.
final class Issue405LiveRecoveryReadingTests: XCTestCase {

    // MARK: - Stage 2 asks the producer (#405 finding 4)

    /// The incident: with the source re-resolving and no bytes arriving, stage 2 reloaded the
    /// unchanged local playlist. AVPlayer rejoined a FROZEN playlist at edge-minus-holdback, 5 s
    /// behind the frozen position, replayed seg-18..21 and parked again, and only two grace windows
    /// later did the final rung ask the host to retune.
    func testNoSegmentSinceTheStallIsAStarvedProducer() {
        XCTAssertTrue(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: 21, segmentsNow: 21),
            "the field case: the producer finalized nothing while the consumer sat silent, so a fresh consumer item has the same frozen tail to work with")
    }

    /// The shape stage 2 exists for: the producer kept finalizing segments, so the playlist grew
    /// and it is the consumer that died on it. A fresh AVPlayerItem is exactly right there.
    func testASegmentFinalizedSinceTheStallKeepsStageTwo() {
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: 21, segmentsNow: 22))
    }

    /// Regression guard: a remote HLS session has no local producer at all, AVPlayer fetches the
    /// origin itself. Reading that absence as "no progress" would turn every live stall on that
    /// route into an immediate retune and skip the stage that recovers it.
    func testNoLocalProducerIsNotStarvation() {
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: nil, segmentsNow: nil),
            "absence of a producer to ask is not an answer from one")
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: true, segmentsAtStall: nil, segmentsNow: 4),
            "no baseline to compare against; stage 2 keeps its old behaviour")
    }

    /// VOD has no retune to fall back on: liveSourceReset is a live-only escalation.
    func testVODNeverReadsAsStarved() {
        XCTAssertFalse(
            AetherEngine.liveProducerIsStarved(
                isLive: false, segmentsAtStall: 10, segmentsNow: 10))
    }

    // MARK: - A wrap-corrected restart is a source restart (#405 finding 2)

    private static let tb90k = 1.0 / 90_000.0

    /// The field numbers, verbatim from the trace: the origin restarted its stream from its ring
    /// buffer with raw dts back at zero, FFmpeg's 33-bit wrap correction turned that into exactly
    /// 2^33, and the producer absorbed it as a programme boundary. seg-15..19 came out
    /// byte-identical in size to seg-6..10 and the viewer watched eleven seconds twice.
    func testTheFieldTraceClassifiesAsAnAxisReset() {
        XCTAssertEqual(
            HLSSegmentProducer.sourceRestartShape(
                newDts: 8_589_934_592,          // 2^33 exactly: raw dts 0, wrap-corrected
                jumpTicks: 8_487_014_192,
                firstSeenDts: 100_915_200,      // this session joined 1121 s into the origin's axis
                tbSeconds: Self.tb90k,
                isLive: true),
            .axisReset)
    }

    /// Why the anchor cannot be `firstSeenDts` for this shape: in the same trace the session had
    /// joined 1121 s into the origin's ring (oldShift=100915200), while the restart lands at zero.
    /// Testing the wrap-corrected value against firstSeenDts would put those 1121 s apart and miss
    /// the case that motivated the check.
    func testAxisResetIsAnchoredAtZeroNotAtTheJoinPoint() {
        let joinedFarIntoTheRing: Int64 = 100_915_200
        let window = Int64(10.0 / Self.tb90k)
        XCTAssertGreaterThan(
            joinedFarIntoTheRing, window,
            "the premise: this session's join point is far outside any start window, so an anchor on it cannot see a restart at zero")
        XCTAssertEqual(
            HLSSegmentProducer.sourceRestartShape(
                newDts: 8_589_934_592, jumpTicks: 8_487_014_192,
                firstSeenDts: joinedFarIntoTheRing, tbSeconds: Self.tb90k, isLive: true),
            .axisReset)
    }

    /// The shape that was already handled stays handled, unchanged.
    func testBackwardRewindStillClassifies() {
        XCTAssertEqual(
            HLSSegmentProducer.sourceRestartShape(
                newDts: 90_000, jumpTicks: -1_800_000,
                firstSeenDts: 0, tbSeconds: Self.tb90k, isLive: true),
            .rewind)
    }

    func testBackwardJumpThatDoesNotLandNearTheJoinIsNotARestart() {
        XCTAssertNil(
            HLSSegmentProducer.sourceRestartShape(
                newDts: 50_000_000, jumpTicks: -1_800_000,
                firstSeenDts: 0, tbSeconds: Self.tb90k, isLive: true),
            "a backward jump into the middle of the axis is a programme boundary, not a replay")
    }

    /// An ordinary forward programme boundary (an hour of PCR, no wrap) must stay a boundary.
    func testForwardProgrammeBoundaryIsNotARestart() {
        XCTAssertNil(
            HLSSegmentProducer.sourceRestartShape(
                newDts: 324_000_000, jumpTicks: 5_400_000,
                firstSeenDts: 100_915_200, tbSeconds: Self.tb90k, isLive: true))
    }

    /// Past the wrap but well into the axis: a genuine 33-bit wrap after ~26.5 h keeps counting
    /// where it left off, so nothing near the start of the axis means nothing restarted.
    func testWrapCorrectedValueDeepIntoTheAxisIsNotARestart() {
        XCTAssertNil(
            HLSSegmentProducer.sourceRestartShape(
                newDts: 8_589_934_592 + 1_800_000,   // 20 s past the axis start, window is 10 s
                jumpTicks: 8_487_014_192,
                firstSeenDts: 100_915_200, tbSeconds: Self.tb90k, isLive: true))
    }

    /// #368: a sequential origin's archive chunks legitimately open their own axis at zero. Reading
    /// that as a replay would end a healthy pump, so the axis reset is live-only.
    func testSequentialOriginChunkSeamIsNotARestart() {
        XCTAssertNil(
            HLSSegmentProducer.sourceRestartShape(
                newDts: 8_589_934_592, jumpTicks: 8_487_014_192,
                firstSeenDts: 100_915_200, tbSeconds: Self.tb90k, isLive: false))
    }
}
