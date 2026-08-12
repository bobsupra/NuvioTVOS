import Foundation
import AetherLibavutil
import Testing
@testable import AetherEngine

/// AE#354: the software host's VT-backed decoder attached no pixel aspect ratio, so anamorphic HEVC
/// reached the layer at its coded dimensions (measured: 720x576 at 64:45 presented as 720x576, a
/// 16:9 picture squashed into 5:4). The libavcodec decoder on the same host has attached it since
/// #177; the gap was one decoder wide.
///
/// The decision is the same one `SoftwareVideoDecoder` makes, minus the per-frame source: VT hands
/// over pixel buffers, not `AVFrame`s, so only the two declared ratios exist here.
@Suite("VT-backed decoder pixel aspect (#354)")
struct Issue354HardwareDecoderPixelAspectTests {

    private func rational(_ num: Int32, _ den: Int32) -> AVRational {
        AVRational(num: num, den: den)
    }

    @Test("the bitstream ratio wins over the container's")
    func bitstreamWins() {
        let resolved = HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(64, 45), container: rational(1, 1), width: 720, height: 576)

        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    /// The case that keeps the container fallback alive: Matroska writes its DisplayWidth quotient to
    /// the stream and leaves codecpar at 0:1, which is every DVD remuxed to MKV.
    @Test("an unset bitstream ratio falls back to the container's")
    func containerIsTheFallback() {
        let resolved = HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(0, 1), container: rational(64, 45), width: 720, height: 576)

        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    @Test("square pixels attach nothing")
    func squarePixelsAttachNothing() {
        #expect(HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(1, 1), container: rational(1, 1), width: 1920, height: 1080) == nil)
    }

    @Test("a garbage component ratio is rejected (#177)")
    func garbageComponentsRejected() {
        #expect(HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(1088, 1), container: rational(0, 1), width: 1920, height: 1080) == nil)
    }

    /// #290: plausible numbers, impossible picture. 1080p declaring 3:1 smears into a 5.33:1 band.
    @Test("a ratio whose display aspect is impossible is rejected (#290)")
    func impossibleDisplayAspectRejected() {
        #expect(HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(3, 1), container: rational(0, 1), width: 1920, height: 1080) == nil)
    }

    /// The same 2:1 that is wrong on a full-width frame is right on a half-width broadcast one, which
    /// is why the gate needs the frame and not just the numbers.
    @Test("2:1 on a 960x1080 broadcast frame is kept")
    func halfWidthBroadcastKept() {
        let resolved = HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(2, 1), container: rational(0, 1), width: 960, height: 1080)

        #expect(resolved?.num == 2)
        #expect(resolved?.den == 1)
    }
}
