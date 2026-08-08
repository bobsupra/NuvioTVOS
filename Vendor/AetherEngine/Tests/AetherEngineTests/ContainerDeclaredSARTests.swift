import Testing
import Foundation
import AetherLibavutil
@testable import AetherEngine

/// The software path's container-SAR fallback exists for anamorphic sources whose ratio is not in
/// the bitstream, and it read `codecpar->sample_aspect_ratio` only, which is where a
/// container-declared ratio never lands: Matroska writes its DisplayWidth quotient to
/// `st->sample_aspect_ratio` (matroskadec.c), MP4 does the same with `pasp` (mov.c), and codecpar
/// stays 0:1. The fallback was therefore dead in exactly the case it was written for, while
/// MPEG-2 sources kept working because their ratio arrives per frame from the sequence header.
///
/// Found while verifying #290 against a VP9 MKV declaring its SAR in the container: the engine
/// resolved frame=0:1 ctx=0:1 stream=0:1 and attached nothing.
@Suite("Container-declared SAR reaches the software decoder")
struct ContainerDeclaredSARTests {

    private func rational(_ num: Int32, _ den: Int32) -> AVRational {
        AVRational(num: num, den: den)
    }

    @Test("a bitstream SAR wins over the container")
    func bitstreamWins() {
        let sar = SoftwareVideoDecoder.declaredStreamSAR(
            bitstream: rational(16, 11), container: rational(1, 1))
        #expect(sar.num == 16)
        #expect(sar.den == 11)
    }

    @Test("an unset bitstream SAR falls back to the container (MKV DisplayWidth, MP4 pasp)")
    func containerFillsIn() {
        let sar = SoftwareVideoDecoder.declaredStreamSAR(
            bitstream: rational(0, 1), container: rational(2, 1))
        #expect(sar.num == 2)
        #expect(sar.den == 1)
    }

    @Test("neither source declaring anything stays unset rather than inventing a ratio")
    func nothingDeclaredStaysUnset() {
        let sar = SoftwareVideoDecoder.declaredStreamSAR(
            bitstream: rational(0, 1), container: rational(0, 1))
        #expect(PixelAspectPolicy.saneSAR(sar) == nil)
    }

    @Test("a container ratio is still subject to the display-aspect gate")
    func containerRatioIsStillJudged() {
        // The VP9 fixture from #290: the container claims 3:1 on 1920x1080. Reaching the decoder is
        // not the same as being believed.
        let sar = SoftwareVideoDecoder.declaredStreamSAR(
            bitstream: rational(0, 1), container: rational(3, 1))
        #expect(sar.num == 3)
        #expect(PixelAspectPolicy.saneSAR(sar, width: 1920, height: 1080) == nil)
        #expect(PixelAspectPolicy.saneSAR(sar, width: 640, height: 1080) != nil)
    }
}
