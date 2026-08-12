// #358: what a request for a plan index the cutter folded away should do.
//
// The keyframe-gated cutter (#92) opens a segment at the IRAP that reaches a plan boundary, so a
// boundary no IRAP reaches is stepped over while the playlist keeps offering that index. Waiting for
// it is waiting for something no pump will produce: measured on a 40 s-GOP source against a 30 s
// grid, the request rode out the slow threshold, the server closed for a retry, and the session sat
// frozen at 90 s with the engine still reporting `playing`. Re-anchoring the producer at the folded
// index moves the boundaries with the base and opens it (same source, same build: plays to the end).
// A second fold is that repair reproducing its own trigger, which is the one case worth failing on.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Folded segment target decision (#358)")
struct FoldedSegmentTargetTests {

    @Test("An index nobody folded is ordinary read-ahead")
    func unfoldedWaits() {
        #expect(VideoSegmentProvider.foldedTargetDecision(
            folds: 0, alreadyReanchoredHere: false) == .wait)
        #expect(VideoSegmentProvider.foldedTargetDecision(
            folds: 0, alreadyReanchoredHere: true) == .wait)
    }

    @Test("The first fold is repaired by anchoring the producer at that index")
    func firstFoldReanchors() {
        #expect(VideoSegmentProvider.foldedTargetDecision(
            folds: 1, alreadyReanchoredHere: false) == .reanchor)
    }

    @Test("A retry while that repair is in flight waits rather than failing")
    func retryDuringRepairWaits() {
        // The fold count is only cleared when the segment lands, so a retry a second after the
        // re-anchor still sees folds=1. Failing here would kill sessions the repair fixes.
        #expect(VideoSegmentProvider.foldedTargetDecision(
            folds: 1, alreadyReanchoredHere: true) == .wait)
    }

    @Test("A second fold ends the source instead of freezing it")
    func secondFoldFails() {
        // The repair rebuilt the same gap, so no further attempt changes the outcome. The alternative
        // is what the reporter saw: a picture that never moves again and no error to act on.
        #expect(VideoSegmentProvider.foldedTargetDecision(
            folds: 2, alreadyReanchoredHere: false) == .fail)
        #expect(VideoSegmentProvider.foldedTargetDecision(
            folds: 2, alreadyReanchoredHere: true) == .fail)
        #expect(VideoSegmentProvider.foldedTargetDecision(
            folds: 7, alreadyReanchoredHere: true) == .fail)
    }

    @Test("The cap is pinned at two folds")
    func capIsTwo() {
        // Pins the threshold so lowering it (which would fail sessions the re-anchor repairs) or
        // raising it (which would restore the freeze) becomes a visible test break.
        #expect(HLSVideoEngine.foldsProvingUnrecoverableGap == 2)
    }
}
