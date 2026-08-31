import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The H.264 CODECS string. The branch built it as
/// `String(format: "avc1.%02X%02X%02X", codecpar.profile, 0, codecpar.level)`, but FFmpeg does not
/// store a bare profile_idc in `AVCodecParameters.profile`: it ORs the constraint flags into the high
/// bits (`AV_PROFILE_H264_CONSTRAINED = 1<<9`, `AV_PROFILE_H264_INTRA = 1<<11`). Constrained Baseline
/// is therefore `66|512 = 578`, `%02X` prints it as three digits, and the attribute came out as
/// `avc1.2420028`: seven hex digits where RFC 6381 defines exactly six (`avc1.PPCCLL`). The hardcoded
/// middle byte compounded it, dropping the constraint_set flags the sample entry actually carries.
///
/// The avcC in the source states all three bytes outright (AVCProfileIndication /
/// profile_compatibility / AVCLevelIndication), which is what ffmpeg, GPAC and Apple's own manifests
/// print, so the record is the source of truth and the masked codecpar value is the fallback for
/// Annex-B extradata (MPEG-TS) that carries no record.
@Suite("AVC RFC 6381 codecs string")
struct AVCCodecStringTests {

    // MARK: - From the avcC configuration record

    @Test("Constrained Baseline avcC -> avc1.42C028 (the case that printed seven digits)")
    func constrainedBaselineFromRecord() {
        // Real head of the fixture that surfaced this: extradata=38B head=0142c028...
        let avcC: [UInt8] = [0x01, 0x42, 0xC0, 0x28, 0xFF, 0xE1, 0x00, 0x17]
        #expect(HLSVideoEngine.avcCodecsString(fromConfigRecord: avcC) == "avc1.42C028")
    }

