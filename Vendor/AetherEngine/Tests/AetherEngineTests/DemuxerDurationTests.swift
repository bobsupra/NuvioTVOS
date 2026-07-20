import XCTest
@testable import AetherEngine

// AE#105 follow-up: FFmpeg's mpegts duration estimate over concatenated multi-clip Blu-ray m2ts with
// discontinuous PTS is unreliable (a 42s title probed as 25.5h, a 35s title as 5s). The MPLS/IFO
// playlist duration is authoritative, so the demuxer prefers it when a disc title supplies one.
final class DemuxerDurationTests: XCTestCase {
    func test_prefersDiscTitleDurationOverInflatedContainerEstimate() {
        // Title probed as 25.5h; MPLS says 42s.
        XCTAssertEqual(Demuxer.effectiveDurationSeconds(discTitle: 42, container: 91_843.97), 42)
    }

    func test_prefersDiscTitleDurationOverTruncatedContainerEstimate() {
        // 8-clip title probed as 5s; MPLS says 35s. Disc duration wins even when it is the larger value.
        XCTAssertEqual(Demuxer.effectiveDurationSeconds(discTitle: 35, container: 5), 35)
    }

    func test_fallsBackToContainerWhenDiscTitleDurationUnknown() {
        // durationTicks 0 (unparsed IFO/MPLS) -> nil disc duration -> keep the container estimate.
        XCTAssertEqual(Demuxer.effectiveDurationSeconds(discTitle: nil, container: 7508.93), 7508.93)
        XCTAssertEqual(Demuxer.effectiveDurationSeconds(discTitle: 0, container: 7508.93), 7508.93)
    }

    func test_nonDiscSourceIsUnaffected() {
        // Plain file: no disc title, keep the container duration verbatim.
        XCTAssertEqual(Demuxer.effectiveDurationSeconds(discTitle: nil, container: 123.4), 123.4)
    }
}
