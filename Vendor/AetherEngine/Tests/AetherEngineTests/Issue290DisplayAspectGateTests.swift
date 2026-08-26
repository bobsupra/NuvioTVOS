import Testing
import Foundation
import AetherLibavutil
@testable import AetherEngine

/// #290: the #177 component gate bounds each SAR component to 256, which catches the pathological
/// values but admits small-but-wrong ratios. A live 1080p H.264 channel declaring 3:1, and 2:1 on a
/// later run, smeared 1920x1080 into a 5.33:1 / 3.56:1 band with both values well inside the gate.
///
/// The magnitude of a SAR carries no information about whether it is a lie; the aspect it produces
/// on the frame it applies to does. These tests pin that distinction from both sides: every entry of
/// the standard H.264/HEVC VUI table (`ff_h2645_pixel_aspect`) survives on the frame size it exists
/// for, including the two that a bound on the ratio alone cannot separate from the reported defect.
@Suite("SAR display-aspect gate (#290)")
struct Issue290DisplayAspectGateTests {

    private func rational(_ num: Int32, _ den: Int32) -> AVRational {
        AVRational(num: num, den: den)
    }

    // MARK: - The reported defect

    @Test("the reported 3:1 and 2:1 on 1920x1080 are rejected")
    func reportedRatiosRejected() {
        #expect(PixelAspectPolicy.saneSAR(rational(3, 1), width: 1920, height: 1080) == nil)
        #expect(PixelAspectPolicy.saneSAR(rational(2, 1), width: 1920, height: 1080) == nil)
        // Both clear the #177 component gate, which is why it could not catch them.
        #expect(PixelAspectPolicy.saneSAR(rational(3, 1)) != nil)
        #expect(PixelAspectPolicy.saneSAR(rational(2, 1)) != nil)
    }

    // MARK: - Why the bound belongs on the aspect, not on the ratio

    @Test("2:1 is right on 960x1080 and wrong on 1920x1080, so only the frame decides")
    func sameRatioBothVerdicts() {
        let broadcast = PixelAspectPolicy.saneSAR(rational(2, 1), width: 960, height: 1080)
        #expect(broadcast?.num == 2)
        #expect(PixelAspectPolicy.displayAspect(sar: rational(2, 1), width: 960, height: 1080) == 16.0 / 9.0)

        #expect(PixelAspectPolicy.saneSAR(rational(2, 1), width: 1920, height: 1080) == nil)
    }

    @Test("32:11 (ratio 2.9) is a standard VUI value and survives on the frame it belongs to")
    func wideStandardRatioSurvives() {
        // H.264 Table E-1 idc 8, PAL half-D1 16:9. A bound on the ratio itself set anywhere below
        // 2.91 rejects real broadcast SD, which is why the gate reads the resulting aspect instead.
        let sane = PixelAspectPolicy.saneSAR(rational(32, 11), width: 352, height: 576)
        #expect(sane?.num == 32)
        #expect(sane?.den == 11)
        let aspect = PixelAspectPolicy.displayAspect(sar: rational(32, 11), width: 352, height: 576)
        #expect(abs(aspect - 16.0 / 9.0) < 0.001)
    }

    @Test("every standard VUI ratio passes on its own frame size")
    func standardTableSurvives() {
        // ff_h2645_pixel_aspect with the frame size each entry exists for (H.264 Table E-1).
        let cases: [(sar: AVRational, width: Int32, height: Int32)] = [
            (rational(12, 11), 720, 576),   // PAL 4:3
            (rational(10, 11), 720, 480),   // NTSC 4:3
            (rational(16, 11), 720, 576),   // PAL 16:9
            (rational(40, 33), 720, 480),   // NTSC 16:9
            (rational(24, 11), 352, 576),   // PAL half-D1 4:3
            (rational(20, 11), 352, 480),   // NTSC half-D1 4:3
            (rational(32, 11), 352, 576),   // PAL half-D1 16:9
            (rational(80, 33), 352, 480),   // NTSC half-D1 16:9
            (rational(18, 11), 480, 576),   // PAL 2/3-D1 4:3
            (rational(15, 11), 480, 480),   // SVCD-ish 4:3
            (rational(64, 33), 528, 576),   // PAL 3/4-D1 16:9
            (rational(160, 99), 528, 480),  // NTSC 3/4-D1 16:9
            (rational(4, 3), 1440, 1080),   // HDV / AVCHD 1440
            (rational(3, 2), 1280, 1080),   // HDCAM 1280
            (rational(2, 1), 960, 1080),    // half-HD broadcast
            (rational(1, 1), 1920, 1080),   // square
        ]
        for c in cases {
            let sane = PixelAspectPolicy.saneSAR(c.sar, width: c.width, height: c.height)
            #expect(sane != nil, "\(c.sar.num):\(c.sar.den) on \(c.width)x\(c.height) must pass")
        }
    }

    @Test("square pixels are never rejected for the aspect of the content itself")
    func squarePixelsAlwaysPass() {
        // A 32:9 desktop capture is 3.56:1 and perfectly correct: it declares no correction, so
        // there is no claim to disbelieve.
        let sane = PixelAspectPolicy.saneSAR(rational(1, 1), width: 5120, height: 1440)
        #expect(sane?.num == 1)
        #expect(sane?.den == 1)
    }

    @Test("a frame that cannot state its size falls back to the component gate")
    func unknownDimensionsUseComponentGate() {
        #expect(PixelAspectPolicy.saneSAR(rational(16, 11), width: 0, height: 0) != nil)
        #expect(PixelAspectPolicy.saneSAR(rational(3, 1), width: 0, height: 0) != nil)
        #expect(PixelAspectPolicy.saneSAR(rational(1088, 1), width: 0, height: 0) == nil)
    }

