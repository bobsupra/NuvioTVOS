import Testing
@testable import AetherEngine

// AE#449: with the #447 holdback down to 6 s the first live manifest arrives ~1.2 s into a native join, and
// the term deciding press-to-motion became the display-criteria gate rather than the manifest. On the
// reporter's panel a `rate=50.000` write to a display already running 50.002 Hz still posts a mode-switch
// start, never posts an end, and holds `isDisplayModeSwitchInProgress` for the whole 2 s cap: eight of nine
// gates in an 18 minute session spent it in full, with the first frame visibly frozen on screen for 0.89 s.
//
// The gate now reads the panel's own cadence instead of waiting out a notification that is not coming. These
// are the pure halves of that decision.
@Suite("AE#449 rate-only criteria satisfied by the panel's measured cadence")
struct Issue449RateOnlyCriteriaSettleTests {

    // MARK: - Relating the measured cadence to the requested rate

    @Test("A panel reading slightly off nominal is still running the requested rate")
    func offNominalPanelIsAnExactMatch() {
        // The reporter's numbers: requested 50.000, panel 50.002.
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: 50.002)
                == .exact(panelRate: 50.002))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 59.94, panelNominalRate: 59.9401)
                == .exact(panelRate: 59.9401))
    }

    @Test("23.976 and 24.000 stay different modes: the pair the tolerance is sized against")
    func filmRatesDoNotCollapse() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 23.976, panelNominalRate: 24.0)
                == .different(panelRate: 24.0))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 24.0, panelNominalRate: 23.976)
                == .different(panelRate: 23.976))
    }

    @Test("29.97 against a 60.000 panel is not a multiple: 2x29.97 is 59.94, a different mode")
    func ntscPairIsNotAMultipleOfTheIntegerRate() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 29.97, panelNominalRate: 60.0)
                == .different(panelRate: 60.0))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 29.97, panelNominalRate: 59.94)
                == .multiple(panelRate: 59.94, factor: 2))
    }

    @Test("A 50 Hz panel is an exact double of a 25.000 request, which tvOS itself leaves alone")
    func halfRateContentIsAMultiple() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 25.0, panelNominalRate: 50.002)
                == .multiple(panelRate: 50.002, factor: 2))
    }

    @Test("A panel running the old mode is neither, so the gate keeps waiting")
    func realSwitchInFlightReadsAsDifferent() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: 60.0)
                == .different(panelRate: 60.0))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 23.976, panelNominalRate: 60.0)
                == .different(panelRate: 60.0))
    }

    @Test("No fresh tick and no requested rate both read as unmeasured")
    func missingInputsAreUnmeasured() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: nil)
                == .unmeasured)
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: nil, panelNominalRate: 50.002)
                == .unmeasured)
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 0, panelNominalRate: 50.002)
                == .unmeasured)
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: 0)
                == .unmeasured)
    }

    // MARK: - What may end the settle wait

    @Test("An exact match ends the wait for the engine's own rate-only write")
    func exactMatchSettlesRateOnly() {
        #expect(DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .exact(panelRate: 50.002), heldForMs: 0))
    }

    /// The multiple is the round-2 half. It cannot settle on sight, because a 25.000 request is
    /// satisfied both by the 50.002 Hz the panel already runs and by a 25 Hz mode it might still be
    /// switching to. It settles on having HELD that reading, which a switch in flight cannot do: the
    /// panel blanks while it runs and the link stops delivering ticks.
    @Test("A multiple settles only once the panel has held it for the dwell")
    func multipleSettlesAfterTheDwell() {
        let multiple = DisplayCriteriaController.PanelRateRelation.multiple(panelRate: 50.002, factor: 2)
        let dwell = DisplayCriteriaController.panelMultipleDwellMs
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: multiple, heldForMs: 0))
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: multiple, heldForMs: dwell - 1))
        #expect(DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: multiple, heldForMs: dwell))
    }

    /// The asymmetry, stated as a test: the exact match needs no dwell because the requested state and
    /// the observed state are the same, so a pending switch is a switch to what is already on screen.
    @Test("An exact match needs no dwell, a multiple does")
    func onlyTheMultipleNeedsTime() {
        #expect(DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .exact(panelRate: 50.002), heldForMs: 0))
    }

    @Test("A panel in another mode, or one not presenting at all, does not settle anything, however long it holds")
    func differentAndUnmeasuredDoNotSettle() {
        for held in [0, DisplayCriteriaController.panelMultipleDwellMs, 10_000] {
            #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
                attribution: .engineRateOnly, relation: .different(panelRate: 60.0), heldForMs: held))
            #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
                attribution: .engineRateOnly, relation: .unmeasured, heldForMs: held))
        }
    }

    @Test("A matching rate says nothing about a dynamic-range handshake, so an HDR write is never settled by it")
    func hdrWriteIsNeverSettledByRate() {
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineHDR, relation: .exact(panelRate: 50.002), heldForMs: 0))
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineHDR, relation: .multiple(panelRate: 50.002, factor: 2), heldForMs: 10_000))
    }

    @Test("A switch the engine did not initiate has no requested rate to be compared against")
    func hostDrivenWriteIsNeverSettledByRate() {
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .hostDriven, relation: .exact(panelRate: 50.002), heldForMs: 0))
    }

    // MARK: - The dwell is a run, not a timer

    /// The reason the run compares relations rather than hertz: the per-tick figure moves in the fourth
    /// decimal, and comparing the value would restart the dwell on nearly every tick.
    @Test("A cadence wobbling in the fourth decimal is the same run")
    func jitterDoesNotRestartTheRun() {
        var run = DisplayCriteriaController.extendCadenceRun(
            nil, relation: .multiple(panelRate: 50.002, factor: 2), nowMs: 0)
        run = DisplayCriteriaController.extendCadenceRun(
            run, relation: .multiple(panelRate: 50.001, factor: 2), nowMs: 50)
        run = DisplayCriteriaController.extendCadenceRun(
            run, relation: .multiple(panelRate: 50.003, factor: 2), nowMs: 100)
        #expect(run.startedAtMs == 0)
        #expect(run.heldMs(atMs: 300) == 300)
    }

    /// The case the dwell exists to catch: a panel that stops presenting mid-dwell reads `.unmeasured`,
    /// which is a different state, so the run restarts and the multiple has to earn its time again.
    @Test("A blank in the middle of the dwell restarts it")
    func aBlankRestartsTheRun() {
        var run = DisplayCriteriaController.extendCadenceRun(
            nil, relation: .multiple(panelRate: 50.002, factor: 2), nowMs: 0)
        run = DisplayCriteriaController.extendCadenceRun(run, relation: .unmeasured, nowMs: 150)
        run = DisplayCriteriaController.extendCadenceRun(
            run, relation: .multiple(panelRate: 50.002, factor: 2), nowMs: 200)
        #expect(run.startedAtMs == 200)
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: run.relation, heldForMs: run.heldMs(atMs: 250)))
    }

    /// A panel that lands on a different multiple is a different state too, so a x2 run cannot be
    /// inherited by a x4 reading.
    @Test("A different factor is a different run")
    func factorChangeRestartsTheRun() {
        let run = DisplayCriteriaController.extendCadenceRun(
            DisplayCriteriaController.extendCadenceRun(
                nil, relation: .multiple(panelRate: 50.0, factor: 2), nowMs: 0),
            relation: .multiple(panelRate: 100.0, factor: 4), nowMs: 100)
        #expect(run.startedAtMs == 100)
    }

    /// Six Stage 2 polls, and longer than seven frame intervals at the slowest mode tvOS switches to,
    /// so a blank cannot fit inside the dwell unobserved. It also has to stay well under the cap it is
    /// there to avoid spending.
    @Test("The dwell outlasts a blank and stays well under the cap")
    func dwellIsBoundedOnBothSides() {
        let dwell = DisplayCriteriaController.panelMultipleDwellMs
        #expect(dwell >= 7 * Int(1000.0 / 23.976))
        #expect(dwell <= 500)
    }

    // MARK: - Log vocabulary

    @Test("Each relation names the panel rate it was read from, so a retest can separate the cases")
    func logDescriptionsCarryTheMeasurement() {
        #expect(DisplayCriteriaController.PanelRateRelation.exact(panelRate: 50.002)
            .logDescription.contains("50.002"))
        #expect(DisplayCriteriaController.PanelRateRelation.multiple(panelRate: 50.002, factor: 2)
            .logDescription.contains("x2"))
        #expect(DisplayCriteriaController.PanelRateRelation.different(panelRate: 60.0)
            .logDescription.contains("60.000"))
        #expect(DisplayCriteriaController.PanelRateRelation.unmeasured
            .logDescription.contains("unmeasured"))
    }

    // MARK: - Round 3: what a cap line has to be able to say

    /// The reporter's caution, made readable: if a `.multiple` ever reaches the cap, the question is
    /// whether the run kept breaking or never got going, and the history answers it without a new run.
    @Test("an unbroken Stage 2 reports no breaks and the run it held")
    func unbrokenHistoryCountsNoBreaks() {
        var history = DisplayCriteriaController.PanelCadenceHistory()
        for ms in stride(from: 50, through: 400, by: 50) {
            history = DisplayCriteriaController.extendCadenceHistory(
                history, relation: .multiple(panelRate: 50.002, factor: 2), nowMs: ms)
        }
        #expect(history.restarts == 0)
        #expect(history.longestHeldMs == 350)
        #expect(history.logDescription.contains("broke 0 times"))
    }

    /// A tick that reads nothing at all is the blank the dwell exists to catch, and it has to show up as
    /// a break rather than as a shorter run.
    @Test("a tick that reads a different cadence breaks the run and is counted")
    func brokenHistoryCountsTheBreak() {
        var history = DisplayCriteriaController.PanelCadenceHistory()
        history = DisplayCriteriaController.extendCadenceHistory(
            history, relation: .multiple(panelRate: 50.002, factor: 2), nowMs: 50)
        history = DisplayCriteriaController.extendCadenceHistory(
            history, relation: .multiple(panelRate: 50.002, factor: 2), nowMs: 150)
        history = DisplayCriteriaController.extendCadenceHistory(
            history, relation: .unmeasured, nowMs: 200)
        history = DisplayCriteriaController.extendCadenceHistory(
            history, relation: .multiple(panelRate: 50.002, factor: 2), nowMs: 250)

        #expect(history.restarts == 2)
        // The longest run is the first one (50 ms to 200 ms), not the truncated tail.
        #expect(history.longestHeldMs == 150)
        #expect(history.logDescription.contains("broke 2 times"))
        #expect(history.logDescription.contains("150ms"))
    }

    /// One break reads as one break, because a line that says "1 times" is a line nobody trusts.
    @Test("the break count is written as English")
    func singularBreakReadsAsOne() {
        var history = DisplayCriteriaController.PanelCadenceHistory()
        history = DisplayCriteriaController.extendCadenceHistory(
            history, relation: .exact(panelRate: 50.002), nowMs: 50)
        history = DisplayCriteriaController.extendCadenceHistory(
            history, relation: .unmeasured, nowMs: 100)
        #expect(history.restarts == 1)
        #expect(history.logDescription.contains("broke 1 time,"))
    }
}
