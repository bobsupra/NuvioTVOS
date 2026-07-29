import Foundation
import Testing
@testable import AetherEngine

/// AetherEngine#207 follow-up: the reported buffer frontier collapsed to the playhead once an opt-in
/// whole-source prefetch reached its retention budget. The frontier walk anchored on the playhead's
/// segment while `pruneOutsideWindow` anchors on the consumer's fetch target (`lo = target - backwardWindow`),
/// so the playhead's own segment is evictable and really was evicted, leaving the walk to start on a hole
/// every tick. Anchoring the walk at `max(playhead, consumerTarget)` reports the end of the contiguous
/// safe range instead: everything below the fetch target is by definition already in the consumer's buffer.
@Suite("Issue #207 buffer frontier anchor")
struct Issue207FrontierAnchorTests {

    private func makeData(_ n: Int, fill: UInt8 = 0xAA) -> Data { Data(repeating: fill, count: n) }

    /// Reproduces the field report: window past the budget, fetch target ~30 segments ahead of the
    /// playhead, so the playhead's segment falls below `lo` and is evicted as an extra.
    private func makeOptInPrefetchCache() -> SegmentCache {
        // forwardWindow = opt-in whole-source; the kept window alone (31 x 10 B) exceeds the budget,
        // which is exactly the #207 condition that makes the extras eviction run at all.
        let c = SegmentCache(forwardWindow: 2700, backwardWindow: 20, retentionBudgetBytes: 100)
        for i in 0...40 { c.store(index: i, data: makeData(10)) }
        // The consumer fetches sequentially up to its target (~120 s ahead of the playhead). Declaring
        // only the final index would model a jump, which is a different situation entirely: the target
        // anchor rests on the consumer having fetched *across* the playhead, so the sequence matters.
        for t in 0...30 { c.declareTarget(t) }
        return c
    }

