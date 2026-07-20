import XCTest
@testable import AetherEngine

/// AE#105: a multi-clip Blu-ray title concatenates m2ts clips that each carry their own STC, so the raw
/// source PTS leaps at every clip boundary. The demuxer folds each clip onto one contiguous presentation
/// timeline by subtracting a per-clip offset, attributing packets to clips by byte position. These cover
/// the pure pieces of that transform (the end-to-end packet rewrite is device-verified on the real disc).
final class Issue105MultiClipTimelineTests: XCTestCase {

    // MARK: - Byte-position -> clip attribution (ClipSpan.index)

    private func span(_ byteStart: Int64, cumBefore: Double = 0, predicted: Double = 0) -> ClipSpan {
        ClipSpan(concatByteStart: byteStart, cumulativeBeforeSec: cumBefore, predictedShiftSec: predicted)
    }

    func test_indexAttributesByByteBoundary() {
        let spans = [span(0), span(1_000), span(2_000)]
        XCTAssertEqual(ClipSpan.index(forPos: 0, in: spans, fallback: 0), 0)
        XCTAssertEqual(ClipSpan.index(forPos: 999, in: spans, fallback: 0), 0)
        XCTAssertEqual(ClipSpan.index(forPos: 1_000, in: spans, fallback: 0), 1)   // boundary belongs to the new clip
        XCTAssertEqual(ClipSpan.index(forPos: 1_500, in: spans, fallback: 0), 1)
        XCTAssertEqual(ClipSpan.index(forPos: 2_000, in: spans, fallback: 0), 2)
        XCTAssertEqual(ClipSpan.index(forPos: 9_999, in: spans, fallback: 0), 2)
    }

    func test_indexNegativePosUsesFallback() {
        // A packet / index entry that reports no byte position keeps the last clip (reads are sequential).
        let spans = [span(0), span(1_000)]
        XCTAssertEqual(ClipSpan.index(forPos: -1, in: spans, fallback: 1), 1)
        XCTAssertEqual(ClipSpan.index(forPos: -1, in: spans, fallback: 9), 1)   // clamped into range
    }

    func test_indexEmptyReturnsFallback() {
        XCTAssertEqual(ClipSpan.index(forPos: 500, in: [], fallback: 3), 3)
    }

    // MARK: - Observed fold offset

    /// The demuxer resolves each later clip's fold offset from its OBSERVED raw base (as unwrapped by
    /// FFmpeg), clip 0's observed base, and the small MPLS presentation duration. Replicates that and asserts
    /// clip 1 is pulled back to continue right where clip 0 ended instead of leaping to ~96043s.
    func test_observedFoldYieldsContiguousTimeline() {
        // Real disc geometry from the #105 log: clip 0 raw base 4199.9s, clip 1 raw base 96043s (already
        // >2^33 ticks, i.e. FFmpeg-unwrapped past the 33-bit PTS wrap), clip 0 presentation duration ~40s.
        let base0 = 4_199.917, clip1ObservedBase = 96_043.0, clip0DurationSec = 40.083
        let shift = ClipFold.offsetSeconds(observedBaseSec: clip1ObservedBase, base0Sec: base0,
                                           cumulativeBeforeSec: clip0DurationSec)

        // Folded clip 1 base = raw base - shift, must equal base0 + clip0 duration (contiguous), not 96043s.
        let clip1FoldedBase = clip1ObservedBase - shift
        XCTAssertEqual(clip1FoldedBase, base0 + clip0DurationSec, accuracy: 0.01)
        XCTAssertEqual(shift, 91_803.0, accuracy: 0.1)
    }

    /// Root cause: the old fold predicted the offset from the MPLS `inTime` field, a 32-bit 45 kHz value that
    /// wraps at ~95443s. When clip 1's STC base (96043s) crosses that wrap, `inTime` reads ~599s, so the
    /// predicted offset is wildly wrong (negative) while the observed offset stays correct. This is why the
    /// prediction-based fold (b025ee8) did not fix the reporter's disc and the observed fold does.
    func test_observedFoldSurvivesInTimeWrapWherePredictionFails() {
        let discTick = 45_000.0
        let base0 = 4_199.917, clip1ObservedBase = 96_043.0, clip0DurationSec = 40.083

        // MPLS inTime is a 32-bit field: clip 1's true STC (96043s) exceeds 2^32 ticks and wraps.
        let inTime0 = UInt64(base0 * discTick)                                   // < 2^32, no wrap
        let inTime1Wrapped = UInt64((clip1ObservedBase * discTick).truncatingRemainder(dividingBy: 4_294_967_296))
        let cumBeforeTicks = UInt64(clip0DurationSec * discTick)
        let predictedSec = (Double(inTime1Wrapped) - Double(inTime0) - Double(cumBeforeTicks)) / discTick

        let observedSec = ClipFold.offsetSeconds(observedBaseSec: clip1ObservedBase, base0Sec: base0,
                                                 cumulativeBeforeSec: clip0DurationSec)

        // Prediction is off by a wrap (thousands of seconds, wrong sign); observed lands on the true jump.
        XCTAssertLessThan(predictedSec, 0)                       // wrong sign, would push clip 1 further out
        XCTAssertEqual(observedSec, 91_803.0, accuracy: 0.1)
        XCTAssertGreaterThan(abs(observedSec - predictedSec), 90_000.0)
    }
}
