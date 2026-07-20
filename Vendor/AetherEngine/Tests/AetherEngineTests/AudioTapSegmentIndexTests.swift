import XCTest
@testable import AetherEngine

/// #95: cumulative-EXTINF mapping from a playlist-axis time to the segment index containing it.
/// Pure static core; the instance method just feeds it the live durations array.
final class AudioTapSegmentIndexTests: XCTestCase {

    private let durations: [Double] = [6.0, 6.0, 4.5, 6.0]   // cumulative: 6, 12, 16.5, 22.5

    func testMapsInsideEachSegment() {
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 0, durations: durations), 0)
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 5.99, durations: durations), 0)
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 6.0, durations: durations), 1)
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 13.0, durations: durations), 2)
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 22.0, durations: durations), 3)
    }

    func testClampsPastEndToLastSegment() {
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 22.5, durations: durations), 3)
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 9999, durations: durations), 3)
    }

    func testNegativeTimeAndEmptyListClampToZero() {
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: -3, durations: durations), 0)
        XCTAssertEqual(VideoSegmentProvider.segmentIndex(forPlaylistTime: 5, durations: []), 0)
    }
}
