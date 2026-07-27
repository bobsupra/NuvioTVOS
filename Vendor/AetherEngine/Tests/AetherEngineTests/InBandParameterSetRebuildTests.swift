import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Fixtures/ is local-only by design (gitignored; Scripts/fetch-fixtures.sh regenerates the
/// synthetic clips). The tests skip via `.enabled(if:)` when a clip is absent, e.g. on CI.
private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// AetherPlayer#2: sources whose HEVC parameter sets live in-band ship an hvcC with
/// `numOfArrays = 0`, and the init.mp4 normalizer rebuilds the record by scanning packets for the
/// VPS/SPS/PPS. That scan ran on whatever cursor the preceding cue prewarm and segment-plan pass
/// had left behind, so on a real film it read 16 mid-GOP packets, found nothing, and let the muxer
/// emit an empty hvcC. AVPlayer then buffers the whole forward window and never renders a frame
/// (CoreMediaErrorDomain -19601, no code the master fallback reacts to): frozen at 00:00.
@Suite("In-band parameter-set rebuild")
struct InBandParameterSetRebuildTests {

    @Test("The rebuild finds the parameter sets from a mid-GOP cursor",
          .enabled(if: fixtureExists("hev1-inband-xps.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the in-band xPS clip"),
          .timeLimit(.minutes(1)))
    func rebuildIsIndependentOfDemuxerCursor() throws {
        let demuxer = Demuxer()
        try demuxer.open(url: fixtureURL("hev1-inband-xps.mp4"), profile: .playback)
        defer { demuxer.close() }
        let videoIdx = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIdx))
        let codecpar = try #require(stream.pointee.codecpar)
        #expect(codecpar.pointee.extradata_size == 23,
                "fixture must ship the bare hvcC header, i.e. numOfArrays = 0")

        // Park the cursor mid-GOP, the state the cue prewarm plus plan pass leaves behind. The
        // fixture's IRAPs are 120 frames apart, so nothing in the scan's packet budget from here
        // carries a parameter set.
        var advanced = 0
        while advanced < 30, let pkt = try demuxer.readPacket() {
            var toFree: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&toFree) }
            if Int(pkt.pointee.stream_index) == videoIdx { advanced += 1 }
        }
        #expect(advanced == 30)

        let engine = HLSVideoEngine(url: fixtureURL("hev1-inband-xps.mp4"), dvModeAvailable: false)
        let rebuilt = engine.rebuildHEVCExtradataWithInBandParameterSets(
            demuxer: demuxer, videoStreamIndex: Int32(videoIdx), codecpar: codecpar)

        let record = try #require(rebuilt, "in-band VPS/SPS/PPS must be recoverable from any cursor")
        #expect(record.count > 23)
        #expect(record[22] == 3, "numOfArrays must cover VPS, SPS and PPS")
    }
}
