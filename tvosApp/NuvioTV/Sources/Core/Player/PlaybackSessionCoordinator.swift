import Foundation
import UIKit
import Combine
import AetherEngine

struct PlaybackCompletionIdentity: Equatable {
    let titleID: String
    let contentType: String
    let season: Int?
    let episode: Int?
    let episodeID: String?
}

struct PlaybackCompletionTracker {
    let profileID: String?
    private(set) var source: TraktWatchProgressSource?
    private(set) var completionAccounts: [String: String]?
    private(set) var identity: PlaybackCompletionIdentity
    private(set) var completionID: String
    private(set) var hasEligiblePlayingSample = false
    private(set) var wasRecorded = false
    private(set) var hasConfirmedResumeTarget: Bool
    private(set) var resumeTargetSeconds: Double?

    init(
        profileID: String?,
        identity: PlaybackCompletionIdentity,
        resumeTargetSeconds: Double? = nil,
        source: TraktWatchProgressSource? = nil,
        completionAccounts: [String: String]? = nil
    ) {
        self.profileID = profileID
        self.source = source
        self.completionAccounts = completionAccounts
        self.identity = identity
        completionID = UUID().uuidString
        self.resumeTargetSeconds = Self.normalizedResumeTarget(resumeTargetSeconds)
        hasConfirmedResumeTarget = self.resumeTargetSeconds == nil
    }

    mutating func transition(to identity: PlaybackCompletionIdentity) {
        guard self.identity != identity else { return }
        self.identity = identity
        completionID = UUID().uuidString
        hasEligiblePlayingSample = false
        wasRecorded = false
        resumeTargetSeconds = nil
        hasConfirmedResumeTarget = true
    }

    mutating func updateResumeTarget(_ seconds: Double?) {
        let target = Self.normalizedResumeTarget(seconds)
        guard resumeTargetSeconds != target else { return }
        resumeTargetSeconds = target
        hasConfirmedResumeTarget = target == nil
    }

    mutating func observePlayingSample(
        isCoherent: Bool,
        isGenuinelyPlaying: Bool,
        isBelowCompletionBoundary: Bool,
        hasReachedResumeTarget: Bool = true
    ) {
        guard !wasRecorded, isCoherent, isGenuinelyPlaying else { return }
        if !hasConfirmedResumeTarget, hasReachedResumeTarget {
            hasConfirmedResumeTarget = true
        }
        guard hasConfirmedResumeTarget, isBelowCompletionBoundary else { return }
        hasEligiblePlayingSample = true
    }

    func completionIDForRecording(
        identity: PlaybackCompletionIdentity,
        currentProfileID: String?,
        isAlreadyWatched: Bool
    ) -> String? {
        guard self.identity == identity,
              profileID == currentProfileID,
              !wasRecorded,
              !isAlreadyWatched || hasEligiblePlayingSample else {
            return nil
        }
        return completionID
    }

    mutating func markRecorded(completionID: String) {
        guard self.completionID == completionID else { return }
        wasRecorded = true
    }

    private static func normalizedResumeTarget(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 5 else { return nil }
        return seconds
    }
}

/// Owns backend selection, generation-safe loads, and one-way Aether → MPV handoff.
@MainActor
final class PlaybackSessionCoordinator: ObservableObject {
    /// Stable across fullscreen view recreation and PiP adoption.
    let wakeLockOwnerID = UUID()
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
    /// Generation whose request has reached its selected backend dispatcher.
    /// Old frames cannot start a new load while cache preparation is pending.
    private(set) var dispatchedLoadGeneration: UInt64?
    private var allowAutomaticFallback = true
    private var didFallbackForCurrentURL = false
    private var currentURLString: String?
    private(set) var lastRequest: PlaybackLoadRequest?
    private var lastRequiresMPVAudioControls = false
    private var isHandoffInProgress = false
    private var handoffTargetSeconds: Double?
    private var handoffStartedAtUptime: TimeInterval?
    private var userStopped = false
    /// Suppress progress saves / watched marks during backend handoff.
    private(set) var isProgressSaveSuspended = false

