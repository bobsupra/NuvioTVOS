import Testing
import Foundation
import CoreMedia
import AetherLibavcodec
@testable import AetherEngine

/// The published source identity a stats panel reads: `sourceVideoCodecName` and `sourceContainerFormat`.
/// Both exist because a host cannot answer them from its own catalogue. A server's metadata describes the
/// file the library holds, and under a remux or a transcode that is not what arrived; only the engine knows
/// what it opened. The panel that prompted this showed a full readout for one library item and a half-empty
/// one for the next, purely because the host's item payload differed.
///
/// Two paths publish the codec name and they must agree word for word: the probe path spells it with
/// `avcodec_get_name`, the probe-free remote-HLS bypass maps the video sample type back to the same word.
/// One field that reads "h264" on one route and "avc1" on the other is a field a reader cannot compare.
@Suite("Source video identity: codec name and container")
struct SourceVideoIdentityTests {

    /// 0.1s of black H.264 in MP4, reused from the Atmos fixtures rather than embedding a second copy.
    private static func h264MP4() -> Data {
        guard let data = Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                              options: .ignoreUnknownCharacters) else {
            Issue.record("failed to decode embedded base64 fixture")
            return Data()
        }
        return data
    }

    // MARK: - Container

    @Test("the demuxer names the container it opened")
    func containerNameFromOpenDemuxer() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.h264MP4()), formatHint: "mp4")
        let name = try #require(demuxer.containerFormatName)
        // libavformat names the whole MP4 family in one string; the substring is the stable part of it.
        #expect(name.contains("mp4"), "expected an MP4-family format name, got \(name)")
    }

    @Test("an unopened demuxer names no container")
    func containerNameNilBeforeOpen() {
        let demuxer = Demuxer()
        #expect(demuxer.containerFormatName == nil)
    }

    // MARK: - Codec name, one word on both paths

    @Test("the probe path spells the codec with libavcodec")
    func probePathCodecName() throws {
        let probe = try AetherEngine.probe(
            source: .custom(DataIOReader(data: Self.h264MP4()), formatHint: "mp4"))
        #expect(probe.videoCodecName == "h264")
    }

    /// The fixture is an `avc1` MP4, so the bypass, handed that sample type, has to arrive at the same
    /// word the probe just produced from the same bytes. This is the test that would fail if either side
    /// changed its vocabulary alone.
    @Test("the bypass maps the same source to the same word")
    func bypassAgreesWithProbe() throws {
        let probe = try AetherEngine.probe(
            source: .custom(DataIOReader(data: Self.h264MP4()), formatHint: "mp4"))
        let avc1: FourCharCode = 0x61766331
        #expect(RemoteHLSFormatDetection.codecName(videoSubType: avc1) == probe.videoCodecName)
    }

    @Test("libavcodec's spelling is what the mapping table promises", arguments: [
        (AV_CODEC_ID_H264, "h264"),
        (AV_CODEC_ID_HEVC, "hevc"),
        (AV_CODEC_ID_AV1, "av1"),
        (AV_CODEC_ID_VP9, "vp9"),
    ])
    func libavcodecSpelling(_ id: AVCodecID, _ expected: String) {
        let name = avcodec_get_name(id).map { String(cString: $0) }
        #expect(name == expected)
    }

    // MARK: - Session state

    @Test("a fresh engine publishes no source identity")
    @MainActor
    func freshEngineHasNoIdentity() async throws {
        let engine = try AetherEngine()
        #expect(engine.sourceVideoCodecName == nil)
        #expect(engine.sourceContainerFormat == nil)
        #expect(engine.sourceVideoWidth == 0)
        #expect(engine.sourceVideoHeight == 0)
    }
}
