import Testing
import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#923: a channel cap, a dialogue lift and night-mode compression, applied to decoded PCM on the
/// bridge (loopback) and the software decoder.
///
/// The end-to-end checks drive a 5.1 fixture that puts a 1 kHz tone on the front centre only and a
/// 250 Hz tone on every other channel, so "the dialogue got louder" is a measured ratio between two
/// frequencies rather than a level that a fold or a limiter could also have moved.
@Suite("AE#923 audio shaping", .serialized)
struct AudioShapingTests {

    // MARK: - The value

    @Test("the default shapes nothing, and a cap of 8 is no cap")
    func defaultIsInactive() {
        #expect(!AudioShaping().isActive)
        #expect(!AudioShaping(maxChannels: 8).isActive)
        #expect(!AudioShaping(maxChannels: 12).isActive)
        #expect(AudioShaping(maxChannels: 2).isActive)
        #expect(AudioShaping(dialogueGainDB: 3).isActive)
        #expect(AudioShaping(compressor: .night).isActive)
    }

    @Test("every field is clamped, and a non-finite value takes the neutral end")
    func clamping() {
        let c = AudioShaping(maxChannels: 0, dialogueGainDB: 40,
                             compressor: .init(thresholdDB: -100, ratio: .nan, makeupGainDB: 99)).clamped
        #expect(c.maxChannels == 1)
        #expect(c.dialogueGainDB == AudioShaping.maxDialogueGainDB)
        #expect(c.compressor?.thresholdDB == -60)
        #expect(c.compressor?.ratio == 1)
        #expect(c.compressor?.makeupGainDB == 24)
        #expect(AudioShaping(dialogueGainDB: -6).clamped.dialogueGainDB == 0)
        #expect(LoadOptions(audioShaping: AudioShaping(dialogueGainDB: 40)).audioShaping.dialogueGainDB
                == AudioShaping.maxDialogueGainDB)
    }

    @Test("a cap never upmixes")
    func capNeverUpmixes() {
        let cap = AudioShaping(maxChannels: 6)
        #expect(cap.outputChannels(forSource: 8) == 6)
        #expect(cap.outputChannels(forSource: 2) == 2)
        #expect(AudioShaping().outputChannels(forSource: 8) == 8)
    }

    @Test("the state is off without shaping, and follows the pipeline's report with it")
    func stateDerivation() {
        let on = AudioShaping(compressor: .night)
        #expect(AudioShapingState.derive(shaping: AudioShaping(), pipelineApplies: true) == .off)
        #expect(AudioShapingState.derive(shaping: on, pipelineApplies: nil) == .off)
        #expect(AudioShapingState.derive(shaping: on, pipelineApplies: true) == .applied)
        #expect(AudioShapingState.derive(shaping: on, pipelineApplies: false) == .unavailable)
    }

    // MARK: - The matrix

    private func withLayouts<T>(_ input: String, _ output: String,
                                _ body: (UnsafePointer<AVChannelLayout>, UnsafePointer<AVChannelLayout>) -> T) -> T {
        var i = AVChannelLayout(), o = AVChannelLayout()
        defer { av_channel_layout_uninit(&i); av_channel_layout_uninit(&o) }
        _ = av_channel_layout_from_string(&i, input)
        _ = av_channel_layout_from_string(&o, output)
        return body(&i, &o)
    }

    @Test("same layout and no lift leaves libswresample's default in place")
    func identityIsNil() {
        #expect(withLayouts("5.1", "5.1") { AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: 1) } == nil)
    }

    @Test("a 5.1 fold to stereo raises only the centre column")
    func foldLiftsCentreColumn() throws {
        let plain = try #require(withLayouts("5.1", "stereo") {
            AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: 1) })
        let lifted = try #require(withLayouts("5.1", "stereo") {
            AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: 2) })
        // 5.1 order: FL FR FC LFE BL BR (or SL SR); FC is input 2.
        for o in 0..<2 {
            for i in 0..<6 {
                let expected = i == 2 ? plain[o * 6 + i] * 2 : plain[o * 6 + i]
                #expect(abs(lifted[o * 6 + i] - expected) < 1e-12, "out \(o) in \(i)")
            }
        }
        #expect(abs(plain[0 * 6 + 2] - M_SQRT1_2) < 1e-9, "libswresample's -3 dB centre level")
        #expect(plain[0 * 6 + 3] == 0, "LFE stays out of the fold")
    }

    @Test("a stereo source gets a mid lift, which leaves the side signal alone")
    func stereoMidLift() throws {
        let g = 2.0
        let m = try #require(withLayouts("stereo", "stereo") {
            AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: g) })
        // Mid (L = R = 1) comes out at g, side (L = 1, R = -1) at 1.
        #expect(abs((m[0] + m[1]) - g) < 1e-12)
        #expect(abs((m[0] - m[1]) - 1) < 1e-12)
        #expect(abs((m[2] + m[3]) - g) < 1e-12)
        #expect(abs((m[3] - m[2]) - 1) < 1e-12)
    }

    @Test("an unspecified order reads as the default order for its channel count")
    func unspecifiedOrder() throws {
        var i = AVChannelLayout(), o = AVChannelLayout()
        defer { av_channel_layout_uninit(&i); av_channel_layout_uninit(&o) }
        i.order = AV_CHANNEL_ORDER_UNSPEC
        i.nb_channels = 6
        av_channel_layout_default(&o, 2)
        let m = try #require(AudioShapingMatrix.coefficients(input: &i, output: &o, dialogueGain: 2))
        #expect(abs(m[2] - 2 * M_SQRT1_2) < 1e-9, "FC found at index 2 of the default 5.1 order")
    }

    // MARK: - The dynamics

    @Test("the static curve: unity below the knee, the ratio above it, continuous through it")
    func staticCurve() {
        let k = AudioShaping.Compressor(thresholdDB: -30, ratio: 4, kneeDB: 6)
        #expect(AudioDynamicsProcessor.staticCurve(inputDB: -50, compressor: k) == -50)
        #expect(abs(AudioDynamicsProcessor.staticCurve(inputDB: -10, compressor: k) - (-25)) < 1e-12)
        let below = AudioDynamicsProcessor.staticCurve(inputDB: -33.0001, compressor: k)
        let above = AudioDynamicsProcessor.staticCurve(inputDB: -26.9999, compressor: k)
        #expect(abs(below - (-33.0001)) < 1e-3)
        #expect(abs(above - (-30 + 3.0 / 4)) < 1e-3)
    }

    private func sine(amplitude: Float, frames: Int, channels: Int, rate: Double = 48_000,
                      hz: Double = 1000) -> [Float] {
        var s = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = amplitude * Float(sin(2 * .pi * hz * Double(f) / rate))
            for c in 0..<channels { s[f * channels + c] = v }
        }
        return s
    }

    private func peak(_ s: ArraySlice<Float>) -> Float { s.map { abs($0) }.max() ?? 0 }

    @Test("the limiter holds every sample under the ceiling, from the first one")
    func limiterHoldsCeiling() {
        var p = AudioDynamicsProcessor(compressor: nil, sampleRate: 48_000)
        var s = sine(amplitude: 2.5, frames: 4800, channels: 2)
        s.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: 4800, channels: 2) }
        let ceiling = Float(pow(10, AudioDynamicsProcessor.ceilingDBFS / 20))
        #expect(peak(s[...]) <= ceiling + 1e-6)
    }

    @Test("night mode brings a loud passage down and a quiet one up")
    func nightNarrowsTheRange() {
        func settledPeakDB(amplitude: Float) -> Double {
            var p = AudioDynamicsProcessor(compressor: .night, sampleRate: 48_000)
            var s = sine(amplitude: amplitude, frames: 48_000, channels: 2)
            s.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: 48_000, channels: 2) }
            return 20 * log10(Double(peak(s[(s.count - 9600)...])))
        }
        let loud = settledPeakDB(amplitude: 1)          // 0 dBFS in
        let quiet = settledPeakDB(amplitude: 0.01)      // -40 dBFS in
        #expect(loud < -10 && loud > -15, "0 dBFS comes down to about -12.5, got \(loud)")
        #expect(quiet > -31 && quiet < -29, "-40 dBFS comes up to -30, got \(quiet)")
    }

    @Test("reset forgets the gain the previous passage left behind")
    func resetForgets() {
        var p = AudioDynamicsProcessor(compressor: .night, sampleRate: 48_000)
        var loud = sine(amplitude: 1, frames: 48_000, channels: 1)
        loud.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: 48_000, channels: 1) }
        p.reset()
        var quiet = sine(amplitude: 0.01, frames: 48, channels: 1)
        quiet.withUnsafeMutableBufferPointer { p.process($0.baseAddress!, frames: 48, channels: 1) }
        // A fresh processor starts at unity compressor gain plus the makeup; a stale one would still
        // be ~22 dB into gain reduction.
        #expect(peak(quiet[...]) > 0.02)
    }

    // MARK: - End to end

    /// 16-bit WAV, `channels` wide: a 1 kHz tone on channel 2 (the front centre of a 5.1 default
    /// order) and a 250 Hz tone on every other channel, each at `amplitude` of full scale.
    private func makeDialogueWAV(channels: Int, seconds: Double = 0.5, amplitude: Double = 0.25) -> Data {
        let rate = 48_000
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let t = Double(n) / Double(rate)
            let dialogue = Int16(amplitude * 32767 * sin(2 * .pi * 1000 * t))
            let score = Int16(amplitude * 32767 * sin(2 * .pi * 250 * t))
            for c in 0..<channels {
                let v = (channels > 2 && c == 2) ? dialogue : score
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate))
        u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// Goertzel magnitude of `hz` over `samples`.
    private func level(_ samples: [Float], hz: Double, rate: Double = 48_000) -> Double {
        let w = 2 * .pi * hz / rate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = Double(x) + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        return sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2) / Double(samples.count)
    }

    private func withAudioStream(_ wav: Data,
                                 _ body: (UnsafeMutablePointer<AVStream>, [UnsafeMutablePointer<AVPacket>]) throws -> Void) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: wav))
        let idx = demuxer.audioStreamIndex
        let stream = try #require(idx >= 0 ? demuxer.stream(at: idx) : nil)
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in packets { var pp: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&pp) } }
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == idx { packets.append(packet) } else {
                var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p)
            }
        }
        try body(stream, packets)
    }

    /// Runs the fixture through a bridge and decodes what it encoded, channel 0 only.
    private func bridgedLeftChannel(sourceChannels: Int, shaping: AudioShaping,
                                    amplitude: Double = 0.25) throws -> (codec: AVCodecID, channels: Int32, left: [Float]) {
        var result: (AVCodecID, Int32, [Float]) = (AV_CODEC_ID_NONE, 0, [])
        try withAudioStream(makeDialogueWAV(channels: sourceChannels, amplitude: amplitude)) { stream, packets in
            let bridge = try AudioBridge(srcCodecpar: stream.pointee.codecpar, srcTimeBase: stream.pointee.time_base,
                                         mode: .surroundCompat, shaping: shaping)
            defer { bridge.close() }
            let cp = try #require(bridge.encoderCodecpar)
            var encoded: [UnsafeMutablePointer<AVPacket>] = []
            defer { for o in encoded { var oo: UnsafeMutablePointer<AVPacket>? = o; trackedPacketFree(&oo) } }
            for p in packets { encoded.append(contentsOf: try bridge.feed(packet: p)) }
            encoded.append(contentsOf: bridge.flush())

            let codec = try #require(avcodec_find_decoder(cp.pointee.codec_id))
            var ctx = avcodec_alloc_context3(codec)
            defer { avcodec_free_context(&ctx) }
            let dec = try #require(ctx)
            _ = avcodec_parameters_to_context(dec, cp)
            dec.pointee.request_sample_fmt = AV_SAMPLE_FMT_FLT
            #expect(avcodec_open2(dec, codec, nil) >= 0)
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame) }
            var left: [Float] = []
            for pkt in encoded {
                _ = avcodec_send_packet(dec, pkt)
                while avcodec_receive_frame(dec, frame) >= 0, let f = frame {
                    let n = Int(f.pointee.nb_samples)
                    let ch = Int(f.pointee.ch_layout.nb_channels)
                    let fmt = AVSampleFormat(rawValue: f.pointee.format)
                    for i in 0..<n {
                        switch fmt {
                        case AV_SAMPLE_FMT_S16:
                            left.append(Float(f.pointee.data.0!.withMemoryRebound(to: Int16.self, capacity: n * ch) { $0[i * ch] }) / 32768)
                        case AV_SAMPLE_FMT_S32:
                            left.append(Float(f.pointee.data.0!.withMemoryRebound(to: Int32.self, capacity: n * ch) { $0[i * ch] }) / 2147483648)
                        case AV_SAMPLE_FMT_FLTP:
                            left.append(f.pointee.data.0!.withMemoryRebound(to: Float.self, capacity: n) { $0[i] })
                        default:
                            left.append(f.pointee.data.0!.withMemoryRebound(to: Float.self, capacity: n * ch) { $0[i * ch] })
                        }
                    }
                }
            }
            result = (cp.pointee.codec_id, cp.pointee.ch_layout.nb_channels, left)
        }
        return result
    }

    @Test("a 5.1 source capped to stereo is bridged as stereo FLAC, not stereo E-AC-3")
    func capPicksTheStereoEncoder() throws {
        let out = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2))
        #expect(out.codec == AV_CODEC_ID_FLAC)
        #expect(out.channels == 2)
        #expect(!out.left.isEmpty)
    }

    @Test("the dialogue lift raises the centre against the rest in the bridged fold")
    func bridgedDialogueLift() throws {
        let plain = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2))
        let lifted = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2, dialogueGainDB: 6))
        func ratioDB(_ s: [Float]) -> Double {
            let body = Array(s.dropFirst(4800).prefix(9600))
            return 20 * log10(level(body, hz: 1000) / level(body, hz: 250))
        }
        let gained = ratioDB(lifted.left) - ratioDB(plain.left)
        #expect(abs(gained - 6) < 0.5, "centre against the rest moved by \(gained) dB, asked for 6")
    }

    @Test("a loud fold with a lift never clips through the bridge")
    func bridgedLimiter() throws {
        let out = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2, dialogueGainDB: 12),
                                         amplitude: 0.9)
        let ceiling = Float(pow(10, AudioDynamicsProcessor.ceilingDBFS / 20))
        #expect((out.left.map { abs($0) }.max() ?? 0) <= ceiling + 1e-3)
    }

    @Test("the software decoder carries the cap and the lift")
    func softwareDecoderShapes() throws {
        func decodedLeft(_ shaping: AudioShaping) throws -> (channels: Int32, left: [Float]) {
            var out: (Int32, [Float]) = (0, [])
            try withAudioStream(makeDialogueWAV(channels: 6)) { stream, packets in
                let decoder = AudioDecoder()
                decoder.shaping = shaping
                try decoder.open(stream: stream)
                defer { decoder.close() }
                var buffers: [CMSampleBuffer] = []
                for p in packets { buffers.append(contentsOf: decoder.decode(packet: p)) }
                buffers.append(contentsOf: decoder.drain())
                var left: [Float] = []
                for b in buffers {
                    let n = CMSampleBufferGetNumSamples(b)
                    let block = try #require(CMSampleBufferGetDataBuffer(b))
                    var data = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                    _ = data.withUnsafeMutableBytes {
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                    }
                    let ch = data.count / n
                    for i in 0..<n { left.append(data[i * ch]) }
                }
                out = (decoder.channels, left)
            }
            return out
        }
        let plain = try decodedLeft(AudioShaping(maxChannels: 2))
        let lifted = try decodedLeft(AudioShaping(maxChannels: 2, dialogueGainDB: 6))
        #expect(plain.channels == 2)
        func ratioDB(_ s: [Float]) -> Double {
            let body = Array(s.dropFirst(4800).prefix(9600))
            return 20 * log10(level(body, hz: 1000) / level(body, hz: 250))
        }
        let gained = ratioDB(lifted.left) - ratioDB(plain.left)
        #expect(abs(gained - 6) < 0.5, "centre against the rest moved by \(gained) dB, asked for 6")
    }
}