    var onHandoffToast: ((String) -> Void)?
    var onAetherControllerChanged: ((AetherPlaybackController?) -> Void)?
    var prepareForHandoff: ((inout PlaybackLoadRequest) -> Void)?
    var onBackendHandoff: ((PlaybackLoadRequest) -> Void)?
    private(set) var currentCacheSessionToken: String?
    /// Retain ownership across PiP and later switches to a non-torrent source.
    var torrentStreamSourceURL: URL?
    private(set) var playbackCompletionTracker: PlaybackCompletionTracker?

    static func shouldUseHybridDiskCache(isEnabled: Bool, request: PlaybackLoadRequest) -> Bool {
        isEnabled
            && !request.isLiveStream
            && !request.isSports
            && PlaybackBackendPolicy.isRemoteHTTP(request.videoURL.absoluteString)
            && request.videoURL.pathExtension.lowercased() != "m3u8"
            && !PlaybackBackendPolicy.isDiscImage(request.videoURL.absoluteString, filename: request.filename)
    }

    func beginNewPlaybackCompletionSession(
        identity: PlaybackCompletionIdentity,
        profileID: String?,
        resumeTargetSeconds: Double? = nil,
        source: TraktWatchProgressSource? = nil,
        completionAccounts: [String: String]? = nil
    ) {
        playbackCompletionTracker = PlaybackCompletionTracker(
            profileID: profileID,
            identity: identity,
            resumeTargetSeconds: resumeTargetSeconds,
            source: source,
            completionAccounts: completionAccounts
        )
    }

    /// Keeps the current profile scope while preserving the completion guard
    /// across same-content source reloads and PiP view-model adoption. A new
    /// episode/title receives a fresh completion ID in the same play session.
    func updatePlaybackCompletionTarget(
        _ identity: PlaybackCompletionIdentity,
        fallbackProfileID: String?,
        resumeTargetSeconds: Double? = nil
    ) {
        guard var tracker = playbackCompletionTracker else {
            beginNewPlaybackCompletionSession(
                identity: identity,
                profileID: fallbackProfileID,
                resumeTargetSeconds: resumeTargetSeconds
            )
            return
        }
        tracker.transition(to: identity)
        tracker.updateResumeTarget(resumeTargetSeconds)
        playbackCompletionTracker = tracker
    }

    func preservePlaybackCompletionTargetIdentity(
        _ identity: PlaybackCompletionIdentity,
        fallbackProfileID: String?
    ) {
        guard var tracker = playbackCompletionTracker else {
            beginNewPlaybackCompletionSession(identity: identity, profileID: fallbackProfileID)
            return
        }
        tracker.transition(to: identity)
        playbackCompletionTracker = tracker
    }

    func observePlaybackCompletionSample(
        isCoherent: Bool,
        isGenuinelyPlaying: Bool,
        isBelowCompletionBoundary: Bool,
        hasReachedResumeTarget: Bool = true
    ) {
        guard var tracker = playbackCompletionTracker else { return }
        tracker.observePlayingSample(
            isCoherent: isCoherent,
            isGenuinelyPlaying: isGenuinelyPlaying,
            isBelowCompletionBoundary: isBelowCompletionBoundary,
            hasReachedResumeTarget: hasReachedResumeTarget
        )
        playbackCompletionTracker = tracker
    }

    func playbackCompletionIDForRecording(
        identity: PlaybackCompletionIdentity,
        currentProfileID: String?,
        isAlreadyWatched: Bool
    ) -> String? {
        playbackCompletionTracker?.completionIDForRecording(
            identity: identity,
            currentProfileID: currentProfileID,
            isAlreadyWatched: isAlreadyWatched
        )
    }

    func markPlaybackCompletionRecorded(completionID: String) {
        guard var tracker = playbackCompletionTracker else { return }
        tracker.markRecorded(completionID: completionID)
        playbackCompletionTracker = tracker
    }

