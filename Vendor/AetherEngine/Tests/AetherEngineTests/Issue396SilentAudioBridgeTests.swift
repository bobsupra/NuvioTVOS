import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#396: a plain SD MKV with mono MP3 audio failed on the native route at every start position,
/// ending on `Source audio cannot be muxed (code -22)`. The muxer was right and innocent: it can only
/// build an AC-3/E-AC-3 sample entry from a packet that was written, and the bridge had written none.
///
/// Nothing said so. Every step between a source packet and an encoded frame ends in a `return` or a
/// loop that stops on a negative code, so a bridge that emitted nothing for a whole segment was
/// indistinguishable from one that was simply not asked yet, and the only sentence the session ever
/// produced named the muxer and the source. These cover the counters that name the arm and the
/// classification that follows from them.
@Suite("AE#396 a silent audio bridge names itself")
struct Issue396SilentAudioBridgeTests {

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

    /// Mono 44.1 kHz MP3 parameters, the reporter's selected track, with no media behind them: the
    /// packets below carry bytes the mp3 decoder cannot make a frame of, which is the shape a
    /// bridge that answers nothing produces from the outside.
    private func makeMP3Codecpar() -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_MP3
        par.pointee.sample_rate = 44_100
        par.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        par.pointee.bit_rate = 40_000
        av_channel_layout_default(&par.pointee.ch_layout, 1)
        return par
    }

    private func makeUndecodablePackets(count: Int) -> [UnsafeMutablePointer<AVPacket>] {
        (0..<count).compactMap { i in
            guard let pkt = trackedPacketAlloc() else { return nil }
            guard av_new_packet(pkt, 130) >= 0 else { return nil }
            memset(pkt.pointee.data, 0xFF, 130)
            pkt.pointee.pts = Int64(i) * 26
            pkt.pointee.dts = pkt.pointee.pts
            return pkt
        }
    }

    // MARK: - The counters

    @Test("a bridge fed real audio reports what it produced")
    func healthyBridgeReportsItsOutput() throws {
        let wav = makeWAV(sampleRate: 48_000, channels: 2, seconds: 0.5)
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }

        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .surroundCompat)
        defer { bridge.close() }

        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outputs) }
        for p in packets { outputs.append(contentsOf: try bridge.feed(packet: p)) }

        let stats = bridge.feedStats
        #expect(stats.packetsFed == packets.count)
        #expect(stats.framesDecoded > 0)
        #expect(stats.samplesEnqueued > 0)
        #expect(stats.packetsEmitted == outputs.count)
        #expect(stats.packetsEmitted > 0)
        #expect(!stats.isSilent, "a bridge that emitted packets must never read as silent")
        #expect(!stats.decodedNothing)
    }

    @Test("a source the decoder rejects reads as decoded nothing, with the decoder's own code")
    func undecodableSourceIsNamedAsADecodeFailure() throws {
        let codecpar = makeMP3Codecpar()
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let bridge = try AudioBridge(srcCodecpar: codecpar,
                                     srcTimeBase: AVRational(num: 1, den: 1000),
                                     mode: .surroundCompat)
        defer { bridge.close() }

        var packets = makeUndecodablePackets(count: 80)
        defer { freeAll(&packets) }
        #expect(packets.count == 80)

        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outputs) }
        for p in packets { outputs.append(contentsOf: (try? bridge.feed(packet: p)) ?? []) }

        let stats = bridge.feedStats
        #expect(outputs.isEmpty)
        #expect(stats.packetsFed == 80)
        #expect(stats.framesDecoded == 0)
        #expect(stats.packetsEmitted == 0)
        #expect(stats.isSilent)
        #expect(stats.decodedNothing,
                "zero decoded frames is the arm a producer restart cannot heal")
        #expect(stats.lastDecodeErrorCode != 0,
                "the decoder's own code is the only thing that says WHY, and it used to be discarded")
        #expect(stats.summary.contains("decoded=0"))
        #expect(stats.summary.contains("emitted=0"))
    }

    // MARK: - The classification that follows

    private final class SurfacedFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (code: Int32, reason: String, kind: PlaybackErrorKind)?
        var snapshot: (code: Int32, reason: String, kind: PlaybackErrorKind)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set(_ code: Int32, _ reason: String, _ kind: PlaybackErrorKind) {
            lock.lock(); value = (code, reason, kind); lock.unlock()
        }
    }

    private func makeEngine() -> HLSVideoEngine {
        HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae396.mkv"), dvModeAvailable: false)
    }

    @Test("an exhausted revive on a bridge that emitted nothing blames the bridge, not the source")
    func exhaustedGateNamesTheSilentBridge() throws {
        let codecpar = makeMP3Codecpar()
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let bridge = try AudioBridge(srcCodecpar: codecpar,
                                     srcTimeBase: AVRational(num: 1, den: 1000),
                                     mode: .surroundCompat)
        defer { bridge.close() }

        let engine = makeEngine()
        engine.audioBridge = bridge
        engine.muxerFailureReviveGate = MuxerFailureReviveGate(maxAttempts: 0)
        let surfaced = SurfacedFailure()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODMuxerFailure()

        #expect(surfaced.snapshot?.kind == .audioBridgeProducedNoOutput,
                "vodSourceFailed reads as a dead source and ends a host's fallback ladder")
        #expect(surfaced.snapshot?.code == FFmpegErr.einval)
    }

    @Test("an exhausted revive on a bridge that DID emit keeps the muxer verdict")
    func exhaustedGateKeepsTheMuxerVerdictWhenTheBridgeProduced() throws {
        let wav = makeWAV(sampleRate: 48_000, channels: 2, seconds: 0.5)
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }

        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .surroundCompat)
        defer { bridge.close() }
        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outputs) }
        for p in packets { outputs.append(contentsOf: try bridge.feed(packet: p)) }
        #expect(!outputs.isEmpty, "precondition: this bridge produced audio")

        let engine = makeEngine()
        engine.audioBridge = bridge
        engine.muxerFailureReviveGate = MuxerFailureReviveGate(maxAttempts: 0)
        let surfaced = SurfacedFailure()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODMuxerFailure()

        #expect(surfaced.snapshot?.kind == .vodSourceFailed,
                "a bridge that produced audio is not the reason the moov could not be written")
        #expect(surfaced.snapshot?.reason == "Source audio cannot be muxed")
    }
}
