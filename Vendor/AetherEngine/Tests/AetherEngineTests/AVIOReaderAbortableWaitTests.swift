import Testing
import Foundation
@testable import AetherEngine

/// Issue #27 (Sodalite): the still-extraction seekable read path parked in a flat
/// 35s semaphore wait (syncRequest) with no way to abort on supersede/close, so a
/// stalled chunk read froze the FrameExtractor's serial decode queue and pinned the
/// scrub-preview image. The abortable wait must bail promptly when a read is
/// superseded (deadline/closed), bounded by a small budget instead of 35s.
struct AVIOReaderAbortableWaitTests {

    @Test("awaitSignal returns .signaled when the semaphore fires")
    func signaled() {
        let sem = DispatchSemaphore(value: 0)
        sem.signal()
        let outcome = AVIOReader.awaitSignal(
            sem, budget: 5, pollInterval: 0.05, shouldAbort: { false })
        #expect(outcome == .signaled)
    }

    @Test("awaitSignal returns .timedOut at the budget, not a 35s park")
    func timedOut() {
        let sem = DispatchSemaphore(value: 0)   // never signaled
        let start = Date()
        let outcome = AVIOReader.awaitSignal(
            sem, budget: 0.2, pollInterval: 0.05, shouldAbort: { false })
        let elapsed = Date().timeIntervalSince(start)
        #expect(outcome == .timedOut)
        #expect(elapsed < 2.0, "must be bounded by the budget, was \(elapsed)s")
    }

    @Test("awaitSignal aborts promptly when shouldAbort flips, well before the budget")
    func abortsPromptly() {
        let sem = DispatchSemaphore(value: 0)   // never signaled
        let start = Date()
        let outcome = AVIOReader.awaitSignal(
            sem, budget: 30, pollInterval: 0.05, shouldAbort: { true })
        let elapsed = Date().timeIntervalSince(start)
        #expect(outcome == .aborted)
        #expect(elapsed < 1.0, "must not ride the 30s budget, was \(elapsed)s")
    }
}
