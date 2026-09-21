import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Windows Media audio, which arrives with the native `.wmv` / `.asf` support of FFmpegBuild 3.1.0.
///
/// No WMA flavour is fMP4-legal, so none of them can stream-copy: the AudioBridge decodes and
/// re-encodes them, exactly like MP2 and Blu-ray LPCM. The failure this suite exists to prevent is
/// the quiet one. An id the table does not know falls to `.unsupported`, which does not bridge, so
/// the session serves video with no audio track at all and the file plays silently. That is why the
/// FFmpegBuild side ships the whole family and why every one of them is named here.
@Suite("WMA audio routing")
struct WMAAudioRouteTests {

    private static let flavours: [(String, AVCodecID)] = [
        ("wmav1", AV_CODEC_ID_WMAV1),
        ("wmav2", AV_CODEC_ID_WMAV2),
        ("wmapro", AV_CODEC_ID_WMAPRO),
        ("wmalossless", AV_CODEC_ID_WMALOSSLESS),
        ("wmavoice", AV_CODEC_ID_WMAVOICE),
    ]

    @Test("every WMA flavour the build ships routes through the bridge")
    func everyFlavourBridges() {
        for (name, id) in Self.flavours {
            let compat = HLSVideoEngine.AudioCodecCompat.from(id)
            #expect(compat == .wma, "\(name) is not routed as WMA")
            #expect(compat.requiresBridge, "\(name) would try to stream-copy into fMP4")
            #expect(compat.hlsCodecsString.isEmpty,
                    "\(name) is bridged, so the master playlist takes its CODECS from the encoder")
        }
    }

    /// The decoders have to be in the linked build too: the table can route a codec the binary
    /// cannot decode, and that failure looks the same to a viewer as the routing one.
    @Test("the linked libavcodec carries every flavour the table claims")
    func everyFlavourDecodes() {
        for (name, _) in Self.flavours {
            #expect(avcodec_find_decoder_by_name(name) != nil,
                    "\(name) is routed but absent from the linked FFmpeg build")
        }
    }
}