    @Test("High avcC -> avc1.640028, byte-identical to what already shipped")
    func highFromRecord() {
        let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1]
        #expect(HLSVideoEngine.avcCodecsString(fromConfigRecord: avcC) == "avc1.640028")
    }

    @Test("Main avcC keeps its constraint_set1 byte -> avc1.4D401E")
    func mainFromRecord() {
        let avcC: [UInt8] = [0x01, 0x4D, 0x40, 0x1E, 0xFF, 0xE1]
        #expect(HLSVideoEngine.avcCodecsString(fromConfigRecord: avcC) == "avc1.4D401E")
    }

    @Test("Annex-B extradata is not an avcC and must not be read as one")
    func annexBRejected() {
        // MPEG-TS extradata: start code, then an SPS NAL. Byte 0 is 0, not configurationVersion 1.
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0x4D, 0x40, 0x1E]
        #expect(HLSVideoEngine.avcCodecsString(fromConfigRecord: annexB) == nil)
    }

    @Test("A record too short to hold the three bytes yields nil")
    func truncatedRecordRejected() {
        #expect(HLSVideoEngine.avcCodecsString(fromConfigRecord: [0x01, 0x42, 0xC0]) == nil)
        #expect(HLSVideoEngine.avcCodecsString(fromConfigRecord: []) == nil)
    }

    // MARK: - From the SPS, which is what MPEG-TS carries instead of a record

    @Test("Annex-B SPS states the same three bytes -> avc1.4D401E")
    func mainFromAnnexBSPS() {
        // SPS NAL header 0x67 (nal_ref_idc 3, type 7), then profile_idc / constraints / level_idc.
        let sps: [UInt8] = [0x67, 0x4D, 0x40, 0x1E, 0xAB, 0xCD]
        #expect(HLSVideoEngine.avcCodecsString(fromSPSNAL: sps) == "avc1.4D401E")
    }

    @Test("Constrained Baseline SPS -> avc1.42C028, exact rather than reconstructed")
    func constrainedBaselineFromAnnexBSPS() {
        let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x28, 0xAB]
        #expect(HLSVideoEngine.avcCodecsString(fromSPSNAL: sps) == "avc1.42C028")
    }

    @Test("A NAL that is not an SPS, or is too short, yields nil")
    func nonSPSNALRejected() {
        #expect(HLSVideoEngine.avcCodecsString(fromSPSNAL: [0x68, 0x4D, 0x40, 0x1E]) == nil)  // PPS
        #expect(HLSVideoEngine.avcCodecsString(fromSPSNAL: [0x67, 0x4D, 0x40]) == nil)
        #expect(HLSVideoEngine.avcCodecsString(fromSPSNAL: []) == nil)
    }

    @Test("resolveCodecRoute reads the SPS out of Annex-B extradata, not the codecpar profile")
    func routeReadsAnnexBSPS() throws {
        // MPEG-TS shape: start code, SPS, start code, PPS. No avcC anywhere.
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x28, 0xAB, 0xCD,
                               0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80]
        try withH264Codecpar(profile: 578, level: 40, extradata: annexB) { codecpar in
            let engine = HLSVideoEngine(url: URL(string: "file:///dev/null")!, dvModeAvailable: false)
            let route = try engine.resolveCodecRoute(codecpar: codecpar)
            #expect(route.primaryCodecs == "avc1.42C028")
        }
    }

    // MARK: - Fallback from codecpar, where the constraint flags live in the high bits

    @Test("Constrained Baseline codecpar 578 masks to profile 0x42 and sets constraint_set1")
    func constrainedBaselineFallback() {
        #expect(HLSVideoEngine.avcCodecsString(profile: 578, level: 40) == "avc1.424028")
    }

    @Test("High 10 Intra codecpar 2158 masks to profile 0x6E and sets constraint_set3")
    func highTenIntraFallback() {
        #expect(HLSVideoEngine.avcCodecsString(profile: 2158, level: 40) == "avc1.6E1028")
    }

    @Test("Plain High and Main are unchanged by the masking")
    func unflaggedProfilesFallback() {
        #expect(HLSVideoEngine.avcCodecsString(profile: 100, level: 40) == "avc1.640028")
        #expect(HLSVideoEngine.avcCodecsString(profile: 77, level: 30) == "avc1.4D001E")
    }

    @Test("An absent profile or level keeps the historical High 4.0 default")
    func missingProfileFallback() {
        #expect(HLSVideoEngine.avcCodecsString(profile: -99, level: -99) == "avc1.640028")
        #expect(HLSVideoEngine.avcCodecsString(profile: 0, level: 0) == "avc1.640028")
    }

    /// The defect in one assertion, independent of which profile produced it: the attribute is
    /// `avc1.` plus exactly six hex digits. `avc1.2420028` fails this and nothing else in the suite
    /// would notice a future value that overflows the same way.
    @Test("Every produced string is avc1 plus exactly six hex digits")
    func shapeHoldsAcrossEveryH264Profile() {
        let profiles: [Int32] = [
            66, 578,            // Baseline, Constrained Baseline
            77, 88,             // Main, Extended
            100, 612,           // High, Constrained High
            110, 2158,          // High 10, High 10 Intra
            122, 2170,          // High 4:2:2, High 4:2:2 Intra
            244, 2292,          // High 4:4:4 Predictive, High 4:4:4 Intra
            44                  // CAVLC 4:4:4
        ]
        for profile in profiles {
            let s = HLSVideoEngine.avcCodecsString(profile: profile, level: 40)
            #expect(s.count == 11, "\(profile) produced \(s)")
            #expect(s.hasPrefix("avc1."))
            let digits = s.dropFirst(5)
            #expect(digits.allSatisfy { $0.isHexDigit }, "\(profile) produced \(s)")
        }
    }

    // MARK: - The route actually uses it

    /// The pure builders are worthless if `resolveCodecRoute` keeps its own format string, so this
    /// drives the real entry point with a real `AVCodecParameters`.
    @Test("resolveCodecRoute prefers the avcC over the codecpar profile")
    func routeReadsTheConfigRecord() throws {
        let avcC: [UInt8] = [0x01, 0x42, 0xC0, 0x28, 0xFF, 0xE1, 0x00, 0x17]
        try withH264Codecpar(profile: 578, level: 40, extradata: avcC) { codecpar in
            let engine = HLSVideoEngine(url: URL(string: "file:///dev/null")!, dvModeAvailable: false)
            let route = try engine.resolveCodecRoute(codecpar: codecpar)
            #expect(route.primaryCodecs == "avc1.42C028")
            #expect(route.codecTagOverride == "avc1")
        }
    }

    @Test("resolveCodecRoute falls back to the masked codecpar when there is no avcC")
    func routeFallsBackWithoutRecord() throws {
        try withH264Codecpar(profile: 578, level: 40, extradata: nil) { codecpar in
            let engine = HLSVideoEngine(url: URL(string: "file:///dev/null")!, dvModeAvailable: false)
            let route = try engine.resolveCodecRoute(codecpar: codecpar)
            #expect(route.primaryCodecs == "avc1.424028")
        }
    }

    // MARK: - Helper

    private func withH264Codecpar(
        profile: Int32, level: Int32, extradata: [UInt8]?,
        _ body: (UnsafePointer<AVCodecParameters>) throws -> Void
    ) throws {
        guard let codecpar = avcodec_parameters_alloc() else {
            Issue.record("avcodec_parameters_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        codecpar.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        codecpar.pointee.codec_id = AV_CODEC_ID_H264
        codecpar.pointee.profile = profile
        codecpar.pointee.level = level
        codecpar.pointee.width = 1920
        codecpar.pointee.height = 1080
        if let extradata {
            let total = extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
            guard let buf = av_malloc(total)?.assumingMemoryBound(to: UInt8.self) else {
                Issue.record("av_malloc failed")
                return
            }
            memset(buf, 0, total)
            extradata.withUnsafeBufferPointer { _ = memcpy(buf, $0.baseAddress!, extradata.count) }
            codecpar.pointee.extradata = buf
            codecpar.pointee.extradata_size = Int32(extradata.count)
        }
        try body(UnsafePointer(codecpar))
    }
}
