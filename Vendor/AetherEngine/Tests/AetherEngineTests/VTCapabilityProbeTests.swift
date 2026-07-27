import Testing
import AetherLibavcodec
@testable import AetherEngine

/// AetherPlayer#2 finding 2: `canHardwareDecode` builds a format description from the avcC / hvcC and
/// asks VideoToolbox for a hardware session. A record whose parameter sets live IN-BAND (`hev1`, what
/// `MP4Box ...:xps_inband` and the common Dolby-Vision MP4 authoring recipes produce) still parses as a
/// valid config record, so `CMVideoFormatDescriptionCreate` succeeds and only the session create fails,
/// with no SPS to configure the decoder. That is a false negative: the stream is hardware-decodable once
/// the in-band SPS arrives, but the probe force-routed it to the software path on every platform.
/// These cover the pure classifier that closes the gap.
@Suite("VT capability probe config classification")
struct VTCapabilityProbeTests {

    /// The exact 23-byte hvcC of Dolby's official Profile 8.1 asset (dolby-vision-contents,
    /// SolLevante 1080p24). numOfArrays (last byte) is 0: every parameter set is in-band.
    static let dolbyInBandHvcC: [UInt8] = [
        0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x99, 0xf0, 0x00, 0xfc, 0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x00,
    ]

    /// Same header shape written by an ordinary hvc1 encode: numOfArrays = 3 (VPS, SPS, PPS).
    static let outOfBandHvcC: [UInt8] = [
        0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x5a, 0xf0, 0x00, 0xfc, 0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x03,
    ]

    @Test("hvcC with numOfArrays = 0 (in-band xPS) carries no parameter sets")
    func hevcInBandParameterSets() {
        #expect(!VTCapabilityProbe.configRecordCarriesParameterSets(
            Self.dolbyInBandHvcC, codecID: AV_CODEC_ID_HEVC))
    }

    @Test("hvcC with parameter-set arrays carries parameter sets")
    func hevcOutOfBandParameterSets() {
        #expect(VTCapabilityProbe.configRecordCarriesParameterSets(
            Self.outOfBandHvcC, codecID: AV_CODEC_ID_HEVC))
    }

    @Test("hvcC truncated before numOfArrays is not classifiable")
    func hevcTruncatedRecord() {
        #expect(!VTCapabilityProbe.configRecordCarriesParameterSets(
            Array(Self.outOfBandHvcC.prefix(13)), codecID: AV_CODEC_ID_HEVC))
    }

    @Test("avcC with numOfSequenceParameterSets = 0 carries no parameter sets")
    func avcNoSPS() {
        let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x28, 0xff, 0xe0]
        #expect(!VTCapabilityProbe.configRecordCarriesParameterSets(
            avcC, codecID: AV_CODEC_ID_H264))
    }

    @Test("avcC with one SPS carries parameter sets")
    func avcOneSPS() {
        let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x28, 0xff, 0xe1, 0x00, 0x04, 0x67, 0x64, 0x00, 0x28]
        #expect(VTCapabilityProbe.configRecordCarriesParameterSets(
            avcC, codecID: AV_CODEC_ID_H264))
    }

    @Test("avcC truncated before the SPS count is not classifiable")
    func avcTruncatedRecord() {
        #expect(!VTCapabilityProbe.configRecordCarriesParameterSets(
            [0x01, 0x64, 0x00], codecID: AV_CODEC_ID_H264))
    }
}
