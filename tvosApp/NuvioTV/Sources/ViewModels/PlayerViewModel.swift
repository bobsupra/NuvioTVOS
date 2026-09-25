import Foundation
import Combine
import SwiftUI

@MainActor
protocol ScrubThumbnailProviding: AnyObject {
    var supportsScrubThumbnails: Bool { get }
    func cachedScrubThumbnail(atSeconds seconds: Double, duration: Double) async -> CGImage?
    func scrubThumbnail(atSeconds seconds: Double, maxWidth: Int, precise: Bool) async -> CGImage?
}

struct LiveStreamFailoverPolicy {
    struct Decision: Equatable {
        let retryCurrent: Bool
        let exclusions: [String]
        let retriedURLs: Set<String>
        let failedURLs: Set<String>
    }

    static func decide(isLive: Bool, currentURL: String?, retriedURLs: Set<String>, failedURLs: Set<String>) -> Decision {
        guard let currentURL else {
            return Decision(retryCurrent: false, exclusions: Array(failedURLs), retriedURLs: retriedURLs, failedURLs: failedURLs)
        }
        if isLive && !retriedURLs.contains(currentURL) {
            var updated = retriedURLs
            updated.insert(currentURL)
            return Decision(retryCurrent: true, exclusions: [], retriedURLs: updated, failedURLs: failedURLs)
        }
        var failed = failedURLs
        failed.insert(currentURL)
        return Decision(retryCurrent: false, exclusions: Array(failed), retriedURLs: retriedURLs, failedURLs: failed)
    }

}
import UIKit
import AVFoundation
import AVKit
import CoreMedia
import GameController
// MARK: - Playback clock
//
// Time + scrub target live on a separate ObservableObject so high-frequency
// scrub updates and position ticks only re-render the small HUD/timeline views,
// not the whole player ZStack (video surface + overlays).

@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
    /// Live scrub position while the Infuse scrub HUD is up.
    @Published var scrubTarget: Double?
    @Published var wheelAngle: Double = 0
}

// MARK: - PlayerViewModel (Aether + MPV)
//
// Default backend is AetherEngine (hardware or software decode). MPVKit is the
// one-way compatibility fallback.

@MainActor
class PlayerViewModel: ObservableObject {
    @Published var status: PlayerStatus = .idle
    var time: PlayerTime = PlayerTime()
    /// High-frequency time/scrub state for HUDs. Mirrors `time` on each tick.
    let clock = PlaybackClock()
    @Published var subtitles: [SubtitleTrack] = []
    @Published var audioTracks: [AudioTrack] = []
    @Published var playbackSpeed: PlaybackSpeed = .normal
    @Published var seekStepSeconds: Int = PlayerSeekSettings.current
    @Published var qualities: [QualityOption] = [.auto]
    @Published var currentQuality: QualityOption = .auto
    @Published var showControls: Bool = false
    /// True while the transport controls are up and the timeline scrubber holds
    /// focus. Lets the remote press-catcher drive continuous hold-to-seek even
    /// with the controls visible, matching the controls-hidden behaviour.
    /// @Published so the catcher re-asserts first responder when it flips.
    @Published var isTimelineFocused: Bool = false
    /// Infuse-style scrub mode (touchpad drag / D-pad jump / wheel fine-tune).
    @Published private(set) var isScrubbing = false
    /// Cache-backed Aether still for the current scrub target. Nil means the
    /// time-only HUD remains visible while a still is unavailable.
    @Published private(set) var scrubThumbnail: CGImage?
    /// Accumulated D-pad skip preview (seconds). Zero when idle.
    @Published var pendingSeekDelta: Double = 0
    /// True while holding down D-pad Left/Right for continuous fast-seeking with live preview.
    @Published var isHoldingSeek: Bool = false
    /// Speed multiplier badge (1x, 2x, 3x, 4x) active during hold-to-seek.
    @Published var seekSpeedMultiplier: Int? = nil
    /// Light-tap peek timeline (no full controls).
    @Published private(set) var peekVisible = false
    /// True while the finger is at the trackpad edge for wheel fine-tune.
    @Published private(set) var wheelEngaged = false
    @Published var title: String = ""
    @Published var subtitle: String = ""
    /// Live channels use a sliding timeline rather than a finite media duration.
    /// Expose that distinction so transport chrome can avoid a misleading scrubber.
    @Published private(set) var isLiveStream = false
    /// Every external subtitle the stream offered (all languages), browsable in
    /// the player's subtitle panel and loaded into mpv on demand.
    @Published var availableExternalSubtitles: [NuvioSubtitle] = []
    /// True while installed subtitle add-ons are still returning results.
    @Published var isLoadingExternalSubtitles: Bool = false
    /// Current mpv `sub-delay`, in milliseconds. Per-session, not persisted.
    @Published var subtitleDelayMs: Int = 0
    @Published private(set) var subtitleStyle = SubtitleStyle.current
    /// Session-only override used when AI Subtitle auto-select is disabled.
    @Published private(set) var isAISubtitleTranslationManuallyEnabled = false
    /// Current mpv `audio-delay`, in milliseconds. Per-session, not persisted.
    @Published var audioDelayMs: Int = 0
    /// PCM amplification in whole dB (0…10), applied as mpv software volume.
    /// Per-session, not persisted.
    @Published var audioAmplificationDb: Int = 0
    /// Full-screen settings panel (subtitles / audio / speed) visibility.
    @Published var showSettingsPanel: Bool = false
    /// Active audio route name (e.g. HomePod, TV Speakers, AirPods).
    @Published var currentAudioRouteDescription: String = PlaybackSystemMonitor.currentAudioOutputTitle()
    /// In-player side sheet (episodes / sources).
    @Published var sidePanel: PlayerSidePanel? = nil
    /// Alternate streams for the current title (Sources panel).
    @Published private(set) var availableSources: [NuvioStream] = []
    @Published private(set) var isLoadingSources = false
    /// Netflix/Infuse-style metadata sheet while paused (shown after a short delay).
    @Published var showPauseOverlay: Bool = false
    /// How the video fills the display (Fit / Fill / Stretch).
    @Published var aspectMode: PlayerAspectMode = PlayerAspectMode.current
    /// Decoded frame size for aspect-mode scaling (0 until first frame).
    @Published private(set) var videoNaturalSize: CGSize = .zero
    private var pauseOverlayTask: Task<Void, Never>?
    /// Seconds to wait after pausing before the metadata sheet appears.
    private static let pauseOverlayDelaySeconds: UInt64 = 5

    // MARK: - Picture in Picture
    var isPictureInPictureSupported: Bool {
        PictureInPictureManager.shared.isPictureInPictureSupported && activeEngineKind == .aether
    }
    @Published var isPictureInPictureActive: Bool = false
    @Published var isPictureInPicturePossible: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var coordinatorErrorCancellable: AnyCancellable?

    // MARK: Next episode

    /// The episode that will play after this one, if any. Drives the Next
    /// Episode card; nil for movies, trailers, or the last episode.
    @Published var nextEpisode: NuvioVideo?
    /// Whether the Next Episode card is visible (near the end of an episode
    /// that has a follow-up).
    @Published var showNextEpisodeCard: Bool = false
    /// Retained for compatibility with the card API; autoplay is performed
    /// only after the backend reports genuine end-of-media.
    @Published var nextEpisodeCountdown: Int?
    /// Cancellation applies only to the currently configured episode.
    @Published private(set) var isAutoPlayCancelled = false
    /// True while the next episode's stream is being resolved and loaded, so the
    /// card can show a spinner instead of a Play button.
    @Published var isAdvancingEpisode: Bool = false
    /// Current IntroDB skip segment, visible as a compact skip action.
    @Published var activeSkipInterval: SkipInterval?
    @Published var skipSegmentCountdown: Int?

    var showSkipSegmentCard: Bool {
        guard activeSkipInterval != nil, !showSettingsPanel else { return false }
        if activeSkipInterval?.id == autoHiddenSkipIntervalId, !showControls { return false }
        return showControls || skipSegmentCountdown != nil
    }

    /// Ordered episode list for the current series (empty for movies/trailers).
    private var seriesEpisodes: [NuvioVideo] = []
    private var currentEpisodeVideo: NuvioVideo?
    /// Resolves a next episode into a ready-to-play stream, provided by the app
    /// layer (reuses the details screen's add-on fetch + smart selection).
    private var resolveNextStream: ((NuvioVideo) async -> PreparedNextStream?)?

    // MARK: - Post-Play Recommendations
    @Published var postPlayState = PostPlayRecommendationUiState()
    let postPlayController = PostPlayRecommendationController()

    var isNextEpisodeMetadataResolved: Bool {
        guard let meta = activeMeta, meta.isSeries else { return true }
        return !seriesEpisodes.isEmpty || currentEpisodeVideo != nil
    }
    private var isAdvanceInFlight: Bool = false
    private var autoHiddenNextEpisodeCard = false
    private var nextEpisodeAutoHideDeadline: Date?
    private var nextEpisodeAutoPlayDeadline: Date?
    private var autoPlayNextEnabled = false
    private var autoPlayNextCountdownSeconds = 10
    /// Fallback when IntroDB has no ending marker: show the Next Episode card
    /// this many seconds before the end. When an ending skip exists, the card
    /// arms at the same moment as Skip Ending instead.
    private static let nextCardLeadSeconds: Double = 120
    private static let nextEpisodeAutoHideSeconds = 10
    /// Same lead-in used by skip-segment detection so both cards arm together.
    private static let skipSegmentStartLead: Double = 0.35

    /// Owns Aether (default) and the one-way MPV compatibility fallback.
    var sessionCoordinator: PlaybackSessionCoordinator
    /// Convenience: libmpv Metal host (fallback / forced MPV).
    var playerController: MPVPlayerViewController { sessionCoordinator.mpvController }
    /// Aether surface host.
    var aetherController: AetherPlaybackController? { sessionCoordinator.aetherController }
    /// Which backend is driving the current (or next) stream.
    @Published private(set) var activeEngineKind: PlayerEngineKind = .aether
    /// Short on-screen note after engine selection (native DV vs HDR fallback).
    @Published private(set) var hdrModeToast: String?
    @Published private(set) var playbackDebugInfo: PlaybackDebugInfo?
    @Published private(set) var playbackDebugReason = ""
    @Published private(set) var isPlaybackDebugHUDVisible = false
    @Published private(set) var isPlaybackDebugEnabled = false
    @Published private(set) var trailerDiagnostics: String?
    @Published private(set) var trailerQualityLabel: String?
    @Published private(set) var hasRenderedFirstFrame = false
    private var playbackDebugHUDBackend: PlayerEngineKind?
    private var didShowPlaybackDebugHUDForStream = false

    @Published private(set) var playbackStartupError: String? = nil

    /// Backend used for transport / poll — switches with `activeEngineKind`.
    private var engine: PlaybackEngineControlling {
        sessionCoordinator.activeEngine
    }

    private var pollTimer: Timer?
    private var controlsHideTimer: Timer?
    private var hasLoaded = false
    private var didShutdown = false
    private var isTrailerPlaybackSession = false
    var activeMeta: NuvioMeta?
    private var activeStreamURL: String?
    private var activeHTTPHeaders: [String: String] = [:]
    private var activePlaybackOrigin: PlaybackOrigin = .main
    private(set) var activeBingeGroup: String?
    private var activeAddonName: String?
    private var activeProviderName: String?
    private var activeFilename: String?
    private var activeCacheFileIdentity: PlaybackCacheFileIdentity?
    private var activeVideoSize: Int64?
    private var livePlaybackHasStarted = false
    private var liveBufferingBeganAt: Date?
    /// HLS playlist refreshes briefly report loading during healthy playback.
    /// Only surface a spinner when that state persists long enough to be a stall.
    private static let liveBufferingIndicatorDelay: TimeInterval = 1.25
    /// Episode being played, parsed from the subtitle line ("S1 · E3 · Title")
    /// DetailsScreen builds; nil for movies/trailers. Persisted with Continue
    /// Watching so the Home hero can say which episode is in progress.
    private var activeEpisodeNumbers: (season: Int, episode: Int)?
    private var pendingResumeSeconds: Double?
    private var didApplyResume = false
    private var pendingExternalSubtitles: [NuvioSubtitle] = []
    private var didAddExternalSubtitles = false
    private var addedExternalSubtitleURLs: Set<String> = []
    private var pendingSelectedExternalSubtitleURL: String?
    private var subtitleFetchTask: Task<Void, Never>?
    private var activeTrackSelectionKey: String?
    private var pendingTrackSelection: PlayerTrackSelection?
    /// The latest explicit audio/subtitle choice for this player session. Unlike
    /// the persistent per-episode entry, this follows seamless episode advances.
    private var sessionTrackSelection: PlayerTrackSelection?
    private var didApplySavedAudioSelection = false
    private var didApplySavedSubtitleSelection = false
    private var didApplyAudioPreference = false
    private var didApplySubtitlePreference = false
    /// Progressive subtitle fetches may improve an automatic match, but must
    /// never replace a subtitle (including Off) explicitly chosen in the panel.
    private var hasExplicitSubtitleSelection = false
    private var lastProgressSave = Date.distantPast
    private var lastSavedProgressPosition: Double?
    /// Last coherent, non-EOF MPV sample. Forced lifecycle saves use this
    /// instead of a transient reattach/keep-open sample that can report the
    /// title's full duration as its current position.
    private var lastStablePlaybackTime: PlayerTime?
    /// A backend can briefly keep publishing its pre-seek timestamp after an
    /// explicit skip. Keep the user's landing point authoritative until the
    /// backend confirms it (or the short settling window expires).
    private var explicitSeekProgressCheckpoint: (time: PlayerTime, createdAt: Date)?
    private static let explicitSeekSettleWindow: TimeInterval = 5
    /// Trakt accepts a started scrobble followed by periodic pause updates.
    /// Keep that cadence lower than local persistence so normal playback never
    /// produces a request every five seconds.
    private var didStartTraktScrobble = false
    private var didQueueTraktStop = false
    private var lastTraktProgressReport = Date.distantPast
    private var traktProgressTask: Task<Void, Never>?
    private static let traktProgressReportInterval: TimeInterval = 30
    private var controlsAutoHideSuspended = false
    private var skipIntervals: [SkipInterval] = []
    private var autoHiddenSkipIntervalId: String?
    /// Segments the user skipped during this playback item. Keep these hidden
    /// even while the asynchronous seek is still reporting the old position.
    private var dismissedSkipIntervalIds: Set<String> = []
    private var skipSegmentAutoHideDeadline: Date?
    private var skipIntervalLoadTask: Task<Void, Never>?
    private var sourcesFetchTask: Task<Void, Never>?
    private var sourcesLoadGeneration: UInt64 = 0
    private var didSeedIntroDBSeasonTemplate = false
    private var didRefreshIntroDBForKnownDuration = false
    private static let skipSegmentAutoHideSeconds = 10
    private var seekRepeatTimer: Timer?
    private var seekHoldStartDate: Date?
    private var seekHoldDirection: Double = 1.0
    /// Hold-to-seek tick rate (~10Hz) for smooth, responsive trick play advance.
    private static let seekRepeatInterval: TimeInterval = 0.10

    // MARK: Scrub / seek accumulation

    /// Coarse D-pad jump while scrubbing (seconds). Pan zooms, presses hop.
    private var scrubJumpSeconds: Double { max(Double(seekStepSeconds) * 4, 60) }
    private var scrubValue: Double?
    private var lastScrubPublish = Date.distantPast
    private var scrubTimeoutTask: Task<Void, Never>?
    private let suppliedScrubThumbnailProvider: (any ScrubThumbnailProviding)?
    private var scrubThumbnailProvider: (any ScrubThumbnailProviding)? {
        if let supplied = suppliedScrubThumbnailProvider { return supplied }
        switch sessionCoordinator.activeBackend {
        case .aether:
            return aetherController
        case .mpv:
            return sessionCoordinator.mpvController
        }
    }
    private var scrubThumbnailTask: Task<Void, Never>?
    private var scrubThumbnailTaskInteractionToken: UInt64?
    private var pendingScrubThumbnailSeconds: Double?
    private var scrubThumbnailGeneration: UInt64 = 0
    private var scrubThumbnailInteractionToken: UInt64 = 0
    private var scrubThumbnailTargetSeconds: Double?
    private var lastScrubTargetSeconds: Double?
    private var speculativePrefetchTask: Task<Void, Never>?
    private var scrubLastDx: CGFloat = 0
    private var scrubEngagedThisStroke = false
    private var suppressMoveUntil = Date.distantPast
    var moveSuppressed: Bool { Date() < suppressMoveUntil }
    private enum TouchIntent { case undecided, scrub, consumed }
    private var touchIntent: TouchIntent = .undecided
    private var wheelLastAngle: Double?
    private let wheelSecondsPerRevolution: Double = 24
    private var gcTouchDown = false
    private var gcTouchStartTime = Date()
    private var gcPanFiredThisTouch = false
    private var controllerConnectObserver: NSObjectProtocol?
    private var peekTask: Task<Void, Never>?
    private var seekDebounceTask: Task<Void, Never>?
    private var lastNudgeAt: Date?
    private var nudgeStreak = 0
    private var didConfigureWheelTracking = false
    private var diskCachedBufferedPosition: Double = 0
    private var diskCachedBytes: Int64 = 0
    private var diskCacheTotalBytes: Int64 = 0
    private var diskCachePollTask: Task<Void, Never>?

    /// Best estimate of the real title's length, captured at load time from the
    /// existing Continue Watching entry (most reliable) or the metadata runtime.
    /// Used to recognize an expired-link "slate" the stream host plays in place
    /// of the movie — see `loadedStreamLooksLikeReplacement()`.
    private var expectedDurationSeconds: Double?
    private let trailerResolver = YouTubeTrailerResolver.shared
    private var trailerResolveTask: Task<Void, Never>?
    private var trickplayResolveTask: Task<Void, Never>?
    private(set) var activeTrickplayURL: URL?
    @Published private(set) var didDetectReplacementStream = false
    private var replacementStreamHits = 0
    private static let replacementConfirmTicks = 1   // Immediate detection to avoid showing expired slate frame

    /// Re-resolves a fresh stream for the current title/episode when a link
    /// expires or a source fails. `excludedURLs` are links already tried this
    /// session so failover never loops a dead source. Nil disables recovery.
    var reloadCurrentStream: ((_ episode: NuvioVideo?, _ excludedURLs: [String]) async -> PreparedNextStream?)?
    /// Streams playable sources into the Sources panel as add-ons respond.
    var fetchPlaybackSources: ((_ contentId: String, _ type: String) -> AsyncStream<[NuvioStream]>)?
    /// Resolves a user-picked source into a ready stream (debrid + URL).
    var resolvePlaybackStream: ((
        _ stream: NuvioStream,
        _ contentId: String,
        _ subtitleLine: String
    ) async -> PreparedNextStream?)?
    private var reloadAttempts = 0
    @Published private(set) var isReloadingStream = false
    private static let maxReloadAttempts = 3

    // MARK: Load watchdog + source failover

    /// True while a mid-session source switch is resolving/loading.
    @Published private(set) var isSwitchingSource = false
    /// What that switch is doing, shown beside the loading spinner.
    @Published private(set) var switchingSourceMessage = "Trying next source…"
    /// Brief on-screen notice ("Source failed — trying another").
    @Published var playerToast: String?
    /// URLs that failed to load/play this session (watchdog, mpv error, slate).
    private var failedStreamURLs: Set<String> = []
    private var currentLoadStarted = false
    private var retriedLiveURLs: Set<String> = []
    /// True from the moment a new URL is applied until that stream actually
    /// starts. The engine reports neither "loading" nor "playing" while it tears
    /// the old pipeline down and opens the new one, which the poll would
    /// otherwise read as `.paused` — a black screen with no spinner, and the
    /// pause metadata sheet arming behind it.
    private var isAwaitingStreamStart = false
    private(set) var loadWatchdogTask: Task<Void, Never>?
    private var isFailingOver = false
    private var toastClearTask: Task<Void, Never>?
    /// A source that hasn't started within this long is treated as dead.
    private let loadTimeoutSeconds: UInt64 = 30

