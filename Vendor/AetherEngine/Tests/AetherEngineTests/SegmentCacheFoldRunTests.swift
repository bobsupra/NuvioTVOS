// #369: discontinuity-scale fold runs must reach the fold counters. The old guard dropped runs
// wider than maxFoldRunLength on the assumption they were repositions; the field case was a 2^33
// wrap folding 312 indices in one cut, and dropping it left every counter at 0, which disarmed
// both #358 recovery arms (the consumer-side reanchor and the engine's unrecoverable-gap handler)
// for exactly the folds most certain to trigger them.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Fold-run counting (#369)")
struct SegmentCacheFoldRunTests {

    @Test("A discontinuity-scale run counts every folded index")
    func wideRunCounts() {
        let cache = SegmentCache()
        defer { cache.close() }
        cache.noteFolded(2..<314)   // the field fold: indices 2...313 into seg-314
        #expect(cache.foldCount(2) == 1)
        #expect(cache.foldCount(160) == 1)
        #expect(cache.foldCount(313) == 1)
        #expect(cache.foldCount(314) == 0)   // the tail segment itself was opened, not folded
    }

    @Test("A repeat across a producer restart is the #358 signal and increments")
    func repeatAcrossPumpsIncrements() {
        let cache = SegmentCache()
        defer { cache.close() }
        cache.noteFolded(2..<314)
        cache.noteFolded(2..<314)
        #expect(cache.foldCount(2) == 2)
        #expect(cache.foldCount(313) == 2)
    }

    @Test("An index that produced a segment is never counted as folded")
    func storedIndexIsNotCounted() {
        let cache = SegmentCache()
        defer { cache.close() }
        cache.store(index: 5, data: Data([0x00]))
        cache.noteFolded(2..<10)
        #expect(cache.foldCount(5) == 0)
        #expect(cache.foldCount(6) == 1)
    }

    @Test("Narrow runs behave as before")
    func narrowRunUnchanged() {
        let cache = SegmentCache()
        defer { cache.close() }
        cache.noteFolded(7..<9)
        #expect(cache.foldCount(7) == 1)
        #expect(cache.foldCount(8) == 1)
        #expect(cache.foldCount(9) == 0)
    }
}