    var activeEngine: PlaybackEngineControlling {
        switch activeBackend {
        case .aether:
            if let aetherController { return aetherController }
            unavailableEngine.currentErrorMessage = lastLoadError ?? ""
            return unavailableEngine
        case .mpv: return mpvController
        }
    }

    var loadingStepMessage: String? {
        if let statusToast, !statusToast.isEmpty {
            return statusToast
        }
        return activeEngine.loadingStepMessage
    }

    var isAwaitingDisplaySwitch: Bool {
        activeEngine.isAwaitingDisplaySwitch
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
        PlaybackDiagnosticLogStore.shared.append(source: "Player", message: "Playback load started")
        userStopped = false
        isHandoffInProgress = false
        isProgressSaveSuspended = false
        handoffStartedAtUptime = nil
        didFallbackForCurrentURL = false
        lastRequest = request
        lastRequiresMPVAudioControls = requiresMPVAudioControls
        currentURLString = request.videoURL.absoluteString
        statusToast = nil
        loadGeneration &+= 1
        dispatchedLoadGeneration = nil
        bindAetherCallbacks()

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
                assMode: request.assMode,
                isAnime: request.isAnime,
                isLiveStream: request.isLiveStream,
                isSports: request.isSports,
                httpHeaders: request.httpHeaders
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

        let diskCacheSetting = (ProfileSettings.current.object(forKey: SettingsKey.hybridDiskCacheEnabled) as? Bool) ?? false
        let cacheEligible = Self.shouldUseHybridDiskCache(isEnabled: diskCacheSetting, request: request)
        let aetherVersion = selectedBackend == .aether ? AetherEngine.version : "not-active"
        PlaybackDiagnosticLogStore.shared.append(
            source: "Player",
            message: "backend=\(selectedBackend.rawValue) aetherVersion=\(aetherVersion) hybridDiskCache=\(cacheEligible ? "enabled" : "disabled")"
        )

        let generation = loadGeneration
        selectBackend(selectedBackend, toast: policy.statusMessage ?? statusToast, pauseOutgoing: true)
        onAetherControllerChanged?(aetherController)
        startLoad(request, on: selectedBackend, generation: generation)
    }

    /// Re-attempts the last request after a recoverable Aether construction
    /// failure. Auto requests can simply be reloaded; explicit Aether requests
    /// use this action to retry without recreating the player view.
    func retryLastLoad(startupBenchmarkToken: UUID? = nil) {
        guard var request = lastRequest else { return }
        guard !userStopped else { return }
        request.startupBenchmarkToken = startupBenchmarkToken
        lastRequest = request
        loadGeneration &+= 1
        aetherController?.onTerminalError = nil
        aetherController?.destroyPlayer()
        aetherController = nil
        bindAetherCallbacks()
        onAetherControllerChanged?(aetherController)
        statusToast = nil
        load(request, requiresMPVAudioControls: lastRequiresMPVAudioControls)
    }

    /// Clears a latched startup error only for the load that has verified recovery.
    @discardableResult
    func clearLoadErrorAfterVerifiedRecovery(generation: UInt64) -> Bool {
        guard loadGeneration == generation, lastLoadError != nil else { return false }
        lastLoadError = nil
        return true
    }

    func hasPresentedCurrentAetherLoad(generation: UInt64) -> Bool {
        guard loadGeneration == generation,
              dispatchedLoadGeneration == generation,
              activeBackend == .aether,
              let aetherController else { return false }
        return aetherController.hasPresentedCurrentLoad(generation: generation)
    }

    func shouldGrantDiscStartupWatchdogGrace(generation: UInt64, graceAlreadyGranted: Bool) -> Bool {
        guard loadGeneration == generation else { return false }
        return AetherDiscStartupWatchdogGracePolicy.shouldGrantGrace(
            request: lastRequest,
            backend: activeBackend,
            loadGeneration: generation,
            dispatchedLoadGeneration: dispatchedLoadGeneration,
            progress: aetherController?.startupLoadCheckpointWitness,
            graceAlreadyGranted: graceAlreadyGranted
        )
    }

