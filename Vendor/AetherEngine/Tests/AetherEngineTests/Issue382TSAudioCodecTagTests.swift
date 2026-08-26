import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#382: E-AC-3 (JOC/Atmos included) from live MPEG-TS never stream-copied into the loopback fMP4. The
/// muxer header was refused with `Could not find tag for codec eac3 in stream #1` / `-22`, the audio cascade
/// read that as "this source cannot stream-copy" and bridged, and every Atmos object was re-encoded away.
///
/// The tag is the whole story. mpegts sets `codecpar.codec_tag` to the PMT stream type (0x87) or, with a
/// registration descriptor, to its fourcc (`EAC3`), `avcodec_parameters_copy` carries it into the output
/// stream, and movenc rejects the (tag, codec) pair because it is not an mp4 tag. `init_muxer` would have
/// intercepted it, but only at `FF_COMPLIANCE_NORMAL`; the muxer runs at `-2` so the Dolby Vision atoms get
/// written, and below NORMAL that guard waves a foreign tag through.
///
/// Reproduced end to end on a plain file remux of the Dolby JOC kit signal
/// (`ffmpeg -i ddp-joc.mp4 -c copy -f mpegts`), so it is not live-specific: any MPEG-TS whose audio tag is
/// not an mp4 tag lost stream-copy, Atmos was only the loudest casualty. AC-3 and AAC from the same remux
/// were measured NOT to be affected in practice, for two different reasons (a `AC-3` registration descriptor
/// resolves to `ac-3` case-insensitively; ADTS AAC has its tag cleared by `prepareAACForFMP4` alongside the
/// synthesised AudioSpecificConfig), which is why E-AC-3 was the one codec the defect was visible on.
@Suite("AE#382: MPEG-TS audio codec_tag must not reach the fMP4 sample entry")
struct Issue382TSAudioCodecTagTests {

    // MARK: - Harness

    private static var mp4Tags: UnsafePointer<OpaquePointer?>? {
        av_guess_format("mp4", nil, nil)?.pointee.codec_tag
    }

    private static func tag(_ fourCC: String) -> UInt32 {
        var value: UInt32 = 0
        for (i, byte) in Array(fourCC.utf8).enumerated() { value |= UInt32(byte) << (i * 8) }
        return value
    }

    private static func accepts(_ tag: UInt32, _ codecID: AVCodecID) -> Bool {
        MP4SegmentMuxer.mp4AcceptsAudioCodecTag(tags: mp4Tags, codecID: codecID, tag: tag)
    }

    // MARK: - The decision

    @Test("the PMT stream type an MPEG-TS carries is not an mp4 tag")
    func rejectsMPEGTSStreamType() {
        #expect(Self.accepts(0x87, AV_CODEC_ID_EAC3) == false)  // E-AC-3 PMT stream type
        #expect(Self.accepts(0x81, AV_CODEC_ID_AC3) == false)   // AC-3 PMT stream type
        #expect(Self.accepts(0x0F, AV_CODEC_ID_AAC) == false)   // ADTS AAC PMT stream type
    }

    @Test("the registration-descriptor fourcc EAC3 is not an mp4 tag either")
    func rejectsRegistrationDescriptor() {
        #expect(Self.accepts(Self.tag("EAC3"), AV_CODEC_ID_EAC3) == false)
    }

    @Test("an mp4 tag survives untouched")
    func keepsMP4Tags() {
        #expect(Self.accepts(Self.tag("ec-3"), AV_CODEC_ID_EAC3))
        #expect(Self.accepts(Self.tag("ac-3"), AV_CODEC_ID_AC3))
        #expect(Self.accepts(Self.tag("mp4a"), AV_CODEC_ID_AAC))
        #expect(Self.accepts(0, AV_CODEC_ID_EAC3))  // no tag: init_muxer fills the canonical one
    }

    /// `AC-3` is what an MPEG-TS registration descriptor carries, and movenc's own validation compares tags
    /// case-insensitively, so it resolves to `ac-3` and works today. Dropping it would be a needless change
    /// of behaviour for a source that already plays; the rule must be as permissive as movenc's, not stricter.
    @Test("a case-variant of an mp4 tag stays, because movenc accepts it")
    func keepsCaseVariantTag() {
        #expect(Self.accepts(Self.tag("AC-3"), AV_CODEC_ID_AC3))
    }

    /// When mp4 has no tag for the codec at all there is nothing better to substitute, so the source tag
    /// stays and movenc fails loudly, which is what routes the cascade to the bridge. The first expectation
    /// pins that premise: if a future FFmpeg gains a tag for this codec the test says so instead of quietly
    /// changing meaning.
    @Test("a codec mp4 cannot carry keeps its tag")
    func keepsTagForCodecWithoutMP4Mapping() {
        var canonical: UInt32 = 0
        #expect(av_codec_get_tag2(Self.mp4Tags, AV_CODEC_ID_PCM_BLURAY, &canonical) == 0)
        #expect(Self.accepts(Self.tag("HDMV"), AV_CODEC_ID_PCM_BLURAY))
    }

    // MARK: - The muxer header

    /// The integration end: a real E-AC-3 codecpar with the tag an MPEG-TS source would carry has to pass
    /// `probeWriteHeader`, because that probe is what the audio cascade reads as "stream-copy is possible".
    /// Before the fix this returned -22 and every TS E-AC-3 session bridged.
    @Test("probeWriteHeader accepts E-AC-3 carrying an MPEG-TS tag")
    func probeAcceptsTSTaggedEAC3() throws {
        for sourceTag in [Self.tag("EAC3"), 0x87, 0] {
            let videoDemuxer = Demuxer()
            let audioDemuxer = Demuxer()
            defer { videoDemuxer.close(); audioDemuxer.close() }
            try videoDemuxer.open(
                reader: DataIOReader(data: Self.data(AtmosDetectionProbeIntegrationTests.videoOnlyBase64)),
                formatHint: "mp4"
            )
            try audioDemuxer.open(
                reader: DataIOReader(data: Self.data(AtmosDetectionProbeIntegrationTests.eac3PlainBase64)),
                formatHint: "mp4"
            )
            guard let videoStream = videoDemuxer.stream(at: videoDemuxer.videoStreamIndex),
                  let audioStream = audioDemuxer.stream(at: audioDemuxer.audioStreamIndex) else {
                Issue.record("fixtures must expose one video and one audio stream")
                return
            }
            audioStream.pointee.codecpar.pointee.codec_tag = sourceTag

            let ret = MP4SegmentMuxer.probeWriteHeader(
                video: MP4SegmentMuxer.VideoConfig(
                    codecpar: UnsafePointer(videoStream.pointee.codecpar),
                    timeBase: videoStream.pointee.time_base,
                    codecTagOverride: nil
                ),
                audio: MP4SegmentMuxer.AudioConfig(
                    codecpar: UnsafePointer(audioStream.pointee.codecpar),
                    timeBase: audioStream.pointee.time_base
                )
            )
            #expect(ret == 0, "source tag \(MP4SegmentMuxer.fourCCDescription(sourceTag)) must not fail the header")
        }
    }

    private static func data(_ base64: String) -> Data {
        guard let d = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            Issue.record("failed to decode embedded base64 fixture")
            return Data()
        }
        return d
    }
}
