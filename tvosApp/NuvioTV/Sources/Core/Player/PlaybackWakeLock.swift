import AVFoundation
import UIKit

/// `AVAudioSession` category and activation changes can block while the system
/// reconfigures audio routes. Keep them off the main actor so a preview or
/// player start never stalls SwiftUI focus and animation work.
enum PlaybackAudioSession {
    private static let queue = DispatchQueue(label: "tv.nuvio.audio-session")

    static func activateMoviePlayback() {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                #if os(tvOS)
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
                #else
                try session.setCategory(.playback, mode: .moviePlayback)
                #endif
                try session.setActive(true)
            } catch {
                print("[PlaybackAudioSession] activate failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Whether the player session should block Apple TV screensaver / Sleep After.
///
/// Custom MPV Metal rendering is not treated as system video playback, so tvOS
/// honors Settings → General → Sleep After unless the idle timer is disabled.
/// Hold the lock while video is loading or playing; drop it on pause, end, and
/// error so screensaver and sleep can run. Source switches keep the lock even
/// if status flickers, because those gaps are not user-idle.
enum PlaybackIdlePolicy {
    static func preventsIdle(
        status: PlayerStatus,
        isSwitchingSource: Bool = false,
        isReloadingStream: Bool = false,
        isAdvancingEpisode: Bool = false
    ) -> Bool {
        if isSwitchingSource || isReloadingStream || isAdvancingEpisode {
            return true
        }
        switch status {
        case .playing, .buffering, .idle:
            return true
        case .paused, .ended, .error:
            return false
        }
    }
}

/// Keeps Apple TV awake while playback is actually in progress.
///
/// Acquire for the playback session (including Picture in Picture), then
/// call `setPreventsIdle` as status changes so a paused session can sleep.
/// Reassert periodically in case the system or another UI path clears the flag
/// while video is still playing.
@MainActor
enum PlaybackWakeLock {
    private static var owners = Set<UUID>()
    private static var preventsIdle = true
    private static var reassertTimer: Timer?

    /// Reappearing views for the same session reuse its existing hold.
    /// AetherEngine owns its own serialized `AVAudioSession` setup and post-play-gate
    /// activation, so Aether sessions pass `activatesAudioSession: false` to avoid racing it.
    static func acquire(ownerID: UUID, activatesAudioSession: Bool = true) {
        let wasEmpty = owners.isEmpty
        owners.insert(ownerID)
        if wasEmpty {
            preventsIdle = true
        }
        apply()
        if activatesAudioSession {
            activateAudioSession()
        }
        startReassertTimerIfNeeded()
    }

    /// End preventing sleep when the last holder releases.
    static func release(ownerID: UUID) {
        owners.remove(ownerID)
        if owners.isEmpty {
            reassertTimer?.invalidate()
            reassertTimer = nil
            preventsIdle = true
            apply()
        }
    }

    /// Update whether the current hold should block screensaver / sleep.
    static func setPreventsIdle(_ value: Bool) {
        preventsIdle = value
        guard !owners.isEmpty else { return }
        apply()
    }

    /// Re-apply the current idle policy while a hold is active (safe to call often).
    static func reassert() {
        guard !owners.isEmpty else { return }
        apply()
    }

    private static func apply() {
        let disabled = !owners.isEmpty && preventsIdle
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
        PlaybackAudioSession.activateMoviePlayback()
    }
}
