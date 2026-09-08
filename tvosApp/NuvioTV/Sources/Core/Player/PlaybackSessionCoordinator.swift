import Foundation
import UIKit
import Combine

/// Owns backend selection, generation-safe loads, and one-way Aether → MPV handoff.
@MainActor
final class PlaybackSessionCoordinator: ObservableObject {
    @Published private(set) var activeBackend: PlayerBackendKind = .aether
    @Published private(set) var statusToast: String?
    @Published private(set) var lastPolicyReason: String = ""
    @Published private(set) var lastLoadError: String?

    private let aetherControllerFactory: @MainActor () -> AetherPlaybackController?
    private let engineSettingProvider: @MainActor () -> String?
    private let loadDispatcher: (@MainActor (PlaybackLoadRequest, PlayerBackendKind, UInt64) -> Void)?
    private(set) var aetherController: AetherPlaybackController?
    let mpvController = MPVPlayerViewController()
    private let unavailableEngine = UnavailablePlaybackEngine()

    /// Generation token for the in-flight load. Completions for older gens are ignored.
    private(set) var loadGeneration: UInt64 = 0
    private var allowAutomaticFallback = true
    private var didFallbackForCurrentURL = false
    private var currentURLString: String?
    private var lastRequest: PlaybackLoadRequest?
    private var lastRequiresMPVAudioControls = false
    private var isHandoffInProgress = false
    private var handoffTargetSeconds: Double?
    private var userStopped = false
    /// Suppress progress saves / watched marks during backend handoff.
    private(set) var isProgressSaveSuspended = false

    var onHandoffToast: ((String) -> Void)?
    var onAetherControllerChanged: ((AetherPlaybackController?) -> Void)?

    var activeEngine: PlaybackEngineControlling {
        switch activeBackend {
        case .aether:
            if let aetherController { return aetherController }
            unavailableEngine.currentErrorMessage = lastLoadError ?? ""
            return unavailableEngine
        case .mpv: return mpvController
        }
    }

    init(
        aetherController: AetherPlaybackController? = nil,
        aetherControllerFactory: @escaping @MainActor () -> AetherPlaybackController? = { AetherPlaybackController() },
        engineSettingProvider: @escaping @MainActor () -> String? = {
            let stored = ProfileSettings.current.string(forKey: SettingsKey.playerEngine)
            let migrated = PlayerEngineSetting.migrated(from: stored).settingsRawValue
            if stored != migrated { ProfileSettings.current.set(migrated, forKey: SettingsKey.playerEngine) }
            return migrated
        },
        loadDispatcher: (@MainActor (PlaybackLoadRequest, PlayerBackendKind, UInt64) -> Void)? = nil
    ) {
        self.aetherControllerFactory = aetherControllerFactory
        self.engineSettingProvider = engineSettingProvider
        self.loadDispatcher = loadDispatcher
        self.aetherController = aetherController
        bindAetherCallbacks()
    }

    // MARK: - Public API

    func prepareControllers() {
        // Rebind only the selected host (for example on PiP return). Preparing
        // the MPV view eagerly also creates a decoder for native-only sessions.
        switch activeBackend {
        case .aether: _ = aetherController?.view
        case .mpv: _ = mpvController.view
        }
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
        lastRequiresMPVAudioControls = requiresMPVAudioControls
        currentURLString = request.videoURL.absoluteString
        statusToast = nil
        loadGeneration &+= 1

        let storedEngine = engineSettingProvider()
        let migratedEngine = PlayerEngineSetting.migrated(from: storedEngine)
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
        lastLoadError = nil
        print("[PlaybackCoordinator] \(policy.reason)")

        var selectedBackend = policy.backend
        if selectedBackend == .aether {
            if aetherController == nil {
                aetherController = aetherControllerFactory()
                bindAetherCallbacks()
                _ = aetherController?.view
            }
            if aetherController == nil {
                let message = "AetherEngine is unavailable on this device."
                if policy.allowAutomaticFallback {
                    selectedBackend = .mpv
                    allowAutomaticFallback = false
                    lastPolicyReason = "\(policy.reason); \(message) Using MPVKit."
                    statusToast = "Compatibility player enabled"
                    print("[PlaybackCoordinator] \(lastPolicyReason)")
                } else {
                    activeEngine.pausePlayback()
                    activeBackend = .aether
                    lastLoadError = message
                    statusToast = message
                    onAetherControllerChanged?(nil)
                    return
                }
            }
        }

        let generation = loadGeneration
        selectBackend(selectedBackend, toast: policy.statusMessage ?? statusToast, pauseOutgoing: true)
        onAetherControllerChanged?(aetherController)
        startLoad(request, on: selectedBackend, generation: generation)
    }

