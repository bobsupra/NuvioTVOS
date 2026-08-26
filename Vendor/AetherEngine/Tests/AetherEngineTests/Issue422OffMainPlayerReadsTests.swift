import Testing
import Foundation
@testable import AetherEngine

/// AE#422 (rrgomes): on macOS, an `AVPlayerItem.currentTime()` made from the host's main actor did
/// not return for 13.3 s while AVPlayer was wedged, blocking the whole app; it came back 30 ms after
/// the re-engage watchdog fired. The engine read the same property from the same place.
///
/// `AVFoundationOffMain` already carried the reason ("a momentarily busy media server turns any of
/// them into a fully blocked main thread and, past the watchdog threshold, a process kill"), but only
/// the 30 s memory probe used it. The paths that run precisely while the server is not answering did
/// not:
///
/// | path | reads per pass | now |
/// | --- | --- | --- |
/// | seek-deadline loop | 1 island + 3 `bufferedEnd` | one batched `seekBufferSnapshot` off-main |
/// | stall nudge / reload | `currentTime()` at the call site and again inside | `renderedPositionMirror` |
/// | VOD shift-publish line | `avPlayerBufferAheadSeconds()` | off-main, awaited before the line |
/// | premature-end recovery (#287) | playhead + seekable + loaded | one batched reading off-main |
///
/// The mirror is not just the non-blocking choice for the recovery anchors, it is the correct value:
/// `recoveryAnchorPosition(currentRendered:)` exists to keep the anchor from sitting below the frame
/// on screen (#115), and `currentTime()` is the clock, which diverges from the rendered frame during
/// exactly the landing these run in (#123). The wedge path was already passing the mirror.
///
/// What is verified here is the logic that came out of the main actor with the reads. `bufferedEnd`
/// used to be a `@MainActor` property wrapped around a blocking round trip, so its rule (the span
/// CONTIGUOUS with the playhead, disjoint islands ahead of a gap ignored) had no test at all.
struct Issue422OffMainPlayerReadsTests {

    private static func end(_ ranges: [(Double, Double)], now: Double) -> Double {
        NativeAVPlayerHost.contiguousBufferedEnd(ranges: ranges, now: now)
    }

    @Test("an empty buffer ends at the playhead, not at zero")
    func emptyBufferEndsAtPlayhead() {
        // The #65 reporter signature: `loaded=[]` with the clock frozen, which `seekIsWedged` reads
        // as starved precisely because bufferedEnd equals renderedTime.
        #expect(Self.end([], now: 149.9) == 149.9)
    }

    @Test("the range covering the playhead sets the end")
    func coveringRangeSetsEnd() {
        #expect(Self.end([(100.0, 158.0)], now: 149.9) == 158.0)
    }

    @Test("an island beyond a gap does not count")
    func disjointIslandIgnored() {
        // A far-forward seek's target island is real buffer, but it is not contiguous with the
        // playhead, so it must not read as "this consumer is fed" (AE#141).
        #expect(Self.end([(100.0, 150.5), (300.0, 330.0)], now: 149.9) == 150.5)
    }

    @Test("a range starting within a second of the playhead still counts as contiguous")
    func toleranceAtTheHead() {
        // The gap between the rendered frame and the range's reported start is normal.
        #expect(Self.end([(150.5, 160.0)], now: 149.9) == 160.0)
        // Past the tolerance it is a hole, and the buffer ends at the playhead.
        #expect(Self.end([(151.5, 160.0)], now: 149.9) == 149.9)
    }

    @Test("a range wholly behind the playhead does not extend the end")
    func behindRangeIgnored() {
        #expect(Self.end([(100.0, 140.0)], now: 149.9) == 149.9)
    }

    @Test("adjacent ranges are not chained: only a range touching the playhead counts")
    func adjacentRangesAreNotChained() {
        // Behaviour as it has stood since AetherEngine#54, recorded rather than changed: each range
        // is judged against the PLAYHEAD, not against the running end, so `[100, 152]` counts and the
        // `[152, 170]` that continues it does not. AVFoundation normally reports a contiguous span as
        // one range, so this rarely bites, but where it does the figure understates the buffer, and
        // `seekIsWedged` reads an understated buffer as starvation. Worth its own measurement before
        // anyone changes it; this test exists so the change would be visible.
        #expect(Self.end([(100.0, 152.0), (152.0, 170.0)], now: 149.9) == 152.0)
        // A single range covering the same span reads the full extent.
        #expect(Self.end([(100.0, 170.0)], now: 149.9) == 170.0)
    }

    @Test("a non-finite playhead reads as no buffer rather than as NaN")
    func nonFinitePlayhead() {
        // `currentTime()` is indefinite before the first sample, and a NaN escaping here would
        // silently poison `seekIsWedged`.
        #expect(Self.end([(100.0, 158.0)], now: .nan) == 0)
    }

    @Test("a non-finite range is skipped rather than poisoning the result")
    func nonFiniteRangeSkipped() {
        #expect(Self.end([(Double.nan, 158.0), (100.0, 152.0)], now: 149.9) == 152.0)
    }
}
