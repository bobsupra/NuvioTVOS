import Testing
import Foundation
@testable import AetherEngine

/// Sodalite#104: `isAtLiveEdge` flips twice per segment in a perfectly healthy live session.
///
/// The edge is a STEP function and the playhead is CONTINUOUS. `noteEdge` moves once per segment
/// cut, by a whole segment duration; the playhead advances smoothly between those moves. So
/// `behindLiveSeconds`, which is their difference, sawtooths from one segment duration down to zero
/// and back, in every live session, with nobody touching anything.
///
/// A tolerance written as a CONSTANT cannot answer a question whose natural amplitude is the segment
/// duration. At 2.0 s against 4 s segments it is under the sawtooth's peak, so the flag toggles:
/// measured on the harness, an untouched 45 s session flipped it 17 times, `behind` running
/// 3.10 -> 2.10 -> 1.10 -> 0.00 and back for the whole run. The host draws its LIVE badge and its
/// "Return to Live" chip from that flag, so the badge greys out on its own and the chip enters the
/// focus order while the viewer is sitting still, which is what was reported. It is also why the
/// chip does not converge: pressing it lands at the edge, and the next cut immediately puts a whole
/// segment between the two again.
///
/// The tolerance is the last observed edge STEP plus the old constant as slack. Right after a cut,
/// the closest a client can be to the new edge is one segment behind it, because the segment that
/// just moved the edge has not been played yet; being that close IS the live edge, and no client can
/// do better without stalling.
///
/// Round 2 note: these pin `isWithinEdgeTolerance`, the instantaneous test. What a host draws is
/// `isAtEdge`, the same test with hysteresis, and it has its own suite below.
@Suite("The live edge tolerance follows the cadence (Sodalite#104)")
struct Sodalite104LiveEdgeCadenceTests {

    /// The measured shape: 4 s segments, ~1 s of playback per tick.
    private func healthySession() -> LiveWindow {
        var w = LiveWindow(windowSeconds: 60)
        w.noteEdge(4)
        w.notePlayhead(4)
        return w   // no TARGETDURATION: these pin the observed-step fallback
    }

    @Test("a healthy session never leaves the edge between two cuts")
    func healthySawtoothStaysAtEdge() {
        var w = healthySession()
        // Two cuts, and the playhead walking the whole way across each of them. This is the run the
        // harness printed: behind peaks at one segment duration right after the cut.
        for cut in 1...2 {
            w.noteEdge(Double(4 + cut * 4))
            for step in 0...4 {
                w.notePlayhead(Double(4 + (cut - 1) * 4) + Double(step))
                #expect(w.isWithinEdgeTolerance,
                        "cut \(cut), \(String(format: "%.1f", w.behindLiveSeconds))s behind")
            }
        }
    }

    @Test("the peak of the sawtooth is exactly one segment, and it used to fail")
    func sawtoothPeakIsOneSegment() {
        var w = healthySession()
        w.noteEdge(8)          // the cut
        w.notePlayhead(4)      // the client has not played into the new segment yet
        #expect(w.behindLiveSeconds == 4)
        #expect(w.behindLiveSeconds > LiveWindow.edgeTolerance)  // the old constant said "not at edge"
        #expect(w.isWithinEdgeTolerance)
    }

    @Test("a viewer who actually rewound is not at the edge")
    func realRewindIsNotAtEdge() {
        var w = healthySession()
        w.noteEdge(8)
        w.notePlayhead(-22)    // 30 s back on the session axis
        #expect(w.behindLiveSeconds == 30)
        #expect(!w.isWithinEdgeTolerance)
    }

    @Test("one segment plus the slack is the boundary")
    func boundaryIsStepPlusSlack() {
        var w = healthySession()
        w.noteEdge(8)
        w.notePlayhead(8 - (4 + LiveWindow.edgeTolerance))
        #expect(w.isWithinEdgeTolerance)                       // exactly at the bound
        w.notePlayhead(8 - (4 + LiveWindow.edgeTolerance) - 0.1)
        #expect(!w.isWithinEdgeTolerance)                      // past it
    }

    @Test("before the first cut the old constant still decides")
    func withoutAStepTheConstantDecides() {
        var w = LiveWindow(windowSeconds: 60)
        w.noteEdge(10)          // the first sample is not a step, it is where the session starts
        w.notePlayhead(8.5)
        #expect(w.isWithinEdgeTolerance)
        w.notePlayhead(7.0)     // 3 s behind, past the constant, and nothing has cut yet
        #expect(!w.isWithinEdgeTolerance)
    }

    @Test("a declared cadence outranks a bursty delivery")
    func targetDurationOutranksTheObservedStep() {
        // The device case: a tuner or transcode route delivers in bursts, so the edge jumps by far
        // more than a segment. Judging by the observed jump made the tolerance as large as the burst,
        // and a viewer who had deliberately rewound was told they were at the live edge. The playlist
        // says how long a segment is; the delivery does not.
        var w = LiveWindow(windowSeconds: 120)
        w.noteTargetDuration(6)
        w.noteEdge(10)
        w.noteEdge(40)          // a 30 s burst
        #expect(w.lastEdgeStepSeconds == 30)
        w.notePlayhead(28)      // 12 s behind: two segments, and a deliberate rewind
        #expect(!w.isWithinEdgeTolerance)
        w.notePlayhead(35)      // 5 s behind: inside the declared segment
        #expect(w.isWithinEdgeTolerance)
    }

    @Test("without a declared cadence the observed step still decides")
    func withoutTargetDurationTheStepDecides() {
        // Remote HLS live and the software live path serve no playlist of ours, so nothing declares
        // a TARGETDURATION there and the observed advance is all there is.
        var w = healthySession()
        w.noteEdge(34)
        w.notePlayhead(14)
        #expect(w.isWithinEdgeTolerance)
        w.noteEdge(38)
        w.notePlayhead(14)
        #expect(!w.isWithinEdgeTolerance)
    }

    @Test("a non-advancing edge sample leaves the step alone")
    func aRepeatedEdgeSampleIsNotAStep() {
        var w = healthySession()
        w.noteEdge(8)
        w.noteEdge(8)           // the same edge published again on the next tick
        w.noteEdge(6)           // and a stale one, which the running maximum ignores
        w.notePlayhead(4)
        #expect(w.behindLiveSeconds == 4)
        #expect(w.isWithinEdgeTolerance)     // still judged against the 4 s step, not against a zeroed one
    }
}

