import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// #234 (cmcpherson274): a seek landing whose only later display set sits beyond the lead window
/// went dark in 5.23.11, the release that added the #230 pacing stream. Bisected on identical
/// fixture bytes, 5.23.10 good and 5.23.11 dark, and the landing set is never delivered at all, so
/// the #143 seed and the #204 finalize never get their chance.
///
/// Root cause is the positioning, not the park. The side reader positions with
/// `avformat_seek_file(ctx, -1, ...)`, and a -1 stream index means libavformat picks the reference
/// stream itself in `av_find_default_stream_index`, which scores
///
///     video: +25, +50 for width/height ... and, for any stream, +200 for `discard != AVDISCARD_ALL`
///
/// Until 5.23.10 every non-subtitle stream sat at `AVDISCARD_ALL`, so the subtitle stream was the
/// only one collecting that +200 and won 200 to 75: the seek was measured on the subtitle axis and
/// landed on the last cue at or before the target. #230 moved the pacing stream to
/// `AVDISCARD_NONKEY`, which is not `AVDISCARD_ALL`, so video scores it too and wins at 275. On
/// Matroska the seek then lands on the cluster holding the last video keyframe, and a landing cue
/// further back than that cluster is behind the read head before the first packet is delivered.
///
/// The reader never asked for the subtitle axis, it inherited it from a discard flag. These tests
/// pin the anchor down explicitly so positioning no longer depends on what else is deliverable.
struct Issue234SideReaderSeekAnchorTests {

    /// Fixture: 15 s Matroska, h264 128x72 at 5 fps with a keyframe every second, plus an S_TEXT
    /// track holding exactly two cues, a landing at 3 s that runs to 11 s and its successor at
    /// 12 s. The muxer writes cue points for both video keyframes and subtitle blocks, and closes a
    /// cluster every 5 s, so the landing sits in the first cluster and the 7.5 s seek target sits
    /// in the second. That is the reporter's shape at fixture scale: a long line whose only
    /// successor is far away, and a seek landing inside it several keyframes further on.
    private static let seekTarget = 7.5
    private static let landingCue = 3.0
    private static let successorCue = 12.0

    private static func makeDemuxer() throws -> Demuxer {
        let data = try #require(Data(base64Encoded: fixtureBase64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        return demuxer
    }

    /// PTS of the first packet delivered on `streamIndex`, in seconds.
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

    // MARK: - The mechanism

    /// The libavformat rule the old behaviour rested on, asserted directly so the next reader does
    /// not have to take it on trust: a discard flag decides which stream a -1 seek is measured
    /// against, and #230 changed a discard flag.
    @Test("a pacing stream at AVDISCARD_NONKEY takes over the default seek reference")
    func discardFlagsDecideTheSeekReference() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        let video = demuxer.videoStreamIndex

