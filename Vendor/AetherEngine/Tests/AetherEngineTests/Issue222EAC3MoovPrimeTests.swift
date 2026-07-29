import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#222: an E-AC-3 source whose first segment contains no audio packet wedged the muxer. movenc builds
/// the `ec-3` sample entry's `dec3` box in `handle_eac3`, i.e. only from a PARSED bitstream frame (never
/// from codecpar or extradata), so a first fragment flush with video only fails -22 "Cannot write moov atom
/// before EAC3 packets parsed". `flushPendingFragment` already refuses that flush; `cutFragmentForNextSegment`
/// did not, and its only "not now" return was nil, which the producer reads as a fatal wedge.
///
/// The fix gives a cut a third outcome (`deferredAwaitingAudioSampleEntry`, muxer left intact) and lets a
/// muxer be primed with one real audio frame at init, which writes moov up front and then discards the
/// primed fragment's bytes, so the delivered segment stays exactly as planned.
///
/// Media is the existing synthesized, non-Atmos base64 fixtures (see AtmosDetectionProbeIntegrationTests):
/// H.264 16x16 video for the video track, 0.1s stereo E-AC-3 / AAC for the audio track.
@Suite("AE#222: EAC3 moov prime and deferred first cut")
struct Issue222EAC3MoovPrimeTests {

    // MARK: - Harness

    /// One muxer under test plus the demuxers whose codecpar it points at (they must outlive it).
    private final class Rig {
        let videoDemuxer = Demuxer()
        let audioDemuxer = Demuxer()
        let sessionDir: URL
        var initBytes: Data?
        var muxer: MP4SegmentMuxer?

        init() throws {
            sessionDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ae222-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        }

        deinit {
            muxer = nil
            videoDemuxer.close()
            audioDemuxer.close()
            try? FileManager.default.removeItem(at: sessionDir)
        }

        func open(audioFixture: String?) throws {
            try videoDemuxer.open(
                reader: DataIOReader(data: Self.data(Issue222EAC3MoovPrimeTests.videoOnlyBase64)),
                formatHint: "mp4"
            )
            if let audioFixture {
                try audioDemuxer.open(reader: DataIOReader(data: Self.data(audioFixture)), formatHint: "mp4")
            }
        }

        /// First audio packet's payload from the audio fixture: a real E-AC-3 / AAC frame, which is exactly
        /// what the producer captures in production.
        func firstAudioFrameBytes() throws -> [UInt8] {
            let idx = audioDemuxer.audioStreamIndex
            while true {
                guard let pkt = try audioDemuxer.readPacket() else { return [] }
                defer {
                    var p: UnsafeMutablePointer<AVPacket>? = pkt
                    trackedPacketFree(&p)
                }
                if pkt.pointee.stream_index == idx, pkt.pointee.size > 0, let data = pkt.pointee.data {
                    return [UInt8](UnsafeBufferPointer(start: data, count: Int(pkt.pointee.size)))
                }
            }
        }

        func makeMuxer(audioPrime: [UInt8]?, withAudio: Bool = true) throws -> MP4SegmentMuxer {
            guard let vStream = videoDemuxer.stream(at: videoDemuxer.videoStreamIndex) else {
                throw MuxerRigError.noVideoStream
            }
            let video = MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(vStream.pointee.codecpar),
                timeBase: vStream.pointee.time_base,
                codecTagOverride: nil
            )
            var audio: MP4SegmentMuxer.AudioConfig?
            if withAudio, let aStream = audioDemuxer.stream(at: audioDemuxer.audioStreamIndex) {
                audio = MP4SegmentMuxer.AudioConfig(
                    codecpar: UnsafePointer(aStream.pointee.codecpar),
                    timeBase: aStream.pointee.time_base
                )
            }
            let m = try MP4SegmentMuxer(
                initialSegmentIndex: 0,
                sessionDir: sessionDir,
                video: video,
                audio: audio,
                audioMoovPrimeFrame: audioPrime,
                onInitCaptured: { [self] bytes in self.initBytes = bytes }
            )
            muxer = m
            return m
        }

