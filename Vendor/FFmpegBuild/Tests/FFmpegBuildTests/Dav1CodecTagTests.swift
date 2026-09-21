import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Proves the dav1 sample entry (build.sh `patch_ffmpeg_dav1_tag`) is in the shipped
/// libavformat, in both directions.
///
/// MP4RA registers 'dav1' as the AV1 variant of 'av01' that signals Dolby Vision, and
/// Dolby Vision Profile 10.0 needs it: the AV1 counterpart of HEVC Profile 5, an
/// IPT-PQ-c2 signal with no compatible base layer, so 'av01' is not an alternative.
/// Stock FFmpeg carries the tag in neither of its two mp4 tag tables, so a file written
/// with it reads back as "unknown codec" and a requested tag is rejected by
/// validate_codec_tag(), leaving avformat_write_header with EINVAL (AetherEngine #547).
///
/// The write side is measured through the real mp4 muxer, the same call the HLS-fMP4
/// producer makes. The read side is measured through av_codec_get_id() on the muxer's
/// own tag table, which is the mapping mov.c performs on a sample entry.
struct Dav1CodecTagTests {

    private static let dav1: UInt32 = 0x3176_6164  // 'dav1', little endian as MKTAG builds it
    private static let av01: UInt32 = 0x3130_7661  // 'av01'

    /// A minimal AV1 codecpar carrying real av1C extradata (320x240 10-bit, SVT-AV1).
    /// The muxer writes the av1C box from it, so a header written without one would
    /// prove nothing about the sample entry.
    private static func makeAV1Codecpar() -> UnsafeMutablePointer<AVCodecParameters> {
        let av1C: [UInt8] = [
            0x81, 0x00, 0x4c, 0x00, 0x0a, 0x0b, 0x00, 0x00,
            0x00, 0x04, 0x3c, 0xff, 0xbc, 0x02, 0xf8, 0x40, 0x40
        ]
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = AV_CODEC_ID_AV1
        par.pointee.width = 320
        par.pointee.height = 240
        par.pointee.format = Int32(AV_PIX_FMT_YUV420P10LE.rawValue)
        let extra = av_malloc(av1C.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!
        memset(extra, 0, av1C.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))
        av1C.withUnsafeBytes { _ = memcpy(extra, $0.baseAddress!, av1C.count) }
        par.pointee.extradata = extra.assumingMemoryBound(to: UInt8.self)
        par.pointee.extradata_size = Int32(av1C.count)
        return par
    }

    /// Writes an mp4 header for an AV1 track with the given codec tag, into a discarded
    /// in-memory sink. Returns the avformat_write_header result.
    private static func writeHeader(tag: UInt32) -> Int32 {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ctxOut, nil, "mp4", "probe.mp4") == 0,
              let ctx = ctxOut else { return -1 }
        defer { avformat_free_context(ctx) }

        var pb: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&pb) >= 0, let sink = pb else { return -1 }
        ctx.pointee.pb = sink
        defer {
            var buf: UnsafeMutablePointer<UInt8>?
            _ = avio_close_dyn_buf(sink, &buf)
            if buf != nil { av_free(buf) }
        }

        guard let stream = avformat_new_stream(ctx, nil) else { return -1 }
        var par: UnsafeMutablePointer<AVCodecParameters>? = makeAV1Codecpar()
        defer { avcodec_parameters_free(&par) }
        guard avcodec_parameters_copy(stream.pointee.codecpar, par!) >= 0 else { return -1 }
        stream.pointee.codecpar.pointee.codec_tag = tag
        stream.pointee.time_base = AVRational(num: 1, den: 24_000)

        return avformat_write_header(ctx, nil)
    }

    @Test("the mp4 muxer writes a dav1 sample entry")
    func muxerAcceptsDav1() {
        // Stock FFmpeg returns -22 (EINVAL): validate_codec_tag() finds no dav1 for AV1.
        #expect(Self.writeHeader(tag: Self.dav1) == 0)
    }

    @Test("the av01 sample entry is untouched next to it")
    func muxerAcceptsAv01() {
        #expect(Self.writeHeader(tag: Self.av01) == 0)
    }

    @Test("a dav1 sample entry maps back to AV1 on the way in")
    func demuxerResolvesDav1() {
        guard let mp4 = av_guess_format("mp4", nil, nil), let tags = mp4.pointee.codec_tag else {
            Issue.record("no mp4 muxer in the shipped libavformat")
            return
        }
        // Stock FFmpeg resolves this to AV_CODEC_ID_NONE, which is the "unknown codec"
        // a dav1 file probes as.
        #expect(av_codec_get_id(tags, Self.dav1) == AV_CODEC_ID_AV1)
        #expect(av_codec_get_id(tags, Self.av01) == AV_CODEC_ID_AV1)
    }
}
