import Foundation

/// Whether a seek on a demuxer-driven host (software video, audio-only) re-arms the clock at
/// `lastRate` or parks it at 0 (#292).
///
/// The hosts park their demux/feeder loops for the duration of a seek by clearing `isPlaying`, and
/// since #254 the reposition that follows is awaited off the main actor. A second seek issued inside
/// that window therefore reads a flag its predecessor cleared, not the transport's intent, and a
/// scrub during playback landed paused with the clock anchored at rate 0. So the seek that owns the
/// window stashes the intent it captured, and whoever supersedes it inherits that instead.
///
/// The stash is not a snapshot of the whole window: `pause()` and `play()` rewrite it, so an explicit
/// transport call while the reposition is in flight still decides the landing.
enum SeekResumeIntent {
    /// - Parameters:
    ///   - isPlaying: the host's loop flag, authoritative only outside a seek window.
    ///   - seekInFlight: whether another seek already owns the window (and cleared the flag).
    ///   - inFlightIntent: the intent stashed by the seek that owns the window.
    static func resolve(isPlaying: Bool, seekInFlight: Bool, inFlightIntent: Bool) -> Bool {
        seekInFlight ? inFlightIntent : isPlaying
    }
}
