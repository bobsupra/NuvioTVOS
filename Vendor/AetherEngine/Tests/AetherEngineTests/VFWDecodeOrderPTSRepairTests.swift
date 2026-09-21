import Testing
import AetherLibavcodec
@testable import AetherEngine

// #407: a VFW-carried Matroska track supplies no PTS, so `+genpts` invents one out of decode order and
// every B/P pair reaches the renderer transposed. These pin the gate that decides which streams lose
// their invented PTS.
@Suite("VFWDecodeOrderPTSRepair gate")
struct VFWDecodeOrderPTSRepairTests {

    private func shape(
        tag: UInt32,
        delay: Int32,
        codec: AVCodecID = AV_CODEC_ID_VC1
    ) -> VFWDecodeOrderPTSRepair.StreamShape {
        .init(codecTag: tag, videoDelay: delay, codecID: codec)
    }

    /// The reported shape: WVC1 in Matroska, one picture of reorder delay.
    @Test("VC-1 VFW track in Matroska loses its generated PTS")
    func vc1VFWMatroska() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "matroska,webm",
            shape: shape(tag: 0x3143_5657, delay: 1)) == true)
    }

    /// A natively mapped Matroska track carries no codec tag and gets real PTS from the container, so
    /// there is nothing invented to drop.
    @Test("Natively mapped Matroska track (codec_tag 0) keeps its PTS")
    func nativeMatroskaTrack() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "matroska,webm",
            shape: shape(tag: 0, delay: 2, codec: AV_CODEC_ID_H264)) == false)
    }

    /// No reorder delay means decode order IS presentation order, so the invented axis is the right
    /// one and touching it would only cost.
    @Test("Zero video_delay keeps its PTS: nothing can transpose")
    func zeroVideoDelay() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "matroska,webm",
            shape: shape(tag: 0x3143_5657, delay: 0)) == false)
    }

    /// Containers that do supply presentation timestamps have nothing invented to drop, whatever
    /// shape the stream has.
    @Test("Same shape in a PTS-carrying container is left alone")
    func ptsCarryingContainer() {
        for format in ["mov,mp4,m4a,3gp,3g2,mj2", "asf", "mpegts"] {
            #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
                formatName: format,
                shape: shape(tag: 0x3143_5657, delay: 1)) == false,
                "\(format) must not arm the repair")
        }
    }

    /// The measured AVI: a 2000s XviD rip, tag `XVID`, one picture of reorder delay. `avidec` has no
    /// PTS to give, so the `+genpts` axis is decode order exactly as in the Matroska case.
    @Test("XviD AVI loses its generated PTS")
    func xvidAVI() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "avi",
            shape: shape(tag: 0x4449_5658, delay: 1, codec: AV_CODEC_ID_MPEG4)) == true)
    }

    /// AVI has no natively mapped flavour to distinguish, so the codec tag carries no signal there and
    /// its absence must not veto the repair the way it does on Matroska.
    @Test("AVI does not gate on the codec tag")
    func aviIgnoresCodecTag() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "avi",
            shape: shape(tag: 0, delay: 1, codec: AV_CODEC_ID_MPEG4)) == true)
    }

    /// The two exclusions hold in AVI as well: nothing to transpose, and the natively routable codecs
    /// whose packets can reach the fMP4 muxer.
    @Test("AVI keeps the shared exclusions")
    func aviExclusions() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "avi",
            shape: shape(tag: 0x4449_5658, delay: 0, codec: AV_CODEC_ID_MPEG4)) == false,
            "no reorder delay means decode order is presentation order")
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "avi",
            shape: shape(tag: 0x3436_3268, delay: 1, codec: AV_CODEC_ID_H264)) == false,
            "H.264 can route natively and must keep its PTS")
    }

    /// H.264 / HEVC / AV1 can stay on the native path, where packets reach the fMP4 muxer and a
    /// timestamp-less packet is refused outright. A bad picture beats no playback.
    @Test("Natively routable codecs keep their PTS even when VFW-carried")
    func nativelyRoutableCodecsExcluded() {
        for codec in [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1] {
            #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
                formatName: "matroska,webm",
                shape: shape(tag: 0x3143_5657, delay: 1, codec: codec)) == false,
                "\(codec) routes natively and must keep its PTS")
        }
    }

    /// The software-path long tail that shares VC-1's carriage.
    @Test("Other VFW-carried software-path codecs are repaired")
    func otherSoftwarePathCodecs() {
        for codec in [AV_CODEC_ID_WMV3, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MSMPEG4V3] {
            #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
                formatName: "matroska,webm",
                shape: shape(tag: 0x3143_5657, delay: 1, codec: codec)) == true,
                "\(codec) takes the software path and should be repaired")
        }
    }

    /// libavformat registers both flavours under one comma-joined name, so the match is per element.
    @Test("Matroska name matching is per element, not substring")
    func matroskaNameMatching() {
        #expect(VFWDecodeOrderPTSRepair.isMatroska("matroska,webm") == true)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("matroska") == true)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("webm") == true)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("avi") == false)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("") == false)
    }

    /// Same per-element match for AVI, so a comma-joined alias cannot slip past either.
    @Test("AVI name matching is per element, not substring")
    func aviNameMatching() {
        #expect(VFWDecodeOrderPTSRepair.isAVI("avi") == true)
        #expect(VFWDecodeOrderPTSRepair.isAVI("matroska,webm") == false)
        #expect(VFWDecodeOrderPTSRepair.isAVI("avisynth") == false)
        #expect(VFWDecodeOrderPTSRepair.isAVI("") == false)
    }
}
