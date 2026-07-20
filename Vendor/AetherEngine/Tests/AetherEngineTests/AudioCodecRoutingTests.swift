import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("AVPlayer audio codec routing")
struct AudioCodecRoutingTests {

    @Test("AVPlayer-decodable music codecs route native")
    func nativeCodecs() {
        for id in [AV_CODEC_ID_AAC, AV_CODEC_ID_MP3, AV_CODEC_ID_MP2, AV_CODEC_ID_ALAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S16BE] {
            #expect(AetherEngine.avPlayerCanDecodeAudio(id) == true)
        }
    }

    @Test("Codecs AVPlayer cannot decode route to the FFmpeg fallback")
    func fallbackCodecs() {
        for id in [AV_CODEC_ID_OPUS, AV_CODEC_ID_VORBIS, AV_CODEC_ID_APE, AV_CODEC_ID_WAVPACK, AV_CODEC_ID_NONE] {
            #expect(AetherEngine.avPlayerCanDecodeAudio(id) == false)
        }
    }
}
