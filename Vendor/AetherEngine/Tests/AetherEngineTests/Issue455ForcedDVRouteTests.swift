import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#455 (DrHurt): on a display with no Dolby Vision of its own, a Profile 8.1 source reaches the panel
/// as its bare HDR10 base layer with one static grade, because that is all `hvc1` + a stripped `dvcC`
/// can be. A Profile 5 source on the same panel does NOT: AVPlayer runs its own DV composition and
/// applies the per-frame RPU to the pixels before they leave the Apple TV.
///
/// The opt-in closes that gap by serving the 8.1 the way the 5 is served. The bitstream is untouched;
/// what changes is the container's claim about it: `dvh1` sample entry, `dvcC` rewritten to profile 5 /
/// compatibility 0, and `CODECS="dvh1.05.LL"` in the master. A P8.1 RPU already carries the mapping out
/// of its own HDR10 base layer, which is why the composer does not need the container to describe it.
///
/// Everything here is a claim about the ROUTE and the container bytes. Whether the composed picture is
/// actually better than the HDR10 base layer is a question for a panel, not for a test.
@Suite("AE#455: Profile 8.1 served as Profile 5 on a display without Dolby Vision")
struct Issue455ForcedDVRouteTests {

    // MARK: - Harness

    /// An HEVC `AVCodecParameters` carrying a DOVI configuration record, freed with the test.
    private final class DVCodecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init(profile: UInt8, blCompatibilityID: UInt8, dvLevel: UInt8 = 6, trc: AVColorTransferCharacteristic = AVCOL_TRC_SMPTE2084) {
            ptr = avcodec_parameters_alloc()
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = AV_CODEC_ID_HEVC
            ptr.pointee.width = 3840
            ptr.pointee.height = 2160
            ptr.pointee.level = 153
            ptr.pointee.color_primaries = AVCOL_PRI_BT2020
            ptr.pointee.color_trc = trc
            ptr.pointee.color_space = AVCOL_SPC_BT2020_NCL
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
                rec.pointee.el_present_flag = 0
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = blCompatibilityID
            }
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }

        /// The DOVI record as it stands now, i.e. after whatever the muxer did to it.
        var record: AVDOVIDecoderConfigurationRecord? {
            let count = Int(ptr.pointee.nb_coded_side_data)
            guard count > 0, let sideData = ptr.pointee.coded_side_data else { return nil }
            for i in 0..<count where sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                guard let raw = sideData[i].data else { return nil }
                return raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
            }
            return nil
        }
    }

    private static func route(
        profile: UInt8,
        compat: UInt8,
        dvLevel: UInt8 = 6,
        trc: AVColorTransferCharacteristic = AVCOL_TRC_SMPTE2084,
        dvDisplay: Bool,
        forceDV: Bool
    ) throws -> HLSVideoEngine.CodecRoute {
        let par = DVCodecpar(profile: profile, blCompatibilityID: compat, dvLevel: dvLevel, trc: trc)
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/dev/null"),
            dvModeAvailable: dvDisplay,
            forceDolbyVisionOnNonDVDisplay: forceDV
        )
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr))
    }

    // MARK: - The route

    @Test("without the opt-in a non-DV display gets the base layer with its dvcC kept and no SUPPLEMENTAL")
    func defaultRouteKeepsTheRecord() throws {
        let r = try Self.route(profile: 8, compat: 1, dvDisplay: false, forceDV: false)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.primaryCodecs == "hvc1.2.4.L153")
        // AE#493: emitted on every display now. The spec pairs a plain CODECS with a DV supplemental so a
        // client that does not know dvh1 still reads the base layer, and the loopback master reaches
        // AirPlay receivers that are exactly that client.
        #expect(r.supplementalCodecs == "dvh1.08.06/db1p")
        // AE#493, tvOS 26.6: the strip that stood here defended a -11868 that no longer reproduces, and it
        // cost the RPU on every session AVPlayer has to tone-map.
        #expect(r.doviConfig == .keep)
    }

    @Test("the malformed \"P8.6\" compat id normalizes on a non-DV display too")
    func p86NormalizesWithoutDVDisplay() throws {
        let r = try Self.route(profile: 8, compat: 6, dvDisplay: false, forceDV: false)
        #expect(r.supplementalCodecs == "dvh1.08.06/db1p")
        // A kept record has to be a truthful one: dropping it hid the malformed compat before.
        #expect(r.doviConfig == .rewriteToProfile81)
    }

    @Test("with the opt-in a non-DV display gets the Profile 5 packaging")
    func forcedRouteClaimsProfile5() throws {
        let r = try Self.route(profile: 8, compat: 1, dvLevel: 6, dvDisplay: false, forceDV: true)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.videoRange == .pq)
        // A bare dvh1 variant, not a SUPPLEMENTAL upgrade: there is no DV panel to upgrade to.
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .rewriteToProfile5)
        // The source is still what it is; only the container claim moves.
        #expect(r.dvVariant == .profile81)
    }

    @Test("the source's own DV level rides into the CODECS string")
    func forcedRouteCarriesDVLevel() throws {
        let r = try Self.route(profile: 8, compat: 1, dvLevel: 9, dvDisplay: false, forceDV: true)
        #expect(r.primaryCodecs == "dvh1.05.09")
    }

    @Test("a display that does Dolby Vision keeps the P8.1 route the opt-in cannot improve on")
    func dvDisplayIgnoresTheOptIn() throws {
        let r = try Self.route(profile: 8, compat: 1, dvDisplay: true, forceDV: true)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.supplementalCodecs == "dvh1.08.06/db1p")
        #expect(r.doviConfig == .keep)
    }

    @Test("the malformed \"P8.6\" compat id still normalizes to 8.1 on a DV display")
    func p86StillNormalizes() throws {
        let r = try Self.route(profile: 8, compat: 6, dvDisplay: true, forceDV: true)
        #expect(r.doviConfig == .rewriteToProfile81)
    }

    @Test("P8.4's HLG base layer is left alone; a profile-5 dvcC would contradict its colr")
    func profile84Untouched() throws {
        let r = try Self.route(profile: 8, compat: 4, trc: AVCOL_TRC_ARIB_STD_B67,
                               dvDisplay: false, forceDV: true)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .hlg)
        // No masquerade here, and since AE#493 no strip either: the record stays as the source wrote it.
        #expect(r.doviConfig == .keep)
        #expect(r.supplementalCodecs == "dvh1.08.06/db4h")
    }

    @Test("P5 is unaffected: it was already served this way")
    func profile5Untouched() throws {
        let r = try Self.route(profile: 5, compat: 0, dvDisplay: false, forceDV: true)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.doviConfig == .keep)
    }

    // MARK: - The container bytes

    @Test("the rewrite lands profile 5, compatibility 0 and a cleared EL flag on the record")
    func rewriteToProfile5MutatesTheRecord() {
        let par = DVCodecpar(profile: 8, blCompatibilityID: 1)
        par.ptr.pointee.coded_side_data[0].data.withMemoryRebound(
            to: AVDOVIDecoderConfigurationRecord.self, capacity: 1
        ) { $0.pointee.el_present_flag = 1 }
        MP4SegmentMuxer.rewriteDoviConfig(par.ptr, profile: 5, blCompatibilityID: 0)
        let rec = try! #require(par.record)
        #expect(rec.dv_profile == 5)
        #expect(rec.dv_bl_signal_compatibility_id == 0)
        #expect(rec.el_present_flag == 0)
        // The level is the source's and stays the source's; the master's CODECS string quotes it.
        #expect(rec.dv_level == 6)
        #expect(rec.rpu_present_flag == 1)
    }

    @Test("the P8.1 rewrite still lands profile 8, compatibility 1")
    func rewriteToProfile81MutatesTheRecord() {
        let par = DVCodecpar(profile: 7, blCompatibilityID: 6)
        MP4SegmentMuxer.rewriteDoviConfig(par.ptr, profile: 8, blCompatibilityID: 1)
        let rec = try! #require(par.record)
        #expect(rec.dv_profile == 8)
        #expect(rec.dv_bl_signal_compatibility_id == 1)
        #expect(rec.el_present_flag == 0)
    }

    @Test("the strip removes the record instead of rewriting it")
    func stripRemovesTheRecord() {
        let par = DVCodecpar(profile: 8, blCompatibilityID: 1)
        MP4SegmentMuxer.stripDolbyVisionSideData(par.ptr)
        #expect(par.record == nil)
    }
}
