import Foundation
import Combine
import SwiftUI
import AetherEngine

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

struct PlayerErrorRecoveryProgress {
    private(set) var firstPosition: Double
    private(set) var firstObservedUptime: TimeInterval
    private(set) var lastPosition: Double
    private(set) var advancingSamples = 1

    init(position: Double, uptime: TimeInterval) {
        firstPosition = position
        firstObservedUptime = uptime
        lastPosition = position
    }

    mutating func observe(position: Double, uptime: TimeInterval) -> Bool {
        guard position.isFinite, uptime.isFinite else { return false }
        if position < lastPosition - 0.02 {
            self = PlayerErrorRecoveryProgress(position: position, uptime: uptime)
            return false
        }
        guard position > lastPosition + 0.01 else { return false }
        lastPosition = position
        advancingSamples += 1
        return advancingSamples >= 3
            && position - firstPosition >= 0.5
            && uptime - firstObservedUptime >= 0.45
    }
}

enum ScenePlaybackPollTransition: Equatable {
    case none
    case paused
    case resumed
}

struct WatchPartyRoomCreationSnapshot {
    let media: WatchPartyMedia
    let paused: Bool
    let positionMs: Int64
    let rate: Float
    fileprivate let stamp: WatchPartyPlayerStamp
    fileprivate let sourceURL: String
    fileprivate let sourceID: String?
    fileprivate let episodeID: String?
    fileprivate let season: Int?
    fileprivate let episode: Int?
    fileprivate let transportIntentRevision: UInt64
}

@MainActor
struct WatchPartyIncomingEpisodePlan {
    typealias Completion = @MainActor (
        UUID, WatchPartyPlaybackContext, WatchPartyMedia, NuvioVideo, PreparedNextStream, UUID
    ) async -> Bool

    let episode: NuvioVideo
    let title: String
    let resolve: (NuvioVideo, UUID?) async -> PreparedNextStream?
    let complete: Completion
}

enum WatchPartyRoomCreationError: Error {
    case unsupportedMedia
    case invalidEpisode
    case transitionInProgress
    case playbackNotReady
    case stalePlayback

    var message: String {
        switch self {
        case .unsupportedMedia:
            return "Live streams, trailers, and previews can't host a Watch Party."
        case .invalidEpisode:
            return "Watch Party couldn't identify this episode. Start a numbered episode and try again."
        case .transitionInProgress:
            return "Wait for the source or episode change to finish before creating a room."
        case .playbackNotReady:
            return "Playback needs to be ready before creating a room."
        case .stalePlayback:
            return "Playback changed while the room was being created."
        }
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

struct PlayerToastItem: Equatable, Sendable, ExpressibleByStringLiteral {
    var message: String
    var avatarURL: String? = nil
    var avatarColor: String? = nil
    var initials: String? = nil
    var senderName: String? = nil

    init(
        message: String,
        avatarURL: String? = nil,
        avatarColor: String? = nil,
        initials: String? = nil,
        senderName: String? = nil
    ) {
        self.message = message
        self.avatarURL = avatarURL
        self.avatarColor = avatarColor
        self.initials = initials
        self.senderName = senderName
    }

    init(stringLiteral value: String) {
        self.init(message: value)
    }
}

// MARK: - PlayerViewModel (Aether + MPV)
//
// Default backend is AetherEngine (hardware or software decode). MPVKit is the
// one-way compatibility fallback.

@MainActor
class PlayerViewModel: ObservableObject {
    enum AutomaticSubtitlePolicy: Equatable {
        case preferredLanguages([String])
        case forced(language: String)
        case off
    }

    @Published var status: PlayerStatus = .idle {
        didSet {
            if case .error = status, oldValue != status {
                PlaybackTimelineRecorder.record(.playbackError, engine: activeEngineKind)
            }
            guard case .error(let message) = status,
                  ProfileSettings.current.bool(forKey: SettingsKey.playbackDiagnostics) else { return }
            // Polling can assign the same error repeatedly. Bound diagnostic work
            // independently of error text, which may contain signed URLs.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPlaybackIssueReportUptime >= 5 else { return }
            lastPlaybackIssueReportUptime = now
            PlaybackIssueReportStore.enqueue(PlaybackIssueReport(
                message: message,
                streamURL: activeStreamURL.flatMap(URL.init(string:)),
                engine: activeEngineKind,
                isLive: isLiveStream,
                renderedFirstFrame: hasRenderedFirstFrame,
                position: self.time.current,
                duration: self.time.duration
            ))
        }
    }
    private var scenePauseIntentPending = false
    private var scenePauseAlreadyNotified = false
    private var lastPlaybackIssueReportUptime = -Double.infinity
    var time: PlayerTime = PlayerTime()
    /// High-frequency time/scrub state for HUDs. Mirrors `time` on each tick.
    let clock = PlaybackClock()
    @Published var subtitles: [SubtitleTrack] = []
    @Published var audioTracks: [AudioTrack] = []
    @Published var playbackSpeed: PlaybackSpeed = .normal
    @Published var seekStepSeconds: Int = PlayerSeekSettings.current
    @Published var qualities: [QualityOption] = [.auto]
    @Published var currentQuality: QualityOption = .auto
    @Published var showControls: Bool = false {
        didSet {
            if oldValue != showControls {
                PlaybackTimelineRecorder.record(showControls ? .controlsShown : .controlsHidden, engine: activeEngineKind)
            }
        }
    }
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
    /// Current audio delay in milliseconds. Persisted across sessions when `isAudioDelayPersistEnabled` is true.
    @Published var audioDelayMs: Int = ProfileSettings.current.bool(forKey: SettingsKey.audioDelayPersistEnabled)
        ? ProfileSettings.current.integer(forKey: SettingsKey.persistentAudioDelayMs)
        : 0
    /// PCM amplification in whole dB (0…10), applied as mpv software volume.
    /// Per-session, not persisted.
    @Published var audioAmplificationDb: Int = 0
    /// Active Dialogue Enhancement mode (Off / Enhance / Boost).
    @Published var enhanceDialogueMode: EnhanceDialogueMode = .off
    /// Active Reduce Loud Sounds toggle state.
    @Published var isReduceLoudSoundsActive: Bool = false
    /// Full-screen settings panel (subtitles / audio / speed) visibility.
    @Published var showSettingsPanel: Bool = false {
        didSet {
            if oldValue != showSettingsPanel {
                PlaybackTimelineRecorder.record(showSettingsPanel ? .settingsOpened : .settingsClosed, engine: activeEngineKind)
            }
            if showSettingsPanel {
                clearNextEpisodeCard()
            }
        }
    }
    /// Active audio route name (e.g. HomePod, TV Speakers, AirPods).
    @Published var currentAudioRouteDescription: String = PlaybackSystemMonitor.currentAudioOutputTitle()
    /// In-player side sheet (episodes / sources).
    @Published var sidePanel: PlayerSidePanel? = nil {
        didSet {
            if (oldValue == nil) != (sidePanel == nil) {
                PlaybackTimelineRecorder.record(sidePanel == nil ? .sidePanelClosed : .sidePanelOpened, engine: activeEngineKind)
            }
            if sidePanel != nil {
                clearNextEpisodeCard()
            }
        }
    }
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
    private let pauseOverlayDelaySeconds: TimeInterval
    private var pauseOverlayGeneration: UInt64 = 0

    // MARK: - Picture in Picture
    var isPictureInPictureSupported: Bool {
        !isStandalonePlaybackSession
            && PictureInPictureManager.shared.isPictureInPictureSupported
            && activeEngineKind == .aether
            && (watchPartyPlayerBridge == nil || aetherController?.canUseWatchPartySoftwarePiP == true)
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
        guard activeSkipInterval != nil, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible, !postPlayState.isVisible, sidePanel == nil else { return false }
        if activeSkipInterval?.id == autoHiddenSkipIntervalId, !showControls { return false }
        return showControls || skipSegmentCountdown != nil
    }

    /// Ordered episode list for the current series (empty for movies/trailers).
    private var seriesEpisodes: [NuvioVideo] = []
    private var currentEpisodeVideo: NuvioVideo?
    /// Resolves a next episode into a ready-to-play stream, provided by the app
    /// layer (reuses the details screen's add-on fetch + smart selection).
    private var resolveNextStream: ((NuvioVideo, UUID?) async -> PreparedNextStream?)?
    private var onWatchPartyEpisodeResolved: (@MainActor (NuvioVideo, PreparedNextStream) async -> Bool)?
    private var onWatchPartyIncomingMediaResolved: WatchPartyIncomingEpisodePlan.Completion?
    var onWatchPartySourceChanged: (@MainActor () async -> Void)?
    private var isCurrentPlayerSurface: @MainActor () -> Bool = { true }
    private var allowsManualEpisodeSelection = true
    private(set) var startupBenchmarkToken: UUID?

    // MARK: - Post-Play Recommendations
    @Published var postPlayState = PostPlayRecommendationUiState()
    let postPlayController = PostPlayRecommendationController()

    var isNextEpisodeMetadataResolved: Bool {
        guard let meta = activeMeta, meta.isSeries else { return true }
        return !seriesEpisodes.isEmpty || currentEpisodeVideo != nil
    }
    private var isAdvanceInFlight: Bool = false
    private var advanceGeneration: UInt64 = 0
    private var lastAdvancedEpisodeId: String? = nil
    private var autoHiddenNextEpisodeCard = false
    private var nextEpisodeAutoHideDeadline: Date?
    private var nextEpisodeAutoPlayDeadline: Date?
    private var watchPartySuspendedAutoPlayWasCancelled: Bool?
    /// While a next-episode resolver is outstanding, engine polls still describe
    /// the previous episode and must not mark that old frame as the new load.
    private var pendingAdvanceResolutionGeneration: UInt64?
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
    @Published private(set) var activeEngineKind: PlayerEngineKind = .aether {
        didSet {
            if oldValue != activeEngineKind {
                PlaybackTimelineRecorder.record(.engineChanged, engine: activeEngineKind)
            }
        }
    }
    /// Short on-screen note after engine selection (native DV vs HDR fallback).
    @Published private(set) var hdrModeToast: String?
    @Published private(set) var playbackDebugInfo: PlaybackDebugInfo?
    @Published private(set) var playbackDebugReason = ""
    @Published private(set) var isPlaybackDebugHUDVisible = false
    @Published private(set) var isPlaybackDebugEnabled = false
    @Published private(set) var trailerDiagnostics: String?
    @Published private(set) var trailerQualityLabel: String?
    @Published private(set) var hasRenderedFirstFrame = false {
        didSet {
            if hasRenderedFirstFrame && !oldValue {
                PlaybackTimelineRecorder.record(.playbackStarted, engine: activeEngineKind)
            }
        }
    }
    private var hasProducedMidFilePosition = false
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
    private(set) var watchPartyPlayerBridge: WatchPartyPlayerBridge?
    private var watchPartyAdmittedMedia: WatchPartyMedia?
    // A received host link is scoped to this player, never a reusable own-source link.
    private var usesWatchPartySharedSource = false
    private var watchPartyTransportIntentRevision: UInt64 = 0
    private var watchPartyLifecycle = PlayerLifecycleAdmission()
    private var watchPartyControls: WatchPartyControlRouter?
    private let adoptsPictureInPictureSession: Bool
    private var isTrailerPlaybackSession = false
    private var isActionPlaybackSession = false

    private var isStandalonePlaybackSession: Bool {
        isTrailerPlaybackSession || isActionPlaybackSession
    }
    private var trailerEndConfirmation = TrailerEndConfirmation()
    private var hasClearedDismissalsForCurrentPlaybackSession = false
    var activeMeta: NuvioMeta?
    private var activeStreamURL: String?
    private var activeSourceID: String?
    private var manualSourceProfileID: String?
    private var didRememberManualSource = false
    private var activeHTTPHeaders: [String: String] = [:]
    private var activePlaybackOrigin: PlaybackOrigin = .main
    private(set) var activeBingeGroup: String?
    private var activeAddonName: String?
    private var activeProviderName: String?
    private var activeFilename: String?
    private var activeCacheFileIdentity: PlaybackCacheFileIdentity?
    private var activeVideoSize: Int64?
    private var activeVideoHash: String?
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
    var pendingExternalSubtitles: [NuvioSubtitle] = []
    private var didAddExternalSubtitles = false
    var addedExternalSubtitleURLs: Set<String> = []
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
    var didApplySubtitlePreference = false
    /// Progressive subtitle fetches may improve an automatic match, but must
    /// never replace a subtitle (including Off) explicitly chosen in the panel.
    var hasExplicitSubtitleSelection = false
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
    private var lastTraktProgressReport = Date.distantPast
    private var traktProgressTask: Task<Void, Never>?
    private static let traktProgressReportInterval: TimeInterval = 30
    private(set) var controlsAutoHideSuspended = false
    private var skipIntervals: [SkipInterval] = []
    private var autoHiddenSkipIntervalId: String?
    /// Segments the user skipped during this playback item. Keep these hidden
    /// even while the asynchronous seek is still reporting the old position.
    private var dismissedSkipIntervalIds: Set<String> = []
    private var autoSkippedIntervalIds: Set<String> = []

    var autoSkipIntroEnabled: Bool {
        get { ProfileSettings.current.bool(forKey: SettingsKey.autoSkipIntro) }
        set { ProfileSettings.current.set(newValue, forKey: SettingsKey.autoSkipIntro) }
    }

    var autoSkipRecapEnabled: Bool {
        get { ProfileSettings.current.bool(forKey: SettingsKey.autoSkipRecap) }
        set { ProfileSettings.current.set(newValue, forKey: SettingsKey.autoSkipRecap) }
    }

    var autoSkipOutroEnabled: Bool {
        get { ProfileSettings.current.bool(forKey: SettingsKey.autoSkipOutro) }
        set { ProfileSettings.current.set(newValue, forKey: SettingsKey.autoSkipOutro) }
    }
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
    private let suppliedSceneCoordinator: SceneCoordinator?
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
    private var touchBeganWhileStatus: PlayerStatus?
    private var wheelLastAngle: Double?
    private let wheelSecondsPerRevolution: Double = 24
    private var gcTouchDown = false
    private var gcTouchStartTime = Date()
    private var gcTouchStartX: Double = 0
    private var gcLastTouchX: Double?
    private var gcLastTouchTime: Date?
    private var gcPanFiredThisTouch = false
    private var gcButtonAPressed = false
    private var gcButtonAPressedStartTime: Date?
    private var gcButtonAPressX: Double?
    private var gcDidHandlePressAsSeek = false
    private var gcHoldSeekTimer: Timer?
    private var controllerConnectObserver: NSObjectProtocol?
    private var peekTask: Task<Void, Never>?
    private var seekDebounceTask: Task<Void, Never>?
    private var lastNudgeAt: Date?
    private var nudgeStreak = 0
    private var didConfigureWheelTracking = false
    private var diskCachedBufferedPosition: Double = 0
    private var diskCachedBytes: Int64 = 0
    private var diskCacheTotalBytes: Int64 = 0
    private var diskCacheConcurrencyStr: String = ""
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
        _ subtitleLine: String,
        _ startupToken: UUID?
    ) async -> PreparedNextStream?)?
    private var reloadAttempts = 0
    @Published private(set) var isReloadingStream = false
    private static let maxReloadAttempts = 3

    // MARK: Load watchdog + source failover