        demuxer.discardAllStreamsExcept([subtitle])
        #expect(demuxer.defaultSeekReferenceStreamIndex() == subtitle,
                "fully discarded, the subtitle stream is the only one scoring the +200")

        demuxer.discardAllStreamsExcept([subtitle], pacing: video)
        #expect(demuxer.defaultSeekReferenceStreamIndex() == video,
                "AVDISCARD_NONKEY is not AVDISCARD_ALL, so video scores it too and outranks")
    }

    // MARK: - The regression

    /// The symptom at demuxer level: same target, same bytes, only the pacing flag differs, and the
    /// landing cue is either delivered or skipped. This is what the reporter measured as
    /// `harvested` dropping from 3 to 1 with no `applySubtitleEvent` at the destination.
    @Test("without an explicit anchor the pacing stream moves the landing out of reach")
    func pacingStreamSkipsTheLandingCue() throws {
        let unpaced = try Self.makeDemuxer()
        defer { unpaced.close() }
        let subtitle = try Self.subtitleIndex(unpaced)
        unpaced.discardAllStreamsExcept([subtitle])
        _ = unpaced.seekBounded(to: Self.seekTarget, timeout: 5)
        #expect(Self.firstDeliveredPTS(unpaced, streamIndex: subtitle) == Self.landingCue,
                "5.23.10 shape: the seek is measured on the subtitle axis")

        let paced = try Self.makeDemuxer()
        defer { paced.close() }
        paced.discardAllStreamsExcept([subtitle], pacing: paced.videoStreamIndex)
        _ = paced.seekBounded(to: Self.seekTarget, timeout: 5)
        #expect(Self.firstDeliveredPTS(paced, streamIndex: subtitle) == Self.successorCue,
                "5.23.11 shape: measured on the video keyframe axis, the landing is already behind")
    }

    /// Why the reporter sees this on Matroska and the #230 tests did not see it on MP4: the
    /// containers implement the reference stream differently. `mov_read_seek` re-seeks every stream
    /// individually and backwards, so a sparse subtitle track keeps its landing sample whatever the
    /// reference is. `matroska_read_seek` jumps to the cluster byte position the reference stream's
    /// index entry names, and everything in earlier clusters is simply not read.
    @Test("the mov container absorbs the same anchor change")
    func movRepositionsEveryStreamRegardlessOfAnchor() throws {
        let data = try #require(Data(base64Encoded: Issue104SubtitleDiscardTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        let subtitle = try Self.subtitleIndex(demuxer)
        // Fixture: mov_text samples at 0/1/3/8/10/13/14.5 s, IRAPs at 0/3/6/9/12 s. Anchored on
        // video the target resolves to the 6 s IRAP, yet the 3 s sample still arrives.
        demuxer.discardAllStreamsExcept([subtitle], pacing: demuxer.videoStreamIndex)
        _ = demuxer.seekBounded(to: 7.5, timeout: 5)
        #expect(Self.firstDeliveredPTS(demuxer, streamIndex: subtitle) == 3.0)
    }

    // MARK: - The fix

    /// An explicit anchor restores the landing regardless of what else the source delivers. This is
    /// what the side readers actually want: they read a subtitle stream, so they position on it.
    @Test("an explicit subtitle anchor keeps the landing cue with pacing enabled")
    func explicitAnchorKeepsTheLandingCue() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        demuxer.discardAllStreamsExcept([subtitle], pacing: demuxer.videoStreamIndex)

        #expect(demuxer.seekBounded(to: Self.seekTarget, anchorStreamIndex: subtitle, timeout: 5))
        #expect(Self.firstDeliveredPTS(demuxer, streamIndex: subtitle) == Self.landingCue,
                "the landing cue must survive the pacing stream")
    }

    /// End to end through the loop the prefetcher actually runs, with the session's own setup
    /// order: the store the drainer reads must hold the landing cue after the seek.
    @Test("the prefetch loop harvests the landing cue after an anchored seek")
    func prefetchLoopHarvestsTheLandingCue() async throws {
        func harvestedPTS(anchored: Bool) async throws -> [Double] {
            let demuxer = try Self.makeDemuxer()
            defer { demuxer.close() }
            let subtitle = try Self.subtitleIndex(demuxer)
            let pacing = demuxer.prefetchPacingStreamIndex()
            demuxer.discardAllStreamsExcept([subtitle], pacing: pacing)
            _ = demuxer.seekBounded(to: Self.seekTarget,
                                    anchorStreamIndex: anchored ? subtitle : -1, timeout: 5)

            let store = SubtitlePacketStore()
            _ = await SubtitleForwardPrefetcher.run(
                demuxer: demuxer, store: store,
                streamIndices: [subtitle], assemblyIndices: [],
                pacingIndex: pacing,
                leadSeconds: 60,
                parkPollNanoseconds: 1_000_000,
                playhead: { Self.seekTarget })
            return store.entries(streamIndex: subtitle, from: 0, through: 1000).map(\.ptsSeconds)
        }

        let unanchored = try await harvestedPTS(anchored: false)
        #expect(!unanchored.contains(Self.landingCue),
                "the regression: nothing at the destination ever reaches the store")

        let anchored = try await harvestedPTS(anchored: true)
        #expect(anchored.contains(Self.landingCue))
        #expect(anchored.contains(Self.successorCue),
                "anchoring must not cost the cues the unanchored read did find")
    }

    // MARK: - Anchor edge cases

    /// A negative anchor is the documented opt-out and must behave exactly like the old call.
    @Test("a negative anchor keeps the libavformat default")
    func negativeAnchorKeepsDefaultBehaviour() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        demuxer.discardAllStreamsExcept([subtitle], pacing: demuxer.videoStreamIndex)

        _ = demuxer.seekBounded(to: Self.seekTarget, anchorStreamIndex: -1, timeout: 5)
        #expect(Self.firstDeliveredPTS(demuxer, streamIndex: subtitle) == Self.successorCue)
    }

    /// An out-of-range anchor must not wedge the seek: it falls back to the default reference
    /// rather than reporting failure and pushing the caller onto the byte estimate.
    @Test("an out-of-range anchor falls back instead of failing")
    func outOfRangeAnchorFallsBack() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        demuxer.discardAllStreamsExcept([subtitle], pacing: demuxer.videoStreamIndex)

        #expect(demuxer.seekBounded(to: Self.seekTarget, anchorStreamIndex: 99, timeout: 5))
    }

    /// The anchor is expressed in the anchored stream's own time base, not in AV_TIME_BASE units.
    /// Getting that wrong is silent: the seek still succeeds, it just lands somewhere else.
    @Test("the anchored target is converted into the stream's time base")
    func anchoredTargetUsesStreamTimeBase() throws {
        let demuxer = try Self.makeDemuxer()
        defer { demuxer.close() }
        let subtitle = try Self.subtitleIndex(demuxer)
        let tb = try #require(demuxer.stream(at: subtitle)?.pointee.time_base)
        #expect(tb.den != Int32(AV_TIME_BASE),
                "fixture must not use AV_TIME_BASE, or this test proves nothing")

        demuxer.discardAllStreamsExcept([subtitle], pacing: demuxer.videoStreamIndex)
        _ = demuxer.seekBounded(to: 12.5, anchorStreamIndex: subtitle, timeout: 5)
        #expect(Self.firstDeliveredPTS(demuxer, streamIndex: subtitle) == Self.successorCue,
                "a target past the last cue must land on that cue, not back at the landing")
    }

    /// Shared with `NativeSubtitleReaderSeekAnchorTests`, which models the other side reader's
    /// setup order on the same bytes.
    static let fixtureBase64 = """
GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAANYRFNm3TAv4QghbfcTbuLU6uEFUmp
    ZlOsgaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIBwU27jFOrhBxTu2tTrIIMHewBAAAAAAAAUwAAAAAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmp
    Zsu/hIUTIrsq17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJC015XkeF7UxAYnJ1WFGCffRImIQM1M
    AAAAAAAWVK5rQMq/hIXuc12uAQAAAAAAAIPXgQFzxYiBD5tCmCFlD5yBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OB
    ASPjg4QL68IA4JCwgYC6gUiagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAY6KoAULACv/hABhnQsAK2ggv5cBEAAADAAQAAAMA
    KDxImoABAAVozgGXIK4BAAAAAAAAL9eBAnPFiMrc3jpbwfM3nIEAIrWcg3VuZIiBAIaLU19URVhUL1VURjiDgRFV7oEAElTD
    Z0DZv4T7COKnc3OgY8CAZ8iaRaOHRU5DT0RFUkSHjUxhdmY2Mi4xMi4xMDFzc9djwItjxYiBD5tCmCFlD2fIokWjh0VOQ09E
    RVJEh5VMYXZjNjIuMjguMTAxIGxpYngyNjRnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjE1LjAwMDAwMDAwMABzc9NjwItjxYjK
    3N46W8HzN2fInkWjh0VOQ09ERVJEh5FMYXZjNjIuMjguMTAxIHNydGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MTMuMDAwMDAw
    MDAwAB9DtnVE6r+Eu18TfeeBAKNChYEAAIAAAAJRBgX//03cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIy
    IGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRl
    b2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1l
    PWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEg
    dHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAg
    dGhyZWFkcz0yIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNl
    ZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTUga2V5
    aW50X21pbj0zIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9NTEuMCBxY29tcD0wLjYw
    IHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAAoZYiEOiYoABWTk5OTk5OTrrrrrrrr
    rrrrrrrrrrrrrrrrrrrrrrrrwKOOgQDIAAAAAAZBmiASoFOjjoEBkAAAAAAGQZpAEqBTo46BAlgAAAAABkGaYBKgU6OOgQMg
    AAAAAAZBmoAToFOjsoED6IAAAAAqZYiCASomKAAIL8nJycnJycnXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgo46BBLAAAAAA
    BkGaIBKgU6OOgQV4AAAAAAZBmkASoFOjjoEGQAAAAAAGQZpgEqBTo46BBwgAAAAABkGagBOgU6OygQfQgAAAACpliIQE6Jig
    ACDTJycnJycnJ111111111111111111111111111111114CjjoEImAAAAAAGQZogEqBTo46BCWAAAAAABkGaQBKgU6OOgQoo
    AAAAAAZBmmASoFOjjoEK8AAAAAAGQZqAE6BTo7OBC7iAAAAAK2WIggFKJigACEDJuTk5OTk5Ot1111111111111111111111
    1111111114CgkaGLggu4AGxhbmRpbmebgh9Ao46BDIAAAAAABkGaIBKgU6OOgQ1IAAAAAAZBmkASoFOjjoEOEAAAAAAGQZpg
    EqBTo46BDtgAAAAABkGagBOgU6OygQ+ggAAAACpliIQFKJigACEDJuTk5OTk5Ot11111111111111111111111111111116j
    joEQaAAAAAAGQZogEqBTo46BETAAAAAABkGaQBKgU6OOgRH4AAAAAAZBmmASoFOjjoESwAAAAAAGQZqAE6BTo7OBE4iAAAAA
    K2WIggFaJigACEjJuTk5OTk5Ot11111111111111111111111111111114AfQ7Z1QmC/hNlukk3nghRQo46BAAAAAAAABkGa
    IBKgU6OOgQDIAAAAAAZBmkASoFOjjoEBkAAAAAAGQZpgEqBTo46BAlgAAAAABkGagBOgU6OygQMggAAAACpliIQFaJigACEj
    JuTk5OTk5Ot11111111111111111111111111111116jjoED6AAAAAAGQZogEqBTo46BBLAAAAAABkGaQBKgU6OOgQV4AAAA
    AAZBmmASoFOjjoEGQAAAAAAGQZqAE6BTo7OBBwiAAAAAK2WIggFaJigACEjJuTk5OTk5Ot11111111111111111111111111
    111114CjjoEH0AAAAAAGQZogEqBTo46BCJgAAAAABkGaQBKgU6OOgQlgAAAAAAZBmmASoFOjjoEKKAAAAAAGQZqAE6BTo7KB
    CvCAAAAAKmWIhAVomKAAISMm5OTk5OTk63XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXqOOgQu4AAAAAAZBmiASoFOjjoEMgAAA
    AAAGQZpAEqBTo46BDUgAAAAABkGaYBKgU6OOgQ4QAAAAAAZBmoAToFOjs4EO2IAAAAArZYiCAVomKAAISMm5OTk5OTk63XXX
    XXXXXXXXXXXXXXXXXXXXXXXXXXXXgKOOgQ+gAAAAAAZBmiASoFOjjoEQaAAAAAAGQZpAEqBTo46BETAAAAAABkGaYBKgU6OO
    gRH4AAAAAAZBmoAToFOjsoESwIAAAAAqZYiEBWiYoAAhIybk5OTk5OTrdddddddddddddddddddddddddddddddeo46BE4gA
    AAAABkGaIBKgUx9DtnVCIb+E1EyWm+eCKKCjjoEAAAAAAAAGQZpAEqBTo46BAMgAAAAABkGaYBKgU6OOgQGQAAAAAAZBmoAT
    oFOjs4ECWIAAAAArZYiCAVomKAAISMm5OTk5OTk63XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgKOOgQMgAAAAAAZBmiASoFOj
    joED6AAAAAAGQZpAEqBTo46BBLAAAAAABkGaYBKgU6OOgQV4AAAAAAZBmoAToFOjsoEGQIAAAAAqZYiEBWiYoAAhIybk5OTk
    5OTrdddddddddddddddddddddddddddddddeoJOhjYIGQABzdWNjZXNzb3KbggPoo46BBwgAAAAABkGaIBKgU6OOgQfQAAAA
    AAZBmkASoFOjjoEImAAAAAAGQZpgEqBTo46BCWAAAAAABkGagBOgU6OzgQoogAAAACtliIIBWiYoAAhIybk5OTk5OTrddddd
    ddddddddddddddddddddddddddeAo46BCvAAAAAABkGaIBKgU6OOgQu4AAAAAAZBmkASoFOjjoEMgAAAAAAGQZpgEqBTo46B
    DUgAAAAABkGagBOgU6OygQ4QgAAAACpliIQFaJigACEjJuTk5OTk5Ot11111111111111111111111111111116jjoEO2AAA
    AAAGQZogEqBTo46BD6AAAAAABkGaQBKgU6OOgRBoAAAAAAZBmmASoFOjjoERMAAAAAAGQZqAE6BTHFO7a0E+v4QJAawpu4+z
    gQC3iveBAfGCAqDwgQm7kbOCA+i3i/eBAfGCAqDwggLRu5GzggfQt4v3gQHxggKg8IIDRbuis4ILuLeL94EB8YICoPCCA7m3
    j/eBAvGCAqDwggPusoIfQLuRs4IPoLeL94EB8YICoPCCBEG7kbOCE4i3i/eBAfGCAqDwggS1u5Czghdwt4r3gQHxggeQ8IFK
    u5CzghtYt4r3gQHxggeQ8IG+u5Gzgh9At4v3gQHxggeQ8IIBM7uRs4IjKLeL94EB8YIHkPCCAae7kbOCJxC3i/eBAfGCB5Dw
    ggIcu5Czgir4t4r3gQHxggn28IE6u6Czgi7gt4r3gQHxggn28IGvt473gQLxggn28IHjsoID6LuRs4IyyLeL94EB8YIJ9vCC
    ATi7kbOCNrC3i/eBAfGCCfbwggGt
"""
}
