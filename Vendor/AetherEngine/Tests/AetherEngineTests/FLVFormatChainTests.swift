import Testing
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// The native `.flv` chain, which becomes whole with FFmpegBuild 3.2.0.
///
/// The container was never the missing piece: the `flv` demuxer has shipped since the first build,
/// so a modern Flash file (H.264 + AAC, anything after 2008) already played. What was missing is the
/// legacy tail, and a format chain is whole or it is nothing. Without the video decoders a file
/// fails the load with `unsupportedCodec`, which is at least honest; without an AUDIO decoder the
/// id falls to `.unsupported`, which does not bridge, and the session serves video with no audio
/// track at all. That reads to a viewer as a broken player rather than an unsupported format, which
/// is why every codec the container can carry is named here rather than the two a typical file has.
@Suite("FLV format chain")
struct FLVFormatChainTests {

    /// Flash audio, all of it. `pcm_alaw` / `pcm_mulaw` route as `.pcm` (libavcodec's own spelling,
    /// same S16 output), the other three carry a case of their own so the routing log names them.
    private static let audio: [(String, AVCodecID, HLSVideoEngine.AudioCodecCompat)] = [
        ("nellymoser", AV_CODEC_ID_NELLYMOSER, .nellymoser),
        ("adpcm_swf", AV_CODEC_ID_ADPCM_SWF, .adpcmSwf),
        ("speex", AV_CODEC_ID_SPEEX, .speex),
        ("pcm_s16be", AV_CODEC_ID_PCM_S16BE, .pcm),
        ("pcm_u8", AV_CODEC_ID_PCM_U8, .pcm),
        ("pcm_alaw", AV_CODEC_ID_PCM_ALAW, .pcm),
        ("pcm_mulaw", AV_CODEC_ID_PCM_MULAW, .pcm),
    ]

    /// The video half. FLV1 is Sorenson Spark and registers under the family name `flv`, so a
    /// lookup by the codec name `flv1` finds nothing; the engine dispatches by id, which is why
    /// both spellings are asserted here rather than only the one a reader would guess.
    private static let video: [(String, AVCodecID)] = [
        ("flv", AV_CODEC_ID_FLV1),
        ("vp6", AV_CODEC_ID_VP6),
        ("vp6a", AV_CODEC_ID_VP6A),
        ("vp6f", AV_CODEC_ID_VP6F),
    ]

    @Test("every Flash audio codec bridges instead of dropping to video-only")
    func everyAudioCodecBridges() {
        for (name, id, expected) in Self.audio {
            let compat = HLSVideoEngine.AudioCodecCompat.from(id)
            #expect(compat == expected, "\(name) routes as \(compat), not \(expected)")
            #expect(compat.requiresBridge, "\(name) would try to stream-copy into fMP4")
            #expect(compat.hlsCodecsString.isEmpty,
                    "\(name) is bridged, so the master playlist takes its CODECS from the encoder")
        }
    }

    @Test("the linked libavcodec carries every Flash audio decoder the table routes")
    func everyAudioDecoderIsLinked() {
        for (name, id, _) in Self.audio {
            #expect(avcodec_find_decoder(id) != nil,
                    "\(name) is routed but absent from the linked FFmpeg build: those files play silently")
        }
    }

    @Test("the linked libavcodec carries the legacy Flash video decoders")
    func everyVideoDecoderIsLinked() {
        for (name, id) in Self.video {
            #expect(avcodec_find_decoder(id) != nil, "\(name) missing: the software path fails the load")
            #expect(avcodec_find_decoder_by_name(name) != nil, "\(name) does not register under that name")
        }
        #expect(avcodec_find_decoder_by_name("flv1") == nil,
                "the FLV1 decoder now answers to flv1 as well; the alias note in this suite is stale")
    }

    @Test("the flv demuxer opens the container the decoders serve")
    func theContainerOpens() {
        #expect(av_find_input_format("flv") != nil, "flv demuxer missing: no Flash file opens at all")
    }
}
