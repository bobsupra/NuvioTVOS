import XCTest
@testable import AetherEngine

/// AE#270: `duration` is 0-based for every source, so the published playhead has to be too. Only a disc
/// title anchored its display origin before this, and every other source published its raw source PTS.
/// A transport stream muxed with a 60 s origin therefore opened its scrubber at 1:02 of a ten-minute item,
/// and at broadcast scale (1001 s origin, measured on `Fixtures/user/hls-hevc-vod-long-offset`) a seek
/// target computed on that axis resolved outside the item and landed at the start of the file.
///
/// These pin the origin policy; the axis arithmetic it feeds is covered by `Issue105PresentationAxisTests`.
final class Issue270PresentationOriginTests: XCTestCase {

    /// Numbers are from the measured runs: first publish of the 60 s-origin fixture, and the 1.96 s drift
    /// a later producer restart folded into the same session's shift.
    private let firstShift = 61.341
    private let driftedShift = 63.301

    /// The container anchor is set when the session starts, so this is the seed for a session that never
    /// got one (no loopback demuxer behind it).
    func test_vodSeedsFromTheFirstPublishedShiftWhenNothingAnchoredIt() {
        XCTAssertEqual(
            PresentationOriginPolicy.origin(latched: nil, publishedShift: firstShift, isLive: false, isDisc: false),
            firstShift,
            accuracy: 0.001
        )
    }

    /// The anchor that the session start installed (the container's own start time) survives the first
    /// publish, whose shift also carries the producer's initial drift: on a B-frame MP4 whose first PTS is
    /// 0 that shift reads -0.08 s, and following it would move every existing source's clock.
    func test_containerAnchorSurvivesTheFirstPublish() {
        XCTAssertEqual(
            PresentationOriginPolicy.origin(latched: 0, publishedShift: -0.08, isLive: false, isDisc: false),
            0,
            accuracy: 0
        )
    }

    /// Later publishes carry producer drift, not a new origin. Following them would move display-0 under a
    /// picture that has not moved.
    func test_vodKeepsTheLatchedOriginWhenTheShiftDrifts() {
        XCTAssertEqual(
            PresentationOriginPolicy.origin(latched: firstShift, publishedShift: driftedShift, isLive: false, isDisc: false),
            firstShift,
            accuracy: 0.001
        )
    }

    /// A disc keeps re-reading it: clip 0's STC base is what every publish of that title carries (AE#105),
    /// and a title switch inside one session has to move the origin with it.
    func test_discFollowsEveryPublish() {
        XCTAssertEqual(
            PresentationOriginPolicy.origin(latched: 599.917, publishedShift: 4_199.917, isLive: false, isDisc: true),
            4_199.917,
            accuracy: 0.001
        )
    }

    /// Live publishes on the source axis by contract: the live edge and the DVR window are expressed there.
    func test_liveStaysOnTheSourceAxis() {
        XCTAssertEqual(
            PresentationOriginPolicy.origin(latched: 1_002.741, publishedShift: 1_002.741, isLive: true, isDisc: false),
            0,
            accuracy: 0
        )
    }

    /// A 0-based source (every MP4 the engine has ever played) latches 0, so all conversions stay identity.
    func test_zeroBasedSourceIsUnaffected() {
        let origin = PresentationOriginPolicy.origin(latched: nil, publishedShift: 0, isLive: false, isDisc: false)
        XCTAssertEqual(origin, 0, accuracy: 0)
        XCTAssertEqual(PresentationAxis.display(sourcePTS: 42, origin: origin), 42, accuracy: 0)
        XCTAssertEqual(PresentationAxis.source(displayTime: 42, origin: origin), 42, accuracy: 0)
    }

    /// The measured defect, through the arithmetic it feeds: with the origin latched, a 1001 s-origin source
    /// publishes inside its own duration and a seek to 480 s maps back onto a source PTS inside the item.
    /// Before, the same playhead published as 1003.44 on a 600 s item and the seek target resolved to 480 s
    /// of source PTS, which is in front of the first frame.
    func test_broadcastOriginPublishesInsideTheItemDuration() {
        let origin = PresentationOriginPolicy.origin(latched: nil, publishedShift: 1_002.741, isLive: false, isDisc: false)
        XCTAssertEqual(PresentationAxis.display(sourcePTS: 1_003.441, origin: origin), 0.7, accuracy: 0.001)
        XCTAssertEqual(PresentationAxis.source(displayTime: 480, origin: origin), 1_482.741, accuracy: 0.001)
    }
}
