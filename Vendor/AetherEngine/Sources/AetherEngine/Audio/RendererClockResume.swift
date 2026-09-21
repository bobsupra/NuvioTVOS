import Foundation

/// AE#549: what a renderer path's `play()` does with a clock that the host itself did not stop.
///
/// Both renderer hosts resume their synchronizer only inside `if pausedByHost`. That is right for the
/// pause they issued, and it leaves no door at all for a clock the SYSTEM stopped. Field log
/// (AetherPlayer 0.18.1, iPhone 17 Pro, iOS 27): an AirPlay route switch arrived as an audio session
/// interruption, the engine's auto-resume ran and said so (`autoResume=true`), and the clock stood at
/// 10.81 s for the remaining two minutes of the session with 3.79 s of decoded video in hand and
/// nothing consuming it.
///
/// The two other states that stop this clock without a host pause are excluded rather than restarted,
/// because each owns a resume of its own and knows something this decision does not: a rebuffer
/// restarts the clock when its lead is back, and an end-of-media park (AE#374) is the source running
/// out, which `AetherEngine.play()` answers with a rewind.
///
/// An unarmed clock is left alone for the #107 reason: a rate change on a synchronizer that has no
/// media at its time wedges the delayed-rate-change machinery permanently, and the arming `seekClock`
/// on the first decoded sample picks the rate up by itself.
enum RendererClockResume {

    enum Action: Equatable {
        /// The host paused this clock, so its own rate resume applies.
        case resumeHostPause
        /// Nobody on this side stopped this clock and it is not running: re-anchor it where it stands.
        case restartStalledClock
        /// Leave it: it runs, it is not armed yet, or it belongs to a rebuffer or an ended source.
        case none
    }

    static func onPlay(
        hostPaused: Bool,
        clockArmed: Bool,
        synchronizerRate: Float,
        rebuffering: Bool,
        parkedAtEndOfMedia: Bool
    ) -> Action {
        if hostPaused { return .resumeHostPause }
        guard clockArmed, !rebuffering, !parkedAtEndOfMedia, synchronizerRate == 0 else { return .none }
        return .restartStalledClock
    }
}
