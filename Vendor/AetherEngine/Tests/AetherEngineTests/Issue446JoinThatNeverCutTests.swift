import Testing
import Foundation
@testable import AetherEngine

/// AE#446 round 8: a join that never cuts anything has no deadline at all.
///
/// The no-cut watchdog's window is armed by the first cut. `HLSSegmentProducer` stamps that
/// moment when the video gate opens, so every deadline in the live path measures from a first
/// video packet that reached the pump. A source that stops right at the join never delivers one:
/// its video PID goes quiet (or the connection stops carrying anything but padding) while the
/// session sits at `readyToPlay`, and the watchdog `evaluate` bails on its own `lastFinalizeAt ==
/// nil` guard, once per second, for the whole session. Nothing times out, nothing is logged, and
/// the host is never told, which is the sustained-nothing shape reported on AE#509.
///
/// So the window is armed when the live pump starts reading, and the two shapes stay
/// distinguishable: `everProduced` says whether this window follows a cut or a join.
///
/// The second half is a classification rule. Before the first cut there is no evidence for the
/// wedge reading ("the cutter is being fed and cannot cut"), because a cutter that has not cut yet
/// looks identical to one that has nothing to cut. The tight 10 s wedge deadline was measured on a
/// mid-session SSAI pod and would tear down a healthy join with a long GOP, so a join is always
/// judged on the 35 s starvation deadline.
@Suite("A join that never cut anything (AE#446 round 8)")
struct Issue446JoinThatNeverCutTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func makeWatchdog() -> NoCutStallWatchdog {
        NoCutStallWatchdog(videoTimeBaseSeconds: 1.0 / 90_000)
    }

    // MARK: - The classification rule

    @Test("a join is never classified as a wedge, whatever the read rate")
    func joinIsNeverAWedge() {
        // Full read rate, nothing cut, 11 s in: past the wedge timeout and under the starvation one.
        // With a cut behind it this is an SSAI wedge and exits; at a join it is a cutter that has not
        // reached its first keyframe, and the session keeps its join.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 80, videoPtsAdvanceSeconds: 0,
            consecutiveHolds: 0, hasEverProduced: true
        ) == .exitForRetune)
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 80, videoPtsAdvanceSeconds: 0,
            consecutiveHolds: 0, hasEverProduced: false
        ) == .keepReading)
    }

    @Test("a join that has produced nothing exits on the starvation deadline")
    func joinExitsOnStarvationDeadline() {
        // Below it, at any rate, the join is left alone.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 34, readRate: 80, videoPtsAdvanceSeconds: 12,
            consecutiveHolds: 0, hasEverProduced: false
        ) == .keepReading)
        // Past it, the session has shown nothing for 35 s and the host is told.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 36, readRate: 80, videoPtsAdvanceSeconds: 12,
            consecutiveHolds: 0, hasEverProduced: false
        ) == .exitForRetune)
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 36, readRate: 0, videoPtsAdvanceSeconds: -1,
            consecutiveHolds: 0, hasEverProduced: false
        ) == .exitForRetune)
    }

    @Test("a join is not held by the slow-delivery budget")
    func joinIsNotHeldForSlowDelivery() {
        // Advancing video PTS at full rate is what holds a mid-session wedge (#177). At a join it
        // cannot mean the same thing: no segment has been cut, so nothing is being delivered to the
        // consumer while the hold runs.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 36, readRate: 61.3, videoPtsAdvanceSeconds: 9.4,
            consecutiveHolds: 0, hasEverProduced: false
        ) == .exitForRetune)
    }

    @Test("the runway deferral does not apply to a join either")
    func joinIsNotHeldForOutageRunway() {
        // A closed window still feeding its consumer is the one case a dead source is kept open for
        // (round 3). A join has no window to have closed, so the flag cannot arrive true here, and
        // if it ever did the answer would still be the exit.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 36, readRate: 5, videoPtsAdvanceSeconds: -1,
            consecutiveHolds: 0, servingOutageRunway: true, hasEverProduced: false
        ) == .exitForRetune)
    }

    // MARK: - Arming the window at the join

    @Test("a join window is armed without a finalize and carries everProduced = false")
    func joinWindowIsArmed() {
        let w = makeWatchdog()
        w.armForJoin(at: t0)
        #expect(w.evaluate(now: t0.addingTimeInterval(20)) == nil)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit 36s after the join was armed")
            return
        }
        #expect(window.everProduced == false)
        #expect(window.isWedge == false)
        #expect(Int(window.stalledFor) == 36)
    }

    @Test("a packet-carrying join still exits, and is not read as a wedge")
    func busyJoinExitsWithoutWedgeReading() {
        let w = makeWatchdog()
        w.armForJoin(at: t0)
        // 3600 packets in 36 s is 100 pkt/s, well past the wedge threshold.
        for _ in 0..<3600 { w.notePacketRead() }
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit despite a healthy read rate")
            return
        }
        #expect(window.readRate > HLSSegmentProducer.liveWedgeProgressRateThreshold)
        #expect(window.isWedge == false)   // everProduced == false outranks the rate
        #expect(window.everProduced == false)
    }

    @Test("the first cut re-anchors the window and restores the wedge reading")
    func firstFinalizeRestoresNormalJudgement() {
        let w = makeWatchdog()
        w.armForJoin(at: t0)
        w.noteFinalize(at: t0.addingTimeInterval(30))
        // The join's own 36 s is gone with the cut: the window measures from the finalize.
        #expect(w.evaluate(now: t0.addingTimeInterval(36)) == nil)
        for _ in 0..<800 { w.notePacketRead() }
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(41)) else {
            Issue.record("expected the wedge deadline to apply once a cut exists")
            return
        }
        #expect(window.everProduced == true)
        #expect(window.isWedge == true)
        #expect(Int(window.stalledFor) == 11)
    }

    @Test("arming does not overwrite a window a finalize already started")
    func armingNeverMovesAnExistingWindow() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        w.armForJoin(at: t0.addingTimeInterval(20))
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected the finalize's own window to decide")
            return
        }
        #expect(Int(window.stalledFor) == 36)
        #expect(window.everProduced == true)
    }

    @Test("an unarmed watchdog still decides nothing")
    func unarmedStillDecidesNothing() {
        // The arming is the producer's call, not something the watchdog does for itself: a VOD
        // producer never starts one, and nothing here may decide before it is asked to.
        let w = makeWatchdog()
        #expect(w.evaluate(now: t0.addingTimeInterval(600)) == nil)
    }
}
