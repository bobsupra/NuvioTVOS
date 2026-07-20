import Testing
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// Regression: bwdif/yadif halve the filter output time_base and double PTS. The filter exposes
/// that sink time_base as `outputTimeBase` and the decoder timestamps filtered frames with it
/// (rescaling back into the stream base is WRONG under mode=send_field: the two fields of a frame
/// sit on odd/even ticks of the halved base and would collapse to duplicate integer PTS).
/// This test pins the invariant that output PTS converted through `outputTimeBase` lands on the
/// source's real-time axis, the original bug was playback at half speed + resume freezes.
struct DeinterlaceTimebaseTests {

    private func makeFrame(pts: Int64) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = 64
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = pts
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    @Test("Software deinterlaced PTS via outputTimeBase stays on the stream's time axis (no 2x drift)")
    func deinterlacedPTSMatchesStreamTimebase() {
        // 1 tick == 1/30 s; source PTS N must emerge at N/30 seconds when converted through
        // the filter's outputTimeBase (NOT the stream time_base, bwdif halves it).
        let streamTB = AVRational(num: 1, den: 30)
        let tbSeconds = Double(streamTB.num) / Double(streamTB.den)

        let filter = DeinterlaceFilter()
        // Force the CPU engine: this regression is about the sw bwdif/yadif time_base contract,
        // and must stay deterministic whether or not the linked build ships yadif_videotoolbox.
        filter.config = DeinterlaceConfig(mode: .software)
        defer { filter.teardown() }

        let inputPTS: [Int64] = [0, 1, 2, 3, 4, 5, 6, 7]
        var outSeconds: [Double] = []

        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }

        for pts in inputPTS {
            let f = makeFrame(pts: pts)
            let built = filter.ensureGraph(frame: f, timeBase: streamTB)
            #expect(built, "bwdif/yadif must be available in the linked FFmpeg build")
            guard built else { var ff: UnsafeMutablePointer<AVFrame>? = f; av_frame_free(&ff); return }

            #expect(filter.push(f) >= 0)
            var ff: UnsafeMutablePointer<AVFrame>? = f
            av_frame_free(&ff)

            let outTB = filter.outputTimeBase
            let outTBSeconds = Double(outTB.num) / Double(outTB.den)
            while filter.pull(into: out) >= 0 {
                if out.pointee.pts != Int64.min {
                    outSeconds.append(Double(out.pointee.pts) * outTBSeconds)
                }
                av_frame_unref(out)
            }
        }

        #expect(!outSeconds.isEmpty, "filter produced no frames")

        // Pre-fix outputs ran to ~14/30 s (2x). Deinterlacer holds one frame of lookahead.
        let maxInput = Double(inputPTS.max()!) * tbSeconds
        for s in outSeconds {
            #expect(s <= maxInput + tbSeconds * 0.5,
                    "output PTS \(s)s exceeds source range (max \(maxInput)s), time_base drift")
        }

        // send_frame: one output per input, so spacing stays at the frame interval.
        let sorted = outSeconds.sorted()
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let delta = sorted[i] - sorted[i - 1]
                #expect(abs(delta - tbSeconds) < tbSeconds * 0.25,
                        "frame spacing \(delta)s is not ~\(tbSeconds)s (time_base drift)")
            }
        }
    }
}
