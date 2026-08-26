import Testing
import Foundation
@testable import AetherEngine

/// #377 round 6: the reporter measured his origin refusing every NEW request for about four
/// minutes out of every ten, healing on its own, with the recovery arriving at 243 s. The engine
/// gave up at 212 s, and no constant said 212: it was four paced attempts (76 s) each followed by a
/// reopen that walked the reader's own reconnect ladder (about 34 s), two counters that did not
/// know about each other. These pin the budget as one stated number, and pin that it belongs to a
/// refusal WINDOW rather than to the session.
@Suite("#377 refusing-source revive budget")
struct Issue377RefusingSourceBudgetTests {

    /// Clock helper: DispatchTime arithmetic in whole seconds from a fixed base.
    private func t(_ seconds: Double, from base: DispatchTime) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: base.uptimeNanoseconds + UInt64(seconds * 1_000_000_000))
    }

    @Test("the budget is wall clock, and it outlasts the 243 s recovery that the old 212 s missed")
    func budgetCoversTheMeasuredRecovery() {
        var budget = RefusingSourceReviveBudget()
        let base = DispatchTime.now()

        let first = budget.admit(now: base)
        #expect(first)
        // The reporter's window: attempts land roughly every 40 to 80 s (a ladder rung plus the
        // reopen). At 243 s the origin answered again, and the session had to still be alive.
        var last = base
        for offset in stride(from: 40.0, through: 243.0, by: 40.0) {
            last = t(offset, from: base)
            let admitted = budget.admit(now: last)
            #expect(admitted,
                    "an origin that heals at 243 s must not be given up on before it")
        }
        #expect(budget.elapsedSeconds(now: last) >= 240)
    }

    @Test("a source that never comes back is still given up on")
    func aDeadSourceStillEndsTheSession() {
        var budget = RefusingSourceReviveBudget()
        let base = DispatchTime.now()
        // Attempts at the cadence a real window produces (a rung plus a reopen), so the window is
        // never mistaken for a new one on the way to the cap.
        var admitted = true
        var last = base
        for offset in stride(from: 0.0, through: 560.0, by: 80.0) {
            last = t(offset, from: base)
            admitted = budget.admit(now: last)
            #expect(admitted, "still inside the budget at \(offset)s")
        }
        let past = budget.admit(now: t(640, from: base))
        #expect(!past, "the budget is capped: a refusing origin is not an excuse to hang forever")
    }

    /// The defect the old gate carried silently. It was never reset, so a session that survived one
    /// window began the next with part of its budget spent and the third with none. On a two hour
    /// film against an origin with this shape, the later windows were given up on for arithmetic
    /// reasons rather than measured ones.
    @Test("each refusal window gets its own budget, so a session that recovers is not penalised")
    func aRecoveredSessionGetsAFullBudgetForTheNextWindow() {
        var budget = RefusingSourceReviveBudget()
        let base = DispatchTime.now()

        // A first window that runs most of its budget, at the cadence a window really has.
        var last = base
        for offset in stride(from: 0.0, through: 480.0, by: 80.0) {
            last = t(offset, from: base)
            let admitted = budget.admit(now: last)
            #expect(admitted)
        }
        #expect(budget.attempts == 7)

        // Six minutes of healthy playback, which is what this origin does between windows.
        let second = t(480 + 360, from: base)
        let reopened = budget.admit(now: second)
        #expect(reopened)
        #expect(budget.attempts == 1, "a new window starts a new count, not a continuation")
        #expect(budget.elapsedSeconds(now: second) == 0)
        // Walked at the same in-window cadence, so this measures the second window's budget rather
        // than quietly opening a third one on an over-long gap.
        let secondWindowStart = 480.0 + 360.0
        for offset in stride(from: 80.0, through: 480.0, by: 80.0) {
            let admitted = budget.admit(now: t(secondWindowStart + offset, from: base))
            #expect(admitted,
                    "the second window must get a full budget, not the remainder of the first")
        }
        #expect(budget.attempts == 7)
    }

    /// The separator has to be longer than any gap that can occur INSIDE a window, which is one
    /// ladder rung (45 s at the widest) plus one reopen (about 34 s).
    @Test("an in-window gap of a rung plus a reopen keeps counting")
    func aLadderRungPlusAReopenIsNotANewWindow() {
        var budget = RefusingSourceReviveBudget()
        let base = DispatchTime.now()
        let a = budget.admit(now: base)
        let b = budget.admit(now: t(79, from: base))
        #expect(a)
        #expect(b)
        #expect(budget.attempts == 2, "45 s of pacing plus a 34 s reopen is one window, not two")
    }

    @Test("a zero budget grants nothing, so an exhausted one can be expressed")
    func zeroBudgetGrantsNothing() {
        var budget = RefusingSourceReviveBudget(budgetSeconds: 0)
        let admitted = budget.admit()
        #expect(!admitted)
    }
}
