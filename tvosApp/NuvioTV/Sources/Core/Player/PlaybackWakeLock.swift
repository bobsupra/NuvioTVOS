import AVFoundation
import UIKit

/// Keeps Apple TV awake for the full player session.
///
/// Custom MPV Metal rendering is not treated as "system video playback" the way
/// `AVPlayerViewController` is, so tvOS can still honor Settings → General →
/// Sleep After (often 15–30 minutes) unless the app explicitly disables the
/// idle timer. Status-based toggling was too fragile: brief non-playing states
/// re-enabled sleep while video continued.
///
/// Hold this for the entire `PlayerView` lifetime (including pause/buffering),
/// and reassert periodically in case the system or another UI path clears it.
@MainActor
enum PlaybackWakeLock {
    private static var holdCount = 0
    private static var reassertTimer: Timer?

    /// Begin preventing sleep. Nested acquires are reference-counted.
    static func acquire() {
        holdCount += 1
        apply(disabled: true)
        activateAudioSession()
        startReassertTimerIfNeeded()
    }

    /// End preventing sleep when the last holder releases.
    static func release() {
        holdCount = max(0, holdCount - 1)
        if holdCount == 0 {
            reassertTimer?.invalidate()
            reassertTimer = nil
            apply(disabled: false)
        }
    }

    /// Force the idle timer off while a hold is active (safe to call often).
    static func reassert() {
        guard holdCount > 0 else { return }
        apply(disabled: true)
    }

    private static func apply(disabled: Bool) {
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }

    private static func startReassertTimerIfNeeded() {
        guard reassertTimer == nil else { return }
        // Sleep After is typically 15+ minutes; reassert well before that so a
        // cleared flag cannot accumulate idle time toward system sleep.
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                reassert()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reassertTimer = timer
    }

    private static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[PlaybackWakeLock] AVAudioSession activate failed: \(error.localizedDescription)")
        }
    }
}
