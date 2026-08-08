import Foundation
import Testing
@testable import AetherEngine

/// #292: a scrub while playing left the software path paused (`[AudioOutput] seekClock rate=0.0`,
/// demux/feeder loops parked) while the engine reported `.playing`; pause+play healed it.
///
/// `SoftwarePlaybackHost.seek` and `AudioPlaybackHost.seek` decide whether to re-arm the clock at
/// `lastRate` or at 0 from `isPlaying`, a flag they clear themselves for the duration of the
/// reposition. Since #254 that reposition is awaited off the main actor, so a second seek can enter
/// the function while the first is suspended, and it then reads its predecessor's cleared flag as
/// "was paused". The reporter's log is exactly that interleave:
///
///     seek#1 programmatic began target=2432.97
///     seek#1 programmatic superseded target=2432.97
///     seek#2 programmatic began target=2432.97
///     [AudioOutput] seekClock to=2432.973 rate=0.0     <-- seek#2 took the paused branch
///
/// The intent therefore has to survive the supersede, and an explicit transport call inside the
/// window has to be able to overwrite it.
@Suite("#292 superseded seek resume intent")
struct Issue292SupersededSeekResumeTests {

    @Test("outside an in-flight window the live transport flag decides")
    func idleWindowReadsTheLiveFlag() {
        #expect(SeekResumeIntent.resolve(isPlaying: true, seekInFlight: false, inFlightIntent: false))
        #expect(SeekResumeIntent.resolve(isPlaying: false, seekInFlight: false, inFlightIntent: true) == false)
    }

    @Test("a seek that supersedes an in-flight seek inherits its intent, not the flag it cleared")
    func supersedingSeekInheritsTheIntent() {
        // The regression. Without this the session lands at rate 0 with the loops parked.
        #expect(SeekResumeIntent.resolve(isPlaying: false, seekInFlight: true, inFlightIntent: true))
    }

    @Test("a paused scrub stays paused across a supersede")
    func pausedScrubStaysPaused() {
        // #122's guarantee on the SW path: a scrub started while paused must not start playing just
        // because a second seek collapsed onto it.
        #expect(SeekResumeIntent.resolve(isPlaying: false, seekInFlight: true, inFlightIntent: false) == false)
    }

    /// The stash is what `pause()` / `play()` rewrite while a reposition is in flight, so an explicit
    /// transport call inside the window still decides the landing. That wiring is the hosts' job; what
    /// this pins is that the stash, once handed over, is the only thing the window consults.
    @Test("inside the window the stash decides on its own, whatever the cleared flag says")
    func windowConsultsOnlyTheStash() {
        #expect(SeekResumeIntent.resolve(isPlaying: false, seekInFlight: true, inFlightIntent: true))
        #expect(SeekResumeIntent.resolve(isPlaying: true, seekInFlight: true, inFlightIntent: false) == false)
    }
}