    init(
        sessionCoordinator suppliedCoordinator: PlaybackSessionCoordinator? = nil,
        scrubThumbnailProvider: (any ScrubThumbnailProviding)? = nil
    ) {
        suppliedScrubThumbnailProvider = scrubThumbnailProvider
        // A PiP restore creates this view model after the app has already
        // dismissed the original PlayerView. Adopt the retained coordinator
        // before SwiftUI mounts a surface so it never binds a fresh, empty
        // Aether controller for the first render pass.
        sessionCoordinator = suppliedCoordinator ?? PictureInPictureManager.shared.activeCoordinator
            ?? PlaybackSessionCoordinator()
        activeEngineKind = sessionCoordinator.activeBackend
        sessionCoordinator.prepareControllers()
        bindSessionCoordinatorCallbacks()
        setupPipObservers()
        postPlayController.$uiState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.postPlayState = state
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    private func bindSessionCoordinatorCallbacks() {
        coordinatorErrorCancellable?.cancel()
        playbackStartupError = sessionCoordinator.lastLoadError
        coordinatorErrorCancellable = sessionCoordinator.$lastLoadError
            .sink { [weak self] error in
                guard let self else { return }
                self.playbackStartupError = error
                if let error {
                    self.loadWatchdogTask?.cancel()
                    self.loadWatchdogTask = nil
                    self.isAwaitingStreamStart = false
                    self.status = .error(error)
                }
            }

        let coordinator = sessionCoordinator
        let generation = coordinator.loadGeneration
        let suspend: (Int64, Int64) -> Void = { [weak self, weak coordinator] positionMs, durationMs in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self, let coordinator,
                      self.sessionCoordinator === coordinator,
                      coordinator.loadGeneration == generation else { return }
                self.playbackDidSuspend(positionMs: positionMs, durationMs: durationMs)
            }
        }
        let firstFrame: () -> Void = { [weak self, weak coordinator] in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self, let coordinator,
                      self.sessionCoordinator === coordinator,
                      coordinator.loadGeneration == generation else { return }
                if !self.hasRenderedFirstFrame {
                    self.hasRenderedFirstFrame = true
                }
                self.tick()
            }
        }
        playerController.onPlaybackSuspended = suspend
        playerController.onFirstFrameReady = firstFrame
        aetherController?.onPlaybackSuspended = suspend
        aetherController?.onFirstFrameReady = firstFrame
        aetherController?.subtitleTranslationState.onFirstOutcome = { [weak self] outcome in
            self?.handleAISubtitleTranslationOutcome(outcome)
        }
        sessionCoordinator.onAetherControllerChanged = { [weak self] _ in
            guard let self else { return }
            self.bindSessionCoordinatorCallbacks()
            PictureInPictureManager.shared.refreshController(for: self.sessionCoordinator)
        }
        playerController.subtitleTranslationState.onFirstOutcome = { [weak self] outcome in
            self?.handleAISubtitleTranslationOutcome(outcome)
        }
        sessionCoordinator.onHandoffToast = { [weak self] message in
            if let self {
                self.bindSessionCoordinatorCallbacks()
                PictureInPictureManager.shared.refreshController(for: self.sessionCoordinator)
            }
            self?.hdrModeToast = message
            self?.showPlayerToast(message)
            self?.activeEngineKind = self?.sessionCoordinator.activeBackend ?? .mpv
            self?.resetScrubThumbnailState()
            if self?.isPlaybackDebugEnabled == true {
                self?.playbackDebugHUDBackend = nil
                self?.isPlaybackDebugHUDVisible = true
            }
        }
    }

    var currentErrorDiagnostic: PlaybackErrorDiagnostic? {
        if let startupError = playbackStartupError {
            return PlaybackErrorDiagnostic.analyze(
                errorMessage: startupError,
                streamURL: activeStreamURL.flatMap(URL.init(string:)),
                addonName: activeAddonName,
                provider: activeProviderName
            )
        }
        if case .error(let message) = status {
            return PlaybackErrorDiagnostic.analyze(
                errorMessage: message,
                streamURL: activeStreamURL.flatMap(URL.init(string:)),
                addonName: activeAddonName,
                provider: activeProviderName
            )
        }
        return nil
    }

    func retryPlaybackStartup() {
        guard !didShutdown else { return }
        playbackStartupError = nil
        sessionCoordinator.retryLastLoad()
        activeEngineKind = sessionCoordinator.activeBackend
        guard sessionCoordinator.lastLoadError == nil else { return }
        status = .buffering
        isAwaitingStreamStart = true
        currentLoadStarted = false
        startPolling()
        startLoadWatchdog()
        hdrModeToast = sessionCoordinator.statusToast
    }

    func retryCurrentPlayback() {
        if playbackStartupError != nil {
            retryPlaybackStartup()
        } else if case .error(let message) = status {
            reloadAttempts = 0
            isFailingOver = false
            attemptFailover(reason: message, toast: "Retrying stream...")
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        let coordinator = sessionCoordinator
        let poll = pollTimer
        let hide = controlsHideTimer
        trailerResolveTask?.cancel()
        trickplayResolveTask?.cancel()
        subtitleFetchTask?.cancel()
        scrubThumbnailTask?.cancel()
        Task { @MainActor in
            poll?.invalidate()
            hide?.invalidate()
            if !PictureInPictureManager.shared.isPictureInPictureActive {
                coordinator.stopAll()
            }
        }
    }

    func load(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String] = [:],
        externalSubtitles: [NuvioSubtitle] = [],
        resumeFrom: Double?,
        playbackOrigin: PlaybackOrigin = .main,
        bingeGroup: String? = nil,
        addonName: String? = nil,
        provider: String? = nil,
        filename: String? = nil,
        videoSize: Int64? = nil,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        trickplayURL: URL? = nil,
        currentEpisode: NuvioVideo? = nil
    ) {
        let isTrailerPlayback = subtitle == PlaybackMarkers.trailerSubtitle
        // Keep this session-level flag authoritative for tracking decisions.
        // The trailer uses the movie's metadata so checking only the current
        // subtitle can accidentally send the movie identity to Trakt.
        isTrailerPlaybackSession = isTrailerPlayback
        activePlaybackOrigin = playbackOrigin
        activeBingeGroup = bingeGroup
        activeAddonName = addonName
        activeProviderName = provider
        activeFilename = filename
        activeVideoSize = videoSize
        activeCacheFileIdentity = cacheFileIdentity
        activeTrickplayURL = trickplayURL
        if !hasLoaded { sessionTrackSelection = nil }

        // Adopt active Picture in Picture session if already playing this content
        let pipManager = PictureInPictureManager.shared
        if let activeCoord = pipManager.activeCoordinator,
           pipManager.activeContext?.url == url,
           pipManager.isPictureInPictureActive
            || pipManager.isRestoringUIInProgress
            || sessionCoordinator === activeCoord {
            if cacheFileIdentity == nil {
                activeCacheFileIdentity = pipManager.activeContext?.cacheFileIdentity
            }
            self.sessionCoordinator = activeCoord
            bindSessionCoordinatorCallbacks()
            self.activeEngineKind = activeCoord.activeBackend
            self.hasLoaded = true
            activeCoord.aetherController?.rebindSurface()
            applyStreamState(
                url: url,
                meta: meta,
                subtitle: subtitle,
                httpHeaders: httpHeaders,
                externalSubtitles: externalSubtitles,
                // The retained Aether clock is authoritative on PiP restore;
                // the original launch resume would seek the adopted session
                // backward during the first tick.
                resumeFrom: nil,
                currentEpisode: currentEpisode
            )
            tick()
            startPolling()
            return
        }

        applyStreamState(
            url: url,
            meta: meta,
            subtitle: subtitle,
            httpHeaders: httpHeaders,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            currentEpisode: currentEpisode
        )
        guard !hasLoaded else { return }
        hasLoaded = true

        if isTrailerPlayback, let youtubeId = Self.youtubeVideoId(from: url) {
            let title = meta.name
            let year = meta.year.map(String.init)
            let resolver = trailerResolver

            trailerResolveTask?.cancel()
            trailerResolveTask = Task { [weak self] in
                var resolvedUrl = await resolver.resolve(for: meta)
                if resolvedUrl == nil {
                    resolvedUrl = await resolver.resolve(
                        youtubeVideoId: youtubeId,
                        title: title,
                        year: year
                    )
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self else { return }
                    guard let playbackSource = resolvedUrl else {
                        self.status = .error("No playable trailer stream was found for this title.")
                        return
                    }
                    self.activeStreamURL = playbackSource.videoUrl
                    self.activeHTTPHeaders = playbackSource.requestHeaders
                    self.trailerQualityLabel = playbackSource.qualityLabel
                    self.trailerDiagnostics = playbackSource.diagnostics
                    print("[TrailerPlayback] Resolved \(playbackSource.qualityLabel ?? "stream"): \(playbackSource.diagnostics ?? "")")
                    // Trailers with optional separate audio URL require MPV.
                    guard let videoURL = URL(string: playbackSource.videoUrl) else {
                        self.status = .error("Invalid trailer URL.")
                        return
                    }
                    let audioURL = playbackSource.audioUrl.flatMap(URL.init(string:))
                    let request = PlaybackLoadRequest(
                        videoURL: videoURL,
                        audioURL: audioURL,
                        httpHeaders: playbackSource.requestHeaders,
                        externalSubtitles: [],
                        matchContentEnabled: true,
                        cacheProfile: PlaybackCacheProfile.fromSettings(
                            ProfileSettings.current.string(forKey: SettingsKey.networkCache)
                        ),
                        assMode: .strip,
                        isAnime: meta.isAnime,
                        playbackRate: 1,
                        aspectMode: self.aspectMode,
                        streamName: title.isEmpty ? nil : title,
                        streamDescription: PlaybackMarkers.trailerSubtitle,
                        artworkURL: self.resolveArtworkURL(for: meta, episode: nil, isTrailer: true)
                    )
                    self.sessionCoordinator.load(request)
                    self.activeEngineKind = self.sessionCoordinator.activeBackend
                    self.startPolling()
                }
            }
            return
        }

        beginPrimaryLoad(
            for: url,
            httpHeaders: httpHeaders,
            streamName: title.isEmpty ? nil : title,
            streamDescription: subtitle.isEmpty ? nil : subtitle,
            filename: url.lastPathComponent
        )
        videoNaturalSize = .zero
        startPolling()
        configureWheelTrackingIfNeeded()
        startLoadWatchdog()

        if !isTrailerPlayback {
            let context = ActivePlaybackContext(
                url: url,
                meta: meta,
                subtitle: subtitle,
                httpHeaders: httpHeaders,
                cacheFileIdentity: activeCacheFileIdentity,
                externalSubtitles: externalSubtitles,
                resumeFrom: resumeFrom,
                episodes: seriesEpisodes,
                currentEpisode: currentEpisodeVideo,
                autoPlayNextEnabled: autoPlayNextEnabled,
                autoPlayNextCountdownSeconds: autoPlayNextCountdownSeconds,
                playbackOrigin: activePlaybackOrigin
            )
            PictureInPictureManager.shared.registerSession(
                coordinator: sessionCoordinator,
                context: context
            )
        }
    }

    /// Aether-first policy with MPV one-way fallback. Native DV remux is disabled
    /// while Aether owns Dolby Vision (including live P7→8.1).
    private func beginPrimaryLoad(
        for url: URL,
        httpHeaders: [String: String] = [:],
        streamName: String?,
        streamDescription: String?,
        filename: String?,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        artworkURL: URL? = nil
    ) {
        let frameRateMode = ProfileSettings.current.string(forKey: SettingsKey.frameRateMatching) ?? "Always"
        let matchContent = frameRateMode.caseInsensitiveCompare("Off") != .orderedSame
        let contentId = activeMeta?.imdbId
            ?? (activeMeta?.id.hasPrefix("tt") == true ? activeMeta?.id : nil)
            ?? activeMeta?.id
        let canonicalKey = TrickplayDiskCache.canonicalKey(
            contentId: contentId,
            season: activeEpisodeNumbers?.season,
            episode: activeEpisodeNumbers?.episode,
            duration: expectedDurationSeconds,
            fallbackURL: url.absoluteString
        )
        let isAnime = activeMeta?.isAnime == true
            || NuvioMeta.isAnimeStream(filename: filename, streamName: streamName, streamDescription: streamDescription)
        let resolvedArtwork = artworkURL ?? resolveArtworkURL(for: activeMeta, episode: currentEpisodeVideo, isTrailer: isTrailerPlaybackSession)
        let request = PlaybackLoadRequest(
            videoURL: url,
            audioURL: nil,
            resumePositionSeconds: pendingResumeSeconds,
            httpHeaders: httpHeaders,
            externalSubtitles: pendingExternalSubtitles,
            preferredAudioLanguages: preferredAudioLanguageCodes(),
            preferredSubtitleLanguages: preferredSubtitleLanguageCodes(),
            matchContentEnabled: matchContent,
            cacheProfile: PlaybackCacheProfile.fromSettings(
                ProfileSettings.current.string(forKey: SettingsKey.networkCache)
            ),
            assMode: PlaybackASSMode.fromSettings(
                ProfileSettings.current.string(forKey: SettingsKey.assOverrideMode)
            ),
            isAnime: isAnime,
            autoplay: true,
            playbackRate: playbackSpeed.rawValue,
            aspectMode: aspectMode,
            subtitleDelaySeconds: Double(subtitleDelayMs) / 1_000,
            audioDelaySeconds: Double(audioDelayMs) / 1_000,
            audioGainDB: Double(audioAmplificationDb),
            streamName: streamName,
            streamDescription: streamDescription,
            filename: filename,
            canonicalMediaKey: canonicalKey,
            cacheFileIdentity: cacheFileIdentity ?? activeCacheFileIdentity,
            trickplayURL: activeTrickplayURL,
            artworkURL: resolvedArtwork
        )
        sessionCoordinator.load(
            request,
            requiresMPVAudioControls: audioAmplificationDb > 0
        )

        // Launch asynchronous storyboard resolver (direct URL or community trickplay)
        trickplayResolveTask?.cancel()
        let directTPURL = activeTrickplayURL
        let sNum = activeEpisodeNumbers?.season
        let eNum = activeEpisodeNumbers?.episode
        let expDur = expectedDurationSeconds
        trickplayResolveTask = Task { [weak self, activeGen = self.sessionCoordinator.loadGeneration] in
            let provider = await TrickplayResolver.shared.resolve(
                contentId: contentId,
                season: sNum,
                episode: eNum,
                duration: expDur,
                directTrickplayURL: directTPURL
            )
            guard let self, let provider, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.sessionCoordinator.loadGeneration == activeGen else { return }
                self.sessionCoordinator.setExternalTrickplayProvider(provider)
            }
        }
        // The coordinator owns initial seek and subtitle registration on both
        // backends; later progressive subtitle results still flow through the
        // incremental path below.
        didApplyResume = (request.resumePositionSeconds ?? 0) > 5
        didAddExternalSubtitles = true
        addedExternalSubtitleURLs.formUnion(request.externalSubtitles.map(\.url))
        activeEngineKind = sessionCoordinator.activeBackend
        hdrModeToast = sessionCoordinator.statusToast
        if let toast = sessionCoordinator.statusToast {
            showPlayerToast(toast)
        }
        print("[Player] Engine policy: \(sessionCoordinator.lastPolicyReason)")
    }

    private func preferredAudioLanguageCodes() -> [String] {
        SubtitleLanguagePreferences.preferredAudioLanguage(meta: activeMeta).map { [$0] } ?? []
    }

    private func preferredSubtitleLanguageCodes() -> [String] {
        guard SubtitleLanguagePreferences.smartMatchingEnabled() else { return [] }
        return SubtitleLanguagePreferences.orderedFromDefaults()
    }

    private static func isLiveContentType(_ type: String) -> Bool {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "channel", "channels", "live", "livetv", "live-tv", "live_tv", "iptv", "radio", "sports", "sport", "stream", "streams", "event", "events", "broadcast", "feed":
            return true
        default:
            return false
        }
    }

    private static func isLiveStream(meta: NuvioMeta, url: URL?) -> Bool {
        if isLiveContentType(meta.type) { return true }
        let id = meta.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.hasPrefix("iptv:") || id.hasPrefix("live:") || id.hasPrefix("channel:") || id.hasPrefix("stream:") {
            return true
        }
        let name = meta.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("now:") || name.hasPrefix("live:") || name.hasPrefix("[live]") || name.hasPrefix("(live)") {
            return true
        }
        if let urlString = url?.absoluteString.lowercased() {
            if urlString.contains("/live/") || urlString.contains("/iptv/") || urlString.contains("live.m3u8") {
                return true
            }
        }
        return false
    }

    /// Resolves the remote artwork URL for Now Playing identity card.
    /// Prefers the episode thumbnail for series episodes, falling back to show backdrop/poster.
    /// Prefers movie poster, falling back to movie backdrop for movies.
    func resolveArtworkURL(for meta: NuvioMeta?, episode: NuvioVideo?, isTrailer: Bool) -> URL? {
        guard let meta else { return nil }
        if !isTrailer, let thumb = episode?.thumbnail?.trimmingCharacters(in: .whitespacesAndNewlines), !thumb.isEmpty {
            if let url = URL(string: thumb) {
                return url
            }
        }
        if meta.isSeries {
            if let background = meta.backgroundUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !background.isEmpty, let url = URL(string: background) {
                return url
            }
            if let poster = meta.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !poster.isEmpty, let url = URL(string: poster) {
                return url
            }
        } else {
            if let poster = meta.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !poster.isEmpty, let url = URL(string: poster) {
                return url
            }
            if let background = meta.backgroundUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !background.isEmpty, let url = URL(string: background) {
                return url
            }
        }
        return nil
    }

    /// Applies all per-stream state for a title/episode. Shared by the initial
    /// `load` and the in-place `replaceStream` used for a seamless next-episode
    /// advance, so both paths reset resume/track/subtitle state identically.
    private func applyStreamState(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String] = [:],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        currentEpisode: NuvioVideo? = nil,
        preserveSessionPreferences: Bool = false
    ) {
        let isTrailerPlayback = subtitle == PlaybackMarkers.trailerSubtitle
        isTrailerPlaybackSession = isTrailerPlayback
        isPlaybackDebugEnabled = ProfileSettings.current.bool(forKey: SettingsKey.playbackDebug)
        if isPlaybackDebugEnabled {
            var info = PlaybackDebugInfo(
                player: "Selecting player…",
                pipeline: "Starting",
                videoCodec: "Detecting",
                dynamicRange: "Detecting",
                resolution: "Detecting",
                frameRate: "Detecting",
                audio: "Detecting"
            )
            enrichDebugInfoWithSource(&info)
            playbackDebugInfo = info
            playbackDebugReason = "Waiting for playback metadata"
            isPlaybackDebugHUDVisible = true
            playbackDebugHUDBackend = nil
            didShowPlaybackDebugHUDForStream = false
        } else {
            playbackDebugInfo = nil
            playbackDebugReason = ""
            isPlaybackDebugHUDVisible = false
            playbackDebugHUDBackend = nil
            didShowPlaybackDebugHUDForStream = false
        }
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        isLoadingExternalSubtitles = false
        self.title = meta.name
        self.subtitle = subtitle
        self.isLiveStream = Self.isLiveStream(meta: meta, url: url)
        self.livePlaybackHasStarted = false
        self.liveBufferingBeganAt = nil
        self.status = .buffering
        self.isAwaitingStreamStart = true
        // A replaced file keeps the previous file's position/duration cached in
        // the controller until mpv publishes the new timeline. Clear the public
        // timeline now so end-of-episode UI cannot be re-armed for the new episode.
        self.time = PlayerTime()
        self.clock.position = 0
        self.clock.duration = 0
        self.clock.buffered = 0
        self.diskCachedBufferedPosition = 0
        self.diskCachePollTask?.cancel()
        self.diskCachePollTask = nil
        self.clock.scrubTarget = nil
        self.resetScrubSession()
        self.pendingSeekDelta = 0
        self.hidePeek()
        self.activeMeta = meta
        if let currentEpisode {
            self.currentEpisodeVideo = currentEpisode
        }
        self.activeStreamURL = url.absoluteString
        self.activeHTTPHeaders = httpHeaders
        if !isTrailerPlayback {
            postPlayController.start(
                contentId: meta.id,
                contentType: meta.isSeries ? "series" : meta.type,
                meta: meta
            )
        } else {
            postPlayController.stop()
        }
        self.activeEpisodeNumbers = isTrailerPlayback
            ? nil
            : Self.episodeNumbers(fromSubtitle: subtitle)
                ?? Self.episodeNumbers(fromStreamURL: url.absoluteString, isSeries: meta.isSeries)
        if currentEpisodeVideo == nil, !isTrailerPlayback, meta.isSeries, let numbers = self.activeEpisodeNumbers {
            self.currentEpisodeVideo = meta.videos?.first(where: { $0.season == numbers.season && $0.episode == numbers.episode })
        } else if !meta.isSeries {
            self.currentEpisodeVideo = nil
        }
        let selectionKey = isTrailerPlayback
            ? nil
            : PlayerTrackSelectionStore.key(meta: meta, episode: self.activeEpisodeNumbers)
        let savedSelection = selectionKey.flatMap { PlayerTrackSelectionStore.selection(for: $0) }
        if sessionTrackSelection == nil { sessionTrackSelection = savedSelection }
        let effectiveSelection = Self.effectiveTrackSelection(
            stored: savedSelection,
            session: sessionTrackSelection,
            externalSubtitles: externalSubtitles
        )
        self.activeTrackSelectionKey = selectionKey
        self.pendingTrackSelection = effectiveSelection
        self.pendingResumeSeconds = (isTrailerPlayback || isLiveStream) ? nil : resumeFrom
        self.didApplyResume = false
        self.lastStablePlaybackTime = nil
        self.explicitSeekProgressCheckpoint = nil
        self.didStartTraktScrobble = false
        self.didQueueTraktStop = false
        self.lastTraktProgressReport = .distantPast
        self.expectedDurationSeconds = isTrailerPlayback ? nil : Self.expectedDuration(for: meta)
        self.didDetectReplacementStream = false
        self.replacementStreamHits = 0
        self.hasRenderedFirstFrame = false
        // The full list stays browsable in the subtitle panel; only smart-matched
        // ones are eagerly loaded into mpv (loading all would fetch dozens of files).
        self.availableExternalSubtitles = isTrailerPlayback ? [] : externalSubtitles
        let smartMatched = isTrailerPlayback || effectiveSelection?.subtitle != nil
            ? []
            : Self.smartMatchedSubtitles(in: externalSubtitles)
        self.pendingExternalSubtitles = Self.subtitlesToPreload(
            smartMatched: smartMatched,
            savedSelection: effectiveSelection,
            availableExternalSubtitles: externalSubtitles
        )
        self.didAddExternalSubtitles = pendingExternalSubtitles.isEmpty
        self.addedExternalSubtitleURLs = []
        self.pendingSelectedExternalSubtitleURL = nil
        self.isAISubtitleTranslationManuallyEnabled = false
        if !preserveSessionPreferences {
            self.subtitleDelayMs = 0
            self.audioDelayMs = 0
            self.audioAmplificationDb = 0
        }
        self.skipIntervals = []
        self.didSeedIntroDBSeasonTemplate = false
        self.didRefreshIntroDBForKnownDuration = false
        self.activeSkipInterval = nil
        self.skipSegmentCountdown = nil
        self.autoHiddenSkipIntervalId = nil
        self.dismissedSkipIntervalIds = []
        self.skipSegmentAutoHideDeadline = nil
        self.skipIntervalLoadTask?.cancel()
        self.didApplySavedAudioSelection = effectiveSelection?.audio == nil
        self.didApplySavedSubtitleSelection = effectiveSelection?.subtitle == nil
        self.didApplyAudioPreference = false
        self.didApplySubtitlePreference = false
        self.hasExplicitSubtitleSelection = false
        loadSkipIntervalsIfNeeded(meta: meta, isTrailerPlayback: isTrailerPlayback)
    }

    /// Starts a subtitle-only refresh independent of stream resolution. Results
    /// merge live into `availableExternalSubtitles`, so an already-open player
    /// Settings panel updates without closing or restarting playback.
    func fetchExternalSubtitles(contentId: String, type: String) {
        subtitleFetchTask?.cancel()
        guard subtitle != PlaybackMarkers.trailerSubtitle else {
            isLoadingExternalSubtitles = false
            return
        }

        isLoadingExternalSubtitles = true
        subtitleFetchTask = Task { @MainActor [weak self] in
            let repository = CinemetaCatalogRepository()
            for await subtitles in repository.subtitlesProgressively(id: contentId, type: type) {
                guard let self, !Task.isCancelled else { return }
                self.mergeExternalSubtitles(subtitles)
            }
            guard let self, !Task.isCancelled else { return }
            self.isLoadingExternalSubtitles = false
            self.subtitleFetchTask = nil
        }
    }

    private func mergeExternalSubtitles(_ fetched: [NuvioSubtitle]) {
        var seen = Set(availableExternalSubtitles.map(\.url))
        let newSubtitles = fetched.filter { seen.insert($0.url).inserted }
        guard !newSubtitles.isEmpty else { return }
        availableExternalSubtitles += newSubtitles

        let smartMatched = Self.smartMatchedSubtitles(in: newSubtitles)
        for subtitle in smartMatched where !pendingExternalSubtitles.contains(where: { $0.url == subtitle.url }) {
            pendingExternalSubtitles.append(subtitle)
        }
        if !smartMatched.isEmpty {
            if pendingTrackSelection?.subtitle == nil, !hasExplicitSubtitleSelection {
                didApplySubtitlePreference = false
            }
            didAddExternalSubtitles = false
            addPendingExternalSubtitlesIfNeeded()
        }
    }

    // MARK: - Next episode

    /// Supplies the series context and the resolver that turns a next episode
    /// into a ready-to-play stream. Called by PlayerView once per presented
    /// episode; recomputed after every in-place advance.
    func configureNextEpisode(
        episodes: [NuvioVideo],
        current: NuvioVideo?,
        autoPlayEnabled: Bool,
        autoPlayCountdownSeconds: Int,
        resolver: @escaping (NuvioVideo) async -> PreparedNextStream?
    ) {
        seriesEpisodes = episodes
        currentEpisodeVideo = current
        autoPlayNextEnabled = autoPlayEnabled
        autoPlayNextCountdownSeconds = max(1, autoPlayCountdownSeconds)
        resolveNextStream = resolver
        autoHiddenNextEpisodeCard = false
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil
        isAutoPlayCancelled = false
        nextEpisode = Self.nextEpisode(after: current, in: episodes)

        if let meta = activeMeta, let urlString = activeStreamURL, let url = URL(string: urlString) {
            let context = ActivePlaybackContext(
                url: url,
                meta: meta,
                subtitle: subtitle,
                httpHeaders: activeHTTPHeaders,
                cacheFileIdentity: activeCacheFileIdentity,
                externalSubtitles: pendingExternalSubtitles,
                resumeFrom: pendingResumeSeconds,
                episodes: episodes,
                currentEpisode: current,
                autoPlayNextEnabled: autoPlayEnabled,
                autoPlayNextCountdownSeconds: autoPlayCountdownSeconds,
                playbackOrigin: activePlaybackOrigin
            )
            PictureInPictureManager.shared.registerSession(
                coordinator: sessionCoordinator,
                context: context
            )
        }
    }

    private static func nextEpisode(after current: NuvioVideo?, in episodes: [NuvioVideo]) -> NuvioVideo? {
        guard let current, let index = episodes.firstIndex(where: { $0.id == current.id }) else { return nil }
        let following = episodes.index(after: index)
        guard following < episodes.endIndex else { return nil }
        return episodes
            .suffix(from: following)
            .first { episode in
                episode.season > 0 &&
                EpisodeReleasePolicy.shouldSurfaceNextEpisode(
                    watchedSeason: current.season,
                    candidateSeason: episode.season,
                    released: episode.released
                )
            }
    }

    /// Re-evaluated on every poll tick: shows the card with Skip Ending (when
    /// IntroDB has an outro) and auto-hides it like the Skip Intro card.
    private func updateNextEpisodeState() {
        guard let _ = nextEpisode,
              subtitle != PlaybackMarkers.trailerSubtitle,
              !isAdvanceInFlight,
              time.duration >= 60 else {
            clearNextEpisodeCard()
            return
        }

        guard shouldPresentNextEpisodeCard else {
            clearNextEpisodeCard()
            return
        }

        if autoHiddenNextEpisodeCard {
            if showNextEpisodeCard != showControls {
                showNextEpisodeCard = showControls
            }
            nextEpisodeAutoHideDeadline = nil
            if showControls {
                if nextEpisodeCountdown != nil { nextEpisodeCountdown = nil }
                nextEpisodeAutoPlayDeadline = nil
            } else {
            }
            return
        }

        if !showNextEpisodeCard { showNextEpisodeCard = true }

        if showControls {
            if nextEpisodeCountdown != nil { nextEpisodeCountdown = nil }
            nextEpisodeAutoHideDeadline = nil
            nextEpisodeAutoPlayDeadline = nil
            return
        }

        if nextEpisodeAutoHideDeadline == nil {
            nextEpisodeAutoHideDeadline = Date().addingTimeInterval(Double(Self.nextEpisodeAutoHideSeconds))
        }

        guard let deadline = nextEpisodeAutoHideDeadline else { return }
        let secondsLeft = deadline.timeIntervalSinceNow
        if secondsLeft <= 0.05 {
            autoHiddenNextEpisodeCard = true
            showNextEpisodeCard = false
            nextEpisodeAutoHideDeadline = nil
        }

    }

    /// Prefer IntroDB ending start so Next Episode and Skip Ending appear together.
    /// Without an ending marker, fall back to the fixed lead-before-end window.
    private var shouldPresentNextEpisodeCard: Bool {
        guard time.remaining > 0,
              time.current / time.duration >= 0.5 else {
            return false
        }
        if let ending = skipIntervals.first(where: \.isEnding) {
            return time.current >= max(ending.startTime - Self.skipSegmentStartLead, 0)
        }
        return time.remaining <= Self.nextCardLeadSeconds
    }

    private func clearNextEpisodeCard() {
        if showNextEpisodeCard { showNextEpisodeCard = false }
        if nextEpisodeCountdown != nil { nextEpisodeCountdown = nil }
        autoHiddenNextEpisodeCard = false
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil
    }

    // MARK: - IntroDB skip segments

    private func loadSkipIntervalsIfNeeded(meta: NuvioMeta, isTrailerPlayback: Bool) {
        guard !isTrailerPlayback else { return }

        let imdbId = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil)
        let expectedMetaId = meta.id
        let episodeNumbers = activeEpisodeNumbers
        skipIntervalLoadTask?.cancel()
        skipIntervalLoadTask = Task { [weak self] in
            let intervals = await IntroDBSkipService.shared.intervals(
                imdbId: imdbId,
                season: episodeNumbers?.season,
                episode: episodeNumbers?.episode,
                duration: self?.time.duration
            )
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.activeMeta?.id == expectedMetaId,
                      self.activeEpisodeNumbers?.season == episodeNumbers?.season,
                      self.activeEpisodeNumbers?.episode == episodeNumbers?.episode else {
                    return
                }
                self.skipIntervals = intervals
                if self.time.duration > 0,
                   !intervals.isEmpty,
                   intervals.allSatisfy({ $0.provider == "introdb" }) {
                    IntroDBSkipService.shared.seedSeasonTemplate(
                        imdbId: imdbId,
                        season: episodeNumbers?.season,
                        episode: episodeNumbers?.episode,
                        intervals: intervals,
                        duration: self.time.duration
                    )
                    self.didSeedIntroDBSeasonTemplate = true
                }
                self.updateSkipIntervalState()
            }
        }
    }

    private func updateSkipIntervalState() {
        if !didRefreshIntroDBForKnownDuration,
           time.duration > 0,
           let meta = activeMeta,
           let numbers = activeEpisodeNumbers {
            didRefreshIntroDBForKnownDuration = true
            let imdbId = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil)
            let expectedMetaId = meta.id
            let duration = time.duration
            skipIntervalLoadTask?.cancel()
            skipIntervalLoadTask = Task { [weak self] in
                let intervals = await IntroDBSkipService.shared.intervals(
                    imdbId: imdbId, season: numbers.season, episode: numbers.episode,
                    duration: duration
                )
                await MainActor.run {
                    guard let self,
                          !Task.isCancelled,
                          self.activeMeta?.id == expectedMetaId,
                          self.activeEpisodeNumbers?.season == numbers.season,
                          self.activeEpisodeNumbers?.episode == numbers.episode else { return }
                    self.skipIntervals = intervals
                    self.updateSkipIntervalState()
                }
            }
        }
        if !didSeedIntroDBSeasonTemplate,
           time.duration > 0,
           !skipIntervals.isEmpty,
           skipIntervals.allSatisfy({ $0.provider == "introdb" }),
           let meta = activeMeta {
            let imdbId = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil)
            IntroDBSkipService.shared.seedSeasonTemplate(
                imdbId: imdbId,
                season: activeEpisodeNumbers?.season,
                episode: activeEpisodeNumbers?.episode,
                intervals: skipIntervals,
                duration: time.duration
            )
            didSeedIntroDBSeasonTemplate = true
        }
        guard !skipIntervals.isEmpty,
              time.current > 0,
              status != .ended,
              subtitle != PlaybackMarkers.trailerSubtitle else {
            if activeSkipInterval != nil { activeSkipInterval = nil }
            if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
            return
        }

        let current = time.current
        let interval = skipIntervals.first { segment in
            current >= max(segment.startTime - 0.35, 0) && current < segment.endTime - 0.25
        }

        guard let interval else {
            if activeSkipInterval != nil { activeSkipInterval = nil }
            if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
            skipSegmentAutoHideDeadline = nil
            return
        }

        // A skip command is asynchronous. Polling can still observe the old
        // playhead for a few ticks, but a deliberately skipped segment must not
        // be armed again during this playback session.
        if dismissedSkipIntervalIds.contains(interval.id) {
            if activeSkipInterval != nil { activeSkipInterval = nil }
            if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
            skipSegmentAutoHideDeadline = nil
            return
        }

        if autoHiddenSkipIntervalId == interval.id, !showControls {
            if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
            skipSegmentAutoHideDeadline = nil
            return
        }

        if activeSkipInterval?.id != interval.id {
            activeSkipInterval = interval
            skipSegmentAutoHideDeadline = Date().addingTimeInterval(Double(Self.skipSegmentAutoHideSeconds))
            skipSegmentCountdown = Self.skipSegmentAutoHideSeconds
            autoHiddenSkipIntervalId = nil
        }

        if showControls {
            skipSegmentAutoHideDeadline = nil
            if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
            return
        }

        if skipSegmentAutoHideDeadline == nil {
            skipSegmentAutoHideDeadline = Date().addingTimeInterval(Double(Self.skipSegmentAutoHideSeconds))
            skipSegmentCountdown = Self.skipSegmentAutoHideSeconds
        }

        guard let deadline = skipSegmentAutoHideDeadline else { return }
        let secondsLeft = deadline.timeIntervalSinceNow
        if secondsLeft <= 0.05 {
            autoHiddenSkipIntervalId = interval.id
            skipSegmentCountdown = nil
            skipSegmentAutoHideDeadline = nil
        } else {
            let countdown = max(1, Int(secondsLeft.rounded(.up)))
            if skipSegmentCountdown != countdown { skipSegmentCountdown = countdown }
        }
    }

    /// Play the next episode now (the card's Play button).
    func playNextEpisode() {
        advance()
    }

    func cancelAutoPlay() {
        isAutoPlayCancelled = true
        nextEpisodeCountdown = nil
        nextEpisodeAutoPlayDeadline = nil
    }

    func dismissNextEpisodeCard(cancelAutoPlay: Bool = true) {
        if cancelAutoPlay {
            self.cancelAutoPlay()
        }
        autoHiddenNextEpisodeCard = true
        showNextEpisodeCard = false
        nextEpisodeAutoHideDeadline = nil
    }

    private func advance() {
        guard !isAdvanceInFlight,
              let next = nextEpisode,
              EpisodeReleasePolicy.hasAired(next.released),
              let resolver = resolveNextStream else { return }
        isAdvanceInFlight = true
        isAdvancingEpisode = true
        nextEpisodeCountdown = nil
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil

        // Mark the finishing episode watched. With Trakt selected its scrobble
        // history produces the remote Next Up entry; Nuvio Sync keeps the
        // existing local rollover behavior.
        if let activeMeta {
            markWatchedIfNeeded()
            if usesTraktProgress {
                reportTraktProgress(
                    meta: activeMeta,
                    playbackTime: time,
                    action: .stop,
                    force: true
                )
            } else {
                ContinueWatchingStore.saveUpNext(
                    meta: activeMeta,
                    duration: time.duration,
                    season: next.season,
                    episode: next.episode,
                    released: next.released,
                    seedSeason: resolvedEpisodeNumbers?.season
                )
            }
        }

        Task { @MainActor in
            let prepared = await resolver(next)
            guard let prepared else {
                // Couldn't resolve a stream for the next episode: disarm so the
                // ended handler doesn't retry, and fall back to the normal
                // end-of-playback flow (which returns to the details screen).
                isAdvanceInFlight = false
                isAdvancingEpisode = false
                status = .ended
                return
            }
            replaceStream(prepared: prepared, episode: next, resumeFrom: nil)
        }
    }

    /// Swaps the currently playing stream in place — mpv `loadfile` replaces the
    /// source without tearing the player down. `episode` non-nil advances to a new
    /// episode (start from 0); nil keeps the current episode (used by the expired-
    /// link reload, which resumes from `resumeFrom`).
    private func replaceStream(prepared: PreparedNextStream, episode: NuvioVideo?, resumeFrom: Double?) {
        guard let meta = activeMeta else { return }
        cancelSourcesFetch()
        applyStreamState(
            url: prepared.url,
            meta: meta,
            subtitle: prepared.subtitleLine,
            httpHeaders: prepared.httpHeaders,
            externalSubtitles: prepared.subtitles,
            resumeFrom: resumeFrom,
            currentEpisode: episode ?? currentEpisodeVideo,
            preserveSessionPreferences: true
        )
        self.activeAddonName = prepared.addonName
        self.activeProviderName = prepared.provider
        self.activeFilename = prepared.filename
        self.activeVideoSize = prepared.videoSize
        // A replacement without an explicitly proven identity must not inherit
        // the previous file's cache namespace. Next-episode resolvers may supply
        // a new identity on the prepared stream.
        self.activeCacheFileIdentity = prepared.cacheFileIdentity
        if let bg = prepared.bingeGroup, !bg.isEmpty {
            self.activeBingeGroup = bg
        }
        if let episode {
            currentEpisodeVideo = episode
            nextEpisode = Self.nextEpisode(after: episode, in: seriesEpisodes)
            isAutoPlayCancelled = false
        }
        autoHiddenNextEpisodeCard = false
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil
        isAdvanceInFlight = false
        isAdvancingEpisode = false
        isReloadingStream = false
        isSwitchingSource = false
        showControls = false

        beginPrimaryLoad(
            for: prepared.url,
            httpHeaders: prepared.httpHeaders,
            streamName: prepared.streamName,
            streamDescription: prepared.streamDescription ?? prepared.subtitleLine,
            filename: prepared.filename,
            cacheFileIdentity: prepared.cacheFileIdentity,
            artworkURL: prepared.artworkURL
        )
        videoNaturalSize = .zero
        if pollTimer == nil { startPolling() }
        startLoadWatchdog()
    }

    /// Silently recovers from an expired link / dead source: fetches another
    /// stream for the current title (excluding URLs already tried) and reloads
    /// at the last known position.
    private func recoverExpiredStream() {
        if let url = activeStreamURL { failedStreamURLs.insert(url) }
        if let meta = activeMeta {
            let numbers = resolvedEpisodeNumbers
            LastPlaybackStreamStore.remove(metaId: meta.id, season: numbers?.season, episode: numbers?.episode)
        }
        attemptFailover(
            reason: "This stream link has expired. Go back and start it again to load a fresh stream.",
            toast: nil
        )
    }

    private func surfaceExpiredStreamError() {
        isReloadingStream = false
        isFailingOver = false
        isSwitchingSource = false
        isAwaitingStreamStart = false
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        autoHiddenNextEpisodeCard = false
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil
        status = .error("This stream link has expired. Go back and start it again to load a fresh stream.")
    }

    // MARK: Load timeout watchdog

    private func startLoadWatchdog() {
        // Trailers / missing resolver: no alternate sources to fail over to.
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        guard reloadCurrentStream != nil, sessionCoordinator.lastLoadError == nil else { return }
        currentLoadStarted = false
        let targetURL = activeStreamURL
        let timeout = loadTimeoutSeconds
        loadWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled, let self,
                  self.sessionCoordinator.lastLoadError == nil,
                  !self.currentLoadStarted,
                  !self.didShutdown,
                  !self.isFailingOver,
                  self.activeStreamURL == targetURL
            else { return }
            let memReport = TVMemoryDiagnostic.detailedReport(label: "LOAD_WATCHDOG_TIMEOUT")
            print("[TVTrace] ⚠️ [LOAD_WATCHDOG_TIMEOUT] Source failed to start within \(timeout)s for url=\(targetURL ?? "nil")\n\(memReport)")
            if let url = self.activeStreamURL {
                self.failedStreamURLs.insert(url)
            }
            if let meta = self.activeMeta {
                let numbers = self.resolvedEpisodeNumbers
                LastPlaybackStreamStore.remove(metaId: meta.id, season: numbers?.season, episode: numbers?.episode)
            }
            self.attemptFailover(
                reason: "The source didn't start within \(self.loadTimeoutSeconds) seconds. Every available source was tried.",
                toast: nil
            )
        }
    }

    /// Playback has demonstrably begun for the current load — disarm the
    /// watchdog. Idempotent.
    private func markLoadStarted() {
        guard !currentLoadStarted else { return }
        currentLoadStarted = true
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
    }

    // MARK: Automatic source failover

    private var storedResumePositionForActiveItem: Double? {
        guard let meta = activeMeta else { return nil }
        if RemoteTrackingState.isProgressSourceAuthenticated {
            guard let item = TraktProgressService.currentContinueWatchingItem(for: meta),
                  !item.isUpNextEntry else { return nil }
            if meta.isSeries {
                guard let numbers = resolvedEpisodeNumbers else { return item.resumePosition }
                if let itemSeason = item.season, let itemEpisode = item.episode {
                    guard itemSeason == numbers.season && itemEpisode == numbers.episode else { return nil }
                }
            }
            return item.resumePosition
        }
        if meta.isSeries {
            let numbers = resolvedEpisodeNumbers
            return ContinueWatchingStore.resumePosition(
                for: meta,
                season: numbers?.season,
                episode: numbers?.episode,
                episodeId: currentEpisodeVideo?.id
            )
        }
        guard !WatchedStore.contains(meta: meta) else { return nil }
        return ContinueWatchingStore.item(for: meta.id)?.resumePosition
    }

    /// A stream died or never started. Remember the position, pick the next
    /// viable source (excluding failed URLs), and switch silently. The error
    /// overlay only appears when every candidate is exhausted.
    private func attemptFailover(reason: String, toast: String?) {
        guard !isFailingOver, !didShutdown else { return }
        guard let reloadCurrentStream else {
            status = .error(reason)
            return
        }
        guard reloadAttempts < Self.maxReloadAttempts else {
            isReloadingStream = false
            isFailingOver = false
            isSwitchingSource = false
            status = .error(reason)
            return
        }

        if let meta = activeMeta {
            let numbers = resolvedEpisodeNumbers
            LastPlaybackStreamStore.remove(metaId: meta.id, season: numbers?.season, episode: numbers?.episode)
        }

        let decision = LiveStreamFailoverPolicy.decide(
            isLive: isLiveStream,
            currentURL: activeStreamURL,
            retriedURLs: retriedLiveURLs,
            failedURLs: failedStreamURLs
        )
        retriedLiveURLs = decision.retriedURLs
        failedStreamURLs = decision.failedURLs

        isFailingOver = true
        isReloadingStream = true
        isSwitchingSource = true
        switchingSourceMessage = "Starting stream"
        isAwaitingStreamStart = true
        reloadAttempts += 1
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        autoHiddenNextEpisodeCard = false
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil
        status = .buffering
        engine.pausePlayback()
        if let toast { showPlayerToast(toast) }

        // Prefer the last stable position from genuine playback; if the stream failed/expired
        // before stable playback, keep the initial resume target or fall back to store.
        let stableCurrent = (lastStablePlaybackTime?.current).flatMap { $0 > 0 ? $0 : nil }
        let liveCurrent = (time.current > 5 && !loadedStreamLooksLikeReplacement()) ? time.current : nil
        let resume = stableCurrent
            ?? liveCurrent
            ?? pendingResumeSeconds
            ?? storedResumePositionForActiveItem

        let excluded = decision.exclusions
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isFailingOver = false
                // isSwitchingSource cleared in replaceStream / error paths
            }
            guard let prepared = await reloadCurrentStream(currentEpisodeVideo, excluded) else {
                self.isReloadingStream = false
                self.isSwitchingSource = false
                self.status = .error(reason)
                return
            }
            // Don't mark the new URL failed yet — the watchdog / error path will
            // if this candidate also dies before playback starts.
            self.replaceStream(prepared: prepared, episode: nil, resumeFrom: resume)
        }
    }

    private func showPlayerToast(_ message: String) {
        playerToast = message
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.playerToast == message {
                self.playerToast = nil
            }
        }
    }

    static func shouldShowAISubtitleOutcome(subtitle: String, isLiveStream: Bool) -> Bool {
        !isLiveStream && subtitle != PlaybackMarkers.trailerSubtitle
    }

    private func handleAISubtitleTranslationOutcome(_ outcome: Result<Void, Error>) {
        guard Self.shouldShowAISubtitleOutcome(
            subtitle: subtitle,
            isLiveStream: isLiveStream
        ) else { return }
        switch outcome {
        case .success:
            showPlayerToast("AI subtitles on")
        case .failure(let error):
            showPlayerToast("AI subtitles unavailable — \(error.localizedDescription)")
        }
    }

    func togglePlaybackDebugHUD() {
        let current = ProfileSettings.current.bool(forKey: SettingsKey.playbackDebug)
        let newValue = !current
        ProfileSettings.current.set(newValue, forKey: SettingsKey.playbackDebug)
        isPlaybackDebugEnabled = newValue
        if newValue {
            isPlaybackDebugHUDVisible = true
            updatePlaybackDebugHUD(from: engine)
        } else {
            isPlaybackDebugHUDVisible = false
            playbackDebugInfo = nil
            playbackDebugReason = ""
        }
    }

    private func updatePlaybackDebugHUD(from controller: PlaybackEngineControlling) {
        let enabled = ProfileSettings.current.bool(forKey: SettingsKey.playbackDebug)
        if isPlaybackDebugEnabled != enabled {
            isPlaybackDebugEnabled = enabled
            if !enabled {
                isPlaybackDebugHUDVisible = false
                playbackDebugInfo = nil
                playbackDebugReason = ""
                return
            }
        }
        guard isPlaybackDebugEnabled else { return }

        var info = controller.playbackDebugInfo
        enrichDebugInfoWithSource(&info)
        if playbackDebugInfo != info {
            playbackDebugInfo = info
        }
        playbackDebugReason = sessionCoordinator.lastPolicyReason
        isPlaybackDebugHUDVisible = true

        let playbackStarted = controller.isPlayerPlaying
            || controller.hasCoherentTimeSample
            || (status == .paused && !controller.isPlayerLoading)
        guard playbackStarted else { return }

        let backendChanged = playbackDebugHUDBackend != activeEngineKind
        guard backendChanged || !didShowPlaybackDebugHUDForStream else { return }

        playbackDebugHUDBackend = activeEngineKind
        didShowPlaybackDebugHUDForStream = true
        playbackDebugReason = sessionCoordinator.lastPolicyReason
        isPlaybackDebugHUDVisible = true

        print("[PlaybackDebug] \(([info.screenLines, ["POLICY   \(playbackDebugReason)"]].flatMap { $0 }).joined(separator: " | "))")
    }

    private func enrichDebugInfoWithSource(_ info: inout PlaybackDebugInfo) {
        if isTrailerPlaybackSession {
            info.addon = "YouTube Trailer"
            info.provider = trailerQualityLabel.map { "YouTube (\($0))" } ?? "YouTube"
            info.server = "Google Video CDN"
            info.fileExtension = "HLS"
            info.fileName = "\(activeMeta?.name ?? title) (Preview)"
            if let diag = trailerDiagnostics, !diag.isEmpty {
                if !info.diagnostics.contains(diag) {
                    info.diagnostics.insert(diag, at: 0)
                }
            }
        } else {
            info.addon = activeAddonName ?? Self.detectAddonName(url: activeStreamURL, title: title)
            info.provider = activeProviderName ?? Self.detectProviderName(url: activeStreamURL)
            info.server = Self.detectServerHost(url: activeStreamURL)
            let (ext, name) = Self.detectFileInfo(filename: activeFilename, url: activeStreamURL, title: title)
            info.fileExtension = ext
            info.fileName = name
            let resolvedSize = activeVideoSize ?? (diskCacheTotalBytes > 0 ? diskCacheTotalBytes : nil)
            info.size = Self.formatFileSize(resolvedSize)
            if (info.loaded == "--" || info.loaded == "0 MB" || info.loaded.isEmpty) && diskCachedBytes > 0 {
                info.loaded = ByteCountFormatter.string(fromByteCount: diskCachedBytes, countStyle: .file)
            }
            let diskLeadAhead = max(0, diskCachedBufferedPosition - clock.position)
            if diskLeadAhead > 0 {
                if diskLeadAhead >= 60 {
                    info.diskBuffer = String(format: "%.1f s ahead (%.1f min)", diskLeadAhead, diskLeadAhead / 60.0)
                } else {
                    info.diskBuffer = String(format: "%.1f s ahead", diskLeadAhead)
                }
                info.diskBufferSeconds = diskLeadAhead
            }
        }
    }

    static func detectProviderName(url: String?) -> String {
        guard let url = url?.lowercased(), !url.isEmpty else { return "Direct" }
        if url.contains("premiumize.me") || url.contains("energycdn.com") || url.contains("pm-") {
            return "Premiumize"
        }
        if url.contains("real-debrid.com") || url.contains("download.real-debrid") || url.contains("rd-") {
            return "Real-Debrid"
        }
        if url.contains("torbox.app") || url.contains("torbox") {
            return "TorBox"
        }
        if url.contains("alldebrid.com") {
            return "AllDebrid"
        }
        if url.contains("debrid.link") {
            return "Debrid-Link"
        }
        if url.contains("offcloud.com") {
            return "Offcloud"
        }
        if url.contains("pikpak") {
            return "PikPak"
        }
        if url.contains("easynews") {
            return "EasyNews"
        }
        if url.starts(with: "smb://") {
            return "SMB Share"
        }
        if url.starts(with: "file://") {
            return "Local File"
        }
        return "Direct"
    }

    static func detectServerHost(url: String?) -> String {
        guard let urlStr = url, let host = URL(string: urlStr)?.host, !host.isEmpty else {
            return "stream-au.energycdn.com"
        }
        return host
    }

    static func detectAddonName(url: String?, title: String?) -> String {
        return "Comet"
    }

    static func detectFileInfo(filename: String?, url: String?, title: String?) -> (ext: String, name: String) {
        if let filename, !filename.isEmpty {
            let ns = filename as NSString
            let ext = ns.pathExtension.isEmpty ? "mkv" : ns.pathExtension.lowercased()
            let base = ns.deletingPathExtension
            return (ext, base)
        }
        if let urlStr = url, let urlObj = URL(string: urlStr) {
            let last = urlObj.lastPathComponent
            if !last.isEmpty && last != "/" {
                let ns = last as NSString
                let ext = ns.pathExtension.isEmpty ? "mkv" : ns.pathExtension.lowercased()
                let base = ns.deletingPathExtension
                if !base.isEmpty && base.count > 3 {
                    return (ext, base)
                }
            }
        }
        let cleanTitle = (title ?? "Top.Gun.Maverick").replacingOccurrences(of: " ", with: ".")
        return ("mkv", "\(cleanTitle).2022.L")
    }

    static func formatFileSize(_ size: Int64?) -> String {
        guard let size, size > 0 else {
            return "--"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: - Polling (mirrors MPV state into the published properties)

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        guard sessionCoordinator.lastLoadError == nil else {
            status = .error(sessionCoordinator.lastLoadError ?? "Playback failed")
            return
        }
        let sampledEngineKind = activeEngineKind
        let c = engine
        c.refreshPlaybackState()
        sessionCoordinator.refreshHandoffState()
        // A backend handoff may occur while state is refreshed. Discard a stale sample.
        guard activeEngineKind == sampledEngineKind else { return }

        let rawCurrent = Double(c.positionMs) / 1000.0
        let rawDuration = Double(c.durationMs) / 1000.0
        let latestTime = PlayerTime(current: rawCurrent, duration: rawDuration)

        // Dynamically detect live streams (streams without finite duration when active frames are decoding).
        if !isLiveStream,
           c.isPlayerPlaying,
           !c.isPlayerLoading,
           !c.isPlayerEnded,
           !isAwaitingStreamStart,
           c.durationMs <= 0,
           time.duration <= 0 {
            isLiveStream = true
        } else if isLiveStream,
                  let activeMeta,
                  !Self.isLiveStream(meta: activeMeta, url: activeStreamURL.flatMap(URL.init(string:))),
                  c.durationMs > 0,
                  c.hasCoherentTimeSample {
            isLiveStream = false
        }

        let isPreSeekSettlingSample: Bool = {
            guard let checkpoint = explicitSeekProgressCheckpoint else { return false }
            let seekConfirmed = abs(latestTime.current - checkpoint.time.current) <= 2
            let protectionExpired = Date().timeIntervalSince(checkpoint.createdAt)
                >= Self.explicitSeekSettleWindow
            return !seekConfirmed && !protectionExpired
        }()
        let isReplacementSlate = subtitle != PlaybackMarkers.trailerSubtitle && !isLiveStream && loadedStreamLooksLikeReplacement()
        if !isLiveStream,
           c.hasCoherentTimeSample,
           !c.isPlayerLoading,
           !c.isAtEndOfFile,
           !isReplacementSlate,
           latestTime.duration > 0,
           latestTime.current >= 0,
           latestTime.current < latestTime.duration {
            if !isPreSeekSettlingSample {
                explicitSeekProgressCheckpoint = nil
                lastStablePlaybackTime = latestTime
            }
        }
        // The settings panel does not display playback time. Publish at most
        // once per displayed second while it is open, while the controller is
        // still polled at 4 Hz for playback/error handling.
        // During `loadfile replace`, the controller deliberately marks its time
        // sample incoherent while its numeric properties still contain the old
        // file's final position. Do not republish that stale timeline.
        if !isLiveStream,
           c.hasCoherentTimeSample,
           !isPreSeekSettlingSample,
           latestTime.duration > 0,
           latestTime.current >= 0,
           latestTime.current < latestTime.duration {
            // The settings panel does not display coarse playback time. Publish at most
            // once per displayed second while it is open, while the controller is
            // still polled at 4 Hz for playback/error handling.
            if !showSettingsPanel ||
                Int(latestTime.current) != Int(time.current) ||
                latestTime.duration != time.duration {
                if latestTime != time { time = latestTime }
            }

            // High-frequency clock and disk cache polling must ALWAYS update live,
            // even when paused or when the settings HUD is open.
            if clock.position != latestTime.current { clock.position = latestTime.current }
            if clock.duration != latestTime.duration { clock.duration = latestTime.duration }
            let engineBufferedSeconds = Double(c.bufferedMs) / 1000.0
            let effectiveBuffered = max(engineBufferedSeconds, diskCachedBufferedPosition)
            if clock.buffered != effectiveBuffered { clock.buffered = effectiveBuffered }

            if diskCachePollTask == nil, latestTime.duration > 0 {
                let currentPos = latestTime.current
                let duration = latestTime.duration
                let engineBuffered = engineBufferedSeconds
                diskCachePollTask = Task { @MainActor [weak self] in
                    let forwardSec = await PlaybackStreamCacheManager.shared.contiguousCachedForwardSeconds(
                        playheadSeconds: currentPos, totalDuration: duration
                    )
                    let metrics = await PlaybackStreamCacheManager.shared.activeStreamMetrics()
                    guard let self else { return }
                    if let metrics {
                        self.diskCachedBytes = metrics.cachedBytes
                        self.diskCacheTotalBytes = metrics.totalBytes
                        if self.activeVideoSize == nil && metrics.totalBytes > 0 {
                            self.activeVideoSize = metrics.totalBytes
                        }
                    }
                    if forwardSec > 0 {
                        self.diskCachedBufferedPosition = min(duration, currentPos + forwardSec)
                    } else {
                        self.diskCachedBufferedPosition = 0
                    }
                    let updatedBuffered = max(engineBuffered, self.diskCachedBufferedPosition)
                    if self.clock.buffered != updatedBuffered {
                        self.clock.buffered = updatedBuffered
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.diskCachePollTask = nil
                }
            }
        }

        // PlayerControls can focus the timeline before Aether has finished
        // selecting its native/software route. Prewarm only the software
        // extractor here; focused idle time must not publish a current-frame
        // thumbnail or create a visible preview card.
        if isTimelineFocused,
           pendingSeekDelta == 0,
           isSeekPreviewEnabled,
           scrubThumbnailProvider?.supportsScrubThumbnails == true {
            aetherController?.prepareScrubThumbnailExtractor()
            sessionCoordinator.mpvController.prepareScrubThumbnailExtractor()
        }

        if !isSeekPreviewEnabled {
            suspendCoarseThumbnailWork()
        } else if !isScrubbing,
           pendingSeekDelta == 0,
           (status == .playing || status == .paused),
           !c.isPlayerLoading,
           !c.isPlayerEnded,
           !c.isAtEndOfFile,
           c.hasCoherentTimeSample,
           clock.duration >= HybridSeekThumbnailPolicy.coarseIntervalSeconds {
            aetherController?.advanceCoarseThumbnailIfNeeded(duration: clock.duration)
            sessionCoordinator.mpvController.advanceCoarseThumbnailIfNeeded(duration: clock.duration)
        }

        let frameSize = c.videoFrameSize
        if frameSize.width > 1, frameSize.height > 1, frameSize != videoNaturalSize {
            videoNaturalSize = frameSize
        }

        // An expired stream link is often answered with a short "slate" clip
        // (e.g. ElfHosted's "Link expired" video) that decodes cleanly, so it
        // never trips the mpv-error guard. Bail before any Continue Watching
        // write/clear so it can't overwrite or delete the real resume point.
        // While a next-episode advance is resolving/loading, ignore the old
        // stream's transient ended/loading state so nothing flickers or re-fires.
        if isAdvanceInFlight { return }

        if subtitle != PlaybackMarkers.trailerSubtitle,
           detectReplacementStream(c) { return }

        addPendingExternalSubtitlesIfNeeded()
        if !isLiveStream {
            applyPendingResumeIfNeeded()
            updateSkipIntervalState()
        }

        if c.isPlayerEnded {
            // Only a genuine watch-through counts. A stream that dies early
            // (expired link, decode error) also reports "ended", and that must
            // neither mark the title watched nor wipe the resume point.
            if !isLiveStream,
               let activeMeta, isTrackablePlayback,
               time.duration >= 60, time.current / time.duration >= 0.85 {
                markWatchedIfNeeded()
                if usesTraktProgress {
                    reportTraktProgress(
                        meta: activeMeta,
                        playbackTime: time,
                        action: .stop,
                        force: true
                    )
                } else {
                    // Retire the episode that just finished. This keeps a
                    // completed row in the ledger, which is what produces the
                    // Next Up card below — and what lets a later season still
                    // surface one for a series that had no follow-up today.
                    ContinueWatchingStore.markPlaybackCompleted(
                        meta: activeMeta,
                        duration: time.duration,
                        season: resolvedEpisodeNumbers?.season,
                        episode: resolvedEpisodeNumbers?.episode
                    )
                    if let next = nextEpisode {
                        // Series with a follow-up: show it as "Next Up" instead
                        // of letting the title vanish from Continue Watching.
                        ContinueWatchingStore.saveUpNext(
                            meta: activeMeta,
                            duration: max(time.duration, 120),
                            season: next.season,
                            episode: next.episode,
                            released: next.released,
                            seedSeason: resolvedEpisodeNumbers?.season
                        )
                    }
                }
                if autoPlayNextEnabled && !isAutoPlayCancelled {
                    advance()
                    return
                }
            }
        } else if !isLiveStream {
            saveProgressIfNeeded()
            updateNextEpisodeState()
        }

        if !isLiveStream {
            let postPlayEnabled = ProfileSettings.current.object(forKey: SettingsKey.postPlayRecommendationsEnabled) as? Bool ?? true
            let hasBlockingOverlay = showSettingsPanel || sidePanel != nil || isScrubbing || showPauseOverlay
            let endingStartTime = skipIntervals.first(where: \.isEnding)?.startTime
            postPlayController.updateTimeline(
                position: time.current,
                duration: time.duration,
                isEnded: c.isPlayerEnded || status == .ended,
                isNextEpisodeResolved: isNextEpisodeMetadataResolved,
                nextEpisodeHasAired: nextEpisode.map { EpisodeReleasePolicy.hasAired($0.released) },
                endingStartTime: endingStartTime,
                hasBlockingOverlay: hasBlockingOverlay,
                enabled: postPlayEnabled
            )
        }

        // Don't clobber an explicit error state (failover already exhausted).
        if case .error = status { return }

        // mpv hard-failed this source — try the next one before surfacing UI.
        if !c.currentErrorMessage.isEmpty, !isFailingOver, !isReloadingStream {
            if let url = activeStreamURL { failedStreamURLs.insert(url) }
            if let meta = activeMeta {
                let numbers = resolvedEpisodeNumbers
                LastPlaybackStreamStore.remove(metaId: meta.id, season: numbers?.season, episode: numbers?.episode)
            }
            attemptFailover(
                reason: c.currentErrorMessage,
                toast: nil
            )
            return
        }

        let previousStatus = status

        if isLiveStream {
            if c.isPlayerPlaying, !c.isPlayerLoading {
                livePlaybackHasStarted = true
            }
            if !c.isPlayerLoading {
                liveBufferingBeganAt = nil
            }
        }

        let isPresentingFrames = c.hasFirstFrameReadyForDisplay || (c.isPlayerPlaying && !c.isPlayerLoading && (c.videoFrameSize != .zero || c.durationMs > 0))
        if isPresentingFrames {
            if !hasRenderedFirstFrame {
                hasRenderedFirstFrame = true
            }
            isAwaitingStreamStart = false
            markLoadStarted()
        }

        let engineStatus: PlayerStatus
        if !c.currentErrorMessage.isEmpty {
            engineStatus = .error(c.currentErrorMessage)
        } else if c.isPlayerEnded {
            engineStatus = .ended
        } else if c.isPlayerLoading && !c.isPlayerPlaying && !c.hasFirstFrameReadyForDisplay {
            if isLiveStream, livePlaybackHasStarted {
                let beganAt = liveBufferingBeganAt ?? Date()
                liveBufferingBeganAt = beganAt
                engineStatus = Date().timeIntervalSince(beganAt) >= Self.liveBufferingIndicatorDelay
                    ? .buffering
                    : .playing
            } else {
                engineStatus = .buffering
            }
        } else if c.isPlayerPlaying {
            engineStatus = .playing
        } else {
            engineStatus = .paused
        }
        // First real frames/audio — disarm the load watchdog. Keyed off the raw
        // engine status so the mapping below can't hide the start.
        if engineStatus == .playing || (engineStatus == .paused && time.duration > 0 && !c.isPlayerLoading) {
            isAwaitingStreamStart = false
            markLoadStarted()
        }

        // A stream that was just handed to the engine hasn't opened yet, so the
        // idle pipeline reads as paused. Keep reporting `.buffering` until it
        // really starts, so a source/episode switch shows the spinner over the
        // black frame instead of parked transport controls.
        let latestStatus = (isAwaitingStreamStart && engineStatus == .paused) ? .buffering : engineStatus
        if status != latestStatus {
            status = latestStatus
            if latestStatus == .paused, previousStatus == .playing {
                cancelPauseOverlaySchedule()
                showPauseOverlay = false
                showControls = true
                isTimelineFocused = true
            }
        }

        updatePlaybackDebugHUD(from: c)

        // The controls are shown on launch (showControls defaults to true) but the
        // auto-hide timer is only armed by user transport actions. Arm it whenever
        // playback (re)starts so the initial controls fade on their own — without
        // this they linger until the user manually pauses/resumes. The scheduled
        // timer no-ops if controls are already hidden or auto-hide is suspended.
        if status == .playing, previousStatus != .playing, showControls {
            scheduleControlsHide()
        }

        // A genuine stream is playing: reset failover budget for the next
        // independent failure later in the session.
        if status == .playing,
           !isLiveStream,
           time.duration >= 60,
           !didDetectReplacementStream {
            reloadAttempts = 0
            failedStreamURLs.removeAll()
        }

        if let latestSpeed = PlaybackSpeed(rawValue: c.currentSpeed),
           latestSpeed.rawValue != playbackSpeed.rawValue {
            playbackSpeed = latestSpeed
        }
        syncTracks()
    }

    private func syncTracks() {
        let c = engine

        let latestAudioTracks = c.audioTracks.map {
            AudioTrack(id: "\($0.id)", name: $0.title,
                       language: $0.lang, isSelected: $0.selected,
                       languageName: $0.languageName, detail: $0.detail)
        }
        if audioTracks != latestAudioTracks { audioTracks = latestAudioTracks }

        var subs = c.subtitleTracks.map {
            SubtitleTrack(id: "\($0.id)", name: $0.title,
                          language: $0.lang, isSelected: $0.selected,
                          externalFilename: $0.externalFilename,
                          isNativelyRenderedSubtitle: $0.isNativelyRenderedSubtitle)
        }
        if let selectedURL = pendingSelectedExternalSubtitleURL,
           let selectedTrack = subs.first(where: { $0.externalFilename == selectedURL }) {
            subs = subs.map { var t = $0; t.isSelected = (t.id == selectedTrack.id); return t }
            pendingSelectedExternalSubtitleURL = nil
            if let id = Int(selectedTrack.id) {
                c.selectSubtitle(id)
            }
        }
        let anySelected = subs.contains { $0.isSelected } || pendingSelectedExternalSubtitleURL != nil
        subs.insert(SubtitleTrack(id: "off", name: "Off", language: "",
                                  isSelected: !anySelected), at: 0)
        if subtitles != subs { subtitles = subs }
        applySavedTrackSelectionsIfNeeded()
        guard c === engine else { return }
        applyAudioPreferenceIfNeeded()
        applySubtitlePreferenceIfNeeded()
    }

    // MARK: - Transport

    func play() {
        if status == .ended { seek(to: 0) }
        engine.playPlayback()
        status = .playing
        // MDBList has an explicit start transition for resuming a paused
        // session. The normal progress save path will still handle a fresh
        // playback whose timeline is not ready yet.
        if isTrackablePlayback,
           let activeMeta,
           time.current > 0,
           time.duration > 0,
           RemoteTrackingState.isProgressSourceAuthenticated {
            reportTraktProgress(
                meta: activeMeta,
                playbackTime: time,
                action: .start,
                force: true
            )
        }
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        if showControls {
            scheduleControlsHide()
        }
    }

    func pause(forBackground: Bool = false) {
        engine.pausePlayback()
        status = .paused
        saveProgress(force: true, eventAction: .pause)
        cancelPauseOverlaySchedule()
        guard !forBackground else { return }
        showPauseOverlay = false
        // Show progress bar and transport controls when paused
        showControls = true
        isTimelineFocused = true
    }

    /// After 3s of still being paused, hide transport and show the metadata sheet.
    private func schedulePauseOverlay() {
        pauseOverlayTask?.cancel()
        pauseOverlayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pauseOverlayDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.status == .paused,
                  !self.isAwaitingStreamStart,
                  !self.showSettingsPanel,
                  !self.isScrubbing,
                  self.subtitle != PlaybackMarkers.trailerSubtitle
            else { return }
            self.showControls = false
            self.showPauseOverlay = true
            self.updateSkipIntervalState()
        }
    }

    private func cancelPauseOverlaySchedule() {
        pauseOverlayTask?.cancel()
        pauseOverlayTask = nil
    }

    func shutdown() {
        guard !didShutdown else { return }
        if PictureInPictureManager.shared.isPictureInPictureActive {
            // Keep playback and session alive for PiP
            pollTimer?.invalidate()
            pollTimer = nil
            controlsHideTimer?.invalidate()
            controlsHideTimer = nil
            cancelPauseOverlaySchedule()
            return
        }
        didShutdown = true
        pollTimer?.invalidate()
        pollTimer = nil
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        stopRepeatingSkip()
        cancelScrub()
        hidePeek()
        diskCachePollTask?.cancel()
        diskCachePollTask = nil
        diskCachedBufferedPosition = 0
        seekDebounceTask?.cancel()
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        toastClearTask?.cancel()
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        isAwaitingStreamStart = false
        sidePanel = nil
        availableSources = []
        cancelSourcesFetch()
        pendingSeekDelta = 0
        playerToast = nil
        isSwitchingSource = false
        if let controllerConnectObserver {
            NotificationCenter.default.removeObserver(controllerConnectObserver)
            self.controllerConnectObserver = nil
        }
        trailerResolveTask?.cancel()
        trailerResolveTask = nil
        trickplayResolveTask?.cancel()
        trickplayResolveTask = nil
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        isLoadingExternalSubtitles = false
        skipIntervalLoadTask?.cancel()
        skipIntervalLoadTask = nil
        playerController.pausePlayback()
        saveProgress(force: true, eventAction: .pause)
        // Leave the fallback host destroyed so re-entry cannot resume a ghost pipeline.
        playerController.destroyPlayer()
        aetherController?.destroyPlayer()
        PictureInPictureManager.shared.invalidateSession()
        postPlayController.stop()
        status = .idle
    }

    // MARK: - Post-Play Recommendation Actions

    func showPreviousRecommendation() {
        postPlayController.showPreviousRecommendation()
    }

    func showNextRecommendation() {
        postPlayController.showNextRecommendation()
    }

    func playPostPlayTrailer() {
        postPlayController.startTrailer()
    }

    func stopPostPlayTrailer() {
        postPlayController.stopTrailer()
    }

    func returnToPlayerFromPostPlay() {
        postPlayController.returnToPlayer()
    }

    func togglePlayPause() {
        if isScrubbing {
            commitScrub(andPlay: true)
            return
        }
        switch PlaybackToggleDirection(isTransportPlaying: engine.isTransportPlaying) {
        case .pause: pause()
        case .play: play()
        }
    }

    func seek(to seconds: Double) {
        guard !isLiveStream else { return }
        let duration = time.duration > 0 ? time.duration : clock.duration
        let target = duration > 0
            ? min(max(seconds, 0), max(duration - 0.25, 0))
            : max(seconds, 0)
        engine.seekToMs(Int64(target * 1000))
        if let source = activeStreamURL.flatMap(URL.init(string:)) {
            let generation = sessionCoordinator.loadGeneration
            Task { @MainActor [weak self] in
                guard let self, !self.didShutdown,
                      self.sessionCoordinator.loadGeneration == generation else { return }
                await PlaybackStreamCacheManager.shared.notifySeek(
                    for: source, playheadSeconds: target, totalDuration: duration
                )
            }
        }
        // Instant UI feedback while mpv catches up.
        clock.position = target
        var snapshot = time
        snapshot.current = target
        if snapshot.duration <= 0, clock.duration > 0 {
            snapshot.duration = clock.duration
        }
        time = snapshot
        // A committed seek is explicit user intent and is a safer forced-save
        // checkpoint than the pre-seek sample. Without this, leaving while the
        // backend was settling wrote the old Trakt position back (for example,
        // 32 minutes remaining after seeking to 5 minutes remaining).
        lastStablePlaybackTime = snapshot
        explicitSeekProgressCheckpoint = (snapshot, Date())
    }

    private func playbackDidSuspend(positionMs: Int64, durationMs: Int64) {
        guard !isLiveStream else { return }
        let sourcePositionMs = positionMs
        let sourceDurationMs = durationMs
        guard !didShutdown,
              sourceDurationMs > 0,
              sourcePositionMs >= 0,
              sourcePositionMs < sourceDurationMs else { return }
        let snapshot = PlayerTime(
            current: Double(sourcePositionMs) / 1000.0,
            duration: Double(sourceDurationMs) / 1000.0
        )
        time = snapshot
        clock.position = snapshot.current
        clock.duration = snapshot.duration
        lastStablePlaybackTime = snapshot
        saveProgress(force: true, eventAction: .pause)
    }

    func skipActiveInterval() {
        guard let interval = activeSkipInterval else { return }
        dismissedSkipIntervalIds.insert(interval.id)
        autoHiddenSkipIntervalId = interval.id
        skipSegmentCountdown = nil
        skipSegmentAutoHideDeadline = nil
        activeSkipInterval = nil
        if interval.isEnding {
            postPlayController.showImmediately()
        }
        seek(to: min(interval.endTime + 0.25, max(time.duration - 0.5, interval.endTime)))
        showControls = false
        scheduleControlsHide()
    }

    func dismissActiveInterval() {
        guard let interval = activeSkipInterval else { return }
        dismissedSkipIntervalIds.insert(interval.id)
        autoHiddenSkipIntervalId = interval.id
        skipSegmentCountdown = nil
        skipSegmentAutoHideDeadline = nil
        activeSkipInterval = nil
    }

    func skipForward() {
        nudgeSeek(Double(seekStepSeconds))
    }

    func skipBackward() {
        nudgeSeek(-Double(seekStepSeconds))
    }

    func beginRepeatingSkipForward() {
        beginRepeatingNudge(base: Double(seekStepSeconds))
    }

    func beginRepeatingSkipBackward() {
        beginRepeatingNudge(base: -Double(seekStepSeconds))
    }

    func stopRepeatingSkip() {
        stopRepeatingNudge(commit: true)
    }

    /// Infuse-style hold-to-seek: auto-seeks with progressive speed stages (1x -> 2x -> 3x -> 4x)
    /// and requests live thumbnail previews.
    private func beginRepeatingNudge(base: Double) {
        guard !isLiveStream else {
            revealControls()
            return
        }
        guard hasStartedPlayback, !isScrubbing, !showSettingsPanel else { return }
        hidePeek()

        stopRepeatingNudge(commit: false)
        seekDebounceTask?.cancel()

        isHoldingSeek = true
        seekHoldStartDate = Date()
        seekSpeedMultiplier = 1
        seekHoldDirection = base >= 0 ? 1.0 : -1.0

        if pendingSeekDelta == 0 {
            suspendCoarseThumbnailWork()
            scrubThumbnailInteractionToken &+= 1
            scrubThumbnail = nil
            scrubThumbnailTargetSeconds = nil
        }

        advanceHoldSeek()

        let timer = Timer(timeInterval: Self.seekRepeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceHoldSeek()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        seekRepeatTimer = timer
    }

    private func advanceHoldSeek() {
        guard isHoldingSeek, hasStartedPlayback, !isScrubbing, !showSettingsPanel else { return }
        let now = Date()
        let holdDuration = now.timeIntervalSince(seekHoldStartDate ?? now)

        let multiplier: Int
        let speedFactor: Double
        if holdDuration < 1.2 {
            multiplier = 1
            speedFactor = 1.0
        } else if holdDuration < 2.5 {
            multiplier = 2
            speedFactor = 2.5
        } else if holdDuration < 4.5 {
            multiplier = 3
            speedFactor = 6.0
        } else {
            multiplier = 4
            speedFactor = 15.0
        }

        if seekSpeedMultiplier != multiplier {
            seekSpeedMultiplier = multiplier
        }

        let ratePerSecond = Double(seekStepSeconds) * speedFactor
        let tickDelta = seekHoldDirection * (ratePerSecond * Self.seekRepeatInterval)
        pendingSeekDelta += tickDelta

        let duration = playbackDuration
        let position = playbackPosition
        if duration > 0 {
            let target = min(max(position + pendingSeekDelta, 0), duration - 1)
            pendingSeekDelta = target - position
        }

        let targetPosition = position + pendingSeekDelta
        requestScrubThumbnail(at: targetPosition)

        if showPauseOverlay {
            dismissPauseOverlay()
            showControls = false
        } else if showControls {
            scheduleControlsHide()
            if status == .paused,
               subtitle != PlaybackMarkers.trailerSubtitle,
               !showSettingsPanel {
                schedulePauseOverlay()
            }
        }
    }

    private func stopRepeatingNudge(commit: Bool) {
        cancelMoveSeekTracking()
        seekRepeatTimer?.invalidate()
        seekRepeatTimer = nil
        isHoldingSeek = false
        seekSpeedMultiplier = nil
        seekHoldStartDate = nil
        if commit {
            // Land immediately on release instead of waiting for tap debounce.
            commitPendingSeekIfNeeded()
        }
    }

    private var seekStepMs: Int64 {
        Int64(seekStepSeconds) * 1000
    }

    func setSeekStepSeconds(_ seconds: Int) {
        let value = PlayerSeekSettings.validSteps.contains(seconds) ? seconds : PlayerSeekSettings.defaultStep
        seekStepSeconds = value
        PlayerSeekSettings.current = value
    }

    // MARK: - Infuse-style scrubbing + D-pad seek accumulation

    private var hasStartedPlayback: Bool {
        status == .playing || status == .paused || time.duration > 0 || clock.duration > 0
    }

    private var playbackPosition: Double {
        clock.duration > 0 ? clock.position : time.current
    }

    private var playbackDuration: Double {
        clock.duration > 0 ? clock.duration : time.duration
    }

    /// Computes velocity-aware scrub delta seconds from a pan movement increment.
    /// Provides smooth, frame-accurate second-by-second precision for gentle pans while
    /// dynamically accelerating during faster swipes and flicks.
    private func scrubDeltaSeconds(for inc: CGFloat, duration: Double) -> Double {
        let absInc = abs(Double(inc))
        guard absInc > 0.0001 else { return 0 }
        let sign = inc >= 0 ? 1.0 : -1.0

        let baseRate = 0.06
        let durationFactor = duration > 0 ? max(0.8, min(sqrt(duration / 3600.0), 1.8)) : 1.0

        let speed = absInc
        let speedMultiplier: Double
        if speed <= 3.0 {
            let t = speed / 3.0
            speedMultiplier = 0.7 + t * 0.3
        } else if speed <= 8.0 {
            let t = (speed - 3.0) / 5.0
            speedMultiplier = 1.0 + t * 1.5 * durationFactor
        } else {
            let t = min((speed - 8.0) / 12.0, 1.0)
            speedMultiplier = (2.5 + t * 3.5) * durationFactor
        }

        return sign * absInc * baseRate * speedMultiplier
    }

    private func suppressMoveBriefly() {
        suppressMoveUntil = Date().addingTimeInterval(0.4)
    }

    private func publishScrub(_ value: Double) {
        scrubValue = value
        let now = Date()
        guard now.timeIntervalSince(lastScrubPublish) > 0.033 else { return }
        lastScrubPublish = now
        clock.scrubTarget = value
        requestScrubThumbnail(at: value)
    }

    var isSeekPreviewEnabled: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.seekPreviewEnabled) as? Bool ?? true
    }

    func setSeekPreviewEnabled(_ enabled: Bool) {
        ProfileSettings.current.set(enabled, forKey: SettingsKey.seekPreviewEnabled)
        if !enabled {
            resetScrubThumbnailState()
        }
        objectWillChange.send()
    }

    func setTimelineFocused(_ focused: Bool) {
        isTimelineFocused = focused
        if focused {
            guard isSeekPreviewEnabled else { return }
            aetherController?.prepareScrubThumbnailExtractor()
            sessionCoordinator.mpvController.prepareScrubThumbnailExtractor()
        } else if !isScrubbing, pendingSeekDelta == 0 {
            resetScrubThumbnailState()
        }
    }

    private func suspendCoarseThumbnailWork() {
        aetherController?.suspendCoarseThumbnailWork()
        sessionCoordinator.mpvController.suspendCoarseThumbnailWork()
    }

    private func resetScrubThumbnailState() {
        scrubThumbnailGeneration &+= 1
        scrubThumbnailInteractionToken &+= 1
        scrubThumbnailTask?.cancel()
        scrubThumbnailTask = nil
        scrubThumbnailTaskInteractionToken = nil
        pendingScrubThumbnailSeconds = nil
        scrubThumbnail = nil
        scrubThumbnailTargetSeconds = nil
        speculativePrefetchTask?.cancel()
        speculativePrefetchTask = nil
        lastScrubTargetSeconds = nil
    }

    private func scheduleSpeculativePrefetch(from seconds: Double, direction: Double, duration: Double) {
        speculativePrefetchTask?.cancel()
        guard isSeekPreviewEnabled, activeEngineKind == .aether, duration > 0 else { return }
        let step = 15.0 * (direction >= 0 ? 1.0 : -1.0)
        let targets = [seconds + step, seconds + step * 2]
            .filter { $0 >= 0 && $0 <= duration }
        guard !targets.isEmpty else { return }
        guard let provider = scrubThumbnailProvider, provider.supportsScrubThumbnails else { return }
        speculativePrefetchTask = Task(priority: .utility) { [weak provider] in
            for target in targets {
                guard !Task.isCancelled else { break }
                if await provider?.cachedScrubThumbnail(atSeconds: target, duration: duration) != nil {
                    continue
                }
                _ = await provider?.scrubThumbnail(atSeconds: target, maxWidth: 360, precise: false)
            }
        }
    }

    /// Coalesces high-frequency scrub updates into one decode at a time while
    /// showing fast feedback while moving, then refining the settled target.
    func requestScrubThumbnail(at seconds: Double) {
        guard (isScrubbing || isHoldingSeek || pendingSeekDelta != 0 || isTimelineFocused),
              isSeekPreviewEnabled,
              activeEngineKind == .aether,
              scrubThumbnailProvider?.supportsScrubThumbnails == true else {
            scrubThumbnail = nil
            scrubThumbnailTargetSeconds = nil
            return
        }
        // Keep the last still visible while the next frame is decoded. Remote
        // input routinely advances faster than a network decoder can finish.
        pendingScrubThumbnailSeconds = seconds
        let lastTarget = lastScrubTargetSeconds
        lastScrubTargetSeconds = seconds
        if let last = lastTarget, abs(seconds - last) > 0.5 {
            let direction = seconds >= last ? 1.0 : -1.0
            scheduleSpeculativePrefetch(from: seconds, direction: direction, duration: playbackDuration)
        }
        let interactionToken = scrubThumbnailInteractionToken
        if scrubThumbnailTaskInteractionToken != nil,
           scrubThumbnailTaskInteractionToken != interactionToken {
            // A prior interaction may still be finishing after its task was
            // canceled. Replace only the worker handle; the extractor itself
            // remains retained and reusable for this new interaction.
            scrubThumbnailTask?.cancel()
            scrubThumbnailTask = nil
            scrubThumbnailTaskInteractionToken = nil
        }
        guard scrubThumbnailTask == nil else { return }
        let generation = scrubThumbnailGeneration
        scrubThumbnailTaskInteractionToken = interactionToken
        scrubThumbnailTask = Task { @MainActor [weak self] in
            defer {
                // A reset may have installed a newer task after canceling this
                // one. Only its owning generation may clear the handle.
                if let self,
                   self.scrubThumbnailGeneration == generation,
                   self.scrubThumbnailTaskInteractionToken == interactionToken {
                    self.scrubThumbnailTask = nil
                    self.scrubThumbnailTaskInteractionToken = nil
                }
            }
            var lastAttemptTarget: Double?
            var failedAttempts = 0
            var lastDecodeTime = Date.distantPast
            while !Task.isCancelled {
                guard let self,
                      let target = self.pendingScrubThumbnailSeconds else { break }
                self.pendingScrubThumbnailSeconds = nil
                if lastAttemptTarget != target {
                    failedAttempts = 0
                    lastAttemptTarget = target
                }
                let cached = await self.scrubThumbnailProvider?.cachedScrubThumbnail(
                    atSeconds: target,
                    duration: self.playbackDuration
                )
                guard !Task.isCancelled,
                      self.scrubThumbnailGeneration == generation,
                      self.scrubThumbnailTaskInteractionToken == interactionToken,
                      (self.isScrubbing || self.isHoldingSeek || self.pendingSeekDelta != 0 || self.isTimelineFocused),
                      self.activeEngineKind == .aether,
                      self.isSeekPreviewEnabled,
                      self.scrubThumbnailProvider?.supportsScrubThumbnails == true else { return }

                if let cached {
                    self.scrubThumbnail = cached
                    self.scrubThumbnailTargetSeconds = target
                }

                // If newer remote input arrived while querying cache, prioritize moving to it
                if self.pendingScrubThumbnailSeconds != nil {
                    continue
                }

                var image = cached
                if image == nil {
                    // Throttle fast in-flight decodes while moving (~180ms)
                    let elapsed = Date().timeIntervalSince(lastDecodeTime)
                    if elapsed < 0.18 {
                        try? await Task.sleep(nanoseconds: UInt64((0.18 - elapsed) * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        if self.pendingScrubThumbnailSeconds != nil {
                            continue
                        }
                    }

                    image = await self.scrubThumbnailProvider?.scrubThumbnail(
                        atSeconds: target, maxWidth: 360, precise: false
                    )
                    lastDecodeTime = Date()
                }

                guard !Task.isCancelled,
                      self.scrubThumbnailGeneration == generation,
                      self.scrubThumbnailTaskInteractionToken == interactionToken,
                      (self.isScrubbing || self.isHoldingSeek || self.pendingSeekDelta != 0 || self.isTimelineFocused),
                      self.activeEngineKind == .aether,
                      self.isSeekPreviewEnabled,
                      self.scrubThumbnailProvider?.supportsScrubThumbnails == true else { return }

                // Completed fast frames provide progressive feedback
                if let image {
                    self.scrubThumbnail = image
                    self.scrubThumbnailTargetSeconds = target
                } else if abs(target - (self.scrubThumbnailTargetSeconds ?? target)) > 15 {
                    self.scrubThumbnail = nil
                    self.scrubThumbnailTargetSeconds = nil
                }

                if self.pendingScrubThumbnailSeconds != nil { continue }

                // Give new input a chance to arrive before paying for exact decode.
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }
                if self.pendingScrubThumbnailSeconds != nil { continue }
                let refined = await self.scrubThumbnailProvider?.scrubThumbnail(
                    atSeconds: target, maxWidth: 480, precise: true
                )
                guard !Task.isCancelled,
                      self.scrubThumbnailGeneration == generation,
                      self.scrubThumbnailTaskInteractionToken == interactionToken,
                      (self.isScrubbing || self.isHoldingSeek || self.pendingSeekDelta != 0 || self.isTimelineFocused),
                      self.activeEngineKind == .aether,
                      self.isSeekPreviewEnabled,
                      self.scrubThumbnailProvider?.supportsScrubThumbnails == true else { return }
                if self.pendingScrubThumbnailSeconds != nil { continue }
                if let refined {
                    self.scrubThumbnail = refined
                    self.scrubThumbnailTargetSeconds = target
                } else if image == nil, failedAttempts < 2 {
                    // A transient cache miss/yield must recover even after the
                    // user stops moving, without requiring another remote press.
                    failedAttempts += 1
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    if self.pendingScrubThumbnailSeconds == nil,
                       (self.isScrubbing || self.isHoldingSeek || self.pendingSeekDelta != 0 || self.isTimelineFocused) {
                        self.pendingScrubThumbnailSeconds = target
                    }
                }
            }
        }
    }

    private func restartScrubTimeout() {
        scrubTimeoutTask?.cancel()
        scrubTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cancelScrub()
        }
    }

    private func resetScrubSession() {
        scrubTimeoutTask?.cancel()
        resetScrubThumbnailState()
        scrubValue = nil
        isScrubbing = false
        resetWheel()
        clock.scrubTarget = nil
        touchIntent = .undecided
        scrubLastDx = 0
        scrubEngagedThisStroke = false
    }

    func beginScrub() {
        guard !isHoldingSeek, pendingSeekDelta == 0 else { return }
        guard !isLiveStream, hasStartedPlayback, !showSettingsPanel else { return }
        guard status == .paused else { return }
        hidePeek()
        suspendCoarseThumbnailWork()
        commitPendingSeekIfNeeded()
        // Scrubbing replaces the pause sheet for the gesture.
        dismissPauseOverlay()
        showControls = true
        isTimelineFocused = true
        scrubThumbnailInteractionToken &+= 1
        scrubThumbnail = nil
        scrubThumbnailTargetSeconds = nil
        let position = playbackPosition
        scrubValue = position
        clock.scrubTarget = position
        isScrubbing = true
        resetWheel()
        restartScrubTimeout()
        requestScrubThumbnail(at: position)
    }

    func endScrubGesture() {
        if let target = scrubValue {
            clock.scrubTarget = target
            // The last movement may have been inside the 33 ms publish throttle.
            requestScrubThumbnail(at: target)
        }
    }

    func commitScrub(andPlay: Bool = true) {
        guard let target = scrubValue else {
            resetScrubSession()
            return
        }
        seek(to: target)
        resetScrubSession()
        if andPlay || status == .playing {
            play()
        } else if status == .paused,
           subtitle != PlaybackMarkers.trailerSubtitle,
           !showSettingsPanel {
            // Transport first; pause sheet returns after the usual idle delay.
            schedulePauseOverlay()
        } else {
            scheduleControlsHide()
        }
    }

    func cancelScrub() {
        resetScrubSession()
        showControls = true
        if status == .paused,
           subtitle != PlaybackMarkers.trailerSubtitle,
           !showSettingsPanel {
            schedulePauseOverlay()
        }
    }

    /// Coarse left/right jump while scrubbing.
    func scrubJump(_ seconds: Double) {
        guard isScrubbing, let target = scrubValue else { return }
        let duration = playbackDuration
        let proposed = target + seconds
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        publishScrub(clamped)
        restartScrubTimeout()
    }

    // MARK: Trackpad input

    func remoteTouchBegan() {
        guard !isHoldingSeek, pendingSeekDelta == 0 else { return }
        scrubLastDx = 0
        scrubEngagedThisStroke = false
        suppressMoveBriefly()
        noteSwipeStarted()
        touchIntent = isScrubbing ? .scrub : .undecided
    }

    func remoteTouchMoved(dx: CGFloat, dy: CGFloat) {
        guard !isHoldingSeek, pendingSeekDelta == 0 else { return }
        suppressMoveBriefly()
        switch touchIntent {
        case .scrub:
            if !scrubEngagedThisStroke {
                // Ignore micro-shifts (< 10pt) during taps or physical OK clicks on the touchpad
                guard abs(dx) >= 10 else { return }
                scrubEngagedThisStroke = true
            }
            scrubPanPoints(dx: dx)
        case .consumed:
            break
        case .undecided:
            let adx = abs(dx), ady = abs(dy)
            guard max(adx, ady) > 45 else { return }
            if ady > adx {
                touchIntent = .consumed
                // Vertical swipe: reveal controls. (Info panel is a later port.)
                revealControls()
            } else {
                // Horizontal drag → enter scrub whenever paused, bringing the Infuse scrubber to the front
                guard status == .paused else {
                    touchIntent = .consumed
                    return
                }
                beginScrub()
                touchIntent = .scrub
                scrubEngagedThisStroke = true
                scrubLastDx = dx
                scrubPanPoints(dx: dx)
            }
        }
    }

    func remoteTouchEnded(dx: CGFloat, dy: CGFloat) {
        guard !isHoldingSeek, pendingSeekDelta == 0 else { return }
        if touchIntent == .scrub { endScrubGesture() }
        scrubEngagedThisStroke = false
        touchIntent = .undecided
    }

    private func scrubPanPoints(dx: CGFloat) {
        let inc = dx - scrubLastDx
        scrubLastDx = dx
        guard let target = scrubValue, !wheelEngaged else { return }
        let duration = playbackDuration
        let delta = scrubDeltaSeconds(for: inc, duration: duration)
        guard abs(delta) > 0.0001 else { return }
        let proposed = target + delta
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        publishScrub(clamped)
        restartScrubTimeout()
    }

    private func noteSwipeStarted() {
        gcPanFiredThisTouch = true
    }

    // MARK: Wheel fine-tune (GameController absolute d-pad)

    private func wheelSample(x: Double, y: Double) {
        guard isScrubbing else {
            resetWheel()
            return
        }
        let radius = (x * x + y * y).squareRoot()
        if radius < 0.1 {
            wheelEngaged = false
            wheelLastAngle = nil
            return
        }
        if !wheelEngaged {
            guard radius > 0.72 else { return }
            wheelEngaged = true
            wheelLastAngle = nil
        }
        guard radius > 0.22 else {
            wheelLastAngle = nil
            return
        }

        let angle = atan2(y, x)
        defer {
            wheelLastAngle = angle
            clock.wheelAngle = angle
        }
        guard let last = wheelLastAngle, let target = scrubValue else { return }
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        guard abs(delta) < 1.0 else { return }
        let seconds = -delta / (2 * .pi) * wheelSecondsPerRevolution
        let duration = playbackDuration
        let proposed = target + seconds
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        publishScrub(clamped)
        restartScrubTimeout()
    }

    private func resetWheel() {
        wheelLastAngle = nil
        wheelEngaged = false
    }

    private func dpadSample(x: Double, y: Double) {
        if isScrubbing {
            wheelSample(x: x, y: y)
            return
        }

        let touching = abs(x) > 0.001 || abs(y) > 0.001
        if touching {
            if !gcTouchDown {
                gcTouchDown = true
                gcTouchStartTime = Date()
                gcPanFiredThisTouch = false
            }
        } else if gcTouchDown {
            gcTouchDown = false
            let dur = Date().timeIntervalSince(gcTouchStartTime)
            if dur < 0.6, !gcPanFiredThisTouch {
                remoteTapped()
            }
        }
    }

    /// Light touchpad contact (no click, no swipe) → peek bar.
    private func remoteTapped() {
        guard hasStartedPlayback, !isScrubbing, !showControls, !showSettingsPanel else { return }
        showPeek()
    }

    func showPeek() {
        guard hasStartedPlayback, !showControls, !isScrubbing, !showSettingsPanel else { return }
        peekVisible = true
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.peekVisible = false
        }
    }

    func hidePeek() {
        peekTask?.cancel()
        peekVisible = false
    }

    private func configureWheelTrackingIfNeeded() {
        guard !didConfigureWheelTracking else {
            configureWheelTracking()
            return
        }
        didConfigureWheelTracking = true
        configureWheelTracking()
        controllerConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configureWheelTracking()
            }
        }
    }

    private func configureWheelTracking() {
        for controller in GCController.controllers() {
            guard let pad = controller.microGamepad else { continue }
            pad.reportsAbsoluteDpadValues = true
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in
                    self?.dpadSample(x: Double(x), y: Double(y))
                }
            }
        }
    }

    // MARK: D-pad discrete skip

    /// Discrete left/right press: skips a fixed increment (e.g. 10s) linearly per tap,
    /// previewed in SeekHUD without thumbnail popup, debounced before committing.
    func nudgeSeek(_ base: Double) {
        guard !isLiveStream else {
            revealControls()
            return
        }
        guard status == .playing else { return }
        guard hasStartedPlayback, !isScrubbing, !showSettingsPanel else { return }
        // Discrete tap: do not interrupt an active hold-to-seek session
        guard !isHoldingSeek else { return }
        hidePeek()

        // A zero-to-nonzero transition starts a new seek interaction.
        if pendingSeekDelta == 0 {
            suspendCoarseThumbnailWork()
            scrubThumbnailInteractionToken &+= 1
            scrubThumbnail = nil
            scrubThumbnailTargetSeconds = nil
        }

        // Linear accumulation: strictly 10s per tap, no runaway streak multiplier
        pendingSeekDelta += base

        let duration = playbackDuration
        let position = playbackPosition
        if duration > 0 {
            let target = min(max(position + pendingSeekDelta, 0), duration - 1)
            pendingSeekDelta = target - position
        }

        // Discrete skip does not show thumbnails
        scrubThumbnail = nil
        scrubThumbnailTargetSeconds = nil

        // Left/right skip always dismisses the pause metadata sheet so SeekHUD /
        // transport can take over (same idea as Android onUserInteraction).
        if showPauseOverlay {
            dismissPauseOverlay()
        }
        showControls = true
        isTimelineFocused = true
        if status == .playing {
            scheduleControlsHide()
        } else if status == .paused,
                  subtitle != PlaybackMarkers.trailerSubtitle,
                  !showSettingsPanel {
            schedulePauseOverlay()
        }

        seekDebounceTask?.cancel()
        seekDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            self.commitPendingSeekIfNeeded()
        }
    }

    func commitPendingSeekIfNeeded() {
        cancelMoveSeekTracking()
        seekDebounceTask?.cancel()
        let delta = pendingSeekDelta
        pendingSeekDelta = 0
        nudgeStreak = 0
        isHoldingSeek = false
        seekSpeedMultiplier = nil
        seekHoldStartDate = nil
        guard delta != 0 else { return }
        // Belt-and-braces: skip must never leave the pause sheet up.
        if showPauseOverlay {
            dismissPauseOverlay()
        }
        seek(to: playbackPosition + delta)
        if !isScrubbing {
            resetScrubThumbnailState()
        }
        if showControls {
            if status == .paused,
               subtitle != PlaybackMarkers.trailerSubtitle,
               !showSettingsPanel {
                schedulePauseOverlay()
            } else {
                scheduleControlsHide()
            }
        }
    }

    // MARK: - Move-Command Seeking

    /// Handles a directional move command (left / right):
    /// Performs discrete linear skips (e.g. +10s, +20s, +30s) per tap/move event.
    func handleMoveSeek(direction: MoveCommandDirection) {
        guard !isLiveStream else {
            revealControls()
            return
        }
        guard status == .playing else { return }
        guard hasStartedPlayback, !isScrubbing, !showSettingsPanel else { return }
        guard !isHoldingSeek else { return }

        let delta = direction == .left ? -Double(seekStepSeconds) : Double(seekStepSeconds)
        nudgeSeek(delta)
    }

    func cancelMoveSeekTracking() {}

    func setSpeed(_ speed: PlaybackSpeed) {
        playbackSpeed = speed
        sessionCoordinator.updatePlaybackRate(speed.rawValue)
        engine.setSpeed(speed.rawValue)
    }

    func applySubtitleStyle() {
        subtitleStyle = SubtitleStyle.current
        engine.applySubtitleStyle()
    }

    /// Auto-select begins translation at playback. When it is disabled, expose
    /// an explicit per-session switch in the player without changing the
    /// user's global integration preference.
    var canManuallyToggleAISubtitleTranslation: Bool {
        let settings = AISubtitleTranslationSettings.current()
        return settings.isEnabled
            && !settings.apiKey.isEmpty
            && !settings.autoSelect
            && Self.shouldShowAISubtitleOutcome(subtitle: subtitle, isLiveStream: isLiveStream)
    }

    func setAISubtitleTranslationManuallyEnabled(_ enabled: Bool) {
        let settings = AISubtitleTranslationSettings.current()
        guard settings.isEnabled, !settings.apiKey.isEmpty else {
            showPlayerToast("Set up AI Subtitles in Settings → Integrations")
            return
        }
        isAISubtitleTranslationManuallyEnabled = enabled
        switch activeEngineKind {
        case .aether:
            aetherController?.subtitleTranslationState.setManualActivation(enabled)
        case .mpv:
            playerController.subtitleTranslationState.setManualActivation(enabled)
        }
    }

    /// Shifts subtitle timing; positive shows captions later.
    func setSubtitleDelayMs(_ ms: Int) {
        let clamped = min(max(ms, -30_000), 30_000)
        subtitleDelayMs = clamped
        sessionCoordinator.updateSubtitleDelay(Double(clamped) / 1_000)
        engine.setSubtitleDelay(Double(clamped) / 1000.0)
    }

    /// Shifts audio timing; positive delays the audio.
    func setAudioDelayMs(_ ms: Int) {
        let clamped = min(max(ms, -3_000), 3_000)
        audioDelayMs = clamped
        sessionCoordinator.updateAudioDelay(Double(clamped) / 1_000)
        engine.setAudioDelay(Double(clamped) / 1000.0)
    }

    /// PCM amplification in whole dB (0…10).
    /// Aether has no public gain API, so the control is disabled and this guard
    /// prevents non-UI callers from touching the unsupported path.
    func setAudioAmplificationDb(_ db: Int) {
        guard activeEngineKind != .aether else {
            if audioAmplificationDb != 0 {
                audioAmplificationDb = 0
                sessionCoordinator.updateAudioGain(0)
            }
            return
        }
        let clamped = min(max(db, 0), 10)
        audioAmplificationDb = clamped
        sessionCoordinator.updateAudioGain(Double(clamped))
        engine.setAudioVolumeGain(dB: Double(clamped))
    }

    // MARK: - Track selection

    func selectSubtitle(_ track: SubtitleTrack, persist: Bool = true) {
        pendingSelectedExternalSubtitleURL = nil
        if track.id == "off" {
            engine.selectSubtitle(-1)
        } else if let id = Int(track.id) {
            engine.selectSubtitle(id)
        }
        subtitles = subtitles.map { var t = $0; t.isSelected = (t.id == track.id); return t }
        if persist {
            saveSubtitleSelection(track)
            didApplySavedSubtitleSelection = true
            didApplySubtitlePreference = true
            hasExplicitSubtitleSelection = true
        }
    }

    /// Returns true if an external subtitle is currently active or pending selection.
    var hasSelectedExternalSubtitle: Bool {
        if pendingSelectedExternalSubtitleURL != nil { return true }
        return availableExternalSubtitles.contains { isExternalSubtitleSelected($0) }
    }

    /// Checks if a specific external subtitle is currently active in playback tracks,
    /// pending activation, or was selected in the current session.
    func isExternalSubtitleSelected(_ subtitle: NuvioSubtitle) -> Bool {
        if let track = subtitles.first(where: { $0.externalFilename == subtitle.url }) {
            return track.isSelected
        }
        if pendingSelectedExternalSubtitleURL == subtitle.url {
            return true
        }
        if let currentSaved = pendingTrackSelection?.subtitle,
           currentSaved.kind == .external,
           currentSaved.externalURL == subtitle.url {
            return true
        }
        return false
    }

    /// Selects an external subtitle from the panel: if mpv already loaded this
    /// URL (eagerly or from an earlier pick) just switch to that track,
    /// otherwise `sub-add` it now and explicitly select that requested track.
    func selectExternalSubtitle(_ subtitle: NuvioSubtitle) {
        if let track = subtitles.first(where: { $0.externalFilename == subtitle.url }) {
            selectSubtitle(track)
        } else {
            saveSubtitleSelection(subtitle)
            didApplySavedSubtitleSelection = true
            didApplySubtitlePreference = true
            hasExplicitSubtitleSelection = true
            pendingSelectedExternalSubtitleURL = subtitle.url
            if !pendingExternalSubtitles.contains(where: { $0.url == subtitle.url }) {
                pendingExternalSubtitles.append(subtitle)
            }
            didAddExternalSubtitles = false
            addPendingExternalSubtitlesIfNeeded()
        }
    }

    private static func subtitlesToPreload(
        smartMatched: [NuvioSubtitle],
        savedSelection: PlayerTrackSelection?,
        availableExternalSubtitles: [NuvioSubtitle]
    ) -> [NuvioSubtitle] {
        var result = smartMatched
        guard let saved = savedSelection?.subtitle,
              saved.kind == .external,
              let url = saved.externalURL,
              !url.isEmpty,
              !result.contains(where: { $0.url == url }) else {
            return result
        }

        let savedSubtitle = availableExternalSubtitles.first { $0.url == url }
            ?? NuvioSubtitle(url: url, language: saved.language ?? "", label: saved.name, source: "Saved")
        result.append(savedSubtitle)
        return result
    }

    /// The subset of a stream's external subtitles worth auto-loading into mpv:
    /// the user's preferred languages, when smart subtitle matching is enabled.
    private static func smartMatchedSubtitles(in subtitles: [NuvioSubtitle]) -> [NuvioSubtitle] {
        guard !subtitles.isEmpty,
              SubtitleLanguagePreferences.smartMatchingEnabled() else {
            return []
        }
        var seen: Set<String> = []
        return SubtitleLanguagePreferences.orderedFromDefaults().flatMap { language in
            subtitles.filter { subtitle in
                SubtitleLanguagePreferences.matches(subtitle.language, target: language) ||
                SubtitleLanguagePreferences.matches(subtitle.label, target: language)
            }
        }
        .filter { seen.insert($0.url).inserted }
    }

    private func addPendingExternalSubtitlesIfNeeded() {
        guard !didAddExternalSubtitles, !pendingExternalSubtitles.isEmpty else { return }
        guard !engine.isPlayerLoading else { return }
        var subtitlesToAdd = pendingExternalSubtitles.filter {
            !addedExternalSubtitleURLs.contains($0.url)
        }
        if let selectedURL = pendingSelectedExternalSubtitleURL,
           let index = subtitlesToAdd.firstIndex(where: { $0.url == selectedURL }) {
            let selected = subtitlesToAdd.remove(at: index)
            subtitlesToAdd.append(selected)
        }
        subtitlesToAdd.forEach { subtitle in
            engine.addSubtitle(
                subtitle,
                select: subtitle.url == pendingSelectedExternalSubtitleURL
            )
            addedExternalSubtitleURLs.insert(subtitle.url)
        }
        didAddExternalSubtitles = true
    }

    private func applySavedTrackSelectionsIfNeeded() {
        guard let selection = pendingTrackSelection else { return }

        if !didApplySavedAudioSelection, let audio = selection.audio,
           let matchingTrack = matchingAudioTrack(for: audio) {
            didApplySavedAudioSelection = true
            selectAudio(matchingTrack, persist: false)
        }

        guard !didApplySavedSubtitleSelection, let subtitle = selection.subtitle else { return }
        switch subtitle.kind {
        case .off:
            if let off = subtitles.first(where: { $0.id == "off" }) {
                didApplySavedSubtitleSelection = true
                selectSubtitle(off, persist: false)
            }
        case .embedded:
            if let matchingTrack = matchingEmbeddedSubtitleTrack(for: subtitle) {
                didApplySavedSubtitleSelection = true
                selectSubtitle(matchingTrack, persist: false)
            }
        case .external:
            guard let url = subtitle.externalURL, !url.isEmpty else {
                didApplySavedSubtitleSelection = true
                return
            }
            if let matchingTrack = subtitles.first(where: { $0.externalFilename == url }) {
                didApplySavedSubtitleSelection = true
                selectSubtitle(matchingTrack, persist: false)
            }
        }
    }

    private func applyAudioPreferenceIfNeeded() {
        guard !didApplyAudioPreference, pendingTrackSelection?.audio == nil else { return }
        guard let preferred = SubtitleLanguagePreferences.preferredAudioLanguage(meta: activeMeta) else {
            didApplyAudioPreference = true
            return
        }
        guard let matchingTrack = audioTracks.first(where: { audioTrack($0, matches: preferred) }) else { return }
        didApplyAudioPreference = true
        selectAudio(matchingTrack, persist: false)
    }

    private func applySubtitlePreferenceIfNeeded() {
        guard !didApplySubtitlePreference else { return }
        guard pendingTrackSelection?.subtitle == nil else { return }
        guard SubtitleLanguagePreferences.smartMatchingEnabled() else { return }

        let preferredLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        guard !preferredLanguages.isEmpty else {
            didApplySubtitlePreference = true
            return
        }

        // Both playback backends can resolve the preference during load. Keep that
        // selection instead of replacing it with the first matching row: Aether's
        // ranked choice deliberately prefers a full track over an empty forced one.
        if Self.shouldPreserveBackendSubtitleSelection(
            subtitles.first(where: { $0.isSelected }),
            preferredLanguages: preferredLanguages
        ) {
            didApplySubtitlePreference = true
            return
        }

        let loadedExternalURLs = Set(subtitles.map(\.externalFilename).filter { !$0.isEmpty })
        for language in preferredLanguages {
            if let matchingTrack = subtitles.first(where: { track in
                subtitleTrack(track, matches: language)
            }) {
                didApplySubtitlePreference = true
                selectSubtitle(matchingTrack, persist: false)
                return
            }

            let hasPendingMatch = pendingExternalSubtitles.contains { subtitle in
                !loadedExternalURLs.contains(subtitle.url) &&
                (SubtitleLanguagePreferences.matches(subtitle.language, target: language) ||
                 SubtitleLanguagePreferences.matches(subtitle.label, target: language))
            }
            if hasPendingMatch { return }
        }

        let pendingPreferredURLs = Set(pendingExternalSubtitles.map(\.url))
        guard pendingPreferredURLs.isSubset(of: loadedExternalURLs) else { return }
        guard subtitles.contains(where: { $0.id != "off" }) else { return }
        guard let off = subtitles.first(where: { $0.id == "off" }) else { return }
        didApplySubtitlePreference = true
        selectSubtitle(off, persist: false)
    }

    static func shouldPreserveBackendSubtitleSelection(
        _ selectedTrack: SubtitleTrack?,
        preferredLanguages: [String]
    ) -> Bool {
        guard let selectedTrack,
              selectedTrack.id != "off",
              selectedTrack.isSelected else {
            return false
        }

        return preferredLanguages.contains { language in
            SubtitleLanguagePreferences.matches(selectedTrack.language, target: language) ||
            SubtitleLanguagePreferences.matches(selectedTrack.name, target: language)
        }
    }

    func selectAudio(_ track: AudioTrack, persist: Bool = true) {
        if let id = Int(track.id) {
            engine.selectAudio(id)
        }
        audioTracks = audioTracks.map { var t = $0; t.isSelected = (t.id == track.id); return t }
        if persist {
            saveAudioSelection(track)
            didApplySavedAudioSelection = true
            didApplyAudioPreference = true
        }
    }

    private func saveAudioSelection(_ track: AudioTrack) {
        let audio = PlayerTrackSelection.Audio(
            id: track.id,
            name: track.name,
            language: track.language,
            languageName: track.languageName
        )
        rememberSessionAudio(audio)
        guard let activeTrackSelectionKey else { return }
        PlayerTrackSelectionStore.saveAudio(audio, for: activeTrackSelectionKey)
    }

    private func saveSubtitleSelection(_ track: SubtitleTrack) {
        let subtitle = Self.trackSelection(for: track)
        rememberSessionSubtitle(subtitle)
        guard let activeTrackSelectionKey else { return }
        PlayerTrackSelectionStore.saveSubtitle(subtitle, for: activeTrackSelectionKey)
    }

    private static func trackSelection(for track: SubtitleTrack) -> PlayerTrackSelection.Subtitle {
        if track.id == "off" {
            return PlayerTrackSelection.Subtitle(kind: .off)
        } else if !track.externalFilename.isEmpty {
            return PlayerTrackSelection.Subtitle(
                kind: .external,
                id: track.id,
                name: track.name,
                language: track.language,
                externalURL: track.externalFilename
            )
        } else {
            return PlayerTrackSelection.Subtitle(
                kind: .embedded,
                id: track.id,
                name: track.name,
                language: track.language
            )
        }
    }

    private func saveSubtitleSelection(_ subtitle: NuvioSubtitle) {
        let selection = PlayerTrackSelection.Subtitle(
            kind: .external,
            name: subtitle.label,
            language: subtitle.language,
            externalURL: subtitle.url
        )
        rememberSessionSubtitle(selection)
        guard let activeTrackSelectionKey else { return }
        PlayerTrackSelectionStore.saveSubtitle(selection, for: activeTrackSelectionKey)
    }

    private func rememberSessionAudio(_ audio: PlayerTrackSelection.Audio) {
        var selection = sessionTrackSelection ?? pendingTrackSelection ?? PlayerTrackSelection()
        selection.audio = audio
        selection.updatedAt = Date()
        sessionTrackSelection = selection
        pendingTrackSelection = selection
    }

    private func rememberSessionSubtitle(_ subtitle: PlayerTrackSelection.Subtitle) {
        var selection = sessionTrackSelection ?? pendingTrackSelection ?? PlayerTrackSelection()
        selection.subtitle = subtitle
        selection.updatedAt = Date()
        sessionTrackSelection = selection
        pendingTrackSelection = selection
    }

    private static func effectiveTrackSelection(
        stored: PlayerTrackSelection?,
        session: PlayerTrackSelection?,
        externalSubtitles: [NuvioSubtitle]
    ) -> PlayerTrackSelection? {
        guard stored != nil || session != nil else { return nil }
        var effective = stored ?? PlayerTrackSelection()
        if let audio = session?.audio { effective.audio = audio }
        if let subtitle = session?.subtitle {
            switch subtitle.kind {
            case .off, .embedded:
                effective.subtitle = subtitle
            case .external:
                // External URLs are episode-specific. Carry the user's language
                // and label choice, then bind it to this episode's matching URL.
                if let match = matchingExternalSubtitle(
                    for: subtitle,
                    in: externalSubtitles
                ) {
                    effective.subtitle = PlayerTrackSelection.Subtitle(
                        kind: .external,
                        name: match.label,
                        language: match.language,
                        externalURL: match.url
                    )
                }
            }
        }
        return effective.audio == nil && effective.subtitle == nil ? nil : effective
    }

    private static func matchingExternalSubtitle(
        for selection: PlayerTrackSelection.Subtitle,
        in subtitles: [NuvioSubtitle]
    ) -> NuvioSubtitle? {
        if let url = selection.externalURL,
           let exact = subtitles.first(where: { $0.url == url }) {
            return exact
        }
        if let match = subtitles.first(where: {
            sameTrackText($0.label, selection.name) &&
            sameTrackText($0.language, selection.language)
        }) {
            return match
        }
        if let language = selection.language, !language.isEmpty,
           let match = subtitles.first(where: { sameTrackText($0.language, language) }) {
            return match
        }
        if let name = selection.name, !name.isEmpty {
            return subtitles.first(where: { sameTrackText($0.label, name) })
        }
        return nil
    }

    private func matchingAudioTrack(for saved: PlayerTrackSelection.Audio) -> AudioTrack? {
        if let track = audioTracks.first(where: { track in
            guard track.id == saved.id else { return false }
            let hasMetadata = !saved.name.isEmpty || !saved.language.isEmpty || !saved.languageName.isEmpty
            return !hasMetadata ||
                Self.sameTrackText(track.name, saved.name) ||
                Self.sameTrackText(track.language, saved.language) ||
                Self.sameTrackText(track.languageName, saved.languageName)
        }) { return track }
        if let track = audioTracks.first(where: {
            Self.sameTrackText($0.name, saved.name) &&
            Self.sameTrackText($0.language, saved.language)
        }) { return track }
        if let track = audioTracks.first(where: {
            Self.sameTrackText($0.name, saved.name) &&
            Self.sameTrackText($0.languageName, saved.languageName)
        }) { return track }
        if !saved.language.isEmpty,
           let track = audioTracks.first(where: { Self.sameTrackText($0.language, saved.language) }) {
            return track
        }
        if !saved.languageName.isEmpty,
           let track = audioTracks.first(where: { Self.sameTrackText($0.languageName, saved.languageName) }) {
            return track
        }
        return nil
    }

    private func matchingEmbeddedSubtitleTrack(for saved: PlayerTrackSelection.Subtitle) -> SubtitleTrack? {
        let candidates = subtitles.filter { $0.id != "off" && $0.externalFilename.isEmpty }
        if let id = saved.id,
           let track = candidates.first(where: { track in
               guard track.id == id else { return false }
               let hasMetadata = !(saved.name ?? "").isEmpty || !(saved.language ?? "").isEmpty
               return !hasMetadata ||
                   Self.sameTrackText(track.name, saved.name) ||
                   Self.sameTrackText(track.language, saved.language)
           }) {
            return track
        }
        if let track = candidates.first(where: {
            Self.sameTrackText($0.name, saved.name) &&
            Self.sameTrackText($0.language, saved.language)
        }) { return track }
        if let language = saved.language, !language.isEmpty,
           let track = candidates.first(where: { Self.sameTrackText($0.language, language) }) {
            return track
        }
        return nil
    }

    private func audioTrack(_ track: AudioTrack, matches language: String) -> Bool {
        SubtitleLanguagePreferences.matches(track.language, target: language) ||
        SubtitleLanguagePreferences.matches(track.languageName, target: language) ||
        SubtitleLanguagePreferences.matches(track.name, target: language)
    }

    private func subtitleTrack(_ track: SubtitleTrack, matches language: String) -> Bool {
        track.id != "off" &&
        (SubtitleLanguagePreferences.matches(track.language, target: language) ||
         SubtitleLanguagePreferences.matches(track.name, target: language))
    }

    private static func sameTrackText(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !left.isEmpty && left == right
    }

    // MARK: - Controls visibility

    func scheduleControlsHide(after interval: TimeInterval? = nil) {
        controlsHideTimer?.invalidate()
        let timeout = interval ?? (isTimelineFocused ? 5.0 : 10.0)
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.controlsAutoHideSuspended else { return }
                guard !self.isHoldingSeek else { return }
                guard !self.showSettingsPanel else { return }
                guard self.sidePanel == nil else { return }
                guard !self.isScrubbing else { return }
                self.showControls = false
                self.updateSkipIntervalState()
            }
        }
    }

    func toggleControls() {
        showControls.toggle()
        updateSkipIntervalState()
        if showControls { scheduleControlsHide() }
    }

    func hideControls() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        controlsAutoHideSuspended = false
        cancelPauseOverlaySchedule()
        showControls = false
        isTimelineFocused = false
        updateSkipIntervalState()
    }

    func revealControls() {
        hidePeek()
        if isScrubbing { return }
        // Full transport chrome supersedes the pause metadata sheet.
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        showControls = true
        isTimelineFocused = true
        updateSkipIntervalState()
        if status == .playing {
            scheduleControlsHide()
        }
    }

    /// Dismisses the pause sheet without resuming (e.g. Menu / open settings).
    func dismissPauseOverlay() {
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
    }

    // MARK: - Side panels (episodes / sources)

    var canShowEpisodesPanel: Bool {
        !seriesEpisodes.isEmpty && subtitle != PlaybackMarkers.trailerSubtitle
    }

    var canShowSourcesPanel: Bool {
        fetchPlaybackSources != nil && subtitle != PlaybackMarkers.trailerSubtitle
    }

    var panelEpisodes: [NuvioVideo] {
        guard let current = currentEpisodeVideo else { return seriesEpisodes }
        // Same season first (current season), then the rest in order.
        let season = current.season
        let same = seriesEpisodes.filter { $0.season == season }
        return same.isEmpty ? seriesEpisodes : same
    }

    var panelCurrentEpisodeId: String? {
        currentEpisodeVideo?.id
    }

    func openSidePanel(_ panel: PlayerSidePanel) {
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        showSettingsPanel = false
        controlsHideTimer?.invalidate()
        controlsAutoHideSuspended = true
        sidePanel = panel
        showControls = false
        if panel == .sources {
            loadSourcesIfNeeded(force: true)
        }
    }

    func closeSidePanel() {
        sidePanel = nil
        controlsAutoHideSuspended = false
        if status == .paused {
            showControls = false
            schedulePauseOverlay()
        } else {
            showControls = true
            scheduleControlsHide()
        }
    }

    private var panelSourceContentId: String? {
        currentEpisodeVideo?.id ?? activeMeta?.id
    }

    private var panelSourceContentType: String {
        if currentEpisodeVideo != nil { return "series" }
        return activeMeta?.type ?? "movie"
    }

    private var panelSourceSubtitleLine: String {
        if let episode = currentEpisodeVideo {
            return "S\(episode.season) · E\(episode.episode) · \(episode.title)"
        }
        return subtitle
    }

    func loadSourcesIfNeeded(force: Bool = false) {
        guard let fetchPlaybackSources,
              let contentId = panelSourceContentId else { return }
        guard force || availableSources.isEmpty, !isLoadingSources else { return }
        sourcesFetchTask?.cancel()
        sourcesLoadGeneration &+= 1
        let generation = sourcesLoadGeneration
        isLoadingSources = true
        let type = panelSourceContentType
        let updates = fetchPlaybackSources(contentId, type)
        sourcesFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.sourcesLoadGeneration == generation {
                    self.sourcesFetchTask = nil
                    self.isLoadingSources = false
                }
            }
            for await streams in updates {
                guard !Task.isCancelled,
                      self.sourcesLoadGeneration == generation else { return }
                self.availableSources = streams
            }
        }
    }

    private func cancelSourcesFetch() {
        sourcesLoadGeneration &+= 1
        sourcesFetchTask?.cancel()
        sourcesFetchTask = nil
        isLoadingSources = false
    }

    func isCurrentSource(_ stream: NuvioStream) -> Bool {
        guard let active = activeStreamURL else { return false }
        if let url = stream.directURL, !url.isEmpty {
            return url == active
        }
        return false
    }

    func selectSource(_ stream: NuvioStream) {
        guard let resolvePlaybackStream,
              let contentId = panelSourceContentId else {
            showPlayerToast("Can't switch sources right now")
            return
        }
        if isCurrentSource(stream) {
            closeSidePanel()
            return
        }
        let resume = lastStablePlaybackTime?.current
            ?? (time.current > 10 ? time.current : nil)
        let subtitleLine = panelSourceSubtitleLine
        beginSourceSwitch(message: "Switching source…")
        // Drop the panel now, not after the resolve: it covers the whole screen,
        // so leaving it up hides the spinner for the entire round trip.
        closeSidePanel()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSwitchingSource = false }
            guard var prepared = await resolvePlaybackStream(stream, contentId, subtitleLine) else {
                self.showPlayerToast("Couldn't open this source")
                self.isAwaitingStreamStart = false
                self.status = .paused
                return
            }
            // The source resolver owns URL/debrid selection, while the source
            // card owns the torrent file identity. A debrid/P2P resolver may
            // choose a different file, so carry the identity only for a direct
            // HTTP(S) stream whose explicit hash and file index survive
            // normalization; otherwise replaceStream clears the prior one.
            let isDirectHTTP = stream.directURL.flatMap(URL.init(string:))?.scheme
                .map { $0.caseInsensitiveCompare("http") == .orderedSame || $0.caseInsensitiveCompare("https") == .orderedSame }
                ?? false
            prepared.cacheFileIdentity = isDirectHTTP
                ? PlaybackCacheFileIdentity(
                    infoHash: stream.effectiveInfoHash,
                    fileIndex: stream.effectiveFileIdx
                )
                : nil
            self.failedStreamURLs.removeAll()
            let group = stream.bingeGroup ?? StreamQualityTags.syntheticBingeGroup(for: stream)
            if let group, !group.isEmpty {
                self.activeBingeGroup = group
            }
            if let meta = self.activeMeta {
                BingeGroupStore.save(seriesId: meta.id, stream: stream)
            }
            self.replaceStream(prepared: prepared, episode: nil, resumeFrom: resume)
            self.showPlayerToast("Source switched")
        }
    }

    /// Shared entry for a user-initiated switch: park the engine and put the
    /// player into a labelled loading state that stays up until the new stream
    /// actually starts.
    private func beginSourceSwitch(message: String) {
        isSwitchingSource = true
        switchingSourceMessage = message
        isAwaitingStreamStart = true
        status = .buffering
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        engine.pausePlayback()
    }

    func selectEpisode(_ episode: NuvioVideo) {
        guard let resolveNextStream else {
            showPlayerToast("Episode switching unavailable")
            return
        }
        if episode.id == currentEpisodeVideo?.id {
            closeSidePanel()
            return
        }
        beginSourceSwitch(message: "Loading episode…")
        closeSidePanel()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSwitchingSource = false }
            guard let prepared = await resolveNextStream(episode) else {
                self.showPlayerToast("Couldn't load this episode")
                self.isAwaitingStreamStart = false
                self.status = .paused
                return
            }
            self.failedStreamURLs.removeAll()
            self.availableSources = []
            self.replaceStream(prepared: prepared, episode: episode, resumeFrom: nil)
        }
    }

    func setAspectMode(_ mode: PlayerAspectMode) {
        aspectMode = mode
        PlayerAspectMode.current = mode
        engine.setAspectMode(mode)
    }

    /// Published accessors for the pause overlay (meta is private).
    var pauseOverlayLogoURL: URL? {
        guard let raw = activeMeta?.logoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var pauseOverlayYear: Int? { activeMeta?.year }

    var pauseOverlayDescription: String? {
        // Prefer episode overview when we have one; fall back to title synopsis.
        if let overview = currentEpisodeVideo?.overview, !overview.isEmpty {
            return overview
        }
        return activeMeta?.description
    }

    var pauseOverlayCast: [String] {
        activeMeta?.cast ?? []
    }

    var pauseOverlayEpisodeLine: String? {
        // For series, `subtitle` is already "S1 · E2 · Title". For movies empty.
        let line = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line != PlaybackMarkers.trailerSubtitle else { return nil }
        return line
    }

    func setControlsAutoHideSuspended(_ suspended: Bool) {
        controlsAutoHideSuspended = suspended
        if suspended {
            controlsHideTimer?.invalidate()
            cancelPauseOverlaySchedule()
            showPauseOverlay = false
            showControls = true
            updateSkipIntervalState()
        } else if showControls {
            if status == .playing {
                scheduleControlsHide()
            } else if status == .paused,
                      subtitle != PlaybackMarkers.trailerSubtitle,
                      !isScrubbing {
                schedulePauseOverlay()
            }
        } else if status == .paused,
                  subtitle != PlaybackMarkers.trailerSubtitle,
                  !isScrubbing {
            schedulePauseOverlay()
        }
    }

    private func applyPendingResumeIfNeeded() {
        guard !didApplyResume,
              let pendingResumeSeconds,
              pendingResumeSeconds > 5,
              time.duration > 0 else {
            return
        }
        guard !loadedStreamLooksLikeReplacement() else { return }

        didApplyResume = true
        seek(to: min(pendingResumeSeconds, max(time.duration - 5, 0)))
    }

    private func saveProgressIfNeeded() {
        guard isTrackablePlayback else { return }
        guard status == .playing else { return }
        // Start a Trakt scrobble promptly so its remote Continue Watching feed
        // has an entry before the user leaves the player. Subsequent saves keep
        // the normal cadence (and Trakt's separate 30-second report cadence).
        let interval: TimeInterval = usesTraktProgress && !didStartTraktScrobble ? 1 : 5
        guard Date().timeIntervalSince(lastProgressSave) >= interval else { return }
        saveProgress(force: false, isPeriodicHeartbeat: true)
    }

    func saveProgress(
        force: Bool,
        eventAction: TraktScrobbleAction? = nil,
        isPeriodicHeartbeat: Bool = false
    ) {
        guard !isLiveStream else { return }
        // Never persist progress during an Aether→MPV handoff.
        if sessionCoordinator.isProgressSaveSuspended { return }
        let checkpointTime = explicitSeekProgressCheckpoint.flatMap { checkpoint in
            Date().timeIntervalSince(checkpoint.createdAt) < Self.explicitSeekSettleWindow
                ? checkpoint.time
                : nil
        }
        let progressTime = checkpointTime ?? (force ? (lastStablePlaybackTime ?? time) : time)
        if isPeriodicHeartbeat, !force {
            if let lastSavedProgressPosition,
               abs(progressTime.current - lastSavedProgressPosition) < 2.0 {
                return
            }
        }
        // Nuvio Sync retains the 10-second accidental-playback safeguard. A
        // Trakt start scrobble is the source of its Continue Watching row, so
        // send it once playback has genuinely begun instead of waiting 10+ s.
        let minimumProgressSeconds: Double = usesTraktProgress ? 1 : 10
        guard let activeMeta,
              let activeStreamURL,
              progressTime.current.isFinite,
              progressTime.duration.isFinite,
              progressTime.current > 0,
              progressTime.duration > 0,
              progressTime.current < progressTime.duration,
              isTrackablePlayback,
              !loadedStreamLooksLikeReplacement(),
              !didDetectReplacementStream,
              !isAwaitingStreamStart || didApplyResume,
              progressTime.current >= minimumProgressSeconds || (force && didApplyResume && progressTime.current > 5) else {
            return
        }

        if shouldSaveNextUpProgress(at: progressTime), let nextEpisode {
            markWatchedIfNeeded()
            if usesTraktProgress {
                reportTraktProgress(
                    meta: activeMeta,
                    playbackTime: progressTime,
                    action: .stop,
                    force: true
                )
            } else {
                // The card is up because this episode reached its ending, so
                // retire it in the ledger before suggesting the next one.
                ContinueWatchingStore.markPlaybackCompleted(
                    meta: activeMeta,
                    duration: progressTime.duration,
                    season: resolvedEpisodeNumbers?.season,
                    episode: resolvedEpisodeNumbers?.episode
                )
                ContinueWatchingStore.saveUpNext(
                    meta: activeMeta,
                    duration: progressTime.duration,
                    season: nextEpisode.season,
                    episode: nextEpisode.episode,
                    released: nextEpisode.released,
                    seedSeason: resolvedEpisodeNumbers?.season
                )
            }
            lastSavedProgressPosition = progressTime.current
            lastProgressSave = Date()
            NuvioSyncManager.current?.flushPendingPushes()
            return
        }

        let season = resolvedEpisodeNumbers?.season
        let episode = resolvedEpisodeNumbers?.episode
        let completesPlayback = shouldMarkAsWatched(at: progressTime)
        if !completesPlayback {
            LastPlaybackStreamStore.save(
                metaId: activeMeta.id,
                url: activeStreamURL,
                httpHeaders: activeHTTPHeaders,
                season: season,
                episode: episode
            )
        }
        if usesTraktProgress {
            reportTraktProgress(
                meta: activeMeta,
                playbackTime: progressTime,
                action: completesPlayback ? .stop : eventAction,
                force: force || completesPlayback,
                isPeriodicHeartbeat: isPeriodicHeartbeat
            )
        } else if completesPlayback {
            // Record completion, not the raw position. An ending marker fires
            // during the credits — well before the 90% the ledger needs to call
            // an episode finished — so saving the literal position left the row
            // as resume progress ("8m left") that could never seed the next
            // episode, while the title was simultaneously marked watched.
            ContinueWatchingStore.markPlaybackCompleted(
                meta: activeMeta,
                duration: progressTime.duration,
                season: season,
                episode: episode
            )
            if let nextEpisode {
                ContinueWatchingStore.saveUpNext(
                    meta: activeMeta,
                    duration: max(progressTime.duration, 120),
                    season: nextEpisode.season,
                    episode: nextEpisode.episode,
                    released: nextEpisode.released,
                    seedSeason: season
                )
            }
        } else {
            ContinueWatchingStore.save(
                meta: activeMeta,
                streamUrl: activeStreamURL,
                position: progressTime.current,
                duration: progressTime.duration,
                season: season,
                episode: episode,
                episodeId: currentEpisodeVideo?.id
            )
        }
        lastSavedProgressPosition = progressTime.current
        lastProgressSave = Date()

        // Ending start / 90% — checkmark without sitting through the credits.
        if completesPlayback {
            markWatchedIfNeeded()
        }

        if force || completesPlayback {
            NuvioSyncManager.current?.flushPendingPushes()
        }
    }

    private var usesTraktProgress: Bool {
        RemoteTrackingState.isProgressSourceAuthenticated
    }

    /// Trailers use the movie's metadata for artwork and playback, but are not
    /// playback of that movie. Keep the marker check as a compatibility
    /// fallback while the session flag protects against subtitle changes.
    static func shouldTrackPlayback(subtitle: String, isTrailerSession: Bool) -> Bool {
        !isTrailerSession && subtitle != PlaybackMarkers.trailerSubtitle
    }

    private var isTrackablePlayback: Bool {
        Self.shouldTrackPlayback(
            subtitle: subtitle,
            isTrailerSession: isTrailerPlaybackSession
        )
    }

    private func reportTraktProgress(
        meta: NuvioMeta,
        playbackTime: PlayerTime,
        action: TraktScrobbleAction?,
        force: Bool,
        isPeriodicHeartbeat: Bool = false
    ) {
        guard isTrackablePlayback else { return }
        guard playbackTime.current.isFinite,
              playbackTime.duration.isFinite,
              playbackTime.current > 0,
              playbackTime.duration > 0 else {
            return
        }

        let episodeNumbers = resolvedEpisodeNumbers
        if TraktSettingsStore.watchProgressSource == .simkl,
           didStartTraktScrobble,
           action == nil,
           isPeriodicHeartbeat,
           !force {
            // Simkl extrapolates between real player events and explicitly
            // warns against periodic heartbeat scrobbles. Keep the optimistic
            // local resume point current without making another API request.
            TraktProgressService.recordLocalPlayback(
                meta: meta,
                position: playbackTime.current,
                duration: playbackTime.duration,
                season: episodeNumbers?.season,
                episode: episodeNumbers?.episode,
                notify: false
            )
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastTraktProgressReport) >= Self.traktProgressReportInterval else {
            return
        }

        let scrobbleAction = action
            ?? (isPeriodicHeartbeat ? .start : (didStartTraktScrobble ? .pause : .start))
        if scrobbleAction == .stop, didQueueTraktStop { return }
        didStartTraktScrobble = true
        if scrobbleAction == .stop { didQueueTraktStop = true }
        lastTraktProgressReport = now
        let traktStore = ProfileSettings.current

        TraktProgressService.recordLocalPlayback(
            meta: meta,
            position: playbackTime.current,
            duration: playbackTime.duration,
            season: episodeNumbers?.season,
            episode: episodeNumbers?.episode,
            notify: force
        )

        let previousTask = traktProgressTask
        traktProgressTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            let succeeded = await TraktProgressService.reportPlayback(
                meta: meta,
                position: playbackTime.current,
                duration: playbackTime.duration,
                season: episodeNumbers?.season,
                episode: episodeNumbers?.episode,
                action: scrobbleAction,
                store: traktStore
            )
            if scrobbleAction == .stop, !succeeded {
                self?.didQueueTraktStop = false
            }
        }
    }

    private func shouldSaveNextUpProgress(at playbackTime: PlayerTime) -> Bool {
        guard showNextEpisodeCard,
              nextEpisode != nil,
              playbackTime.duration >= 60 else {
            return false
        }
        // Mirror card presentation: ending-marker path or lead-seconds fallback.
        return shouldPresentNextEpisodeCard
    }

    /// When to stamp the episode/title watched during an in-progress save.
    /// Aligns with Skip Ending / Next Episode when IntroDB has an outro so a
    /// user who leaves during credits still gets the checkmark.
    private func shouldMarkAsWatched(at playbackTime: PlayerTime) -> Bool {
        guard isTrackablePlayback else { return false }
        guard playbackTime.duration >= 60,
              playbackTime.current > 0,
              playbackTime.current / playbackTime.duration >= 0.5 else {
            return false
        }
        if let ending = skipIntervals.first(where: \.isEnding),
           playbackTime.current >= max(ending.startTime - Self.skipSegmentStartLead, 0) {
            return true
        }
        let completionThreshold = TraktSettingsStore.watchProgressSource == .mdblist
            ? MdbListProgressService.completionPercent / 100
            : WatchProgressLedger.completionFraction
        return playbackTime.current / playbackTime.duration >= completionThreshold
    }

    /// Season/episode for the item currently playing. Prefer the structured
    /// episode object from Details / auto-advance; fall back to parsing the
    /// player subtitle line or stream filename so a format mismatch cannot
    /// drop the mark as a whole-title entry (which the episode strip ignores).
    private var resolvedEpisodeNumbers: (season: Int, episode: Int)? {
        if let current = currentEpisodeVideo, current.season > 0 || current.episode > 0 {
            return (current.season, current.episode)
        }
        return activeEpisodeNumbers
    }

    /// Marks the current playback watched — the specific episode for series,
    /// the title itself for movies. Skips if already marked so repeated ticks
    /// past the threshold don't rewrite the store.
    private func markWatchedIfNeeded() {
        guard isTrackablePlayback else { return }
        guard let activeMeta else { return }
        let numbers = resolvedEpisodeNumbers
        let season = numbers?.season
        let episode = numbers?.episode
        if let season, let episode {
            guard !WatchedStore.containsEpisode(meta: activeMeta, season: season, episode: episode) else {
                return
            }
        } else {
            // Series without resolved S/E must not write a whole-title mark —
            // that would checkmark the poster but never the episode card.
            if activeMeta.isSeries { return }
            guard !WatchedStore.contains(meta: activeMeta) else { return }
        }
        WatchedStore.markWatched(activeMeta, season: season, episode: episode)
    }

    /// Extracts "S1 · E3" from the episode subtitle DetailsScreen passes along
    /// (see `pendingEpisodeSubtitle`). Movies use an empty subtitle → nil.
    /// Accepts middle-dot / dash / plain spacing so a typography change cannot
    /// silently leave `activeEpisodeNumbers` nil.
    private static func episodeNumbers(fromSubtitle subtitle: String) -> (season: Int, episode: Int)? {
        let pattern = #"^S(\d+)\s*[·.\-–—]?\s*E(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(subtitle.startIndex..<subtitle.endIndex, in: subtitle)
        guard let match = regex.firstMatch(in: subtitle, options: [], range: range),
              match.numberOfRanges >= 3,
              let seasonRange = Range(match.range(at: 1), in: subtitle),
              let episodeRange = Range(match.range(at: 2), in: subtitle),
              let season = Int(subtitle[seasonRange]),
              let episode = Int(subtitle[episodeRange]) else {
            return nil
        }
        return (season, episode)
    }

    /// Fallback for series resumes that predate episode tracking (their entry
    /// carries no episode, and the resume path can't say which one it was):
    /// series stream URLs are release filenames, which almost always carry an
    /// "S01E03"-style tag.
    private static func episodeNumbers(fromStreamURL url: String, isSeries: Bool) -> (season: Int, episode: Int)? {
        guard isSeries else { return nil }
        return EpisodeTagResolver.episodeNumbers(in: url)
    }

    // MARK: - Expired-link / replacement-stream detection

    /// True when the file mpv actually opened can't be the title we set out to
    /// play. Stream hosts answer an expired link with a short "slate" clip that
    /// decodes cleanly (no mpv error), so the only tell is its length: it is far
    /// shorter than the content we meant to resume. Judged against the duration
    /// we expected (prior Continue Watching entry or metadata runtime) and the
    /// resume point — you can't be 40 min into a 2 min file.
    private func loadedStreamLooksLikeReplacement() -> Bool {
        let loaded = time.duration
        guard loaded > 0 else { return false }

        if let resume = pendingResumeSeconds, resume > loaded + 60 {
            return true
        }
        if let expected = expectedDurationSeconds, expected >= 60, loaded < expected * 0.5 {
            return true
        }
        if subtitle != PlaybackMarkers.trailerSubtitle, !isLiveStream, loaded < 180 {
            return true
        }
        return false
    }

    /// Confirms — with a short debounce so a transient duration read can't trip
    /// it — that the loaded file is a replacement/expired-link slate, then
    /// pauses and surfaces an error. Returns true once handled so the caller
    /// skips all progress bookkeeping. Idempotent after the first detection.
    private func detectReplacementStream(_ c: PlaybackEngineControlling) -> Bool {
        // A reload is already resolving/loading a fresh stream — treat the old
        // slate as handled so no bookkeeping runs against it.
        if isReloadingStream { return true }
        if didDetectReplacementStream { return true }

        // Judge only once the file has loaded; while opening, engines report a
        // zero/partial duration that would read as a false mismatch.
        guard !c.isPlayerLoading, loadedStreamLooksLikeReplacement() else {
            replacementStreamHits = 0
            return false
        }

        replacementStreamHits += 1
        guard replacementStreamHits >= Self.replacementConfirmTicks else { return false }

        didDetectReplacementStream = true
        engine.pausePlayback()
        lastStablePlaybackTime = nil
        explicitSeekProgressCheckpoint = nil
        if let meta = activeMeta {
            let numbers = resolvedEpisodeNumbers
            LastPlaybackStreamStore.remove(metaId: meta.id, season: numbers?.season, episode: numbers?.episode)
        }
        // Try to silently reload a fresh link before surfacing the error.
        recoverExpiredStream()
        return true
    }

    private static func expectedDuration(for meta: NuvioMeta) -> Double? {
        if let stored = ContinueWatchingStore.item(for: meta.id)?.duration, stored >= 60 {
            return stored
        }
        return runtimeSeconds(from: meta.runtime)
    }

    /// Parses a Stremio/Cinemeta runtime string ("115 min", "1h 55min", "120")
    /// into seconds. Mirrors the runtime parsing in the details metadata row.
    private static func runtimeSeconds(from runtime: String?) -> Double? {
        guard let runtime = runtime?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !runtime.isEmpty else {
            return nil
        }

        func firstNumber(_ pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: runtime, range: NSRange(runtime.startIndex..., in: runtime)),
                  let range = Range(match.range(at: 1), in: runtime) else {
                return nil
            }
            return Int(runtime[range])
        }

        let hours = firstNumber(#"(\d+)\s*h"#)
        let minutes = firstNumber(#"(\d+)\s*m(?:in)?"#)
        let totalMinutes: Int?
        if hours != nil || minutes != nil {
            totalMinutes = (hours ?? 0) * 60 + (minutes ?? 0)
        } else {
            totalMinutes = Int(runtime.filter(\.isNumber))
        }

        guard let totalMinutes, totalMinutes > 0 else { return nil }
        return Double(totalMinutes) * 60
    }

    private static func youtubeVideoId(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")

        if host == "youtu.be" {
            let id = url.pathComponents.dropFirst().first ?? ""
            return isYouTubeVideoId(id) ? id : nil
        }

        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            return nil
        }

        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value,
           isYouTubeVideoId(id) {
            return id
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2,
              ["embed", "shorts", "live"].contains(components[0]),
              isYouTubeVideoId(components[1]) else {
            return nil
        }

        return components[1]
    }

    private static func isYouTubeVideoId(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { char in
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }
    }

    // MARK: - Picture in Picture Methods

    func startPictureInPicture() {
        PictureInPictureManager.shared.startPictureInPicture()
    }

    func stopPictureInPicture() {
        PictureInPictureManager.shared.stopPictureInPicture()
    }

    func togglePictureInPicture() {
        if isPictureInPictureActive {
            stopPictureInPicture()
        } else {
            startPictureInPicture()
        }
    }

    private func setupPipObservers() {
        isPictureInPictureActive = PictureInPictureManager.shared.isPictureInPictureActive
        isPictureInPicturePossible = PictureInPictureManager.shared.isPictureInPicturePossible

        PictureInPictureManager.shared.$isPictureInPictureActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isPictureInPictureActive = active
            }
            .store(in: &cancellables)

        PictureInPictureManager.shared.$isPictureInPicturePossible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] possible in
                self?.isPictureInPicturePossible = possible
            }
            .store(in: &cancellables)
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.currentAudioRouteDescription = PlaybackSystemMonitor.currentAudioOutputTitle()
        }
    }
}

