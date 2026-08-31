import Foundation
import Testing
@testable import AetherEngine

/// AE#441: `seekableLiveRange`'s lower bound was window arithmetic (`max(0, edge - window)`) and never
/// consulted the cache, so it advertised a rewind depth the session had never written.
@Suite("AE#441 the advertised live floor is the resident one")
struct Issue441ResidentLiveFloorTests {

    // MARK: - The intersection

    /// The report's regime, measured on the harness: a session joined at edge 181.62 s advertised a
    /// floor of 0.00 for its whole run, while a seek to 0.20 landed at 181.66.
    @Test("a floor above the arithmetic one wins, because it is the one a seek can reach")
    func residentFloorRaisesTheBound() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(246.71)
        w.noteResidentFloor(181.66)
        #expect(w.seekableRange?.lowerBound == 181.66)
        #expect(w.seekableRange?.upperBound == 246.71)
    }

    /// The window is a cap, not a promise of depth: retention that kept LESS than the window is the
    /// case above, and one that happens to hold more must not widen the advertised range past policy.
    @Test("the window still caps a cache that holds more than it")
    func policyStillCaps() {
        var w = LiveWindow(windowSeconds: 30)
        w.noteEdge(600)
        w.noteResidentFloor(100)          // the cache kept 500 s; the session promised 30
        #expect(w.seekableRange?.lowerBound == 570)
    }

    /// Paths with no segment cache to ask (software live) report nothing, and must keep exactly the
    /// behaviour they had.
    @Test("an unknown floor leaves the arithmetic untouched")
    func unknownFloorIsUnchangedBehaviour() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(246.71)
        w.noteResidentFloor(nil)
        #expect(w.seekableRange?.lowerBound == 0)
        var deep = LiveWindow(windowSeconds: 30)
        deep.noteEdge(600)
        deep.noteResidentFloor(nil)
        #expect(deep.seekableRange?.lowerBound == 570)
    }

    /// A floor read while the edge is still catching up can exceed it for a tick, and a reversed
    /// ClosedRange traps. This is the guard that keeps a crash out of a diagnostics path.
    @Test("a floor past the edge collapses the range instead of trapping")
    func floorPastEdgeDoesNotTrap() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(10)
        w.noteResidentFloor(42)
        let range = w.seekableRange
        #expect(range?.lowerBound == 10)
        #expect(range?.upperBound == 10)
    }

    /// `clamp` reads the same range, which is what makes the engine's own resume clamp (AE#444) and
    /// `seek(to:)` aim at a position that was actually retained.
    @Test("clamp aims at the resident floor, not the arithmetic one")
    func clampFollowsTheHonestFloor() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(246.71)
        w.noteResidentFloor(181.66)
        #expect(w.clamp(0.2) == 181.66)
        #expect(w.clamp(200) == 200)
        #expect(w.clamp(9999) == 246.71)
    }

    @Test("live-only sessions still have no range at all")
    func liveOnlyUnaffected() {
        var w = LiveWindow(windowSeconds: nil)
        w.noteEdge(500)
        w.noteResidentFloor(120)
        #expect(w.seekableRange == nil)
        #expect(w.clamp(3) == 500)
    }

    // MARK: - The floor the cache reports

    @Test("the backward floor is the deepest contiguous index, not the lowest resident one")
    func backwardFloorStopsAtAHole() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        for i in [0, 1, 2, 5, 6, 7] { cache.store(index: i, data: Data([UInt8(i)])) }
        #expect(cache.highestResidentIndex == 7)
        // A rewind to 2 could not play forward across the hole at 3, so 5 is the honest floor.
        #expect(cache.contiguousBackwardFloor(from: 7) == 5)
    }

    @Test("a fully contiguous cache reports its first segment")
    func backwardFloorOnContiguousCache() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        for i in 0..<6 { cache.store(index: i, data: Data([UInt8(i)])) }
        #expect(cache.contiguousBackwardFloor(from: 5) == 0)
    }

    @Test("walking from an absent index reports nothing below it")
    func backwardFloorFromAHole() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        cache.store(index: 0, data: Data([0]))
        #expect(cache.contiguousBackwardFloor(from: 4) == 5)
    }

    @Test("an empty cache has no top to walk back from")
    func emptyCacheHasNoFloor() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        #expect(cache.highestResidentIndex == nil)
    }
}

