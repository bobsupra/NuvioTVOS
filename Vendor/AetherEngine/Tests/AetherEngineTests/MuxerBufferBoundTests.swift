// Mid-segment fragment-flush bound for the fMP4 muxer (#64).
//
// The session muxer runs with movflags +frag_custom, so a moof+mdat is emitted only at an explicit
// segment cut. A degenerate segment plan (or any very long segment, or an audio stream that decodes to
// nothing) would otherwise leave the whole span buffered in libavformat's interleaver until the cut,
// growing RAM without bound. These pure helpers decide when an interim flush is due, computed in the
// muxer's rewritten output video time base.
import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("MP4SegmentMuxer buffered-fragment bound (#64)")
struct MuxerBufferBoundTests {

    @Test("Tick span is computed from the output video time base")
    func ticksFromTimeBase() {
        // movenc's typical 24 fps rewrite is 1/16000; 8 s -> 128000 ticks.
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 8, timeBase: AVRational(num: 1, den: 16_000)) == 128_000)
        // Source-axis 90 kHz would be 720000; proves the unit depends on the passed time base.
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 8, timeBase: AVRational(num: 1, den: 90_000)) == 720_000)
    }

    @Test("Non-positive seconds or an invalid time base disables the bound (0 ticks)")
    func ticksDisabled() {
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 0, timeBase: AVRational(num: 1, den: 16_000)) == 0)
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: -1, timeBase: AVRational(num: 1, den: 16_000)) == 0)
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 8, timeBase: AVRational(num: 0, den: 0)) == 0)
    }

    @Test("A flush is due once the buffered video span reaches the bound")
    func boundReached() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 127_999, boundTicks: 128_000) == false)
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 128_000, boundTicks: 128_000) == true)
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 200_000, boundTicks: 128_000) == true)
    }

    @Test("No window yet (sentinel first DTS) never triggers a flush")
    func sentinelFirstDts() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: Int64.min, currentDts: 999_999, boundTicks: 128_000) == false)
    }

    @Test("A backward DTS step never triggers a flush")
    func backwardStep() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 100_000, currentDts: 50_000, boundTicks: 128_000) == false)
    }

    @Test("A disabled bound (0 ticks) never triggers a flush")
    func disabledBound() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 10_000_000, boundTicks: 0) == false)
    }
}
