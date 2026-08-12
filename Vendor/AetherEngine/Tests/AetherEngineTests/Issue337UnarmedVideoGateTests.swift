import Testing
@testable import AetherEngine

/// #337: both software feed loops gate video on `renderer.isReadyForMoreMediaData`, and the
/// renderer only drains while the synchronizer clock runs. Parking there with an unarmed clock
/// is therefore terminal, not slow: the packets that would arm the clock sit downstream of the
/// park. Reported as `state=.playing` with `currentTime` pinned at 0 forever after a host picked
/// an audio track whose first packet lies past the renderer's fill point.
@Suite("Unarmed video gate (#337 clock arming deadlock on the SW path)")
struct Issue337UnarmedVideoGateTests {

    @Test("the reported shape: playing, renderer full, clock unarmed, no audio left to arm it")
    func reportedDeadlock() {
        #expect(SWClockAnchorPolicy.shouldArmFromParkedVideo(
            clockArmed: false,
            isPlaying: true,
            rendererReadyForMoreData: false,
            audioArmingStillPossible: false))
    }

    @Test("an armed clock never re-arms from the gate (seekClock is not idempotent)")
    func armedClockIsLeftAlone() {
        #expect(!SWClockAnchorPolicy.shouldArmFromParkedVideo(
            clockArmed: true,
            isPlaying: true,
            rendererReadyForMoreData: false,
            audioArmingStillPossible: false))
    }

    @Test("a paused session keeps its cold clock: play() is what starts it, not the gate")
    func pausedSessionIsNotArmed() {
        #expect(!SWClockAnchorPolicy.shouldArmFromParkedVideo(
            clockArmed: false,
            isPlaying: false,
            rendererReadyForMoreData: false,
            audioArmingStillPossible: false))
    }

    @Test("a draining renderer is not a deadlock: the loop is between packets, not parked")
    func drainingRendererIsNotParked() {
        #expect(!SWClockAnchorPolicy.shouldArmFromParkedVideo(
            clockArmed: false,
            isPlaying: true,
            rendererReadyForMoreData: true,
            audioArmingStillPossible: false))
    }

    @Test("the feeder loop waits while its look-ahead pump can still deliver a first buffer")
    func pumpStillHasBudget() {
        #expect(!SWClockAnchorPolicy.shouldArmFromParkedVideo(
            clockArmed: false,
            isPlaying: true,
            rendererReadyForMoreData: false,
            audioArmingStillPossible: true))
    }

    @Test("a spent pre-arm budget makes the feeder's park terminal too")
    func pumpBudgetSpent() {
        let stillPossible = AudioLookaheadPolicy.decide(
            clockArmed: false,
            preArmPacketsFed: AudioLookaheadPolicy.preArmPacketBudget,
            lastFedAudioPTS: .nan,
            clockSeconds: 0) == .feed
        #expect(!stillPossible)
        #expect(SWClockAnchorPolicy.shouldArmFromParkedVideo(
            clockArmed: false,
            isPlaying: true,
            rendererReadyForMoreData: false,
            audioArmingStillPossible: stillPossible))
    }

    @Test("the gate's video anchor keeps a zero-based load anchor, so the queued frames still present")
    func gateAnchorKeepsTheLoadAnchor() {
        // The packet held at the gate is the renderer queue's depth ahead of the frame on screen
        // (a few hundred ms), which is inside the mid-stream-join tolerance, so nothing re-anchors.
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 0.5)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }
}
