import Testing
import AetherLibavcodec

/// Proves the VC-1 parse context seeding (build.sh `patch_ffmpeg_vc1_parser`) is in the
/// shipped libavcodec and behaves as intended.
///
/// libavformat closes and reopens the parser on every reposition, so a seek hands
/// `vc1_parse` a zeroed `VC1Context`. Stock `vc1_parser.c` never seeds it from
/// `avctx->extradata`, so an entry point landing there is read at the wrong bit offset:
/// `hrd_full[]` precedes `coded_size_flag` only when the sequence header set
/// `hrd_param_flag`, which a zeroed context cannot know. The bit taken for
/// `coded_size_flag` is then the top bit of `hrd_full[0]`, the leaky bucket fullness at
/// that entry point, so a bucket below half falls back to a zero picture size
/// ("Picture size 0x0 is invalid") and one above half takes a coded size out of the
/// following payload (AetherEngine issue 490, FFmpeg PR 24458).
///
/// The BDUs below are synthetic and driven straight through `av_parser_parse2`, the same
/// entry point libavformat uses. The decoder is deliberately not opened: it seeds itself
/// from the same extradata and would hide what is being measured.
struct VC1ParserExtradataTests {

    // MARK: - Bitstream builders (layouts per vc1.c)

    private struct BitWriter {
        private var bits: [UInt8] = []

