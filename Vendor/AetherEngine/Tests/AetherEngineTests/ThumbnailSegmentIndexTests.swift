import XCTest
@testable import AetherEngine

/// #106: maps a scrub time to the segment whose [startSeconds, startSeconds+duration)
/// window contains it. Unlike segmentIndex(forPlaylistTime:) this does NOT clamp past
/// the end: a scrub past the produced range must miss (nil), not pin to the last segment.
final class ThumbnailSegmentIndexTests: XCTestCase {

    private func seg(_ start: Double, _ dur: Double) -> HLSVideoEngine.Segment {
        HLSVideoEngine.Segment(startPts: 0, endPts: 0, startSeconds: start, durationSeconds: dur)
    }

    // starts: 0, 6, 12, 16.5 ; ends: 6, 12, 16.5, 22.5
    private lazy var segments: [HLSVideoEngine.Segment] =
        [seg(0, 6), seg(6, 6), seg(12, 4.5), seg(16.5, 6)]

    func testHitInsideEachSegment() {
        XCTAssertEqual(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 0, segments: segments), 0)
        XCTAssertEqual(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 5.99, segments: segments), 0)
        XCTAssertEqual(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 6.0, segments: segments), 1)
        XCTAssertEqual(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 13.0, segments: segments), 2)
        XCTAssertEqual(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 22.0, segments: segments), 3)
    }

    func testEndBoundaryIsExclusive() {
        // 22.5 == last segment end -> outside every window -> nil (no clamp).
        XCTAssertNil(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 22.5, segments: segments))
    }

    func testBeforeFirstAndPastEndAreNil() {
        XCTAssertNil(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: -1, segments: segments))
        XCTAssertNil(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 9999, segments: segments))
    }

    func testEmptySegmentsIsNil() {
        XCTAssertNil(VideoSegmentProvider.thumbnailSegmentIndex(atSeconds: 5, segments: []))
    }
}
