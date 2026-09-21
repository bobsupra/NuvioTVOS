import Foundation
import Testing
@testable import AetherEngine

/// AE#446 round 7: a source that is merely LATE is not a source that has stopped.
///
/// Closing the window is irreversible for the item that reads the ENDLIST, so it is paid for with an
/// item swap and a visible seam when the source comes back. It used to fire on the same threshold as
/// the blocking-reload withdrawal, which is cheap and reversible, so every hiccup a target duration
/// long committed the session (reported from the field on a 1 s-segment stack: a 3.0 s stall in the
/// source read, 14 s of runway still ahead, the source delivering again 0.6 s later, and a swap 17 s
/// after that). The wait is now bounded twice: by the clock, and by the runway left to wait with.
@Suite("AE#446 round 7 outage close deadline")
struct Issue446OutageCloseDeadlineTests {

    /// 4 s segments seal TARGETDURATION 6 (`ceil(1.5 x cut target)`), so patience is 9 s and the close
    /// deadline 18 s: two numbers a reader can follow through the test. What the runway has to beat is
    /// whatever is left of that 18 s at the moment it is asked.
    private func makeLiveProvider(segments segmentCount: Int)
        -> (provider: VideoSegmentProvider, cache: SegmentCache) {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 4.0,
                                               dvrWindowSeconds: 1800)
        )
        for i in 0..<segmentCount {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
        #expect(provider.liveTargetDurationSeconds(maxSegmentDuration: 4.0) == 6)
        return (provider, cache)
    }

    @Test("the silence that withdraws the blocking-reload advert does not close the window")
    func lateSourceKeepsTheWindowLive() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(2) // 17 segments / 68 s of runway ahead of the fetch point
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 10.0) // 1.7 x TD

        // The cheap half still fires exactly where it did: past AVPlayer's own patience a held poll
        // can only starve a client the cache could feed.
        #expect(provider.liveDeliveryStalled)
        // The expensive half does not. This pair is the whole round.
        #expect(!provider.liveOutageEndlist)
        #expect(!provider.liveOutageEndlistLatched)
    }

    /// AE#523 round 2: the same silence with the content still in hand closes nothing. What used to
    /// close here was the `3 x TD` deadline, with 68 s of runway ahead of the consumer.
    @Test("past the old close deadline a consumer that still holds content is not closed on")
    func quietSourceWithRunwayKeepsTheWindowLive() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(2) // 17 segments / 68 s of runway
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 18.5) // > 3 x TD

        #expect(!provider.liveOutageEndlist)
        #expect(!provider.liveOutageEndlistLatched)
        // Past the producer's own patience with a source that cuts nothing it closes anyway: a window
        // left open there would never be closed at all, whatever the consumer is still holding.
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 8.0) // 26.5 s, past 35 - 9
        #expect(provider.liveOutageEndlist)
        #expect(provider.liveOutageEndlistLatched)
    }

    @Test("a runway too thin to carry the close to the consumer closes at once")
    func shallowRunwayClosesAtOnce() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(18) // 1 segment / 4 s left, under the 6 s the close needs to be told in
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 10.0) // late, nowhere near quiet

        #expect(provider.liveOutageEndlist)
    }

    /// AE#520's reporter shape: a viewer near the live edge, a gap the wait was built to absorb, and a
    /// runway that the old `2 x TD` constant called shallow. Three segments is 12 s, exactly the old
    /// floor, and twice what the close needs to reach the consumer, so nothing may be closed and no
    /// item may be swapped. AE#523 round 2: nor when the clock runs on past the old deadline.
    @Test("a runway the close does not need yet waits the source out instead of closing")
    func runwayAboveTheReserveIsNotClosedOn() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(16) // 3 segments / 12 s ahead of the fetch point
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 10.0) // 1.7 x TD, late not quiet

        #expect(!provider.liveOutageEndlist)
        #expect(!provider.liveOutageEndlistLatched)
        // Past the old `3 x TD` deadline, and the content is still what decides.
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 8.6) // 18.6 s of silence
        #expect(!provider.liveOutageEndlist)
        // The consumer walks the window while the source is quiet, and the close lands one poll before
        // the content runs out, which is the last moment the ENDLIST can still reach it.
        cache.declareTarget(18) // 4 s left
        #expect(provider.liveOutageEndlist)
    }

    /// The bound in isolation, so the rule is readable without a provider around it.
    @Test("the runway bound is what the close needs, not a clock and not a share of the window")
    func runwayBoundIsWhatTheCloseNeeds() {
        // 12 s of content at TARGETDURATION 6: two polls' worth, the close is not needed yet.
        #expect(!LiveEdgePolicy.outageCloseOnDepth(depthSeconds: 12, targetDuration: 6))
        // One poll's worth is the last moment the ENDLIST still reaches a consumer with content left.
        #expect(LiveEdgePolicy.outageCloseOnDepth(depthSeconds: 6, targetDuration: 6))
        #expect(LiveEdgePolicy.outageCloseOnDepth(depthSeconds: 4, targetDuration: 6))
        // A deeply timeshifted viewer is never closed on by this bound, at any silence: the clock it
        // used to be compared against shares its axis and only ever beat it to the decision.
        #expect(!LiveEdgePolicy.outageCloseOnDepth(depthSeconds: 68, targetDuration: 6))
        // The reserve is never less than a segment, since TARGETDURATION is the longest one served.
        for td in 1...30 {
            #expect(LiveEdgePolicy.outageCloseDepthReserveSeconds(targetDuration: td) >= Double(td))
        }
    }

    @Test("a source that has not missed its cadence closes nothing, however little runway is left")
    func aHealthySourceIsNeverClosedOn() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(17)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 4.0) // inside its own cadence

        #expect(!provider.liveOutageEndlist)
    }

    @Test("a consumer at the end of the window has nothing to serve as a finished asset")
    func consumerAtTheEndIsNotClosedOn() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(19)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 60.0)

        #expect(!provider.liveOutageEndlist)
    }

    @Test("the recovery reading stays on the strict cadence, not on what closed the window")
    func recoveryIsStillTheStrictReading() {
        // 26.5 s of silence with a thick runway: past the ceiling, so the window is closed.
        let (stillQuiet, stillQuietCache) = makeLiveProvider(segments: 20)
        stillQuietCache.declareTarget(2)
        stillQuiet.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 26.5)
        #expect(stillQuiet.liveOutageEndlist)
        // A window that is already closed must NOT read as recovered while the source is still quiet,
        // or the swap lands in a window whose source is dead.
        #expect(!stillQuiet.liveOutageProductionResumed)
    }

    @Test("the clock bound never waits past the producer's own patience with a silent source")
    func ceilingStaysInsideTheStarvationExit() {
        // The ordinary case: the exit at 35 s, less a patience so the client still has polls left to
        // be handed the closed playlist in.
        #expect(LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: 2) == 32.0)
        #expect(LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: 6) == 26.0)
        // A bursty relay seals its TARGETDURATION from an arrival cadence, and the ceiling then lands
        // at the moment the source is late at all: below that it would close the window before the
        // question could even be asked.
        for td in 1...30 {
            let ceiling = LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: td)
            let late = LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * Double(td)
            #expect(ceiling >= late)
            #expect(ceiling <= max(late, HLSSegmentProducer.liveSourceStarvationTimeoutSeconds - late))
        }
        #expect(LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: 14) == 21.0)
    }

    @Test("the close is strictly more patient than the client's own patience")
    func theTwoThresholdsAreNotTheSameNumber() {
        // The round 7 defect in one line: an irreversible decision sized by a threshold chosen for a
        // withdrawal that costs nothing. The close now outlives the withdrawal at every seal.
        for td in 1...30 {
            let patience = LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * Double(td)
            #expect(LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: td) >= patience)
        }
        // And the wait stays well inside what the client will sit through: measured at 13 x TD with
        // the window open and the advert withdrawn, against a ceiling of 35 s at any seal.
        #expect(LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: 6)
                <= HLSSegmentProducer.liveSourceStarvationTimeoutSeconds)
    }
}
