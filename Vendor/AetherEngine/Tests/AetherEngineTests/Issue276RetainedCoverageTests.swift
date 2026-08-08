import Foundation
import Testing
@testable import AetherEngine

/// #276 (cmcpherson274): the #250 statement could express every truth class its harness needed
/// except one, "empty because nothing was ever authored before this point". Adjudicating that as
/// determined emptiness rather than a dead pipeline needs coverage back to track start, and
/// `coveredFrom` resets to `target - backscan` on every discontinuity. The pre-seek line does carry
/// the bound, but under the previous `seekGen`, and combining across the fence is exactly what the
/// fence forbids. So the engine has to do the reconciling and state the result: `retainedFrom`.
///
/// The claim is real rather than optimistic bookkeeping: `reanchorSubtitleOverlays` leaves a
/// drained channel's cues in place across a seek by design and rebuilds only the decoder and the
/// stale-arrival gate. What was missing was the record of it.
///
/// Every case here is one way the field could lie. A diagnostic that over-claims is worse than no
/// diagnostic, because the harness adjudicates on it.
struct Issue276RetainedCoverageTests {

    private typealias Retention = SubtitleResolutionStatement.Retention

    // MARK: - Folding a fresh run into the retained one

    /// The reporter's case. A load run covered from before track start and determined through 40;
    /// a far seek to 30 opens its window at 15, inside that span. The runs touch, so the floor
    /// survives the seek and the line can still state coverage back past zero.
    @Test("a seek landing inside the retained span keeps the floor")
    func contiguousSeekKeepsTheFloor() {
        let folded = SubtitleResolutionStatement.fold(Retention(from: -15, through: 40),
                                                      windowFrom: 15)
        #expect(folded.from == -15)
        #expect(folded.through == 40)
    }