    @Test("Extras eviction really does drop the playhead's own segment (the #207 precondition)")
    func playheadSegmentIsEvictedUnderOptInPrefetch() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        // lo = 30 - 20 = 10, so 0...9 are extras and the kept window is already over budget.
        #expect(c.peek(index: 0) == nil)
        #expect(c.peek(index: 9) == nil)
        #expect(c.peek(index: 10) != nil)
        #expect(c.peek(index: 40) != nil)
    }

    @Test("Playhead-anchored walk reports nothing cached ahead while 31 segments are resident")
    func playheadAnchoredWalkCollapses() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        // The bug: the walk starts on a hole and returns playhead - 1, which fails the caller's
        // `frontier >= playheadIdx` guard and yields a read-ahead of 0.
        #expect(c.contiguousForwardFrontier(from: 0) == -1)
    }

    @Test("Target-anchored walk reports the resident band ahead of the consumer")
    func targetAnchoredWalkReportsFullBand() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        #expect(c.contiguousForwardFrontier(fromPlayhead: 0) == 40)
    }

    /// The trap the reporter flagged: simply skipping the leading hole would land on a stale band that
    /// survives a backward seek (nothing forces its eviction while the budget has room) and report it as
    /// buffered, i.e. fail in the dangerous direction. Anchoring on the fetch target must stop at the
    /// hole above the freshly produced band instead.
    @Test("Backward seek does not report the stale band left above the new target")
    func backwardSeekStopsBelowStaleBand() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        // Seek back to segment 2. hi = max(2 + 2700, highestStored 40) keeps the old band resident,
        // and the producer has only restarted far enough to write 2 and 3.
        c.declareTarget(2)
        c.store(index: 2, data: makeData(10))
        c.store(index: 3, data: makeData(10))
        #expect(c.peek(index: 40) != nil, "the stale band must still be resident for this to be a real trap")
        #expect(c.contiguousForwardFrontier(fromPlayhead: 2) == 3)
    }

    @Test("A refetch behind the playhead does not drag the anchor backwards")
    func backwardRefetchKeepsPlayheadAnchor() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 20)
        defer { c.close() }
        for i in 0...8 { c.store(index: i, data: makeData(10)) }
        // Continuous-Audio handover refetches a segment behind the playhead; the playhead is at 8.
        c.declareTarget(5)
        #expect(c.contiguousForwardFrontier(fromPlayhead: 8) == 8)
    }

    @Test("Default window: anchor stays the playhead, behaviour unchanged")
    func defaultWindowUnchanged() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 20)
        defer { c.close() }
        for i in [5, 6, 7, 8, 10] { c.store(index: i, data: makeData(10)) }
        c.declareTarget(5)
        #expect(c.contiguousForwardFrontier(fromPlayhead: 5) == 8)   // stops before the hole at 9
        #expect(c.contiguousForwardFrontier(fromPlayhead: 5) == c.contiguousForwardFrontier(from: 5))
    }

    /// Field report on 5.23.4: a far seek made the frontier claim a lead the size of the seek distance
    /// for one tick. `declareTarget` lands at the seek destination while `currentTime()` still reads the
    /// old position, so the target anchor walked the freshly produced band and measured it against a
    /// playhead the consumer never fetched across. The target anchor only holds inside an uninterrupted
    /// fetch sequence: AVPlayer fetches no further ahead than its buffer reaches, which is what bounds
    /// `target - playhead` during normal playback and what a seek removes.
    @Test("Forward seek: the fresh target does not claim a lead over the playhead it jumped away from")
    func forwardSeekDoesNotClaimLeadOverStalePlayhead() {
        let c = SegmentCache(forwardWindow: 2700, backwardWindow: 20, retentionBudgetBytes: 1_000_000)
        defer { c.close() }
        for i in 0...40 { c.store(index: i, data: makeData(10)) }
        for t in 0...30 { c.declareTarget(t) }
        // Seek to segment 200; the consumer fetches there and the restarted producer writes 200/201
        // while the clock still reads segment 20.
        c.declareTarget(200)
        c.store(index: 200, data: makeData(10))
        c.store(index: 201, data: makeData(10))
        #expect(c.peek(index: 40) != nil, "the budget has room, so the old band must still be resident")
        #expect(c.contiguousForwardFrontier(fromPlayhead: 20) == 40)
    }

    /// Same jump under the field's actual eviction pressure: the old band is gone, so the honest answer
    /// is that nothing is available ahead of the stale playhead. Returning below it fails the caller's
    /// `frontier >= playheadIdx` guard, which reports a read-ahead of 0.
    @Test("Forward seek with the old band evicted reports nothing ahead, not the band at the destination")
    func forwardSeekWithEvictedOldBandReportsNothingAhead() {
        let c = makeOptInPrefetchCache()
        defer { c.close() }
        c.declareTarget(200)
        c.store(index: 200, data: makeData(10))
        c.store(index: 201, data: makeData(10))
        #expect(c.peek(index: 20) == nil, "the playhead's segment must be evicted for this to be the field case")
        #expect(c.contiguousForwardFrontier(fromPlayhead: 20) == 19)
    }

    /// A backward seek ends the sequence too, otherwise a later forward seek that lands *below* the old
    /// fetch front would look like a segment the consumer had already fetched and the stale band above
    /// it would be reported as buffered.
    @Test("Forward seek below the pre-seek fetch front is still a jump")
    func forwardSeekBelowOldFrontIsStillAJump() {
        let c = SegmentCache(forwardWindow: 2700, backwardWindow: 20, retentionBudgetBytes: 1_000_000)
        defer { c.close() }
        for i in 45...60 { c.store(index: i, data: makeData(10)) }   // band left by the first pass
        for t in 0...50 { c.declareTarget(t) }
        c.declareTarget(10)                                          // backward seek, producer restarts
        for i in 10...25 { c.store(index: i, data: makeData(10)) }
        for t in 10...20 { c.declareTarget(t) }
        c.declareTarget(45)                                          // forward seek, below the old front
        #expect(c.contiguousForwardFrontier(fromPlayhead: 20) == 25)
    }

    /// Guard against tightening the rule into a plain "any non-sequential index ends the sequence":
    /// the Continuous-Audio handover refetches ~7-10 segments backward and returns to the fetch front,
    /// which must not be read as a seek. Treating it as one would re-open #207 itself, since the playhead
    /// under an opt-in prefetch sits below the retained low end and its segment really is evicted.
    @Test("Handover refetch and the return to the fetch front keep the target anchor")
    func handoverRefetchKeepsTheTargetAnchor() {
        let c = SegmentCache(forwardWindow: 2700, backwardWindow: 20, retentionBudgetBytes: 100)
        defer { c.close() }
        for i in 0...60 { c.store(index: i, data: makeData(10)) }
        for t in 0...50 { c.declareTarget(t) }
        c.declareTarget(42)   // handover refetch, inside the backward window
        c.declareTarget(51)   // back to the fetch front
        #expect(c.peek(index: 21) == nil, "the playhead's own segment is an evicted extra (lo = 51 - 20)")
        #expect(c.contiguousForwardFrontier(fromPlayhead: 21) == 60)
    }

    @Test("Fresh cache with no declared target walks from the playhead")
    func noTargetDeclaredYet() {
        let c = SegmentCache(forwardWindow: 10, backwardWindow: 20)
        defer { c.close() }
        for i in 0...3 { c.store(index: i, data: makeData(10)) }
        // currentTargetIndex is still -1 here; max() must not pull the anchor below the playhead.
        #expect(c.contiguousForwardFrontier(fromPlayhead: 0) == 3)
    }
}