    func shouldGrantStartupWatchdogGrace(generation: UInt64, graceAlreadyGranted: Bool) -> Bool {
        guard loadGeneration == generation else { return false }
        if shouldGrantDiscStartupWatchdogGrace(generation: generation, graceAlreadyGranted: graceAlreadyGranted) {
            return true
        }
        guard !graceAlreadyGranted,
              activeBackend == .aether,
              dispatchedLoadGeneration == generation,
              let request = lastRequest,
              !request.isLiveStream,
              !request.isSports,
              PlaybackBackendPolicy.isRemoteHTTP(request.videoURL.absoluteString),
              let progress = aetherController?.startupLoadCheckpointWitness,
              progress.ownerLoadGeneration == generation,
              let floor = progress.engineGenerationFloor,
              let pGen = progress.progressGeneration,
              pGen >= floor,
              let cp = progress.checkpoint,
              cp >= .containerOpened else {
            return false
        }
        return true
    }

    func hasDispatchedCurrentLoad(generation: UInt64) -> Bool {
        loadGeneration == generation && dispatchedLoadGeneration == generation
    }

    /// Explicit Aether → MPV handoff (audio delay / amplification / terminal error).
    func handoffToMPV(reason: String, resumeSeconds: Double?) {
        guard !userStopped else { return }
        guard let request = lastRequest else { return }
        guard activeBackend == .aether else { return }
        guard mpvSupportsRequest(request) else {
            print("[PlaybackCoordinator] MPV handoff suppressed: remote HLS requires native playback")
            return
        }
        guard !didFallbackForCurrentURL else {
            print("[PlaybackCoordinator] fallback already used for \(currentURLString ?? "?")")
            return
        }

        guard let aetherController else { return }
        isHandoffInProgress = true
        isProgressSaveSuspended = true
        didFallbackForCurrentURL = true
        allowAutomaticFallback = false
        let hasLiveTimeline = request.isLiveStream || request.isSports
        let captured = hasLiveTimeline
            ? 0
            : (resumeSeconds ?? aetherController.coherentSourceTimeSeconds())
        lastPolicyReason = "AetherEngine → MPVKit: \(reason)"
        print("[PlaybackCoordinator] Aether→MPV handoff: \(reason) @ \(String(format: "%.2f", captured))s")

        aetherController.pausePlayback()
        aetherController.destroyPlayer()

        var mpvRequest = request
        if hasLiveTimeline {
            mpvRequest.resumePositionSeconds = nil
        } else if captured > 1 {
            mpvRequest.resumePositionSeconds = captured
        }
        prepareForHandoff?(&mpvRequest)
        lastRequest = mpvRequest
        handoffTargetSeconds = mpvRequest.resumePositionSeconds
        handoffStartedAtUptime = ProcessInfo.processInfo.systemUptime

        let outgoingCacheToken = currentCacheSessionToken
        currentCacheSessionToken = nil
        if let outgoingCacheToken {
            Task {
                await PlaybackStreamCacheManager.shared.stopSession(token: outgoingCacheToken)
            }
        }

        loadGeneration += 1
        dispatchedLoadGeneration = nil
        let generation = loadGeneration
        selectBackend(.mpv, toast: "Compatibility player enabled", pauseOutgoing: false)
        onHandoffToast?("Compatibility player enabled")
        onBackendHandoff?(mpvRequest)
        startLoad(mpvRequest, on: .mpv, generation: generation)
    }

    /// Startup-only fallback for live and sports requests selected for Aether
    /// by Auto. The generation and dispatch guards reject callbacks from older
    /// loads; the ordinary handoff guard still enforces one fallback per URL.
    @discardableResult
    func requestLiveStartupFallback(generation expectedGeneration: UInt64) -> Bool {
        guard !userStopped,
              !isHandoffInProgress,
              loadGeneration == expectedGeneration,
              dispatchedLoadGeneration == expectedGeneration,
              lastLoadError == nil,
              activeBackend == .aether,
              allowAutomaticFallback,
              !didFallbackForCurrentURL,
              let request = lastRequest,
              request.isLiveStream || request.isSports,
              let aetherController,
              !aetherController.hasFirstFrameReadyForDisplay,
              !aetherController.isPlayerPlaying,
              !aetherController.isTransportPlaying else {
            return false
        }
        guard mpvSupportsRequest(request) else {
            return false
        }

        let previousGeneration = loadGeneration
        handoffToMPV(reason: "Live stream did not start in AetherEngine", resumeSeconds: 0)
        return activeBackend == .mpv && loadGeneration != previousGeneration
    }

