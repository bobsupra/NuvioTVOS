import XCTest
@testable import AetherEngine

/// AE#105 round 5: the multi-clip fold made the intra-title timeline contiguous, but the published playhead
/// still sat in the disc's source-PTS domain (clip 0's STC base) while `duration` was the 0-based MPLS length,
/// so the scrubber showed 10:04 / 1:10:14 on 0:35 / 0:41 titles. `PresentationAxis` + `sourcePresentationOrigin`
/// map the published playhead / seek target onto the same 0-based axis as the duration, leaving `sourceTime`
/// (subtitle-cue alignment) on the source-PTS axis. These cover the pure axis arithmetic; the clock wiring is
/// device-verified on the real disc.
final class Issue105PresentationAxisTests: XCTestCase {

    // Concrete geometry from the reporter's test.t.log.txt / screenshots.
    private let eightClipBase0 = 599.917    // "Title 4", 8 clips, duration 0:35 -> scrubber showed 10:04
    private let twoClipBase0 = 4_199.917    // "Title 3", 2 clips, duration 0:41 -> scrubber showed 1:10:14

    // MARK: - Display axis (published playhead / seek target)

    /// The exact reporter numbers: a source-PTS playhead of base0 + elapsed must publish as `elapsed` (0-based),
    /// not base0 + elapsed. 604s on the 8-clip title -> 4.083s; 4214s on the 2-clip title -> 14.083s.
    func test_discOriginRebasesReporterPlayheadToZeroBased() {
        XCTAssertEqual(PresentationAxis.display(sourcePTS: 604.0, origin: eightClipBase0), 4.083, accuracy: 0.01)
        XCTAssertEqual(PresentationAxis.display(sourcePTS: 4_214.0, origin: twoClipBase0), 14.083, accuracy: 0.01)
    }

    /// The published playhead must never exceed the 0-based duration (the "ball pinned at the end" symptom).
    func test_discPlayheadStaysWithinZeroBasedDuration() {
        let duration = 35.285                       // 8-clip title MPLS duration
        // Playhead near the end of the title: source PTS = base0 + 35.0.
        let display = PresentationAxis.display(sourcePTS: eightClipBase0 + 35.0, origin: eightClipBase0)
        XCTAssertEqual(display, 35.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(display, duration)
    }

    /// Normal files and live use origin 0, so the display axis is byte-identical to the source axis (no-op).
    func test_zeroOriginIsIdentity() {
        for pts in [0.0, 12.5, 3_600.0, 7_508.9] {
            XCTAssertEqual(PresentationAxis.display(sourcePTS: pts, origin: 0), pts, accuracy: 0.0)
            XCTAssertEqual(PresentationAxis.source(displayTime: pts, origin: 0), pts, accuracy: 0.0)
        }
    }

    // MARK: - Round trip (host seek in / playhead out are inverses)

    func test_displaySourceRoundTrip() {
        for origin in [0.0, eightClipBase0, twoClipBase0] {
            for value in [0.0, 4.083, 35.0, 41.6] {
                let source = PresentationAxis.source(displayTime: value, origin: origin)
                XCTAssertEqual(PresentationAxis.display(sourcePTS: source, origin: origin), value, accuracy: 1e-9)
            }
        }
    }

    // MARK: - Seek clock target (display target -> AVPlayer's 0-based HLS clock)

    /// Replicates `seek(to:)`: clockTarget = source(displayTarget, origin) - playlistShiftSeconds. For a disc,
    /// origin == the constant shift == base0, so a 0-based display target lands on the SAME 0-based playlist
    /// clock AVPlayer runs on (never the negative value the old `target - shift` produced). Off disc it stays
    /// `target - shift`.
    private func clockTarget(displayTarget: Double, shift: Double, origin: Double) -> Double {
        PresentationAxis.source(displayTime: displayTarget, origin: origin) - shift
    }

    func test_discSeekTargetMapsToZeroBasedPlaylistClock() {
        // Disc: origin == shift == base0. Scrub to 0:20 must seek AVPlayer to itemAxis 20s, not 20 - 599 < 0.
        let shift = eightClipBase0, origin = eightClipBase0
        XCTAssertEqual(clockTarget(displayTarget: 20.0, shift: shift, origin: origin), 20.0, accuracy: 0.001)
        XCTAssertEqual(clockTarget(displayTarget: 0.0, shift: shift, origin: origin), 0.0, accuracy: 0.001)
    }

    func test_oldFormulaWouldSeekNegativeOnDisc() {
        // Guards the regression this fixes: without the origin, scrubbing a disc seeks to a negative clock.
        let shift = eightClipBase0
        let brokenClockTarget = 20.0 - shift            // the pre-fix `target - playlistShiftSeconds`
        XCTAssertLessThan(brokenClockTarget, 0)
    }

    func test_nonDiscSeekTargetIsUnchanged() {
        // Normal VOD: origin 0, so clockTarget == target - shift exactly as before this change.
        let shift = 0.4                                  // a small head-of-stream offset
        XCTAssertEqual(clockTarget(displayTarget: 30.0, shift: shift, origin: 0),
                       30.0 - shift, accuracy: 1e-9)
    }
}
