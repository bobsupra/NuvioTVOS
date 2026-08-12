import Foundation
import Testing
@testable import AetherEngine

/// #318 (cmcpherson274, raised in the #240 thread): the statement was emitted on transitions of the
/// frontier's SOURCE, and the moment determination first reaches the playhead is not one of those.
/// In their battery the pump-to-prefetch line landed at `resolvedThrough` 639.30 against a rendered
/// 640.00, the frontier climbed past 640 about a second later in silence, and the next admissible
/// line was the 30 s cadence tick. Hence 29.25 s clustered across three seek targets: emission
/// cadence, not determination latency.
///
/// Every case here is one way the crossing could be announced wrongly. A diagnostic that over-claims
/// is worse than no diagnostic, because the harness adjudicates on it.
struct Issue318CoverageCrossingTests {

    private typealias Frontier = SubtitleResolutionStatement.Frontier
    private typealias Reason = SubtitleResolutionStatement.Reason

    /// Build a statement the way the drain tick does, so the tests exercise the real clamping in
    /// `make` rather than a hand-set `resolvedThrough`.
    private func statement(playhead: Double, frontier: Double?, atEOF: Bool = false,
                           decodedThrough: Double = .nan,
                           reason: Reason = .frontier) -> SubtitleResolutionStatement.Statement {
        SubtitleResolutionStatement.make(
            fence: .init(loadGeneration: 2, seekGeneration: 7),
            streamIndex: 4,
            coveredFrom: playhead - 15,
            windowThrough: playhead + 60,
            decodedThrough: decodedThrough,
            prefetchFrontier: frontier,
            prefetchAtEndOfFile: atEOF,
            retainedFrom: nil,
            reason: reason)
    }

    // MARK: - What may count as coverage

    /// The reporter's rejected line, and the one the whole ask turns on. `via=pump` bounds the claim
    /// with the drain cursor, a lower bound on what was decoded rather than a contiguity claim, so a
    /// cursor sitting 4 s past the playhead still says nothing about determination there.
    @Test("a pump-bounded statement never states coverage, however far its cursor reaches")
    func pumpNeverStatesCoverage() {
        let s = statement(playhead: 640, frontier: nil, decodedThrough: 644.48,
                          reason: .reconstruction)
        #expect(s.via == .pump)
        #expect(s.resolvedThrough == 644.48)
        #expect(SubtitleResolutionStatement.statesCoverage(s, playhead: 640) == false)
    }

    /// Their actual frontier line: admissible in kind, short in fact. Announcing this as the crossing
    /// would claim determination over the 0.7 s the reader had not reached.
    @Test("a frontier short of the playhead does not state coverage")
    func frontierShortOfThePlayheadIsNotCoverage() {
        let s = statement(playhead: 640, frontier: 639.30)
        #expect(s.via == .prefetch)
        #expect(SubtitleResolutionStatement.statesCoverage(s, playhead: 640) == false)
    }