    /// Abutting is touching. A window that opens exactly at the determined end leaves no undecoded
    /// second between the runs, so there is nothing to over-claim.
    @Test("a window opening exactly at the determined end still joins")
    func abuttingRunsJoin() {
        #expect(SubtitleResolutionStatement.fold(Retention(from: -15, through: 40),
                                                 windowFrom: 40).from == -15)
    }

    /// The over-claim the fold exists to prevent. A seek far enough forward that the 15 s backscan
    /// does not reach back over the hole leaves a span nobody decoded, and a floor spanning it
    /// would state determination over content the engine never saw.
    @Test("a forward seek past the determined end starts a new run")
    func forwardSeekPastTheEndStartsOver() {
        let folded = SubtitleResolutionStatement.fold(Retention(from: -15, through: 40),
                                                      windowFrom: 285)
        #expect(folded.from == 285)
        #expect(folded.through == nil, "the old run's ceiling does not carry over a hole")
    }

    /// The mirror image, and the subtler one: a backward seek whose window opens BELOW the retained
    /// floor. `windowFrom <= through` holds, but the union is two disjoint intervals until the new
    /// run's determination climbs back up to the old floor, so the retained span restarts on the
    /// new window. The old ceiling goes with it, which under-claims a region above a playhead that
    /// just moved below it.
    @Test("a backward seek below the retained floor starts a new run")
    func backwardSeekBelowTheFloorStartsOver() {
        let folded = SubtitleResolutionStatement.fold(Retention(from: 100, through: 160),
                                                      windowFrom: -5)
        #expect(folded.from == -5)
        #expect(folded.through == nil)
    }

    /// A run that never stated a determined end vouches for nothing, so nothing can be folded into
    /// it. This is the state right after a reset whose reader had not banked a position yet.
    @Test("a run with no determined end cannot be extended into")
    func runWithoutACeilingCannotBeJoined() {
        let folded = SubtitleResolutionStatement.fold(Retention(from: 15, through: nil),
                                                      windowFrom: 20)
        #expect(folded.from == 20)
    }

    /// The first run of a session seeds the floor from its own window, unclamped: a container with
    /// `start_time != 0` must not have coverage claimed below its first PTS.
    @Test("the first run seeds the floor from its window, unclamped")
    func firstRunSeedsTheFloor() {
        let seeded = SubtitleResolutionStatement.fold(nil, windowFrom: -15)
        #expect(seeded.from == -15)
        #expect(seeded.through == nil)
    }

    // MARK: - Banking the determined end

    /// The high-water only ever moves forward. A tick whose frontier sits behind the retained
    /// ceiling (a backward seek leaves the reader ahead of the new window, so its early ticks
    /// resolve short) must not pull the ceiling down and manufacture a hole at the next seek.
    @Test("the determined end is a high-water mark")
    func determinedEndIsAHighWater() {
        var run = SubtitleResolutionStatement.extend(Retention(from: -15, through: nil), with: 40)
        #expect(run.through == 40)
        run = SubtitleResolutionStatement.extend(run, with: 25)
        #expect(run.through == 40)
        run = SubtitleResolutionStatement.extend(run, with: 90)
        #expect(run.through == 90)
    }

    /// A tick that determined nothing states nothing. `resolvedThrough` is nil whenever the window
    /// holds no usable frontier, and folding that in as a zero would put the ceiling below the
    /// floor and read as a hole forever after.
    @Test("an unresolved tick banks nothing")
    func unresolvedTickBanksNothing() {
        let run = Retention(from: -15, through: 40)
        #expect(SubtitleResolutionStatement.extend(run, with: nil).through == 40)
        #expect(SubtitleResolutionStatement.extend(run, with: .nan).through == 40)
        #expect(SubtitleResolutionStatement.extend(Retention(from: -15, through: nil),
                                                   with: nil).through == nil)
    }

    // MARK: - The two claims stay separate

    /// `retainedFrom` is never later than `coveredFrom`: a fold either keeps a floor that is at or
    /// below the new window start, or restarts on that same window start. The harness reads them
    /// as a pair, and an inversion would mean one of them is not what it says it is.
    @Test("the retained floor is never later than the reset window")
    func retainedFloorNeverExceedsCoveredFrom() {
        for windowFrom in stride(from: -30.0, through: 300.0, by: 7.5) {
            let folded = SubtitleResolutionStatement.fold(Retention(from: -15, through: 40),
                                                          windowFrom: windowFrom)
            #expect(folded.from <= windowFrom)
        }
    }

    /// End to end on the reporter's fixture: PGS whose first display set is at 88.380, a load run
    /// determined through 40, a far seek to 30. The line states a reset window of 15 and a retained
    /// floor of -15 at the same time, under the CURRENT seek generation, so the harness never has
    /// to combine two lines to reach track start.
    @Test("a far seek states the reset window and the retained floor together")
    func farSeekStatesBothFloors() {
        let retained = SubtitleResolutionStatement.fold(Retention(from: -15, through: 40),
                                                        windowFrom: 15)
        let s = SubtitleResolutionStatement.make(
            fence: .init(loadGeneration: 3, seekGeneration: 8),
            streamIndex: 4,
            coveredFrom: 15, windowThrough: 90, decodedThrough: .nan,
            prefetchFrontier: 92, prefetchAtEndOfFile: false,
            retainedFrom: retained.from, reason: .reconstruction)
        #expect(s.coveredFrom == 15)
        #expect(s.retainedFrom == -15)
        #expect(s.resolvedThrough == 90)
        let line = SubtitleResolutionStatement.format(s)
        #expect(line.contains("coveredFrom=15.00 "))
        #expect(line.contains("retainedFrom=-15.00 "))
    }

    /// The honest negative, and the reason the field is not simply pinned to the load window: seek
    /// to 30 before the reader ever passed 15 and the span between them is a real hole that the
    /// backscan does not fill. The floor rises to the new window and the harness correctly fails to
    /// prove track-start coverage.
    @Test("a seek before the reader reached the window states no retained coverage")
    func seekAheadOfTheReaderDropsTheFloor() {
        let retained = SubtitleResolutionStatement.fold(Retention(from: -15, through: 3),
                                                        windowFrom: 15)
        #expect(retained.from == 15)
    }

    /// Nothing retained is stated as nothing, not as a position. A cursor-less channel has decoded
    /// no run at all, and "none" has to stay distinguishable from a floor that happens to be 0.
    @Test("no retained run formats as none")
    func noRetainedRunFormatsAsNone() {
        let s = SubtitleResolutionStatement.make(
            fence: .init(loadGeneration: 1, seekGeneration: 1),
            streamIndex: 4,
            coveredFrom: 15, windowThrough: 90, decodedThrough: .nan,
            prefetchFrontier: nil, prefetchAtEndOfFile: false,
            retainedFrom: nil, reason: .tick)
        #expect(SubtitleResolutionStatement.format(s).contains("retainedFrom=none "))
    }
}
