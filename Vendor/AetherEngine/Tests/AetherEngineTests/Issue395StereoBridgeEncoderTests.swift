import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#395: a live MPEG-TS program carrying H.264 + MP2 stereo + AC3 5.1 + a second MP2 stereo played on
/// HDMI and was silent on an AirPlay 2 optical adapter, intermittently, and the intermittency was which
/// track `av_find_best_stream` had landed on. Measured against a rebuilt fixture, all three selectable
/// tracks reached AVPlayer as a Dolby bitstream: the AC3 5.1 stream-copied to `ac-3`, and each MP2 stereo
/// track came out of the bridge as `ec-3`, because `.surroundCompat` picked its encoder from the MODE
/// alone. The reporter's own A/B then split exactly there: the stream-copied AC3 5.1 played, the bridged
/// EAC3 stereo did not.
///
/// A mode is not an encoder. `.surroundCompat` exists to carry SURROUND across a route that cannot take
/// multichannel LPCM; a source with two channels or fewer has none to carry, so its EAC3 output was lossy
/// where the FLAC in the same build is lossless, and a Dolby bitstream on every route that can only pass
/// one through. The encoder is now resolved from the mode AND the source's channel count.
///
/// Route-blind by construction: the input is the source, never the current output route. #34 measured
/// route-dependent bridging wrong (AVPlayer downmixes EAC3+JOC natively over A2DP) and it was removed.
@Suite("AE#395 the bridge encoder follows the source, not the mode", .serialized)
struct Issue395StereoBridgeEncoderTests {

    // MARK: - The resolution itself