    /// Re-attempts the last request after a recoverable Aether construction
    /// failure. Auto requests can simply be reloaded; explicit Aether requests
    /// use this action to retry without recreating the player view.
    func retryLastLoad() {
        guard let lastRequest else { return }
        guard !userStopped else { return }
        loadGeneration &+= 1
        aetherController?.onTerminalError = nil
        aetherController?.destroyPlayer()
        aetherController = nil
        bindAetherCallbacks()
        onAetherControllerChanged?(aetherController)
        statusToast = nil
        load(lastRequest, requiresMPVAudioControls: lastRequiresMPVAudioControls)
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

        guard let aetherController else { return }
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
        statusToast = nil
        aetherController?.destroyPlayer()
        mpvController.destroyPlayer()
    }

    func requestMPVForAudioControls(reason: String) {
        handoffToMPV(reason: reason, resumeSeconds: nil)
    }

    // MARK: - Internals

    private func bindAetherCallbacks() {
        guard let controller = aetherController else { return }
        controller.onTerminalError = { [weak self, weak controller] message in
            guard let self, let controller, self.aetherController === controller else { return }
            self.handleAetherTerminalError(message)
        }
    }

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
            let generation = loadGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self?.loadGeneration == generation, self?.statusToast == toast {
                    self?.statusToast = nil
                }
            }
        }
    }

    private func startLoad(_ request: PlaybackLoadRequest, on backend: PlayerBackendKind, generation: UInt64) {
        guard !userStopped, loadGeneration == generation else { return }
        if let loadDispatcher {
            loadDispatcher(request, backend, generation)
            return
        }
        switch backend {
        case .aether:
            guard let aetherController else {
                lastLoadError = "AetherEngine is unavailable on this device."
                return
            }
            aetherController.load(request, generation: generation)
        case .mpv:
            _ = mpvController.view
            mpvController.load(request)
            mpvController.setAspectMode(.fit)
        }
    }
}

/// An unavailable selection must not route controls into another live backend.
@MainActor
private final class UnavailablePlaybackEngine: PlaybackEngineControlling {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
    let audioTracks: [PlaybackTrackInfo] = []
    let subtitleTracks: [PlaybackTrackInfo] = []
    let isPlayerLoading = false
    let isPlayerPlaying = false
    let isPlayerEnded = false
    let isAtEndOfFile = false
    let hasCoherentTimeSample = false
    let durationMs: Int64 = 0
    let positionMs: Int64 = 0
    let bufferedMs: Int64 = 0
    let currentSpeed: Float = 1
    var currentErrorMessage = ""
    let videoFrameSize = CGSize.zero
    var playbackDebugInfo: PlaybackDebugInfo { PlaybackDebugInfo(player: "Unavailable") }
    func loadFile(_ urlString: String) {}
    func playPlayback() {}
    func pausePlayback() {}
    func seekToMs(_ ms: Int64) {}
    func setSpeed(_ speed: Float) {}
    func setAspectMode(_ mode: PlayerAspectMode) {}
    func setSubtitleDelay(_ seconds: Double) {}
    func setAudioDelay(_ seconds: Double) {}
    func setAudioVolumeGain(dB: Double) {}
    func selectAudio(_ trackId: Int) {}
    func selectSubtitle(_ trackId: Int) {}
    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {}
    func addAudioUrl(_ url: String) {}
    func applySubtitleStyle() {}
    func destroyPlayer() {}
    func refreshPlaybackState() {}
}
