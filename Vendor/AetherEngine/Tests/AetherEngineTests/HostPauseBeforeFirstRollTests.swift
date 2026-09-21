import Testing
@testable import AetherEngine

/// AE#440 follow-up: a pause the host ASKED FOR, on a session whose rate never rolled.
///
/// AE#440 held the pre-roll `.paused` reading back because AVPlayer delivers the mount's outgoing
/// status AFTER the autostart has written `.playing`, which published a millisecond of `.paused` on
/// every native start. That reading is nobody's intent. A host that pauses a session before its rate
/// has rolled produces the same status with the opposite meaning, and the roll gate swallowed that
/// one too, which is the shape a background return has: the reload autostarts, the host pauses on the
/// resumed frame, and AVPlayer's pre-pause `.waitingToPlayAtSpecifiedRate` lands after the pause and
/// re-declares `.playing`. The `.paused` that follows was dropped, so the session stood at
/// `state == .playing` with `hasTransportRolled == false` on a transport that was not moving, which
/// `PlaybackPhase.derive` reports as `.loading` for as long as the session lasts. Nothing rolls a
/// paused transport, so nothing ever corrected it.
///
/// The durable #122 transport intent separates the two readings: a pause the engine was asked for has
/// already cleared it, the mount's outgoing status has not.
@Suite("AE#440 follow-up: a host pause that lands before the first roll")
struct HostPauseBeforeFirstRollTests {

    /// The ordinary mid-session pause, unchanged by any of this.
    @Test("a rolled session publishes its pause")
    func rolledSessionPublishesPause() {
        #expect(AetherEngine.publishesTransportPause(hasTransportRolled: true,
                                                     transportIntentIsPlaying: false))
    }

    /// AE#440's own case, which must stay held back: the session still intends to play, so the
    /// `.paused` in hand is the status the item was mounted with.
    @Test("the pre-roll status of an autostart is not a pause")
    func preRollStatusOfAutostartIsNotAPause() {
        #expect(!AetherEngine.publishesTransportPause(hasTransportRolled: false,
                                                      transportIntentIsPlaying: true))
    }

    /// The regression: the engine was asked to pause, and the rate never rolled to earn the gate.
    @Test("a host pause before the first roll is a pause")
    func hostPauseBeforeFirstRollIsAPause() {
        #expect(AetherEngine.publishesTransportPause(hasTransportRolled: false,
                                                     transportIntentIsPlaying: false))
    }

    /// A session that rolled once and is playing: a `.paused` reading is a real pause (AVKit bar,
    /// Control Center, hardware button), which is what this sink exists to reconcile.
    @Test("a rolled playing session still reconciles an external pause")
    func rolledPlayingSessionReconcilesExternalPause() {
        #expect(AetherEngine.publishesTransportPause(hasTransportRolled: true,
                                                     transportIntentIsPlaying: true))
    }

    /// The wedge in phase terms, both ends of it: what the swallowed reading left behind is exactly
    /// what a host draws a spinner over, and the published pause is what settles it onto the frame.
    @Test("the swallowed pause strands the phase on loading, the published one settles it")
    func swallowedPauseStrandsPhaseOnLoading() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .loading)
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .loading)
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false,
                                     stall: .flowing, transportHasRolled: false) == .paused)
    }
}