    /// Wait for the resume target, or a coherent clock after the seek settle window.
    func refreshHandoffState() {
        guard isHandoffInProgress, activeBackend == .mpv else { return }
        guard !mpvController.isPlayerLoading, mpvController.durationMs > 0 else { return }
        let position = Double(mpvController.positionMs) / 1_000
        if let target = handoffTargetSeconds, target > 1,
           abs(position - target) > 12 {
            // A failed/imprecise seek must not suppress saves for the whole session.
            // After the settle window, use MPV's actual coherent clock.
            guard let startedAt = handoffStartedAtUptime,
                  ProcessInfo.processInfo.systemUptime - startedAt >= 15,
                  mpvController.hasCoherentTimeSample else { return }
        }
        isHandoffInProgress = false
        isProgressSaveSuspended = false
        handoffTargetSeconds = nil
        handoffStartedAtUptime = nil
    }

    func updateExternalSubtitles(_ subtitles: [NuvioSubtitle]) {
        lastRequest?.externalSubtitles = subtitles
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
        PlaybackWakeLock.release(ownerID: wakeLockOwnerID)
        userStopped = true
        loadGeneration += 1
        dispatchedLoadGeneration = nil
        isProgressSaveSuspended = false
        isHandoffInProgress = false
        handoffTargetSeconds = nil
        handoffStartedAtUptime = nil
        statusToast = nil
        aetherController?.destroyPlayer()
        mpvController.destroyPlayer()
        let tokenToStop = currentCacheSessionToken
        currentCacheSessionToken = nil
        if let tokenToStop {
            Task {
                await PlaybackStreamCacheManager.shared.stopSession(token: tokenToStop)
            }
        }
    }

    func requestMPVForAudioControls(reason: String) {
        handoffToMPV(reason: reason, resumeSeconds: nil)
    }

    // MARK: - Internals

    private func bindAetherCallbacks() {
        guard let controller = aetherController else { return }
        let generation = loadGeneration
        controller.onTerminalError = { [weak self, weak controller] message in
            guard let self, let controller,
                  self.aetherController === controller,
                  self.loadGeneration == generation else { return }
            self.handleAetherTerminalError(message)
        }
    }

    private func mpvSupportsRequest(_ request: PlaybackLoadRequest) -> Bool {
        guard !PlaybackBackendPolicy.isDiscImage(request.videoURL.absoluteString, filename: request.filename),
              PlaybackBackendPolicy.mpvSupportsURL(request.videoURL.absoluteString),
              request.httpHeaderSourceURL.map({ PlaybackBackendPolicy.mpvSupportsURL($0.absoluteString) }) ?? true
        else { return false }
        // Extensionless playlists may only be identified after the native engine opens them.
        return PlaybackEngineCapabilities.mpv.supportsRemoteHLS
            || aetherController?.engine.videoRoute != .remoteBypass
    }