/// Sodalite#104 round 2: the verdict a host draws is not a bare threshold, and on a path that
/// declares no cadence it measures its own.
///
/// Both defects were measured on the harness against a loopback origin running 6 s ahead of the wall
/// clock, driven through the software live path:
///
///   - After a return-to-live the session's distance sawtoothed 1.38 to 2.63 s while the tolerance
///     moved between 2.03 and 3.32 s, because `lastEdgeStep` on a frontier sampled once per publish
///     is however much media arrived since the last tick. The verdict flipped inside the run with
///     the remote untouched, which puts the chip back in the button row a second after it was
///     pressed: that is the "Return to Live lights, then falls behind again" report.
///   - A session that joined the origin's 6 s standing lead played 4.92 to 6.19 s behind the frontier
///     for all forty ticks of an untouched run. That verdict is right, and it stays right here: the
///     viewer really is six seconds behind what the box already holds, so the chip belongs in the
///     row. What must not happen is the tolerance LEARNING those six seconds, and the sample gate is
///     what stops it.
@Suite("The live edge verdict, with hysteresis and a measured cadence (Sodalite#104 round 2)")
struct Sodalite104LiveEdgeVerdictTests {

    /// The software live shape: a read frontier, no declared cadence, and a session keeping up.
    private func trackingSession(distance: Double) -> LiveWindow {
        var w = LiveWindow(windowSeconds: 120)
        w.noteEdge(100)
        w.notePlayhead(100 - distance)
        return w
    }

    @Test("entering the edge is the plain test")
    func enteringIsThePlainTest() {
        var w = trackingSession(distance: 1.0)
        w.settleEdgeVerdict(tracking: false)
        #expect(w.isAtEdge)

        var behind = trackingSession(distance: 6.0)
        behind.settleEdgeVerdict(tracking: false)
        #expect(!behind.isAtEdge)
    }