        mutating func put(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> shift) & 1))
            }
        }

        var bytes: [UInt8] {
            var out: [UInt8] = []
            var accumulator: UInt8 = 0
            var filled = 0
            for bit in bits {
                accumulator = (accumulator << 1) | bit
                filled += 1
                if filled == 8 {
                    out.append(accumulator)
                    accumulator = 0
                    filled = 0
                }
            }
            if filled > 0 { out.append(accumulator << (8 - filled)) }
            return out
        }
    }

    /// `AV_NOPTS_VALUE`, which does not survive the C macro import.
    private let noPTS = Int64.min

    private func bdu(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0x00, 0x00, 0x01, type] + payload
    }

    /// Advanced profile sequence header, 1920x1080, one HRD leaky bucket.
    /// The bucket is the point: it puts eight bits between the fixed entry point fields
    /// and `coded_size_flag`, and only this header says they are there.
    private var sequenceHeader: [UInt8] {
        var w = BitWriter()
        w.put(3, 2)             // profile: advanced
        w.put(0, 3)             // level
        w.put(1, 2)             // chromaformat: 4:2:0
        w.put(7, 3)             // frmrtq_postproc
        w.put(31, 5)            // bitrtq_postproc
        w.put(0, 1)             // postprocflag
        w.put(959, 12)          // max_coded_width:  (959 + 1) << 1 == 1920
        w.put(539, 12)          // max_coded_height: (539 + 1) << 1 == 1080
        w.put(0, 1)             // broadcast
        w.put(0, 1)             // interlace
        w.put(0, 1)             // tfcntrflag
        w.put(0, 1)             // finterpflag
        w.put(0, 1)             // reserved
        w.put(0, 1)             // psf
        w.put(0, 1)             // display info: absent
        w.put(1, 1)             // hrd_param_flag
        w.put(1, 5)             // hrd_num_leaky_buckets
        w.put(0, 4)             // bitrate exponent
        w.put(0, 4)             // buffer size exponent
        w.put(0x1234, 16)       // hrd_rate[0]
        w.put(0x5678, 16)       // hrd_buffer[0]
        return w.bytes
    }

    /// Entry point carrying no coded size of its own, so the picture size comes from the
    /// sequence header's `max_coded_width`/`max_coded_height`.
    ///
    /// - Parameter bucketFullness: `hrd_full[0]`. Its top bit is what an unseeded context
    ///   mistakes for `coded_size_flag`.
    private func entryPoint(bucketFullness: Int) -> [UInt8] {
        var w = BitWriter()
        w.put(0, 1)             // broken_link
        w.put(1, 1)             // closed_entry
        w.put(0, 1)             // panscanflag
        w.put(1, 1)             // refdist_flag
        w.put(1, 1)             // loop_filter
        w.put(0, 1)             // fastuvmc
        w.put(0, 1)             // extended_mv
        w.put(0, 2)             // dquant
        w.put(0, 1)             // vstransform
        w.put(0, 1)             // overlap
        w.put(0, 2)             // quantizer_mode
        w.put(bucketFullness, 8)
        w.put(0, 1)             // coded_size_flag
        w.put(0, 1)             // range_mapy_flag
        w.put(0, 1)             // range_mapuv_flag
        return w.bytes
    }

    /// What a seek lands on when the encoder does not repeat the sequence header: an entry
    /// point, then a frame. The frame payload only has to terminate the entry point BDU.
    private func landingPacket(bucketFullness: Int) -> [UInt8] {
        bdu(0x0E, entryPoint(bucketFullness: bucketFullness))
            + bdu(0x0D, [UInt8](repeating: 0x40, count: 32))
    }

    private var extradata: [UInt8] {
        bdu(0x0F, sequenceHeader) + bdu(0x0E, entryPoint(bucketFullness: 0x20))
    }

    // MARK: - Harness

    /// Parses one buffer with a freshly initialised parser, the state every seek produces,
    /// and reports the picture size the parser settled on.
    private func parseLanding(bucketFullness: Int) -> (width: Int32, height: Int32) {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_VC1),
              let ctx = avcodec_alloc_context3(codec) else {
            Issue.record("vc1 decoder unavailable")
            return (0, 0)
        }
        defer {
            var freed: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&freed)
        }

        let blob = extradata
        let padding = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buffer = av_malloc(blob.count + padding) else {
            Issue.record("av_malloc failed")
            return (0, 0)
        }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: blob.count + padding)
        blob.withUnsafeBufferPointer { source in
            buffer.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        ctx.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
        ctx.pointee.extradata_size = Int32(blob.count)

        guard let parser = av_parser_init(Int32(AV_CODEC_ID_VC1.rawValue)) else {
            Issue.record("vc1 parser unavailable")
            return (0, 0)
        }
        defer { av_parser_close(parser) }

        var packet = landingPacket(bucketFullness: bucketFullness)
        packet.append(contentsOf: [UInt8](repeating: 0, count: padding))
        packet.withUnsafeMutableBufferPointer { input in
            var out: UnsafeMutablePointer<UInt8>? = nil
            var outSize: Int32 = 0
            _ = av_parser_parse2(parser, ctx, &out, &outSize,
                                 input.baseAddress, Int32(input.count - padding),
                                 noPTS, noPTS, 0)
        }
        return (ctx.pointee.width, ctx.pointee.height)
    }

    // MARK: - Tests

    @Test("a seek landing on an entry point alone still resolves the picture size")
    func landingWithoutSequenceHeaderKeepsTheSize() {
        // hrd_full[0] below half full: unseeded, this reads coded_size_flag == 0 at the
        // wrong offset and falls back to a max_coded of 0x0.
        let size = parseLanding(bucketFullness: 0x20)
        #expect(size.width == 1920, "the parse context was not seeded from extradata")
        #expect(size.height == 1080)
    }

    @Test("the bucket fullness no longer decides the picture size")
    func landingIsIndependentOfBucketFullness() {
        // hrd_full[0] above half full: unseeded, this reads coded_size_flag == 1 and takes
        // a coded size out of the following payload, silently and without a log line.
        let size = parseLanding(bucketFullness: 0xA0)
        #expect(size.width == 1920, "the entry point was read at the wrong bit offset")
        #expect(size.height == 1080)
    }

    @Test("a landing that repeats the sequence header resolves too (fixture control)")
    func landingWithSequenceHeaderControl() {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_VC1),
              let ctx = avcodec_alloc_context3(codec),
              let parser = av_parser_init(Int32(AV_CODEC_ID_VC1.rawValue)) else {
            Issue.record("vc1 parser or decoder unavailable")
            return
        }
        defer {
            av_parser_close(parser)
            var freed: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&freed)
        }

        let padding = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        var packet = bdu(0x0F, sequenceHeader) + landingPacket(bucketFullness: 0x20)
        packet.append(contentsOf: [UInt8](repeating: 0, count: padding))
        packet.withUnsafeMutableBufferPointer { input in
            var out: UnsafeMutablePointer<UInt8>? = nil
            var outSize: Int32 = 0
            _ = av_parser_parse2(parser, ctx, &out, &outSize,
                                 input.baseAddress, Int32(input.count - padding),
                                 noPTS, noPTS, 0)
        }
        #expect(ctx.pointee.width == 1920, "the synthetic BDUs themselves are broken")
        #expect(ctx.pointee.height == 1080)
    }
}
