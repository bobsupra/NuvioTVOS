import Testing
@testable import AetherEngine

/// AE#286: the pump may only drop to the efficiency QoS while nothing is waiting on it. The local
/// server answers segment requests from a `.userInitiated` work queue and parks that thread in
/// `cache.fetch` on a miss, a dependency dispatch cannot see, so every window where the consumer can
/// be blocked has to keep the pump at the responsive class.
@Suite("Pump QoS relaxation (#286)")
struct PumpQoSRelaxationTests {

    private func mayRelax(started: Bool = true, target: Int, head: Int, lead: Int = 4) -> Bool {
        HLSSegmentProducer.pumpMayRelax(hasStartedRendering: started, targetIndex: target,
                                        epochHighestStored: head, relaxedLeadSegments: lead)
    }

    @Test("A comfortable lead relaxes")
    func comfortableLeadRelaxes() {
        #expect(mayRelax(target: 3, head: 7))
        #expect(mayRelax(target: 0, head: 9))
    }

    @Test("Cold start never relaxes, whichever guard catches it")
    func coldStartStaysResponsive() {
        // Consumer has not fetched anything: the sentinel -1 makes the lead look large.
        #expect(!mayRelax(target: -1, head: 9))
        // Consumer has fetched but AVPlayer is still filling its startup buffer.
        #expect(!mayRelax(started: false, target: 0, head: 9))
    }

    @Test("A consumer sitting on the production head never relaxes")
    func consumerAtHeadStaysResponsive() {
        #expect(!mayRelax(target: 40, head: 40))
        #expect(!mayRelax(target: 40, head: 42))
    }

    @Test("A restarted pump has produced nothing, whatever the cache's high-water says")
    func freshEpochStaysResponsive() {
        // The head passed in is per-epoch. A seek restart at idx=127 with the previous epoch stored
        // through 135 must not read as a lead of 7: this pump has written nothing yet.
        #expect(!mayRelax(target: 128, head: Int.min))
        #expect(!mayRelax(target: 0, head: -1))
    }

    @Test("The lead threshold is content time, not a segment count")
    func leadThresholdIsContentTime() {
        // 16 s of content, floored at 2 segments so a long-segment source cannot relax on one segment.
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 4.0) == 4)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 6.0) == 3)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 2.0) == 8)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 10.0) == 2)
        // Degenerate durations must not produce a zero or negative threshold.
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: 0) == 16)
        #expect(HLSSegmentProducer.relaxedLeadSegments(targetSegmentDurationSeconds: -1) == 16)
    }
}