    @Test("leaving the edge costs one more slack than entering it")
    func leavingCostsTheExitSlack() {
        var w = trackingSession(distance: 1.0)
        w.settleEdgeVerdict(tracking: false)
        #expect(w.isAtEdge)
        // The measured sawtooth: past the tolerance, inside the exit slack, and the verdict holds.
        w.notePlayhead(100 - 2.6)
        w.settleEdgeVerdict(tracking: false)
        #expect(w.behindLiveSeconds > w.edgeToleranceSeconds)
        #expect(w.isAtEdge)
        // Past the exit slack it gives the edge up, and then needs the plain test to come back.
        w.notePlayhead(100 - (w.edgeToleranceSeconds + LiveWindow.edgeExitSlack + 0.1))
        w.settleEdgeVerdict(tracking: false)
        #expect(!w.isAtEdge)
        w.notePlayhead(100 - 2.6)
        w.settleEdgeVerdict(tracking: false)
        #expect(!w.isAtEdge)
        w.notePlayhead(100 - 1.0)
        w.settleEdgeVerdict(tracking: false)
        #expect(w.isAtEdge)
    }

    /// The run that produced the flap, ten ticks of it, asked of the verdict rather than of the test.
    @Test("the measured sawtooth does not flip the verdict once")
    func theMeasuredSawtoothHoldsTheVerdict() {
        let measured = [1.38, 1.38, 1.77, 2.17, 2.24, 2.52, 1.51, 1.93, 2.20, 2.52, 1.52, 1.88, 2.19]
        var w = trackingSession(distance: measured[0])
        w.settleEdgeVerdict(tracking: true)
        #expect(w.isAtEdge)
        var flips = 0
        for distance in measured.dropFirst() {
            let before = w.isAtEdge
            w.notePlayhead(100 - distance)
            w.settleEdgeVerdict(tracking: true)
            if w.isAtEdge != before { flips += 1 }
        }
        #expect(flips == 0)
    }

    @Test("a session that keeps up teaches the tolerance what this source costs")
    func trackingTeachesTheCadence() {
        var w = trackingSession(distance: 1.0)
        #expect(w.trackingCadenceSeconds == nil)      // nothing measured yet
        for distance in [1.0, 1.8, 2.4, 2.6, 1.4, 2.5] {
            w.notePlayhead(100 - distance)
            w.settleEdgeVerdict(tracking: true)
        }
        // The robust maximum: the second largest sample, so one outsized tick cannot set it.
        #expect(w.trackingCadenceSeconds == 2.5)
        #expect(w.edgeToleranceSeconds == LiveWindow.edgeTolerance + 2.5)
    }

    /// The round 4 trap from the other side: a rewind must not teach the tolerance patience. It
    /// cannot, because the samples are only taken while the verdict already says at-edge.
    @Test("a rewound session contributes no samples at all")
    func aRewindTeachesNothing() {
        var w = trackingSession(distance: 1.0)
        for _ in 0..<6 {
            w.settleEdgeVerdict(tracking: true)
        }
        let learned = w.trackingCadenceSeconds
        #expect(learned != nil)
        // Thirty seconds back, playing forward, tick after tick: the distance is stable and large.
        w.notePlayhead(70)
        for _ in 0..<20 {
            w.settleEdgeVerdict(tracking: true)
            #expect(!w.isAtEdge)
        }
        #expect(w.trackingCadenceSeconds == learned)
    }

    @Test("a declared cadence still outranks a measured one")
    func targetDurationOutranksTheMeasuredCadence() {
        var w = trackingSession(distance: 1.0)
        w.noteTargetDuration(6)
        for distance in [1.0, 1.2, 1.4, 1.6, 1.8] {
            w.notePlayhead(100 - distance)
            w.settleEdgeVerdict(tracking: true)
        }
        #expect(w.trackingCadenceSeconds != nil)
        #expect(w.edgeToleranceSeconds == LiveWindow.edgeTolerance + 6)
    }

    /// The join the harness measured: six seconds behind the frontier from the first tick, which is
    /// the origin's standing lead and not a cushion this session chose. It stays BEHIND, so the chip
    /// stays offered, and it never learns a six second patience.
    @Test("a session that joined a standing backlog stays behind live")
    func aBackloggedJoinStaysBehind() {
        var w = trackingSession(distance: 6.0)
        for distance in [5.87, 6.19, 5.19, 5.64, 5.87, 6.15, 5.16, 5.34, 5.62, 5.89] {
            w.notePlayhead(100 - distance)
            w.settleEdgeVerdict(tracking: true)
            #expect(!w.isAtEdge)
        }
        #expect(w.trackingCadenceSeconds == nil)
    }
}
