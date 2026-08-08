import XCTest
@testable import AetherEngine

final class VODSegmentCutterTests: XCTestCase {

    // 4 segments of 4s each, boundaries in ms (source TB 1/1000): starts 0,4,8,12 + end 16.
    private let fourSeg: [Int64] = [0, 4000, 8000, 12000, 16000]

    func testFirstKeyframeOpensBaseSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        XCTAssertEqual(c.index(pts: 0, isKeyframe: true), 0)   // first IRAP stays in seg 0
    }

    func testNonKeyframesStayInCurrentSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 1000, isKeyframe: false), 0)
        XCTAssertEqual(c.index(pts: 2000, isKeyframe: false), 0)
    }

    func testBoundaryKeyframeOpensNextSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 1)   // IRAP at 4s opens seg 1
        XCTAssertEqual(c.index(pts: 8000, isKeyframe: true), 2)
        XCTAssertEqual(c.index(pts: 12000, isKeyframe: true), 3)
    }

    /// The #92 fix: open-GOP RASL leading pictures arrive in decode order AFTER the CRA but carry a PTS
    /// BEFORE it. They must stay in the CRA's segment, not be re-routed to the previous one.
    func testRaslLeadingPicturesStayWithTheirKeyframe() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 1)    // CRA opens seg 1
        XCTAssertEqual(c.index(pts: 3958, isKeyframe: false), 1)   // RASL, pts < CRA -> stays in seg 1
        XCTAssertEqual(c.index(pts: 3917, isKeyframe: false), 1)
        XCTAssertEqual(c.index(pts: 4083, isKeyframe: false), 1)   // trailing -> seg 1
    }

    /// GOP shorter than the segment: an intra-segment keyframe that has not reached the next boundary
    /// must NOT open a new segment.
    func testIntraSegmentKeyframeDoesNotCut() {
        let twoSeg: [Int64] = [0, 8000, 16000]   // 8s segments
        var c = VODSegmentCutter(sourceBoundaries: twoSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 0)   // mid-segment IRAP stays in seg 0
        XCTAssertEqual(c.index(pts: 8000, isKeyframe: true), 1)   // boundary IRAP opens seg 1
    }

    func testBaseIndexOffsetForRestart() {
        let b: [Int64] = [264_000, 268_000, 272_000, 276_000]   // 3 segments: 264, 265, 266
        var c = VODSegmentCutter(sourceBoundaries: b, planAnchorPts: 0, baseIndex: 264)
        XCTAssertEqual(c.index(pts: 264_000, isKeyframe: true), 264)
        XCTAssertEqual(c.index(pts: 268_000, isKeyframe: true), 265)
        XCTAssertEqual(c.index(pts: 272_000, isKeyframe: true), 266)
    }

    func testSparseKeyframeJumpAdvancesMultiple() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 12000, isKeyframe: true), 3)   // skips 1,2 in one step
    }

    func testNeverAdvancesPastLastSegment() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        // Keyframes well past the final boundary clamp at the last segment (count-1 boundaries => seg 3).
        XCTAssertEqual(c.index(pts: 99_000, isKeyframe: true), 3)
        XCTAssertEqual(c.index(pts: 99_000, isKeyframe: true), 3)
    }

    func testNoptsKeyframeStaysPut() {
        var c = VODSegmentCutter(sourceBoundaries: fourSeg, planAnchorPts: 0, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: Int64.min, isKeyframe: true), 0)
    }

    /// AE#268: packets arrive with the producer's shift already subtracted, so they are on the item
    /// axis while the plan's boundaries are source PTS. On a source whose content starts at 1.48 s
    /// (every MPEG-TS), comparing the two directly put each cut a whole anchor late; on a plan whose
    /// boundaries ARE the source's IRAPs it never cut at all, because such a keyframe's item-axis pts
    /// is exactly one anchor below its own boundary.
    func testNonZeroPlanAnchorCutsOnTheItemAxis() {
        let anchor: Int64 = 1480
        let boundaries: [Int64] = [1480, 11480, 21480, 31480]   // IRAPs of a 10 s-segmented source
        var c = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: anchor, baseIndex: 0)
        XCTAssertEqual(c.index(pts: 0, isKeyframe: true), 0)
        XCTAssertEqual(c.index(pts: 9999, isKeyframe: false), 0)
        XCTAssertEqual(c.index(pts: 10_000, isKeyframe: true), 1)   // the source's own second IRAP
        XCTAssertEqual(c.index(pts: 20_000, isKeyframe: true), 2)
    }

    /// A restart whose gate overshot its target still opens at `baseIndex`: the producer rebases the
    /// gating keyframe onto the segment's advertised start, and the cutter sees exactly that.
    func testRestartGateOvershootStillOpensBaseIndex() {
        let anchor: Int64 = 1480
        let boundaries: [Int64] = [641_480, 651_480, 661_480, 671_480]
        var c = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: anchor, baseIndex: 64)
        XCTAssertEqual(c.index(pts: 640_000, isKeyframe: true), 64)   // rebased onto seg 64's start
        XCTAssertEqual(c.index(pts: 650_000, isKeyframe: true), 65)
    }
}
