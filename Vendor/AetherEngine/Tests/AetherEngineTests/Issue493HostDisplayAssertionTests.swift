import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#493 / AE#459: what the host asserts about a display the engine cannot observe.
///
/// The two issues are the same gap from two sides. macOS has no per-mode capability API at all
/// (`AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`), and on tvOS the panel-mode readout
/// answers only around a dynamic-range transition, which a panel parked in HDR never makes and which
/// one tvOS 27 box stopped answering entirely. Both are closed by letting the host claim it, and by
/// keeping a wrong claim cheap.
struct Issue493HostDisplayAssertionTests {

    private let stub = DisplayCapabilities(
        supportsHDR: false, supportsDolbyVision: false, supportsHDR10: false, supportsHLG: false)
    private let eligibleMac = DisplayCapabilities.onDemandEDRDisplay(hdrEligible: true)

    // MARK: - The capability assertion

    @Test("AE#493: the assertion claims Dolby Vision where nothing could observe it")
    func assertionClaimsDolbyVision() {
        #expect(eligibleMac.supportsDolbyVision == false)
        #expect(eligibleMac.assertingDolbyVision(true).supportsDolbyVision)
    }

    @Test("AE#493: HDR rides along, because a display presenting DV presents HDR")
    func assertionEntailsHDR() {
        #expect(stub.assertingDolbyVision(true).supportsHDR)
    }

    @Test("AE#493: HDR10 and HLG are not implied by a Dolby Vision claim")
    func assertionDoesNotInventTheOtherFlavours() {
        let asserted = stub.assertingDolbyVision(true)
        #expect(asserted.supportsHDR10 == false)
        #expect(asserted.supportsHLG == false)
    }

    @Test("AE#493: an assertion only ever adds, so false cannot hide an observed capability")
    func assertionNeverRemoves() {
        let dvPanel = DisplayCapabilities(
            supportsHDR: true, supportsDolbyVision: true, supportsHDR10: true, supportsHLG: true)
        #expect(dvPanel.assertingDolbyVision(false) == dvPanel)
        #expect(eligibleMac.assertingDolbyVision(false) == eligibleMac)
    }

    // MARK: - What the assertion changes about the source

