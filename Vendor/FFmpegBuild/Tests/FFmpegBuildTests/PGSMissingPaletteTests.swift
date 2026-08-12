import Testing
import AetherLibavcodec

/// Proves the `pgs-missing-palette` patch (build.sh `patch_ffmpeg_pgssub`) is in the
/// shipped libavcodec and behaves as intended.
///
/// PGS carries no end time, a cue is closed by the start of its successor. Stock
/// pgssubdec drops a display set whose referenced palette is not cached, so the
/// successor that would have closed the previous cue disappears with it and the
/// predecessor overstays its authored end (AetherEngine issue 142). The patch returns
/// the empty subtitle instead, outside `AV_EF_EXPLODE`.
///
/// The sets below are synthetic and driven straight through
/// `avcodec_decode_subtitle2`, the same entry point AetherEngine's decoders use.
struct PGSMissingPaletteTests {

    // MARK: - Segment builders (layouts per pgssubdec.c parsers)

    /// A PGS segment: [type:1][len:2 BE][body:len].
    private func segment(type: UInt8, body: [UInt8]) -> [UInt8] {
        [type, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    /// PCS (0x16): 1920x1080, one composition object referencing object 0 / palette 0.
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

    /// WDS (0x17): one 8x8 window at (100,100). pgssubdec skips it; present for stream shape.
    private var wds: [UInt8] {
        segment(type: 0x17, body: [0x01, 0x00, 0x00, 0x64, 0x00, 0x64, 0x00, 0x08, 0x00, 0x08])
    }

    /// PDS (0x14): palette 0, entry 0 transparent, entry 1 opaque white.
    private var pds: [UInt8] {
        segment(type: 0x14, body: [
            0x00, 0x00,
            0x00, 0x10, 0x80, 0x80, 0x00,
            0x01, 0xEB, 0x80, 0x80, 0xFF,
        ])
    }

    /// ODS (0x15): object 0, single segment, 8x8 bitmap of palette entry 1.
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

    /// A self-contained Epoch Start set (PCS+WDS+PDS+ODS+END).
    private var epochStartSet: [UInt8] { pcs(compositionState: 0x80) + wds + pds + ods + end }

    /// A bare follow-up set: PCS+WDS+END, palette and object expected from decoder state.
    private func bareSet(compositionState: UInt8) -> [UInt8] {
        pcs(compositionState: compositionState) + wds + end
    }

    // MARK: - Harness

    private func withPGSDecoder(errorRecognition: Int32 = 0,
                                _ body: (UnsafeMutablePointer<AVCodecContext>) -> Void) {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE),
              let ctx = avcodec_alloc_context3(codec) else {
            Issue.record("pgssub decoder unavailable")
            return
        }
        ctx.pointee.err_recognition = errorRecognition
        // Without a packet time base avcodec_decode_subtitle2 leaves sub->pts unset,
        // and the clearing cue's timestamp is the whole point of the patch.
        ctx.pointee.pkt_timebase = AVRational(num: 1, den: 90_000)
        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            Issue.record("avcodec_open2 failed for pgssub")
            return
        }
        body(ctx)
        var freed: UnsafeMutablePointer<AVCodecContext>? = ctx
        avcodec_free_context(&freed)
    }

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

    @Test("a display set without its palette yields an empty subtitle at its own pts")
    func missingPaletteClosesPredecessor() {
        withPGSDecoder { ctx in
            var anchor = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &anchor) == 1)
            #expect(anchor.num_rects == 1)
            avsubtitle_free(&anchor)

            // Epoch Continue flushes the caches, so this set loses the palette it references.
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
    func missingPaletteRecoveryAppliesToEveryDamagedSet() {
        withPGSDecoder { ctx in
            var anchor = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &anchor) == 1)
            avsubtitle_free(&anchor)

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
            var anchor = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &anchor) == 1)
            avsubtitle_free(&anchor)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0xC0), pts: 90_000, into: &continued)
            #expect(got == 0, "strict error recognition must keep rejecting the set")
            if got == 1 { avsubtitle_free(&continued) }
        }
    }

    @Test("a bare Normal set still renders from retained state (fixture control)")
    func bareNormalSetControl() {
        withPGSDecoder { ctx in
            var anchor = AVSubtitle()
            #expect(decode(ctx, epochStartSet, pts: 0, into: &anchor) == 1)
            avsubtitle_free(&anchor)

            var continued = AVSubtitle()
            let got = decode(ctx, bareSet(compositionState: 0x00), pts: 90_000, into: &continued)
            #expect(got == 1, "a bare Normal set failed; the synthetic fixture itself is broken")
            #expect(continued.num_rects == 1)
            if got == 1 { avsubtitle_free(&continued) }
        }
    }
}