    /// The boundary is inclusive: a frontier exactly at the playhead has read through the position
    /// being rendered, so everything below it that holds no packet genuinely holds no subtitle.
    @Test("a frontier exactly at the playhead states coverage")
    func frontierAtThePlayheadIsCoverage() {
        #expect(SubtitleResolutionStatement.statesCoverage(statement(playhead: 640, frontier: 640),
                                                           playhead: 640))
    }

    /// End of stream is the strongest form: the reader ran out of file, so the window is determined
    /// in full and the playhead is inside it.
    @Test("end of stream states coverage")
    func endOfStreamIsCoverage() {
        let s = statement(playhead: 640, frontier: nil, atEOF: true)
        #expect(s.via == .eof)
        #expect(SubtitleResolutionStatement.statesCoverage(s, playhead: 640))
    }

    /// A window with nothing determined in it states nothing. `resolvedThrough=none` is the honest
    /// negative and must never read as a crossing.
    @Test("an unresolved statement states no coverage")
    func unresolvedStatesNothing() {
        var s = statement(playhead: 640, frontier: 700)
        s.resolvedThrough = nil
        #expect(SubtitleResolutionStatement.statesCoverage(s, playhead: 640) == false)
    }

    /// The claim is a SPAN. A run that begins above the playhead ends above it too, and the position
    /// being rendered sits below the floor, undetermined by this run. This is the shape a backward
    /// seek leaves behind for the ticks before the reset lands.
    @Test("a span that opens above the playhead does not cover it")
    func spanAboveThePlayheadDoesNotCoverIt() {
        let s = SubtitleResolutionStatement.Statement(
            fence: .init(loadGeneration: 2, seekGeneration: 7), streamIndex: 4,
            coveredFrom: 700, resolvedThrough: 760, via: .prefetch, decodedThrough: 720,
            retainedFrom: nil, reason: .frontier)
        #expect(SubtitleResolutionStatement.statesCoverage(s, playhead: 640) == false)
    }

    /// A playhead the engine cannot state (no timebase yet) is not a position to claim coverage at.
    @Test("a non-finite playhead states no coverage")
    func nonFinitePlayheadStatesNothing() {
        #expect(SubtitleResolutionStatement.statesCoverage(statement(playhead: 640, frontier: 700),
                                                           playhead: .nan) == false)
    }

    // MARK: - Which transition the tick prints

    /// A reset anchors the post-seek sequence and keeps its own reason even when it happens to state
    /// coverage already. The caller latches the claim on the way out, so nothing repeats it.
    @Test("a reset prints as reconstruction even when it already states coverage")
    func resetKeepsItsReason() {
        let s = statement(playhead: 640, frontier: 700, reason: .reconstruction)
        #expect(SubtitleResolutionStatement.transitionReason(
            s, playhead: 640, isReset: true, coverageStated: false,
            lastFrontier: nil) == .reconstruction)
    }

    /// The two transitions coincide often: the tick where the side reader's position first passes the
    /// fence is frequently the tick where it is already ahead of the playhead. The crossing wins,
    /// because `via=` carries the source change either way while nothing else marks the crossing.
    @Test("a crossing outranks the frontier change it arrives with")
    func crossingOutranksFrontierChange() {
        let s = statement(playhead: 640, frontier: 690)
        #expect(SubtitleResolutionStatement.transitionReason(
            s, playhead: 640, isReset: false, coverageStated: false,
            lastFrontier: .pump) == .coverage)
    }

    /// The #231 case, unchanged by #318: the prefetcher died, determination collapsed to the pump's
    /// lookahead, and that has to be said before the next cadence tick 30 s later.
    @Test("a frontier collapse with no coverage still prints as frontier")
    func frontierCollapseStillPrints() {
        let s = statement(playhead: 640, frontier: nil, decodedThrough: 641)
        #expect(s.via == .pump)
        #expect(SubtitleResolutionStatement.transitionReason(
            s, playhead: 640, isReset: false, coverageStated: true,
            lastFrontier: .prefetch) == .frontier)
    }

    /// The reason the line is a transition and not a cadence: once the crossing is stated, the same
    /// truth every 500 ms would bury it. The reporter declined per-tick cadence explicitly in #250.
    @Test("a stated crossing does not repeat on the ticks after it")
    func crossingIsStatedOnce() {
        let s = statement(playhead: 641, frontier: 700)
        #expect(SubtitleResolutionStatement.transitionReason(
            s, playhead: 641, isReset: false, coverageStated: true,
            lastFrontier: .prefetch) == nil)
    }

    /// A tick that changed nothing prints nothing, including while determination is still short.
    /// Silence between the reconstruction line and the crossing is itself the information that the
    /// reader has not caught the playhead yet, which is the #240 starvation signature.
    @Test("a tick with neither a crossing nor a source change prints nothing")
    func quietTickPrintsNothing() {
        let s = statement(playhead: 640, frontier: 639.5)
        #expect(SubtitleResolutionStatement.transitionReason(
            s, playhead: 640, isReset: false, coverageStated: false,
            lastFrontier: .prefetch) == nil)
    }

    // MARK: - The reporter's sequence, end to end

    /// Their 640 s repetitions, tick by tick. Before #318 the third tick was silent and their gate
    /// waited for the 30 s cadence line; now the crossing is stated where it happens, roughly where
    /// their own instrumentation saw the rendered state match at 1.33 to 1.39 s.
    @Test("the reporter's post-seek sequence announces the crossing when it happens")
    func reporterSequence() {
        var stated = false
        var lastFrontier: Frontier? = nil

        func step(_ s: SubtitleResolutionStatement.Statement, playhead: Double,
                  isReset: Bool = false) -> Reason? {
            if isReset { stated = false }
            let reason = SubtitleResolutionStatement.transitionReason(
                s, playhead: playhead, isReset: isReset, coverageStated: stated,
                lastFrontier: lastFrontier)
            guard reason != nil else { return nil }
            lastFrontier = s.via
            if SubtitleResolutionStatement.statesCoverage(s, playhead: playhead) { stated = true }
            return reason
        }

        // The reconstruction tick. The reanchor has not even been requested yet, so the frontier is
        // the pump's and its 644.48 is the drain cursor.
        #expect(step(statement(playhead: 640, frontier: nil, decodedThrough: 644.48,
                               reason: .reconstruction),
                     playhead: 640, isReset: true) == .reconstruction)
        #expect(stated == false)

        // The side reader's position passes the fence, still 0.7 s short of the rendered position.
        #expect(step(statement(playhead: 640.2, frontier: 639.30), playhead: 640.2) == .frontier)
        #expect(stated == false)

        // The tick this issue exists for. Before #318 this one was silent.
        #expect(step(statement(playhead: 641.4, frontier: 646.10), playhead: 641.4) == .coverage)
        #expect(stated)

        // And it stays stated, so the crossing does not repeat at 2 Hz for the rest of the run.
        #expect(step(statement(playhead: 641.9, frontier: 651.0), playhead: 641.9) == nil)
    }

    /// The field the harness switches on. New value, unchanged field set and order, so a key-based
    /// parser is untouched.
    @Test("the crossing formats as reason=coverage")
    func crossingFormatsAsCoverage() {
        var s = statement(playhead: 641.4, frontier: 646.10)
        s.reason = .coverage
        let line = SubtitleResolutionStatement.format(s)
        #expect(line.hasSuffix("reason=coverage"))
        #expect(line.contains("via=prefetch "))
        #expect(line.contains("resolvedThrough=646.10 "))
    }
}