/// AE#441 round 3: the retest read `live window slid past the consumer` four times in the 48 s after a
/// deep rewound landing, every one of them `firstVisible == consumerTarget + 1`, with no stall and no
/// cache miss behind any of them. Reproduced on the harness (`live --rewind-hold`, 220 s, window 60 s):
/// four latched lines, gap 1 on all four. So the line was reading the LAST fetch when the cost is
/// decided by the NEXT one, and the slide that reaches the fetch point was also unlinking the segment
/// under the serve.
@Suite("AE#441 round 3 a window slide is measured against the consumer's next fetch")
struct Issue441ConsumerFetchPointTests {

    // MARK: - The discriminator

    /// The sawtooth on the fetch axis. A viewer parked at the floor sits one segment below the new
    /// first-visible index for part of every slide; the index it asks for next is that very segment.
    @Test("one segment behind the window is the parked viewer's ordinary position, not a defect")
    func oneSegmentBehindIsNotADefect() {
        #expect(VideoSegmentProvider.windowSlidPastConsumer(firstVisible: 5, consumerTarget: 4) == false)
        #expect(VideoSegmentProvider.windowSlidPastConsumer(firstVisible: 33, consumerTarget: 32) == false)
    }

    /// Two segments behind is the real thing: `consumerTarget + 1` has already been deleted, so the
    /// consumer's next request is a miss whatever the playlist says.
    @Test("two segments behind means the next fetch is already deleted")
    func twoSegmentsBehindIsTheDefect() {
        #expect(VideoSegmentProvider.windowSlidPastConsumer(firstVisible: 6, consumerTarget: 4))
        #expect(VideoSegmentProvider.windowSlidPastConsumer(firstVisible: 40, consumerTarget: 11))
    }

    /// A consumer at or ahead of the window is the healthy steady state and was never a defect.
    @Test("a consumer inside the window stays silent")
    func consumerInsideTheWindow() {
        #expect(VideoSegmentProvider.windowSlidPastConsumer(firstVisible: 5, consumerTarget: 5) == false)
        #expect(VideoSegmentProvider.windowSlidPastConsumer(firstVisible: 5, consumerTarget: 12) == false)
    }

    // MARK: - The eviction floor

    /// The case the retest exposed: the slide reaching `consumerTarget + 1` used to unlink the segment
    /// whose URL a response was about to stat, which is a 404 for an index the playlist offered.
    @Test("eviction stops at the segment being served")
    func evictionSpareTheServedSegment() {
        #expect(VideoSegmentProvider.liveEvictionFloor(firstVisible: 5, consumerTarget: 4) == 4)
    }

    /// A consumer already inside the window costs nothing: the floor is the playlist's own.
    @Test("a consumer inside the window does not hold eviction back")
    func consumerInsideDoesNotHoldBack() {
        #expect(VideoSegmentProvider.liveEvictionFloor(firstVisible: 5, consumerTarget: 5) == 5)
        #expect(VideoSegmentProvider.liveEvictionFloor(firstVisible: 5, consumerTarget: 40) == 5)
    }

    /// The other side of the bound. A consumer that stopped fetching entirely must not pin retention
    /// behind it, so the floor never trails the window by more than the one served segment.
    @Test("a stalled consumer cannot pin retention behind the window")
    func stalledConsumerCannotPinRetention() {
        #expect(VideoSegmentProvider.liveEvictionFloor(firstVisible: 40, consumerTarget: 4) == 39)
        #expect(VideoSegmentProvider.liveEvictionFloor(firstVisible: 900, consumerTarget: 0) == 899)
    }

    /// Before the first fetch there is no point to protect.
    @Test("no declared fetch point evicts to the window")
    func noConsumerYet() {
        #expect(VideoSegmentProvider.liveEvictionFloor(firstVisible: 12, consumerTarget: -1) == 12)
    }
}
