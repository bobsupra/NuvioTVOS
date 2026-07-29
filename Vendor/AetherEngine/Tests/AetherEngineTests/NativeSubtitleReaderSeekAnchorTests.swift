import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// The other half of #234, found while fixing it and not a regression: `runNativeSubtitleReaders`
/// has the same unanchored positioning seek, for a different reason.
///
/// The forward prefetcher sets its discard flags and then seeks, so before #230 the subtitle stream
/// was the sole survivor of `av_find_default_stream_index`'s +200 for `discard != AVDISCARD_ALL`
/// and anchored the seek by accident. The native readers seek first and set discard afterwards, so
/// at seek time every stream is still `AVDISCARD_DEFAULT`, every stream scores the +200, and video
/// wins on its own +75. That has been true since the readers were written: there was never an
/// accident to lose.
///
/// The consequence is the same as #234's. On Matroska the seek lands in the cluster holding the
/// last video keyframe, so a cue that starts further back is behind the read head before the first
/// packet arrives and the destination stays uncovered until the next cue. The readers feed the
/// native WebVTT renditions, so what goes missing there is the line that should be on screen when a
/// seek lands.
///
/// Both readers are meant to share every positioning fix, so this pins the same anchor down here.
/// Fixture and shape are #234's: landing at 3 s running to 11 s, successor at 12 s, seek to 7.5 s.
struct NativeSubtitleReaderSeekAnchorTests {

    private static let seekTarget = 7.5
    private static let landingCue = 3.0
    private static let successorCue = 12.0

    private static func makeDemuxer() throws -> Demuxer {
        let data = try #require(Data(base64Encoded: Issue234SideReaderSeekAnchorTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        return demuxer
    }

    private static func firstDeliveredPTS(_ demuxer: Demuxer, streamIndex: Int32) -> Double? {
        guard let tb = demuxer.stream(at: streamIndex)?.pointee.time_base,
              tb.num > 0, tb.den > 0 else { return nil }
        while let pkt = try? demuxer.readPacket() {
            let idx = pkt.pointee.stream_index
            let pts = pkt.pointee.pts
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            guard idx == streamIndex, pts != Int64.min else { continue }
            return Double(pts) * Double(tb.num) / Double(tb.den)
        }
        return nil
    }

    private static func subtitleIndex(_ demuxer: Demuxer) throws -> Int32 {
        Int32(try #require(demuxer.subtitleTrackInfos().first).id)
    }

    /// The readers' setup order stated as the score it produces: nothing is discarded yet when the
    /// positioning seek runs, so the +200 is universal and video's +75 decides.
    @Test("before any discard flag is set the default seek reference is video")
    func defaultReferenceIsVideoBeforeDiscard() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        #expect(demuxer.defaultSeekReferenceStreamIndex() == demuxer.videoStreamIndex)
    }

    /// The cost of that: the landing cue is behind the read head, exactly as in #234.
    @Test("an unanchored seek in the readers' setup order drops the landing cue")
    func unanchoredSeekDropsTheLandingCue() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        _ = demuxer.seekBounded(to: Self.seekTarget, timeout: 5)
        #expect(Self.firstDeliveredPTS(demuxer, streamIndex: subtitle) == Self.successorCue)
    }

    /// Anchored on the routed subtitle stream the landing survives, and it survives before the
    /// discard flags exist, which is where the readers actually seek.
    @Test("an explicit anchor keeps the landing cue in the readers' setup order")
    func anchoredSeekKeepsTheLandingCue() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        #expect(demuxer.seekBounded(to: Self.seekTarget, anchorStreamIndex: subtitle, timeout: 5))
        #expect(Self.firstDeliveredPTS(demuxer, streamIndex: subtitle) == Self.landingCue)
    }

    /// A whole-program read (Sodalite#32) starts at 0 and has nothing to anchor away from, so the
    /// anchor must be harmless there rather than special-cased.
    @Test("anchoring a seek to zero changes nothing")
    func anchorAtZeroIsHarmless() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        #expect(demuxer.seekBounded(to: 0, anchorStreamIndex: subtitle, timeout: 5))
        #expect(Self.firstDeliveredPTS(demuxer, streamIndex: subtitle) == Self.landingCue,
                "the first cue in the file is still the first cue delivered")
    }
}
