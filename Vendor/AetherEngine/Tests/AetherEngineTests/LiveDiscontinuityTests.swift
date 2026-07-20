// Tests/AetherEngineTests/LiveDiscontinuityTests.swift
// Pins the producer-flag -> provider -> playlist-builder path for #EXT-X-DISCONTINUITY placement.
// Does not use the mpegts demuxer (it normalizes PTS jumps before the producer sees them).
import XCTest
@testable import AetherEngine

/// Hand-built segment list with a discontinuity at a known index; only playlist-builder-relevant members are meaningful.
private final class MockLiveProvider: HLSSegmentProvider, @unchecked Sendable {
    let count: Int
    let discontinuousIndex: Int

    init(count: Int, discontinuousIndex: Int) {
        self.count = count
        self.discontinuousIndex = discontinuousIndex
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 5.0 }
    func segmentIsDiscontinuous(at index: Int) -> Bool { index == discontinuousIndex }
    var playlistType: HLSPlaylistType { .live }
    // No window sliding (firstVisible=0): every segment listed, tag position unambiguous.
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool) {
        (visibleCount: count, refreshCounter: 1, endlistAdded: false)
    }
}

final class LiveDiscontinuityTests: XCTestCase {

    func testDiscontinuityTagPrecedesOnlyTheBoundarySegment() {
        let provider = MockLiveProvider(count: 5, discontinuousIndex: 2)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Exactly one discontinuity tag.
        let tagCount = lines.filter { $0 == "#EXT-X-DISCONTINUITY" }.count
        XCTAssertEqual(tagCount, 1, "expected exactly one #EXT-X-DISCONTINUITY tag")

        // The tag must immediately precede seg2's #EXTINF, and seg2's URI
        // must follow that #EXTINF.
        guard let tagIdx = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") else {
            return XCTFail("no #EXT-X-DISCONTINUITY tag emitted")
        }
        XCTAssertTrue(lines[tagIdx + 1].hasPrefix("#EXTINF:"),
                      "tag must be immediately followed by an #EXTINF")
        XCTAssertEqual(lines[tagIdx + 2], "seg2.mp4",
                       "the tagged segment must be seg2 (the discontinuous index)")

        // Verify no other segment carries the tag (seg0/1/3/4).
        for i in [0, 1, 3, 4] {
            guard let uriIdx = lines.firstIndex(of: "seg\(i).mp4") else {
                return XCTFail("seg\(i).mp4 missing from playlist")
            }
            // URI is preceded by #EXTINF, which is preceded by MAP (seg0) or prior URI, never a discontinuity tag.
            XCTAssertNotEqual(lines[uriIdx - 2], "#EXT-X-DISCONTINUITY",
                              "seg\(i) must not be flagged discontinuous")
        }
    }

    func testNoTagWhenNoDiscontinuity() {
        // discontinuousIndex out of range: no segment flagged.
        let provider = MockLiveProvider(count: 4, discontinuousIndex: -1)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        // Use exact-line match: #EXT-X-DISCONTINUITY-SEQUENCE header (RFC 8216 6.2.2) would fool a substring check.
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertFalse(lines.contains("#EXT-X-DISCONTINUITY"),
                       "a playlist with no discontinuous segment must not emit the tag")
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"),
                      "live playlists must carry the discontinuity-sequence header")
    }

    func testFirstSegmentDiscontinuityIsEmittedAfterMap() {
        // seg0 discontinuity is legal; tag must still appear after #EXT-X-MAP.
        let provider = MockLiveProvider(count: 3, discontinuousIndex: 0)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let tagIdx = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") else {
            return XCTFail("no tag emitted for a seg0 discontinuity")
        }
        XCTAssertTrue(lines[tagIdx + 1].hasPrefix("#EXTINF:"))
        XCTAssertEqual(lines[tagIdx + 2], "seg0.mp4")
    }
}
