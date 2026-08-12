import Foundation
import UIKit
import Combine

/// Owns backend selection, generation-safe loads, and one-way Aether → MPV handoff.
@MainActor
final class PlaybackSessionCoordinator: ObservableObject {
    @Published private(set) var activeBackend: PlayerBackendKind = .aether
    @Published private(set) var statusToast: String?
    @Published private(set) var lastPolicyReason: String = ""

    let aetherController = AetherPlaybackController()
    let mpvController = MPVPlayerViewController()

    /// Generation token for the in-flight load. Completions for older gens are ignored.
    private(set) var loadGeneration: UInt64 = 0
    private var allowAutomaticFallback = true
    private var didFallbackForCurrentURL = false
    private var currentURLString: String?
    private var lastRequest: PlaybackLoadRequest?
    private var isHandoffInProgress = false
    private var handoffTargetSeconds: Double?
    private var userStopped = false
    /// Suppress progress saves / watched marks during backend handoff.
    private(set) var isProgressSaveSuspended = false

    var onHandoffToast: ((String) -> Void)?

    var activeEngine: PlaybackEngineControlling {
        switch activeBackend {
        case .aether: return aetherController
        case .mpv: return mpvController
        }
    }

    init() {
        aetherController.onTerminalError = { [weak self] message in
            self?.handleAetherTerminalError(message)
        }
    }

    // MARK: - Public API

    func prepareControllers() {
        // Touch view controllers so viewDidLoad binds surfaces early.
        _ = aetherController.view
        _ = mpvController.view
    }

    func load(
        _ request: PlaybackLoadRequest,
        requiresMPVAudioControls: Bool = false
    ) {
        userStopped = false
        isHandoffInProgress = false
        isProgressSaveSuspended = false
        didFallbackForCurrentURL = false
        lastRequest = request
        currentURLString = request.videoURL.absoluteString

        let storedEngine = ProfileSettings.current.string(forKey: SettingsKey.playerEngine)
        let migratedEngine = PlayerEngineSetting.migrated(from: storedEngine)
        if storedEngine != migratedEngine.settingsRawValue {
            ProfileSettings.current.set(migratedEngine.settingsRawValue, forKey: SettingsKey.playerEngine)
        }
        let policy = PlaybackBackendPolicy.resolve(
            .init(
                urlString: request.videoURL.absoluteString,
                separateAudioURL: request.audioURL?.absoluteString,
                streamName: request.streamName,
                streamDescription: request.streamDescription,
                filename: request.filename,
                engineSetting: migratedEngine,
                requiresMPVAudioControls: requiresMPVAudioControls,
                assMode: request.assMode
            )
        )
        lastPolicyReason = policy.reason
        allowAutomaticFallback = policy.allowAutomaticFallback
        print("[PlaybackCoordinator] \(policy.reason)")

        loadGeneration += 1
        let generation = loadGeneration
        selectBackend(policy.backend, toast: policy.statusMessage, pauseOutgoing: true)
        startLoad(request, on: policy.backend, generation: generation)
    }

    /// Explicit Aether → MPV handoff (audio delay / amplification / terminal error).
    func handoffToMPV(reason: String, resumeSeconds: Double?) {
        guard !userStopped else { return }
        guard let request = lastRequest else { return }
        guard activeBackend == .aether else { return }
        guard !didFallbackForCurrentURL else {
            print("[PlaybackCoordinator] fallback already used for \(currentURLString ?? "?")")
            return
        }
        // MPVKit has no SMB transport. The automatic-fallback path is already
        // blocked for SMB via `allowAutomaticFallback` (see
        // `PlaybackBackendPolicy`), but `requestMPVForAudioControls` hands off
        // unconditionally on a user action (audio delay/gain), so this needs
        // its own guard rather than silently attempting a load MPV can't do.
        guard request.videoURL.scheme != "smb" else {
            print("[PlaybackCoordinator] refusing MPV handoff for SMB source (\(reason))")
            onHandoffToast?("Compatibility player isn't available for local network files")
            return
        }

        isHandoffInProgress = true
        isProgressSaveSuspended = true
        didFallbackForCurrentURL = true
        allowAutomaticFallback = false

        let captured = resumeSeconds
            ?? aetherController.coherentSourceTimeSeconds()
        lastPolicyReason = "AetherEngine → MPVKit: \(reason)"
        print("[PlaybackCoordinator] Aether→MPV handoff: \(reason) @ \(String(format: "%.2f", captured))s")

        aetherController.pausePlayback()
        aetherController.destroyPlayer()

        var mpvRequest = request
        if captured > 1 {
            mpvRequest.resumePositionSeconds = captured
        }
        lastRequest = mpvRequest
        handoffTargetSeconds = mpvRequest.resumePositionSeconds

        loadGeneration += 1
        let generation = loadGeneration
        selectBackend(.mpv, toast: "Compatibility player enabled", pauseOutgoing: false)
        onHandoffToast?("Compatibility player enabled")
        startLoad(mpvRequest, on: .mpv, generation: generation)
    }

    /// Ends the save guard only after MPV reports a coherent post-handoff clock.
    func refreshHandoffState() {
        guard isHandoffInProgress, activeBackend == .mpv else { return }
        guard !mpvController.isPlayerLoading, mpvController.durationMs > 0 else { return }
        let position = Double(mpvController.positionMs) / 1_000
        if let target = handoffTargetSeconds, target > 1,
           abs(position - target) > 12 {
            return
        }
        isHandoffInProgress = false
        isProgressSaveSuspended = false
        handoffTargetSeconds = nil
    }

    func updatePlaybackRate(_ value: Float) {
        lastRequest?.playbackRate = value
    }

    func updateSubtitleDelay(_ seconds: Double) {
        lastRequest?.subtitleDelaySeconds = seconds
    }

    func updateAudioDelay(_ seconds: Double) {
        lastRequest?.audioDelaySeconds = seconds
    }

    func updateAudioGain(_ decibels: Double) {
        lastRequest?.audioGainDB = decibels
    }

    func stopAll() {
        userStopped = true
        loadGeneration += 1
        isProgressSaveSuspended = false
        isHandoffInProgress = false
        handoffTargetSeconds = nil
        aetherController.destroyPlayer()
        mpvController.destroyPlayer()
    }

    func requestMPVForAudioControls(reason: String) {
        handoffToMPV(reason: reason, resumeSeconds: nil)
    }

    // MARK: - Internals

    private func handleAetherTerminalError(_ message: String) {
        guard !userStopped, !isHandoffInProgress else { return }
        guard activeBackend == .aether else { return }
        guard allowAutomaticFallback else {
            print("[PlaybackCoordinator] terminal Aether error without fallback: \(message)")
            return
        }
        // Ignore recoverable wording — Aether phase already filters rebuffering/stalled.
        handoffToMPV(reason: message, resumeSeconds: nil)
    }

    private func selectBackend(_ kind: PlayerBackendKind, toast: String?, pauseOutgoing: Bool) {
        if pauseOutgoing, activeBackend != kind {
            activeEngine.pausePlayback()
        }
        activeBackend = kind
        statusToast = toast
        if let toast {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self?.statusToast == toast {
                    self?.statusToast = nil
                }
            }
        }
    }

    private func startLoad(_ request: PlaybackLoadRequest, on backend: PlayerBackendKind, generation: UInt64) {
        switch backend {
        case .aether:
            aetherController.load(request, generation: generation)
        case .mpv:
            mpvController.load(request)
            mpvController.setAspectMode(.fit)
        }
    }
}
