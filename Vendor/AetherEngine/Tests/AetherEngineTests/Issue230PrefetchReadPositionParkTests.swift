import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// #230 (rrgomes, reading the software path for #220): the #151 forward prefetcher's park was
/// edge-triggered on subtitle packets only, so a stretch of the file with no cues was read at full
/// speed however far past `playhead + leadSeconds` the demuxer already sat. The park guard is only
/// reachable from a packet the loop receives, and with every non-subtitle stream on `AVDISCARD_ALL`
/// the only packets it receives are subtitle packets. Between two cues there is no control point at
/// all: one `av_read_frame` call walks whatever lies between them. Bounded on a dense PGS track
/// (the reporter measured a cue every 1 to 5 s), unbounded on a sparse track, a long dialogue-free
/// stretch, or a forced-subtitle track with a handful of cues per hour.
///
/// The premise in the issue text, that non-subtitle packets reach the loop and take a discard
/// branch, is wrong: `AVDISCARD_ALL` is applied inside `av_read_frame`, so evaluating the park on a
/// discarded packet would never run. The fix leaves one stream at `AVDISCARD_NONKEY` instead, which
/// delivers one packet per IRAP and gives the park a read-position control point.
///
/// Fixture is Issue104SubtitleDiscardTests': 15 s MP4, h264 at 10 fps with IRAPs at 0/3/6/9/12 s,
/// plus mov_text samples at 0/1/3/8/10/13/14.5 s. The 3 s to 8 s gap is the sparse stretch.
struct Issue230PrefetchReadPositionParkTests {

    private static func makeDemuxer() throws -> Demuxer {
        let data = try #require(Data(base64Encoded: Issue104SubtitleDiscardTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        return demuxer
    }

    private static func drainStreamIndices(_ demuxer: Demuxer) -> [Int32] {
        var indices: [Int32] = []
        while let pkt = try? demuxer.readPacket() {
            indices.append(pkt.pointee.stream_index)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        return indices
    }

    // MARK: - The delivery gap the park cannot see

    /// The defect, stated as the demuxer contract it rests on: fully discarded, the side demuxer
    /// hands the loop nothing between two subtitle packets. Every gap between consecutive control
    /// points is a stretch the park cannot evaluate.
    @Test("without a pacing stream the loop has no control point between cues")
    func fullyDiscardedSourceDeliversOnlySubtitlePackets() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitleIndex = Int32(try #require(demuxer.subtitleTrackInfos().first).id)
        demuxer.seek(to: 0)
        demuxer.discardAllStreamsExcept([subtitleIndex])
        let delivered = Self.drainStreamIndices(demuxer)

        #expect(delivered.allSatisfy { $0 == subtitleIndex },
                "AVDISCARD_ALL is applied inside av_read_frame; nothing else can reach the loop")
    }

    /// The fix: the pacing stream restores control points without restoring the payload. Only
    /// keyframes are delivered, so the cost is one packet per IRAP rather than one per frame.
    @Test("the pacing stream delivers IRAPs only, alongside every subtitle packet")
    func pacingStreamDeliversKeyframesOnly() throws {
        let control = try Self.makeDemuxer()
        defer { control.close() }
        let subtitleIndex = Int32(try #require(control.subtitleTrackInfos().first).id)
        let videoIndex = control.videoStreamIndex
        control.seek(to: 0)
        let controlIndices = Self.drainStreamIndices(control)
        let allVideo = controlIndices.filter { $0 == videoIndex }.count
        let allSubtitles = controlIndices.filter { $0 == subtitleIndex }.count

        let paced = try Self.makeDemuxer()
        defer { paced.close() }
        paced.seek(to: 0)
        paced.discardAllStreamsExcept([subtitleIndex], pacing: videoIndex)
        let delivered = Self.drainStreamIndices(paced)
        let pacedVideo = delivered.filter { $0 == videoIndex }.count
        let pacedSubtitles = delivered.filter { $0 == subtitleIndex }.count

        #expect(pacedVideo > 0, "the park needs control points between cues")
        #expect(pacedVideo == 5, "fixture has IRAPs at 0/3/6/9/12s")
        #expect(pacedVideo < allVideo / 10, "AVDISCARD_NONKEY must not restore the payload")
        #expect(pacedSubtitles == allSubtitles, "every subtitle packet must still be delivered")
    }

    /// The pacing stream must never be cover art: a single attached picture delivers one packet and
    /// paces nothing. The fixture has a real video track, so that is what gets picked.
    @Test("pacing selection prefers the video track")
    func pacingSelectionPicksVideo() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        #expect(demuxer.prefetchPacingStreamIndex() == demuxer.videoStreamIndex)
    }

    // MARK: - The park itself

