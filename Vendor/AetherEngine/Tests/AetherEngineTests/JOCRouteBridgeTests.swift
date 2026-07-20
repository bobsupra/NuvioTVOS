import Testing
import AetherLibavcodec
@testable import AetherEngine

/// EAC3/JOC routing tests. EAC3 always stream-copies (CODECS string "ec-3" for both JOC and plain 5.1); FLAC bridge is never route-driven (AetherEngine#34).
/// Missing `dec3` extradata is caught by probeWriteHeader, not the codec-compat table.
/// libavcodec marks JOC with EAC3 profile == 30 (FF_PROFILE_EAC3_DDP_ATMOS).
@Suite("EAC3 / JOC route bridge routing")
struct JOCRouteBridgeTests {

    @Test("EAC3 is a stream-copy codec, never a route-driven bridge (issue #34)")
    func eac3StreamCopies() {
        let compat = HLSVideoEngine.AudioCodecCompat.from(AV_CODEC_ID_EAC3)
        #expect(compat == .eac3)
        #expect(compat.requiresBridge == false)
        #expect(compat.hlsCodecsString == "ec-3")
    }

    @Test("JOC and non-JOC EAC3 share the same CODECS string and routing")
    func jocSignalsLikePlainEAC3() {
        // JOC lives in EAC3 profile (30), not a separate codec id; routing table keys off .eac3 for both, so AVPlayer cannot reject the JOC variant.
        let compat = HLSVideoEngine.AudioCodecCompat.from(AV_CODEC_ID_EAC3)
        #expect(compat.hlsCodecsString == "ec-3")
        #expect(compat.requiresBridge == false)
    }
}
