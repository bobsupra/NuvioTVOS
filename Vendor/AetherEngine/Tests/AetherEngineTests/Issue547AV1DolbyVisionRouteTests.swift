import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#547 (DrHurt): Dolby Vision over AV1, the Profile 10 family.
///
/// Two separate claims live here, and they failed for two different reasons.
///
/// Profile 10.0 is the AV1 analogue of HEVC Profile 5: IPT-PQ-c2, no compatible base layer, so the
/// sample entry has to be `dav1` and `av01` is not an alternative. FFmpeg's mp4 muxer validates a
/// requested `codec_tag` against `codec_mp4_tags` in `movenc.c`, which carries `av01` and, for the
/// HEVC side, `dvh1`, but not `dav1`. A requested tag that is not in that table resolves to 0 and
/// `avformat_write_header` returns EINVAL, so the route could never produce an init segment at all.
/// FFmpegBuild carries the two-line addition (`patch_ffmpeg_dav1_tag`); the probe below is what
/// notices if a future FFmpeg bump drops it.
///
/// Profile 10.1 is the analogue of HEVC Profile 8.1: an HDR10-compatible base layer. Apple's HLS
/// authoring spec packages that as an `av01` sample entry with `SUPPLEMENTAL-CODECS="dav1.10.XX/db1p"`
/// and `VIDEO-RANGE=PQ`, exactly the way 10.4 is packaged with `db4h` and HLG. It was routed here as a
/// bare `dav1` instead, which is the packaging of a source without a base layer.
///
/// Everything here is a claim about the ROUTE and about what the muxer accepts. Whether a panel
/// composes the result is a question for a panel.
@Suite("AE#547: Dolby Vision over AV1, Profile 10.0 and 10.1")
struct Issue547AV1DolbyVisionRouteTests {

    // MARK: - Harness

    /// An AV1 `AVCodecParameters` carrying a DOVI configuration record, freed with the test.
    /// The `av1C` extradata is a real one (320x240 10-bit, SVT-AV1), because the mp4 muxer writes the
    /// box from it and a header written without one proves nothing about the sample entry.
    private final class AV1DVCodecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        static let av1C: [UInt8] = [
            0x81, 0x00, 0x4c, 0x00, 0x0a, 0x0b, 0x00, 0x00,
            0x00, 0x04, 0x3c, 0xff, 0xbc, 0x02, 0xf8, 0x40, 0x40
        ]

