import XCTest
@testable import AetherEngine

final class VODSegmentCutterTests: XCTestCase {

    // 4 segments of 4s each, boundaries in ms (source TB 1/1000): starts 0,4,8,12 + end 16.
    private let fourSeg: [Int64] = [0, 4000, 8000, 12000, 16000]

    func testFirstKeyframeOpensBaseSegment() {
        var c = VODSegmentCutter(boundaries: fourSeg, baseIndex: 0)
        XCTAssertEqual(c.index(pts: 0, isKeyframe: true), 0)   // first IRAP stays in seg 0
    }

    func testNonKeyframesStayInCurrentSegment() {
        var c = VODSegmentCutter(boundaries: fourSeg, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 1000, isKeyframe: false), 0)
        XCTAssertEqual(c.index(pts: 2000, isKeyframe: false), 0)
    }

    func testBoundaryKeyframeOpensNextSegment() {
        var c = VODSegmentCutter(boundaries: fourSeg, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 1)   // IRAP at 4s opens seg 1
        XCTAssertEqual(c.index(pts: 8000, isKeyframe: true), 2)
        XCTAssertEqual(c.index(pts: 12000, isKeyframe: true), 3)
    }

    /// The #92 fix: open-GOP RASL leading pictures arrive in decode order AFTER the CRA but carry a PTS
    /// BEFORE it. They must stay in the CRA's segment, not be re-routed to the previous one.
    func testRaslLeadingPicturesStayWithTheirKeyframe() {
        var c = VODSegmentCutter(boundaries: fourSeg, baseIndex: 0)
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
        var c = VODSegmentCutter(boundaries: twoSeg, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 4000, isKeyframe: true), 0)   // mid-segment IRAP stays in seg 0
        XCTAssertEqual(c.index(pts: 8000, isKeyframe: true), 1)   // boundary IRAP opens seg 1
    }

    func testBaseIndexOffsetForRestart() {
        let b: [Int64] = [264_000, 268_000, 272_000, 276_000]   // 3 segments: 264, 265, 266
        var c = VODSegmentCutter(boundaries: b, baseIndex: 264)
        XCTAssertEqual(c.index(pts: 264_000, isKeyframe: true), 264)
        XCTAssertEqual(c.index(pts: 268_000, isKeyframe: true), 265)
        XCTAssertEqual(c.index(pts: 272_000, isKeyframe: true), 266)
    }

    func testSparseKeyframeJumpAdvancesMultiple() {
        var c = VODSegmentCutter(boundaries: fourSeg, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: 12000, isKeyframe: true), 3)   // skips 1,2 in one step
    }

    func testNeverAdvancesPastLastSegment() {
        var c = VODSegmentCutter(boundaries: fourSeg, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        // Keyframes well past the final boundary clamp at the last segment (count-1 boundaries => seg 3).
        XCTAssertEqual(c.index(pts: 99_000, isKeyframe: true), 3)
        XCTAssertEqual(c.index(pts: 99_000, isKeyframe: true), 3)
    }

    func testNoptsKeyframeStaysPut() {
        var c = VODSegmentCutter(boundaries: fourSeg, baseIndex: 0)
        _ = c.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(c.index(pts: Int64.min, isKeyframe: true), 0)
    }
}
