import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// #142: PGS carries no end time, a cue is closed by the start of its successor. When a display set
/// references a palette the decoder does not have, stock pgssubdec drops the whole set, so the
/// successor that would have closed the previous cue disappears with it and the predecessor
/// overstays its authored end. FFmpegBuild carries a pgssubdec patch that returns the empty subtitle
/// at that branch instead (outside AV_EF_EXPLODE), which closes the predecessor at the authored time
/// without inventing a rendering the damaged set never conveyed.
///
/// FFmpegBuild 2.1.1 through 2.4.1 repaired the same symptom by keeping the palette and object caches
/// across composition state 3 (Epoch Continue) so a bare PCS+WDS+END set rendered from retained
/// state. That was withdrawn in 2.4.2: the caches are fixed arrays bounded by a COUNT
/// (MAX_EPOCH_OBJECTS 64), so retained pre-connection objects occupy the slots a self-contained
/// connection set needs and a conformant set conveying a new object id was rejected outright. See
/// FFmpeg PR 23851.
///
/// These tests drive the shipped Libavcodec pgssub decoder directly with synthetic display sets, the
/// same call path EmbeddedSubtitleDecoder uses. They exist here to guard the FFmpegBuild pin: an
/// engine built against a package without the patch fails them.
struct Issue142PGSEpochContinueTests {

    // MARK: - Segment builders (layouts per pgssubdec.c parsers)

    /// A PGS segment run: each segment is [type:1][len:2 BE][body:len].
    private func segment(type: UInt8, body: [UInt8]) -> [UInt8] {
        [type, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    /// PCS (0x16): 1920x1080, one composition object referencing object 0 / palette 0 at (100,100).
    private func pcs(compositionState: UInt8) -> [UInt8] {
        segment(type: 0x16, body: [
            0x07, 0x80, 0x04, 0x38,             // width 1920, height 1080
            0x10,                               // frame rate (opaque to the decoder)
            0x00, 0x01,                         // composition number
            compositionState,
            0x00,                               // palette_update_flag
            0x00,                               // palette_id 0
            0x01,                               // one composition object
            0x00, 0x00,                         // object id 0
            0x00,                               // window id 0
            0x00,                               // composition flags (no crop, not forced)
            0x00, 0x64, 0x00, 0x64,             // x 100, y 100
        ])
    }

    /// WDS (0x17): one 8x8 window at (100,100). pgssubdec skips it; present for stream shape fidelity.
    private var wds: [UInt8] {
        segment(type: 0x17, body: [0x01, 0x00, 0x00, 0x64, 0x00, 0x64, 0x00, 0x08, 0x00, 0x08])
    }

    /// PDS (0x14): palette 0 with entry 0 transparent and entry 1 opaque white.
    private var pds: [UInt8] {
        segment(type: 0x14, body: [
            0x00, 0x00,                         // palette id 0, version 0
            0x00, 0x10, 0x80, 0x80, 0x00,       // entry 0: transparent
            0x01, 0xEB, 0x80, 0x80, 0xFF,       // entry 1: opaque white
        ])
    }

    /// ODS (0x15): object 0, single-segment (first+last), 8x8 bitmap of palette entry 1.
    /// RLE per line: 0x00 0x88 0x01 (run of 8, color 1) then 0x00 0x00 (end of line) = 5 bytes x 8 lines.
    private var ods: [UInt8] {
        let rle = Array(repeating: [0x00, 0x88, 0x01, 0x00, 0x00] as [UInt8], count: 8).flatMap { $0 }
        return segment(type: 0x15, body: [
            0x00, 0x00,                         // object id 0
            0x00,                               // version
            0xC0,                               // sequence: first and last
            0x00, 0x00, 0x2C,                   // rle length 44 (40 RLE + 4 dimension bytes)
            0x00, 0x08, 0x00, 0x08,             // width 8, height 8
        ] + rle)
    }

    private var end: [UInt8] { segment(type: 0x80, body: []) }

    /// The anchor: a self-contained Epoch Start display set (PCS+WDS+PDS+ODS+END).
    private var epochStartSet: [UInt8] { pcs(compositionState: 0x80) + wds + pds + ods + end }

    /// A bare follow-up set: PCS+WDS+END only, palette/objects expected from retained state.
    private func bareSet(compositionState: UInt8) -> [UInt8] { pcs(compositionState: compositionState) + wds + end }

    // MARK: - Decoder harness

    private func withPGSDecoder(errorRecognition: Int32 = 0,
                                _ body: (UnsafeMutablePointer<AVCodecContext>) -> Void) {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE),
              let ctx = avcodec_alloc_context3(codec) else {
            Issue.record("pgssub decoder unavailable")
            return
        }
        ctx.pointee.err_recognition = errorRecognition
        // Without a packet time base avcodec_decode_subtitle2 leaves sub->pts unset, and the
        // clearing cue's timestamp is what closes the predecessor.
        ctx.pointee.pkt_timebase = AVRational(num: 1, den: 90_000)
        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            Issue.record("avcodec_open2 failed for pgssub")
            return
        }
        body(ctx)
        var freed: UnsafeMutablePointer<AVCodecContext>? = ctx
        avcodec_free_context(&freed)
    }

