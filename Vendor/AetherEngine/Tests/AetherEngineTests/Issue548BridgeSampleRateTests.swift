import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#548: a 96 kHz TrueHD track played as video only. The bridge opened its encoder at the SOURCE
/// rate, and E-AC-3 exists at 32 / 44.1 / 48 kHz only, so `avcodec_open2` refused the context and the
/// whole session fell to silent video-only (the #165 cascade covers an ABSENT encoder, not a present
/// one that rejects the configuration).
///
/// The resampler was always in the path and always asked for the encoder's rate, so the rate the
/// encoder is opened at is a free choice. These pin that it is the encoder's choice, not the source's,
/// and that a rate the encoder does accept survives untouched (FLAC at 96 kHz stays bit-perfect).
@Suite("AE#548 the bridge encoder opens at a rate it supports")
struct Issue548BridgeSampleRateTests {

    // MARK: - Fixtures

    /// Little-endian 16-bit PCM WAV with a 440 Hz sine, built in memory.
    private func makeWAV(sampleRate: Int, channels: Int, seconds: Double) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let v = Int16(9000 * sin(2 * .pi * 440 * Double(n) / Double(sampleRate)))
            for _ in 0..<channels {
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    private func readAudioPackets(
        wav: Data
    ) throws -> (packets: [UnsafeMutablePointer<AVPacket>],
                 codecpar: UnsafeMutablePointer<AVCodecParameters>,
                 timeBase: AVRational,
                 demuxer: Demuxer) {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: wav))
        let audioIdx = demuxer.audioStreamIndex
        guard audioIdx >= 0, let stream = demuxer.stream(at: audioIdx) else {
            throw NSError(domain: "test", code: 1)
        }
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == audioIdx {
                packets.append(packet)
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&p)
            }
        }
        return (packets, stream.pointee.codecpar, stream.pointee.time_base, demuxer)
    }

    private func freeAll(_ packets: inout [UnsafeMutablePointer<AVPacket>]) {
        for p in packets {
            var pp: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&pp)
        }
        packets.removeAll()
    }

    /// The reporter's track: 96 kHz 5.1 TrueHD, described by its container header.
    private func makeTrueHDCodecpar(sampleRate: Int32, channels: Int32) -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_TRUEHD
        par.pointee.sample_rate = sampleRate
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        return par
    }

    // MARK: - The rate the encoder is opened at

    @Test("a 96 kHz source opens the E-AC-3 bridge at a rate E-AC-3 has")
    func ninetySixKilohertzSourceOpensEAC3() throws {
        let codecpar = makeTrueHDCodecpar(sampleRate: 96_000, channels: 6)
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }

        let bridge = try AudioBridge(srcCodecpar: codecpar,
                                     srcTimeBase: AVRational(num: 1, den: 96_000),
                                     mode: .surroundCompat)
        defer { bridge.close() }

        #expect(bridge.encoderCodecpar?.pointee.codec_id == AV_CODEC_ID_EAC3)
        #expect(bridge.encoderTimeBase.den == 48_000,
                "E-AC-3 tops out at 48 kHz, so the bridge must resample rather than refuse the session")
    }

    @Test("96 kHz surround really encodes end to end")
    func ninetySixKilohertzSurroundProducesPackets() throws {
        let wav = makeWAV(sampleRate: 96_000, channels: 6, seconds: 0.5)
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }

        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .surroundCompat)
        defer { bridge.close() }

        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outputs) }
        for p in packets { outputs.append(contentsOf: try bridge.feed(packet: p)) }

        #expect(bridge.encoderTimeBase.den == 48_000)
        #expect(outputs.count > 0, "the whole point of the resample is that audio arrives")
        #expect(!bridge.feedStats.isSilent)
    }

    @Test("a rate the encoder supports is left alone, so FLAC at 96 kHz stays bit-perfect")
    func losslessKeepsTheSourceRate() throws {
        let codecpar = makeTrueHDCodecpar(sampleRate: 96_000, channels: 6)
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }

        let bridge = try AudioBridge(srcCodecpar: codecpar,
                                     srcTimeBase: AVRational(num: 1, den: 96_000),
                                     mode: .lossless)
        defer { bridge.close() }

        #expect(bridge.encoderCodecpar?.pointee.codec_id == AV_CODEC_ID_FLAC)
        #expect(bridge.encoderTimeBase.den == 96_000,
                "FLAC carries 96 kHz, and a lossless mode that resampled it would not be lossless")
    }

    // MARK: - The choice itself

    @Test("the encoder's own list decides")
    func supportedRatesComeFromTheEncoder() {
        let eac3 = AudioBridge.supportedSampleRates(for: AV_CODEC_ID_EAC3)
        #expect(eac3.contains(48_000))
        #expect(!eac3.contains(96_000), "if this ever fails, E-AC-3 grew a rate and the fix below is moot")

        let flac = AudioBridge.supportedSampleRates(for: AV_CODEC_ID_FLAC)
        #expect(flac.isEmpty || flac.contains(96_000))
    }

    @Test("an exact match wins")
    func exactMatchIsKept() {
        #expect(AudioBridge.encoderSampleRate(supported: [48_000, 44_100, 32_000], source: 44_100) == 44_100)
    }

    @Test("an unconstrained encoder takes the source rate whole")
    func emptyListMeansNoConstraint() {
        #expect(AudioBridge.encoderSampleRate(supported: [], source: 96_000) == 96_000)
    }

    @Test("above the list, the highest supported rate wins, never an invented one")
    func aboveTheListPicksTheHighest() {
        #expect(AudioBridge.encoderSampleRate(supported: [48_000, 44_100, 32_000], source: 96_000) == 48_000)
        #expect(AudioBridge.encoderSampleRate(supported: [48_000, 44_100, 32_000], source: 192_000) == 48_000)
        #expect(AudioBridge.encoderSampleRate(supported: [48_000, 44_100, 32_000], source: 88_200) == 48_000)
        #expect(AudioBridge.encoderSampleRate(supported: [48_000, 44_100, 32_000], source: 47_000) == 44_100)
    }

    @Test("below the list, the lowest supported rate wins, so the session still plays")
    func belowTheListPicksTheLowest() {
        #expect(AudioBridge.encoderSampleRate(supported: [48_000, 44_100, 32_000], source: 8_000) == 32_000)
    }

    @Test("a source rate nobody resolved falls back rather than opening at zero")
    func unresolvedSourceRateStillOpens() {
        #expect(AudioBridge.encoderSampleRate(supported: [48_000, 44_100, 32_000], source: 0) == 48_000)
        #expect(AudioBridge.encoderSampleRate(supported: [], source: 0) == 48_000)
    }
}
