import Foundation
import Testing
@testable import AetherEngine

/// AetherEngine#122 (rrgomes): a seek issued while the host was PAUSED spontaneously re-engaged
/// playback. Root cause: the normal seek finalize forced `state = .playing` regardless of the
/// transport intent in effect when the seek was issued. That was wrong on its own (the engine
/// reported playing after a paused scrub) and it weaponised the #93 stall-recovery reassert: the
/// seek's own paused landing (`timeControlStatus == .paused`) arriving while `state == .playing`
/// inside an open recovery window is misread as a spurious pause, so the engine calls
/// `host.play()`. Since #129 the finalize reconciles from live `timeControlStatus` through
/// `seekRecoveredState`, but the #122 guarantee is unchanged: the reassert decision keys on the
/// durable transport intent (the host's `playIntent`, which a seek never touches), so a paused
/// scrub lands paused and its paused landing can never be reasserted into playback.
struct Issue122PausedSeekTests {

    @Test("a seek issued while playing lands playing")
    func playingSeekLandsPlaying() {
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: false,
            shouldReassertPausedStatus: false
        ) == .playing)
    }

    @Test("a seek issued while paused lands paused, not forced .playing")
    func pausedSeekLandsPaused() {
        // The paused intent vetoes the reassert (see honestStateVetoesReassert), so the reconcile
        // reaches seekRecoveredState with shouldReassertPausedStatus == false and lands paused.
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: false,
            statusIsPaused: true,
            shouldReassertPausedStatus: false
        ) == .paused)
    }

    @Test("the paused intent vetoes the stall-recovery reassert for a paused seek")
    func honestStateVetoesReassert() {
        let now = Date(timeIntervalSince1970: 100)
        let windowOpen = Date(timeIntervalSince1970: 130)   // recovery window still open
        // A paused scrub reconciles with the durable intent false, so the spurious-pause reassert
        // never fires even with the window open and the seek's paused landing present.
        #expect(!AetherEngine.shouldReassertPlayDuringRecovery(
            statusIsPaused: true, engineStateIsPlaying: false,
            now: now, windowUntil: windowOpen, reasserts: 0))
        // Documents the pre-fix bug: the forced `.playing` (engineStateIsPlaying == true) DID fire
        // the reassert on the seek's own paused landing.
        #expect(AetherEngine.shouldReassertPlayDuringRecovery(
            statusIsPaused: true, engineStateIsPlaying: true,
            now: now, windowUntil: windowOpen, reasserts: 0))
    }

    @Test("a genuine spurious pause during a PLAYING seek still recovers")
    func playingSeekStillRecovers() {
        let now = Date(timeIntervalSince1970: 100)
        let windowOpen = Date(timeIntervalSince1970: 130)
        // A playing seek carries the playing intent, so a real spurious pause inside the window is
        // still re-asserted (no regression to #93 recovery)...
        #expect(AetherEngine.shouldReassertPlayDuringRecovery(
            statusIsPaused: true, engineStateIsPlaying: true,
            now: now, windowUntil: windowOpen, reasserts: 0))
        // ...and the reconcile overrides the spurious paused status back to playing.
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: true,
            shouldReassertPausedStatus: true
        ) == .playing)
    }
}