    @Test("an implausible aspect is rejected in both directions")
    func bothDirectionsBounded() {
        // Squeezing is bounded too, though far more loosely than stretching is in practice: the
        // narrowest real picture is a portrait phone capture at ~0.46, and those store square
        // pixels. 1920x1080 at 1:8 is 0.22, 720x576 at 1:6 is 0.21.
        #expect(PixelAspectPolicy.saneSAR(rational(1, 8), width: 1920, height: 1080) == nil)
        #expect(PixelAspectPolicy.saneSAR(rational(1, 6), width: 720, height: 576) == nil)
        // A portrait aspect that a real source could produce is left alone.
        #expect(PixelAspectPolicy.saneSAR(rational(10, 11), width: 1080, height: 1920) != nil)
    }

    // MARK: - Resolution order

    @Test("a frame SAR that fails on the aspect drops through to the next source")
    func rejectedFrameSARFallsThrough() {
        // Live TS: the frame claims 3:1, the container says square. The claim is dropped and the
        // picture is drawn at coded dimensions instead of a 5.33:1 band. The square declaration
        // behind it is not an answer of its own (it corrects nothing), so the resolution ends in
        // nil; both attach nothing, which is what "drawn at coded dimensions" means here.
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(3, 1), codecCtx: rational(0, 1), stream: rational(1, 1),
            width: 1920, height: 1080)
        #expect(resolved == nil)
        let (attach, latch) = SoftwareVideoDecoder.sarForAttachment(resolved: resolved, latched: nil)
        #expect(attach == nil)
        #expect(latch == nil)
    }

    @Test("no believable SAR anywhere resolves to nil, which attaches nothing")
    func allSourcesRejectedIsNil() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(3, 1), codecCtx: rational(2, 1), stream: rational(0, 1),
            width: 1920, height: 1080)
        #expect(resolved == nil)

        let (attach, latch) = SoftwareVideoDecoder.sarForAttachment(resolved: resolved, latched: nil)
        #expect(attach == nil)
        #expect(latch == nil)
    }

    @Test("a believable SAR still latches for the stream")
    func believableSARStillLatches() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 1), codecCtx: rational(3, 1), stream: rational(16, 11),
            width: 720, height: 576)
        #expect(resolved?.num == 16)
        #expect(resolved?.den == 11)
    }

    // MARK: - The rejection line

    /// A rejected SAR never latches, so the latch line that names frame / ctx / stream cannot fire
    /// for it: the rejection line is the only line a bad ratio produces, and until it carried the
    /// axes the question "which axis lied" was unanswerable in exactly the case that asks it.
    @Test("the rejection line names the axis the ratio arrived on")
    func rejectionLineNamesAxes() {
        // The reported shape, reproduced as a container-declared ratio: nothing on the frame,
        // nothing on the codec context, 3:1 on the stream axis alone.
        let message = SoftwareVideoDecoder.rejectedSARMessage(
            frame: rational(0, 1), ctx: rational(0, 1), stream: rational(3, 1),
            width: 1920, height: 1080)
        #expect(message?.contains("SAR 3:1 rejected on 1920x1080") == true)
        #expect(message?.contains("display aspect 5.33 outside 0.33...3.00") == true)
        #expect(message?.contains("(frame=0:1 ctx=0:1 stream=3:1)") == true)
    }

    @Test("disagreeing axes are both readable, which is the mid-stream-join fingerprint")
    func rejectionLineShowsDisagreement() {
        // MPEG-TS has no container ratio, so stream= is the parser's SPS reading at open and
        // frame= is the SPS in force for this frame. Different values mean the declaration moved.
        let message = SoftwareVideoDecoder.rejectedSARMessage(
            frame: rational(3, 1), ctx: rational(0, 1), stream: rational(2, 1),
            width: 1920, height: 1080)
        // The headline names what would have been used, the axes name where each value sat.
        #expect(message?.contains("SAR 3:1 rejected") == true)
        #expect(message?.contains("(frame=3:1 ctx=0:1 stream=2:1)") == true)
    }

    @Test("a ratio too broken for the component gate still reports the one that was used")
    func rejectionLineSkipsComponentGarbage() {
        // #177's 1088:1 fails the component gate, so the ctx value is what the resolution would
        // have attached, but the frame axis still has to be visible to explain the drop.
        let message = SoftwareVideoDecoder.rejectedSARMessage(
            frame: rational(1088, 1), ctx: rational(3, 1), stream: rational(0, 1),
            width: 1920, height: 1080)
        #expect(message?.contains("SAR 3:1 rejected") == true)
        #expect(message?.contains("(frame=1088:1 ctx=3:1 stream=0:1)") == true)
    }

    @Test("no declared SAR anywhere stays silent")
    func noSARIsSilent() {
        let message = SoftwareVideoDecoder.rejectedSARMessage(
            frame: rational(0, 1), ctx: rational(0, 1), stream: rational(0, 1),
            width: 1920, height: 1080)
        #expect(message == nil)
    }

    @Test("a SAR that was believed is never described as rejected")
    func believedSARIsSilent() {
        // Only an axis that lost on the display aspect is reported: square pixels and a legal
        // broadcast ratio both pass, and a line about either would be a false accusation.
        #expect(SoftwareVideoDecoder.rejectedSARMessage(
            frame: rational(1, 1), ctx: rational(0, 1), stream: rational(0, 1),
            width: 1920, height: 1080) == nil)
        #expect(SoftwareVideoDecoder.rejectedSARMessage(
            frame: rational(0, 1), ctx: rational(0, 1), stream: rational(32, 11),
            width: 352, height: 576) == nil)
    }
}
