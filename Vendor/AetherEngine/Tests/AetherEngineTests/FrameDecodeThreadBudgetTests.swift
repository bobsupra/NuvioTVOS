import Testing
@testable import AetherEngine

/// Issue #27 (Sodalite): FrameDecodeContext requested thread_count = activeProcessorCount,
/// so the disposable scrub-thumbnail decoder grabbed all 6 A12 cores at the same QoS as the
/// real-time software playback decode (and, with subs on, a third context), starving the
/// preview. The still-extraction thumbnail has no clock deadline, so its thread budget must be
/// capped well below the core count to leave headroom for playback.
struct FrameDecodeThreadBudgetTests {

    @Test("still-extraction thread count is capped below the core count")
    func capsThreads() {
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 8) <= 2)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 6) <= 2)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 6) < 6)
    }

    @Test("still-extraction thread count stays at least 1 on constrained hosts")
    func atLeastOne() {
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 1) >= 1)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 0) >= 1)
    }
}
