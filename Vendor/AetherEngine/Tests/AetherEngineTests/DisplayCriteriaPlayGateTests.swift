import Testing
@testable import AetherEngine

// #274: the post-load play-gate called waitForSwitch() with the same 1000 ms Stage 1 budget on every load.
// That budget exists for one case, a sole-writer host whose criteria write lands during the load (AVKit's
// auto path, DV P5 cold start). Sessions no dynamic-range switch can reach paid it as dead startup time,
// and the Stage 2 classification attributed a host-driven switch that ended SDR to a failed HDR handshake.
// Both are pure decisions; this suite covers them.
//
// Sodalite#49: the settle log those decisions would be verified against was reporting Stage 1's whole
// budget as time spent, so no run ever showed how long a switch really took. The timing helpers are pure
// too, and covered here alongside.
@Suite("DisplayCriteria play-gate grace, switch attribution and settle timing")
struct DisplayCriteriaPlayGateTests {

    // MARK: - Stage 1 budget

    @Test("Unchanged criteria skip the gate entirely (#133 behaviour preserved)")
    func unchangedCriteriaSkip() {
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: true, engineIsCriteriaWriter: true,
            formatKnown: true, effectiveFormat: .dolbyVision) == .skip)
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: true, engineIsCriteriaWriter: false,
            formatKnown: false, effectiveFormat: .sdr) == .skip)
    }

    @Test("Engine-writer sessions take the brief budget: their write already happened, pre-load and synchronously")
    func engineWriterIsBrief() {
        for format: VideoFormat in [.sdr, .hdr10, .hdr10Plus, .hlg, .dolbyVision] {
            #expect(AetherEngine.playGateGrace(
                criteriaUnchanged: false, engineIsCriteriaWriter: true,
                formatKnown: true, effectiveFormat: format) == .brief)
        }
    }

    @Test("Sole-writer host with HDR/DV content keeps the full budget (the DV P5 cold-start case the gate exists for)")
    func suppressedHostHDRIsFull() {
        for format: VideoFormat in [.hdr10, .hdr10Plus, .hlg, .dolbyVision] {
            #expect(AetherEngine.playGateGrace(
                criteriaUnchanged: false, engineIsCriteriaWriter: false,
                formatKnown: true, effectiveFormat: format) == .full)
        }
    }

    @Test("Sole-writer host with SDR content takes the brief budget: only a rate-only write can still arrive")
    func suppressedHostSDRIsBrief() {
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: false, engineIsCriteriaWriter: false,
            formatKnown: true, effectiveFormat: .sdr) == .brief)
    }

    @Test("Sole-writer host keeps the full budget when the probe failed and the range is unknown")
    func suppressedHostUnknownFormatIsFull() {
        // effectiveFormat defaults to .sdr on a failed probe, so the format alone must not decide here.
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: false, engineIsCriteriaWriter: false,
            formatKnown: false, effectiveFormat: .sdr) == .full)
    }

    @Test("Budgets are the documented millisecond values")
    func graceBudgets() {
        #expect(DisplayCriteriaController.StartGrace.skip.budgetMs == 0)
        #expect(DisplayCriteriaController.StartGrace.brief.budgetMs == 200)
        #expect(DisplayCriteriaController.StartGrace.full.budgetMs == 1000)
    }

    // MARK: - Match Content off (#289)

    @Test("Match Content off drops the wait for every budget: nothing can start a switch")
    func matchContentOffSkipsTheWait() {
        for grace: DisplayCriteriaController.StartGrace in [.skip, .brief, .full] {
            #expect(DisplayCriteriaController.shouldWait(startGrace: grace, matchingEnabled: false) == false)
        }
    }

    @Test("Match Content on keeps every non-skip budget")
    func matchContentOnKeepsTheWait() {
        #expect(DisplayCriteriaController.shouldWait(startGrace: .full, matchingEnabled: true))
        #expect(DisplayCriteriaController.shouldWait(startGrace: .brief, matchingEnabled: true))
        // #133's unchanged-skip stays a skip regardless of the toggle.
        #expect(DisplayCriteriaController.shouldWait(startGrace: .skip, matchingEnabled: true) == false)
    }

    @Test("The sole-writer DV cold start is the case the wait exists for and must survive")
    func soleWriterHDRStillWaitsWhenMatchingIsOn() {
        // playGateGrace hands this path .full; with matching on it must still be waited out (#274).
        let grace = AetherEngine.playGateGrace(
            criteriaUnchanged: false, engineIsCriteriaWriter: false,
            formatKnown: true, effectiveFormat: .dolbyVision)
        #expect(grace == .full)
        #expect(DisplayCriteriaController.shouldWait(startGrace: grace, matchingEnabled: true))
        // ... and is dead time only once the panel cannot switch at all.
        #expect(DisplayCriteriaController.shouldWait(startGrace: grace, matchingEnabled: false) == false)
    }

    // MARK: - Criteria attribution

    @Test("Engine HDR criteria ending with headroom 1.0 stays a real handshake failure")
    func engineHDRFailureStillWarns() {
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: true, lastCriteriaWasHDR: true) == .engineHDR)
    }

    @Test("Engine SDR rate-only criteria ending SDR is the expected outcome")
    func engineRateOnlySettles() {
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: true, lastCriteriaWasHDR: false) == .engineRateOnly)
    }

    @Test("A switch the engine never wrote is unattributable, not an HDR failure")
    func hostDrivenSwitchIsUnattributable() {
        // The reporter's symptom: a host SDR rate write, mid-load, logged as
        // "panel stayed SDR despite HDR criteria" because didApply was false.
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: false, lastCriteriaWasHDR: false) == .hostDriven)
        // lastCriteriaWasHDR is stale state from a previous session once didApply is false; it must not
        // resurrect the HDR verdict.
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: false, lastCriteriaWasHDR: true) == .hostDriven)
    }

    // MARK: - Settle timing (Sodalite#49)

    @Test("Reported timings are the measured ones, not the Stage 1 budget added back in")
    func timingSuffixReportsMeasuredValues() {
        let suffix = DisplayCriteriaController.timingSuffix(
            startSignal: .inGate, stage1Ms: 5, totalMs: 55)
        #expect(suffix == "start in-gate after 5ms, total 55ms")
        // The line this replaces read "~1050ms" for exactly this switch: Stage 1's full 1000 ms budget,
        // which it never spent, plus one 50 ms Stage 2 tick.
        #expect(!suffix.contains("1050"))
        #expect(!suffix.contains("1000"))
    }

    @Test("Start signal distinguishes a switch already running from one that began inside the gate")
    func startSignalNamesTheOrdering() {
        // The whole point of #49. Since #339 the observation is armed at the criteria write, so a switch
        // that was running while the item was built announces itself and the flag-only reading says exactly
        // what it is: a switch this session's write never announced.
        #expect(DisplayCriteriaController.StartSignal.preGateObserved.rawValue
            == "pre-gate (start notification, before gate entry)")
        #expect(DisplayCriteriaController.StartSignal.preGate.rawValue
            == "pre-gate (flag only, no start notification since the criteria write)")
        #expect(DisplayCriteriaController.StartSignal.inGate.rawValue == "in-gate")
        #expect(DisplayCriteriaController.timingSuffix(
            startSignal: .inGate, stage1Ms: 120, totalMs: 300)
            == "start in-gate after 120ms, total 300ms")
    }

    // MARK: - Start classification (Sodalite#49, second measurement round)
    //
    // The first round's fix made the reported numbers real. The numbers then showed that the signal they
    // were attached to was not: all three reporter runs came back "pre-gate", including one whose flag was
    // demonstrably false for the first 376 ms. Stage 1 tested the in-progress flag on every poll but drew
    // the pre-gate conclusion the enum only licenses for the first one.

    @Test("A start notification names an in-gate start, whatever the in-progress flag reads")
    func notificationWinsOverFlag() {
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: true, startNotificationFired: true, switchInProgress: true) == .inGate)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: false, startNotificationFired: true, switchInProgress: false) == .inGate)
    }

    @Test("The in-progress flag on the very first poll is the only evidence of a pre-gate start")
    func flagOnFirstPollIsPreGate() {
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: true, startNotificationFired: false, switchInProgress: true) == .preGate)
    }

    @Test("A flag that only rises after the first poll started inside the gate, notification or not")
    func flagRisingLaterIsNotPreGate() {
        // The reporter's flipped run logged "start pre-gate after 376ms". The flag was false at entry and
        // for ~37 polls after it, and the classifier still called the switch older than the gate, which is
        // the single question #49 was filed on. A flag observed false at entry cannot describe a switch
        // that predates entry.
        let signal = DisplayCriteriaController.classifyStart(
            isFirstPoll: false, startNotificationFired: false, switchInProgress: true)
        #expect(signal == .inGateFlagOnly)
        #expect(signal != .preGate)
    }

    @Test("Nothing observed keeps Stage 1 polling")
    func nothingObservedKeepsPolling() {
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: true, startNotificationFired: false, switchInProgress: false) == nil)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: false, startNotificationFired: false, switchInProgress: false) == nil)
    }

    @Test("The flag-only start reads as its own signal, not as either certainty")
    func flagOnlyStartHasItsOwnSuffix() {
        // Naming the missed notification matters: it is the difference between "the panel started late" and
        // "we were not listening yet", and only the second one indicts the observer registration point.
        #expect(DisplayCriteriaController.timingSuffix(
            startSignal: .inGateFlagOnly, stage1Ms: 376, totalMs: 3238)
            == "start in-gate (flag only, start notification missed) after 376ms, total 3238ms")
    }

    // MARK: - Budgets are deadlines, not tick counts (Sodalite#49)

    @Test("A budget is spent by elapsed time, so scheduler overhead cannot stretch it")
    func budgetExhaustsOnElapsedTime() {
        #expect(DisplayCriteriaController.isBudgetSpent(elapsedMs: 1999, budgetMs: 2000) == false)
        #expect(DisplayCriteriaController.isBudgetSpent(elapsedMs: 2000, budgetMs: 2000))
        // Both figures are measured, from two runs of the same "2 s cap" on the reporter's Apple TV: a
        // tick-counting Stage 2 ran its 40 x 50 ms to 2082 ms in one and to 2862 ms in another, a 40 %
        // spread on a thermally throttled device. A deadline does not have that spread.
        #expect(DisplayCriteriaController.isBudgetSpent(elapsedMs: 2082, budgetMs: 2000))
        #expect(DisplayCriteriaController.isBudgetSpent(elapsedMs: 2862, budgetMs: 2000))
    }

    @Test("A zero budget is spent before the first poll")
    func zeroBudgetIsSpentImmediately() {
        #expect(DisplayCriteriaController.isBudgetSpent(elapsedMs: 0, budgetMs: 0))
    }

    @Test("The Stage 2 cap is the documented two seconds")
    func stage2CapIsTwoSeconds() {
        #expect(DisplayCriteriaController.stage2CapMs == 2000)
    }

    @Test("Elapsed conversion is nanoseconds to whole milliseconds, truncating")
    func elapsedMsConvertsNanoseconds() {
        let base: UInt64 = 1_000_000_000
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: 1_050_000_000) == 50)
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: base) == 0)
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: 1_000_999_000) == 0)
        // Reversed arguments must not trap on the unsigned subtraction.
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: 0) == 0)
    }
}