    private func handleAetherTerminalError(_ message: String) {
        guard !userStopped, !isHandoffInProgress else { return }
        guard activeBackend == .aether else { return }
        guard allowAutomaticFallback else {
            print("[PlaybackCoordinator] terminal Aether error without fallback: \(message)")
            lastLoadError = message
            return
        }
        if let request = lastRequest, !mpvSupportsRequest(request) {
            print("[PlaybackCoordinator] terminal Aether error on remote stream; suppressing MPV fallback: \(message)")
            lastLoadError = message
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
            dispatchedLoadGeneration = generation
            loadDispatcher(request, backend, generation)
            return
        }

        let isDiskCacheEnabled = (ProfileSettings.current.object(forKey: SettingsKey.hybridDiskCacheEnabled) as? Bool) ?? false

        if Self.shouldUseHybridDiskCache(isEnabled: isDiskCacheEnabled, request: request) {
            let sessionToken = UUID().uuidString
            let previousToken = currentCacheSessionToken
            currentCacheSessionToken = sessionToken
            if let previousToken {
                Task {
                    await PlaybackStreamCacheManager.shared.stopSession(token: previousToken)
                }
            }

            Task { @MainActor [weak self] in
                guard let self, !self.userStopped, self.loadGeneration == generation else {
                    await PlaybackStreamCacheManager.shared.stopSession(token: sessionToken)
                    return
                }
                var effectiveRequest = request
                if let localURL = await PlaybackStreamCacheManager.shared.prepareCacheServer(
                    for: request.videoURL,
                    headers: request.httpHeaders,
                    sessionToken: sessionToken,
                    canonicalMediaKey: request.canonicalMediaKey,
                    cacheFileIdentity: request.cacheFileIdentity,
                    filename: request.filename,
                    targetLeadSeconds: request.cacheProfile.hybridCacheTargetLeadSeconds
                ) {
                    effectiveRequest.httpHeaderSourceURL = request.httpHeaderSourceURL ?? request.videoURL
                    effectiveRequest.videoURL = localURL
                }
                guard !self.userStopped, self.loadGeneration == generation else {
                    await PlaybackStreamCacheManager.shared.stopSession(token: sessionToken)
                    return
                }
                self.dispatchToEngine(effectiveRequest, on: backend, generation: generation)
            }
        } else {
            let previousToken = currentCacheSessionToken
            currentCacheSessionToken = nil
            if let previousToken {
                Task {
                    await PlaybackStreamCacheManager.shared.stopSession(token: previousToken)
                }
            }
            dispatchToEngine(request, on: backend, generation: generation)
        }
    }

    private func dispatchToEngine(_ request: PlaybackLoadRequest, on backend: PlayerBackendKind, generation: UInt64) {
        guard !userStopped, loadGeneration == generation else { return }
        switch backend {
        case .aether:
            guard let aetherController else {
                lastLoadError = "AetherEngine is unavailable on this device."
                return
            }
            dispatchedLoadGeneration = generation
            aetherController.load(request, generation: generation)
        case .mpv:
            _ = mpvController.view
            dispatchedLoadGeneration = generation
            mpvController.load(request)
            mpvController.setAspectMode(request.aspectMode)
        }
    }

    func setExternalTrickplayProvider(_ provider: (any TrickplayProviding)?) {
        aetherController?.setExternalTrickplayProvider(provider)
        mpvController.setExternalTrickplayProvider(provider)
    }
}

/// An unavailable selection must not route controls into another live backend.
@MainActor
private final class UnavailablePlaybackEngine: PlaybackEngineControlling {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
    var onFirstFrameReady: (() -> Void)?
    let audioTracks: [PlaybackTrackInfo] = []
    let subtitleTracks: [PlaybackTrackInfo] = []
    let isPlayerLoading = false
    let isPlayerPlaying = false
    let isTransportPlaying = false
    let isPlayerEnded = false
    let isAtEndOfFile = false
    let hasCoherentTimeSample = false
    let hasFirstFrameReadyForDisplay = false
    let durationMs: Int64 = 0
    let positionMs: Int64 = 0
    let bufferedMs: Int64 = 0
    let currentSpeed: Float = 1
    var currentErrorMessage = ""
    let videoFrameSize = CGSize.zero
    var playbackDebugInfo: PlaybackDebugInfo { PlaybackDebugInfo(player: "Unavailable") }
    var loadingStepMessage: String? { nil }
    func loadFile(_ urlString: String) {}
    func playPlayback() {}
    func pausePlayback() {}
    func seekToMs(_ ms: Int64) {}
    func seekToMs(_ ms: Int64, exact: Bool) {}
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
