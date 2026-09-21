import Testing
@testable import AetherEngine

/// AE#519: the software VOD read-ahead producer may only sit in the efficiency class while the
/// consumer provably cannot reach it. The demux consumer blocks on an `NSCondition` whenever the
/// store runs dry and a condition donates no priority, so a permanently demoted producer is an
/// inversion dispatch cannot see, and one that measurably fails to drain the link it is given.
@Suite("Read-ahead producer QoS (#519)")
struct Issue519ReadAheadQoSTests {

    /// The shipping forward window: 10 segments of 4 s, so 20 s to relax and 10 s to go responsive.
    private let window: Double = 40

    private func mayRelax(relaxed: Bool = false, waiting: Int = 0, reservoir: Double?,
                          forward: Double? = nil) -> Bool {
        SoftwarePacketReadAhead.producerMayRelax(
            currentlyRelaxed: relaxed, consumersWaiting: waiting, reservoirSeconds: reservoir,
            forwardSeconds: forward ?? window)
    }

    @Test("A reserve at half the window relaxes")
    func deepReserveRelaxes() {
        #expect(mayRelax(reservoir: 20))
        #expect(mayRelax(reservoir: 39.5))
    }

    @Test("A consumer parked in read() is being waited on, whatever the reserve says")
    func waitingConsumerNeverRelaxes() {
        #expect(!mayRelax(waiting: 1, reservoir: 39.5))
        #expect(!mayRelax(relaxed: true, waiting: 1, reservoir: 39.5))
    }

    @Test("A reserve that cannot be expressed in seconds is not a deep one")
    func unknownReserveNeverRelaxes() {
        // No stored video timestamp yet: the state a cold start and a seek landing are both in.
        #expect(!mayRelax(reservoir: nil))
        #expect(!mayRelax(relaxed: true, reservoir: nil))
        #expect(!mayRelax(reservoir: .nan))
        #expect(!mayRelax(reservoir: .infinity))
    }

    @Test("Cold start stays responsive")
    func coldStartStaysResponsive() {
        #expect(!mayRelax(reservoir: 0))
        #expect(!mayRelax(reservoir: 19.9))
    }

    @Test("The band holds the class, so a source sitting on the depth does not retune per packet")
    func hysteresisBandHoldsTheClass() {
        // 15 s is below the relax depth and above the boost depth: whoever is there, stays.
        #expect(!mayRelax(relaxed: false, reservoir: 15))
        #expect(mayRelax(relaxed: true, reservoir: 15))
        // The edges themselves are the only places the answer changes.
        #expect(mayRelax(relaxed: false, reservoir: 20))
        #expect(!mayRelax(relaxed: true, reservoir: 9.9))
    }

    @Test("The depths are fractions of the window, with an absolute floor under a tiny one")
    func depthsTrackTheWindow() {
        #expect(SoftwarePacketReadAhead.relaxReservoirSeconds(forwardSeconds: 40) == 20)
        #expect(SoftwarePacketReadAhead.boostReservoirSeconds(forwardSeconds: 40) == 10)
        // The clamp floors the window at 4 segments, but the type takes any value.
        #expect(SoftwarePacketReadAhead.relaxReservoirSeconds(forwardSeconds: 16) == 8)
        #expect(SoftwarePacketReadAhead.boostReservoirSeconds(forwardSeconds: 16) == 4)
        #expect(SoftwarePacketReadAhead.relaxReservoirSeconds(forwardSeconds: 2) == 2)
        #expect(SoftwarePacketReadAhead.boostReservoirSeconds(forwardSeconds: 2) == 1)
    }

    @Test("A degenerate window never relaxes rather than relaxing always")
    func degenerateWindowNeverRelaxes() {
        for forward in [0.0, -1.0, Double.nan, Double.infinity] {
            #expect(!mayRelax(reservoir: 1_000_000, forward: forward))
            #expect(!mayRelax(relaxed: true, reservoir: 1_000_000, forward: forward))
        }
    }
}
