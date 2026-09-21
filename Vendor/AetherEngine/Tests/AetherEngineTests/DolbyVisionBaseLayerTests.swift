import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// `LoadOptions.dolbyVisionHandling = .baseLayerOnly`: the HDR10 / HLG base layer of a Dolby Vision
/// source, the Dolby Vision left out of the container, on every display.
///
/// The case it exists for is a container record the bitstream contradicts. The reported title carries a
/// Profile 5 / compatibility 0 record (IPT-PQ-c2, no base layer) over a VUI that declares BT.2020 YCbCr
/// PQ, with an RPU whose residual and NLQ fields only a Profile 7 has. Served as the record asks, AVPlayer
/// reads YCbCr as IPT and the picture is green / violet; served as its base layer it is plain HDR10.
///
/// Everything here is a claim about the ROUTE, the format clamp and the guards. Whether the base layer
/// looks right on a panel is a question for the panel.
@Suite("dolbyVisionHandling = .baseLayerOnly: the base layer of a Dolby Vision source")
struct DolbyVisionBaseLayerTests {

    // MARK: - Harness

    /// An `AVCodecParameters` carrying a DOVI configuration record, freed with the test. The VUI is the
    /// HDR10 tuple by default; a genuine Profile 5 is built with it unspecified, as Dolby writes it.
    private final class DVCodecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init(codecID: AVCodecID = AV_CODEC_ID_HEVC,
             profile: UInt8, blCompatibilityID: UInt8, dvLevel: UInt8 = 6,
             trc: AVColorTransferCharacteristic = AVCOL_TRC_SMPTE2084,
             matrix: AVColorSpace = AVCOL_SPC_BT2020_NCL,
             primaries: AVColorPrimaries = AVCOL_PRI_BT2020) {
            ptr = avcodec_parameters_alloc()
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = codecID
            ptr.pointee.width = 3840
            ptr.pointee.height = 2160
            if codecID == AV_CODEC_ID_AV1 {
                ptr.pointee.profile = 0
                ptr.pointee.level = 8
                ptr.pointee.bits_per_raw_sample = 10
            } else {
                ptr.pointee.level = 153
            }
            ptr.pointee.color_primaries = primaries
            ptr.pointee.color_trc = trc
            ptr.pointee.color_space = matrix
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
                rec.pointee.dv_profile = profile
                rec.pointee.dv_level = dvLevel
                rec.pointee.rpu_present_flag = 1
                rec.pointee.el_present_flag = profile == 7 ? 1 : 0
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = blCompatibilityID
            }
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private static func route(
        _ par: DVCodecpar,
        dvDisplay: Bool = true,
        handling: DolbyVisionHandling,
        forceDV: Bool = false
    ) throws -> HLSVideoEngine.CodecRoute {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/dev/null"),
            dvModeAvailable: dvDisplay,
            forceDolbyVisionOnNonDVDisplay: forceDV,
            dolbyVisionHandling: handling
        )
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr))
    }

    /// The reported shape: a Profile 5 record over an HDR10 VUI.
    private static func relabelledProfile5() -> DVCodecpar {
        DVCodecpar(profile: 5, blCompatibilityID: 0)
    }

    /// What Dolby writes for a real Profile 5: the VUI unspecified, IPT-PQ-c2 having no code point.
    private static func genuineProfile5() -> DVCodecpar {
        DVCodecpar(profile: 5, blCompatibilityID: 0,
                   trc: AVCOL_TRC_UNSPECIFIED, matrix: AVCOL_SPC_UNSPECIFIED, primaries: AVCOL_PRI_UNSPECIFIED)
    }

    // MARK: - The route, HEVC

    @Test("Profile 8.1 on a Dolby Vision display is served as its HDR10 base layer")
    func profile81BaseLayer() throws {
        let r = try Self.route(DVCodecpar(profile: 8, blCompatibilityID: 1), handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .pq)
        // No hvcC on the harness codecpar: the plain-HEVC fallback, the same the P8.2 strip route uses.
        #expect(r.primaryCodecs == "hvc1.2.4.L153")
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .strip)
        #expect(r.convertP7ToProfile81 == false)
        // The source is still what it is; only the container claim moves.
        #expect(r.dvVariant == .profile81)
    }

    @Test("Profile 8.4 keeps its HLG range on the base-layer route")
    func profile84BaseLayer() throws {
        let r = try Self.route(DVCodecpar(profile: 8, blCompatibilityID: 4, trc: AVCOL_TRC_ARIB_STD_B67),
                               handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .hlg)
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .strip)
    }

    @Test("Profile 7 on a Dolby Vision display is neither converted nor supplemented")
    func profile7BaseLayer() throws {
        let par = DVCodecpar(profile: 7, blCompatibilityID: 6)
        let automatic = try Self.route(par, handling: .automatic)
        #expect(automatic.convertP7ToProfile81 == true)
        #expect(automatic.doviConfig == .rewriteToProfile81)
        #expect(automatic.supplementalCodecs == "dvh1.08.06/db1p")

        let base = try Self.route(par, handling: .baseLayerOnly)
        #expect(base.codecTagOverride == "hvc1")
        #expect(base.videoRange == .pq)
        #expect(base.convertP7ToProfile81 == false)
        #expect(base.doviConfig == .strip)
        #expect(base.supplementalCodecs == nil)
        #expect(base.dvVariant == .profile7)
    }

    @Test("a Profile 5 record over an HDR10 VUI is served as that HDR10 base layer")
    func relabelledProfile5BaseLayer() throws {
        let r = try Self.route(Self.relabelledProfile5(), handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .pq)
        #expect(r.primaryCodecs == "hvc1.2.4.L153")
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .strip)
        #expect(r.dvVariant == .profile5)
    }

    @Test("the same record on the default route is still served as Profile 5")
    func relabelledProfile5DefaultRouteUnchanged() throws {
        let r = try Self.route(Self.relabelledProfile5(), handling: .automatic)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.doviConfig == .keep)
    }

    @Test("a genuine Profile 5 has no base layer to present and keeps its route")
    func genuineProfile5KeepsItsRoute() throws {
        let r = try Self.route(Self.genuineProfile5(), handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.videoRange == .pq)
        #expect(r.doviConfig == .keep)
    }

    @Test("the base layer wins over the AE#455 masquerade on a display without Dolby Vision")
    func baseLayerWinsOverForcedDV() throws {
        let par = DVCodecpar(profile: 8, blCompatibilityID: 1)
        let forced = try Self.route(par, dvDisplay: false, handling: .automatic, forceDV: true)
        #expect(forced.codecTagOverride == "dvh1")
        #expect(forced.doviConfig == .rewriteToProfile5)

        let base = try Self.route(par, dvDisplay: false, handling: .baseLayerOnly, forceDV: true)
        #expect(base.codecTagOverride == "hvc1")
        #expect(base.doviConfig == .strip)
        #expect(base.supplementalCodecs == nil)
    }

    @Test("a plain HDR10 source is untouched by the option")
    func plainHDR10Untouched() throws {
        let par = DVCodecpar(profile: 8, blCompatibilityID: 1)
        MP4SegmentMuxer.stripDolbyVisionSideData(par.ptr)   // now a plain Main10 PQ stream
        let r = try Self.route(par, handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .pq)
        #expect(r.doviConfig == .keep)
        #expect(r.dvVariant == .none)
    }

    // MARK: - The route, AV1

    @Test("AV1 Profile 10.1 is served as plain av01 with the record stripped")
    func av1Profile101BaseLayer() throws {
        let r = try Self.route(DVCodecpar(codecID: AV_CODEC_ID_AV1, profile: 10, blCompatibilityID: 1),
                               handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "av01")
        #expect(r.videoRange == .pq)
        #expect(r.primaryCodecs == "av01.0.08M.10.0.111.09.16.09.0")
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .strip)
        #expect(r.dvVariant == .av1Profile101)
    }

    @Test("a genuine AV1 Profile 10.0 keeps its dav1 route")
    func av1Profile10KeepsItsRoute() throws {
        let par = DVCodecpar(codecID: AV_CODEC_ID_AV1, profile: 10, blCompatibilityID: 0,
                             trc: AVCOL_TRC_UNSPECIFIED, matrix: AVCOL_SPC_UNSPECIFIED,
                             primaries: AVCOL_PRI_UNSPECIFIED)
        let r = try Self.route(par, handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "dav1")
        #expect(r.primaryCodecs == "dav1.10.06")
        #expect(r.doviConfig == .keep)
    }

    // MARK: - The predicate the route, the clamp and the guards share

    @Test("which records admit a base layer")
    func presentableBaseLayers() {
        func presentable(_ codec: AVCodecID, _ profile: Int?, _ compat: Int?,
                         trc: AVColorTransferCharacteristic = AVCOL_TRC_SMPTE2084,
                         matrix: AVColorSpace = AVCOL_SPC_BT2020_NCL) -> Bool {
            VideoRoutingPolicy.dolbyVisionBaseLayerIsPresentable(
                codecID: codec, dvProfile: profile, dvBlCompatID: compat,
                colorTransfer: trc, colorMatrix: matrix)
        }
        #expect(presentable(AV_CODEC_ID_HEVC, 8, 1))
        #expect(presentable(AV_CODEC_ID_HEVC, 8, 4, trc: AVCOL_TRC_ARIB_STD_B67))
        #expect(presentable(AV_CODEC_ID_HEVC, 8, 2, trc: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709))
        #expect(presentable(AV_CODEC_ID_HEVC, 7, 6))
        // Profile 5: the VUI decides.
        #expect(presentable(AV_CODEC_ID_HEVC, 5, 0))
        #expect(presentable(AV_CODEC_ID_HEVC, 5, 0, trc: AVCOL_TRC_ARIB_STD_B67, matrix: AVCOL_SPC_BT2020_CL))
        #expect(!presentable(AV_CODEC_ID_HEVC, 5, 0, trc: AVCOL_TRC_UNSPECIFIED, matrix: AVCOL_SPC_UNSPECIFIED))
        // A PQ transfer alone is not a YCbCr base: the matrix is the term IPT cannot declare.
        #expect(!presentable(AV_CODEC_ID_HEVC, 5, 0, matrix: AVCOL_SPC_UNSPECIFIED))
        #expect(!presentable(AV_CODEC_ID_HEVC, 5, 0, trc: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709))
        #expect(presentable(AV_CODEC_ID_AV1, 10, 1))
        #expect(presentable(AV_CODEC_ID_AV1, 10, 4, trc: AVCOL_TRC_ARIB_STD_B67))
        #expect(presentable(AV_CODEC_ID_AV1, 10, 0))
        #expect(!presentable(AV_CODEC_ID_AV1, 10, 0, trc: AVCOL_TRC_UNSPECIFIED, matrix: AVCOL_SPC_UNSPECIFIED))
        // Not Dolby Vision at all.
        #expect(!presentable(AV_CODEC_ID_HEVC, nil, nil))
        #expect(!presentable(AV_CODEC_ID_H264, 9, 0))
    }

    @Test("the default handling never presents a base layer, whatever the source")
    func automaticPresentsNothing() {
        #expect(!VideoRoutingPolicy.presentsDolbyVisionBaseLayer(
            handling: .automatic, codecID: AV_CODEC_ID_HEVC, dvProfile: 8, dvBlCompatID: 1,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
        #expect(VideoRoutingPolicy.presentsDolbyVisionBaseLayer(
            handling: .baseLayerOnly, codecID: AV_CODEC_ID_HEVC, dvProfile: 8, dvBlCompatID: 1,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    @Test("the software-path refusal for Profile 5 stands down when the base layer is presented")
    func softwarePathRefusalLifted() {
        #expect(VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5, dvBlCompatID: 0))
        #expect(!VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5, dvBlCompatID: 0, presentsDolbyVisionBaseLayer: true))
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false, preferred: .software, codecID: AV_CODEC_ID_HEVC,
            dvProfile: 5, dvBLCompatID: 0, isLive: false, hasCompanionAudioReader: false)
            == .softwarePathCannotRepresentSource)
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false, preferred: .software, codecID: AV_CODEC_ID_HEVC,
            dvProfile: 5, dvBLCompatID: 0, presentsDolbyVisionBaseLayer: true,
            isLive: false, hasCompanionAudioReader: false) == nil)
    }

    // MARK: - The format clamp and the criteria it feeds

    @Test("with Dolby Vision left unclaimed a DV source resolves to the format of its base layer")
    func formatClampReadsTheBaseLayer() {
        let dvDisplay = DisplayCapabilities(
            supportsHDR: true, supportsDolbyVision: true, supportsHDR10: true, supportsHLG: true)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084, capabilities: dvDisplay) == .dolbyVision)
        let unclaimed = dvDisplay.withoutDolbyVision()
        #expect(unclaimed.supportsHDR)
        #expect(!unclaimed.supportsDolbyVision)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084, capabilities: unclaimed) == .hdr10)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_ARIB_STD_B67, capabilities: unclaimed) == .hlg)
        // A display that never claimed Dolby Vision is returned as it is.
        let hdr10Only = DisplayCapabilities(
            supportsHDR: true, supportsDolbyVision: false, supportsHDR10: true, supportsHLG: false)
        #expect(hdr10Only.withoutDolbyVision() == hdr10Only)
    }

    // MARK: - A tuning field

    @Test("the option is correctable on a playing session, not a load identity")
    func correctableThroughReload() {
        var proposed = LoadOptions()
        proposed.dolbyVisionHandling = .baseLayerOnly
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: proposed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: LoadOptions(), to: proposed) == ["dolbyVisionHandling"])
    }
}