    @Test("surroundCompat takes EAC3 only where there is surround to carry")
    func surroundCompatResolvesPerSource() {
        for channels in Int32(1)...2 {
            #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: channels)
                    == AV_CODEC_ID_FLAC)
        }
        for channels in Int32(3)...8 {
            #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: channels)
                    == AV_CODEC_ID_EAC3)
        }
    }

    @Test("lossless is FLAC at every channel count")
    func losslessIsAlwaysFLAC() {
        for channels in Int32(1)...8 {
            #expect(AudioBridge.bridgeEncoder(for: .lossless, sourceChannels: channels) == AV_CODEC_ID_FLAC)
        }
    }

    /// An unresolved layout (Matroska TrueHD/MLP leave Channels empty) reads as 0 here, and the bridge's
    /// own fallback is stereo. FLAC is the right answer for that case too: it carries whatever the decoder
    /// turns out to produce up to 7.1, where EAC3 would have folded it.
    @Test("an unresolved channel count does not claim surround")
    func unresolvedChannelCountTakesFLAC() {
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 0) == AV_CODEC_ID_FLAC)
    }

    @Test("caps and rates follow the encoder, not the mode")
    func capsAndRatesFollowTheEncoder() {
        #expect(AudioBridge.maxEncodedChannels(for: AV_CODEC_ID_EAC3) == 6)
        #expect(AudioBridge.maxEncodedChannels(for: AV_CODEC_ID_FLAC) == 8)
        #expect(AudioBridge.encoderBitRate(for: AV_CODEC_ID_FLAC, channels: 2) == 0,
                "a FLAC context that inherited EAC3's 256 kbps would cap a lossless path")
        #expect(AudioBridge.encoderBitRate(for: AV_CODEC_ID_EAC3, channels: 6) == 768_000)
    }

    // MARK: - What the bridge actually opens

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

    private func openBridge(
        channels: Int,
        mode: AudioBridgeMode,
        forcedEncoder: AVCodecID? = nil,
        _ body: (AudioBridge, [UnsafeMutablePointer<AVPacket>]) throws -> Void
    ) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(
            data: makeWAV(sampleRate: 48_000, channels: channels, seconds: 0.25)))
        let audioIdx = demuxer.audioStreamIndex
        guard audioIdx >= 0, let stream = demuxer.stream(at: audioIdx) else {
            throw NSError(domain: "test", code: 1)
        }
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        defer {
            for p in packets {
                var pp: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&pp)
            }
        }
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == audioIdx {
                packets.append(packet)
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&p)
            }
        }
        let bridge = try AudioBridge(srcCodecpar: stream.pointee.codecpar,
                                     srcTimeBase: stream.pointee.time_base,
                                     mode: mode,
                                     forcedEncoder: forcedEncoder)
        defer { bridge.close() }
        try body(bridge, packets)
    }

    /// The regression this issue is about, at the only place it is observable without a device: what the
    /// muxer is handed for a stereo source under the DEFAULT mode. `ec-3` here is what reached the AirPlay
    /// route; `fLaC` is what AVPlayer decodes to LPCM on any route at all.
    @Test("a stereo source under the default mode is handed to the muxer as FLAC")
    func stereoSourceBridgesToFLAC() throws {
        try openBridge(channels: 2, mode: .surroundCompat) { bridge, packets in
            #expect(bridge.outputCodecID == AV_CODEC_ID_FLAC)
            #expect(bridge.encoderCodecpar?.pointee.codec_id == AV_CODEC_ID_FLAC)
            #expect(bridge.encoderCodecpar?.pointee.ch_layout.nb_channels == 2)
            #expect(bridge.encoderCodecpar?.pointee.bit_rate == 0, "FLAC is VBR")
            var outputs: [UnsafeMutablePointer<AVPacket>] = []
            for p in packets { outputs.append(contentsOf: try bridge.feed(packet: p)) }
            defer {
                for o in outputs {
                    var oo: UnsafeMutablePointer<AVPacket>? = o
                    trackedPacketFree(&oo)
                }
            }
            #expect(!outputs.isEmpty, "the re-routed encoder still has to produce audio")
            #expect(!bridge.feedStats.isSilent)
        }
    }

    @Test("a 5.1 source under the default mode still bridges to EAC3")
    func surroundSourceStillBridgesToEAC3() throws {
        try openBridge(channels: 6, mode: .surroundCompat) { bridge, packets in
            #expect(bridge.outputCodecID == AV_CODEC_ID_EAC3)
            #expect(bridge.encoderCodecpar?.pointee.codec_id == AV_CODEC_ID_EAC3)
            #expect(bridge.encoderCodecpar?.pointee.ch_layout.nb_channels == 6)
            #expect(bridge.encoderCodecpar?.pointee.bit_rate == 768_000)
            var outputs: [UnsafeMutablePointer<AVPacket>] = []
            for p in packets { outputs.append(contentsOf: try bridge.feed(packet: p)) }
            defer {
                for o in outputs {
                    var oo: UnsafeMutablePointer<AVPacket>? = o
                    trackedPacketFree(&oo)
                }
            }
            #expect(!outputs.isEmpty)
        }
    }

    /// The #165 retry path: the route forces the other encoder when the resolved one is absent from the
    /// build, and the forced choice has to reach the encoder context AND the PCM intermediate format, or
    /// the encoder opens with a sample format it cannot take.
    @Test("a forced encoder overrides the resolution and still opens")
    func forcedEncoderOverridesTheResolution() throws {
        try openBridge(channels: 2, mode: .surroundCompat, forcedEncoder: AV_CODEC_ID_EAC3) { bridge, packets in
            #expect(bridge.outputCodecID == AV_CODEC_ID_EAC3)
            #expect(bridge.encoderCodecpar?.pointee.bit_rate == 256_000)
            var outputs: [UnsafeMutablePointer<AVPacket>] = []
            for p in packets { outputs.append(contentsOf: try bridge.feed(packet: p)) }
            defer {
                for o in outputs {
                    var oo: UnsafeMutablePointer<AVPacket>? = o
                    trackedPacketFree(&oo)
                }
            }
            #expect(!outputs.isEmpty)
        }
    }
}
