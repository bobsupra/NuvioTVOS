#if DEBUG
import Foundation

// Test-only hooks for the aetherctl `--host-calls stallclock` drill (AE#549). The trigger in the field
// is an AVAudioSession interruption, which does not exist on macOS, so the CLI reproduces its OUTCOME
// instead: a master clock stopped by something other than the host, which is the state `play()` had no
// door out of. DEBUG-gated: absent from Release builds, so this is never shipped API.
extension AetherEngine {

    /// Stop the renderer path's master clock without going through `pause()`, the way an interrupted
    /// audio session does. False when the active backend has no such clock (native path, or a session
    /// whose clock has not armed yet).
    @MainActor
    public func stallRendererClockForTesting() -> Bool {
        if let softwareHost { return softwareHost.stallClockForTesting() }
        if let audioHost { return audioHost.stallClockForTesting() }
        return false
    }

    /// The renderer path's synchronizer rate, nil when the active backend has no synchronizer.
    @MainActor
    public var rendererClockRateForTesting: Float? {
        softwareHost?.clockRateForTesting ?? audioHost?.clockRateForTesting
    }
}
#endif