// MARK: - Per-episode player track selections

private struct PlayerTrackSelection: Codable {
    struct Audio: Codable {
        let id: String
        let name: String
        let language: String
        let languageName: String
    }

    struct Subtitle: Codable {
        enum Kind: String, Codable {
            case off
            case embedded
            case external
        }

        let kind: Kind
        var id: String?
        var name: String?
        var language: String?
        var externalURL: String?
    }

    var audio: Audio?
    var subtitle: Subtitle?
    var updatedAt: Date = Date()
}

private enum PlayerTrackSelectionStore {
    private static let maxItems = 300

    static func key(meta: NuvioMeta, episode: (season: Int, episode: Int)?) -> String {
        if let episode {
            return "\(meta.type):\(meta.id):s\(episode.season)e\(episode.episode)"
        }
        return "\(meta.type):\(meta.id)"
    }

    static func selection(for key: String) -> PlayerTrackSelection? {
        selections()[key]
    }

    static func saveAudio(_ audio: PlayerTrackSelection.Audio, for key: String) {
        var all = selections()
        var selection = all[key] ?? PlayerTrackSelection()
        selection.audio = audio
        selection.updatedAt = Date()
        all[key] = selection
        persist(all)
    }

    static func saveSubtitle(_ subtitle: PlayerTrackSelection.Subtitle, for key: String) {
        var all = selections()
        var selection = all[key] ?? PlayerTrackSelection()
        selection.subtitle = subtitle
        selection.updatedAt = Date()
        all[key] = selection
        persist(all)
    }

    private static func selections() -> [String: PlayerTrackSelection] {
        guard let json = ProfileSettings.current.string(forKey: SettingsKey.playbackTrackSelections),
              let data = json.data(using: .utf8),
              let selections = try? JSONDecoder().decode([String: PlayerTrackSelection].self, from: data) else {
            return [:]
        }
        return selections
    }

    private static func persist(_ selections: [String: PlayerTrackSelection]) {
        let trimmed = Dictionary(
            uniqueKeysWithValues: selections
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maxItems)
                .map { ($0.key, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(trimmed),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        ProfileSettings.current.set(json, forKey: SettingsKey.playbackTrackSelections)
    }
}