    @discardableResult
    private func decode(_ ctx: UnsafeMutablePointer<AVCodecContext>, _ payload: [UInt8],
                        pts: Int64, into sub: inout AVSubtitle) -> Int32 {
        var got: Int32 = 0
        var bytes = payload
        bytes.withUnsafeMutableBufferPointer { buffer in
            var packet = AVPacket()
            packet.data = buffer.baseAddress
            packet.size = Int32(buffer.count)
            packet.pts = pts
            _ = avcodec_decode_subtitle2(ctx, &sub, &got, &packet)
        }
        return got
    }

    // MARK: - Tests

    @Test("a bare Epoch-Continue set emits a clearing cue at its own pts")
    func bareEpochContinueEmitsClearingCue() {
        withPGSDecoder { ctx in
            var sub = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &sub) == 1)
            #expect(sub.num_rects == 1)
            avsubtitle_free(&sub)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0xC0), pts: 90_000, into: &continued)
            #expect(got == 1, "the damaged set was dropped, so the predecessor cue overstays")
            #expect(continued.num_rects == 0, "a set that conveys nothing must not render")
            // 90000 ticks of 1/90000 rescaled to AV_TIME_BASE_Q (microseconds).
            #expect(continued.pts == 1_000_000, "the clearing cue must carry the successor's pts")
            avsubtitle_free(&continued)
        }
    }

    @Test("the recovery is not scoped to Epoch Continue")
    func recoveryAppliesToEveryDamagedSet() {
        withPGSDecoder { ctx in
            var sub = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &sub) == 1)
            avsubtitle_free(&sub)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0x80), pts: 90_000, into: &continued)
            #expect(got == 1)
            #expect(continued.num_rects == 0)
            avsubtitle_free(&continued)
        }
    }

    @Test("AV_EF_EXPLODE still rejects the damaged set")
    func explodeStillRejects() {
        withPGSDecoder(errorRecognition: AV_EF_EXPLODE) { ctx in
            var sub = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &sub) == 1)
            avsubtitle_free(&sub)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0xC0), pts: 90_000, into: &continued)
            #expect(got == 0, "strict error recognition must keep rejecting the set")
            if got == 1 { avsubtitle_free(&continued) }
        }
    }

    @Test("a bare Normal set already renders from retained state (fixture control)")
    func bareNormalSetControl() {
        withPGSDecoder { ctx in
            var sub = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &sub) == 1)
            avsubtitle_free(&sub)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0x00), pts: 90_000, into: &continued)
            #expect(got == 1, "bare Normal set failed; the synthetic fixture itself is broken")
            #expect(continued.num_rects == 1)
            if got == 1 { avsubtitle_free(&continued) }
        }
    }
}
