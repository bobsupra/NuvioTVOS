import Testing
import AetherLibavutil
@testable import AetherEngine

/// #452: a `SwrContext` reads a frame's planes per the input it was built for and revalidates
/// nothing. A live TS splice from 5.1 to stereo left the context reading six planes from a frame
/// that carries two, and `swr_convert` faulted on the first NULL one. These cover the rule that
/// decides when a persistent resampler has to be rebuilt, and what counts as a readable frame.
@Suite("Resampler input parameters (#452)")
struct ResamplerInputParametersTests {

    /// An AVFrame with the fields the rule reads. Buffers are allocated so `extended_data` carries
    /// real planes; `av_frame_free` releases them.
    private func makeFrame(
        channels: Int32,
        format: AVSampleFormat,
        rate: Int32,
        samples: Int32 = 1024
    ) -> UnsafeMutablePointer<AVFrame> {
        let frame = av_frame_alloc()!
        av_channel_layout_default(&frame.pointee.ch_layout, channels)
        frame.pointee.format = format.rawValue
        frame.pointee.sample_rate = rate
        frame.pointee.nb_samples = samples
        #expect(av_frame_get_buffer(frame, 0) >= 0)
        return frame
    }

    private func adopted(channels: Int32, format: AVSampleFormat, rate: Int32) -> ResamplerInputParameters {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, channels)
        defer { av_channel_layout_uninit(&layout) }
        var params = ResamplerInputParameters()
        params.adopt(layout: &layout, format: format, rate: rate)
        return params
    }

    @Test("a frame matching what the context was built for does not rebuild it")
    func unchangedFrameDoesNotRebuild() {
        var params = adopted(channels: 6, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        let frame = makeFrame(channels: 6, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            params.release()
        }
        #expect(params.differ(from: frame) == false)
    }

    @Test("the reported splice, 5.1 to stereo at one rate and format, is a change")
    func channelCountDropIsAChange() {
        var params = adopted(channels: 6, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        let frame = makeFrame(channels: 2, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            params.release()
        }
        #expect(params.differ(from: frame))
    }

    @Test("a sample rate change is a change, so an HE-AAC core rate does not pin the session")
    func sampleRateChangeIsAChange() {
        var params = adopted(channels: 2, format: AV_SAMPLE_FMT_FLTP, rate: 24_000)
        let frame = makeFrame(channels: 2, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            params.release()
        }
        #expect(params.differ(from: frame))
    }

    @Test("a sample format change is a change, planar float read as S32 is noise")
    func sampleFormatChangeIsAChange() {
        var params = adopted(channels: 2, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        let frame = makeFrame(channels: 2, format: AV_SAMPLE_FMT_S32P, rate: 48_000)
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            params.release()
        }
        #expect(params.differ(from: frame))
    }

    @Test("a layout change at the same channel count is a change")
    func sameCountDifferentLayoutIsAChange() {
        var configured = AVChannelLayout()
        #expect(av_channel_layout_from_string(&configured, "5.1") >= 0)
        var params = ResamplerInputParameters()
        params.adopt(layout: &configured, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        av_channel_layout_uninit(&configured)

        let frame = av_frame_alloc()!
        #expect(av_channel_layout_from_string(&frame.pointee.ch_layout, "5.1(side)") >= 0)
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = 48_000
        frame.pointee.nb_samples = 1024
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            params.release()
        }

        #expect(frame.pointee.ch_layout.nb_channels == 6)
        #expect(params.differ(from: frame))
    }

    @Test("a frame that states no layout does not rebuild the synthesised default on every frame")
    func unspecifiedLayoutDoesNotRebuild() {
        var params = adopted(channels: 2, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        let frame = av_frame_alloc()!
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = 48_000
        frame.pointee.nb_samples = 1024
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            params.release()
        }
        #expect(frame.pointee.ch_layout.nb_channels == 0)
        #expect(params.differ(from: frame) == false)
    }

    @Test("planar input reads one plane per channel, interleaved input reads one")
    func planeCountFollowsPlanarity() {
        var planar = adopted(channels: 6, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        var packed = adopted(channels: 6, format: AV_SAMPLE_FMT_FLT, rate: 48_000)
        defer {
            planar.release()
            packed.release()
        }
        #expect(planar.planeCount == 6)
        #expect(packed.planeCount == 1)
    }

    @Test("a frame missing a plane the context would read is refused instead of dereferenced")
    func missingPlaneIsRefused() {
        var params = adopted(channels: 6, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        let frame = makeFrame(channels: 6, format: AV_SAMPLE_FMT_FLTP, rate: 48_000)
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            params.release()
        }

        #expect(params.framePlanesArePresent(frame))

        // What a stereo frame looks like to a context built for 5.1: the planes above the second
        // are the NULLs swr_convert read in the crash.
        let saved = (2..<6).map { frame.pointee.extended_data[$0] }
        for i in 2..<6 { frame.pointee.extended_data[i] = nil }
        #expect(params.framePlanesArePresent(frame) == false)
        for (offset, plane) in saved.enumerated() { frame.pointee.extended_data[2 + offset] = plane }
    }
}