    /// True while a mid-session source switch is resolving/loading.
    @Published private(set) var isSwitchingSource = false
    /// What that switch is doing, shown beside the loading spinner.
    @Published private(set) var switchingSourceMessage = "Trying next source…"
    /// Current step-by-step loading progress message shown in the loading overlay.
    @Published private(set) var loadingStepMessage: String = L10n.string("player_loading_preparing", fallback: "Preparing stream…")
    /// Brief on-screen notice ("Source failed — trying another").
    @Published var playerToast: PlayerToastItem?
    /// URLs that failed to load/play this session (watchdog, mpv error, slate).
    private var failedStreamURLs: Set<String> = []
    private var currentLoadStarted = false
    private struct VMOnlyErrorRecoveryProbe {
        let errorMessage: String
        let sourceURL: String
        let loadGeneration: UInt64
        let engineKind: PlayerEngineKind
        var progress: PlayerErrorRecoveryProgress
    }
    private var vmOnlyErrorRecoveryProbe: VMOnlyErrorRecoveryProbe?
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
        adoptsPictureInPictureSession: Bool = true,
        scrubThumbnailProvider: (any ScrubThumbnailProviding)? = nil,
        pauseOverlayDelaySeconds: TimeInterval = 15,
        sceneCoordinator suppliedSceneCoordinator: SceneCoordinator? = nil
    ) {
        self.adoptsPictureInPictureSession = adoptsPictureInPictureSession
        suppliedScrubThumbnailProvider = scrubThumbnailProvider
        self.suppliedSceneCoordinator = suppliedSceneCoordinator
        self.pauseOverlayDelaySeconds = max(0, pauseOverlayDelaySeconds)
        // A PiP restore creates this view model after the app has already
        // dismissed the original PlayerView. Adopt the retained coordinator
        // before SwiftUI mounts a surface so it never binds a fresh, empty
        // Aether controller for the first render pass.
        sessionCoordinator = suppliedCoordinator ?? (adoptsPictureInPictureSession ? PictureInPictureManager.shared.activeCoordinator : nil)
            ?? PlaybackSessionCoordinator()
        activeEngineKind = sessionCoordinator.activeBackend
        sessionCoordinator.prepareControllers()
        bindSessionCoordinatorCallbacks()
        setupPipObservers()
        postPlayController.$uiState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.postPlayState = state
                if state.isVisible {
                    self.clearNextEpisodeCard()
                    if self.activeSkipInterval != nil { self.activeSkipInterval = nil }
                    if self.skipSegmentCountdown != nil { self.skipSegmentCountdown = nil }
                    self.skipSegmentAutoHideDeadline = nil
                }
            }
            .store(in: &cancellables)
        UsenetEngineManager.shared.$damagedStreamURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, let url else { return }
                self.handleUsenetDamage(url)
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
        bindWatchPartyRemoteControls()
        coordinatorErrorCancellable?.cancel()
        updateCoordinatorLoadError(sessionCoordinator.lastLoadError)
        coordinatorErrorCancellable = sessionCoordinator.$lastLoadError
            .sink { [weak self] error in
                guard let self else { return }
                self.updateCoordinatorLoadError(error)
            }

        let coordinator = sessionCoordinator
        let generation = coordinator.loadGeneration
        let mpv = playerController
        mpv.onWillSuspendPlayback = { [weak self, weak coordinator, weak mpv] in
            guard let self, let coordinator, let mpv, !self.didShutdown,
                  self.sessionCoordinator === coordinator, self.engine === mpv else { return }
            self.suspendWatchPartyForLifecycle(engineWillPark: true)
        }
        mpv.onDidRestorePlayback = { [weak self, weak coordinator, weak mpv] in
            guard let self, let coordinator, let mpv, !self.didShutdown,
                  self.sessionCoordinator === coordinator, self.engine === mpv else { return }
            self.watchPartyEngineDidRestore()
        }
        if let aether = aetherController {
            aether.onWillSuspendPlayback = { [weak self, weak coordinator, weak aether] in
                guard let self, let coordinator, let aether, !self.didShutdown,
                      self.sessionCoordinator === coordinator, self.engine === aether else { return }
                self.suspendWatchPartyForLifecycle(engineWillPark: true)
            }
            aether.onDidRestorePlayback = { [weak self, weak coordinator, weak aether] in
                guard let self, let coordinator, let aether, !self.didShutdown,
                      self.sessionCoordinator === coordinator, self.engine === aether else { return }
                self.watchPartyEngineDidRestore()
            }
        }
        let suspend: (Int64, Int64) -> Void = { [weak self, weak coordinator] positionMs, durationMs in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self, let coordinator,
                      self.sessionCoordinator === coordinator,
                      coordinator.loadGeneration == generation,
                      self.currentLoadPresentationIsConfirmed(
                        engineKind: self.activeEngineKind,
                        generation: generation
                      ) else { return }
                self.playbackDidSuspend(positionMs: positionMs, durationMs: durationMs)
            }
        }
        let firstFrame: () -> Void = { [weak self, weak coordinator] in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self, let coordinator,
                      self.sessionCoordinator === coordinator,
                      coordinator.loadGeneration == generation,
                      self.pendingAdvanceResolutionGeneration == nil,
                      self.currentLoadPresentationIsConfirmed(
                        engineKind: self.activeEngineKind,
                        generation: generation
                      ), self.engine.hasFirstFrameReadyForDisplay else { return }
                if !self.hasRenderedFirstFrame {
                    self.hasRenderedFirstFrame = true
                    if let meta = self.activeMeta {
                        self.prewarmSceneIfNeeded(meta: meta, isTrailerPlayback: self.subtitle == PlaybackMarkers.trailerSubtitle)
                    }
                }
                self.tick()
            }
        }
        playerController.onPlaybackSuspended = suspend
        playerController.onFirstFrameReady = firstFrame
        aetherController?.onPlaybackSuspended = suspend
        aetherController?.onFirstFrameReady = firstFrame
        aetherController?.onStartupProgressChanged = { [weak self] _ in
            self?.updateLoadingStepMessage()
        }
        aetherController?.subtitleTranslationState.onFirstOutcome = { [weak self] outcome in
            self?.handleAISubtitleTranslationOutcome(outcome)
        }
        sessionCoordinator.onAetherControllerChanged = { [weak self] _ in
            guard let self else { return }
            self.bindSessionCoordinatorCallbacks()
            self.updateLoadingStepMessage()
            PictureInPictureManager.shared.refreshController(for: self.sessionCoordinator)
        }
        playerController.subtitleTranslationState.onFirstOutcome = { [weak self] outcome in
            self?.handleAISubtitleTranslationOutcome(outcome)
        }
        sessionCoordinator.prepareForHandoff = { [weak self] req in
            guard let self else { return }
            if let currentAudio = self.audioTracks.first(where: { $0.isSelected }) {
                let saved = PlayerTrackSelection.Audio(
                    id: currentAudio.id,
                    name: currentAudio.name,
                    language: currentAudio.language,
                    languageName: currentAudio.languageName
                )
                self.rememberSessionAudio(saved)
            }
            if let currentSubtitle = self.subtitles.first(where: { $0.isSelected }) {
                let saved = Self.trackSelection(for: currentSubtitle)
                self.rememberSessionSubtitle(saved)
            }

            var seen = Set<String>()
            var allSubs: [NuvioSubtitle] = []
            for sub in (req.externalSubtitles + self.availableExternalSubtitles) {
                if seen.insert(sub.url).inserted {
                    allSubs.append(sub)
                }
            }
            req.externalSubtitles = allSubs
        }
        sessionCoordinator.onHandoffToast = { [weak self] message in
            guard let self else { return }
            self.bindSessionCoordinatorCallbacks()
            PictureInPictureManager.shared.refreshController(for: self.sessionCoordinator)
            self.hdrModeToast = message
            self.showPlayerToast(message)
            self.activeEngineKind = self.sessionCoordinator.activeBackend
            self.resetScrubThumbnailState()
            self.updateLoadingStepMessage()
            if !self.currentLoadStarted,
               !self.hasRenderedFirstFrame,
               !self.livePlaybackHasStarted,
               !self.hasProducedMidFilePosition {
                self.startLoadWatchdog()
            }
            if self.isPlaybackDebugEnabled == true {
                self.playbackDebugHUDBackend = nil
                self.isPlaybackDebugHUDVisible = true
            }

            self.didApplySavedAudioSelection = false
            self.didApplySavedSubtitleSelection = false
            self.didApplyAudioPreference = false
            self.didApplySubtitlePreference = false
            self.addedExternalSubtitleURLs = Set(self.sessionCoordinator.lastRequest?.externalSubtitles.map(\.url) ?? [])
            self.didAddExternalSubtitles = true
            self.audioTracks = []
            self.subtitles = []
        }
    }

    private func updateCoordinatorLoadError(_ error: String?) {
        let previousError = playbackStartupError
        if let error {
            loadWatchdogTask?.cancel()
            loadWatchdogTask = nil
            isAwaitingStreamStart = false

            let isEngineUnavailable = error.contains("unavailable on this device") || error.contains("AetherEngine is unavailable")
            if !isEngineUnavailable,
               !isStandalonePlaybackSession,
               reloadCurrentStream != nil,
               reloadAttempts < Self.maxReloadAttempts,
               !isFailingOver,
               !didShutdown {
                if let url = activeStreamURL { failedStreamURLs.insert(url) }
                if let meta = activeMeta {
                    let numbers = resolvedEpisodeNumbers
                    LastPlaybackStreamStore.remove(metaId: meta.id, season: numbers?.season, episode: numbers?.episode)
                }
                playbackStartupError = nil
                status = .buffering
                attemptFailover(reason: error, toast: nil)
            } else {
                playbackStartupError = error
                status = .error(error)
            }
        } else {
            playbackStartupError = nil
            if let previousError,
               case .error(let statusError) = status,
               statusError == previousError {
                status = .buffering
            }
        }
    }

    var currentErrorDiagnostic: PlaybackErrorDiagnostic? {
        if isFailingOver || isReloadingStream || isSwitchingSource || (!hasRenderedFirstFrame && reloadCurrentStream != nil && reloadAttempts < Self.maxReloadAttempts) {
            return nil
        }
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
        if watchPartyPlayerBridge != nil, UIApplication.shared.applicationState == .active {
            watchPartyLifecycle.engineDidRestore()
            resumeWatchPartyAfterForeground()
        }
        cancelPendingAdvanceResolution()
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        playbackStartupError = nil
        let startupToken = beginStartupBenchmark(title: activeMeta?.name ?? "")
        sessionCoordinator.retryLastLoad(startupBenchmarkToken: startupToken)
        activeEngineKind = sessionCoordinator.activeBackend
        guard sessionCoordinator.lastLoadError == nil else {
            cancelStartupBenchmark(token: startupToken)
            return
        }
        status = .buffering
        isAwaitingStreamStart = true
        hasProducedMidFilePosition = false
        currentLoadStarted = false
        startPolling()
        startLoadWatchdog()
        hdrModeToast = sessionCoordinator.statusToast
    }

    func adoptStartupBenchmarkToken(_ token: UUID?) {
        startupBenchmarkToken = PlaybackStartupTiming.isActive(token: token) ? token : nil
    }

    @discardableResult
    private func beginStartupBenchmark(title: String = "") -> UUID {
        let token = PlaybackStartupTiming.start(title: title)
        startupBenchmarkToken = token
        return token
    }

    func completeStartupBenchmark() -> TimeInterval? {
        guard let token = startupBenchmarkToken else { return nil }
        let total = PlaybackStartupTiming.complete(token: token)
        if startupBenchmarkToken == token, !PlaybackStartupTiming.isActive(token: token) {
            startupBenchmarkToken = nil
        }
        return total
    }

    func cancelStartupBenchmark(token explicitToken: UUID? = nil) {
        guard let token = explicitToken ?? startupBenchmarkToken else { return }
        PlaybackStartupTiming.cancel(token: token)
        if startupBenchmarkToken == token { startupBenchmarkToken = nil }
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
        videoHash: String? = nil,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        trickplayURL: URL? = nil,
        sourceID: String? = nil,
        currentEpisode: NuvioVideo? = nil,
        isActionPlaybackSession: Bool = false
    ) {
        PlaybackTimelineRecorder.record(.playbackLoadRequested)
        let isTrailerPlayback = subtitle == PlaybackMarkers.trailerSubtitle
        self.isActionPlaybackSession = isActionPlaybackSession
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
        activeVideoHash = videoHash
        activeCacheFileIdentity = cacheFileIdentity
        activeTrickplayURL = trickplayURL
        activeSourceID = sourceID
        manualSourceProfileID = ProfileSettings.activeProfileID
        didRememberManualSource = false
        if !hasLoaded { sessionTrackSelection = nil }

        // Adopt active Picture in Picture session if already playing this content
        let pipManager = PictureInPictureManager.shared
        if !isStandalonePlaybackSession, adoptsPictureInPictureSession,
           let activeCoord = pipManager.activeCoordinator,
           pipManager.activeContext?.url == url,
           pipManager.isPictureInPictureActive
            || pipManager.isRestoringUIInProgress
            || sessionCoordinator === activeCoord {
            if cacheFileIdentity == nil {
                activeCacheFileIdentity = pipManager.activeContext?.cacheFileIdentity
            }
            if activeSourceID == nil { activeSourceID = pipManager.activeContext?.sourceID }
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
                currentEpisode: currentEpisode,
                preservesCompletionResumeTarget: true
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
            currentEpisode: currentEpisode,
            beginsNewPlaybackCompletionSession: !hasLoaded
        )
        guard !hasLoaded else { return }
        hasLoaded = true

        if isTrailerPlayback, let youtubeId = Self.youtubeVideoId(from: url) {
            let title = meta.name
            let year = meta.year.map(String.init)
            let resolver = trailerResolver
            let startupToken = startupBenchmarkToken

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
                    guard let self, !Task.isCancelled else { return }
                    let stillOwnsStartup = startupToken == nil
                        ? self.startupBenchmarkToken == nil
                        : self.startupBenchmarkToken == startupToken
                            && PlaybackStartupTiming.isActive(token: startupToken)
                    guard stillOwnsStartup else { return }
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
                        resumePositionSeconds: self.pendingResumeSeconds,
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
                        artworkURL: self.resolveArtworkURL(for: meta, episode: nil, isTrailer: true),
                        nowPlayingTitle: title.isEmpty ? nil : title,
                        nowPlayingSubtitle: "Trailer",
                        startupBenchmarkToken: startupToken
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

        if !isStandalonePlaybackSession {
            let context = ActivePlaybackContext(
                url: url,
                meta: meta,
                subtitle: subtitle,
                httpHeaders: httpHeaders,
                cacheFileIdentity: activeCacheFileIdentity,
                sourceID: activeSourceID,
                externalSubtitles: externalSubtitles,
                resumeFrom: resumeFrom,
                episodes: seriesEpisodes,
                currentEpisode: currentEpisodeVideo,
                autoPlayNextEnabled: autoPlayNextEnabled,
                autoPlayNextCountdownSeconds: autoPlayNextCountdownSeconds,
                playbackOrigin: activePlaybackOrigin,
                filename: activeFilename,
                videoSize: activeVideoSize,
                videoHash: activeVideoHash
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
        let nowPlaying = resolveNowPlayingLabels(for: activeMeta, episode: currentEpisodeVideo, isTrailer: isTrailerPlaybackSession)
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
            isLiveStream: isLiveStream,
            isSports: activeMeta?.isSports ?? false,
            autoplay: watchPartyPlayerBridge == nil,
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
            artworkURL: resolvedArtwork,
            nowPlayingTitle: nowPlaying.title,
            nowPlayingSubtitle: nowPlaying.subtitle,
            startupBenchmarkToken: startupBenchmarkToken
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
        updateLoadingStepMessage()
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
        if id.hasPrefix("iptv:") || id.hasPrefix("live:") || id.hasPrefix("channel:") || id.hasPrefix("stream:")
            || id.hasPrefix("pp-live:") || id.contains("cdnlive") || id.contains("daddylive") || id.contains("streamed.pk") || id.contains("nuvio_sport") {
            return true
        }
        var name = meta.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let first = name.first, !first.isLetter && !first.isNumber && first != "[" && first != "(" {
            name.removeFirst()
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name.hasPrefix("now:") || name.hasPrefix("live:") || name.hasPrefix("[live]") || name.hasPrefix("(live)") {
            return true
        }
        // Only the resource path is a live hint. Hostnames, tokens and fragments are not.
        if let path = url?.path.lowercased() {
            if path.contains("/live/") || path.contains("/iptv/") || path.contains("live.m3u8") || path.contains("cdnlive") {
                return true
            }
        }
        return false
    }

    /// Resolves the remote artwork URL for Now Playing identity card.
    /// Prefers the episode thumbnail for series episodes, falling back to show backdrop/poster.
    /// Prefers movie poster, falling back to movie backdrop for movies.
    /// System Now Playing labels: the show/movie name, with the episode
    /// ("S1, E3 · Title") or year underneath. Stream card names are addon
    /// labels (e.g. "⚡ [TB] 1080p") and must not leak into the Remote app.
    func resolveNowPlayingLabels(for meta: NuvioMeta?, episode: NuvioVideo?, isTrailer: Bool) -> (title: String?, subtitle: String?) {
        guard let meta else { return (nil, nil) }
        let name = meta.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return (nil, nil) }
        if isTrailer { return (name, "Trailer") }
        if let episode, !isStandalonePlaybackSession {
            let code = "S\(episode.season), E\(episode.episode)"
            let episodeTitle = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, episodeTitle.isEmpty ? code : "\(code) · \(episodeTitle)")
        }
        return (name, meta.year.map(String.init))
    }

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
    func applyStreamState(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String] = [:],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        currentEpisode: NuvioVideo? = nil,
        preserveSessionPreferences: Bool = false,
        beginsNewPlaybackCompletionSession: Bool = false,
        preservesCompletionResumeTarget: Bool = false
    ) {
        let isTrailerPlayback = subtitle == PlaybackMarkers.trailerSubtitle
        let isStandalonePlaybackSession = isTrailerPlayback || isActionPlaybackSession
        isTrailerPlaybackSession = isTrailerPlayback
        trailerEndConfirmation.reset()
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
        self.diskCacheConcurrencyStr = ""
        self.diskCachePollTask?.cancel()
        self.diskCachePollTask = nil
        self.clock.scrubTarget = nil
        self.resetScrubSession()
        self.pendingSeekDelta = 0
        self.hidePeek()
        self.activeMeta = meta
        if let currentEpisode {
            if self.currentEpisodeVideo?.id != currentEpisode.id {
                self.lastAdvancedEpisodeId = nil
            }
            self.currentEpisodeVideo = currentEpisode
        }
        // Usenet streams use the same local-server lifecycle as torrents.
        if TorrentEngineManager.shared.activeStreamURL == url || UsenetEngineManager.shared.activeStreamURL == url {
            sessionCoordinator.torrentStreamSourceURL = url
        }
        self.activeStreamURL = url.absoluteString
        self.activeHTTPHeaders = httpHeaders
        if UsenetEngineManager.shared.damagedStreamURL == url {
            Task { @MainActor [weak self] in self?.handleUsenetDamage(url) }
        }
        if !isStandalonePlaybackSession && watchPartyPlayerBridge == nil {
            postPlayController.start(
                contentId: meta.id,
                contentType: meta.isSeries ? "series" : meta.type,
                meta: meta
            )
        } else {
            postPlayController.stop()
        }
        self.activeEpisodeNumbers = isStandalonePlaybackSession
            ? nil
            : Self.episodeNumbers(fromSubtitle: subtitle)
                ?? Self.episodeNumbers(fromStreamURL: url.absoluteString, isSeries: meta.isSeries)
        if isStandalonePlaybackSession {
            self.seriesEpisodes = []
            self.currentEpisodeVideo = nil
            self.resolveNextStream = nil
            self.nextEpisode = nil
        } else if currentEpisodeVideo == nil, meta.isSeries, let numbers = self.activeEpisodeNumbers {
            self.currentEpisodeVideo = meta.videos?.first(where: { $0.season == numbers.season && $0.episode == numbers.episode })
        } else if !meta.isSeries {
            self.currentEpisodeVideo = nil
        }
        if !isStandalonePlaybackSession {
            let completionIdentity = playbackCompletionIdentity(for: meta)
            if beginsNewPlaybackCompletionSession {
                let completionContext = capturePlaybackCompletionContext(profileID: WatchedStore.activeProfileId)
                sessionCoordinator.beginNewPlaybackCompletionSession(
                    identity: completionIdentity,
                    profileID: WatchedStore.activeProfileId,
                    resumeTargetSeconds: resumeFrom,
                    source: completionContext.source,
                    completionAccounts: completionContext.accountIDs
                )
            } else if preservesCompletionResumeTarget {
                sessionCoordinator.preservePlaybackCompletionTargetIdentity(
                    completionIdentity,
                    fallbackProfileID: WatchedStore.activeProfileId
                )
            } else {
                sessionCoordinator.updatePlaybackCompletionTarget(
                    completionIdentity,
                    fallbackProfileID: WatchedStore.activeProfileId,
                    resumeTargetSeconds: resumeFrom
                )
            }
        }
        let selectionKey = isStandalonePlaybackSession
            ? nil
            : PlayerTrackSelectionStore.key(meta: meta, episode: self.activeEpisodeNumbers)
        let savedSelection = selectionKey.flatMap { PlayerTrackSelectionStore.selection(for: $0) }
        if sessionTrackSelection == nil { sessionTrackSelection = savedSelection }
        let effectiveSelection = isStandalonePlaybackSession ? nil : Self.effectiveTrackSelection(
            stored: savedSelection,
            session: sessionTrackSelection,
            externalSubtitles: externalSubtitles
        )
        self.activeTrackSelectionKey = selectionKey
        self.pendingTrackSelection = effectiveSelection
        self.pendingResumeSeconds = isActionPlaybackSession || isLiveStream ? nil : resumeFrom
        self.didApplyResume = false
        self.lastStablePlaybackTime = nil
        self.hasProducedMidFilePosition = false
        self.explicitSeekProgressCheckpoint = nil
        self.didStartTraktScrobble = false
        self.lastTraktProgressReport = .distantPast
        self.expectedDurationSeconds = isStandalonePlaybackSession ? nil : Self.expectedDuration(for: meta)
        self.didDetectReplacementStream = false
        self.replacementStreamHits = 0
        self.hasRenderedFirstFrame = false
        // The full list stays browsable in the subtitle panel; only smart-matched
        // ones are eagerly loaded into mpv (loading all would fetch dozens of files).
        self.availableExternalSubtitles = isStandalonePlaybackSession ? [] : externalSubtitles
        let smartMatched = isStandalonePlaybackSession || effectiveSelection?.subtitle != nil
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
        self.hasClearedDismissalsForCurrentPlaybackSession = false
        if !preserveSessionPreferences {
            self.subtitleDelayMs = 0
            self.audioDelayMs = isAudioDelayPersistEnabled ? persistentAudioDelayMs : 0
            self.audioAmplificationDb = 0
        }
        self.skipIntervals = []
        self.didSeedIntroDBSeasonTemplate = false
        self.didRefreshIntroDBForKnownDuration = false
        self.activeSkipInterval = nil
        self.skipSegmentCountdown = nil
        self.autoHiddenSkipIntervalId = nil
        self.dismissedSkipIntervalIds = []
        self.autoSkippedIntervalIds = []
        self.skipSegmentAutoHideDeadline = nil
        self.showNextEpisodeCard = false
        self.nextEpisodeCountdown = nil
        self.autoHiddenNextEpisodeCard = false
        self.nextEpisodeAutoHideDeadline = nil
        self.nextEpisodeAutoPlayDeadline = nil
        self.skipIntervalLoadTask?.cancel()
        self.didApplySavedAudioSelection = effectiveSelection?.audio == nil
        self.didApplySavedSubtitleSelection = effectiveSelection?.subtitle == nil
        self.didApplyAudioPreference = false
        self.didApplySubtitlePreference = false
        self.hasExplicitSubtitleSelection = false
        self.sceneSessionID = UUID()
        loadSkipIntervalsIfNeeded(meta: meta, isStandalonePlaybackSession: isStandalonePlaybackSession)
    }

    private var effectiveFilename: String? {
        if let activeFilename = activeFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !activeFilename.isEmpty {
            return activeFilename
        }
        if let activeStreamURL, let urlObj = URL(string: activeStreamURL) {
            let last = urlObj.lastPathComponent
            if !last.isEmpty && last != "/" && last.contains(".") {
                let ext = (last as NSString).pathExtension.lowercased()
                let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "webm", "ts", "m4v", "wmv", "iso"]
                if videoExtensions.contains(ext) {
                    return last
                }
            }
        }
        return nil
    }

    /// Starts a subtitle-only refresh independent of stream resolution. Results
    /// merge live into `availableExternalSubtitles`, so an already-open player
    /// Settings panel updates without closing or restarting playback.
    func fetchExternalSubtitles(
        contentId: String,
        type: String,
        videoHash: String? = nil,
        videoSize: Int64? = nil,
        filename: String? = nil
    ) {
        subtitleFetchTask?.cancel()
        guard !isStandalonePlaybackSession else {
            isLoadingExternalSubtitles = false
            return
        }

        var effectiveHash = videoHash ?? activeVideoHash
        var effectiveSize = videoSize ?? activeVideoSize
        let effFilename = filename ?? effectiveFilename

        if (effectiveHash == nil || effectiveSize == nil),
           let streamURL = activeStreamURL.flatMap({ URL(string: $0) }),
           streamURL.isFileURL {
            if let result = OpenSubtitlesHasher.computeHashAndSize(for: streamURL) {
                if effectiveHash == nil { effectiveHash = result.hash }
                if effectiveSize == nil { effectiveSize = result.size }
            }
        }

        isLoadingExternalSubtitles = true
        subtitleFetchTask = Task { @MainActor [weak self] in
            let repository = CinemetaCatalogRepository()
            for await subtitles in repository.subtitlesProgressively(
                id: contentId,
                type: type,
                videoHash: effectiveHash,
                videoSize: effectiveSize,
                filename: effFilename
            ) {
                guard let self, !Task.isCancelled else { return }
                self.mergeExternalSubtitles(subtitles)
            }
            guard let self, !Task.isCancelled else { return }
            self.isLoadingExternalSubtitles = false
            self.subtitleFetchTask = nil
        }
    }

    func mergeExternalSubtitles(_ fetched: [NuvioSubtitle]) {
        guard !fetched.isEmpty else { return }
        var hasChanges = false

        var existingIndices: [String: Int] = [:]
        for (index, sub) in availableExternalSubtitles.enumerated() {
            existingIndices[sub.url] = index
        }

        for sub in fetched {
            if let index = existingIndices[sub.url] {
                let existing = availableExternalSubtitles[index]
                if existing != sub {
                    availableExternalSubtitles[index] = sub
                    hasChanges = true
                    if let pendingIndex = pendingExternalSubtitles.firstIndex(where: { $0.url == sub.url }) {
                        pendingExternalSubtitles[pendingIndex] = sub
                    }
                    if let trackIndex = subtitles.firstIndex(where: { $0.externalFilename == sub.url }) {
                        let existingTrack = subtitles[trackIndex]
                        if let label = sub.label, !label.isEmpty {
                            subtitles[trackIndex] = SubtitleTrack(
                                id: existingTrack.id,
                                name: label,
                                language: existingTrack.language,
                                isSelected: existingTrack.isSelected,
                                externalFilename: existingTrack.externalFilename,
                                isForced: existingTrack.isForced || Self.isForcedSubtitleLabel(label),
                                isNativelyRenderedSubtitle: existingTrack.isNativelyRenderedSubtitle
                            )
                        }
                    }
                }
            } else {
                availableExternalSubtitles.append(sub)
                existingIndices[sub.url] = availableExternalSubtitles.count - 1
                hasChanges = true
            }
        }

        guard hasChanges else { return }

        sessionCoordinator.updateExternalSubtitles(availableExternalSubtitles)

        if isSceneEnabled {
            sceneCoordinator.updateAvailableSubtitles(availableExternalSubtitles)
        }

        if let targetURL = pendingSelectedExternalSubtitleURL ?? pendingTrackSelection?.subtitle?.externalURL,
           let matchingSub = availableExternalSubtitles.first(where: { $0.url == targetURL }),
           !addedExternalSubtitleURLs.contains(matchingSub.url) {
            engine.addSubtitle(matchingSub, select: true)
            addedExternalSubtitleURLs.insert(matchingSub.url)
            didAddExternalSubtitles = true
        }

        // Manual and saved subtitle choices always win over automatic matching.
        guard !hasExplicitSubtitleSelection,
              pendingTrackSelection?.subtitle == nil,
              SubtitleLanguagePreferences.smartMatchingEnabled() else { return }

        let preferredLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        let allowForcedSubtitles = Self.allowsAutomaticForcedSubtitles
        guard let policy = Self.automaticSubtitlePolicy(
            selectedAudio: audioTracks.first(where: { $0.isSelected }),
            preferredAudioLanguage: SubtitleLanguagePreferences.preferredAudioLanguage(meta: activeMeta),
            preferredSubtitleLanguages: preferredLanguages,
            allowForcedSubtitles: allowForcedSubtitles
        ) else { return }

        didApplySubtitlePreference = false
        applySubtitlePreferenceIfNeeded()

        switch policy {
        case .off:
            return

        case .forced(let language):
            let selectedTrack = subtitles.first(where: { $0.isSelected })
            guard !Self.shouldPreserveBackendSubtitleSelection(
                selectedTrack,
                preferredLanguages: [language],
                allowForcedSubtitles: true,
                requireForcedSubtitle: true
            ) else { return }

            let loadedExternalURLs = Set(subtitles.map(\.externalFilename).filter { !$0.isEmpty })
            let hasPendingForcedSubtitle = pendingExternalSubtitles.contains { subtitle in
                !loadedExternalURLs.contains(subtitle.url) &&
                Self.externalSubtitle(subtitle, matches: language, forcedOnly: true)
            }
            guard !hasPendingForcedSubtitle else { return }

            guard let best = availableExternalSubtitles.first(where: {
                Self.externalSubtitle($0, matches: language, forcedOnly: true)
            }),
            !addedExternalSubtitleURLs.contains(best.url),
            !pendingExternalSubtitles.contains(where: { $0.url == best.url }) else { return }

            pendingExternalSubtitles.append(best)
            pendingSelectedExternalSubtitleURL = best.url
            didApplySubtitlePreference = false
            didAddExternalSubtitles = false
            addPendingExternalSubtitlesIfNeeded()

        case .preferredLanguages(let preferredLanguages):
            let hasActivePreferredSubtitle = Self.shouldPreserveBackendSubtitleSelection(
                subtitles.first(where: { $0.isSelected }),
                preferredLanguages: preferredLanguages,
                allowForcedSubtitles: false
            )
            let hasPendingOrAddedSubtitles = !pendingExternalSubtitles.isEmpty || !addedExternalSubtitleURLs.isEmpty
            guard !hasActivePreferredSubtitle, !hasPendingOrAddedSubtitles else { return }

            let smartMatched = Self.smartMatchedSubtitles(in: availableExternalSubtitles)
            guard let best = smartMatched.first,
                  !addedExternalSubtitleURLs.contains(best.url),
                  !pendingExternalSubtitles.contains(where: { $0.url == best.url }) else { return }
            pendingExternalSubtitles.append(best)
            pendingSelectedExternalSubtitleURL = best.url
            didApplySubtitlePreference = false
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
        resolver: @escaping (NuvioVideo, UUID?) async -> PreparedNextStream?,
        allowsManualEpisodeSelection: Bool = true,
        isCurrentPlayerSurface: @escaping @MainActor () -> Bool = { true },
        onWatchPartyEpisodeResolved: (@MainActor (NuvioVideo, PreparedNextStream) async -> Bool)? = nil,
        onWatchPartyIncomingMediaResolved: WatchPartyIncomingEpisodePlan.Completion? = nil
    ) {
        guard !isStandalonePlaybackSession else {
            seriesEpisodes = []
            currentEpisodeVideo = nil
            resolveNextStream = nil
            self.onWatchPartyEpisodeResolved = nil
            self.onWatchPartyIncomingMediaResolved = nil
            self.allowsManualEpisodeSelection = false
            nextEpisode = nil
            clearNextEpisodeCard()
            return
        }
        seriesEpisodes = episodes
        if currentEpisodeVideo?.id != current?.id {
            lastAdvancedEpisodeId = nil
        }
        currentEpisodeVideo = current
        autoPlayNextEnabled = autoPlayEnabled
        autoPlayNextCountdownSeconds = max(1, autoPlayCountdownSeconds)
        resolveNextStream = resolver
        self.allowsManualEpisodeSelection = allowsManualEpisodeSelection
        self.isCurrentPlayerSurface = isCurrentPlayerSurface
        self.onWatchPartyEpisodeResolved = onWatchPartyEpisodeResolved
        self.onWatchPartyIncomingMediaResolved = onWatchPartyIncomingMediaResolved
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
                sourceID: activeSourceID,
                externalSubtitles: pendingExternalSubtitles,
                resumeFrom: pendingResumeSeconds,
                episodes: episodes,
                currentEpisode: current,
                autoPlayNextEnabled: autoPlayEnabled,
                autoPlayNextCountdownSeconds: autoPlayCountdownSeconds,
                playbackOrigin: activePlaybackOrigin,
                filename: activeFilename,
                videoSize: activeVideoSize,
                videoHash: activeVideoHash
            )
            PictureInPictureManager.shared.registerSession(
                coordinator: sessionCoordinator,
                context: context
            )
        }
    }

    /// Breaks closures back into the app root before the checked Watch Party mount is released.
    /// The episode callback may retain that mount, which itself owns this player model.
    func clearWatchPartyTransitionCallbacks() {
        onWatchPartyEpisodeResolved = nil
        onWatchPartyIncomingMediaResolved = nil
        onWatchPartySourceChanged = nil
    }

    func incomingWatchPartyEpisodePlan(for media: WatchPartyMedia) -> WatchPartyIncomingEpisodePlan? {
        guard watchPartyPlayerBridge != nil,
              let activeMeta, activeMeta.isSeries,
              let episode = nextEpisode,
              EpisodeReleasePolicy.hasAired(episode.released),
              let resolver = resolveNextStream,
              let complete = onWatchPartyIncomingMediaResolved,
              let expected = try? WatchPartyLaunchPolicy.mediaForPlayback(
                activeMeta, episode: episode, room: media
              ), expected.key == media.key else { return nil }
        return WatchPartyIncomingEpisodePlan(
            episode: episode,
            title: activeMeta.name,
            resolve: resolver,
            complete: complete
        )
    }

    func resolveIncomingWatchPartyEpisode(
        _ plan: WatchPartyIncomingEpisodePlan,
        media: WatchPartyMedia,
        context: WatchPartyPlaybackContext,
        transitionID: UUID,
        isCurrent: @escaping @MainActor () -> Bool,
        waitUntilReady: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard isCurrent() else { return false }
        let startupToken = PlaybackStartupTiming.start(title: plan.title)
        let prepared = await plan.resolve(plan.episode, startupToken)
        guard let prepared, !Task.isCancelled, isCurrent(),
              nextEpisode?.id == plan.episode.id,
              isIncomingWatchPartyEpisode(plan.episode, matching: media),
              PlaybackStartupTiming.isActive(token: startupToken) else {
            PlaybackStartupTiming.cancel(token: startupToken)
            if let prepared,
               PictureInPictureManager.shared.activeCoordinator?.torrentStreamSourceURL != prepared.url {
                await TorrentEngineManager.shared.stopActiveStream(for: prepared.url)
            }
            return false
        }
        guard await waitUntilReady(), !Task.isCancelled, isCurrent(),
              nextEpisode?.id == plan.episode.id,
              isIncomingWatchPartyEpisode(plan.episode, matching: media) else {
            PlaybackStartupTiming.cancel(token: startupToken)
            if PictureInPictureManager.shared.activeCoordinator?.torrentStreamSourceURL != prepared.url {
                await TorrentEngineManager.shared.stopActiveStream(for: prepared.url)
            }
            return false
        }
        let accepted = await plan.complete(transitionID, context, media, plan.episode, prepared, startupToken)
        guard accepted else {
            PlaybackStartupTiming.cancel(token: startupToken)
            if PictureInPictureManager.shared.activeCoordinator?.torrentStreamSourceURL != prepared.url {
                await TorrentEngineManager.shared.stopActiveStream(for: prepared.url)
            }
            return false
        }
        return true
    }

    func openWatchPartyScene() {
        openScene()
        sceneViewModel.selectTab(.watchParty)
    }

    func isCurrentWatchPartyPlayerSurface() -> Bool {
        isCurrentPlayerSurface()
    }

    private func isIncomingWatchPartyEpisode(_ episode: NuvioVideo, matching media: WatchPartyMedia) -> Bool {
        guard let activeMeta, activeMeta.isSeries,
              nextEpisode?.id == episode.id,
              EpisodeReleasePolicy.hasAired(episode.released),
              let expected = try? WatchPartyLaunchPolicy.mediaForPlayback(
                activeMeta, episode: episode, room: media
              ) else { return false }
        return expected.key == media.key
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
        guard allowsManualEpisodeSelection,
              let _ = nextEpisode,
              !isStandalonePlaybackSession,
              !isAdvanceInFlight,
              !isAdvancingEpisode,
              !isAwaitingStreamStart,
              hasRenderedFirstFrame,
              status == .playing || status == .paused,
              time.duration >= 60,
              !postPlayState.isVisible,
              !showSettingsPanel,
              !showScenePanel,
              !isSceneDetailVisible,
              sidePanel == nil else {
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
        guard !postPlayState.isVisible,
              !showSettingsPanel,
              !showScenePanel,
              !isSceneDetailVisible,
              sidePanel == nil,
              hasRenderedFirstFrame,
              !isAdvanceInFlight,
              !isAdvancingEpisode,
              !isAwaitingStreamStart,
              time.duration >= 60,
              time.remaining > 0,
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

    /// Stop autoplay UI/resolution after the current player is adopted into a room.
    /// Keep `currentEpisodeVideo` intact because it supplies the canonical room media key.
    func suspendNextEpisodeStateForWatchParty() {
        guard watchPartySuspendedAutoPlayWasCancelled == nil else { return }
        watchPartySuspendedAutoPlayWasCancelled = isAutoPlayCancelled
        cancelPendingAdvanceResolution()
        isAdvanceInFlight = false
        isAdvancingEpisode = false
        isAutoPlayCancelled = true
        clearNextEpisodeCard()
    }

    /// Restore the standalone episode presentation after leaving a room while keeping playback.
    func resumeNextEpisodeStateAfterWatchParty() {
        clearWatchPartyTransitionCallbacks()
        guard watchPartyPlayerBridge == nil,
              let wasCancelled = watchPartySuspendedAutoPlayWasCancelled else { return }
        watchPartySuspendedAutoPlayWasCancelled = nil
        isAutoPlayCancelled = wasCancelled
        updateNextEpisodeState()
    }

    // MARK: - IntroDB skip segments

    private func loadSkipIntervalsIfNeeded(meta: NuvioMeta, isStandalonePlaybackSession: Bool) {
        guard !isStandalonePlaybackSession else { return }

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

    func shouldAutoSkip(interval: SkipInterval) -> Bool {
        guard watchPartyPlayerBridge == nil,
              !isScrubbing,
              !isHoldingSeek else {
            return false
        }
        if interval.isIntro && autoSkipIntroEnabled {
            return true
        }
        if interval.isRecap && autoSkipRecapEnabled {
            return true
        }
        if interval.isEnding && autoSkipOutroEnabled {
            return true
        }
        return false
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
              !isStandalonePlaybackSession,
              !postPlayState.isVisible,
              !showSettingsPanel,
              !showScenePanel,
              !isSceneDetailVisible,
              sidePanel == nil else {
            if activeSkipInterval != nil { activeSkipInterval = nil }
            if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
            skipSegmentAutoHideDeadline = nil
            return
        }

        let current = time.current
        for segment in skipIntervals {
            if current < max(segment.startTime - 0.35, 0) {
                dismissedSkipIntervalIds.remove(segment.id)
                autoSkippedIntervalIds.remove(segment.id)
                if autoHiddenSkipIntervalId == segment.id {
                    autoHiddenSkipIntervalId = nil
                }
            }
        }

        let interval = skipIntervals.first { segment in
            current >= max(segment.startTime - 0.35, 0) && current < segment.endTime - 0.25
        }

        guard let interval else {
            if activeSkipInterval != nil { activeSkipInterval = nil }
            if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
            skipSegmentAutoHideDeadline = nil
            return
        }

        if shouldAutoSkip(interval: interval) &&
            !autoSkippedIntervalIds.contains(interval.id) &&
            !dismissedSkipIntervalIds.contains(interval.id) {
            skipInterval(interval)
            return
        }

        // A skip command is asynchronous. Polling can still observe the old
        // playhead for a few ticks, but a deliberately skipped segment must not
        // be armed again during clean playback. If controls are pulled up, allow
        // the button to be presented.
        if dismissedSkipIntervalIds.contains(interval.id) {
            if !showControls {
                if activeSkipInterval != nil { activeSkipInterval = nil }
                if skipSegmentCountdown != nil { skipSegmentCountdown = nil }
                skipSegmentAutoHideDeadline = nil
                return
            } else {
                if activeSkipInterval?.id != interval.id {
                    activeSkipInterval = interval
                }
                skipSegmentCountdown = nil
                skipSegmentAutoHideDeadline = nil
                return
            }
        }

        if autoHiddenSkipIntervalId == interval.id, !showControls {
            if activeSkipInterval?.id != interval.id {
                activeSkipInterval = interval
            }
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
        guard !isAdvanceInFlight, !isAwaitingStreamStart else { return }
        advance()
    }

    func cancelAutoPlay() {
        isAutoPlayCancelled = true
        nextEpisodeCountdown = nil
        nextEpisodeAutoPlayDeadline = nil
    }

    var canShowPauseOverlay: Bool {
        status == .paused
            && !isAwaitingStreamStart
            && !isAdvancingEpisode
            && pendingAdvanceResolutionGeneration == nil
            && !isSwitchingSource
            && !isReloadingStream
            && !isFailingOver
            && !didDetectReplacementStream
            && !controlsAutoHideSuspended
            && !showSettingsPanel
            && !showScenePanel
            && !isSceneDetailVisible
            && !isScrubbing
            && sidePanel == nil
            && !isStandalonePlaybackSession
            && !didShutdown
    }

    private var canSchedulePauseOverlay: Bool {
        canShowPauseOverlay
            && isTimelineFocused
    }

    func dismissNextEpisodeCard(cancelAutoPlay: Bool = true) {
        if cancelAutoPlay {
            self.cancelAutoPlay()
        }
        autoHiddenNextEpisodeCard = true
        showNextEpisodeCard = false
        nextEpisodeAutoHideDeadline = nil
    }

    func advance() {
        guard allowsManualEpisodeSelection, !isStandalonePlaybackSession, !isAdvanceInFlight,
              let next = nextEpisode,
              currentEpisodeVideo?.id != next.id,
              lastAdvancedEpisodeId != next.id,
              EpisodeReleasePolicy.hasAired(next.released),
              let resolver = resolveNextStream else { return }
        lastAdvancedEpisodeId = next.id
        advanceGeneration &+= 1
        let gen = advanceGeneration
        let startupToken = beginStartupBenchmark(title: activeMeta?.name ?? "")
        pendingAdvanceResolutionGeneration = gen
        isAdvanceInFlight = true
        isAdvancingEpisode = true
        isAwaitingStreamStart = true
        status = .buffering
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        loadingStepMessage = L10n.string("player_searching_sources", fallback: "Searching sources…")
        nextEpisodeCountdown = nil
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil
        autoHiddenNextEpisodeCard = false
        showNextEpisodeCard = false

        // Pause/stop active playback so the finishing episode doesn't produce
        // lingering playback phase or EOF events while resolving the next stream.
        engine.pausePlayback()

        // Mark the finishing episode watched. With Trakt selected its scrobble
        // history produces the remote Next Up entry; Nuvio Sync keeps the
        // existing local rollover behavior.
        if let activeMeta {
            markWatchedIfNeeded()
            if !usesTraktProgress {
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

        Task { @MainActor [weak self] in
            guard let self else {
                PlaybackStartupTiming.cancel(token: startupToken)
                return
            }
            guard self.advanceGeneration == gen else {
                self.clearPendingAdvanceResolution(generation: gen)
                self.cancelStartupBenchmark(token: startupToken)
                return
            }
            let prepared = await resolver(next, startupToken)
            guard !Task.isCancelled,
                  self.advanceGeneration == gen,
                  self.pendingAdvanceResolutionGeneration == gen,
                  PlaybackStartupTiming.isActive(token: startupToken) else {
                if self.clearPendingAdvanceResolution(generation: gen) {
                    self.isAdvanceInFlight = false
                    self.isAdvancingEpisode = false
                    self.isAwaitingStreamStart = false
                }
                self.cancelStartupBenchmark(token: startupToken)
                return
            }
            guard let prepared else {
                // Couldn't resolve a stream for the next episode: disarm so the
                // ended handler doesn't retry, and fall back to the normal
                // end-of-playback flow (which returns to the details screen).
                self.clearPendingAdvanceResolution(generation: gen)
                self.isAdvanceInFlight = false
                self.isAdvancingEpisode = false
                self.isAwaitingStreamStart = false
                self.lastAdvancedEpisodeId = nil
                self.cancelStartupBenchmark(token: startupToken)
                self.status = .ended
                return
            }
            guard self.clearPendingAdvanceResolution(generation: gen) else { return }
            if self.watchPartyPlayerBridge != nil {
                guard let transition = self.onWatchPartyEpisodeResolved,
                      await transition(next, prepared) else {
                    self.cancelStartupBenchmark(token: startupToken)
                    self.isAdvanceInFlight = false
                    self.isAdvancingEpisode = false
                    self.isAwaitingStreamStart = false
                    self.isSwitchingSource = false
                    self.lastAdvancedEpisodeId = nil
                    self.status = .paused
                    self.showPlayerToast("Couldn't change the Watch Party episode")
                    return
                }
                return
            }
            self.replaceStream(prepared: prepared, episode: next, resumeFrom: nil)
        }
    }

    @discardableResult
    private func clearPendingAdvanceResolution(generation: UInt64) -> Bool {
        guard pendingAdvanceResolutionGeneration == generation else { return false }
        pendingAdvanceResolutionGeneration = nil
        return true
    }

    private func cancelPendingAdvanceResolution() {
        guard let generation = pendingAdvanceResolutionGeneration else { return }
        _ = clearPendingAdvanceResolution(generation: generation)
        if advanceGeneration == generation { advanceGeneration &+= 1 }
        isAdvanceInFlight = false
        isAdvancingEpisode = false
    }

    /// Swaps the currently playing stream in place — mpv `loadfile` replaces the
    /// source without tearing the player down. `episode` non-nil advances to a new
    /// episode (start from 0); nil keeps the current episode (used by the expired-
    /// link reload, which resumes from `resumeFrom`).
    private func replaceStream(prepared: PreparedNextStream, episode: NuvioVideo?, resumeFrom: Double?) {
        guard let meta = activeMeta else { return }
        PlaybackTimelineRecorder.record(.playbackLoadRequested, engine: activeEngineKind)
        cancelSourcesFetch()
        if let episode, episode.id != currentEpisodeVideo?.id {
            availableSources = []
        }
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
        self.activeVideoHash = prepared.videoHash
        // A replacement without an explicitly proven identity must not inherit
        // the previous file's cache namespace. Next-episode resolvers may supply
        // a new identity on the prepared stream.
        self.activeCacheFileIdentity = prepared.cacheFileIdentity
        self.activeTrickplayURL = prepared.trickplayURL
        self.activeSourceID = prepared.sourceID
        didRememberManualSource = false
        if let bg = prepared.bingeGroup, !bg.isEmpty {
            self.activeBingeGroup = bg
        }
        if let episode {
            currentEpisodeVideo = episode
            nextEpisode = Self.nextEpisode(after: episode, in: seriesEpisodes)
            isAutoPlayCancelled = false
            fetchExternalSubtitles(
                contentId: episode.id,
                type: "series",
                videoHash: prepared.videoHash,
                videoSize: prepared.videoSize,
                filename: prepared.filename
            )
        } else if let activeMeta, !isStandalonePlaybackSession {
            let contentId = currentEpisodeVideo?.id ?? activeMeta.id
            fetchExternalSubtitles(
                contentId: contentId,
                type: activeMeta.isSeries ? "series" : activeMeta.type,
                videoHash: prepared.videoHash,
                videoSize: prepared.videoSize,
                filename: prepared.filename
            )
        }
        clearNextEpisodeCard()
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
        guard !isStandalonePlaybackSession else {
            surfaceExpiredStreamError()
            return
        }
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
        isAdvanceInFlight = false
        isAdvancingEpisode = false
        lastAdvancedEpisodeId = nil
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        autoHiddenNextEpisodeCard = false
        nextEpisodeAutoHideDeadline = nil
        nextEpisodeAutoPlayDeadline = nil
        status = .error("This stream link has expired. Go back and start it again to load a fresh stream.")
    }

    // MARK: Load timeout watchdog

    private func startLoadWatchdog() {
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        guard !isStandalonePlaybackSession,
              reloadCurrentStream != nil || isLiveStream || activeMeta?.isSports == true,
              sessionCoordinator.lastLoadError == nil else { return }
        currentLoadStarted = false
        let targetURL = activeStreamURL
        let targetGeneration = sessionCoordinator.loadGeneration
        let timeout = loadTimeoutSeconds
        loadWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled, let self,
                  self.sessionCoordinator.loadGeneration == targetGeneration,
                  self.sessionCoordinator.lastLoadError == nil,
                  !self.currentLoadStarted,
                  !self.hasRenderedFirstFrame,
                  !self.livePlaybackHasStarted,
                  !self.hasProducedMidFilePosition,
                  !self.didShutdown,
                  !self.isFailingOver,
                  self.activeStreamURL == targetURL
            else { return }
            let memReport = TVMemoryDiagnostic.detailedReport(label: "LOAD_WATCHDOG_TIMEOUT")
            print("[TVTrace] ⚠️ [LOAD_WATCHDOG_TIMEOUT] Source failed to start within \(timeout)s for url=\(targetURL ?? "nil")\n\(memReport)")
            if self.isStandalonePlaybackSession {
                self.status = .error("The stream did not start within \(self.loadTimeoutSeconds) seconds.")
                return
            }
            if (self.isLiveStream || self.activeMeta?.isSports == true),
               self.sessionCoordinator.requestLiveStartupFallback(generation: targetGeneration) {
                self.activeEngineKind = self.sessionCoordinator.activeBackend
                self.currentLoadStarted = false
                self.isAwaitingStreamStart = true
                return
            }
            guard self.reloadCurrentStream != nil else {
                self.status = .error("The stream did not start within \(self.loadTimeoutSeconds) seconds.")
                return
            }
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

    /// The playing Usenet release turned out too damaged (long runs of
    /// missing articles): switch to the next source at the current position,
    /// the same way a failed stream does.
    private func handleUsenetDamage(_ url: URL) {
        guard activeStreamURL == url.absoluteString, !didShutdown, !isFailingOver else { return }
        failedStreamURLs.insert(url.absoluteString)
        attemptFailover(
            reason: L10n.string("usenet_error_damaged", fallback: "This Usenet release is too damaged to play, and no other source worked."),
            toast: L10n.string("usenet_switching_damaged", fallback: "Release damaged — switching source")
        )
    }

    /// A stream died or never started. Remember the position, pick the next
    /// viable source (excluding failed URLs), and switch silently. The error
    /// overlay only appears when every candidate is exhausted.
    private func attemptFailover(reason: String, toast: String?) {
        guard !isFailingOver, !didShutdown else { return }
        guard !isStandalonePlaybackSession else {
            isReloadingStream = false
            isFailingOver = false
            isSwitchingSource = false
            status = .error(reason)
            return
        }
        cancelPendingAdvanceResolution()
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
        let startupToken = beginStartupBenchmark(title: activeMeta?.name ?? "")

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
        isAdvanceInFlight = false
        isAdvancingEpisode = false
        switchingSourceMessage = "Starting stream"
        isAwaitingStreamStart = true
        hasProducedMidFilePosition = false
        reloadAttempts += 1
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
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
            guard let self else {
                PlaybackStartupTiming.cancel(token: startupToken)
                return
            }
            defer {
                self.isFailingOver = false
                // isSwitchingSource cleared in replaceStream / error paths
            }
            let result = await reloadCurrentStream(currentEpisodeVideo, excluded)
            guard self.startupBenchmarkToken == startupToken,
                  PlaybackStartupTiming.isActive(token: startupToken) else {
                self.cancelStartupBenchmark(token: startupToken)
                return
            }
            guard !Task.isCancelled else {
                self.cancelStartupBenchmark(token: startupToken)
                self.isFailingOver = false
                self.isReloadingStream = false
                self.isSwitchingSource = false
                self.isAwaitingStreamStart = false
                return
            }
            guard let prepared = result else {
                self.cancelStartupBenchmark(token: startupToken)
                self.isReloadingStream = false
                self.isSwitchingSource = false
                self.status = .error(reason)
                return
            }
            guard !Task.isCancelled,
                  PlaybackStartupTiming.isActive(token: startupToken) else {
                self.cancelStartupBenchmark(token: startupToken)
                return
            }
            // Don't mark the new URL failed yet — the watchdog / error path will
            // if this candidate also dies before playback starts.
            self.replaceStream(prepared: prepared, episode: nil, resumeFrom: resume)
        }
    }

    func showPlayerToast(
        _ message: String,
        avatarURL: String? = nil,
        avatarColor: String? = nil,
        initials: String? = nil,
        senderName: String? = nil,
        durationSeconds: Double = 2.8
    ) {
        let item = PlayerToastItem(
            message: message,
            avatarURL: avatarURL,
            avatarColor: avatarColor,
            initials: initials,
            senderName: senderName
        )
        playerToast = item
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.playerToast == item {
                self.playerToast = nil
            }
        }
    }

    func showPlayerToast(_ notice: WatchPartyNotice) {
        showPlayerToast(
            notice.message,
            avatarURL: notice.avatarURL,
            avatarColor: notice.avatarColor,
            initials: notice.initials
        )
    }

    func handleWatchPartyChatMessage(_ message: WatchPartyChatMessage) {
        let isEnabled = ProfileSettings.current.object(forKey: SettingsKey.partyChatToastsEnabled) as? Bool ?? true
        guard isEnabled else { return }

        let rawName = message.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sender = rawName.isEmpty ? "Friend" : rawName
        let initials = String(sender.prefix(1)).uppercased()

        showPlayerToast(
            message.body,
            avatarURL: message.avatarURL,
            avatarColor: message.avatarColor,
            initials: initials,
            senderName: sender,
            durationSeconds: 4.5
        )
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
            info.concurrency = diskCacheConcurrencyStr
            let usenet = UsenetEngineManager.shared
            if let usenetURL = usenet.activeStreamURL, usenetURL.absoluteString == activeStreamURL {
                let stats = usenet.activeStats
                info.provider = stats.kind == UsenetStreamSource.Kind.rar.rawValue ? "Usenet · RAR" : "Usenet"
                if !stats.server.isEmpty { info.server = stats.server }
                if !stats.fileName.isEmpty {
                    info.fileName = (stats.fileName as NSString).lastPathComponent
                    let ext = (stats.fileName as NSString).pathExtension
                    if !ext.isEmpty { info.fileExtension = ext.uppercased() }
                }
                if stats.fileSize > 0 { info.size = Self.formatFileSize(stats.fileSize) }
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

    private func hasStablePlaybackSinceVMError(
        _ errorMessage: String,
        position: Double,
        controller: PlaybackEngineControlling,
        engineKind: PlayerEngineKind,
        loadGeneration: UInt64
    ) -> Bool {
        guard sessionCoordinator.lastLoadError == nil,
              let sourceURL = activeStreamURL,
              !isSwitchingSource,
              !isReloadingStream,
              !isFailingOver,
              !isScrubbing,
              !isHoldingSeek,
              pendingSeekDelta == 0,
              seekDebounceTask == nil,
              explicitSeekProgressCheckpoint == nil,
              controller.currentErrorMessage.isEmpty,
              controller.isPlayerPlaying,
              !controller.isPlayerLoading,
              !controller.isPlayerEnded,
              controller.hasFirstFrameReadyForDisplay || controller.isTransportPlaying,
              position.isFinite else {
            vmOnlyErrorRecoveryProbe = nil
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        if var probe = vmOnlyErrorRecoveryProbe,
           probe.errorMessage == errorMessage,
           probe.sourceURL == sourceURL,
           probe.loadGeneration == loadGeneration,
           probe.engineKind == engineKind {
            let recovered = probe.progress.observe(position: position, uptime: now)
            vmOnlyErrorRecoveryProbe = probe
            return recovered
        }

        vmOnlyErrorRecoveryProbe = VMOnlyErrorRecoveryProbe(
            errorMessage: errorMessage,
            sourceURL: sourceURL,
            loadGeneration: loadGeneration,
            engineKind: engineKind,
            progress: PlayerErrorRecoveryProgress(position: position, uptime: now)
        )
        return false
    }

    func pollForTesting(using controller: PlaybackEngineControlling) {
        tick(engineOverride: controller)
    }

    static func scenePlaybackPollTransition(
        from previous: PlayerStatus,
        to latest: PlayerStatus,
        pauseIntentPending: Bool,
        pauseAlreadyNotified: Bool,
        isVerifiedPlaying: Bool
    ) -> ScenePlaybackPollTransition {
        if previous == .playing, latest == .paused {
            return pauseAlreadyNotified ? .none : .paused
        }
        if latest == .playing, previous != .playing, !pauseIntentPending, isVerifiedPlaying {
            return .resumed
        }
        return .none
    }

    private func currentLoadPresentationIsConfirmed(
        engineKind: PlayerEngineKind,
        generation: UInt64
    ) -> Bool {
        guard pendingAdvanceResolutionGeneration == nil,
              sessionCoordinator.hasDispatchedCurrentLoad(generation: generation) else { return false }
        guard engineKind == .aether else { return true }
        return sessionCoordinator.hasPresentedCurrentAetherLoad(generation: generation)
    }

    private func tick(engineOverride: PlaybackEngineControlling? = nil) {
        guard !didShutdown else { return }
        watchPartyControls?.validateContext()
        guard !didShutdown else { return }
        let sampledEngineKind = activeEngineKind
        let sampledLoadGeneration = sessionCoordinator.loadGeneration
        let c = engineOverride ?? engine
        c.refreshPlaybackState()
        sessionCoordinator.refreshHandoffState()
        updateLoadingStepMessage()
        // A backend handoff may occur while state is refreshed. Discard a stale sample.
        guard activeEngineKind == sampledEngineKind,
              sessionCoordinator.loadGeneration == sampledLoadGeneration else {
            trailerEndConfirmation.reset()
            return
        }
        PictureInPictureManager.shared.refreshWatchPartyTimebase(for: sessionCoordinator)
        guard !didShutdown, activeEngineKind == sampledEngineKind,
              sessionCoordinator.loadGeneration == sampledLoadGeneration else { return }
        if pendingAdvanceResolutionGeneration != nil {
            trailerEndConfirmation.reset()
            if status != .buffering { status = .buffering }
            return
        }

        let hasPresentedCurrentLoad = currentLoadPresentationIsConfirmed(
            engineKind: sampledEngineKind,
            generation: sampledLoadGeneration
        )

        // Reuse this refresh; Party never starts its own engine polling loop.
        if let bridge = watchPartyPlayerBridge, let sample = watchPartySampleForCurrentState() {
            bridge.observe(sample)
            // A binding's synchronous callback can invalidate or replace the source.
            guard activeEngineKind == sampledEngineKind,
                  sessionCoordinator.loadGeneration == sampledLoadGeneration,
                  c === engine, !didShutdown else { return }
        }

        let confirmedTrailerEnd = trailerEndConfirmation.observe(
            isTrailer: isStandalonePlaybackSession,
            usesMPV: sampledEngineKind == .mpv,
            reachedEOF: c.isAtEndOfFile,
            isStable: hasPresentedCurrentLoad && hasRenderedFirstFrame
                && c.hasCoherentTimeSample && !c.isPlayerLoading
                && c.currentErrorMessage.isEmpty && sessionCoordinator.lastLoadError == nil
                && !isAwaitingStreamStart && !isAdvanceInFlight
                && !isSwitchingSource && !isReloadingStream && !isFailingOver
                && !isScrubbing && !isHoldingSeek && pendingSeekDelta == 0
                && seekDebounceTask == nil && !didShutdown,
            position: Double(c.positionMs) / 1000,
            duration: Double(c.durationMs) / 1000,
            loadGeneration: sampledLoadGeneration,
            uptime: ProcessInfo.processInfo.systemUptime
        )

        if let startupError = sessionCoordinator.lastLoadError {
            guard !isFailingOver, !isReloadingStream, !isSwitchingSource else { return }
            let recoveredPlayback = (c.hasFirstFrameReadyForDisplay || c.isTransportPlaying)
                && c.isPlayerPlaying
                && !c.isPlayerLoading
                && !c.isPlayerEnded
                && hasPresentedCurrentLoad
            guard recoveredPlayback, c.currentErrorMessage.isEmpty else {
                let isEngineUnavailable = startupError.contains("unavailable on this device") || startupError.contains("AetherEngine is unavailable")
                if !isEngineUnavailable,
                   !isStandalonePlaybackSession,
                   reloadCurrentStream != nil,
                   reloadAttempts < Self.maxReloadAttempts,
                   !didShutdown {
                    if let url = activeStreamURL { failedStreamURLs.insert(url) }
                    if let meta = activeMeta {
                        let numbers = resolvedEpisodeNumbers
                        LastPlaybackStreamStore.remove(metaId: meta.id, season: numbers?.season, episode: numbers?.episode)
                    }
                    status = .buffering
                    attemptFailover(reason: sessionCoordinator.lastLoadError ?? startupError, toast: nil)
                } else {
                    status = .error(sessionCoordinator.lastLoadError ?? startupError)
                }
                return
            }
            if sampledEngineKind == .aether {
                guard sessionCoordinator.aetherController?.clearTerminalErrorAfterVerifiedRecovery() == true else {
                    status = .error(sessionCoordinator.lastLoadError ?? startupError)
                    return
                }
            }
            guard sessionCoordinator.clearLoadErrorAfterVerifiedRecovery(generation: sampledLoadGeneration) else {
                status = .error(sessionCoordinator.lastLoadError ?? startupError)
                return
            }
            updateCoordinatorLoadError(nil)
            if case .error = status { status = .playing }
        }

        let rawCurrent = Double(c.positionMs) / 1000.0
        let rawDuration = Double(c.durationMs) / 1000.0
        let latestTime = PlayerTime(current: rawCurrent, duration: rawDuration)

        // An unavailable duration is unknown, not evidence of a live stream.
        // Keep recognized channel/source hints, including a URL resolved after load.
        if let activeMeta {
            let sourceIsLive = Self.isLiveStream(
                meta: activeMeta, url: activeStreamURL.flatMap(URL.init(string:))
            )
            if sourceIsLive {
                if !isLiveStream { isLiveStream = true }
            } else if isLiveStream, c.durationMs > 0, c.hasCoherentTimeSample {
                isLiveStream = false
            }
        }

        let isPreSeekSettlingSample: Bool = {
            guard let checkpoint = explicitSeekProgressCheckpoint else { return false }
            let seekConfirmed = abs(latestTime.current - checkpoint.time.current) <= 2
            let protectionExpired = Date().timeIntervalSince(checkpoint.createdAt)
                >= Self.explicitSeekSettleWindow
            return !seekConfirmed && !protectionExpired
        }()
        let isReplacementSlate = !isStandalonePlaybackSession && !isLiveStream && loadedStreamLooksLikeReplacement()
        if !isLiveStream,
           hasPresentedCurrentLoad,
           c.hasCoherentTimeSample,
           !c.isPlayerLoading,
           !c.isAtEndOfFile,
           !c.isPlayerEnded,
           !isReplacementSlate,
           latestTime.duration > 0,
           latestTime.current > 0,
           latestTime.current < latestTime.duration {
            hasProducedMidFilePosition = true
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
        // file's final position. Do not accept a sample until this load has
        // been presented, either.
        if !isLiveStream,
           hasPresentedCurrentLoad,
           c.hasCoherentTimeSample,
           !isPreSeekSettlingSample,
           latestTime.duration > 0,
           latestTime.current >= 0,
           latestTime.current < latestTime.duration {
            // Neither the settings panel nor native menus (subtitles/audio) display coarse
            // playback time. While open, do not publish continuous time updates so view
            // re-evaluations do not trigger UIKit menu reloads or reset menu focus.
            if !showSettingsPanel && !controlsAutoHideSuspended {
                if latestTime != time { time = latestTime }
            } else if latestTime.duration != time.duration {
                time = latestTime
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
                    guard await PlaybackStreamCacheManager.shared.hasActiveServer else {
                        self?.diskCachePollTask = nil
                        return
                    }
                    let forwardSec = await PlaybackStreamCacheManager.shared.contiguousCachedForwardSeconds(
                        playheadSeconds: currentPos, totalDuration: duration
                    )
                    let metrics = await PlaybackStreamCacheManager.shared.activeStreamMetrics()
                    let concurrency = await PlaybackStreamCacheManager.shared.activeConcurrencyMetrics()
                    guard let self else { return }
                    if let metrics {
                        self.diskCachedBytes = metrics.cachedBytes
                        self.diskCacheTotalBytes = metrics.totalBytes
                        if self.activeVideoSize == nil && metrics.totalBytes > 0 {
                            self.activeVideoSize = metrics.totalBytes
                        }
                    }
                    if let concurrency {
                        if concurrency.active > 0 {
                            if concurrency.currentMax < concurrency.configuredMax {
                                self.diskCacheConcurrencyStr = "\(concurrency.active)/\(concurrency.currentMax) (max \(concurrency.configuredMax))"
                            } else {
                                self.diskCacheConcurrencyStr = "\(concurrency.active)/\(concurrency.currentMax) active"
                            }
                        } else {
                            self.diskCacheConcurrencyStr = "0/\(concurrency.currentMax) idle"
                        }
                    } else {
                        self.diskCacheConcurrencyStr = ""
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

        let isRecoverableAetherLoading = sampledEngineKind == .aether && c.isPlayerLoading
        // mpv hard-failed this source — try the next one before surfacing UI.
        if !c.currentErrorMessage.isEmpty,
           !isRecoverableAetherLoading,
           !isFailingOver,
           !isReloadingStream {
            if isStandalonePlaybackSession {
                status = .error(c.currentErrorMessage)
                return
            }
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

        if case .error(let vmErrorMessage) = status {
            guard hasStablePlaybackSinceVMError(
                vmErrorMessage,
                position: latestTime.current,
                controller: c,
                engineKind: sampledEngineKind,
                loadGeneration: sampledLoadGeneration
            ) else { return }
            vmOnlyErrorRecoveryProbe = nil
            status = .playing
            isAwaitingStreamStart = false
            markLoadStarted()
            if showControls { scheduleControlsHide() }
        } else {
            vmOnlyErrorRecoveryProbe = nil
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

        let isPresentingFrames = hasPresentedCurrentLoad
            && (c.hasFirstFrameReadyForDisplay || (c.isPlayerPlaying && !c.isPlayerLoading && (c.videoFrameSize != .zero || c.durationMs > 0)))
        if isPresentingFrames {
            if !hasRenderedFirstFrame {
                hasRenderedFirstFrame = true
                if let meta = activeMeta {
                    prewarmSceneIfNeeded(meta: meta, isTrailerPlayback: subtitle == PlaybackMarkers.trailerSubtitle)
                }
            }
            isAwaitingStreamStart = false
            isAdvanceInFlight = false
            isAdvancingEpisode = false
            markLoadStarted()
        }

        let engineStatus: PlayerStatus
        if isFailingOver || isReloadingStream || isSwitchingSource {
            engineStatus = .buffering
        } else if !c.currentErrorMessage.isEmpty, !isRecoverableAetherLoading {
            let isEngineUnavailable = c.currentErrorMessage.contains("unavailable on this device") || c.currentErrorMessage.contains("AetherEngine is unavailable")
            if !isEngineUnavailable, reloadCurrentStream != nil, reloadAttempts < Self.maxReloadAttempts {
                engineStatus = .buffering
            } else {
                engineStatus = .error(c.currentErrorMessage)
            }
        } else if c.isPlayerEnded || confirmedTrailerEnd {
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
        let engineHasStarted = engineStatus == .playing
            || (engineStatus == .paused && time.duration > 0 && !c.isPlayerLoading)
        if hasPresentedCurrentLoad && engineHasStarted {
            isAwaitingStreamStart = false
            markLoadStarted()
        }

        // A stream that was just handed to the engine hasn't opened yet, so the
        // idle pipeline reads as paused. Keep reporting `.buffering` until it
        // really starts, so a source/episode switch shows the spinner over the
        // black frame instead of parked transport controls.
        let isAwaitingCurrentLoadDispatch = !sessionCoordinator.hasDispatchedCurrentLoad(
            generation: sampledLoadGeneration
        )
        let isAwaitingAetherPresentation = sampledEngineKind == .aether && !hasPresentedCurrentLoad
        let latestStatus = (isAwaitingStreamStart
            && (engineStatus == .paused || isAwaitingCurrentLoadDispatch || isAwaitingAetherPresentation))
            ? .buffering
            : engineStatus
        let scenePollTransition = Self.scenePlaybackPollTransition(
            from: previousStatus,
            to: latestStatus,
            pauseIntentPending: scenePauseIntentPending,
            pauseAlreadyNotified: scenePauseAlreadyNotified,
            isVerifiedPlaying: c.isPlayerPlaying && !c.isPlayerLoading && !c.isPlayerEnded && !c.isAtEndOfFile
        )
        if latestStatus == .playing {
            cancelPauseOverlaySchedule()
            showPauseOverlay = false
        }
        if status != latestStatus {
            status = latestStatus
            if latestStatus == .paused, previousStatus == .playing {
                cancelControlsHideTimer()
                cancelPauseOverlaySchedule()
                showPauseOverlay = false
                showControls = true
                isTimelineFocused = true
                schedulePauseOverlay()
            }
        }
        if showScenePanel {
            switch scenePollTransition {
            case .paused:
                sceneCoordinator.handlePlaybackPaused()
            case .resumed:
                sceneCoordinator.handlePlaybackResumed()
            case .none:
                break
            }
        }
        switch latestStatus {
        case .paused:
            scenePauseIntentPending = false
            scenePauseAlreadyNotified = false
        case .playing:
            if !scenePauseIntentPending { scenePauseAlreadyNotified = false }
        case .idle, .buffering, .ended, .error(_):
            scenePauseIntentPending = false
            scenePauseAlreadyNotified = false
        }

        updatePlaybackDebugHUD(from: c)
        if showScenePanel {
            let scenePlaybackInfo = buildScenePlaybackInfo()
            if sceneViewModel.playbackInfo != scenePlaybackInfo {
                sceneViewModel.updatePlaybackInfo(scenePlaybackInfo)
            }
        }

        // The controls are shown on launch (showControls defaults to true) but the
        // auto-hide timer is only armed by user transport actions. Arm it whenever
        // playback (re)starts so the initial controls fade on their own — without
        // this they linger until the user manually pauses/resumes. The scheduled
        // timer no-ops if controls are already hidden or auto-hide is suspended.
        if status == .playing, previousStatus != .playing, showControls {
            scheduleControlsHide()
        }

        // An expired stream link is often answered with a short "slate" clip
        // (e.g. ElfHosted's "Link expired" video) that decodes cleanly, so it
        // never trips the mpv-error guard. Bail before any Continue Watching
        // write/clear so it can't overwrite or delete the real resume point.
        // While a next-episode advance is resolving/loading, ignore the old
        // stream's transient ended/loading state so nothing flickers or re-fires.
        if isAdvanceInFlight || isAwaitingStreamStart { return }

        if !isStandalonePlaybackSession,
           detectReplacementStream(c) { return }

        addPendingExternalSubtitlesIfNeeded()
        if !isLiveStream {
            applyPendingResumeIfNeeded()
            updateSkipIntervalState()
            let isCoherentCompletionSample = isTrackablePlayback
                && c.hasCoherentTimeSample
                && !isPreSeekSettlingSample
                && !isReplacementSlate
                && !sessionCoordinator.isProgressSaveSuspended
                && !isAwaitingStreamStart
                && !isFailingOver
                && !isReloadingStream
                && !isSwitchingSource
                && hasRenderedFirstFrame
                && latestTime.duration >= 60
                && latestTime.current > 0
                && latestTime.current < latestTime.duration
            let isGenuinelyPlaying = status == .playing
                && c.isPlayerPlaying
                && !c.isPlayerLoading
                && !c.isPlayerEnded
                && !c.isAtEndOfFile
            if isTrackablePlayback {
                observePlaybackCompletionEligibility(
                    at: latestTime,
                    isCoherent: isCoherentCompletionSample,
                    isGenuinelyPlaying: isGenuinelyPlaying,
                    isBelowCompletionBoundary: !shouldMarkAsWatched(at: latestTime)
                )
            }
        }

        if c.isPlayerEnded {
            // Only a genuine watch-through counts. A stream that dies early
            // (expired link, decode error) also reports "ended", and that must
            // neither mark the title watched nor wipe the resume point.
            if !isLiveStream,
               let activeMeta, isTrackablePlayback,
               hasRenderedFirstFrame,
               hasProducedMidFilePosition,
               !isAwaitingStreamStart,
               !isAdvanceInFlight,
               !isSwitchingSource, !isReloadingStream, !isFailingOver,
               time.duration >= 60, time.current / time.duration >= 0.85 {
                markWatchedIfNeeded()
                if !usesTraktProgress {
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

        if !isStandalonePlaybackSession && !isLiveStream && watchPartyPlayerBridge == nil {
            let postPlayEnabled = ProfileSettings.current.object(forKey: SettingsKey.postPlayRecommendationsEnabled) as? Bool ?? true
            let hasBlockingOverlay = showSettingsPanel || showScenePanel || isSceneDetailVisible || sidePanel != nil || isScrubbing || showPauseOverlay
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

        // A genuine stream is playing: reset failover budget for the next
        // independent failure later in the session.
        if status == .playing,
           !isLiveStream,
           time.duration >= 60,
           !didDetectReplacementStream {
            reloadAttempts = 0
            failedStreamURLs.removeAll()
        }

        let displayedRate = watchPartyPlayerBridge == nil ? c.currentSpeed : watchPartyControls?.canonicalRate
        if let displayedRate, let latestSpeed = PlaybackSpeed(rawValue: displayedRate),
           latestSpeed.rawValue != playbackSpeed.rawValue {
            playbackSpeed = latestSpeed
        }
        syncTracks()
    }

    func syncTracks() {
        let c = engine

        let latestAudioTracks = c.audioTracks.map {
            AudioTrack(id: "\($0.id)", name: $0.title,
                       language: $0.lang, isSelected: $0.selected,
                       languageName: $0.languageName, detail: $0.detail)
        }
        if audioTracks != latestAudioTracks { audioTracks = latestAudioTracks }

        var subs = c.subtitleTracks.map { track in
            let externalSubtitle = availableExternalSubtitles.first {
                !$0.url.isEmpty && $0.url == track.externalFilename
            }
            let externalLabel = externalSubtitle?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = externalLabel.flatMap { $0.isEmpty ? nil : $0 } ?? track.title
            return SubtitleTrack(
                id: "\(track.id)",
                name: title,
                language: track.lang,
                isSelected: track.selected,
                externalFilename: track.externalFilename,
                isForced: track.isForced || Self.isForcedSubtitleLabel(title),
                isNativelyRenderedSubtitle: track.isNativelyRenderedSubtitle
            )
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
        if watchPartyPlayerBridge != nil && status == .ended {
            showPlayerToast("Start a new room to watch again")
            return
        }
        recordWatchPartyTransportIntent()
        if routeWatchPartyControl(status == .ended ? .seekAndPlay(0) : .play) { return }
        let shouldNotifySceneResume = showScenePanel && status == .paused
        scenePauseIntentPending = false
        scenePauseAlreadyNotified = false
        screensaverDebugLog("[ScreensaverDebug][PlayerVM] play() called: currentStatus=\(status), time=\(time.current)/\(time.duration)")
        if status == .ended {
            if isTrackablePlayback, let activeMeta {
                let completionContext = capturePlaybackCompletionContext(profileID: WatchedStore.activeProfileId)
                sessionCoordinator.beginNewPlaybackCompletionSession(
                    identity: playbackCompletionIdentity(for: activeMeta),
                    profileID: WatchedStore.activeProfileId,
                    source: completionContext.source,
                    completionAccounts: completionContext.accountIDs
                )
            }
            pendingResumeSeconds = nil
            didApplyResume = false
            seek(to: 0)
        }
        engine.playPlayback()
        status = .playing
        recordPlaybackResumeIfEligible()
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        if showControls {
            scheduleControlsHide()
        }
        if shouldNotifySceneResume {
            sceneCoordinator.handlePlaybackResumed()
        }
    }

    private func recordPlaybackResumeIfEligible() {
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
    }

    func pause(forBackground: Bool = false) {
        if forBackground {
            // Revoke room effects first; lifecycle parking must not broadcast a user's pause.
            watchPartyLifecycle.suspend(engineWillPark: false)
            watchPartyControls?.setSuspended(true)
        } else if routeWatchPartyControl(.pause) { return }
        if !forBackground { recordWatchPartyTransportIntent() }
        let shouldNotifyScenePause = !forBackground && showScenePanel && status == .playing
        scenePauseIntentPending = true
        // The explicit or lifecycle path owns this pause edge; the polling observer must not duplicate it.
        scenePauseAlreadyNotified = shouldNotifyScenePause || (forBackground && showScenePanel)
        screensaverDebugLog("[ScreensaverDebug][PlayerVM] pause(forBackground=\(forBackground)) called: currentStatus=\(status), time=\(time.current)/\(time.duration)")
        cancelControlsHideTimer()
        engine.pausePlayback()
        status = .paused
        saveProgress(force: true, eventAction: .pause)
        cancelPauseOverlaySchedule()
        guard !forBackground else {
            if showScenePanel { sceneCoordinator.handlePlaybackPaused(captureFrame: false) }
            return
        }
        showPauseOverlay = false
        // Show progress bar and transport controls when paused
        showControls = true
        isTimelineFocused = true
        schedulePauseOverlay()
        if shouldNotifyScenePause {
            sceneCoordinator.handlePlaybackPaused()
        }
    }

    /// After the pause delay, hide transport and show the metadata sheet.
    private func schedulePauseOverlay() {
        guard canSchedulePauseOverlay else {
            cancelPauseOverlaySchedule()
            showPauseOverlay = false
            return
        }
        cancelPauseOverlaySchedule()
        let generation = pauseOverlayGeneration
        let delayNanoseconds = UInt64(pauseOverlayDelaySeconds * 1_000_000_000)
        pauseOverlayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.pauseOverlayGeneration == generation,
                  self.canSchedulePauseOverlay else { return }
            self.pauseOverlayTask = nil
            screensaverDebugLog("[ScreensaverDebug][PlayerVM] schedulePauseOverlay fired: showing pause overlay")
            self.showControls = false
            self.showPauseOverlay = true
            self.updateSkipIntervalState()
        }
    }

    private func cancelPauseOverlaySchedule() {
        pauseOverlayGeneration &+= 1
        pauseOverlayTask?.cancel()
        pauseOverlayTask = nil
    }

    private func watchPartyPlayerStamp() -> WatchPartyPlayerStamp? {
        guard !didShutdown, hasLoaded, let meta = activeMeta,
              let media = watchPartyCanonicalMedia(for: meta) else { return nil }
        return WatchPartyPlayerStamp(generation: sessionCoordinator.loadGeneration,
                                     engineID: ObjectIdentifier(engine), mediaKey: media.key)
    }

    /// Inert snapshot for hosting the current in-player title. It never refreshes, seeks, resumes,
    /// or resolves a source, and its stamp prevents an asynchronous create from adopting a new load.
    func watchPartyRoomCreationSnapshot() throws -> WatchPartyRoomCreationSnapshot {
        guard !didShutdown, hasLoaded, !isStandalonePlaybackSession, !isLiveStream,
              let meta = activeMeta, let sourceURL = activeStreamURL else {
            throw WatchPartyRoomCreationError.unsupportedMedia
        }
        guard !isSwitchingSource, !isReloadingStream, !isFailingOver, !isAwaitingStreamStart,
              pendingAdvanceResolutionGeneration == nil, !isAdvanceInFlight, !isAdvancingEpisode,
              !isScrubbing, !isHoldingSeek, pendingSeekDelta == 0, seekDebounceTask == nil else {
            throw WatchPartyRoomCreationError.transitionInProgress
        }

        let numbers = meta.isSeries ? resolvedEpisodeNumbers : nil
        if meta.isSeries, !(numbers.map { $0.season >= 0 && $0.episode > 0 } ?? false) {
            throw WatchPartyRoomCreationError.invalidEpisode
        }
        guard let canonicalMedia = watchPartyCanonicalMedia(for: meta),
              let stamp = watchPartyPlayerStamp(),
              stamp.mediaKey == canonicalMedia.key else {
            throw WatchPartyRoomCreationError.unsupportedMedia
        }
        guard (try? WatchPartyLaunchPolicy.validate(canonicalMedia)) != nil else {
            throw meta.isSeries ? WatchPartyRoomCreationError.invalidEpisode : .unsupportedMedia
        }

        let controller = engine
        let generation = sessionCoordinator.loadGeneration
        guard hasRenderedFirstFrame,
              currentLoadPresentationIsConfirmed(engineKind: activeEngineKind, generation: generation),
              controller.hasCoherentTimeSample, !controller.isPlayerLoading,
              controller.currentErrorMessage.isEmpty, sessionCoordinator.lastLoadError == nil,
              status == .playing || status == .paused,
              controller.positionMs >= 0, controller.durationMs > 0,
              controller.currentSpeed.isFinite, (0.25...4).contains(controller.currentSpeed) else {
            throw WatchPartyRoomCreationError.playbackNotReady
        }
        let positionSeconds = clock.position
        let rate = playbackSpeed.rawValue
        guard positionSeconds.isFinite, positionSeconds >= 0,
              rate.isFinite, (0.25...4).contains(rate) else {
            throw WatchPartyRoomCreationError.playbackNotReady
        }
        let positionMs = Int64((min(positionSeconds, Double(controller.durationMs) / 1_000) * 1_000).rounded())

        var media = canonicalMedia
        media.videoID = currentEpisodeVideo?.id
        media.title = meta.name
        media.episodeTitle = meta.isSeries ? currentEpisodeVideo?.title : nil
        return WatchPartyRoomCreationSnapshot(
            media: media,
            paused: status == .paused,
            positionMs: min(positionMs, controller.durationMs),
            rate: rate,
            stamp: stamp,
            sourceURL: sourceURL,
            sourceID: activeSourceID,
            episodeID: currentEpisodeVideo?.id,
            season: numbers?.season,
            episode: numbers?.episode,
            transportIntentRevision: watchPartyTransportIntentRevision
        )
    }

    /// Beta: prepare the *currently playing* HTTP source for explicit host approval.
    /// This never sends anything, and never reads a discovery URL in place of the resolved URL.
    /// Local torrent/loopback and sources with unavailable response headers remain unsupported.
    func watchPartyShareableStream(for roomMedia: WatchPartyMedia) throws -> WatchPartyStream {
        let snapshot = try watchPartyRoomCreationSnapshot()
        guard snapshot.media.key == roomMedia.key,
              let sourceURL = URL(string: snapshot.sourceURL),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              TorrentEngineManager.shared.activeStreamURL?.absoluteString != snapshot.sourceURL else {
            throw WatchPartyStreamError.unsupportedSource
        }
        let source = NuvioStream(
            url: snapshot.sourceURL,
            name: activeFilename ?? activeMeta?.name,
            description: nil,
            addonName: activeAddonName,
            filename: activeFilename,
            videoSize: activeVideoSize,
            httpHeaders: activeHTTPHeaders
        )
        return try WatchPartyStream.fromPlayback(
            source, mediaKey: roomMedia.key, resolvedURL: snapshot.sourceURL,
            requestHeaders: activeHTTPHeaders, responseHeaders: [:],
            origin: .directHTTP
        )
    }

    /// Compare load/media/source identity separately so a new local transport intent can refresh
    /// the snapshot without accidentally adopting another source or episode.
    func isSameWatchPartyRoomCreationPlayback(_ snapshot: WatchPartyRoomCreationSnapshot) -> Bool {
        guard !didShutdown, hasLoaded, !isStandalonePlaybackSession, !isLiveStream,
              let meta = activeMeta,
              activeStreamURL == snapshot.sourceURL,
              activeSourceID == snapshot.sourceID,
              currentEpisodeVideo?.id == snapshot.episodeID,
              sessionCoordinator.loadGeneration == snapshot.stamp.generation,
              ObjectIdentifier(engine) == snapshot.stamp.engineID,
              let media = watchPartyCanonicalMedia(for: meta), media.key == snapshot.media.key,
              let stamp = watchPartyPlayerStamp(), stamp == snapshot.stamp else { return false }
        let numbers = meta.isSeries ? resolvedEpisodeNumbers : nil
        guard numbers?.season == snapshot.season, numbers?.episode == snapshot.episode else { return false }
        return hasRenderedFirstFrame
            && currentLoadPresentationIsConfirmed(engineKind: activeEngineKind, generation: snapshot.stamp.generation)
    }

    /// Recheck after publication. Clock progression is intentionally excluded; only explicit
    /// transport commands invalidate the snapshot.
    func isCurrentWatchPartyRoomCreationSnapshot(_ snapshot: WatchPartyRoomCreationSnapshot) -> Bool {
        watchPartyTransportIntentRevision == snapshot.transportIntentRevision
            && !isSwitchingSource && !isReloadingStream && !isFailingOver && !isAwaitingStreamStart
            && pendingAdvanceResolutionGeneration == nil && !isAdvanceInFlight && !isAdvancingEpisode
            && !isScrubbing && !isHoldingSeek && pendingSeekDelta == 0 && seekDebounceTask == nil
            && isSameWatchPartyRoomCreationPlayback(snapshot)
    }

    private func recordWatchPartyTransportIntent() {
        watchPartyTransportIntentRevision &+= 1
    }

    private func watchPartyCanonicalMedia(for meta: NuvioMeta) -> WatchPartyMedia? {
        let numbers = meta.isSeries ? resolvedEpisodeNumbers : nil
        let canonicalID = watchPartyAdmittedMedia.flatMap { admitted in
            [meta.id, meta.imdbId].compactMap { $0 }.contains(admitted.metaID) ? admitted.metaID : nil
        } ?? meta.id
        let media = WatchPartyMedia(type: meta.isSeries ? "episode" : "movie", metaID: canonicalID,
                                   metaType: meta.isSeries ? "series" : meta.type,
                                   season: numbers?.season, episode: numbers?.episode)
        if let admitted = watchPartyAdmittedMedia,
           (try? WatchPartyLaunchPolicy.validateSelection(media, room: admitted)) == nil { return nil }
        return media
    }

    /// Explicit opt-in for the future runtime binding. UI/room admission must precede apply().
    @discardableResult
    func attachWatchPartyPlayerBridge(media: WatchPartyMedia? = nil, isCurrent: @escaping @MainActor () -> Bool) throws -> WatchPartyPlayerBridge {
        guard watchPartyPlayerBridge == nil else { throw WatchPartyPlayerBridgeError.alreadyAttached }
        watchPartyAdmittedMedia = media
        let bridge = WatchPartyPlayerBridge(isCurrent: isCurrent, currentStamp: { [weak self] in
            self?.watchPartyPlayerStamp()
        }, issueSeek: { [weak self] target, stamp in
            guard let self, self.watchPartyPlayerStamp() == stamp else { throw WatchPartyPlayerBridgeError.staleOperation }
            switch self.activeEngineKind {
            case .aether:
                guard let controller = self.aetherController else { throw WatchPartyPlayerBridgeError.notReady }
                await controller.engine.seek(to: Double(target) / 1000)
            case .mpv:
                try self.playerController.beginWatchPartySeek(target)
            }
            try Task.checkCancellation()
            guard self.watchPartyPlayerStamp() == stamp else { throw WatchPartyPlayerBridgeError.staleOperation }
        }, transport: { [weak self] paused, rate, stamp in
            guard let self, self.watchPartyPlayerStamp() == stamp else { throw WatchPartyPlayerBridgeError.staleOperation }
            let engine = self.engine
            if let rate { engine.setSpeed(rate) }
            if let paused {
                let wasPlaying = engine.isTransportPlaying
                if paused {
                    let shouldNotifyScenePause = self.showScenePanel && self.status == .playing
                    self.scenePauseIntentPending = true
                    self.scenePauseAlreadyNotified = shouldNotifyScenePause
                    engine.pausePlayback()
                    self.status = .paused
                    if wasPlaying { self.saveProgress(force: true, eventAction: .pause) }
                    self.cancelPauseOverlaySchedule()
                    if shouldNotifyScenePause { self.sceneCoordinator.handlePlaybackPaused() }
                } else {
                    let shouldNotifySceneResume = self.showScenePanel && self.status == .paused
                    self.scenePauseIntentPending = false
                    self.scenePauseAlreadyNotified = false
                    engine.playPlayback()
                    self.status = .playing
                    if !wasPlaying { self.recordPlaybackResumeIfEligible() }
                    self.cancelPauseOverlaySchedule()
                    self.showPauseOverlay = false
                    if shouldNotifySceneResume { self.sceneCoordinator.handlePlaybackResumed() }
                }
            }
            return engine.currentSpeed
        }, maximumRate: { [weak self] in
            guard let self else { return 0 }
            return self.activeEngineKind == .aether ? (self.aetherController?.engine.maxSupportedRate ?? 0) : 4
        })
        watchPartyPlayerBridge = bridge
        bindWatchPartyRemoteControls()
        return bridge
    }

    func detachWatchPartyPlayerBridge() {
        if watchPartyPlayerBridge != nil {
            playerController.stopWatchPartyRemoteCommands()
            aetherController?.stopWatchPartyRemoteCommands()
            // Discard previews before removing admission, including runtime cleanup before shutdown.
            seekDebounceTask?.cancel()
            seekDebounceTask = nil
            stopRepeatingNudge(commit: false)
            pendingSeekDelta = 0
            resetScrubSession()
        }
        watchPartyControls?.stop()
        watchPartyControls = nil
        watchPartyPlayerBridge?.stop()
        watchPartyPlayerBridge = nil
        watchPartyAdmittedMedia = nil
        watchPartyLifecycle = PlayerLifecycleAdmission()
        PictureInPictureManager.shared.refreshController(for: sessionCoordinator)
    }

    /// Read current engine properties and UI admission flags without starting another
    /// poll or issuing playback commands. The binding validates the exact stamp.
    private func watchPartySampleForCurrentState() -> WatchPartyPlayerSample? {
        guard !didShutdown, let stamp = watchPartyPlayerStamp() else { return nil }
        let controller = engine
        let kind = activeEngineKind
        let presented = currentLoadPresentationIsConfirmed(
            engineKind: kind, generation: sessionCoordinator.loadGeneration
        )
        return WatchPartyPlayerSample(
            stamp: stamp, positionMs: controller.positionMs, durationMs: controller.durationMs,
            rate: controller.currentSpeed, paused: !controller.isTransportPlaying,
            loading: !presented || controller.isPlayerLoading || isSwitchingSource
                || isReloadingStream || isFailingOver || isAwaitingStreamStart
                || isScrubbing || isHoldingSeek || pendingSeekDelta != 0,
            coherent: controller.hasCoherentTimeSample && controller.currentErrorMessage.isEmpty
                && !controller.isPlayerEnded && !isLiveStream,
            seeking: kind == .mpv && playerController.isSeekingForWatchParty,
            rendered: presented && hasRenderedFirstFrame,
            failed: !controller.currentErrorMessage.isEmpty || sessionCoordinator.lastLoadError != nil
        )
    }

    func attachWatchPartyControls(binding: WatchPartyPlaybackBinding,
                                  isCurrent: @escaping @MainActor () -> Bool) throws {
        guard watchPartyPlayerBridge != nil, watchPartyControls == nil else {
            throw WatchPartyPlaybackBindingError.alreadyBound
        }
        binding.onNotice = { [weak self] notice in
            self?.showPlayerToast(notice)
        }
        binding.onChatMessage = { [weak self] message in
            self?.handleWatchPartyChatMessage(message)
        }
        watchPartyControls = WatchPartyControlRouter(isCurrent: isCurrent,
            currentStamp: { [weak self] in self?.watchPartyPlayerStamp() },
            canonicalRate: { [weak binding] in binding?.canonicalRate }, perform: { [weak self, weak binding] intent, applied in
            guard let binding else { throw WatchPartyPlaybackBindingError.notReady }
            try await binding.perform(intent, onApplied: applied,
                refreshSample: { [weak self] in self?.watchPartySampleForCurrentState() })
        }, suspend: { [weak binding] in binding?.setSuspended($0) }, onError: { [weak self] error in
            self?.showPlayerToast((error as? WatchPartyPlaybackBindingError) == .busy
                ? "Watch Party is synchronizing" : "Watch Party control unavailable")
        }, onCompleted: { [weak self] intent in self?.completedWatchPartyControl(intent) })
        bindWatchPartyRemoteControls()
    }

    private func bindWatchPartyRemoteControls() {
        guard watchPartyPlayerBridge != nil else {
            playerController.setWatchPartyRemoteIntent(nil)
            aetherController?.setWatchPartyRemoteIntent(nil)
            aetherController?.setWatchPartyPiPIntent(nil)
            return
        }
        let mpv = playerController
        mpv.setWatchPartyRemoteIntent { [weak self, weak mpv] intent in
            guard let self, let mpv, ObjectIdentifier(self.engine) == ObjectIdentifier(mpv) else { return false }
            return self.admitWatchPartyRemoteControl(intent)
        }
        if let aether = aetherController {
            aether.setWatchPartyPiPIntent { [weak self, weak aether] intent, applied, completion in
                guard let self, let aether, ObjectIdentifier(self.engine) == ObjectIdentifier(aether) else { completion(); return }
                _ = self.admitWatchPartyRemoteControl(intent, completion: completion, onApplied: applied)
            }
            aether.setWatchPartyRemoteIntent { [weak self, weak aether] intent in
                guard let self, let aether, ObjectIdentifier(self.engine) == ObjectIdentifier(aether) else { return false }
                return self.admitWatchPartyRemoteControl(intent)
            }
        }
        PictureInPictureManager.shared.refreshController(for: sessionCoordinator)
    }

    private func admitWatchPartyRemoteControl(_ intent: PlayerRemoteIntent, completion: (@MainActor () -> Void)? = nil,
                                             onApplied: (@MainActor () -> Void)? = nil) -> Bool {
        guard status != .ended else { completion?(); return false }
        guard watchPartyPlayerBridge != nil, let watchPartyControls,
              let local = intent.localIntent(positionMs: engine.positionMs, isPlaying: engine.isTransportPlaying) else { completion?(); return false }
        return watchPartyControls.submit(local, completion: completion, onApplied: onApplied) == .accepted
    }

    /// Explicit root foreground hook; never called merely because a user presses Play.
    func resumeWatchPartyAfterForeground() {
        watchPartyLifecycle.enterForeground()
        if watchPartyLifecycle.canResume { watchPartyControls?.setSuspended(false) }
    }

    func suspendWatchPartyForLifecycle(engineWillPark: Bool = false) {
        guard watchPartyPlayerBridge != nil, !didShutdown else { return }
        let pip = PictureInPictureManager.shared
        if pip.activeCoordinator === sessionCoordinator,
           pip.isPictureInPictureActive || pip.isPictureInPictureStarting || pip.isRestoringUIInProgress { return }
        watchPartyLifecycle.suspend(engineWillPark: engineWillPark)
        watchPartyControls?.setSuspended(true) // Revokes permits before any raw engine pause/vid parking.
        if engineWillPark { hasRenderedFirstFrame = false }
    }

    private func watchPartyEngineDidRestore() {
        guard watchPartyPlayerBridge != nil else { return }
        watchPartyLifecycle.engineDidRestore()
        if watchPartyLifecycle.canResume { watchPartyControls?.setSuspended(false) }
    }
    func catchUpWithWatchParty() { _ = routeWatchPartyControl(.catchUp) }

    /// A mounted bridge without controls must fail closed rather than bypass room permissions.
    private func routeWatchPartyControl(_ intent: WatchPartyLocalIntent) -> Bool {
        guard watchPartyPlayerBridge != nil else { return false }
        guard let watchPartyControls else {
            showPlayerToast("Watch Party control unavailable")
            return true
        }
        watchPartyControls.submit(intent)
        return true
    }

    private func completedWatchPartyControl(_ intent: WatchPartyLocalIntent) {
        guard let sample = watchPartyPlayerBridge?.sample else { return }
        switch intent {
        case .seek, .seekAndPlay:
            recordCommittedSeek(to: Double(sample.positionMs) / 1000, previous: time.current,
                                duration: Double(sample.durationMs) / 1000)
        default: break
        }
        // UI effects happen after admission/completion, never through play()/pause() again.
        if status == .paused {
            cancelControlsHideTimer()
            showControls = true
            isTimelineFocused = true
            schedulePauseOverlay()
        } else if showControls { scheduleControlsHide() }
    }

    /// Reattach the same Party model without applying stale launch metadata or restarting load work.
    /// AetherPlayerSurface still owns the PiP manager's fullscreenSurfaceDidRebind handshake.
    @discardableResult
    func rebindWatchPartyFullscreen() -> Bool {
        guard hasLoaded, !didShutdown else { return false }
        sessionCoordinator.prepareControllers()
        aetherController?.rebindSurface()
        if pollTimer == nil { startPolling() }
        return true
    }

    /// Only the checked Party runtime's resource cleanup calls this entry point.
    func shutdownForWatchParty() {
        guard !didShutdown else { return }
        clearWatchPartyTransitionCallbacks()
        let sourceURL = sessionCoordinator.torrentStreamSourceURL
        cancelStartupBenchmark()
        shutdown(preservingPictureInPicture: false)
        if let sourceURL {
            // Server URLs carry unique session tokens; a delayed exit cannot stop a successor.
            Task {
                await TorrentEngineManager.shared.stopActiveStream(for: sourceURL)
                await UsenetEngineManager.shared.stopActiveStream(for: sourceURL)
            }
        }
    }

    func shutdown() {
        shutdown(preservingPictureInPicture: true)
    }

    private func shutdown(preservingPictureInPicture: Bool) {
        guard !didShutdown else { return }
        if preservingPictureInPicture && PictureInPictureManager.shared.isPictureInPictureActive {
            // Keep playback and session alive for PiP
            pollTimer?.invalidate()
            pollTimer = nil
            controlsHideTimer?.invalidate()
            controlsHideTimer = nil
            cancelPauseOverlaySchedule()
            return
        }
        detachWatchPartyPlayerBridge()
        cancelPendingAdvanceResolution()
        didShutdown = true
        PlaybackTimelineRecorder.record(.playbackStopRequested, engine: activeEngineKind)
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
        diskCacheConcurrencyStr = ""
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        toastClearTask?.cancel()
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
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
        gcHoldSeekTimer?.invalidate()
        gcHoldSeekTimer = nil
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
        isAwaitingStreamStart = false
        if preservingPictureInPicture {
            // Preserve the existing non-Party teardown path.
            playerController.destroyPlayer()
            aetherController?.destroyPlayer()
            PictureInPictureManager.shared.invalidateSession()
        } else if PictureInPictureManager.shared.activeCoordinator === sessionCoordinator {
            // Progress was saved above, before invalidation stops the owned coordinator.
            PictureInPictureManager.shared.invalidateSession()
        } else {
            // Never invalidate another playback's PiP. Also releases this coordinator's cache/wake lock.
            sessionCoordinator.stopAll()
        }
        postPlayController.stop()
        sceneCoordinator.resetSession()
        status = .idle
        PlaybackTimelineRecorder.record(.playbackStopped, engine: activeEngineKind)
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
        recordWatchPartyTransportIntent()
        if isScrubbing {
            commitScrub(andPlay: true)
            return
        }
        if watchPartyPlayerBridge != nil {
            // The transport may have changed since the last 250 ms sample (rapid remote taps).
            _ = routeWatchPartyControl(engine.isTransportPlaying ? .pause : .play)
            return
        }
        let dir = PlaybackToggleDirection(isTransportPlaying: engine.isTransportPlaying)
        screensaverDebugLog("[ScreensaverDebug][PlayerVM] togglePlayPause() called: isTransportPlaying=\(engine.isTransportPlaying), direction=\(dir), status=\(status), time=\(time.current)")
        switch dir {
        case .pause: pause()
        case .play: play()
        }
    }

    func seek(to seconds: Double) {
        guard !isLiveStream, seconds.isFinite else { return }
        recordWatchPartyTransportIntent()
        if watchPartyPlayerBridge != nil {
            guard let target = Self.watchPartySeekMilliseconds(seconds) else { return }
            _ = routeWatchPartyControl(.seek(target))
            return
        }
        let duration = time.duration > 0 ? time.duration : clock.duration
        let target = duration > 0
            ? min(max(seconds, 0), max(duration - 0.25, 0))
            : max(seconds, 0)
        let prevCurrent = time.current
        seekWatchdogLog("[SeekWatchdog][PlayerVM] 👆 User seek to \(String(format: "%.3f", seconds))s (target: \(String(format: "%.3f", target))s, current: \(String(format: "%.3f", time.current))s, duration: \(String(format: "%.3f", duration))s)")
        screensaverDebugLog("[ScreensaverDebug][PlayerVM] seek(to: \(seconds)) called: target=\(target), prevCurrent=\(time.current), duration=\(duration)")
        engine.seekToMs(Int64(target * 1000))
        recordCommittedSeek(to: target, previous: prevCurrent, duration: duration)
    }

    static func watchPartySeekMilliseconds(_ seconds: Double) -> Int64? {
        let milliseconds = max(0, seconds) * 1000
        guard seconds.isFinite, milliseconds.isFinite, milliseconds < Double(Int64.max) else { return nil }
        return Int64(milliseconds.rounded(.towardZero))
    }

    private func recordCommittedSeek(to target: Double, previous: Double, duration: Double) {
        if target < previous - 0.5 { handleRewind(from: previous, to: target) }
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
        if showScenePanel {
            sceneCoordinator.handleSeek()
        }
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
        screensaverDebugLog("[ScreensaverDebug][PlayerVM] playbackDidSuspend(pos=\(positionMs)ms, dur=\(durationMs)ms): currentTime=\(time.current), lastStable=\(lastStablePlaybackTime?.current ?? -1), clock=\(clock.position)")
        guard !didShutdown,
              sourceDurationMs > 0,
              sourcePositionMs >= 0,
              sourcePositionMs < sourceDurationMs else {
            screensaverDebugLog("[ScreensaverDebug][PlayerVM] playbackDidSuspend dropped: shutdown=\(didShutdown), dur=\(sourceDurationMs), pos=\(sourcePositionMs)")
            return
        }
        let existingPositionSeconds = lastStablePlaybackTime?.current ?? time.current
        let targetPositionSeconds: Double
        if sourcePositionMs == 0 && existingPositionSeconds > 5.0 {
            screensaverDebugLog("[ScreensaverDebug][PlayerVM] playbackDidSuspend preserving existing position \(existingPositionSeconds)s against zero-clock sample")
            targetPositionSeconds = existingPositionSeconds
        } else {
            targetPositionSeconds = Double(sourcePositionMs) / 1000.0
        }
        let snapshot = PlayerTime(
            current: targetPositionSeconds,
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
        skipInterval(interval)
    }

    func skipInterval(_ interval: SkipInterval) {
        autoSkippedIntervalIds.insert(interval.id)
        dismissedSkipIntervalIds.insert(interval.id)
        autoHiddenSkipIntervalId = interval.id
        skipSegmentCountdown = nil
        skipSegmentAutoHideDeadline = nil
        if activeSkipInterval?.id == interval.id {
            activeSkipInterval = nil
        }
        if interval.isEnding {
            postPlayController.showImmediately()
        }
        seek(to: min(interval.endTime + 0.25, max(time.duration - 0.5, interval.endTime)))
        showControls = false
        scheduleControlsHide()
    }

    private func handleRewind(from prevCurrent: Double, to target: Double) {
        if target <= 1.0 {
            autoSkippedIntervalIds.removeAll()
        }
        // Reset auto-hidden or dismissed skip intervals only when rewinding before their start
        for segment in skipIntervals {
            if target < max(segment.startTime - 0.35, 0) {
                dismissedSkipIntervalIds.remove(segment.id)
                autoSkippedIntervalIds.remove(segment.id)
                if autoHiddenSkipIntervalId == segment.id {
                    autoHiddenSkipIntervalId = nil
                }
            }
        }
        if !shouldPresentNextEpisodeCard {
            autoHiddenNextEpisodeCard = false
            nextEpisodeAutoHideDeadline = nil
            isAutoPlayCancelled = false
        }
        updateSkipIntervalState()
    }

    func dismissActiveInterval() {
        guard let interval = activeSkipInterval else { return }
        autoHiddenSkipIntervalId = interval.id
        skipSegmentCountdown = nil
        skipSegmentAutoHideDeadline = nil
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
        guard hasStartedPlayback, !isScrubbing, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible else { return }
        recordWatchPartyTransportIntent()
        hidePeek()

        stopRepeatingNudge(commit: false)
        seekDebounceTask?.cancel()
        seekDebounceTask = nil

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
        guard isHoldingSeek, hasStartedPlayback, !isScrubbing, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible else { return }
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
               !isStandalonePlaybackSession,
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

    private func suppressMoveBriefly(_ duration: TimeInterval = 0.4) {
        suppressMoveUntil = max(suppressMoveUntil, Date().addingTimeInterval(duration))
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

    var isShowLoadingStatusEnabled: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.showLoadingStatus) as? Bool ?? true
    }

    func setShowLoadingStatusEnabled(_ enabled: Bool) {
        ProfileSettings.current.set(enabled, forKey: SettingsKey.showLoadingStatus)
        objectWillChange.send()
    }

    func updateLoadingStepMessage() {
        let nextMessage: String
        if isAdvancingEpisode {
            nextMessage = L10n.string("player_searching_sources", fallback: "Searching sources…")
        } else if isSwitchingSource {
            nextMessage = switchingSourceMessage
        } else if isReloadingStream {
            nextMessage = L10n.string("player_loading_preparing", fallback: "Preparing stream…")
        } else if let coordinatorToast = sessionCoordinator.statusToast, !coordinatorToast.isEmpty {
            nextMessage = coordinatorToast
        } else if TorrentEngineManager.shared.isStreaming {
            let stats = TorrentEngineManager.shared.activeStats
            if stats.connectedSeeds > 0 || stats.connectedPeers > 0 {
                nextMessage = L10n.string("player_torrent_connecting_peers", fallback: "Connecting to peers…")
            } else {
                nextMessage = L10n.string("player_torrent_starting_engine", fallback: "Starting P2P engine…")
            }
        } else if isLoadingExternalSubtitles && !hasRenderedFirstFrame {
            nextMessage = L10n.string("player_loading_subtitles", fallback: "Fetching subtitles…")
        } else if let engineMessage = engine.loadingStepMessage, !engineMessage.isEmpty {
            nextMessage = engineMessage
        } else {
            nextMessage = L10n.string("player_status_starting_stream", fallback: "Starting stream")
        }
        if loadingStepMessage != nextMessage { loadingStepMessage = nextMessage }
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
        let selectedBackend = activeEngineKind
        guard let selectedProvider = scrubThumbnailProvider,
              (isScrubbing || isHoldingSeek || pendingSeekDelta != 0 || isTimelineFocused),
              isSeekPreviewEnabled,
              selectedBackend == .aether || selectedBackend == .mpv,
              sessionCoordinator.activeBackend == selectedBackend,
              selectedProvider.supportsScrubThumbnails else {
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
        scrubThumbnailTask = Task { @MainActor [weak self, selectedProvider] in
            guard let self else { return }
            defer {
                // A reset may have installed a newer task after canceling this
                // one. Only its owning generation may clear the handle.
                if self.scrubThumbnailGeneration == generation,
                   self.scrubThumbnailTaskInteractionToken == interactionToken {
                    self.scrubThumbnailTask = nil
                    self.scrubThumbnailTaskInteractionToken = nil
                }
            }
            var lastAttemptTarget: Double?
            var failedAttempts = 0
            var lastDecodeTime = Date.distantPast
            while !Task.isCancelled {
                guard let target = self.pendingScrubThumbnailSeconds else { break }
                self.pendingScrubThumbnailSeconds = nil
                if lastAttemptTarget != target {
                    failedAttempts = 0
                    lastAttemptTarget = target
                }
                let cached = await selectedProvider.cachedScrubThumbnail(
                    atSeconds: target,
                    duration: self.playbackDuration
                )
                guard !Task.isCancelled,
                      self.scrubThumbnailGeneration == generation,
                      self.scrubThumbnailTaskInteractionToken == interactionToken,
                      (self.isScrubbing || self.isHoldingSeek || self.pendingSeekDelta != 0 || self.isTimelineFocused),
                      self.activeEngineKind == selectedBackend,
                      self.sessionCoordinator.activeBackend == selectedBackend,
                      self.isSeekPreviewEnabled,
                      self.scrubThumbnailProvider === selectedProvider,
                      selectedProvider.supportsScrubThumbnails else { return }

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

                    image = await selectedProvider.scrubThumbnail(
                        atSeconds: target, maxWidth: 360, precise: false
                    )
                    lastDecodeTime = Date()
                }

                guard !Task.isCancelled,
                      self.scrubThumbnailGeneration == generation,
                      self.scrubThumbnailTaskInteractionToken == interactionToken,
                      (self.isScrubbing || self.isHoldingSeek || self.pendingSeekDelta != 0 || self.isTimelineFocused),
                      self.activeEngineKind == selectedBackend,
                      self.sessionCoordinator.activeBackend == selectedBackend,
                      self.isSeekPreviewEnabled,
                      self.scrubThumbnailProvider === selectedProvider,
                      selectedProvider.supportsScrubThumbnails else { return }

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
                let refined = await selectedProvider.scrubThumbnail(
                    atSeconds: target, maxWidth: 480, precise: true
                )
                guard !Task.isCancelled,
                      self.scrubThumbnailGeneration == generation,
                      self.scrubThumbnailTaskInteractionToken == interactionToken,
                      (self.isScrubbing || self.isHoldingSeek || self.pendingSeekDelta != 0 || self.isTimelineFocused),
                      self.activeEngineKind == selectedBackend,
                      self.sessionCoordinator.activeBackend == selectedBackend,
                      self.isSeekPreviewEnabled,
                      self.scrubThumbnailProvider === selectedProvider,
                      selectedProvider.supportsScrubThumbnails else { return }
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
        touchBeganWhileStatus = nil
        scrubLastDx = 0
        scrubEngagedThisStroke = false
    }

    func beginScrub() {
        guard !isHoldingSeek, pendingSeekDelta == 0 else { return }
        guard !isLiveStream, hasStartedPlayback, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible else { return }
        guard status == .paused else { return }
        recordWatchPartyTransportIntent()
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
        if watchPartyPlayerBridge != nil {
            resetScrubSession()
            guard let milliseconds = Self.watchPartySeekMilliseconds(target) else { return }
            _ = routeWatchPartyControl(andPlay ? .seekAndPlay(milliseconds) : .seek(milliseconds))
            return
        }
        seek(to: target)
        resetScrubSession()
        if andPlay || status == .playing {
            play()
        } else if status == .paused,
           !isStandalonePlaybackSession,
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
           !isStandalonePlaybackSession,
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
        guard !isHoldingSeek, pendingSeekDelta == 0, !showScenePanel, !isSceneDetailVisible else { return }
        scrubLastDx = 0
        scrubEngagedThisStroke = false
        touchBeganWhileStatus = status
        if isScrubbing {
            suppressMoveBriefly()
        }
        noteSwipeStarted()
        touchIntent = isScrubbing ? .scrub : .undecided
    }

    func remoteTouchMoved(dx: CGFloat, dy: CGFloat) {
        guard !isHoldingSeek, pendingSeekDelta == 0, !showScenePanel, !isSceneDetailVisible else { return }
        switch touchIntent {
        case .scrub:
            suppressMoveBriefly()
            if !scrubEngagedThisStroke {
                // Ignore micro-shifts (< 10pt) during taps or physical OK clicks on the touchpad
                guard abs(dx) >= 10 else { return }
                scrubEngagedThisStroke = true
            }
            scrubPanPoints(dx: dx)
        case .consumed:
            suppressMoveBriefly()
        case .undecided:
            let adx = abs(dx), ady = abs(dy)
            guard max(adx, ady) >= 15 else { return }
            suppressMoveBriefly()
            if ady > adx {
                touchIntent = .consumed
                // Vertical swipe: reveal controls. (Info panel is a later port.)
                revealControls()
            } else {
                // While playing: horizontal swipes are suppressed (no swipe seeking, only tap seek).
                // While paused: enter scrub only when playback was already paused when the touch began.
                guard status == .paused,
                      touchBeganWhileStatus == .paused,
                      adx >= 35,
                      adx > ady * 1.5 else {
                    if status != .paused || touchBeganWhileStatus != .paused {
                        touchIntent = .consumed
                    }
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
        guard !isHoldingSeek, pendingSeekDelta == 0, !showScenePanel, !isSceneDetailVisible else { return }
        if touchIntent == .scrub {
            endScrubGesture()
        } else if touchIntent == .consumed || max(abs(dx), abs(dy)) >= 15 {
            suppressMoveBriefly(0.3)
        }
        scrubEngagedThisStroke = false
        touchBeganWhileStatus = nil
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

    /// Whether discrete directional seek (10s skip / hold-to-seek) can be performed from remote input.
    var canPerformDiscreteSeek: Bool {
        status == .playing
            && hasStartedPlayback
            && !isLiveStream
            && !isScrubbing
            && !showSettingsPanel
            && !showScenePanel
            && !isSceneDetailVisible
            && sidePanel == nil
            && !postPlayState.isVisible
            && !showNextEpisodeCard
            && !showSkipSegmentCard
            && (!showControls || isTimelineFocused)
            && currentErrorDiagnostic == nil
    }

    func dpadSample(x: Double, y: Double) {
        guard !showScenePanel, !isSceneDetailVisible else { return }
        if isScrubbing {
            wheelSample(x: x, y: y)
            return
        }

        let touching = abs(x) > 0.001 || abs(y) > 0.001
        if touching {
            gcLastTouchX = x
            gcLastTouchTime = Date()
            if !gcTouchDown {
                gcTouchDown = true
                gcTouchStartTime = Date()
                gcTouchStartX = x
                gcPanFiredThisTouch = false
                gcDidHandlePressAsSeek = false
            }
        } else if gcTouchDown {
            gcTouchDown = false
            let dur = Date().timeIntervalSince(gcTouchStartTime)
            let lastX = gcLastTouchX ?? gcTouchStartX
            if dur < 0.5, !gcPanFiredThisTouch, !gcDidHandlePressAsSeek, !gcButtonAPressed {
                if canPerformDiscreteSeek, lastX < -0.45 {
                    handleMoveSeek(direction: .left)
                } else if canPerformDiscreteSeek, lastX > 0.45 {
                    handleMoveSeek(direction: .right)
                } else {
                    remoteTapped()
                }
            }
        }
    }

    /// Handles GameController buttonA (physical click on Siri Remote touchpad).
    /// On 1st Gen Siri Remotes (black remote), clicks on the left/right sides trigger discrete seek or hold-to-seek.
    func handleGCButtonA(isPressed: Bool, pad: GCMicroGamepad? = nil, touchX: Double? = nil) {
        let currentTouchX = touchX ?? gcLastTouchX ?? pad.map { Double($0.dpad.xAxis.value) } ?? 0

        if isPressed {
            gcButtonAPressed = true
            gcButtonAPressedStartTime = Date()
            gcButtonAPressX = currentTouchX

            if canPerformDiscreteSeek, abs(currentTouchX) > 0.35 {
                gcHoldSeekTimer?.invalidate()
                let direction: MoveCommandDirection = currentTouchX < 0 ? .left : .right
                let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.gcButtonAPressed else { return }
                        self.gcDidHandlePressAsSeek = true
                        if direction == .left {
                            self.beginRepeatingSkipBackward()
                        } else {
                            self.beginRepeatingSkipForward()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                gcHoldSeekTimer = timer
            }
        } else {
            gcButtonAPressed = false
            gcHoldSeekTimer?.invalidate()
            gcHoldSeekTimer = nil

            if isHoldingSeek {
                stopRepeatingSkip()
                gcDidHandlePressAsSeek = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    self.gcDidHandlePressAsSeek = false
                }
                return
            }

            let pressX = gcButtonAPressX ?? currentTouchX
            if canPerformDiscreteSeek, abs(pressX) > 0.35 {
                if !gcDidHandlePressAsSeek {
                    gcDidHandlePressAsSeek = true
                    if pressX < -0.35 {
                        handleMoveSeek(direction: .left)
                    } else {
                        handleMoveSeek(direction: .right)
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    self.gcDidHandlePressAsSeek = false
                }
            }
        }
    }

    /// Handles a select / click gesture from the remote (e.g. from SwiftUI `.onTapGesture`).
    /// Dispatches edge clicks to discrete seeking on 1st Gen Siri Remotes, and center clicks to play/pause.
    func handleSelectTap(isOverlayFocused: Bool = false) {
        if isOverlayFocused {
            if isScrubbing {
                commitScrub()
            } else if showPauseOverlay {
                play()
            } else {
                togglePlayPause()
            }
            return
        }

        if gcDidHandlePressAsSeek {
            gcDidHandlePressAsSeek = false
            return
        }

        if let lastTouchTime = gcLastTouchTime,
           Date().timeIntervalSince(lastTouchTime) < 0.45,
           let lastX = gcLastTouchX,
           canPerformDiscreteSeek,
           abs(lastX) > 0.35 {
            gcDidHandlePressAsSeek = true
            if lastX < -0.35 {
                handleMoveSeek(direction: .left)
            } else {
                handleMoveSeek(direction: .right)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self.gcDidHandlePressAsSeek = false
            }
            return
        }

        if isScrubbing {
            commitScrub()
        } else if showPauseOverlay {
            play()
        } else {
            togglePlayPause()
        }
    }

    /// Light touchpad contact (no click, no swipe) → peek bar.
    private func remoteTapped() {
        guard hasStartedPlayback, !isScrubbing, !showControls, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible else { return }
        showPeek()
    }

    func showPeek() {
        guard hasStartedPlayback, !showControls, !isScrubbing, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible else { return }
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
            pad.buttonA.pressedChangedHandler = { [weak self] _, _, isPressed in
                Task { @MainActor in
                    self?.handleGCButtonA(isPressed: isPressed, pad: pad)
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
        guard hasStartedPlayback, !isScrubbing, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible else { return }
        // Discrete tap: do not interrupt an active hold-to-seek session
        guard !isHoldingSeek else { return }
        recordWatchPartyTransportIntent()
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
                  !isStandalonePlaybackSession,
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
        seekDebounceTask = nil
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
               !isStandalonePlaybackSession,
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
        guard hasStartedPlayback, !isScrubbing, !showSettingsPanel, !showScenePanel, !isSceneDetailVisible else { return }
        guard !isHoldingSeek else { return }

        let delta = direction == .left ? -Double(seekStepSeconds) : Double(seekStepSeconds)
        nudgeSeek(delta)
    }

    func cancelMoveSeekTracking() {}

    func setSpeed(_ speed: PlaybackSpeed) {
        if routeWatchPartyControl(.speed(speed.rawValue)) { return }
        recordWatchPartyTransportIntent()
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
        if isAudioDelayPersistEnabled {
            ProfileSettings.current.set(clamped, forKey: SettingsKey.persistentAudioDelayMs)
        }
        sessionCoordinator.updateAudioDelay(Double(clamped) / 1_000)
        engine.setAudioDelay(Double(clamped) / 1000.0)
    }

    var isAudioDelayPersistEnabled: Bool {
        ProfileSettings.current.bool(forKey: SettingsKey.audioDelayPersistEnabled)
    }

    var persistentAudioDelayMs: Int {
        ProfileSettings.current.integer(forKey: SettingsKey.persistentAudioDelayMs)
    }

    func setAudioDelayPersistEnabled(_ enabled: Bool) {
        ProfileSettings.current.set(enabled, forKey: SettingsKey.audioDelayPersistEnabled)
        if enabled {
            ProfileSettings.current.set(audioDelayMs, forKey: SettingsKey.persistentAudioDelayMs)
        }
        objectWillChange.send()
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

    func setEnhanceDialogueMode(_ mode: EnhanceDialogueMode) {
        enhanceDialogueMode = mode
        engine.setAudioProcessing(dialogue: enhanceDialogueMode, reduceLoud: isReduceLoudSoundsActive)
    }

    func toggleReduceLoudSounds() {
        isReduceLoudSoundsActive.toggle()
        engine.setAudioProcessing(dialogue: enhanceDialogueMode, reduceLoud: isReduceLoudSoundsActive)
    }

    // MARK: - Track selection

    func selectSubtitle(_ track: SubtitleTrack, persist: Bool = true) {
        PlaybackTimelineRecorder.record(.subtitleSelectionRequested, engine: activeEngineKind)
        pendingSelectedExternalSubtitleURL = nil
        if track.id == "off" {
            engine.selectSubtitle(-1)
        } else if let id = Int(track.id) {
            engine.selectSubtitle(id)
        }
        PlaybackTimelineRecorder.record(.subtitleSelectionReturned, engine: activeEngineKind)
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
        PlaybackTimelineRecorder.record(.externalSubtitleRequested, engine: activeEngineKind)
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

    /// The best-matching full external subtitle worth auto-loading into the player:
    /// at most one non-forced subtitle matching the highest-priority preference.
    static func smartMatchedSubtitles(in subtitles: [NuvioSubtitle]) -> [NuvioSubtitle] {
        guard !subtitles.isEmpty,
              SubtitleLanguagePreferences.smartMatchingEnabled() else {
            return []
        }
        for language in SubtitleLanguagePreferences.orderedFromDefaults() {
            if let match = subtitles.first(where: { subtitle in
                !isForcedSubtitleLabel(subtitle.label) &&
                (SubtitleLanguagePreferences.matches(subtitle.language, target: language) ||
                 SubtitleLanguagePreferences.matches(subtitle.label, target: language))
            }) {
                return [match]
            }
        }
        return []
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

        if !didApplySavedAudioSelection, let audio = selection.audio {
            let showLanguageOverride = activeMeta.flatMap { ShowAudioLanguageStore.canonicalKey(meta: $0) }
                .flatMap { ShowAudioLanguageStore.getLanguage(for: $0) }
            let showPrefersDifferentLanguage: Bool
            if showLanguageOverride != nil,
               let target = SubtitleLanguagePreferences.preferredAudioLanguage(meta: activeMeta) {
                showPrefersDifferentLanguage = !audioTrackMatches(audio, language: target)
            } else {
                showPrefersDifferentLanguage = false
            }

            if !showPrefersDifferentLanguage, let matchingTrack = matchingAudioTrack(for: audio) {
                didApplySavedAudioSelection = true
                selectAudio(matchingTrack, persist: false)
            } else if showPrefersDifferentLanguage {
                pendingTrackSelection?.audio = nil
            }
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
            } else if let available = availableExternalSubtitles.first(where: { $0.url == url }) {
                if !addedExternalSubtitleURLs.contains(available.url) {
                    engine.addSubtitle(available, select: true)
                    addedExternalSubtitleURLs.insert(available.url)
                }
                pendingSelectedExternalSubtitleURL = available.url
            }
        }
    }

    private func applyAudioPreferenceIfNeeded() {
        guard !didApplyAudioPreference, !didApplySavedAudioSelection, pendingTrackSelection?.audio == nil else { return }
        guard let preferred = SubtitleLanguagePreferences.preferredAudioLanguage(meta: activeMeta) else {
            didApplyAudioPreference = true
            return
        }
        guard let matchingTrack = audioTracks.first(where: { audioTrack($0, matches: preferred) }) else { return }
        didApplyAudioPreference = true
        selectAudio(matchingTrack, persist: false)
    }

    static func automaticSubtitlePolicy(
        selectedAudio: AudioTrack?,
        preferredAudioLanguage: String?,
        preferredSubtitleLanguages: [String],
        allowForcedSubtitles: Bool
    ) -> AutomaticSubtitlePolicy? {
        if let selectedAudio,
           let preferredAudioLanguage,
           selectedAudioTrack(selectedAudio, matches: preferredAudioLanguage) {
            if allowForcedSubtitles {
                return .forced(language: preferredAudioLanguage)
            }
            if preferredSubtitleLanguages.isEmpty {
                return .off
            }
        }
        guard !preferredSubtitleLanguages.isEmpty else { return nil }
        return .preferredLanguages(preferredSubtitleLanguages)
    }

    private static func selectedAudioTrack(_ track: AudioTrack, matches language: String) -> Bool {
        SubtitleLanguagePreferences.matches(track.language, target: language) ||
        SubtitleLanguagePreferences.matches(track.languageName, target: language) ||
        SubtitleLanguagePreferences.matches(track.name, target: language)
    }

    private func applySubtitlePreferenceIfNeeded() {
        guard !didApplySubtitlePreference else { return }
        guard pendingTrackSelection?.subtitle == nil else { return }
        guard SubtitleLanguagePreferences.smartMatchingEnabled() else { return }
        let allowForcedSubtitles = Self.allowsAutomaticForcedSubtitles
        let preferredLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        guard let policy = Self.automaticSubtitlePolicy(
            selectedAudio: audioTracks.first(where: { $0.isSelected }),
            preferredAudioLanguage: SubtitleLanguagePreferences.preferredAudioLanguage(meta: activeMeta),
            preferredSubtitleLanguages: preferredLanguages,
            allowForcedSubtitles: allowForcedSubtitles
        ) else {
            didApplySubtitlePreference = true
            return
        }

        switch policy {
        case .off:
            guard let off = subtitles.first(where: { $0.id == "off" }) else { return }
            pendingSelectedExternalSubtitleURL = nil
            didApplySubtitlePreference = true
            if !off.isSelected { selectSubtitle(off, persist: false) }
            return

        case .forced(let language):
            let selectedTrack = subtitles.first(where: { $0.isSelected })
            if Self.shouldPreserveBackendSubtitleSelection(
                selectedTrack,
                preferredLanguages: [language],
                allowForcedSubtitles: true,
                requireForcedSubtitle: true
            ) {
                didApplySubtitlePreference = true
                return
            }

            if let forcedTrack = Self.matchingForcedSubtitle(in: subtitles, language: language) {
                didApplySubtitlePreference = true
                selectSubtitle(forcedTrack, persist: false)
                return
            }

            let loadedExternalURLs = Set(subtitles.map(\.externalFilename).filter { !$0.isEmpty })
            if let pendingForced = pendingExternalSubtitles.first(where: { subtitle in
                !loadedExternalURLs.contains(subtitle.url) && Self.externalSubtitle(subtitle, matches: language, forcedOnly: true)
            }) {
                pendingSelectedExternalSubtitleURL = pendingForced.url
                if let off = subtitles.first(where: { $0.id == "off" }), !off.isSelected {
                    selectSubtitle(off, persist: false)
                    pendingSelectedExternalSubtitleURL = pendingForced.url
                }
                return
            }

            if let external = availableExternalSubtitles.first(where: {
                Self.externalSubtitle($0, matches: language, forcedOnly: true)
            }) {
                if addedExternalSubtitleURLs.contains(external.url) {
                    pendingSelectedExternalSubtitleURL = external.url
                    if let off = subtitles.first(where: { $0.id == "off" }), !off.isSelected {
                        selectSubtitle(off, persist: false)
                        pendingSelectedExternalSubtitleURL = external.url
                    }
                    return
                }
                if !pendingExternalSubtitles.contains(where: { $0.url == external.url }) {
                    pendingExternalSubtitles.append(external)
                }
                pendingSelectedExternalSubtitleURL = external.url
                if let off = subtitles.first(where: { $0.id == "off" }), !off.isSelected {
                    selectSubtitle(off, persist: false)
                    pendingSelectedExternalSubtitleURL = external.url
                }
                didAddExternalSubtitles = false
                addPendingExternalSubtitlesIfNeeded()
                return
            }

            guard let off = subtitles.first(where: { $0.id == "off" }) else { return }
            pendingSelectedExternalSubtitleURL = nil
            didApplySubtitlePreference = true
            if !off.isSelected { selectSubtitle(off, persist: false) }
            return

        case .preferredLanguages(let preferredLanguages):
            // Both playback backends can resolve the preference during load. Keep
            // that selection instead of replacing it with the first matching row.
            if Self.shouldPreserveBackendSubtitleSelection(
                subtitles.first(where: { $0.isSelected }),
                preferredLanguages: preferredLanguages,
                allowForcedSubtitles: false
            ) {
                didApplySubtitlePreference = true
                return
            }

            let loadedExternalURLs = Set(subtitles.map(\.externalFilename).filter { !$0.isEmpty })
            for language in preferredLanguages {
                if let matchingTrack = Self.matchingPreferredFullSubtitle(in: subtitles, language: language) {
                    didApplySubtitlePreference = true
                    selectSubtitle(matchingTrack, persist: false)
                    return
                }

                let hasPendingMatch = pendingExternalSubtitles.contains { subtitle in
                    !loadedExternalURLs.contains(subtitle.url) &&
                    !Self.isForcedSubtitleLabel(subtitle.label) &&
                    (SubtitleLanguagePreferences.matches(subtitle.language, target: language) ||
                     SubtitleLanguagePreferences.matches(subtitle.label, target: language))
                }
                if hasPendingMatch {
                    let selectedTrack = subtitles.first(where: { $0.isSelected })
                    if let selectedTrack,
                       Self.isForcedSubtitle(selectedTrack),
                       let off = subtitles.first(where: { $0.id == "off" }) {
                        let pendingFull = pendingExternalSubtitles.first {
                            !loadedExternalURLs.contains($0.url) &&
                            !Self.isForcedSubtitleLabel($0.label) &&
                            (SubtitleLanguagePreferences.matches($0.language, target: language) ||
                             SubtitleLanguagePreferences.matches($0.label, target: language))
                        }
                        pendingSelectedExternalSubtitleURL = pendingFull?.url
                        if !off.isSelected {
                            selectSubtitle(off, persist: false)
                            pendingSelectedExternalSubtitleURL = pendingFull?.url
                        }
                    }
                    return
                }
            }

            let pendingPreferredURLs = Set(pendingExternalSubtitles.filter {
                !Self.isForcedSubtitleLabel($0.label)
            }.map(\.url))
            guard pendingPreferredURLs.isSubset(of: loadedExternalURLs) else { return }
            guard subtitles.contains(where: { $0.id != "off" }) else { return }
            guard let off = subtitles.first(where: { $0.id == "off" }) else { return }
            didApplySubtitlePreference = true
            selectSubtitle(off, persist: false)
        }
    }

    static func shouldPreserveBackendSubtitleSelection(
        _ selectedTrack: SubtitleTrack?,
        preferredLanguages: [String],
        allowForcedSubtitles: Bool = true,
        requireForcedSubtitle: Bool = false
    ) -> Bool {
        guard let selectedTrack,
              selectedTrack.id != "off",
              selectedTrack.isSelected,
              allowForcedSubtitles || !isForcedSubtitle(selectedTrack),
              !requireForcedSubtitle || isForcedSubtitle(selectedTrack) else {
            return false
        }

        return preferredLanguages.contains { language in
            SubtitleLanguagePreferences.matches(selectedTrack.language, target: language) ||
            SubtitleLanguagePreferences.matches(selectedTrack.name, target: language)
        }
    }

    func selectAudio(_ track: AudioTrack, persist: Bool = true) {
        PlaybackTimelineRecorder.record(.audioSelectionRequested, engine: activeEngineKind)
        if let id = Int(track.id) {
            engine.selectAudio(id)
        }
        PlaybackTimelineRecorder.record(.audioSelectionReturned, engine: activeEngineKind)
        audioTracks = audioTracks.map { var t = $0; t.isSelected = (t.id == track.id); return t }
        if persist {
            saveAudioSelection(track)
            didApplySavedAudioSelection = true
            didApplyAudioPreference = true
            reapplyAutomaticSubtitlePreferenceAfterAudioSelection()
        }
    }

    private func reapplyAutomaticSubtitlePreferenceAfterAudioSelection() {
        guard !hasExplicitSubtitleSelection,
              pendingTrackSelection?.subtitle == nil,
              sessionTrackSelection?.subtitle == nil else { return }
        didApplySubtitlePreference = false
        applySubtitlePreferenceIfNeeded()
    }

    private func saveAudioSelection(_ track: AudioTrack) {
        let audio = PlayerTrackSelection.Audio(
            id: track.id,
            name: track.name,
            language: track.language,
            languageName: track.languageName
        )
        rememberSessionAudio(audio)
        if let meta = activeMeta, let showId = ShowAudioLanguageStore.canonicalKey(meta: meta) {
            if let lang = Self.detectedLanguage(for: track) {
                ShowAudioLanguageStore.setLanguage(lang, for: showId)
            }
        }
        guard let activeTrackSelectionKey else { return }
        PlayerTrackSelectionStore.saveAudio(audio, for: activeTrackSelectionKey)
    }

    private func audioTrackMatches(_ audio: PlayerTrackSelection.Audio, language: String) -> Bool {
        SubtitleLanguagePreferences.matches(audio.language, target: language) ||
        SubtitleLanguagePreferences.matches(audio.languageName, target: language) ||
        SubtitleLanguagePreferences.matches(audio.name, target: language)
    }

    nonisolated static func detectedLanguage(for track: AudioTrack) -> String? {
        let langCode = track.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !langCode.isEmpty && langCode.lowercased() != "und" {
            if let match = SubtitleLanguagePreferences.supportedLanguages.first(where: {
                SubtitleLanguagePreferences.matches(langCode, target: $0)
            }) {
                return match
            }
        }

        let langName = track.languageName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !langName.isEmpty {
            if let match = SubtitleLanguagePreferences.supportedLanguages.first(where: {
                SubtitleLanguagePreferences.matches(langName, target: $0)
            }) {
                return match
            }
        }

        let trackTitle = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trackTitle.isEmpty {
            if let match = SubtitleLanguagePreferences.supportedLanguages.first(where: {
                SubtitleLanguagePreferences.matches(trackTitle, target: $0)
            }) {
                return match
            }
        }

        let fallbackCandidate = !langCode.isEmpty && langCode.lowercased() != "und"
            ? langCode
            : (!langName.isEmpty ? langName : "")
        if !fallbackCandidate.isEmpty {
            let lower = fallbackCandidate.lowercased()
            if let locName = Locale.current.localizedString(forLanguageCode: lower) ??
                             Locale(identifier: "en").localizedString(forLanguageCode: lower) {
                return locName.prefix(1).uppercased() + locName.dropFirst()
            }
        }
        return nil
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
        if let track = audioTracks.first(where: {
            Self.sameTrackText($0.name, saved.name) &&
            (Self.sameTrackText($0.language, saved.language) ||
             SubtitleLanguagePreferences.matches($0.language, target: saved.language) ||
             Self.sameTrackText($0.languageName, saved.languageName))
        }) { return track }
        if !saved.name.isEmpty,
           let track = audioTracks.first(where: { Self.sameTrackText($0.name, saved.name) }) {
            return track
        }
        if !saved.language.isEmpty,
           let track = audioTracks.first(where: {
               Self.sameTrackText($0.language, saved.language) ||
               SubtitleLanguagePreferences.matches($0.language, target: saved.language) ||
               SubtitleLanguagePreferences.matches($0.name, target: saved.language)
           }) {
            return track
        }
        if !saved.languageName.isEmpty,
           let track = audioTracks.first(where: { Self.sameTrackText($0.languageName, saved.languageName) }) {
            return track
        }
        let hasMetadata = !saved.name.isEmpty || !saved.language.isEmpty || !saved.languageName.isEmpty
        if let track = audioTracks.first(where: { track in
            guard track.id == saved.id else { return false }
            return !hasMetadata ||
                Self.sameTrackText(track.name, saved.name) ||
                Self.sameTrackText(track.language, saved.language) ||
                Self.sameTrackText(track.languageName, saved.languageName)
        }) { return track }
        return nil
    }

    private func matchingEmbeddedSubtitleTrack(for saved: PlayerTrackSelection.Subtitle) -> SubtitleTrack? {
        let candidates = subtitles.filter { $0.id != "off" && $0.externalFilename.isEmpty }
        if let track = candidates.first(where: {
            Self.sameTrackText($0.name, saved.name) &&
            (Self.sameTrackText($0.language, saved.language) ||
             (saved.language != nil && SubtitleLanguagePreferences.matches($0.language, target: saved.language!)))
        }) { return track }
        if let name = saved.name, !name.isEmpty,
           let track = candidates.first(where: { Self.sameTrackText($0.name, name) }) {
            return track
        }
        if let language = saved.language, !language.isEmpty,
           let track = candidates.first(where: {
               Self.sameTrackText($0.language, language) ||
               SubtitleLanguagePreferences.matches($0.language, target: language) ||
               SubtitleLanguagePreferences.matches($0.name, target: language)
           }) {
            return track
        }
        let hasMetadata = !(saved.name ?? "").isEmpty || !(saved.language ?? "").isEmpty
        if let id = saved.id,
           let track = candidates.first(where: { track in
               guard track.id == id else { return false }
               return !hasMetadata ||
                   Self.sameTrackText(track.name, saved.name) ||
                   Self.sameTrackText(track.language, saved.language)
           }) {
            return track
        }
        return nil
    }

    private func audioTrack(_ track: AudioTrack, matches language: String) -> Bool {
        Self.selectedAudioTrack(track, matches: language)
    }

    static func isForcedSubtitle(_ track: SubtitleTrack) -> Bool {
        track.isForced || isForcedSubtitleLabel(track.name)
    }

    static func matchingPreferredFullSubtitle(in tracks: [SubtitleTrack], language: String) -> SubtitleTrack? {
        tracks.first { track in
            track.id != "off" &&
            !isForcedSubtitle(track) &&
            (SubtitleLanguagePreferences.matches(track.language, target: language) ||
             SubtitleLanguagePreferences.matches(track.name, target: language))
        }
    }

    static func matchingForcedSubtitle(in tracks: [SubtitleTrack], language: String) -> SubtitleTrack? {
        tracks.first { track in
            track.id != "off" &&
            isForcedSubtitle(track) &&
            (SubtitleLanguagePreferences.matches(track.language, target: language) ||
             SubtitleLanguagePreferences.matches(track.name, target: language))
        }
    }

    private static func externalSubtitle(
        _ subtitle: NuvioSubtitle,
        matches language: String,
        forcedOnly: Bool
    ) -> Bool {
        (!forcedOnly || isForcedSubtitleLabel(subtitle.label)) &&
        (SubtitleLanguagePreferences.matches(subtitle.language, target: language) ||
         SubtitleLanguagePreferences.matches(subtitle.label, target: language))
    }

    private static var allowsAutomaticForcedSubtitles: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.forcedSubtitles) as? Bool ?? true
    }

    static func isForcedSubtitleLabel(_ label: String?) -> Bool {
        let words = (label ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        return words.contains("forced") || words.contains("forzado") || words.contains("forzados")
    }

    private static func sameTrackText(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !left.isEmpty && left == right
    }

    // MARK: - Controls visibility

    func scheduleControlsHide(after interval: TimeInterval? = nil) {
        guard status == .playing else {
            cancelControlsHideTimer()
            return
        }
        controlsHideTimer?.invalidate()
        let timeout = interval ?? (isTimelineFocused ? 5.0 : 10.0)
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.status == .playing else { return }
                guard !self.controlsAutoHideSuspended else { return }
                guard !self.isHoldingSeek else { return }
                guard !self.showSettingsPanel, !self.showScenePanel, !self.isSceneDetailVisible else { return }
                guard self.sidePanel == nil else { return }
                guard !self.isScrubbing else { return }
                self.showControls = false
                self.updateSkipIntervalState()
            }
        }
    }

    private func cancelControlsHideTimer() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
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
        if isScrubbing || controlsAutoHideSuspended || showScenePanel || isSceneDetailVisible { return }
        // Full transport chrome supersedes the pause metadata sheet.
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        let wasHidden = !showControls
        showControls = true
        if wasHidden {
            isTimelineFocused = true
        }
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
        allowsManualEpisodeSelection && !seriesEpisodes.isEmpty && !isStandalonePlaybackSession
    }

    var canShowSourcesPanel: Bool {
        fetchPlaybackSources != nil && !isStandalonePlaybackSession
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
        if let activeSourceID, !activeSourceID.isEmpty { return stream.id == activeSourceID }
        guard let active = activeStreamURL else { return false }
        if let url = stream.directURL, !url.isEmpty {
            return url == active
        }
        return false
    }

    func selectSource(_ stream: NuvioStream) {
        PlaybackTimelineRecorder.record(.sourceSelectionRequested, engine: activeEngineKind)
        if let unavailableReason = stream.unavailabilityReason {
            showPlayerToast(unavailableReason)
            return
        }
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
        let startupToken = beginSourceSwitch(message: "Switching source…")
        // Drop the panel now, not after the resolve: it covers the whole screen,
        // so leaving it up hides the spinner for the entire round trip.
        closeSidePanel()

        Task { @MainActor [weak self] in
            guard let self else {
                PlaybackStartupTiming.cancel(token: startupToken)
                return
            }
            let result = await resolvePlaybackStream(stream, contentId, subtitleLine, startupToken)
            guard !Task.isCancelled,
                  self.startupBenchmarkToken == startupToken,
                  PlaybackStartupTiming.isActive(token: startupToken) else {
                self.cancelStartupBenchmark(token: startupToken)
                return
            }
            guard var prepared = result else {
                self.cancelStartupBenchmark(token: startupToken)
                self.isSwitchingSource = false
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
            prepared.sourceID = stream.id
            self.failedStreamURLs.removeAll()
            let group = stream.bingeGroup ?? StreamQualityTags.syntheticBingeGroup(for: stream)
            if let group, !group.isEmpty {
                self.activeBingeGroup = group
            }
            if let meta = self.activeMeta {
                BingeGroupStore.save(seriesId: meta.id, stream: stream)
            }
            self.replaceStream(prepared: prepared, episode: nil, resumeFrom: resume)
            if self.watchPartyPlayerBridge != nil {
                await self.onWatchPartySourceChanged?()
            }
            self.showPlayerToast(self.watchPartyPlayerBridge == nil
                ? "Source switched"
                : "Source switched. Share it from the Watch Party panel if guests should use it.")
        }
    }

    /// Shared entry for a user-initiated switch: park the engine and put the
    /// player into a labelled loading state that stays up until the new stream
    /// actually starts.
    private func beginSourceSwitch(message: String) -> UUID {
        cancelPendingAdvanceResolution()
        let token = beginStartupBenchmark(title: activeMeta?.name ?? "")
        isSwitchingSource = true
        switchingSourceMessage = message
        loadingStepMessage = message
        isAwaitingStreamStart = true
        hasProducedMidFilePosition = false
        status = .buffering
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        engine.pausePlayback()
        return token
    }

    func selectEpisode(_ episode: NuvioVideo) {
        guard allowsManualEpisodeSelection else {
            showPlayerToast("Only the host can change the room episode")
            return
        }
        guard let resolveNextStream else {
            showPlayerToast("Episode switching unavailable")
            return
        }
        if episode.id == currentEpisodeVideo?.id {
            closeSidePanel()
            return
        }
        isAdvanceInFlight = false
        lastAdvancedEpisodeId = nil
        let startupToken = beginSourceSwitch(message: "Loading episode…")
        closeSidePanel()

        Task { @MainActor [weak self] in
            guard let self else {
                PlaybackStartupTiming.cancel(token: startupToken)
                return
            }
            let prepared = await resolveNextStream(episode, startupToken)
            guard !Task.isCancelled,
                  self.startupBenchmarkToken == startupToken,
                  PlaybackStartupTiming.isActive(token: startupToken) else {
                self.cancelStartupBenchmark(token: startupToken)
                return
            }
            guard let prepared else {
                self.cancelStartupBenchmark(token: startupToken)
                self.isSwitchingSource = false
                self.showPlayerToast("Couldn't load this episode")
                self.isAwaitingStreamStart = false
                self.status = .paused
                return
            }
            self.failedStreamURLs.removeAll()
            self.availableSources = []
            if self.watchPartyPlayerBridge != nil {
                guard let transition = self.onWatchPartyEpisodeResolved,
                      await transition(episode, prepared) else {
                    self.cancelStartupBenchmark(token: startupToken)
                    self.isSwitchingSource = false
                    self.isAwaitingStreamStart = false
                    self.status = .paused
                    self.showPlayerToast("Couldn't change the Watch Party episode")
                    return
                }
                return
            }
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
        guard controlsAutoHideSuspended != suspended else { return }
        controlsAutoHideSuspended = suspended
        if suspended {
            controlsHideTimer?.invalidate()
            cancelPauseOverlaySchedule()
        } else if showControls {
            if status == .playing {
                scheduleControlsHide()
            } else if status == .paused,
                      !isStandalonePlaybackSession,
                      !isScrubbing {
                schedulePauseOverlay()
            }
        } else if status == .paused,
                  !isStandalonePlaybackSession,
                  !isScrubbing {
            schedulePauseOverlay()
        }
    }

    // MARK: - Scene Feature
    
    @Published var showScenePanel: Bool = false
    
    var isSceneEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.sceneFeatureEnabled) as? Bool ?? true
    }
    
    var isSceneDetailVisible: Bool {
        sceneViewModel.isDetailVisible
    }
    
    private var sceneSessionID: UUID = UUID()

    private(set) lazy var sceneAudioTapBroker = PlaybackAudioTapBroker(engine: aetherController?.engine)
    
    var currentActiveSubtitleText: String? {
        switch activeEngineKind {
        case .aether:
            return aetherController?.currentSubtitleText(at: time.current)
        case .mpv:
            return playerController.currentSubtitleText
        }
    }

    private(set) lazy var sceneCoordinator: SceneCoordinator = {
        let coordinator: SceneCoordinator
        if let suppliedSceneCoordinator {
            coordinator = suppliedSceneCoordinator
        } else {
            let frameProvider = DynamicPlayerSceneFrameProvider(
                activeEngineKindProvider: { [weak self] in self?.activeEngineKind ?? .aether },
                aetherControllerProvider: { [weak self] in self?.aetherController }
            )
            coordinator = SceneCoordinator(
                frameProvider: frameProvider,
                audioTapBroker: sceneAudioTapBroker
            )
        }
        coordinator.setPlaybackProviders(
            isPlaying: { [weak self] in self?.status == .playing },
            sourceTime: { [weak self] in self?.time.current ?? 0 },
            activeSubtitleText: { [weak self] in self?.currentActiveSubtitleText }
        )
        return coordinator
    }()
    
    private(set) lazy var sceneViewModel: SceneViewModel = {
        let vm = SceneViewModel(coordinator: sceneCoordinator)
        vm.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        return vm
    }()

    private func buildSceneContext(
        meta: NuvioMeta? = nil,
        currentEpisode: NuvioVideo? = nil,
        sessionID: UUID? = nil
    ) -> SceneContext {
        let targetMeta = meta ?? activeMeta
        let targetEpisode = currentEpisode ?? currentEpisodeVideo
        let contentImdbId = targetMeta?.imdbId
            ?? (targetMeta?.id.hasPrefix("tt") == true ? targetMeta?.id : nil)
            ?? (targetEpisode?.id.hasPrefix("tt") == true ? targetEpisode?.id : nil)
        let resolvedImdb = contentImdbId?.split(separator: ":").first.map(String.init)
        let resolvedTitle = targetMeta?.name ?? title

        let isAnime = (targetMeta?.isAnime == true)
            || (targetMeta?.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "anime")
            || NuvioMeta.isAnimeStream(
                filename: activeFilename ?? activeStreamURL,
                streamName: activeProviderName,
                streamDescription: activeBingeGroup
            )

        return SceneContext(
            canonicalId: targetMeta?.id ?? targetEpisode?.id ?? resolvedTitle,
            mediaType: targetMeta?.type ?? "movie",
            title: resolvedTitle,
            season: targetEpisode?.season,
            episode: targetEpisode?.episode,
            tmdbId: targetMeta?.tmdbId,
            imdbId: resolvedImdb,
            streamURL: activeStreamURL.flatMap(URL.init(string:)),
            sessionID: sessionID ?? sceneSessionID,
            timelineGeneration: sessionCoordinator.loadGeneration,
            backend: activeEngineKind,
            isAnime: isAnime
        )
    }

    private func prewarmSceneIfNeeded(meta: NuvioMeta, isTrailerPlayback: Bool) {
        guard isSceneEnabled, !isTrailerPlayback else { return }
        let context = buildSceneContext(meta: meta)
        sceneCoordinator.prewarm(context: context)
        if !availableExternalSubtitles.isEmpty {
            sceneCoordinator.updateAvailableSubtitles(availableExternalSubtitles)
        }
    }
    
    func buildScenePlaybackInfo() -> ScenePlaybackInfo {
        let engineName: String
        let engineVer: String
        switch activeEngineKind {
        case .aether:
            engineName = "AetherEngine"
            engineVer = aetherController?.engineVersion ?? AetherEngine.version
        case .mpv:
            engineName = "MPVKit"
            engineVer = sessionCoordinator.mpvController.engineVersion ?? "—"
        }

        let aether: AetherPlaybackController?
        let mpv: MPVPlayerViewController?
        let debug: PlaybackDebugInfo?
        switch activeEngineKind {
        case .aether:
            aether = aetherController
            mpv = nil
            debug = Self.selectedScenePlaybackDebugInfo(
                activeEngineKind: .aether,
                aether: aether?.playbackDebugInfo,
                mpv: nil
            )
        case .mpv:
            aether = nil
            mpv = sessionCoordinator.mpvController
            debug = Self.selectedScenePlaybackDebugInfo(
                activeEngineKind: .mpv,
                aether: nil,
                mpv: mpv?.playbackDebugInfo
            )
        }
        func reportedValue(_ candidates: [String?]) -> String? {
            candidates.compactMap { candidate in
                guard let candidate else { return nil }
                let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.caseInsensitiveCompare("Unknown") != .orderedSame else { return nil }
                return value
            }.first
        }

        // Video Codec
        let rawCodec = reportedValue([debug?.videoCodec]) ?? "—"
        let videoCodec: String
        let codecUpper = rawCodec.uppercased()
        if codecUpper.contains("HEVC") || codecUpper.contains("H265") || codecUpper.contains("H.265") {
            videoCodec = "HEVC"
        } else if codecUpper.contains("H264") || codecUpper.contains("AVC") || codecUpper.contains("H.264") {
            videoCodec = "H.264"
        } else if codecUpper.contains("AV1") {
            videoCodec = "AV1"
        } else if codecUpper.contains("VP9") {
            videoCodec = "VP9"
        } else if !rawCodec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && codecUpper != "UNKNOWN" {
            videoCodec = rawCodec.uppercased()
        } else {
            videoCodec = "—"
        }

        // Resolution
        let resRaw = reportedValue([debug?.resolution]) ?? ""
        let resolution: String
        if !resRaw.isEmpty {
            resolution = resRaw.replacingOccurrences(of: "×", with: " × ")
                               .replacingOccurrences(of: "x", with: " × ")
                               .replacingOccurrences(of: "  ×  ", with: " × ")
        } else if videoNaturalSize.width > 0 && videoNaturalSize.height > 0 {
            resolution = "\(Int(videoNaturalSize.width)) × \(Int(videoNaturalSize.height))"
        } else {
            resolution = "—"
        }

        // Frame rate
        let fpsRaw = reportedValue([debug?.frameRate]) ?? ""
        let frameRate: String
        if !fpsRaw.isEmpty {
            frameRate = fpsRaw.contains("fps") ? fpsRaw : "\(fpsRaw) fps"
        } else {
            frameRate = "—"
        }

        // Dynamic Range & DV Profile
        let hdrRaw = reportedValue([
            debug?.hdr,
            debug?.dynamicRange
        ]) ?? ""
        let dvRaw = reportedValue([debug?.dv]) ?? ""
        let mpvDVProfile = mpv?.dolbyVisionProfile ?? 0
        let isDV = aether?.engine.sourceDVProfile != nil
            || (aether?.engine.sourceVideoFormat == .dolbyVision)
            || mpvDVProfile > 0
            || hdrRaw.localizedCaseInsensitiveContains("Dolby")
            || (!dvRaw.isEmpty && dvRaw.caseInsensitiveCompare("None") != .orderedSame)

        var dvProfile: String? = nil
        if let p = aether?.engine.sourceDVProfile, p > 0 {
            dvProfile = "\(p)"
        } else if mpvDVProfile > 0 {
            dvProfile = "\(mpvDVProfile)"
        } else if !dvRaw.isEmpty, dvRaw.caseInsensitiveCompare("None") != .orderedSame {
            let dvStr = dvRaw
            if dvStr.contains("5") { dvProfile = "5" }
            else if dvStr.contains("7") { dvProfile = "7" }
            else if dvStr.contains("8") { dvProfile = "8" }
            else if let firstDigit = dvStr.first(where: { $0.isNumber }) {
                dvProfile = String(firstDigit)
            }
        }

        let tvSupportsDV: Bool
        let tvSupportsHDR: Bool
        if #available(tvOS 11.0, *) {
            tvSupportsDV = AVPlayer.availableHDRModes.contains(.dolbyVision)
            tvSupportsHDR = AVPlayer.availableHDRModes.contains(.hdr10) || AVPlayer.availableHDRModes.contains(.hlg)
        } else {
            tvSupportsDV = false
            tvSupportsHDR = false
        }

        let engineOutputFormat = aether?.engine.videoFormat
        let dynamicRange: String
        if isDV {
            if engineOutputFormat == .hdr10 || (!tvSupportsDV && tvSupportsHDR) {
                dynamicRange = "Dolby Vision → HDR10"
            } else if engineOutputFormat == .sdr || (!tvSupportsDV && !tvSupportsHDR) {
                dynamicRange = "Dolby Vision → SDR"
            } else if debug?.dynamicRange.contains("→") == true {
                dynamicRange = "Dolby Vision → HDR10"
            } else if tvSupportsDV {
                dynamicRange = "Dolby Vision"
            } else {
                dynamicRange = "Dolby Vision → HDR10"
            }
        } else if hdrRaw.localizedCaseInsensitiveContains("HLG") {
            dynamicRange = "HLG"
        } else if hdrRaw.localizedCaseInsensitiveContains("HDR") || engineOutputFormat == .hdr10 {
            dynamicRange = "HDR10"
        } else if hdrRaw.localizedCaseInsensitiveContains("SDR") {
            dynamicRange = "SDR"
        } else if engineOutputFormat == .sdr {
            dynamicRange = "SDR"
        } else {
            dynamicRange = "—"
        }

        // Bitrate
        let vBitrateRaw = reportedValue([debug?.vBitrate]) ?? ""
        let videoBitrate: String
        if let match = vBitrateRaw.components(separatedBy: " · ").first(where: {
            ($0.contains("Mbit/s") || $0.contains("Mbps")) && !$0.contains("--")
        }) {
            let cleaned = match.replacingOccurrences(of: "avg mux ", with: "")
                               .replacingOccurrences(of: "now ", with: "")
                               .replacingOccurrences(of: "Mbit/s", with: "Mbps")
                               .trimmingCharacters(in: .whitespaces)
            videoBitrate = cleaned.isEmpty ? "—" : cleaned
        } else {
            videoBitrate = "—"
        }

        // Container
        let ext = reportedValue([debug?.fileExtension]) ?? ""
        let container: String
        let extLower = ext.lowercased()
        if extLower == "mkv" || extLower == "webm" {
            container = "matroska,webm"
        } else if extLower == "mp4" || extLower == "m4v" || extLower == "mov" {
            container = "quicktime,mov,mp4,m4a,3gp,3g2,mj2"
        } else if extLower == "m3u8" {
            container = "hls,applehttp"
        } else if !ext.isEmpty {
            container = extLower
        } else {
            container = "—"
        }

        // Video Decoder
        let decRaw = reportedValue([debug?.decoder]) ?? ""
        let videoDecoder: String
        if decRaw.localizedCaseInsensitiveContains("videotoolbox") {
            videoDecoder = "VideoToolbox \(videoCodec) (HW)"
        } else if !decRaw.isEmpty {
            videoDecoder = decRaw
        } else {
            videoDecoder = "—"
        }

        // Audio stream info
        let selectedAudio = audioTracks.first(where: { $0.isSelected }) ?? audioTracks.first
        let audioPresentation = Self.sceneAudioPresentation(
            debug: debug,
            legacyDetails: selectedAudio?.detail
        )
        let audioCodec = audioPresentation.codec
        let audioChannels = audioPresentation.channels

        // Language
        let lang = reportedValue([selectedAudio?.language])?.uppercased() ?? ""
        let audioLanguage = lang.isEmpty || lang == "UND" ? "—" : lang

        // Audio Bitrate
        let aBitRaw = reportedValue([debug?.aBitrate]) ?? ""
        let audioBitrate: String
        if !aBitRaw.isEmpty && aBitRaw != "--" {
            let cleaned = aBitRaw.replacingOccurrences(of: "meas ", with: "")
                                 .replacingOccurrences(of: "Mbit/s", with: "Mbps")
                                 .trimmingCharacters(in: .whitespaces)
            audioBitrate = cleaned.isEmpty ? "—" : cleaned
        } else {
            audioBitrate = "—"
        }

        let audioSpatialFormat = audioPresentation.spatialFormat
        let audioDecoder = audioPresentation.pipeline

        return ScenePlaybackInfo(
            engine: engineName,
            version: engineVer,
            videoCodec: videoCodec,
            resolution: resolution,
            frameRate: frameRate,
            dynamicRange: dynamicRange,
            dolbyVisionProfile: dvProfile,
            videoBitrate: videoBitrate,
            container: container,
            videoDecoder: videoDecoder,
            audioCodec: audioCodec,
            audioChannels: audioChannels,
            audioLanguage: audioLanguage,
            audioBitrate: audioBitrate,
            audioSpatialFormat: audioSpatialFormat,
            audioDecoder: audioDecoder,
            avSyncGapMs: Self.sceneAVSyncGap(debug: debug)
        )
    }

    static func sceneAudioPresentation(
        debug: PlaybackDebugInfo?,
        legacyDetails: String?
    ) -> (codec: String, channels: String, spatialFormat: String, pipeline: String) {
        func usable(_ candidate: String?) -> String? {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value.caseInsensitiveCompare("Unknown") != .orderedSame else { return nil }
            return value
        }

        let details = usable(legacyDetails) ?? usable(debug?.audio) ?? ""
        let structuredCodec = usable(debug?.audioSourceCodec)
        let codecUpper = (structuredCodec ?? details).uppercased()
        let codec: String
        if codecUpper.contains("TRUEHD") {
            codec = "TRUEHD"
        } else if codecUpper.contains("EAC3") || codecUpper.contains("E-AC-3") || codecUpper.contains("EC-3")
                    || codecUpper.contains("DDP") || codecUpper.contains("DOLBY DIGITAL PLUS") {
            codec = "E-AC-3"
        } else if codecUpper.contains("AC3") || codecUpper.contains("AC-3") || codecUpper.contains("DOLBY DIGITAL") {
            codec = "AC-3"
        } else if codecUpper.contains("DTS:X") {
            codec = "DTS:X"
        } else if codecUpper.contains("DTS-HD") {
            codec = "DTS-HD MA"
        } else if codecUpper.contains("DTS") {
            codec = "DTS"
        } else if codecUpper.contains("AAC") {
            codec = "AAC"
        } else if codecUpper.contains("FLAC") {
            codec = "FLAC"
        } else {
            codec = structuredCodec == nil || codecUpper.isEmpty ? "—" : codecUpper
        }

        let detailUpper = details.uppercased()
        let channels: String
        if let count = debug?.audioSourceChannels, count > 0 {
            switch count {
            case 1: channels = "Mono (1ch)"
            case 2: channels = "Stereo (2.0ch)"
            case 6: channels = "Surround (5.1ch)"
            case 8: channels = "Surround (7.1ch)"
            default: channels = "Surround (\(count)ch)"
            }
        } else if detailUpper.contains("8 CH") || detailUpper.contains("7.1") || detailUpper.contains("8CH") {
            channels = "Surround (7.1ch)"
        } else if detailUpper.contains("6 CH") || detailUpper.contains("5.1") || detailUpper.contains("6CH") {
            channels = "Surround (5.1ch)"
        } else if detailUpper.contains("2 CH") || detailUpper.contains("STEREO") || detailUpper.contains("2.0") {
            channels = "Stereo (2.0ch)"
        } else {
            channels = "—"
        }

        return (
            codec,
            channels,
            usable(debug?.audioSpatialFormat) ?? "Not confirmed",
            usable(debug?.audioPipeline) ?? "Unavailable"
        )
    }

    static func selectedScenePlaybackDebugInfo(
        activeEngineKind: PlayerEngineKind,
        aether: PlaybackDebugInfo?,
        mpv: PlaybackDebugInfo?
    ) -> PlaybackDebugInfo? {
        switch activeEngineKind {
        case .aether: return aether
        case .mpv: return mpv
        }
    }

    static func sceneAVSyncGap(debug: PlaybackDebugInfo?) -> Double? {
        guard let gap = debug?.avSyncGapMs, gap.isFinite else { return nil }
        return gap
    }

    func openScene() {
        guard isSceneEnabled else { return }
        cancelMoveSeekTracking()
        if isScrubbing {
            cancelScrub()
        }
        showScenePanel = true
        setControlsAutoHideSuspended(true)
        hideControls()
        
        let context = buildSceneContext()
        sceneAudioTapBroker.updateEngine(aetherController?.engine)
        sceneCoordinator.updateContext(context)
        if !availableExternalSubtitles.isEmpty {
            sceneCoordinator.updateAvailableSubtitles(availableExternalSubtitles)
        }
        let playbackInfo = buildScenePlaybackInfo()
        sceneViewModel.setMetadata(
            title: title,
            year: activeMeta?.year,
            overview: activeMeta?.description,
            runtime: activeMeta?.runtime,
            nextEpisode: nextEpisode,
            playbackInfo: playbackInfo
        )
        sceneViewModel.open()
    }
    
    func closeScene() {
        showScenePanel = false
        setControlsAutoHideSuspended(false)
        sceneViewModel.close()
    }
    
    func openSceneDetail(_ item: SceneDetailItem) {
        sceneViewModel.openDetail(item)
    }
    
    func closeSceneDetail() {
        sceneViewModel.closeDetail()
    }

    private func applyPendingResumeIfNeeded() {
        // The accepted room timeline owns Party startup; local history is not a user seek.
        guard watchPartyPlayerBridge == nil else { return }
        let minResumeThreshold = isTrailerPlaybackSession ? 0.5 : 5.0
        guard !didApplyResume,
              let pendingResumeSeconds,
              pendingResumeSeconds > minResumeThreshold,
              time.duration > 0 else {
            return
        }
        guard !loadedStreamLooksLikeReplacement() else { return }

        didApplyResume = true
        let target = isTrailerPlaybackSession
            ? min(pendingResumeSeconds, max(time.duration - 1, 0))
            : min(pendingResumeSeconds, max(time.duration - 5, 0))
        seek(to: target)
    }

    private func rememberManualSourceIfReady() {
        guard isTrackablePlayback,
              ProfileSettings.current.bool(forKey: SettingsKey.rememberLastSourceFocus),
              !didRememberManualSource, !isLiveStream, !isTrailerPlaybackSession,
              hasRenderedFirstFrame, !isAwaitingStreamStart,
              !isSwitchingSource, !isReloadingStream, !isFailingOver,
              !sessionCoordinator.isProgressSaveSuspended,
              !loadedStreamLooksLikeReplacement(), !didDetectReplacementStream,
              time.current.isFinite, time.current > 0,
              currentLoadPresentationIsConfirmed(
                engineKind: activeEngineKind, generation: sessionCoordinator.loadGeneration
              ),
              let profileID = manualSourceProfileID,
              Self.isCurrentPlaybackProfile(profileID),
              let meta = activeMeta, let sourceID = activeSourceID else { return }
        let numbers = resolvedEpisodeNumbers
        LastManualSourceStore.remember(
            sourceID: sourceID, profileID: profileID, metaID: meta.id, type: meta.type,
            season: numbers?.season, episode: numbers?.episode
        )
        didRememberManualSource = true
    }

    private func saveProgressIfNeeded() {
        guard isTrackablePlayback else { return }
        guard status == .playing else { return }
        rememberManualSourceIfReady()
        // Start a Trakt scrobble promptly so its remote Continue Watching feed
        // has an entry before the user leaves the player. Subsequent saves keep
        // the normal cadence (and Trakt's separate 30-second report cadence).
        let interval: TimeInterval = (usesTraktProgress || hasActiveScrobbleServices) && !didStartTraktScrobble ? 1 : 5
        guard Date().timeIntervalSince(lastProgressSave) >= interval else { return }
        saveProgress(force: false, isPeriodicHeartbeat: true)
    }

    func markWatchPartySharedSource() { usesWatchPartySharedSource = true }

    func saveProgress(
        force: Bool,
        eventAction: TraktScrobbleAction? = nil,
        isPeriodicHeartbeat: Bool = false
    ) {
        guard !isLiveStream else {
            print("[ContinueWatching][Player] saveProgress skipped: isLiveStream=true")
            return
        }
        guard isTrackablePlayback else { return }
        // Never persist progress during an Aether→MPV handoff.
        if sessionCoordinator.isProgressSaveSuspended {
            print("[ContinueWatching][Player] saveProgress skipped: sessionCoordinator.isProgressSaveSuspended=true")
            return
        }
        let playbackProfileID: String?
        if let tracker = sessionCoordinator.playbackCompletionTracker {
            playbackProfileID = tracker.profileID
        } else {
            playbackProfileID = WatchedStore.activeProfileId
        }
        guard Self.isCurrentPlaybackProfile(playbackProfileID) else { return }

        let checkpointTime = explicitSeekProgressCheckpoint.flatMap { checkpoint in
            Date().timeIntervalSince(checkpoint.createdAt) < Self.explicitSeekSettleWindow
                ? checkpoint.time
                : nil
        }
        let progressTime = checkpointTime ?? lastStablePlaybackTime ?? time
        let store = ProfileSettings.current
        let usesRemoteProgress = usesTraktProgress
        let shouldSaveNuvioSyncProgress = RemoteTrackingState.shouldSaveNuvioSyncPlayback(
            usesRemoteProgress: usesRemoteProgress,
            in: store
        )
        if isPeriodicHeartbeat, !force {
            if let lastSavedProgressPosition,
               abs(progressTime.current - lastSavedProgressPosition) < 2.0 {
                return
            }
        }
        // Nuvio Sync retains the 10-second accidental-playback safeguard. A
        // Trakt start scrobble is the source of its Continue Watching row, so
        // send it once playback has genuinely begun instead of waiting 10+ s.
        let minimumProgressSeconds: Double = (usesRemoteProgress || hasActiveScrobbleServices) ? 1 : WatchProgressLedger.minimumTrackableSeconds
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
            if !isPeriodicHeartbeat || progressTime.current >= minimumProgressSeconds {
                print("[ContinueWatching][Player] saveProgress guard failed: meta=\(activeMeta?.id ?? "nil"), streamURL=\(activeStreamURL != nil), pos=\(progressTime.current), dur=\(progressTime.duration), trackable=\(isTrackablePlayback), isReplacement=\(loadedStreamLooksLikeReplacement()), didDetectReplacement=\(didDetectReplacementStream), awaitingStreamStart=\(isAwaitingStreamStart), didApplyResume=\(didApplyResume), minSec=\(minimumProgressSeconds), force=\(force)")
            }
            return
        }

        let epString = resolvedEpisodeNumbers.map { "S\($0.season)E\($0.episode)" } ?? "movie"
        #if DEBUG
        print("[ContinueWatching][Player] saveProgress executing: meta=\(activeMeta.id) (\(activeMeta.name)), ep=\(epString), pos=\(progressTime.current)/\(progressTime.duration) (\(String(format: "%.1f", (progressTime.current / progressTime.duration) * 100))%), force=\(force), heartbeat=\(isPeriodicHeartbeat), usesTraktProgress=\(usesRemoteProgress)")
        #endif

        if !hasClearedDismissalsForCurrentPlaybackSession {
            hasClearedDismissalsForCurrentPlaybackSession = true
            ContinueWatchingDismissStore.clear(contentId: activeMeta.id)
        }

        if shouldSaveNextUpProgress(at: progressTime), let nextEpisode {
            #if DEBUG
            print("[ContinueWatching][Player] shouldSaveNextUpProgress triggered for nextEpisode: S\(nextEpisode.season)E\(nextEpisode.episode)")
            #endif
            markWatchedIfNeeded()
            LastPlaybackStreamStore.remove(
                metaId: activeMeta.id,
                season: resolvedEpisodeNumbers?.season,
                episode: resolvedEpisodeNumbers?.episode,
                profileId: WatchedStore.activeProfileId
            )
            if shouldSaveNuvioSyncProgress {
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
        #if DEBUG
        print("[ContinueWatching][Player] completesPlayback=\(completesPlayback) (ep=\(epString))")
        #endif
        if !completesPlayback && !usesWatchPartySharedSource {
            LastPlaybackStreamStore.save(
                metaId: activeMeta.id,
                url: activeStreamURL,
                httpHeaders: activeHTTPHeaders,
                season: season,
                episode: episode,
                profileId: WatchedStore.activeProfileId
            )
        } else if completesPlayback {
            LastPlaybackStreamStore.remove(
                metaId: activeMeta.id,
                season: season,
                episode: episode,
                profileId: WatchedStore.activeProfileId
            )
        }
        if shouldSaveNuvioSyncProgress {
            if completesPlayback {
                // Record completion, not the raw position. An ending marker fires
                // during the credits — well before the 90% the ledger needs to call
                // an episode finished — so saving the literal position left the row
                // as resume progress ("8m left") that could never seed the following
                // episode, while the title was simultaneously marked watched.
                #if DEBUG
                print("[ContinueWatching][Player] completing playback -> ContinueWatchingStore.markPlaybackCompleted (meta: \(activeMeta.id), S\(season.map(String.init) ?? "nil")E\(episode.map(String.init) ?? "nil"))")
                #endif
                ContinueWatchingStore.markPlaybackCompleted(
                    meta: activeMeta,
                    duration: progressTime.duration,
                    season: season,
                    episode: episode
                )
                if let nextEpisode {
                    #if DEBUG
                    print("[ContinueWatching][Player] saving Up Next card for nextEpisode: S\(nextEpisode.season)E\(nextEpisode.episode)")
                    #endif
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
                #if DEBUG
                print("[ContinueWatching][Player] saving active progress -> ContinueWatchingStore.save (meta: \(activeMeta.id), pos: \(progressTime.current)/\(progressTime.duration), S\(season.map(String.init) ?? "nil")E\(episode.map(String.init) ?? "nil"))")
                #endif
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
        }

        if usesRemoteProgress {
            if completesPlayback {
                markWatchedIfNeeded()
            } else {
                print("[ContinueWatching][Player] routing progress to provider: action=\(eventAction.map { "\($0)" } ?? "update")")
                reportTraktProgress(
                    meta: activeMeta,
                    playbackTime: progressTime,
                    action: eventAction,
                    force: force,
                    isPeriodicHeartbeat: isPeriodicHeartbeat
                )
            }
        } else if !completesPlayback && hasActiveScrobbleServices {
            print("[ContinueWatching][Player] routing background scrobble to active services (NuvioSync resume)")
            reportTraktProgress(
                meta: activeMeta,
                playbackTime: progressTime,
                action: eventAction,
                force: force,
                isPeriodicHeartbeat: isPeriodicHeartbeat
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
        let store = ProfileSettings.current
        let source = sessionCoordinator.playbackCompletionTracker?.source
            ?? TraktSettingsStore.watchProgressSource(in: store)
        return source != .nuvioSync && RemoteTrackingState.isProgressSourceAuthenticated(source, in: store)
    }

    private var hasActiveScrobbleServices: Bool {
        let store = ProfileSettings.current
        return !RemoteTrackingState.activeScrobbleSources(in: store).isEmpty
    }

    static func shouldReportPlaybackProgress(
        afterCompletionWasRecorded wasRecorded: Bool,
        source: TraktWatchProgressSource
    ) -> Bool {
        !(wasRecorded && (source == .trakt || source == .wetrakr))
    }

    static func scrobbleReportPolicy(
        action: TraktScrobbleAction?,
        primarySource: TraktWatchProgressSource,
        didStartTraktScrobble: Bool,
        isPeriodicHeartbeat: Bool
    ) -> (action: TraktScrobbleAction, isPeriodicHeartbeat: Bool) {
        let effectiveHeartbeat = isPeriodicHeartbeat && action == nil && didStartTraktScrobble
        let effectiveAction: TraktScrobbleAction
        if (primarySource == .trakt || primarySource == .wetrakr), action == .stop {
            effectiveAction = .pause
        } else {
            effectiveAction = action ?? .start
        }
        return (effectiveAction, effectiveHeartbeat)
    }

    /// Trailers use the movie's metadata for artwork and playback, but are not
    /// playback of that movie. Keep the marker check as a compatibility
    /// fallback while the session flag protects against subtitle changes.
    static func shouldTrackPlayback(
        subtitle: String,
        isTrailerSession: Bool,
        isActionSession: Bool = false
    ) -> Bool {
        !isTrailerSession && !isActionSession && subtitle != PlaybackMarkers.trailerSubtitle
    }

    private var isTrackablePlayback: Bool {
        Self.shouldTrackPlayback(
            subtitle: subtitle,
            isTrailerSession: isTrailerPlaybackSession,
            isActionSession: isActionPlaybackSession
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

        let store = ProfileSettings.current
        let tracker = sessionCoordinator.playbackCompletionTracker
        let primarySource = tracker?.source ?? TraktSettingsStore.watchProgressSource(in: store)
        let profileID = tracker?.profileID ?? WatchedStore.activeProfileId
        guard ProfileSettings.isActiveStore(store),
              Self.isCurrentPlaybackProfile(profileID) else { return }

        let activeSources = RemoteTrackingState.activeScrobbleSources(in: store)
        guard !activeSources.isEmpty else { return }

        guard Self.shouldReportPlaybackProgress(
            afterCompletionWasRecorded: tracker?.wasRecorded == true,
            source: primarySource
        ) else { return }

        let playbackID = tracker?.completionID
        let episodeNumbers = resolvedEpisodeNumbers

        TraktProgressService.recordLocalPlaybackForScrobbleSources(
            meta: meta,
            position: playbackTime.current,
            duration: playbackTime.duration,
            season: episodeNumbers?.season,
            episode: episodeNumbers?.episode,
            primarySource: primarySource,
            scrobbleSources: activeSources,
            notify: force && primarySource != .nuvioSync
        )

        if activeSources == [.simkl],
           didStartTraktScrobble,
           action == nil,
           isPeriodicHeartbeat,
           !force {
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastTraktProgressReport) >= Self.traktProgressReportInterval else {
            return
        }

        let reportPolicy = Self.scrobbleReportPolicy(
            action: action,
            primarySource: primarySource,
            didStartTraktScrobble: didStartTraktScrobble,
            isPeriodicHeartbeat: isPeriodicHeartbeat
        )
        didStartTraktScrobble = true
        lastTraktProgressReport = now

        let expectedAccountID = tracker?.completionAccounts?[TraktWatchProgressSource.trakt.rawValue]
            ?? tracker?.completionAccounts?[primarySource.rawValue]

        let previousTask = traktProgressTask
        traktProgressTask = Task {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            guard ProfileSettings.isActiveStore(store),
                  Self.isCurrentPlaybackProfile(profileID) else { return }
            _ = await TraktProgressService.reportPlayback(
                meta: meta,
                position: playbackTime.current,
                duration: playbackTime.duration,
                season: episodeNumbers?.season,
                episode: episodeNumbers?.episode,
                action: reportPolicy.action,
                store: store,
                sourceOverride: nil,
                expectedAccountID: expectedAccountID,
                playbackID: playbackID,
                profileId: profileID,
                isPeriodicHeartbeat: reportPolicy.isPeriodicHeartbeat
            )
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
            print("[ContinueWatching][Player] shouldMarkAsWatched=true due to ending skip interval at \(ending.startTime)s")
            return true
        }
        let completionThreshold = TraktSettingsStore.watchProgressSource == .mdblist
            ? MdbListProgressService.completionPercent / 100
            : WatchProgressLedger.completionFraction
        let isOverThreshold = playbackTime.current / playbackTime.duration >= completionThreshold
        if isOverThreshold {
            print("[ContinueWatching][Player] shouldMarkAsWatched=true: progress (\(String(format: "%.1f", (playbackTime.current / playbackTime.duration) * 100))%) >= threshold (\(String(format: "%.1f", completionThreshold * 100))%)")
        }
        return isOverThreshold
    }

    func observePlaybackCompletionEligibility(
        at sample: PlayerTime,
        isCoherent: Bool,
        isGenuinelyPlaying: Bool,
        isBelowCompletionBoundary: Bool
    ) {
        guard isTrackablePlayback else { return }
        let resumeTargetReached: Bool
        if let resumeTarget = sessionCoordinator.playbackCompletionTracker?.resumeTargetSeconds {
            let target = min(resumeTarget, max(sample.duration - 5, 0))
            resumeTargetReached = sample.current >= max(target - 2, 0)
        } else {
            resumeTargetReached = true
        }

        sessionCoordinator.observePlaybackCompletionSample(
            isCoherent: isCoherent,
            isGenuinelyPlaying: isGenuinelyPlaying,
            isBelowCompletionBoundary: isBelowCompletionBoundary,
            hasReachedResumeTarget: resumeTargetReached
        )
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

    private func playbackCompletionIdentity(for meta: NuvioMeta) -> PlaybackCompletionIdentity {
        let numbers = resolvedEpisodeNumbers
        return PlaybackCompletionIdentity(
            titleID: meta.id,
            contentType: meta.isSeries ? "series" : meta.type.lowercased(),
            season: numbers?.season,
            episode: numbers?.episode,
            episodeID: numbers == nil ? currentEpisodeVideo?.id : nil
        )
    }

    private func capturePlaybackCompletionContext(profileID: String?) -> (
        source: TraktWatchProgressSource,
        accountIDs: [String: String]
    ) {
        let store = ProfileSettings.current
        let source = TraktSettingsStore.watchProgressSource(in: store)
        var accountIDs: [String: String] = [:]

        if source == .trakt || RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store) || RemoteTrackingState.shouldMirrorWatchedHistoryToTrakt(in: store),
           let accountID = TraktHistoryService.completionAccountID(in: store, profileId: profileID) {
            accountIDs[TraktWatchProgressSource.trakt.rawValue] = accountID
        }
        if source == .wetrakr || RemoteTrackingState.isScrobbleEnabled(for: .wetrakr, in: store),
           let accountID = WeTrakrProgressService.completionAccountID(in: store, profileId: profileID) {
            accountIDs[TraktWatchProgressSource.wetrakr.rawValue] = accountID
        }
        return (source, accountIDs)
    }

    /// Finalizes the durable completion after any queued progress report for
    /// this player. The captured provider/account stay bound to the play even
    /// if the user changes tracking settings or links another account before
    /// the network request runs.
    private func finishPlaybackCompletion(
        meta: NuvioMeta,
        playbackTime: PlayerTime,
        season: Int?,
        episode: Int?,
        completionID: String,
        tracker: PlaybackCompletionTracker
    ) {
        let profileID = tracker.profileID
        guard !isLiveStream,
              tracker.completionID == completionID,
              Self.isCurrentPlaybackProfile(profileID),
              ProfileSettings.isActiveStore(ProfileSettings.current) else { return }

        let store = ProfileSettings.current
        let source = tracker.source ?? TraktSettingsStore.watchProgressSource(in: store)
        let expectedAccountID = tracker.completionAccounts?[source.rawValue]
        let traktMirrorAccountID = source == .trakt
            ? nil
            : tracker.completionAccounts?[TraktWatchProgressSource.trakt.rawValue]
        let previousTask = traktProgressTask
        traktProgressTask = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled,
                  ProfileSettings.isActiveStore(store),
                  Self.isCurrentPlaybackProfile(profileID) else { return }

            let succeeded = await TraktProgressService.finishPlaybackForHistory(
                meta: meta,
                position: playbackTime.current,
                duration: playbackTime.duration,
                season: season,
                episode: episode,
                store: store,
                profileId: profileID,
                completionID: completionID,
                source: source,
                expectedAccountID: expectedAccountID,
                traktMirrorAccountID: traktMirrorAccountID
            )
            guard ProfileSettings.isActiveStore(store),
                  Self.isCurrentPlaybackProfile(profileID) else { return }
            if !succeeded {
                print("[ContinueWatching][Player] completion finalization deferred for \(meta.id) (\(source.rawValue))")
            }
        }
    }

    /// Records one completed playback per logical play. The coordinator-owned
    /// completion ID survives source retries and PiP adoption, while a rewatch
    /// must have played below the completion boundary before it can increment.
    private func markWatchedIfNeeded() {
        guard isTrackablePlayback else { return }
        guard let activeMeta else { return }
        let numbers = resolvedEpisodeNumbers
        let season = numbers?.season
        let episode = numbers?.episode
        // Series without resolved S/E must not write a whole-title mark —
        // that would checkmark the poster but never the episode card.
        if activeMeta.isSeries && (season == nil || episode == nil) {
            print("[ContinueWatching][Player] markWatchedIfNeeded: series without S/E numbers, skipping whole-title mark")
            return
        }
        let identity = playbackCompletionIdentity(for: activeMeta)
        let profileID = WatchedStore.activeProfileId
        guard let tracker = sessionCoordinator.playbackCompletionTracker,
              tracker.profileID == profileID,
              Self.isCurrentPlaybackProfile(profileID),
              ProfileSettings.isActiveStore(ProfileSettings.current) else {
            print("[ContinueWatching][Player] markWatchedIfNeeded: profile changed during playback; skipping completion")
            return
        }
        let watchCount: Int
        if let season, let episode {
            watchCount = WatchedStore.episodeWatchCount(meta: activeMeta, season: season, episode: episode)
        } else {
            watchCount = WatchedStore.watchCount(meta: activeMeta)
        }
        guard let completionID = sessionCoordinator.playbackCompletionIDForRecording(
            identity: identity,
            currentProfileID: profileID,
            isAlreadyWatched: watchCount > 0
        ) else {
            return
        }
        let accepted = WatchedStore.recordPlaybackCompletion(
            activeMeta,
            season: season,
            episode: episode,
            completionID: completionID,
            source: tracker.source,
            completionAccounts: tracker.completionAccounts
        )
        guard accepted else { return }
        sessionCoordinator.markPlaybackCompletionRecorded(completionID: completionID)
        finishPlaybackCompletion(
            meta: activeMeta,
            playbackTime: time,
            season: season,
            episode: episode,
            completionID: completionID,
            tracker: tracker
        )
        print("[ContinueWatching][Player] markWatchedIfNeeded: recorded completion for \(activeMeta.id) S\(season.map(String.init) ?? "nil")E\(episode.map(String.init) ?? "nil")")
    }

    private static func isCurrentPlaybackProfile(_ profileID: String?) -> Bool {
        WatchedStore.activeProfileId == profileID
            && ProfileSettings.activeProfileID == profileID
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
    static func streamLooksLikeReplacement(
        loadedDuration: Double,
        pendingResumeSeconds: Double?,
        expectedDurationSeconds: Double?,
        isStandalonePlaybackSession: Bool,
        isLiveStream: Bool
    ) -> Bool {
        guard !isStandalonePlaybackSession, loadedDuration > 0 else { return false }
        if let resume = pendingResumeSeconds, resume > loadedDuration + 60 {
            return true
        }
        if let expected = expectedDurationSeconds, expected >= 60, loadedDuration < expected * 0.5 {
            return true
        }
        return !isLiveStream && loadedDuration < 180
    }

    private func loadedStreamLooksLikeReplacement() -> Bool {
        Self.streamLooksLikeReplacement(
            loadedDuration: time.duration,
            pendingResumeSeconds: pendingResumeSeconds,
            expectedDurationSeconds: expectedDurationSeconds,
            isStandalonePlaybackSession: isStandalonePlaybackSession,
            isLiveStream: isLiveStream
        )
    }

    /// Confirms — with a short debounce so a transient duration read can't trip
    /// it — that the loaded file is a replacement/expired-link slate, then
    /// pauses and surfaces an error. Returns true once handled so the caller
    /// skips all progress bookkeeping. Idempotent after the first detection.
    private func detectReplacementStream(_ c: PlaybackEngineControlling) -> Bool {
        guard !isStandalonePlaybackSession else { return false }
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
        hasProducedMidFilePosition = false
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
        guard watchPartyPlayerBridge == nil || aetherController?.canUseWatchPartySoftwarePiP == true else {
            showPlayerToast("Picture in Picture is unavailable for this Watch Party source")
            return
        }
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