    /// End to end through the real loop: with the playhead at 0 and a 4 s lead, the read must stop
    /// inside the 3 s to 8 s subtitle gap instead of running to the far side of it.
    ///
    /// The playhead closure returns 0 once (the loop's initial snapshot) and nil afterwards, which
    /// is the loop's "engine gone" exit. So the second call happening at all proves the park
    /// engaged, and where it engaged is readable from what the store holds: harvest-then-park means
    /// a subtitle packet that triggers the park is stored before the loop stops.
    @Test("the park engages on the read position, not on the next cue")
    func parkEngagesInsideTheSubtitleGap() async throws {
        func harvestedPTS(pacing: Bool) async throws -> [Double] {
            let demuxer = try Self.makeDemuxer()
            defer { demuxer.close() }
            let subtitleIndex = Int32(try #require(demuxer.subtitleTrackInfos().first).id)
            demuxer.seek(to: 0)
            let pacingIndex = pacing ? demuxer.prefetchPacingStreamIndex() : -1
            demuxer.discardAllStreamsExcept([subtitleIndex], pacing: pacingIndex)

            let store = SubtitlePacketStore()
            let calls = Counter()
            _ = await SubtitleForwardPrefetcher.run(
                demuxer: demuxer, store: store,
                streamIndices: [subtitleIndex], assemblyIndices: [],
                pacingIndex: pacingIndex,
                leadSeconds: 4.0,
                parkPollNanoseconds: 1_000_000,
                playhead: { await calls.next() == 0 ? 0.0 : nil })
            return store.entries(streamIndex: subtitleIndex, from: 0, through: 1000)
                .map(\.ptsSeconds)
        }

        // The defect: the park is not evaluated until the cue on the far side of the gap arrives,
        // so the read crosses the whole gap and the 8 s cue is already stored.
        let unpaced = try await harvestedPTS(pacing: false)
        #expect(unpaced.contains { $0 >= 8 },
                "without pacing the read runs to the next cue however far away it is")

        // Fixed: the 6 s IRAP crosses the lead edge first, so the read stops mid-gap.
        let paced = try await harvestedPTS(pacing: true)
        #expect(!paced.contains { $0 >= 8 },
                "the park must engage on the pacing packet inside the gap")
        #expect(paced.contains { $0 == 3 },
                "everything inside the lead window must still be harvested")
    }

    /// A pacing packet must never be harvested: it is not a subtitle packet and the store is the
    /// drainer's input.
    @Test("pacing packets are freed, not harvested")
    func pacingPacketsAreNotHarvested() async throws {
        let control = try Self.makeDemuxer()
        defer { control.close() }
        let subtitleIndex = Int32(try #require(control.subtitleTrackInfos().first).id)
        control.seek(to: 0)
        let deliverableSubtitles = Self.drainStreamIndices(control)
            .filter { $0 == subtitleIndex }.count

        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        demuxer.seek(to: 0)
        let pacingIndex = demuxer.prefetchPacingStreamIndex()
        demuxer.discardAllStreamsExcept([subtitleIndex], pacing: pacingIndex)

        let store = SubtitlePacketStore()
        let outcome = await SubtitleForwardPrefetcher.run(
            demuxer: demuxer, store: store,
            streamIndices: [subtitleIndex], assemblyIndices: [],
            pacingIndex: pacingIndex,
            leadSeconds: 3600,
            parkPollNanoseconds: 1_000_000,
            playhead: { 0.0 })

        #expect(outcome.harvested == deliverableSubtitles,
                "only subtitle packets count as harvested, and all of them do")
        #expect(store.entries(streamIndex: pacingIndex, from: 0, through: 1000).isEmpty,
                "the pacing stream must leave nothing in the store")
    }

    // MARK: - Timestamp axis

    /// A pacing packet is placed by DTS. With B-frames a video PTS runs ahead of the bytes actually
    /// read, and it is the bytes the park exists to bound.
    @Test("a pacing packet is placed by DTS, a subtitle packet by PTS")
    func packetSecondsPrefersDecodeOrderForPacing() {
        let tb = AVRational(num: 1, den: 1000)
        #expect(SubtitleForwardPrefetcher.packetSeconds(
            pts: 5000, dts: 2000, timeBase: tb, preferDecodeOrder: true) == 2.0)
        #expect(SubtitleForwardPrefetcher.packetSeconds(
            pts: 5000, dts: 2000, timeBase: tb, preferDecodeOrder: false) == 5.0)
    }

    /// Either axis falls back to the other when its own timestamp is absent.
    @Test("a missing timestamp falls back to the other axis")
    func packetSecondsFallsBack() {
        let tb = AVRational(num: 1, den: 1000)
        #expect(SubtitleForwardPrefetcher.packetSeconds(
            pts: Int64.min, dts: 2000, timeBase: tb, preferDecodeOrder: false) == 2.0)
        #expect(SubtitleForwardPrefetcher.packetSeconds(
            pts: 5000, dts: Int64.min, timeBase: tb, preferDecodeOrder: true) == 5.0)
        #expect(SubtitleForwardPrefetcher.packetSeconds(
            pts: Int64.min, dts: Int64.min, timeBase: tb, preferDecodeOrder: false) == nil)
    }

    /// A degenerate time base cannot place a packet; parking against it would compare against
    /// second 0 forever.
    @Test("a degenerate time base yields no position")
    func packetSecondsRejectsDegenerateTimeBase() {
        #expect(SubtitleForwardPrefetcher.packetSeconds(
            pts: 5000, dts: 5000, timeBase: AVRational(num: 0, den: 1),
            preferDecodeOrder: false) == nil)
        #expect(SubtitleForwardPrefetcher.packetSeconds(
            pts: 5000, dts: 5000, timeBase: AVRational(num: 1, den: 0),
            preferDecodeOrder: false) == nil)
    }
}

/// Serializes the playhead call count across the prefetcher's concurrent context.
private actor Counter {
    private var count = 0
    func next() -> Int {
        defer { count += 1 }
        return count
    }
}
