import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Live rotation wedge: a mid-session muxer rotation (same-PID parameter-set change after a live reconnect
/// join, or an SSAI program switch) builds a brand-new muxer, and with BRIDGED E-AC-3 the rotated muxer's
/// first cut can arrive before any post-seam audio packet exists: video leads audio across the seam and
/// the bridge adds encoder latency on top. Unprimed, that cut defers for a sample entry (AE#222), the
/// producer converts the deferral into a pump exit, teardown finalize fails on the same precondition, and
/// the live session dies with `muxerFailed`. The exit-scan cannot help either: it rightly excludes bridged
/// sessions (a raw source frame cannot prime a bridge-encoded track).
///
/// The fix has the producer retain the last audio frame a muxer accepted and prime every later allocation
/// with it. These tests pin the claim that rests on, which AE#222's source-frame tests do not cover: a
/// BRIDGE-OUTPUT E-AC-3 frame is a valid moov prime for a muxer whose audio track IS the bridge encoder.
@Suite("Live rotation: bridge-output audio frame as moov prime")
struct LiveRotationAudioPrimeTests {

    // MARK: - Harness

    /// Little-endian 16-bit PCM WAV with a 440 Hz sine (same shape as Issue99BridgeResumeTests).
    private static func makeWAV(sampleRate: Int, channels: Int, seconds: Double) -> Data {
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

    /// A live bridged session in miniature: WAV source -> AudioBridge(.surroundCompat) -> E-AC-3 packets,
    /// plus the H.264 video fixture, feeding a muxer whose audio track is the bridge's encoder.
    private final class Rig {
        let videoDemuxer = Demuxer()
        let audioDemuxer = Demuxer()
        let sessionDir: URL
        var bridge: AudioBridge?
        var initBytes: Data?
        var muxer: MP4SegmentMuxer?
        /// Payloads of every E-AC-3 packet the bridge emitted, in order.
        var bridgeFrames: [[UInt8]] = []

        init() throws {
            sessionDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-rotation-prime-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            try videoDemuxer.open(
                reader: DataIOReader(data: Data(
                    base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                    options: .ignoreUnknownCharacters) ?? Data()),
                formatHint: "mp4"
            )
        }

        deinit {
            muxer = nil
            bridge?.close()
            videoDemuxer.close()
            audioDemuxer.close()
            try? FileManager.default.removeItem(at: sessionDir)
        }

        /// Opens the bridge over an in-memory WAV and runs every source packet through it.
        func runBridge() throws {
            try audioDemuxer.open(
                reader: DataIOReader(data: LiveRotationAudioPrimeTests.makeWAV(
                    sampleRate: 48_000, channels: 2, seconds: 1.0))
            )
            let audioIdx = audioDemuxer.audioStreamIndex
            guard audioIdx >= 0, let stream = audioDemuxer.stream(at: audioIdx) else {
                throw RigError.noStream
            }
            // AE#395: `.surroundCompat` resolves to FLAC for a stereo source, and FLAC's dfLa box is
            // built from extradata at init, so it never reaches the deferred-sample-entry shape this
            // suite is about. The subject here is the EAC3 dec3 prime, so the encoder is forced rather
            // than inferred; a surround fixture would test the same thing at three times the PCM.
            let bridge = try AudioBridge(
                srcCodecpar: stream.pointee.codecpar,
                srcTimeBase: stream.pointee.time_base,
                mode: .surroundCompat,
                forcedEncoder: AV_CODEC_ID_EAC3
            )
            self.bridge = bridge
            while let packet = try audioDemuxer.readPacket() {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&p) }
                guard packet.pointee.stream_index == audioIdx else { continue }
                for out in try bridge.feed(packet: packet) {
                    var o: UnsafeMutablePointer<AVPacket>? = out
                    defer { trackedPacketFree(&o) }
                    if let data = out.pointee.data, out.pointee.size > 0 {
                        bridgeFrames.append(
                            [UInt8](UnsafeBufferPointer(start: data, count: Int(out.pointee.size))))
                    }
                }
            }
        }

        /// The rotated muxer: fresh AVFormatContext whose audio track is the bridge's E-AC-3 encoder,
        /// exactly what `rotateMuxerForProgramSwitch` allocates mid-session.
        func makeRotatedMuxer(audioPrime: [UInt8]?) throws -> MP4SegmentMuxer {
            guard let vStream = videoDemuxer.stream(at: videoDemuxer.videoStreamIndex),
                  let encoderCodecpar = bridge?.encoderCodecpar, let bridge else {
                throw RigError.noStream
            }
            let m = try MP4SegmentMuxer(
                initialSegmentIndex: 414,
                sessionDir: sessionDir,
                video: MP4SegmentMuxer.VideoConfig(
                    codecpar: UnsafePointer(vStream.pointee.codecpar),
                    timeBase: vStream.pointee.time_base,
                    codecTagOverride: nil
                ),
                audio: MP4SegmentMuxer.AudioConfig(
                    codecpar: UnsafePointer(encoderCodecpar),
                    timeBase: bridge.encoderTimeBase
                ),
                audioMoovPrimeFrame: audioPrime,
                onInitCaptured: { [self] bytes in self.initBytes = bytes }
            )
            muxer = m
            return m
        }

        /// Post-seam video: every fixture packet, rescaled like the producer does.
        @discardableResult
        func writeAllVideoPackets(into muxer: MP4SegmentMuxer) throws -> Int {
            guard let vStream = videoDemuxer.stream(at: videoDemuxer.videoStreamIndex) else { return 0 }
            let sourceTb = vStream.pointee.time_base
            var written = 0
            while let pkt = try videoDemuxer.readPacket() {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                defer { trackedPacketFree(&p) }
                guard pkt.pointee.stream_index == videoDemuxer.videoStreamIndex else { continue }
                pkt.pointee.stream_index = muxer.videoOutputStreamIndex
                av_packet_rescale_ts(pkt, sourceTb, muxer.muxerVideoTimeBase)
                _ = muxer.writePacket(pkt)
                written += 1
            }
            return written
        }
    }

    private enum RigError: Error { case noStream }

    private static func containsBox(_ data: Data?, _ fourCC: String) -> Bool {
        guard let data else { return false }
        return data.range(of: Data(fourCC.utf8)) != nil
    }

    // MARK: - The incident, pinned

    @Test("unprimed rotation with bridged EAC3: video-only cut defers and teardown finalize salvages nothing")
    func unprimedRotationDiesLikeTheIncident() throws {
        let rig = try Rig()
        try rig.runBridge()
        let muxer = try rig.makeRotatedMuxer(audioPrime: nil)

        let written = try rig.writeAllVideoPackets(into: muxer)
        #expect(written > 0, "fixture must contribute post-seam video packets")

        #expect(muxer.cutFragmentForNextSegment(415) == .deferredAwaitingAudioSampleEntry,
                "the rotated muxer's first cut arrives before any post-seam bridge output")
        #expect(muxer.finalize() == nil,
                "teardown finalize fails on the same precondition, the 'final finalize failed; not adopted' -> muxerFailed pump death")
    }

    // MARK: - The fix's load-bearing claim

    @Test("a bridge-output EAC3 frame primes the rotated muxer: moov+dec3 at init, video-only cut completes")
    func bridgeOutputFramePrimesRotatedMuxer() throws {
        let rig = try Rig()
        try rig.runBridge()
        #expect(!rig.bridgeFrames.isEmpty, "bridge must emit E-AC-3 packets")

        // What the producer's capture retains: the payload of the last frame a muxer accepted.
        let muxer = try rig.makeRotatedMuxer(audioPrime: rig.bridgeFrames.last)

        #expect(Self.containsBox(rig.initBytes, "moov"), "moov is written at init, before any packet")
        #expect(Self.containsBox(rig.initBytes, "dec3"),
                "dec3 must be derivable from a BRIDGE-OUTPUT frame, not just a source frame")

        try rig.writeAllVideoPackets(into: muxer)
        guard case .completed(let path, let bytes) = muxer.cutFragmentForNextSegment(415) else {
            Issue.record("primed rotation cut must complete")
            return
        }
        #expect(bytes > 0)
        let segment = try Data(contentsOf: path)
        #expect(Self.containsBox(segment, "moof"), "the delivered segment is a plain fragment")
        #expect(!Self.containsBox(segment, "moov"), "moov already went to the versioned init")
    }

    // MARK: - The gate the retention hangs on

    /// The producer copies a prime frame per audio write only when this predicate says the codec needs one,
    /// so narrowing it silently disarms the rotation prime (and the #64 flush guard with it). The bridged
    /// case is what the incident ran on: the producer's AudioConfig carries the ENCODER codecpar, so a
    /// surroundCompat bridge reads as E-AC-3 here and a lossless bridge as FLAC.
    @Test("only the packet-derived sample entries ask for a prime frame")
    func onlyPacketDerivedSampleEntriesNeedAPrime() {
        for codec in [AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_TRUEHD] {
            #expect(MP4SegmentMuxer.audioNeedsParsedPacketForMoov(codec),
                    "dac3/dec3/dmlp are built from a parsed packet, so the frame must be retained")
        }
        for codec in [AV_CODEC_ID_AAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC,
                      AV_CODEC_ID_OPUS, AV_CODEC_ID_MP3, AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_NONE] {
            #expect(!MP4SegmentMuxer.audioNeedsParsedPacketForMoov(codec),
                    "sample entry comes from codecpar alone, so no per-frame copy is warranted")
        }
    }
}