        init(blCompatibilityID: UInt8, dvLevel: UInt8 = 6,
             trc: AVColorTransferCharacteristic = AVCOL_TRC_SMPTE2084,
             matrix: AVColorSpace = AVCOL_SPC_BT2020_NCL,
             primaries: AVColorPrimaries = AVCOL_PRI_BT2020) {
            ptr = avcodec_parameters_alloc()
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = AV_CODEC_ID_AV1
            ptr.pointee.width = 3840
            ptr.pointee.height = 2160
            ptr.pointee.profile = 0
            ptr.pointee.level = 8
            ptr.pointee.bits_per_raw_sample = 10
            ptr.pointee.color_primaries = primaries
            ptr.pointee.color_trc = trc
            ptr.pointee.color_space = matrix

            let extra = av_malloc(Self.av1C.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))
            guard let extra else { fatalError("could not allocate extradata") }
            memset(extra, 0, Self.av1C.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))
            Self.av1C.withUnsafeBytes { _ = memcpy(extra, $0.baseAddress!, Self.av1C.count) }
            ptr.pointee.extradata = extra.assumingMemoryBound(to: UInt8.self)
            ptr.pointee.extradata_size = Int32(Self.av1C.count)

            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            guard let sd = av_packet_side_data_new(
                &ptr.pointee.coded_side_data,
                &ptr.pointee.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF,
                size,
                0
            ) else {
                fatalError("could not attach a DOVI configuration record")
            }
            memset(sd.pointee.data, 0, size)
            sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_version_major = 1
                rec.pointee.dv_version_minor = 0
                rec.pointee.dv_profile = 10
                rec.pointee.dv_level = dvLevel
                rec.pointee.rpu_present_flag = 1
                rec.pointee.el_present_flag = 0
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = blCompatibilityID
            }
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private static func route(_ par: AV1DVCodecpar, dvDisplay: Bool = true) throws -> HLSVideoEngine.CodecRoute {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/dev/null"),
            dvModeAvailable: dvDisplay
        )
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr))
    }

    // MARK: - Profile 10.0: the dav1 sample entry

    @Test("Profile 10.0 is served as dav1, the AV1 shape of a source without a base layer")
    func profile100RoutesAsDav1() throws {
        let r = try Self.route(AV1DVCodecpar(blCompatibilityID: 0,
                                             trc: AVCOL_TRC_UNSPECIFIED,
                                             matrix: AVCOL_SPC_UNSPECIFIED,
                                             primaries: AVCOL_PRI_UNSPECIFIED))
        #expect(r.codecTagOverride == "dav1")
        #expect(r.videoRange == .pq)
        #expect(r.primaryCodecs == "dav1.10.06")
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .keep)
        #expect(r.dvVariant == .av1Profile10)
    }

    @Test("the mp4 muxer accepts the dav1 sample entry (FFmpegBuild patch_ffmpeg_dav1_tag)")
    func muxerAcceptsDav1Tag() throws {
        let par = AV1DVCodecpar(blCompatibilityID: 0,
                                trc: AVCOL_TRC_UNSPECIFIED,
                                matrix: AVCOL_SPC_UNSPECIFIED,
                                primaries: AVCOL_PRI_UNSPECIFIED)
        let ret = MP4SegmentMuxer.probeWriteHeader(
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(par.ptr),
                timeBase: AVRational(num: 1, den: 24_000),
                codecTagOverride: "dav1",
                doviConfig: .keep
            ),
            audio: nil
        )
        // Stock FFmpeg returns -22 (EINVAL) here: validate_codec_tag() finds no dav1 for AV1 and
        // mov_init bails with "codec not currently supported in container".
        #expect(ret == 0)
    }

    @Test("the av01 sample entry keeps working next to it")
    func muxerStillAcceptsAv01Tag() throws {
        let par = AV1DVCodecpar(blCompatibilityID: 1)
        let ret = MP4SegmentMuxer.probeWriteHeader(
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(par.ptr),
                timeBase: AVRational(num: 1, den: 24_000),
                codecTagOverride: "av01",
                doviConfig: .keep
            ),
            audio: nil
        )
        #expect(ret == 0)
    }

    // MARK: - Profile 10.1: the cross-compatible packaging

    @Test("Profile 10.1 is served as av01 with a dav1 SUPPLEMENTAL, the way 10.4 is")
    func profile101RoutesAsAv01WithSupplemental() throws {
        let r = try Self.route(AV1DVCodecpar(blCompatibilityID: 1))
        #expect(r.codecTagOverride == "av01")
        #expect(r.videoRange == .pq)
        #expect(r.primaryCodecs == "av01.0.08M.10.0.111.09.16.09.0")
        #expect(r.supplementalCodecs == "dav1.10.06/db1p")
        #expect(r.doviConfig == .keep)
        #expect(r.dvVariant == .av1Profile101)
    }

    @Test("Profile 10.4 keeps its HLG packaging")
    func profile104Unchanged() throws {
        let r = try Self.route(AV1DVCodecpar(blCompatibilityID: 4, trc: AVCOL_TRC_ARIB_STD_B67))
        #expect(r.codecTagOverride == "av01")
        #expect(r.videoRange == .hlg)
        #expect(r.supplementalCodecs == "dav1.10.06/db4h")
        #expect(r.doviConfig == .keep)
    }

    @Test("a display without Dolby Vision gets the plain av01 base layer, no SUPPLEMENTAL")
    func profile101OnNonDVDisplay() throws {
        let r = try Self.route(AV1DVCodecpar(blCompatibilityID: 1), dvDisplay: false)
        #expect(r.codecTagOverride == "av01")
        #expect(r.videoRange == .pq)
        #expect(r.supplementalCodecs == nil)
    }
}