    @Test("AE#493: a DV source on an asserted display keeps Dolby Vision instead of its base layer")
    func assertedDisplayKeepsDolbyVision() {
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084,
            capabilities: eligibleMac) == .hdr10)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084,
            capabilities: eligibleMac.assertingDolbyVision(true)) == .dolbyVision)
    }

    @Test("AE#493: the all-false table is what collapsed a DV source to SDR")
    func stubTableCollapsesDolbyVisionToSDR() {
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_SMPTE2084, capabilities: stub) == .sdr)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_ARIB_STD_B67, capabilities: stub) == .sdr)
    }

    @Test("AE#493: an HLG-base DV source falls to HLG, not to the PQ base")
    func hlgBaseFallsToHLG() {
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision, baseTransfer: AVCOL_TRC_ARIB_STD_B67,
            capabilities: eligibleMac) == .hlg)
    }

    /// The correction the reporter's measurement forced onto the split: the clamp returns early for
    /// anything that is not Dolby Vision, so the capability table never reached a plain HDR10 or HLG
    /// source at all. "Every PQ source plays as SDR" was the label branch, not this one.
    @Test("AE#493: the capability table never touches a source that is not Dolby Vision")
    func nonDVSourcesBypassTheTableEntirely() {
        for format in [VideoFormat.hdr10, .hlg, .sdr] {
            #expect(AetherEngine.effectiveVideoFormat(
                detected: format, baseTransfer: AVCOL_TRC_SMPTE2084, capabilities: stub) == format)
        }
    }

    /// Why `supportsHDR` rides along with the DV claim: without it the routing gate that decides
    /// master-vs-media would have sent the asserted DV session media-direct, and a DV source served
    /// through a bare media playlist is the HDR10 base layer, which is exactly what the assertion
    /// exists to stop.
    @Test("AE#493: an asserted display routes the DV master rather than the base layer")
    func assertedDisplayRoutesTheMaster() {
        let asserted = stub.assertingDolbyVision(true)
        #expect(HLSVideoEngine.resolveUseMasterPlaylist(
            videoRange: .pq, effectiveDvMode: true, panelIsInHDRMode: false,
            displaySupportsHDR: asserted.supportsHDR, hasNativeSubs: false,
            builtInPanelEngagesOnDemand: true, frameRateKnown: true))
        #expect(HLSVideoEngine.resolveUseMasterPlaylist(
            videoRange: .pq, effectiveDvMode: true, panelIsInHDRMode: false,
            displaySupportsHDR: stub.supportsHDR, hasNativeSubs: false,
            builtInPanelEngagesOnDemand: true, frameRateKnown: true) == false)
    }

    // MARK: - The panel-mode assertion (AE#459)

    @Test("AE#459: the host assertion is an OR term over the readout, not a replacement")
    func panelAssertionIsAnORTerm() {
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: true, criteriaReadout: false))
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: false, criteriaReadout: true))
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: true, criteriaReadout: true))
    }

    @Test("AE#459: asserting nothing leaves the readout in charge, which is the shipping default")
    func noAssertionKeepsTheReadout() {
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: false, criteriaReadout: false) == false)
        #expect(LoadOptions().panelIsInHDRMode == false)
    }

    @Test("AE#459: a suppressed-criteria session has no readout, so the assertion is the whole answer")
    func suppressedSessionRestsOnTheAssertion() {
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: true, criteriaReadout: nil))
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: false, criteriaReadout: nil) == false)
    }

    // MARK: - The option itself

    @Test("AE#493: the DV assertion is off by default, so an unchanged host is unchanged")
    func assertionDefaultsOff() {
        #expect(LoadOptions().panelPresentsDolbyVision == false)
    }

    @Test("AE#493: two option sets differing only in the assertion are not equal")
    func assertionParticipatesInEquality() {
        #expect(LoadOptions(panelPresentsDolbyVision: true) != LoadOptions(panelPresentsDolbyVision: false))
    }

    /// AE#460: the assertion is a correction, not an identity. A host that learns the display does DV
    /// after the session started can say so without restarting the item.
    @Test("AE#493: the assertion is correctable mid-session")
    func assertionIsCorrectable() {
        #expect(SessionOptionCorrection.knownFields.contains("panelPresentsDolbyVision"))
        #expect(SessionOptionCorrection.loadIdentityFields.contains("panelPresentsDolbyVision") == false)
        let corrected = SessionOptionCorrection.changedFields(
            from: LoadOptions(), to: LoadOptions(panelPresentsDolbyVision: true))
        #expect(corrected == ["panelPresentsDolbyVision"])
        #expect(SessionOptionCorrection.refusedFields(
            from: LoadOptions(), to: LoadOptions(panelPresentsDolbyVision: true)).isEmpty)
    }

    // MARK: - What the assertion no longer changes about the served bytes

    /// An HEVC / AV1 `AVCodecParameters` carrying a DOVI configuration record, freed with the test.
    private final class DVCodecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init(codecID: AVCodecID, profile: UInt8, compat: UInt8, trc: AVColorTransferCharacteristic) {
            ptr = avcodec_parameters_alloc()
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = codecID
            ptr.pointee.width = 3840
            ptr.pointee.height = 2160
            ptr.pointee.level = 153
            ptr.pointee.color_primaries = AVCOL_PRI_BT2020
            ptr.pointee.color_trc = trc
            ptr.pointee.color_space = AVCOL_SPC_BT2020_NCL
            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            guard let sd = av_packet_side_data_new(
                &ptr.pointee.coded_side_data, &ptr.pointee.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF, size, 0
            ) else { fatalError("could not attach a DOVI configuration record") }
            memset(sd.pointee.data, 0, size)
            sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_version_major = 1
                rec.pointee.dv_profile = profile
                rec.pointee.dv_level = 6
                rec.pointee.rpu_present_flag = 1
                rec.pointee.el_present_flag = profile == 7 ? 1 : 0
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = compat
            }
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private static func route(
        codecID: AVCodecID = AV_CODEC_ID_HEVC,
        profile: UInt8,
        compat: UInt8,
        trc: AVColorTransferCharacteristic = AVCOL_TRC_SMPTE2084,
        dvDisplay: Bool
    ) throws -> HLSVideoEngine.CodecRoute {
        let par = DVCodecpar(codecID: codecID, profile: profile, compat: compat, trc: trc)
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/dev/null"), dvModeAvailable: dvDisplay)
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr))
    }

    /// Everything the muxer and the manifest read out of a route, as one comparable line.
    private static func packaging(_ r: HLSVideoEngine.CodecRoute) -> String {
        "tag=\(r.codecTagOverride ?? "nil") range=\(r.videoRange) codecs=\(r.primaryCodecs) "
        + "supplemental=\(r.supplementalCodecs ?? "nil") dovi=\(r.doviConfig) "
        + "p7convert=\(r.convertP7ToProfile81) variant=\(r.dvVariant)"
    }

    /// 6.72.0 gave the non-DV branch its `dvcC` back and 6.73.0 its `SUPPLEMENTAL-CODECS`, which left the
    /// three grades a Dolby Vision display used to be served differently identical on both branches. So
    /// the assertion no longer decides a byte of the served stream for them, only the published
    /// `videoFormat`, the tvOS criteria request, and the HDR readiness that rides along. Measured the
    /// same day against the matched Dolby P5 / P8.1 / P8.4 grades on macOS: master, media playlist,
    /// init.mp4 and seg0.mp4 came back md5-identical with and without the claim.
    @Test("AE#493: the assertion does not move the packaging of P5, P8.1 or P8.4",
          arguments: [(UInt8(5), UInt8(0)), (UInt8(8), UInt8(1)), (UInt8(8), UInt8(4))])
    func assertionLeavesTheHEVCPackagingAlone(grade: (profile: UInt8, compat: UInt8)) throws {
        let trc: AVColorTransferCharacteristic = grade.compat == 4 ? AVCOL_TRC_ARIB_STD_B67 : AVCOL_TRC_SMPTE2084
        let asserted = try Self.route(profile: grade.profile, compat: grade.compat, trc: trc, dvDisplay: true)
        let control = try Self.route(profile: grade.profile, compat: grade.compat, trc: trc, dvDisplay: false)
        #expect(Self.packaging(asserted) == Self.packaging(control))
    }

    /// The two grades where it still does, so "the claim changes nothing" cannot quietly become the rule:
    /// P7 needs the per-packet RPU conversion to 8.1 and its supplemental, and the AV1 DV record is read
    /// only on a display that takes it, so a non-DV display gets the base layer with no supplemental and
    /// no Dolby Vision variant at all. Since #547 both AV1 branches carry the same `av01` sample entry,
    /// the base layer's own; what the claim moves there is the supplemental entry beside it.
    @Test("AE#493: P7 and AV1 Dolby Vision are still packaged by the claim")
    func assertionStillMovesTheGatedGrades() throws {
        let p7Asserted = try Self.route(profile: 7, compat: 0, dvDisplay: true)
        let p7Control = try Self.route(profile: 7, compat: 0, dvDisplay: false)
        #expect(Self.packaging(p7Asserted) != Self.packaging(p7Control))
        #expect(p7Asserted.convertP7ToProfile81)
        #expect(p7Control.convertP7ToProfile81 == false)

        let av1Asserted = try Self.route(codecID: AV_CODEC_ID_AV1, profile: 10, compat: 1, dvDisplay: true)
        let av1Control = try Self.route(codecID: AV_CODEC_ID_AV1, profile: 10, compat: 1, dvDisplay: false)
        #expect(Self.packaging(av1Asserted) != Self.packaging(av1Control))
        #expect(av1Asserted.codecTagOverride == "av01")
        #expect(av1Control.codecTagOverride == "av01")
        #expect(av1Asserted.supplementalCodecs == "dav1.10.06/db1p")
        #expect(av1Control.supplementalCodecs == nil)
    }
}
