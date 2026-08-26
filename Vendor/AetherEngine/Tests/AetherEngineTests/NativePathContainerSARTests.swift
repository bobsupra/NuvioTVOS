import Testing
import Foundation
import AetherLibavutil
@testable import AetherEngine

/// The loopback fMP4 served the native path at the source's CODED shape whenever the pixel aspect was
/// declared by the container alone. `movenc` writes `pasp` from the output codecpar
/// (`mov_write_pasp_tag` reads `track->par->sample_aspect_ratio`), the muxer fills that codecpar with
/// `avcodec_parameters_copy` from the source, and a container-declared ratio never reaches codecpar:
/// Matroska's DisplayWidth quotient and MP4's own `pasp` land on `AVStream` (matroskadec.c / mov.c).
/// So a 720x576 MKV carrying 64:45 in its header alone reached AVPlayer as 720x576, squeezed, while a
/// file whose H.264 VUI declared the same ratio played correctly, which is why this survived: the
/// common encode carries the ratio in the bitstream.
///
/// Measured on two fixtures cut from one source (`setsar=64/45` vs `-c copy -aspect 1024:576`), the
/// `pasp` box in the served `init.mp4`: 64:45 for the VUI file, 1:1 for the container-only file, and
/// 64:45 for both once the ratio is resolved before the copy.
///
/// The resolution is `PixelAspectPolicy.declaredPixelAspect`, the same answer the VT decoder took for
/// #354, so the ratio the native path stretches to and the ratio the software path attaches cannot
/// disagree about one picture.
@Suite("A container-declared pixel aspect reaches the loopback fMP4")
struct NativePathContainerSARTests {

    private func rational(_ num: Int32, _ den: Int32) -> AVRational {
        AVRational(num: num, den: den)
    }

    @Test("a ratio only the container declares is the one to write")
    func containerOnlyRatioSurvives() {
        let resolved = PixelAspectPolicy.declaredPixelAspect(
            bitstream: rational(1, 1), container: rational(64, 45), width: 720, height: 576)
        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    @Test("an unset bitstream ratio is not a square one")
    func unsetBitstreamFallsThrough() {
        let resolved = PixelAspectPolicy.declaredPixelAspect(
            bitstream: rational(0, 1), container: rational(64, 45), width: 720, height: 576)
        #expect(resolved?.num == 64)
    }

    @Test("the bitstream is the answer where the container declares no correction")
    func bitstreamWinsWithoutAContainerClaim() {
        for container in [rational(0, 1), rational(1, 1)] {
            let resolved = PixelAspectPolicy.declaredPixelAspect(
                bitstream: rational(16, 11), container: container, width: 720, height: 576)
            #expect(resolved?.num == 16)
            #expect(resolved?.den == 11)
        }
    }

    /// Square pixels return nil rather than 1:1: nothing needs correcting, and writing a `pasp` of one
    /// is a claim a consumer cannot tell from a measured ratio.
    @Test("square pixels attach nothing")
    func squarePixelsAttachNothing() {
        #expect(PixelAspectPolicy.declaredPixelAspect(
            bitstream: rational(1, 1), container: rational(1, 1), width: 1920, height: 1080) == nil)
        #expect(PixelAspectPolicy.declaredPixelAspect(
            bitstream: rational(0, 1), container: rational(0, 1), width: 1920, height: 1080) == nil)
    }

    /// #290 governs the native path too now. A live channel declaring 3:1 on 1080p would have been
    /// stretched into a 5.33:1 band by AVPlayer while the software decoder refused the same ratio.
    @Test("a ratio the software path disbelieves is not written either")
    func rejectedRatioIsNotWritten() {
        #expect(PixelAspectPolicy.declaredPixelAspect(
            bitstream: rational(3, 1), container: rational(0, 1), width: 1920, height: 1080) == nil)
        // The same 3:1 on the frame it is right for stays.
        #expect(PixelAspectPolicy.declaredPixelAspect(
            bitstream: rational(3, 1), container: rational(0, 1), width: 640, height: 1080) != nil)
    }

    /// The container is the later authoring layer (`mkvmerge --aspect-ratio` writes DisplayWidth and
    /// leaves the bitstream alone), and it is what `av_guess_sample_aspect_ratio` returns, so every
    /// ffmpeg-based player shows that ratio for the same file.
    @Test("a real container correction outranks a bitstream one")
    func containerOutranksBitstream() {
        let resolved = PixelAspectPolicy.declaredPixelAspect(
            bitstream: rational(16, 11), container: rational(64, 45), width: 720, height: 576)
        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    /// The decoders read three axes, and a square one used to end the search: the frame's square VUI
    /// hid the container's ratio one axis below it. That is the same defect the muxer had.
    @Test("a square frame ratio does not end the search")
    func squareFrameDoesNotEndTheSearch() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(1, 1), codecCtx: rational(1, 1), stream: rational(64, 45),
            width: 720, height: 576)
        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    @Test("a non-square frame ratio still wins, mid-stream truth included (#177)")
    func nonSquareFrameStillWins() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(16, 11), codecCtx: rational(1, 1), stream: rational(64, 45),
            width: 720, height: 576)
        #expect(resolved?.num == 16)
        #expect(resolved?.den == 11)
    }

    /// #354's resolution is the same decision, so it keeps answering identically after the move.
    @Test("the VT decoder and the muxer resolve one ratio")
    func decoderAndMuxerAgree() {
        for (bitstream, container, w, h) in [
            (rational(0, 1), rational(64, 45), Int32(720), Int32(576)),
            (rational(32, 11), rational(0, 1), Int32(352), Int32(576)),
            (rational(3, 1), rational(0, 1), Int32(1920), Int32(1080)),
            (rational(1, 1), rational(1, 1), Int32(1280), Int32(720)),
        ] {
            let policy = PixelAspectPolicy.declaredPixelAspect(
                bitstream: bitstream, container: container, width: w, height: h)
            let decoder = HardwareVideoDecoder.resolvePixelAspectRatio(
                bitstream: bitstream, container: container, width: w, height: h)
            #expect(policy?.num == decoder?.num)
            #expect(policy?.den == decoder?.den)
        }
    }
}
