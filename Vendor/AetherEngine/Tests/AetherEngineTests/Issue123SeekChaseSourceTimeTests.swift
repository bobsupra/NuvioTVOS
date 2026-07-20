import Testing
import Foundation
@testable import AetherEngine

/// AetherEngine#123 (rrgomes): under sustained *queued* seek bursts on a heavy 4K Dolby Vision asset the
/// engine clock diverged from the picture by the queued skip amount for 14-33 s, and subtitle cues paced
/// off `sourceTime` rendered 10-30 s ahead of a frozen frame until convergence.
///
/// Root cause (the phase logs ruled out the producer coalescer: 9 cheap restarts across ~107 seeks, the
/// long stretches had zero rebuilds and were pure AVPlayer buffering): `sourceTime` is documented as the
/// on-screen frame, holding the picture across a seek and NOT the scrub target (#49). But the VOD seek
/// finalize stamped `clock.sourceTime = landedSourcePTS` (the target) and the native host's seek
/// completion stamped `renderedTime = avPlayer.currentTime()` (the target the player accepted)
/// unconditionally at landing. Under a queued-burst chase the player is `waitingToPlayAtSpecifiedRate`
/// with the picture frozen behind the target, and the 100 ms periodic observer that would walk
/// `renderedTime`/`sourceTime` back to the frozen frame is silent while buffering, so `sourceTime` parked
/// on the target tens of seconds ahead of the picture for the whole chase.
///
/// The fix gates both stamps on `seekLandingSettlesToTarget(bufferingTowardTarget:)`: settle onto the
/// target only when the landed frame is presented (playing/paused shows the target frame), hold on the
/// rendered frame while buffering. The `$renderedTime` sink then settles `sourceTime` onto the target when
/// playback resumes and the frame is delivered, so cues glued to `sourceTime` stay glued to the picture
/// through the chase and `abs(currentTime - sourceTime)` stays honest as a converging gap.
struct Issue123SeekChaseSourceTimeTests {

    @Test("a landing while presenting the frame settles sourceTime onto the target")
    func presentedLandingSettles() {
        #expect(AetherEngine.seekLandingSettlesToTarget(bufferingTowardTarget: false))
    }

    @Test("a landing still buffering toward the target holds instead of parking sourceTime ahead")
    func bufferingLandingHolds() {
        #expect(!AetherEngine.seekLandingSettlesToTarget(bufferingTowardTarget: true))
    }

    @MainActor
    @Test("finalize holds sourceTime on the frozen frame during a buffering chase, settles once presented")
    func finalizeHoldsThenSettles() throws {
        let engine = try AetherEngine()

        // The picture is frozen at 100 s (last frame the $renderedTime sink published) while the user
        // queues forward skips; the newest optimistic scrub target is 130 s.
        engine.clock.sourceTime = 100.0

        // Winning seek to 130 s finalizes WHILE the player is still buffering toward it (chase): sourceTime
        // must stay on the frozen frame, not jump to 130 (the pre-fix bug that paced cues over a stale frame).
        engine.applySeekFinalizeSourceTime(target: 130.0, bufferingTowardTarget: true)
        #expect(engine.clock.sourceTime == 100.0)

        // Once the frame at the target is presented (buffer filled, playback resumed), the same finalize
        // path settles sourceTime onto the target.
        engine.applySeekFinalizeSourceTime(target: 130.0, bufferingTowardTarget: false)
        #expect(engine.clock.sourceTime == 130.0)
    }

    @MainActor
    @Test("an isolated seek that lands presented settles sourceTime immediately (no #49 regression)")
    func isolatedSeekSettlesImmediately() throws {
        let engine = try AetherEngine()
        engine.clock.sourceTime = 40.0
        // A normal fast seek to a buffered position lands presented: sourceTime settles at once, so subs
        // do not lag the picture on ordinary scrubs.
        engine.applySeekFinalizeSourceTime(target: 88.17, bufferingTowardTarget: false)
        #expect(engine.clock.sourceTime == 88.17)
    }
}