        /// Feeds every video packet of the fixture into the muxer, rescaled like the producer does.
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

        /// Muxes one audio frame at an explicit dts, the way a source whose audio starts late does.
        func writeAudioFrame(_ frame: [UInt8], dts: Int64, into muxer: MP4SegmentMuxer) throws {
            var pktOpt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            guard let pkt = pktOpt else { throw MuxerRigError.noVideoStream }
            defer { av_packet_free(&pktOpt) }
            guard av_new_packet(pkt, Int32(frame.count)) == 0, let dst = pkt.pointee.data else {
                throw MuxerRigError.noVideoStream
            }
            frame.withUnsafeBytes { src in
                if let base = src.baseAddress { memcpy(dst, base, frame.count) }
            }
            pkt.pointee.stream_index = muxer.audioOutputStreamIndex
            pkt.pointee.pts = dts
            pkt.pointee.dts = dts
            pkt.pointee.duration = 1536
            pkt.pointee.flags |= AV_PKT_FLAG_KEY
            _ = muxer.writePacket(pkt)
        }

        static func data(_ base64: String) -> Data {
            Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        }
    }

    private enum MuxerRigError: Error { case noVideoStream }

    private static let videoOnlyBase64 = AtmosDetectionProbeIntegrationTests.videoOnlyBase64
    private static let eac3Base64 = AtmosDetectionProbeIntegrationTests.eac3PlainBase64
    private static let aacBase64 = AtmosDetectionProbeIntegrationTests.aacBase64

    private static func containsBox(_ data: Data?, _ fourCC: String) -> Bool {
        guard let data else { return false }
        return data.range(of: Data(fourCC.utf8)) != nil
    }

    /// Every `tfdt` baseMediaDecodeTime in the buffer (one per traf). Version 1 (64-bit) is what movenc writes.
    private static func allTfdts(in data: Data) -> [Int64] {
        var out: [Int64] = []
        var searchStart = data.startIndex
        while let r = data.range(of: Data("tfdt".utf8), in: searchStart..<data.endIndex) {
            searchStart = r.upperBound
            let versionOffset = r.upperBound
            guard versionOffset + 12 <= data.endIndex, data[versionOffset] == 1 else { continue }
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(data[versionOffset + 4 + i])
            }
            out.append(Int64(bitPattern: value))
        }
        return out
    }

    // MARK: - The wedge: a video-only first cut on a packet-derived audio sample entry

    @Test("EAC3 first cut with no audio packet defers instead of failing, and leaves the muxer usable")
    func eac3FirstCutWithoutAudioDefers() throws {
        let rig = try Rig()
        try rig.open(audioFixture: Self.eac3Base64)
        let muxer = try rig.makeMuxer(audioPrime: nil)

        let written = try rig.writeAllVideoPackets(into: muxer)
        #expect(written > 0, "fixture must contribute video packets")

        let outcome = muxer.cutFragmentForNextSegment(1)
        #expect(outcome == .deferredAwaitingAudioSampleEntry,
                "a moov that cannot carry dec3 yet is 'not now', not a failed cut")
        #expect(!muxer.isWedged, "deferring must not wedge the muxer")
        #expect(rig.initBytes == nil, "no moov can have been emitted")
    }

    @Test("AAC keeps cutting a video-only first segment (sample entry comes from codecpar)")
    func aacFirstCutWithoutAudioStillCompletes() throws {
        let rig = try Rig()
        try rig.open(audioFixture: Self.aacBase64)
        let muxer = try rig.makeMuxer(audioPrime: nil)

        try rig.writeAllVideoPackets(into: muxer)
        let outcome = muxer.cutFragmentForNextSegment(1)

        guard case .completed(_, let bytes) = outcome else {
            Issue.record("AAC must not defer, got \(outcome)")
            return
        }
        #expect(bytes > 0)
        #expect(Self.containsBox(rig.initBytes, "moov"), "init.mp4 is emitted at the first cut")
    }

    // MARK: - The fix: prime moov with one real audio frame, discard the primed fragment

    @Test("priming with one real EAC3 frame writes a dec3-carrying moov before any packet is muxed")
    func primeWritesMoovWithDec3UpFront() throws {
        let rig = try Rig()
        try rig.open(audioFixture: Self.eac3Base64)
        let prime = try rig.firstAudioFrameBytes()
        #expect(!prime.isEmpty, "fixture must yield a real EAC3 frame")

        let muxer = try rig.makeMuxer(audioPrime: prime)

        #expect(Self.containsBox(rig.initBytes, "moov"), "moov is written at init, not at the first cut")
        #expect(Self.containsBox(rig.initBytes, "dec3"),
                "dec3 must come from the parsed prime frame, so Atmos/JOC signaling survives")
        #expect(muxer.stagedSegmentByteCount == 0,
                "the primed fragment's bytes must not be delivered as segment payload")
    }

    @Test("a primed muxer cuts a video-only first segment exactly as planned")
    func primedMuxerCutsVideoOnlyFirstSegment() throws {
        let rig = try Rig()
        try rig.open(audioFixture: Self.eac3Base64)
        let prime = try rig.firstAudioFrameBytes()
        let muxer = try rig.makeMuxer(audioPrime: prime)

        try rig.writeAllVideoPackets(into: muxer)
        let outcome = muxer.cutFragmentForNextSegment(1)

        guard case .completed(let path, let bytes) = outcome else {
            Issue.record("primed cut must complete, got \(outcome)")
            return
        }
        #expect(bytes > 0)
        let segment = try Data(contentsOf: path)
        #expect(segment.count == bytes)
        #expect(Self.containsBox(segment, "moof"), "the delivered segment is a plain fragment")
        #expect(!Self.containsBox(segment, "moov"), "moov already went to init.mp4")
    }

    /// The regression this guards: movenc rewrites a fragment's first sample dts to
    /// `start_dts + track_duration` unless the track is flagged discontinuous, and it consumes the
    /// +frag_discont flag on the prime packet. Un-rearmed, an audio track whose real samples start seconds in
    /// gets tfdt 0, i.e. the audio plays that far ahead of picture. Measured on the repro fixture before the
    /// re-arm: a 12 s audio start wrote tfdt=0.
    @Test("audio muxed after a prime keeps its own timestamp (no tfdt collapse to 0)")
    func primedMuxerKeepsRealAudioTimestamps() throws {
        let rig = try Rig()
        try rig.open(audioFixture: Self.eac3Base64)
        let prime = try rig.firstAudioFrameBytes()
        let muxer = try rig.makeMuxer(audioPrime: prime)

        try rig.writeAllVideoPackets(into: muxer)

        // One audio packet, deliberately far from the prime's dts 0, exactly like a source whose audio starts
        // seconds after its video.
        let audioDts: Int64 = 12 * 48000
        try rig.writeAudioFrame(prime, dts: audioDts, into: muxer)

        guard case .completed(let path, _) = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("primed cut must complete")
            return
        }
        let segment = try Data(contentsOf: path)
        let tfdts = Self.allTfdts(in: segment)
        #expect(tfdts.contains(audioDts),
                "the audio fragment must carry its real baseMediaDecodeTime, got \(tfdts)")
        #expect(!tfdts.isEmpty)
    }

    @Test("a prime frame is ignored when the session has no audio stream")
    func primeIgnoredWithoutAudioStream() throws {
        let rig = try Rig()
        try rig.open(audioFixture: Self.eac3Base64)
        let prime = try rig.firstAudioFrameBytes()
        let muxer = try rig.makeMuxer(audioPrime: prime, withAudio: false)

        try rig.writeAllVideoPackets(into: muxer)
        let outcome = muxer.cutFragmentForNextSegment(1)

        guard case .completed(_, let bytes) = outcome else {
            Issue.record("video-only session must cut normally, got \(outcome)")
            return
        }
        #expect(bytes > 0)
    }
}
