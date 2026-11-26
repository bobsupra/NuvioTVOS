import Testing
import AetherLibavcodec

/// Proves the VC-1 frame threading patch (build.sh `patch_ffmpeg_vc1_frame_threads`)
/// is in the shipped libavcodec.
///
/// Upstream's `vc1` and `wmv3` decoders declare no threading capability, so a host
/// that asks for frame threads silently decodes on one thread. The patch adds
/// `AV_CODEC_CAP_FRAME_THREADS` to both. The image variants `vc1image` and `wmv3image`
/// keep their single thread, and this build does not enable them.
///
/// That the threaded output equals the single-threaded output needs real VC-1, and
/// FFmpeg has no VC-1 encoder to make a fixture with. So it was checked outside this
/// suite, with FATE's vc1, wmv3-drm and mss2 tests at 1 to 16 frame threads, frame
/// hashes across repeated seeks, and Blu-ray VC-1 at 2 to 8 threads (AetherEngine
/// issue 1107).
struct VC1FrameThreadingTests {

    @Test("vc1 and wmv3 decode with frame threads")
    func vc1DecodersAreFrameThreaded() throws {
        for name in ["vc1", "wmv3"] {
            let codec = try #require(avcodec_find_decoder_by_name(name), "\(name) missing")
            #expect(codec.pointee.capabilities & AV_CODEC_CAP_FRAME_THREADS != 0,
                    "\(name) does not declare frame threading")
        }
    }

    @Test("an opened vc1 decoder takes the frame threads it is given")
    func vc1DecoderOpensFrameThreaded() throws {
        // A minimal Advanced Profile sequence header and entry point for 64x64.
        try openFrameThreaded("vc1", width: 64, height: 64, extradata: [
            0x00, 0x00, 0x01, 0x0F, 0xDB, 0xFE, 0x01, 0x1F, 0xC3, 0xF0, 0x80,
            0x00, 0x00, 0x01, 0x0E, 0x5A, 0xE7, 0xF8, 0x00, 0x00, 0x00, 0x00,
        ])
    }

    @Test("an opened wmv3 decoder takes the frame threads it is given")
    func wmv3DecoderOpensFrameThreaded() throws {
        // The Main Profile sequence header of FATE's vc1/SMM0005.rcv (720x480).
        try openFrameThreaded("wmv3", width: 720, height: 480,
                              extradata: [0x4D, 0xF1, 0x0A, 0x11])
    }

    /// The decoders refuse to open without extradata, so each test hands one in.
    private func openFrameThreaded(_ name: String, width: Int32, height: Int32,
                                   extradata: [UInt8]) throws {
        let codec = try #require(avcodec_find_decoder_by_name(name))
        var ctx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        let c = try #require(ctx)
        let buf = try #require(av_mallocz(extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
        buf.copyMemory(from: extradata, byteCount: extradata.count)
        c.pointee.extradata = buf.assumingMemoryBound(to: UInt8.self)
        c.pointee.extradata_size = Int32(extradata.count)
        c.pointee.width = width
        c.pointee.height = height
        c.pointee.thread_count = 4
        c.pointee.thread_type = FF_THREAD_FRAME
        #expect(avcodec_open2(c, codec, nil) == 0, "\(name) did not open")
        #expect(c.pointee.active_thread_type == FF_THREAD_FRAME,
                "\(name) did not take frame threads")
    }
}
