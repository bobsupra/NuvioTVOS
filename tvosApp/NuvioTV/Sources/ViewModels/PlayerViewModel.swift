import Foundation
import Combine
import SwiftUI
import UIKit
import AVFoundation
import AVKit
import CoreMedia
import GameController
import Libmpv

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

// MARK: - PlayerViewModel (dual-engine)
//
// Default backend is libmpv (gpu-next / VideoToolbox) so Stremio/debrid streams
// — MKV, AC3/EAC3/DTS, HEVC/AV1 — play on tvOS. AVPlayer is used when Settings
// force it, or after Auto has packet-remuxed Dolby Vision into local fMP4 HLS
// so the TV can engage true Dolby Vision mode. MPV stays alive as the immediate
// HDR10/PQ fallback if the native pipeline cannot display the remux.

@MainActor
class PlayerViewModel: ObservableObject {
    @Published var status: PlayerStatus = .idle
    @Published var time: PlayerTime = PlayerTime()
    /// High-frequency time/scrub state for HUDs. Mirrors `time` on each tick.
    let clock = PlaybackClock()
    @Published var subtitles: [SubtitleTrack] = []
    @Published var audioTracks: [AudioTrack] = []
    @Published var playbackSpeed: PlaybackSpeed = .normal
    @Published var seekStepSeconds: Int = PlayerSeekSettings.current
    @Published var qualities: [QualityOption] = [.auto]
    @Published var currentQuality: QualityOption = .auto
    @Published var showControls: Bool = true
    /// True while the transport controls are up and the timeline scrubber holds
    /// focus. Lets the remote press-catcher drive continuous hold-to-seek even
    /// with the controls visible, matching the controls-hidden behaviour.
    /// @Published so the catcher re-asserts first responder when it flips.
    @Published var isTimelineFocused: Bool = false
    /// Infuse-style scrub mode (touchpad drag / D-pad jump / wheel fine-tune).
    @Published private(set) var isScrubbing = false
    /// Accumulated D-pad skip preview (seconds). Zero when idle.
    @Published var pendingSeekDelta: Double = 0
    /// Light-tap peek timeline (no full controls).
    @Published private(set) var peekVisible = false
    /// True while the finger is at the trackpad edge for wheel fine-tune.
    @Published private(set) var wheelEngaged = false
    @Published var title: String = ""
    @Published var subtitle: String = ""
    /// Every external subtitle the stream offered (all languages), browsable in
    /// the player's subtitle panel and loaded into mpv on demand.
    @Published var availableExternalSubtitles: [NuvioSubtitle] = []
    /// True while installed subtitle add-ons are still returning results.
    @Published var isLoadingExternalSubtitles: Bool = false
    /// Current mpv `sub-delay`, in milliseconds. Per-session, not persisted.
    @Published var subtitleDelayMs: Int = 0
    /// Current mpv `audio-delay`, in milliseconds. Per-session, not persisted.
    @Published var audioDelayMs: Int = 0
    /// PCM amplification in whole dB (0…10), applied as mpv software volume.
    /// Per-session, not persisted.
    @Published var audioAmplificationDb: Int = 0
    /// Full-screen settings panel (subtitles / audio / speed) visibility.
    @Published var showSettingsPanel: Bool = false
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

    // MARK: Next-episode auto-play

    /// The episode that will play after this one, if any. Drives the Next
    /// Episode card; nil for movies, trailers, or the last episode.
    @Published var nextEpisode: NuvioVideo?
    /// Whether the Next Episode card is visible (near the end of an episode
    /// that has a follow-up).
    @Published var showNextEpisodeCard: Bool = false
    /// Seconds left on the auto-play countdown, or nil when there is no active
    /// countdown (auto-play off, cancelled by a fast-forward, or not started).
    @Published var nextEpisodeCountdown: Int?
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
    /// Master toggle from Settings → "Auto-Play Next Episode".
    private var autoPlayNextEnabled: Bool = true
    /// Set when the user fast-forwards with the card up: they may be watching
    /// credits or a post-credit scene, so the countdown is cancelled (the card
    /// stays for a manual Play). Reset on each new episode.
    private var autoAdvanceDisabled: Bool = false
    private var isAdvanceInFlight: Bool = false
    /// Wall-clock moment the auto-advance fires, set when the card first arms so
    /// the countdown is a fixed 10s from the card appearing (skips the credits)
    /// rather than tracking the video's final seconds.
    private var autoAdvanceDeadline: Date?
    /// Fallback when IntroDB has no ending marker: show the Next Episode card
    /// this many seconds before the end. When an ending skip exists, the card
    /// arms at the same moment as Skip Ending instead.
    private static let nextCardLeadSeconds: Double = 120
    private static let autoCountdownSeconds = 10
    /// Same lead-in used by skip-segment detection so both cards arm together.
    private static let skipSegmentStartLead: Double = 0.35

    /// libmpv Metal host. PlayerView shows this when `activeEngineKind == .mpv`.
    let playerController = MPVPlayerViewController()
    /// AVFoundation host for native Dolby Vision (and forced AVPlayer setting).
    let avPlayerController = AVPlayerEngineController()
    /// Which backend is driving the current (or next) stream.
    @Published private(set) var activeEngineKind: PlayerEngineKind = .mpv
    /// Short on-screen note after engine selection (native DV vs HDR fallback).
    @Published private(set) var hdrModeToast: String?
    @Published private(set) var isUsingNativeDolbyVision = false

    private var nativeDVRemuxAllowed = false
    private var nativeDVRemuxAttempted = false
    private var nativeDVRemuxer: DolbyVisionRemuxer?
    private var retiredNativeDVRemuxers: [DolbyVisionRemuxer] = []
    private var nativeDVFailedURLs: Set<String> = []
    private var nativeDVPlaylistURL: String?
    private var nativeDVStartOffset: Double = 0
    private var nativeDVWrittenSeconds: Double = 0
    private var nativeDVOriginalDuration: Double = 0
    private var nativeDVRemuxFinished = false
    private var nativeDVDeferredSourceError: String?
    private var nativeDVSourceErrorDeadline: Date?

    /// Backend used for transport / poll — switches with `activeEngineKind`.
    private var engine: PlaybackEngineControlling {
        activeEngineKind == .avPlayer ? avPlayerController : playerController
    }

    private var pollTimer: Timer?
    private var controlsHideTimer: Timer?
    private var hasLoaded = false
    private var didShutdown = false
    private var activeMeta: NuvioMeta?
    private var activeStreamURL: String?
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
    private var didApplySavedAudioSelection = false
    private var didApplySavedSubtitleSelection = false
    private var didApplyAudioPreference = false
    private var didApplySubtitlePreference = false
    /// Progressive subtitle fetches may improve an automatic match, but must
    /// never replace a subtitle (including Off) explicitly chosen in the panel.
    private var hasExplicitSubtitleSelection = false
    private var lastProgressSave = Date.distantPast
    /// Last coherent, non-EOF MPV sample. Forced lifecycle saves use this
    /// instead of a transient reattach/keep-open sample that can report the
    /// title's full duration as its current position.
    private var lastStablePlaybackTime: PlayerTime?
    private var controlsAutoHideSuspended = false
    private var skipIntervals: [SkipInterval] = []
    private var autoHiddenSkipIntervalId: String?
    private var skipSegmentAutoHideDeadline: Date?
    private var skipIntervalLoadTask: Task<Void, Never>?
    private static let skipSegmentAutoHideSeconds = 5
    private var seekRepeatTimer: Timer?
    /// Hold-to-seek tick rate — faster than a casual tap cadence so a held
    /// direction ramps at least as quickly as rapid tapping.
    private static let seekRepeatInterval: TimeInterval = 0.11

    // MARK: Scrub / seek accumulation

    /// Coarse D-pad jump while scrubbing (seconds). Pan zooms, presses hop.
    private var scrubJumpSeconds: Double { max(Double(seekStepSeconds) * 4, 60) }
    private var scrubValue: Double?
    private var lastScrubPublish = Date.distantPast
    private var scrubTimeoutTask: Task<Void, Never>?
    private var scrubLastDx: CGFloat = 0
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

    /// Best estimate of the real title's length, captured at load time from the
    /// existing Continue Watching entry (most reliable) or the metadata runtime.
    /// Used to recognize an expired-link "slate" the stream host plays in place
    /// of the movie — see `loadedStreamLooksLikeReplacement()`.
    private var expectedDurationSeconds: Double?
    private let trailerResolver = YouTubeTrailerResolver()
    private var trailerResolveTask: Task<Void, Never>?
    private var didDetectReplacementStream = false
    private var replacementStreamHits = 0
    private static let replacementConfirmTicks = 4   // ~1s at the 0.25s poll cadence

    /// Re-resolves a fresh stream for the current title/episode when a link
    /// expires or a source fails. `excludedURLs` are links already tried this
    /// session so failover never loops a dead source. Nil disables recovery.
    var reloadCurrentStream: ((_ excludedURLs: [String]) async -> PreparedNextStream?)?
    /// Lists playable sources for a content id (Sources panel).
    var fetchPlaybackSources: ((_ contentId: String, _ type: String) async -> [NuvioStream])?
    /// Resolves a user-picked source into a ready stream (debrid + URL).
    var resolvePlaybackStream: ((
        _ stream: NuvioStream,
        _ contentId: String,
        _ subtitleLine: String
    ) async -> PreparedNextStream?)?
    private var reloadAttempts = 0
    private var isReloadingStream = false
    private static let maxReloadAttempts = 5

    // MARK: Load watchdog + source failover

    /// True while a mid-session source switch is resolving/loading.
    @Published private(set) var isSwitchingSource = false
    /// Brief on-screen notice ("Source failed — trying another").
    @Published var playerToast: String?
    /// URLs that failed to load/play this session (watchdog, mpv error, slate).
    private var failedStreamURLs: Set<String> = []
    private var currentLoadStarted = false
    private var loadWatchdogTask: Task<Void, Never>?
    private var isFailingOver = false
    private var toastClearTask: Task<Void, Never>?
    /// A source that hasn't started within this long is treated as dead.
    private let loadTimeoutSeconds: UInt64 = 30

    init() {
        let suspend: (Int64, Int64) -> Void = { [weak self] positionMs, durationMs in
            Task { @MainActor [weak self] in
                self?.playbackDidSuspend(positionMs: positionMs, durationMs: durationMs)
            }
        }
        playerController.onPlaybackSuspended = suspend
        avPlayerController.onPlaybackSuspended = suspend
        avPlayerController.onNativeVideoUnavailable = { [weak self] urlString, reason in
            self?.fallBackToMPV(urlString: urlString, reason: reason)
        }
        avPlayerController.onVideoReady = { [weak self] urlString in
            self?.nativeDolbyVisionVideoDidBecomeReady(urlString: urlString)
        }
    }

    deinit {
        let mpv = playerController
        let av = avPlayerController
        let poll = pollTimer
        let hide = controlsHideTimer
        let remuxers = retiredNativeDVRemuxers + [nativeDVRemuxer].compactMap { $0 }
        remuxers.forEach { $0.cancel() }
        trailerResolveTask?.cancel()
        subtitleFetchTask?.cancel()
        Task { @MainActor in
            poll?.invalidate()
            hide?.invalidate()
            mpv.destroyPlayer()
            av.destroyPlayer()
            remuxers.forEach { $0.cleanup() }
        }
    }

    func load(url: URL, meta: NuvioMeta, subtitle: String, externalSubtitles: [NuvioSubtitle] = [], resumeFrom: Double?) {
        let isTrailerPlayback = subtitle == PlaybackMarkers.trailerSubtitle
        applyStreamState(url: url, meta: meta, subtitle: subtitle, externalSubtitles: externalSubtitles, resumeFrom: resumeFrom)
        guard !hasLoaded else { return }
        hasLoaded = true

        if isTrailerPlayback, let youtubeId = Self.youtubeVideoId(from: url) {
            let title = meta.name
            let year = meta.year.map(String.init)
            let resolver = trailerResolver

            trailerResolveTask?.cancel()
            trailerResolveTask = Task { [weak self] in
                let resolvedUrl = await resolver.resolve(
                    youtubeVideoId: youtubeId,
                    title: title,
                    year: year
                )

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self else { return }
                    guard let playbackSource = resolvedUrl else {
                        self.status = .error("No 1080p trailer stream was found for this title.")
                        return
                    }
                    self.activeStreamURL = playbackSource.videoUrl
                    // Trailers are ordinary progressive streams — keep MPV for
                    // dual audio-url support.
                    self.selectEngine(.mpv, decisionMessage: nil)
                    self.engine.loadFile(playbackSource.videoUrl)
                    if let audioUrl = playbackSource.audioUrl {
                        self.engine.addAudioUrl(audioUrl)
                    }
                    self.startPolling()
                }
            }
            return
        }

        applyEnginePolicy(
            for: url,
            streamName: nil,
            streamDescription: subtitle,
            // Debrid URLs often encode the release name in the path.
            filename: url.lastPathComponent
        )
        engine.loadFile(url.absoluteString)
        // mpv letterboxes; fill/stretch are SwiftUI transforms on the host.
        engine.setAspectMode(.fit)
        videoNaturalSize = .zero
        startPolling()
        configureWheelTrackingIfNeeded()
        startLoadWatchdog()
    }

    /// Picks MPV vs AVPlayer from Settings + Dolby Vision policy.
    private func applyEnginePolicy(
        for url: URL,
        streamName: String?,
        streamDescription: String?,
        filename: String?
    ) {
        let result = DolbyVisionPlaybackPolicy.resolve(
            url: url,
            streamName: streamName,
            streamDescription: streamDescription,
            filename: filename
        )
        let engineSetting = ProfileSettings.current
            .string(forKey: SettingsKey.playerEngine) ?? "Auto"
        let normalizedSetting = engineSetting
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isAuto = normalizedSetting != "avplayer"
            && normalizedSetting != "mpvkit"
            && normalizedSetting != "mpv"
        nativeDVRemuxAllowed = isAuto && result.decision != .mpvHdrFallback
        print("[Player] Engine policy: \(result.reason)")
        selectEngine(result.engine, decisionMessage: DolbyVisionPlaybackPolicy.statusMessage(for: result))
    }

    private func selectEngine(_ kind: PlayerEngineKind, decisionMessage: String?) {
        if activeEngineKind != kind {
            // Pause the outgoing backend so two audio pipelines never run together.
            switch activeEngineKind {
            case .mpv: playerController.pausePlayback()
            case .avPlayer: avPlayerController.pausePlayback()
            }
        }
        activeEngineKind = kind
        if let decisionMessage {
            hdrModeToast = decisionMessage
            showPlayerToast(decisionMessage)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self?.hdrModeToast == decisionMessage {
                    self?.hdrModeToast = nil
                }
            }
        } else {
            hdrModeToast = nil
        }
    }

    /// AVPlayer may successfully open the container and audio track while the
    /// Dolby Vision video track remains black. Retry that same source through
    /// MPV so its HDR10/PQ-compatible base layer remains watchable.
    private func fallBackToMPV(urlString: String, reason: String) {
        if isUsingNativeDolbyVision, urlString == nativeDVPlaylistURL {
            abandonNativeDolbyVision(reason: reason)
            return
        }

        guard !didShutdown,
              activeEngineKind == .avPlayer,
              activeStreamURL == urlString else { return }

        let avPosition = Double(avPlayerController.positionMs) / 1000.0
        let resume = max(avPosition, time.current)
        if resume > 5 {
            pendingResumeSeconds = resume
            didApplyResume = false
        }

        print("[Player] AVPlayer fallback: \(reason)")
        status = .buffering
        didAddExternalSubtitles = false
        addedExternalSubtitleURLs.removeAll()
        selectEngine(.mpv, decisionMessage: "Dolby Vision → HDR10/PQ (MPV fallback)")
        playerController.loadFile(urlString)
        playerController.setAspectMode(.fit)
        videoNaturalSize = .zero
        startLoadWatchdog()
    }

    /// MPV identifies the actual Dolby Vision profile after probing. For P5/P8,
    /// keep MPV playing while a packet-only local HLS remux is prepared.
    private func maybeStartNativeDolbyVisionRemux() {
        guard nativeDVRemuxAllowed,
              !nativeDVRemuxAttempted,
              !isUsingNativeDolbyVision,
              activeEngineKind == .mpv,
              currentLoadStarted,
              playerController.hasCoherentTimeSample,
              !playerController.isPlayerLoading,
              let sourceURL = activeStreamURL,
              !nativeDVFailedURLs.contains(sourceURL),
              URL(string: sourceURL)?.isFileURL != true else { return }
        let bufferedAheadMs = playerController.bufferedMs - playerController.positionMs
        guard bufferedAheadMs >= 2_000 || playerController.positionMs >= 5_000 else { return }
        if let pendingResumeSeconds,
           pendingResumeSeconds > 5,
           abs(time.current - pendingResumeSeconds) > 5 {
            return
        }

        let profile = playerController.dolbyVisionProfile
        guard profile > 0 else { return }
        nativeDVRemuxAttempted = true

        guard profile == 5 || profile == 8 else {
            print("[Player] Native DV remux skipped: profile \(profile)")
            showPlayerToast("Dolby Vision profile \(profile) → HDR10/PQ")
            return
        }

        #if targetEnvironment(simulator)
        let displaySupportsDolbyVision = false
        #else
        let displaySupportsDolbyVision = AVPlayer.availableHDRModes.contains(.dolbyVision)
        #endif
        guard displaySupportsDolbyVision else {
            print("[Player] Native DV remux skipped: display does not advertise Dolby Vision")
            showPlayerToast("Dolby Vision unavailable on this display → HDR10/PQ")
            return
        }

        let startAt = max(time.current - 2, 0)
        nativeDVOriginalDuration = max(time.duration, Double(playerController.durationMs) / 1000)
        let preferredLanguage = playerController.audioTracks
            .first(where: \.selected)?.lang ?? ""
        let remuxer = DolbyVisionRemuxer(
            input: sourceURL,
            startAt: startAt,
            preferredAudioLanguage: preferredLanguage
        )
        nativeDVRemuxer = remuxer

        remuxer.onProgress = { [weak self, weak remuxer] written in
            guard let self, let remuxer, self.nativeDVRemuxer === remuxer else { return }
            self.nativeDVWrittenSeconds = max(self.nativeDVWrittenSeconds, written)
        }
        remuxer.onFinished = { [weak self, weak remuxer] in
            guard let self, let remuxer, self.nativeDVRemuxer === remuxer else { return }
            self.nativeDVRemuxFinished = true
        }
        remuxer.onReady = { [weak self, weak remuxer] playlistURL, actualStart in
            guard let self, let remuxer, self.nativeDVRemuxer === remuxer,
                  self.activeStreamURL == sourceURL,
                  self.activeEngineKind == .mpv,
                  !self.didShutdown else { return }
            self.activateNativeDolbyVision(
                playlistURL: playlistURL,
                actualStart: actualStart
            )
        }
        remuxer.onIneligible = { [weak self, weak remuxer] reason in
            guard let self, let remuxer else { return }
            self.nativeDolbyVisionRemuxFailed(
                reason: reason,
                sourceURL: sourceURL,
                remuxer: remuxer
            )
        }
        remuxer.onError = { [weak self, weak remuxer] reason in
            guard let self, let remuxer else { return }
            self.nativeDolbyVisionRemuxFailed(
                reason: reason,
                sourceURL: sourceURL,
                remuxer: remuxer
            )
        }

        print("[Player] Preparing native Dolby Vision P\(profile) from \(startAt)s")
        remuxer.start()
    }

    private func activateNativeDolbyVision(playlistURL: URL, actualStart: Double) {
        let sourcePosition = max(time.current, actualStart)
        nativeDVStartOffset = actualStart
        nativeDVPlaylistURL = playlistURL.absoluteString
        nativeDVDeferredSourceError = nil
        nativeDVSourceErrorDeadline = nil
        isUsingNativeDolbyVision = true

        print("[Player] Native DV playlist ready at source t=\(actualStart)s")
        status = .buffering
        playerController.suspendDisplayCriteriaForNativePlayback()
        selectEngine(.avPlayer, decisionMessage: nil)
        avPlayerController.loadFile(playlistURL.absoluteString)
        avPlayerController.seekToMs(Int64(max(sourcePosition - actualStart, 0) * 1000))
        avPlayerController.setAspectMode(.fit)
        videoNaturalSize = .zero
    }

    private func nativeDolbyVisionVideoDidBecomeReady(urlString: String) {
        guard isUsingNativeDolbyVision, urlString == nativeDVPlaylistURL else { return }
        let message = "Native Dolby Vision"
        hdrModeToast = message
        showPlayerToast(message)
    }

    private func nativeDolbyVisionRemuxFailed(
        reason: String,
        sourceURL: String,
        remuxer: DolbyVisionRemuxer
    ) {
        guard nativeDVRemuxer === remuxer, activeStreamURL == sourceURL else { return }
        print("[Player] Native DV remux unavailable: \(reason)")
        nativeDVFailedURLs.insert(sourceURL)
        nativeDVDeferredSourceError = nil
        nativeDVSourceErrorDeadline = nil
        if isUsingNativeDolbyVision {
            abandonNativeDolbyVision(reason: reason)
            return
        }

        remuxer.cancel()
        retiredNativeDVRemuxers.append(remuxer)
        nativeDVRemuxer = nil
        showPlayerToast("Native Dolby Vision unavailable → HDR10/PQ")
    }

    private func abandonNativeDolbyVision(
        reason: String?,
        resumeAt: Double? = nil,
        allowRetry: Bool = false
    ) {
        guard !didShutdown, isUsingNativeDolbyVision else { return }

        let nativePosition = nativeDVStartOffset
            + Double(avPlayerController.positionMs) / 1000
        let resume = max(resumeAt ?? max(nativePosition, time.current), 0)
        if !allowRetry, let sourceURL = activeStreamURL {
            nativeDVFailedURLs.insert(sourceURL)
        }

        avPlayerController.pausePlayback()
        if let remuxer = nativeDVRemuxer {
            remuxer.cancel()
            retiredNativeDVRemuxers.append(remuxer)
        }
        nativeDVRemuxer = nil
        nativeDVPlaylistURL = nil
        nativeDVStartOffset = 0
        nativeDVWrittenSeconds = 0
        nativeDVRemuxFinished = false
        nativeDVDeferredSourceError = nil
        nativeDVSourceErrorDeadline = nil
        isUsingNativeDolbyVision = false
        nativeDVRemuxAttempted = !allowRetry

        if let reason {
            print("[Player] Native DV fallback to retained MPV stream: \(reason)")
        }
        selectEngine(
            .mpv,
            decisionMessage: reason == nil
                ? nil
                : "Native Dolby Vision unavailable → HDR10/PQ"
        )
        playerController.restoreDisplayCriteriaAfterNativePlayback()
        playerController.seekToMs(Int64(resume * 1000))
        playerController.playPlayback()
        status = .buffering
    }

    private func resetNativeDolbyVisionSession() {
        if isUsingNativeDolbyVision {
            avPlayerController.pausePlayback()
        }
        if let remuxer = nativeDVRemuxer {
            remuxer.cancel()
            retiredNativeDVRemuxers.append(remuxer)
        }
        nativeDVRemuxer = nil
        nativeDVPlaylistURL = nil
        nativeDVStartOffset = 0
        nativeDVWrittenSeconds = 0
        nativeDVOriginalDuration = 0
        nativeDVRemuxFinished = false
        nativeDVDeferredSourceError = nil
        nativeDVSourceErrorDeadline = nil
        nativeDVRemuxAllowed = false
        nativeDVRemuxAttempted = false
        isUsingNativeDolbyVision = false
    }

    /// A second read of some debrid URLs can make MPV's original connection
    /// close while the packet-copy remux is already producing valid media.
    /// Give that remux a short chance to become ready before declaring the
    /// original URL dead and cycling through every source.
    private func shouldDeferSourceFailureForNativeDolbyVision(_ message: String) -> Bool {
        guard activeEngineKind == .mpv,
              !isUsingNativeDolbyVision,
              nativeDVRemuxer != nil else { return false }

        if nativeDVDeferredSourceError == nil {
            nativeDVDeferredSourceError = message
            nativeDVSourceErrorDeadline = Date().addingTimeInterval(15)
            print("[Player] Deferring MPV source error while native DV remux finishes: \(message)")
        }

        if let deadline = nativeDVSourceErrorDeadline, Date() < deadline {
            return true
        }

        print("[Player] Native DV remux did not recover before the source-error deadline")
        if let remuxer = nativeDVRemuxer {
            remuxer.cancel()
            retiredNativeDVRemuxers.append(remuxer)
        }
        if let sourceURL = activeStreamURL {
            nativeDVFailedURLs.insert(sourceURL)
        }
        nativeDVRemuxer = nil
        nativeDVDeferredSourceError = nil
        nativeDVSourceErrorDeadline = nil
        return false
    }

    /// Applies all per-stream state for a title/episode. Shared by the initial
    /// `load` and the in-place `replaceStream` used for a seamless next-episode
    /// advance, so both paths reset resume/track/subtitle state identically.
    private func applyStreamState(url: URL, meta: NuvioMeta, subtitle: String, externalSubtitles: [NuvioSubtitle], resumeFrom: Double?) {
        let isTrailerPlayback = subtitle == PlaybackMarkers.trailerSubtitle
        resetNativeDolbyVisionSession()
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        isLoadingExternalSubtitles = false
        self.title = meta.name
        self.subtitle = subtitle
        self.status = .buffering
        // A replaced file keeps the previous file's position/duration cached in
        // the controller until mpv publishes the new timeline. Clear the public
        // timeline now so end-of-episode UI cannot be re-armed for the new episode.
        self.time = PlayerTime()
        self.clock.position = 0
        self.clock.duration = 0
        self.clock.buffered = 0
        self.clock.scrubTarget = nil
        self.resetScrubSession()
        self.pendingSeekDelta = 0
        self.hidePeek()
        self.activeMeta = meta
        self.activeStreamURL = url.absoluteString
        self.activeEpisodeNumbers = isTrailerPlayback
            ? nil
            : Self.episodeNumbers(fromSubtitle: subtitle)
                ?? Self.episodeNumbers(fromStreamURL: url.absoluteString, isSeries: meta.isSeries)
        let selectionKey = isTrailerPlayback
            ? nil
            : PlayerTrackSelectionStore.key(meta: meta, episode: self.activeEpisodeNumbers)
        let savedSelection = selectionKey.flatMap { PlayerTrackSelectionStore.selection(for: $0) }
        self.activeTrackSelectionKey = selectionKey
        self.pendingTrackSelection = savedSelection
        self.pendingResumeSeconds = isTrailerPlayback ? nil : resumeFrom
        self.didApplyResume = false
        self.lastStablePlaybackTime = nil
        self.expectedDurationSeconds = isTrailerPlayback ? nil : Self.expectedDuration(for: meta)
        self.didDetectReplacementStream = false
        self.replacementStreamHits = 0
        // The full list stays browsable in the subtitle panel; only smart-matched
        // ones are eagerly loaded into mpv (loading all would fetch dozens of files).
        self.availableExternalSubtitles = isTrailerPlayback ? [] : externalSubtitles
        let smartMatched = isTrailerPlayback || savedSelection?.subtitle != nil
            ? []
            : Self.smartMatchedSubtitles(in: externalSubtitles)
        self.pendingExternalSubtitles = Self.subtitlesToPreload(
            smartMatched: smartMatched,
            savedSelection: savedSelection,
            availableExternalSubtitles: externalSubtitles
        )
        self.didAddExternalSubtitles = pendingExternalSubtitles.isEmpty
        self.addedExternalSubtitleURLs = []
        self.pendingSelectedExternalSubtitleURL = nil
        self.subtitleDelayMs = 0
        self.audioDelayMs = 0
        self.audioAmplificationDb = 0
        self.skipIntervals = []
        self.activeSkipInterval = nil
        self.skipSegmentCountdown = nil
        self.autoHiddenSkipIntervalId = nil
        self.skipSegmentAutoHideDeadline = nil
        self.skipIntervalLoadTask?.cancel()
        self.didApplySavedAudioSelection = savedSelection?.audio == nil
        self.didApplySavedSubtitleSelection = savedSelection?.subtitle == nil
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

    // MARK: - Next-episode auto-play

    /// Supplies the series context and the resolver that turns a next episode
    /// into a ready-to-play stream. Called by PlayerView once per presented
    /// episode; recomputed after every in-place advance.
    func configureNextEpisode(
        episodes: [NuvioVideo],
        current: NuvioVideo?,
        autoPlayEnabled: Bool,
        resolver: @escaping (NuvioVideo) async -> PreparedNextStream?
    ) {
        seriesEpisodes = episodes
        currentEpisodeVideo = current
        autoPlayNextEnabled = autoPlayEnabled
        resolveNextStream = resolver
        autoAdvanceDisabled = false
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        autoAdvanceDeadline = nil
        nextEpisode = Self.nextEpisode(after: current, in: episodes)
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
    /// IntroDB has an outro) and runs the auto-play countdown once armed.
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

        if !showNextEpisodeCard { showNextEpisodeCard = true }
        guard autoPlayNextEnabled, !autoAdvanceDisabled, nextEpisodeIsPlayable else {
            if nextEpisodeCountdown != nil { nextEpisodeCountdown = nil }
            autoAdvanceDeadline = nil
            return
        }

        // Fixed 10s countdown from when the card first arms, so it advances a few
        // seconds into the credits instead of waiting for the very end.
        if autoAdvanceDeadline == nil {
            autoAdvanceDeadline = Date().addingTimeInterval(Double(Self.autoCountdownSeconds))
        }
        let secondsLeft = autoAdvanceDeadline?.timeIntervalSinceNow ?? 0
        let countdown = max(0, Int(secondsLeft.rounded(.up)))
        if nextEpisodeCountdown != countdown { nextEpisodeCountdown = countdown }
        if secondsLeft <= 0.05 { advance(userInitiated: false) }
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
        autoAdvanceDeadline = nil
    }

    // MARK: - IntroDB skip segments

    private func loadSkipIntervalsIfNeeded(meta: NuvioMeta, isTrailerPlayback: Bool) {
        guard !isTrailerPlayback,
              meta.isSeries,
              let episodeNumbers = activeEpisodeNumbers else {
            return
        }

        let imdbId = meta.imdbId ?? meta.id
        skipIntervalLoadTask = Task { [weak self] in
            let intervals = await IntroDBSkipService.shared.intervals(
                imdbId: imdbId,
                season: episodeNumbers.season,
                episode: episodeNumbers.episode
            )
            await MainActor.run {
                guard let self else { return }
                self.skipIntervals = intervals
                self.updateSkipIntervalState()
            }
        }
    }

    private func updateSkipIntervalState() {
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
        advance(userInitiated: true)
    }

    private var canAutoAdvanceOnEnd: Bool {
        nextEpisode != nil && nextEpisodeIsPlayable && autoPlayNextEnabled && !autoAdvanceDisabled
            && subtitle != PlaybackMarkers.trailerSubtitle
    }

    private func advance(userInitiated: Bool) {
        guard !isAdvanceInFlight,
              let next = nextEpisode,
              EpisodeReleasePolicy.hasAired(next.released),
              let resolver = resolveNextStream else { return }
        isAdvanceInFlight = true
        isAdvancingEpisode = true
        nextEpisodeCountdown = nil

        // Mark the finishing episode watched, then roll Continue Watching over to
        // the next episode locally (like the phone) instead of removing the row.
        // This keeps the series visible as "Next Up" even if the next stream fails
        // to resolve or the user backs out before its own progress saves — the
        // bug where a finished episode made the whole series vanish from Home.
        if let activeMeta {
            markWatchedIfNeeded()
            ContinueWatchingStore.saveUpNext(
                meta: activeMeta,
                duration: time.duration,
                season: next.season,
                episode: next.episode,
                released: next.released
            )
        }

        Task { @MainActor in
            let prepared = await resolver(next)
            guard let prepared else {
                // Couldn't resolve a stream for the next episode: disarm so the
                // ended handler doesn't retry, and fall back to the normal
                // end-of-playback flow (which returns to the details screen).
                isAdvanceInFlight = false
                isAdvancingEpisode = false
                autoAdvanceDisabled = true
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
        applyStreamState(
            url: prepared.url,
            meta: meta,
            subtitle: prepared.subtitleLine,
            externalSubtitles: prepared.subtitles,
            resumeFrom: resumeFrom
        )
        if let episode {
            currentEpisodeVideo = episode
            nextEpisode = Self.nextEpisode(after: episode, in: seriesEpisodes)
        }
        autoAdvanceDisabled = false
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        autoAdvanceDeadline = nil
        isAdvanceInFlight = false
        isAdvancingEpisode = false
        isReloadingStream = false
        isSwitchingSource = false
        showControls = false

        applyEnginePolicy(
            for: prepared.url,
            streamName: prepared.streamName,
            streamDescription: prepared.streamDescription ?? prepared.subtitleLine,
            filename: prepared.filename
        )
        engine.loadFile(prepared.url.absoluteString)
        engine.setAspectMode(.fit)
        videoNaturalSize = .zero
        if pollTimer == nil { startPolling() }
        startLoadWatchdog()
    }

    /// Silently recovers from an expired link / dead source: fetches another
    /// stream for the current title (excluding URLs already tried) and reloads
    /// at the last known position.
    private func recoverExpiredStream() {
        if let url = activeStreamURL { failedStreamURLs.insert(url) }
        attemptFailover(
            reason: "This stream link has expired. Go back and start it again to load a fresh stream.",
            toast: "Link expired — trying another source"
        )
    }

    private func surfaceExpiredStreamError() {
        isReloadingStream = false
        isFailingOver = false
        isSwitchingSource = false
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        status = .error("This stream link has expired. Go back and start it again to load a fresh stream.")
    }

    // MARK: Load timeout watchdog

    private func startLoadWatchdog() {
        // Trailers / missing resolver: no alternate sources to fail over to.
        guard reloadCurrentStream != nil else { return }
        currentLoadStarted = false
        loadWatchdogTask?.cancel()
        let targetURL = activeStreamURL
        let timeout = loadTimeoutSeconds
        loadWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled, let self,
                  !self.currentLoadStarted,
                  !self.didShutdown,
                  !self.isFailingOver,
                  self.activeStreamURL == targetURL
            else { return }
            if let url = self.activeStreamURL {
                self.failedStreamURLs.insert(url)
            }
            self.showPlayerToast("Source didn't load — trying another")
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

        if let url = activeStreamURL {
            failedStreamURLs.insert(url)
        }

        isFailingOver = true
        isReloadingStream = true
        isSwitchingSource = true
        reloadAttempts += 1
        showNextEpisodeCard = false
        nextEpisodeCountdown = nil
        autoAdvanceDeadline = nil
        status = .buffering
        engine.pausePlayback()
        if let toast { showPlayerToast(toast) }

        // Prefer the last stable position (slate/error ticks can lie).
        let resume = lastStablePlaybackTime?.current
            ?? (time.current > 5 ? time.current : nil)
            ?? activeMeta.flatMap { ContinueWatchingStore.item(for: $0.id)?.resumePosition }

        let excluded = Array(failedStreamURLs)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isFailingOver = false
                // isSwitchingSource cleared in replaceStream / error paths
            }
            guard let prepared = await reloadCurrentStream(excluded) else {
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
        let sampledEngineKind = activeEngineKind
        let c = engine
        c.refreshPlaybackState()
        // An AVPlayer error callback can synchronously restore MPV while the
        // old controller is being refreshed. Discard that stale AV sample.
        guard activeEngineKind == sampledEngineKind else { return }

        let rawCurrent = Double(c.positionMs) / 1000.0
        let rawDuration = Double(c.durationMs) / 1000.0
        let latestTime = PlayerTime(
            current: isUsingNativeDolbyVision ? nativeDVStartOffset + rawCurrent : rawCurrent,
            duration: isUsingNativeDolbyVision
                ? max(nativeDVOriginalDuration, nativeDVStartOffset + rawDuration)
                : rawDuration
        )
        if c.hasCoherentTimeSample,
           !c.isPlayerLoading,
           !c.isAtEndOfFile,
           latestTime.duration > 0,
           latestTime.current >= 0,
           latestTime.current < latestTime.duration {
            lastStablePlaybackTime = latestTime
        }
        // The settings panel does not display playback time. Publish at most
        // once per displayed second while it is open, while the controller is
        // still polled at 4 Hz for playback/error handling.
        // During `loadfile replace`, the controller deliberately marks its time
        // sample incoherent while its numeric properties still contain the old
        // file's final position. Do not republish that stale timeline.
        if c.hasCoherentTimeSample,
           latestTime.duration > 0,
           latestTime.current >= 0,
           latestTime.current < latestTime.duration,
           (!showSettingsPanel ||
            Int(latestTime.current) != Int(time.current) ||
            latestTime.duration != time.duration) {
            if latestTime != time { time = latestTime }
            // Keep the high-frequency clock in sync for scrub/seek HUDs even when
            // the coarser `time` publication is throttled by the settings panel.
            if clock.position != latestTime.current { clock.position = latestTime.current }
            if clock.duration != latestTime.duration { clock.duration = latestTime.duration }
            let rawBufferedSeconds = Double(c.bufferedMs) / 1000.0
            let bufferedSeconds = isUsingNativeDolbyVision
                ? min(nativeDVStartOffset + rawBufferedSeconds, latestTime.duration)
                : rawBufferedSeconds
            if clock.buffered != bufferedSeconds { clock.buffered = bufferedSeconds }
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

        if !isUsingNativeDolbyVision,
           subtitle != PlaybackMarkers.trailerSubtitle,
           detectReplacementStream(c) { return }

        applyPendingResumeIfNeeded()
        maybeStartNativeDolbyVisionRemux()
        addPendingExternalSubtitlesIfNeeded()
        updateSkipIntervalState()

        if c.isPlayerEnded {
            // Roll straight into the next episode instead of ending, when armed —
            // but only on a genuine watch-through. mpv can momentarily report
            // "ended" while a fresh stream is still loading (position ~0); without
            // this position check that would wrongly clear Continue Watching and
            // jump to the following episode.
            if canAutoAdvanceOnEnd, time.duration >= 60, time.current / time.duration >= 0.85 {
                advance(userInitiated: false)
                return
            }
            // Only a genuine watch-through counts. A stream that dies early
            // (expired link, decode error) also reports "ended", and that must
            // neither mark the title watched nor wipe the resume point.
            if let activeMeta, subtitle != PlaybackMarkers.trailerSubtitle,
               time.duration >= 60, time.current / time.duration >= 0.85 {
                markWatchedIfNeeded()
                if let next = nextEpisode {
                    // Series with a follow-up: roll Continue Watching over to the
                    // next episode so it shows as "Next Up" instead of vanishing.
                    ContinueWatchingStore.save(
                        meta: activeMeta,
                        streamUrl: "",
                        position: 1,
                        duration: max(time.duration, 120),
                        season: next.season,
                        episode: next.episode
                    )
                } else {
                    // Movie or final episode: nothing left to continue.
                    ContinueWatchingStore.remove(metaId: activeMeta.id)
                }
            }
        } else {
            saveProgressIfNeeded()
            updateNextEpisodeState()
        }

        // Don't clobber an explicit error state (failover already exhausted).
        if case .error = status { return }

        // mpv hard-failed this source — try the next one before surfacing UI.
        if !c.currentErrorMessage.isEmpty, !isFailingOver, !isReloadingStream {
            if shouldDeferSourceFailureForNativeDolbyVision(c.currentErrorMessage) {
                if status != .buffering { status = .buffering }
                return
            }
            if let url = activeStreamURL { failedStreamURLs.insert(url) }
            attemptFailover(
                reason: c.currentErrorMessage,
                toast: "Source failed — trying another"
            )
            return
        }

        let previousStatus = status

        let latestStatus: PlayerStatus
        if !c.currentErrorMessage.isEmpty {
            latestStatus = .error(c.currentErrorMessage)
        } else if c.isPlayerEnded {
            latestStatus = .ended
        } else if c.isPlayerLoading {
            latestStatus = .buffering
        } else if c.isPlayerPlaying {
            latestStatus = .playing
        } else {
            latestStatus = .paused
        }
        if status != latestStatus { status = latestStatus }

        // First real frames/audio — disarm the load watchdog.
        if status == .playing || (status == .paused && time.duration > 0 && !c.isPlayerLoading) {
            markLoadStarted()
        }

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
        if status == .playing, time.duration >= 60, !didDetectReplacementStream {
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
                          externalFilename: $0.externalFilename)
        }
        let anySelected = subs.contains { $0.isSelected }
        subs.insert(SubtitleTrack(id: "off", name: "Off", language: "",
                                  isSelected: !anySelected), at: 0)
        if subtitles != subs { subtitles = subs }
        applySavedTrackSelectionsIfNeeded()
        applyAudioPreferenceIfNeeded()
        applySubtitlePreferenceIfNeeded()
        if let selectedURL = pendingSelectedExternalSubtitleURL,
           let selectedTrack = subtitles.first(where: { $0.externalFilename == selectedURL }) {
            selectSubtitle(selectedTrack, persist: false)
            pendingSelectedExternalSubtitleURL = nil
        }
    }

    // MARK: - Transport

    func play() {
        if status == .ended { seek(to: 0) }
        engine.playPlayback()
        status = .playing
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        showControls = true
        scheduleControlsHide()
    }

    func pause() {
        engine.pausePlayback()
        status = .paused
        saveProgress(force: true)
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        // Show transport first; metadata sheet fades in after a short delay
        // (trailers stay on simple controls only).
        showControls = true
        if subtitle != PlaybackMarkers.trailerSubtitle, !showSettingsPanel, !isScrubbing {
            schedulePauseOverlay()
        } else {
            scheduleControlsHide()
        }
    }

    /// After 3s of still being paused, hide transport and show the metadata sheet.
    private func schedulePauseOverlay() {
        pauseOverlayTask?.cancel()
        pauseOverlayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pauseOverlayDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.status == .paused,
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
        didShutdown = true
        pollTimer?.invalidate()
        pollTimer = nil
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        stopRepeatingSkip()
        cancelScrub()
        hidePeek()
        seekDebounceTask?.cancel()
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        toastClearTask?.cancel()
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        sidePanel = nil
        availableSources = []
        pendingSeekDelta = 0
        playerToast = nil
        isSwitchingSource = false
        if let controllerConnectObserver {
            NotificationCenter.default.removeObserver(controllerConnectObserver)
            self.controllerConnectObserver = nil
        }
        trailerResolveTask?.cancel()
        trailerResolveTask = nil
        subtitleFetchTask?.cancel()
        subtitleFetchTask = nil
        isLoadingExternalSubtitles = false
        skipIntervalLoadTask?.cancel()
        skipIntervalLoadTask = nil
        playerController.pausePlayback()
        avPlayerController.pausePlayback()
        let remuxers = retiredNativeDVRemuxers + [nativeDVRemuxer].compactMap { $0 }
        remuxers.forEach { $0.cancel() }
        nativeDVRemuxer = nil
        retiredNativeDVRemuxers.removeAll()
        saveProgress(force: true)
        // Leave both engines destroyed so a re-entry cannot resume a ghost pipeline.
        playerController.destroyPlayer()
        avPlayerController.destroyPlayer()
        remuxers.forEach { $0.cleanup() }
        status = .idle
    }

    func togglePlayPause() {
        if isScrubbing {
            commitScrub()
            return
        }
        if status == .playing { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        let duration = time.duration > 0 ? time.duration : clock.duration
        let target = duration > 0
            ? min(max(seconds, 0), max(duration - 0.25, 0))
            : max(seconds, 0)
        if isUsingNativeDolbyVision {
            let availableEnd = nativeDVStartOffset + nativeDVWrittenSeconds
            let isInWrittenWindow = target >= nativeDVStartOffset
                && (nativeDVRemuxFinished || target <= max(availableEnd - 0.5, nativeDVStartOffset))
            if isInWrittenWindow {
                avPlayerController.seekToMs(
                    Int64(max(target - nativeDVStartOffset, 0) * 1000)
                )
            } else {
                // The local EVENT playlist does not contain this source time.
                // Resume instantly through the retained MPV item; the next poll
                // starts a fresh remux around the requested position.
                abandonNativeDolbyVision(
                    reason: nil,
                    resumeAt: target,
                    allowRetry: true
                )
            }
        } else {
            engine.seekToMs(Int64(target * 1000))
        }
        // Instant UI feedback while mpv catches up.
        clock.position = target
        var snapshot = time
        snapshot.current = target
        if snapshot.duration <= 0, clock.duration > 0 {
            snapshot.duration = clock.duration
        }
        time = snapshot
        if showNextEpisodeCard { disableAutoAdvanceForCurrentEpisode() }
    }

    private func playbackDidSuspend(positionMs: Int64, durationMs: Int64) {
        let sourcePositionMs = isUsingNativeDolbyVision
            ? Int64(nativeDVStartOffset * 1000) + positionMs
            : positionMs
        let sourceDurationMs = isUsingNativeDolbyVision && nativeDVOriginalDuration > 0
            ? Int64(nativeDVOriginalDuration * 1000)
            : durationMs
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
        saveProgress(force: true)
    }

    func skipActiveInterval() {
        guard let interval = activeSkipInterval else { return }
        autoHiddenSkipIntervalId = interval.id
        skipSegmentCountdown = nil
        skipSegmentAutoHideDeadline = nil
        activeSkipInterval = nil
        seek(to: min(interval.endTime + 0.25, max(time.duration - 0.5, interval.endTime)))
        showControls = false
        scheduleControlsHide()
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

    /// Hold-to-seek uses the same accelerating accumulation as rapid taps
    /// (`nudgeSeek`), not fixed-size hard seeks — so holding feels at least as
    /// fast as mashing the button.
    private func beginRepeatingNudge(base: Double) {
        stopRepeatingNudge(commit: false)
        // Keep any pending delta from the initial press; continue the streak.
        applyNudge(base, holdMode: true)
        let timer = Timer(timeInterval: Self.seekRepeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.applyNudge(base, holdMode: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        seekRepeatTimer = timer
    }

    private func stopRepeatingNudge(commit: Bool) {
        seekRepeatTimer?.invalidate()
        seekRepeatTimer = nil
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

    private var secondsPerPoint: Double {
        let duration = playbackDuration
        guard duration > 0 else { return 0.5 }
        return max(duration / 3200, 0.35)
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
        scrubValue = nil
        isScrubbing = false
        resetWheel()
        clock.scrubTarget = nil
        touchIntent = .undecided
        scrubLastDx = 0
    }

    func beginScrub() {
        guard hasStartedPlayback, !showSettingsPanel else { return }
        hidePeek()
        commitPendingSeekIfNeeded()
        // Scrubbing replaces the pause sheet for the gesture.
        dismissPauseOverlay()
        showControls = false
        let position = playbackPosition
        scrubValue = position
        clock.scrubTarget = position
        isScrubbing = true
        resetWheel()
        restartScrubTimeout()
    }

    func endScrubGesture() {
        if let target = scrubValue {
            clock.scrubTarget = target
        }
    }

    func commitScrub() {
        guard let target = scrubValue else {
            resetScrubSession()
            return
        }
        seek(to: target)
        resetScrubSession()
        showControls = true
        if status == .paused,
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
        if status == .paused,
           subtitle != PlaybackMarkers.trailerSubtitle,
           !showSettingsPanel {
            showControls = false
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
        scrubLastDx = 0
        suppressMoveBriefly()
        noteSwipeStarted()
        touchIntent = isScrubbing ? .scrub : .undecided
    }

    func remoteTouchMoved(dx: CGFloat, dy: CGFloat) {
        suppressMoveBriefly()
        switch touchIntent {
        case .scrub:
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
                // Horizontal drag → enter Infuse scrub and start tracking.
                // beginScrub dismisses the pause sheet if it was up.
                beginScrub()
                touchIntent = .scrub
                scrubPanPoints(dx: dx)
            }
        }
    }

    func remoteTouchEnded(dx: CGFloat, dy: CGFloat) {
        if touchIntent == .scrub { endScrubGesture() }
        touchIntent = .undecided
    }

    private func scrubPanPoints(dx: CGFloat) {
        let inc = dx - scrubLastDx
        scrubLastDx = dx
        guard let target = scrubValue, !wheelEngaged else { return }
        let duration = playbackDuration
        let proposed = target + Double(inc) * secondsPerPoint
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

    // MARK: D-pad accumulating seek

    /// One left/right press. Rapid presses accumulate into one seek with
    /// acceleration, previewed by `pendingSeekDelta` / SeekHUD. Hold-to-seek
    /// uses the same path via `beginRepeatingNudge`.
    func nudgeSeek(_ base: Double) {
        applyNudge(base, holdMode: false)
    }

    private func applyNudge(_ base: Double, holdMode: Bool) {
        guard hasStartedPlayback, !isScrubbing, !showSettingsPanel else { return }
        hidePeek()

        let now = Date()
        // Hold ticks are ~0.11s apart; taps need a looser window.
        let streakWindow = holdMode ? 0.25 : 0.35
        let maxStreak = holdMode ? 28 : 12
        let accelPerStep = holdMode ? 0.75 : 0.6
        if let last = lastNudgeAt, now.timeIntervalSince(last) < streakWindow {
            nudgeStreak = min(nudgeStreak + 1, maxStreak)
        } else if !holdMode {
            nudgeStreak = 0
        }
        // Hold mode: don't reset streak on a slightly late tick.
        lastNudgeAt = now

        let accel = 1.0 + Double(nudgeStreak) * accelPerStep
        pendingSeekDelta += base * accel

        let duration = playbackDuration
        let position = playbackPosition
        if duration > 0 {
            let target = min(max(position + pendingSeekDelta, 0), duration - 1)
            pendingSeekDelta = target - position
        }

        if showNextEpisodeCard { disableAutoAdvanceForCurrentEpisode() }

        // Left/right skip always dismisses the pause metadata sheet so SeekHUD /
        // transport can take over (same idea as Android onUserInteraction).
        if showPauseOverlay {
            dismissPauseOverlay()
            showControls = false
        } else if showControls {
            scheduleControlsHide()
            if status == .paused,
               subtitle != PlaybackMarkers.trailerSubtitle,
               !showSettingsPanel {
                // Restart the 3s countdown if transport is already up while paused.
                schedulePauseOverlay()
            }
        }

        seekDebounceTask?.cancel()
        if holdMode {
            // Commit on finger-up (`stopRepeatingNudge`), not mid-hold.
            return
        }
        seekDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let self else { return }
            self.commitPendingSeekIfNeeded()
        }
    }

    private func commitPendingSeekIfNeeded() {
        seekDebounceTask?.cancel()
        let delta = pendingSeekDelta
        pendingSeekDelta = 0
        nudgeStreak = 0
        guard delta != 0 else { return }
        // Belt-and-braces: skip must never leave the pause sheet up.
        if showPauseOverlay {
            dismissPauseOverlay()
        }
        seek(to: playbackPosition + delta)
        if !isScrubbing, !showControls {
            // After a bare-video skip, briefly flash controls so the user sees
            // the landing position, then auto-hide (or return to pause sheet).
            showControls = true
            if status == .paused,
               subtitle != PlaybackMarkers.trailerSubtitle,
               !showSettingsPanel {
                schedulePauseOverlay()
            } else {
                scheduleControlsHide()
            }
        } else if showControls {
            if status == .paused,
               subtitle != PlaybackMarkers.trailerSubtitle,
               !showSettingsPanel {
                schedulePauseOverlay()
            } else {
                scheduleControlsHide()
            }
        }
    }

    /// Cancels the countdown for the current episode after a manual seek; the
    /// Next Episode card remains so the user can still advance by hand.
    func disableAutoAdvanceForCurrentEpisode() {
        guard !autoAdvanceDisabled else { return }
        autoAdvanceDisabled = true
        nextEpisodeCountdown = nil
        autoAdvanceDeadline = nil
    }

    func setSpeed(_ speed: PlaybackSpeed) {
        playbackSpeed = speed
        engine.setSpeed(speed.rawValue)
    }

    func applySubtitleStyle() {
        engine.applySubtitleStyle()
    }

    /// Shifts subtitle timing; positive shows captions later.
    func setSubtitleDelayMs(_ ms: Int) {
        let clamped = min(max(ms, -30_000), 30_000)
        subtitleDelayMs = clamped
        engine.setSubtitleDelay(Double(clamped) / 1000.0)
    }

    /// Shifts audio timing; positive delays the audio.
    func setAudioDelayMs(_ ms: Int) {
        let clamped = min(max(ms, -3_000), 3_000)
        audioDelayMs = clamped
        engine.setAudioDelay(Double(clamped) / 1000.0)
    }

    /// PCM amplification in whole dB (0…10).
    func setAudioAmplificationDb(_ db: Int) {
        let clamped = min(max(db, 0), 10)
        audioAmplificationDb = clamped
        engine.setAudioVolumeGain(dB: Double(clamped))
    }

    // MARK: - Track selection

    func selectSubtitle(_ track: SubtitleTrack, persist: Bool = true) {
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
        guard let preferred = SubtitleLanguagePreferences.preferredAudioLanguage() else {
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
        guard let activeTrackSelectionKey else { return }
        PlayerTrackSelectionStore.saveAudio(
            PlayerTrackSelection.Audio(
                id: track.id,
                name: track.name,
                language: track.language,
                languageName: track.languageName
            ),
            for: activeTrackSelectionKey
        )
    }

    private func saveSubtitleSelection(_ track: SubtitleTrack) {
        guard let activeTrackSelectionKey else { return }
        let selection: PlayerTrackSelection.Subtitle
        if track.id == "off" {
            selection = PlayerTrackSelection.Subtitle(kind: .off)
        } else if !track.externalFilename.isEmpty {
            selection = PlayerTrackSelection.Subtitle(
                kind: .external,
                id: track.id,
                name: track.name,
                language: track.language,
                externalURL: track.externalFilename
            )
        } else {
            selection = PlayerTrackSelection.Subtitle(
                kind: .embedded,
                id: track.id,
                name: track.name,
                language: track.language
            )
        }
        PlayerTrackSelectionStore.saveSubtitle(selection, for: activeTrackSelectionKey)
    }

    private func saveSubtitleSelection(_ subtitle: NuvioSubtitle) {
        guard let activeTrackSelectionKey else { return }
        PlayerTrackSelectionStore.saveSubtitle(
            PlayerTrackSelection.Subtitle(
                kind: .external,
                name: subtitle.label,
                language: subtitle.language,
                externalURL: subtitle.url
            ),
            for: activeTrackSelectionKey
        )
    }

    private func matchingAudioTrack(for saved: PlayerTrackSelection.Audio) -> AudioTrack? {
        if let track = audioTracks.first(where: { $0.id == saved.id }) { return track }
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
           let track = candidates.first(where: { $0.id == id }) {
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

    func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.controlsAutoHideSuspended else { return }
                // While paused, the dedicated pause-overlay timer owns visibility
                // (3s delay). Don't fight it by auto-hiding controls early.
                guard self.status == .playing else { return }
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

    func revealControls() {
        hidePeek()
        if isScrubbing { return }
        // Full transport chrome supersedes the pause metadata sheet.
        cancelPauseOverlaySchedule()
        showPauseOverlay = false
        showControls = true
        updateSkipIntervalState()
        if status == .playing {
            scheduleControlsHide()
        } else if status == .paused {
            // Restart the 3s countdown to the pause sheet.
            if subtitle != PlaybackMarkers.trailerSubtitle, !showSettingsPanel {
                schedulePauseOverlay()
            }
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
        showControls = false
        sidePanel = panel
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
        isLoadingSources = true
        let type = panelSourceContentType
        Task { @MainActor [weak self] in
            guard let self else { return }
            let streams = await fetchPlaybackSources(contentId, type)
            self.availableSources = streams
            self.isLoadingSources = false
        }
    }

    func isCurrentSource(_ stream: NuvioStream) -> Bool {
        guard let active = activeStreamURL else { return false }
        if let url = stream.url, !url.isEmpty {
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
        isSwitchingSource = true
        status = .buffering
        engine.pausePlayback()
        showPlayerToast("Switching source…")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSwitchingSource = false }
            guard let prepared = await resolvePlaybackStream(stream, contentId, subtitleLine) else {
                self.showPlayerToast("Couldn't open this source")
                self.status = .paused
                return
            }
            self.failedStreamURLs.removeAll()
            self.replaceStream(prepared: prepared, episode: nil, resumeFrom: resume)
            self.closeSidePanel()
            self.showPlayerToast("Source switched")
        }
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
        isSwitchingSource = true
        status = .buffering
        engine.pausePlayback()
        showPlayerToast("Loading episode…")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSwitchingSource = false }
            guard let prepared = await resolveNextStream(episode) else {
                self.showPlayerToast("Couldn't load this episode")
                self.status = .paused
                return
            }
            self.failedStreamURLs.removeAll()
            self.availableSources = []
            self.replaceStream(prepared: prepared, episode: episode, resumeFrom: nil)
            self.closeSidePanel()
        }
    }

    func setAspectMode(_ mode: PlayerAspectMode) {
        // Aspect modes temporarily disabled — always FIT.
        aspectMode = .fit
        PlayerAspectMode.current = .fit
        engine.setAspectMode(.fit)
        _ = mode
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

        didApplyResume = true
        seek(to: min(pendingResumeSeconds, max(time.duration - 5, 0)))
    }

    private func saveProgressIfNeeded() {
        guard Date().timeIntervalSince(lastProgressSave) >= 5 else { return }
        saveProgress(force: false)
    }

    private func saveProgress(force: Bool) {
        let progressTime = force ? (lastStablePlaybackTime ?? time) : time
        guard let activeMeta,
              let activeStreamURL,
              progressTime.current.isFinite,
              progressTime.duration.isFinite,
              progressTime.current > 0,
              progressTime.duration > 0,
              progressTime.current < progressTime.duration,
              subtitle != PlaybackMarkers.trailerSubtitle,
              !loadedStreamLooksLikeReplacement(),
              force || progressTime.current >= 10 else {
            return
        }

        if shouldSaveNextUpProgress(at: progressTime), let nextEpisode {
            markWatchedIfNeeded()
            ContinueWatchingStore.saveUpNext(
                meta: activeMeta,
                duration: progressTime.duration,
                season: nextEpisode.season,
                episode: nextEpisode.episode,
                released: nextEpisode.released
            )
            lastProgressSave = Date()
            return
        }

        let season = resolvedEpisodeNumbers?.season
        let episode = resolvedEpisodeNumbers?.episode
        ContinueWatchingStore.save(
            meta: activeMeta,
            streamUrl: activeStreamURL,
            position: progressTime.current,
            duration: progressTime.duration,
            season: season,
            episode: episode
        )
        lastProgressSave = Date()

        // Ending start / 92% — checkmark without sitting through the credits.
        if shouldMarkAsWatched(at: progressTime) {
            markWatchedIfNeeded()
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
        guard playbackTime.duration >= 60,
              playbackTime.current > 0,
              playbackTime.current / playbackTime.duration >= 0.5 else {
            return false
        }
        if let ending = skipIntervals.first(where: \.isEnding),
           playbackTime.current >= max(ending.startTime - Self.skipSegmentStartLead, 0) {
            return true
        }
        return playbackTime.current / playbackTime.duration >= 0.92
    }

    private var nextEpisodeIsPlayable: Bool {
        nextEpisode.map { EpisodeReleasePolicy.hasAired($0.released) } ?? false
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
        guard let activeMeta else { return }
        let numbers = resolvedEpisodeNumbers
        let season = numbers?.season
        let episode = numbers?.episode
        if let season, let episode {
            guard !WatchedStore.containsEpisode(metaId: activeMeta.id, season: season, episode: episode) else {
                return
            }
        } else {
            // Series without resolved S/E must not write a whole-title mark —
            // that would checkmark the poster but never the episode card.
            if activeMeta.isSeries { return }
            guard !WatchedStore.contains(metaId: activeMeta.id, type: activeMeta.type) else { return }
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

// MARK: - Track Info

struct TrackInfo {
    let index: Int
    let id: Int
    let type: String
    let title: String
    let lang: String
    let selected: Bool
    /// mpv `external-filename` — the URL a `sub-add`ed track was loaded from,
    /// empty for tracks embedded in the container.
    let externalFilename: String
    /// Localized language name for audio cards ("Russian"), empty for subs.
    var languageName: String = ""
    /// Technical summary for audio cards ("AC-3 | 6 ch | 48 kHz"), empty for subs.
    var detail: String = ""
}

// MARK: - Network buffer sizing

/// libmpv network-cache sizes, driven by Settings → Playback → Network Cache.
/// `forwardBuffer` is how far ahead mpv prefetches ("preload"); `backBuffer`
/// keeps already-played data resident for instant backward seeks. Values are
/// libmpv bytesize strings (e.g. `"128MiB"`).
///
/// Caps are intentionally modest on tvOS. Apple TV often has only 2–4 GB RAM
/// total; demuxer cache + decode surfaces + Metal/Vulkan can jetsam the app
/// (bug type 298 / `per-process-limit`) once a process approaches ~2 GB.
/// Older defaults (Auto ≈ 512 MiB–1 GiB forward alone) filled aggressively on
/// debrid/4K hosts and caused frequent foreground kills during long watches.
struct PlaybackCacheSettings {
    let forwardBuffer: String
    let backBuffer: String

    static var current: PlaybackCacheSettings {
        switch ProfileSettings.current.string(forKey: SettingsKey.networkCache) ?? "Auto" {
        case "Small":
            // Minimal readahead — prefer stability over seek/buffer comfort.
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        case "Medium":
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        case "Large":
            // Still well under previous 1 GiB default; enough for bursty hosts.
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        default:
            return auto
        }
    }

    /// Ceiling scaled to total device RAM (`physicalMemory` is bytes).
    /// Prefer staying far below jetsam: demuxer is only one slice of peak RSS.
    /// > 3.5 GB (newer 4K) → 192/48, ~3 GB (common 4K) → 128/32, ≤ 2.5 GB (HD) → 64/16.
    private static var auto: PlaybackCacheSettings {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gib > 3.5 {
            return PlaybackCacheSettings(forwardBuffer: "192MiB", backBuffer: "48MiB")
        } else if gib > 2.5 {
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        } else {
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        }
    }
}

// MARK: - MPV Player View Controller (tvOS)
//
// Self-contained libmpv host. Ported from the iOS bridge, with the Kotlin/
// Compose plumbing and iOS-only UIViewController overrides (home indicator,
// status-bar, screen-edge gestures — none exist on tvOS) removed.

final class MPVPlayerViewController: UIViewController, PlaybackEngineControlling {
    /// Called after a coherent position is captured but before tvOS suspends
    /// the player. PlayerViewModel uses it for a durable lifecycle save.
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?


    private static let defaultAudioOutput = "avfoundation"

    private let errorStateLock = NSLock()
    private var metalLayer = MPVMetalLayer()
    private var lastAppliedDrawableSize: CGSize = .zero
    private var pendingURL: String?
    private var pendingAudioURL: String?
    private var mpv: OpaquePointer?
    private lazy var eventQueue = DispatchQueue(label: "mpv-events", qos: .userInitiated)
    private var recentPlaybackLogs: [String] = []

    // Cached track lists
    var audioTracks: [TrackInfo] = []
    var subtitleTracks: [TrackInfo] = []

    // State (polled from the view model every 250ms)
    var isPlayerLoading: Bool = true
    var isPlayerPlaying: Bool = false
    var isPlayerEnded: Bool = false
    private(set) var isAtEndOfFile: Bool = false
    private(set) var hasCoherentTimeSample: Bool = false
    var durationMs: Int64 = 0
    var positionMs: Int64 = 0
    var bufferedMs: Int64 = 0
    var currentSpeed: Float = 1.0
    var currentErrorMessage: String {
        errorStateLock.lock(); defer { errorStateLock.unlock() }
        return _currentErrorMessage ?? ""
    }
    private var _currentErrorMessage: String?
    private var _didReachCleanEndOfFile = false
    private var didReachCleanEndOfFile: Bool {
        errorStateLock.lock(); defer { errorStateLock.unlock() }
        return _didReachCleanEndOfFile
    }

    // tvOS detaches video while another app is frontmost. Freeze the last
    // coherent time until MPV has reattached and sought back to it; otherwise
    // keep-open can briefly expose its last frame as time-pos == duration.
    private var isApplicationBackgrounded = false
    private var wasPlayingBeforeBackground = false
    private var lifecyclePositionMs: Int64?
    private var lifecycleDurationMs: Int64?
    /// Independent of the UI-facing position, which MPV can overwrite with the
    /// final frame just before tvOS delivers didEnterBackground.
    private var lastVerifiedPositionMs: Int64?
    private var lastVerifiedDurationMs: Int64?
    private var lastVerifiedWasPlaying = false
    private var foregroundRestoreTargetMs: Int64?
    private var foregroundRestoreDeadline: Date?
    private var lifecycleRestoreFailed = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        // `.resize` lets mpv own letterboxing/cropping via panscan/keepaspect.
        // `.resizeAspect` would re-letterbox after mpv already rendered.
        metalLayer.contentsGravity = .resize
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        layoutMetalLayer()

        setupMpv()
        setupNotifications()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMetalLayer()
        attemptStartPendingLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attemptStartPendingLoad()
    }

    private func layoutMetalLayer() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        let scale = UIScreen.main.nativeScale
        let drawableSize = CGSize(
            width: (bounds.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero)
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        if drawableSize != lastAppliedDrawableSize {
            metalLayer.drawableSize = drawableSize
            lastAppliedDrawableSize = drawableSize
        }
        CATransaction.commit()
    }

    // MARK: - MPV Setup

    private func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else {
            print("[MPV] Failed to create mpv instance")
            return
        }

        checkError(mpv_request_log_messages(mpv, "warn"))

        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(mpv, "ao", Self.defaultAudioOutput))
        // AVSampleBufferAudioRenderer follows tvOS's active output route without
        // using the failing RemoteIO callback from MPV's AudioUnit backend.
        checkError(mpv_set_option_string(mpv, "audio-channels", "auto-safe"))
        // AVFoundation accepts interleaved PCM; packed float preserves decoded
        // precision while supporting route-selected stereo or multichannel audio.
        checkError(mpv_set_option_string(mpv, "audio-format", "float"))
        // Headroom for the Audio → Amplification control (+10 dB ≈ 316%).
        checkError(mpv_set_option_string(mpv, "volume-max", "400"))
        // Do not silently replace a failed audio renderer with `ao=null` and
        // continue as video-only playback.
        checkError(mpv_set_option_string(mpv, "audio-fallback-to-null", "no"))

        // Network buffering. Byte caps (Settings → Playback → Network Cache)
        // are the hard limit; keep time windows modest so we do not encourage
        // filling multi‑hundred‑MB demuxer caches on every debrid stream.
        #if targetEnvironment(simulator)
        // MoltenVK's tvOS simulator PBO path allocates every uploaded video
        // frame through MTLSim XPC and can trap in `_xpc_api_misuse` for real
        // streams. Keep the simulator light and allow VideoToolbox's Metal
        // texture interop; physical Apple TV keeps the user's cache setting.
        let cache = PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        #else
        let cache = PlaybackCacheSettings.current
        #endif
        checkError(mpv_set_option_string(mpv, "cache", "yes"))
        // ~2 minutes of readahead intent; demuxer-max-bytes still hard-caps RAM.
        checkError(mpv_set_option_string(mpv, "cache-secs", "120"))
        checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "120"))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", cache.forwardBuffer))
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", cache.backBuffer))
        checkError(mpv_set_option_string(mpv, "vulkan-swap-mode", "fifo"))
        checkError(mpv_set_option_string(mpv, "vulkan-queue-count", "1"))
        checkError(mpv_set_option_string(mpv, "vulkan-async-compute", "no"))
        checkError(mpv_set_option_string(mpv, "vulkan-async-transfer", "no"))
        #if targetEnvironment(simulator)
        checkError(mpv_set_option_string(mpv, "vulkan-disable-interop", "no"))
        #else
        checkError(mpv_set_option_string(mpv, "vulkan-disable-interop", "yes"))
        #endif
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        if let audioLanguage = SubtitleLanguagePreferences.preferredAudioLanguage(),
           let alang = SubtitleLanguagePreferences.mpvLanguageList(for: [audioLanguage]) {
            checkError(mpv_set_option_string(mpv, "alang", alang))
        }
        let preferredSubtitleLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        let shouldStrictlyMatchSubtitles = SubtitleLanguagePreferences.smartMatchingEnabled() &&
            !preferredSubtitleLanguages.isEmpty
        if let slang = SubtitleLanguagePreferences.mpvLanguageList(for: preferredSubtitleLanguages) {
            checkError(mpv_set_option_string(mpv, "slang", slang))
        }
        checkError(mpv_set_option_string(mpv, "subs-match-os-language", shouldStrictlyMatchSubtitles ? "no" : "yes"))
        checkError(mpv_set_option_string(mpv, "subs-fallback", shouldStrictlyMatchSubtitles ? "no" : "yes"))
        // Render text subtitles through the app's style instead of honoring
        // embedded ASS/SSA positioning tags. Some tracks declare top alignment
        // (for example `\\an8`), which otherwise bypasses the user's bottom
        // margin and leaves dialogue at the top of the screen.
        checkError(mpv_set_option_string(mpv, "sub-ass-override", "strip"))
        checkError(mpv_set_option_string(mpv, "sub-use-margins", "yes"))
        checkError(mpv_set_option_string(mpv, "sub-ass-force-margins", "yes"))
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))
        checkError(mpv_set_option_string(mpv, "target-colorspace-hint", "yes"))
        checkError(mpv_set_option_string(mpv, "tone-mapping", "auto"))
        #if targetEnvironment(simulator)
        checkError(mpv_set_option_string(mpv, "hdr-compute-peak", "no"))
        #else
        checkError(mpv_set_option_string(mpv, "hdr-compute-peak", "yes"))
        #endif
        checkError(mpv_set_option_string(mpv, "target-prim", "auto"))
        checkError(mpv_set_option_string(mpv, "target-trc", "auto"))

        checkError(mpv_initialize(mpv))
        applySubtitleStyle()

        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list/count", MPV_FORMAT_INT64)
        // Selecting a different audio/subtitle track leaves the track *count*
        // unchanged, so those alone wouldn't refresh the cached track list and
        // the panel's checkmark would snap back to the old track. Observing the
        // active ids (they can be "no"/"auto", hence STRING) fires a refresh the
        // moment a selection actually changes. See `refreshTracks`.
        mpv_observe_property(mpv, 0, "aid", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "sid", MPV_FORMAT_STRING)

        mpv_set_wakeup_callback(mpv, { ctx in
            let vc = unsafeBitCast(ctx, to: MPVPlayerViewController.self)
            vc.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func enterBackground() {
        guard mpv != nil else { return }
        let sampledDurationMs = milliseconds(from: readDoubleProperty("duration")) ?? durationMs
        let sampledPositionMs = milliseconds(from: readDoubleProperty("time-pos")) ?? positionMs
        let verifiedPositionMs = lastVerifiedPositionMs ?? positionMs
        let verifiedDurationMs = lastVerifiedDurationMs ?? durationMs
        let referenceDurationMs = max(sampledDurationMs, verifiedDurationMs)

        // The UI-facing position can already contain MPV's bogus final-frame
        // value by this point. Compare against the independent verified sample.
        let jumpedToEnd = referenceDurationMs >= 60_000
            && sampledPositionMs >= referenceDurationMs - 5_000
            && verifiedPositionMs < referenceDurationMs * 85 / 100
            && sampledPositionMs - verifiedPositionMs > 30_000
        let safePositionMs = max(0, jumpedToEnd ? verifiedPositionMs : sampledPositionMs)

        let mpvStillPlaying = !getFlag("pause") && !getFlag("eof-reached")
        wasPlayingBeforeBackground = mpvStillPlaying || (jumpedToEnd && lastVerifiedWasPlaying)
        lifecyclePositionMs = safePositionMs
        lifecycleDurationMs = max(referenceDurationMs, durationMs)
        foregroundRestoreTargetMs = nil
        foregroundRestoreDeadline = nil
        lifecycleRestoreFailed = false
        isApplicationBackgrounded = true
        clearCleanEndState()
        pausePlayback()
        setStringProperty("vid", "no")
        publishLifecycleSnapshot()
        onPlaybackSuspended?(safePositionMs, lifecycleDurationMs ?? 0)
    }

    @objc private func enterForeground() {
        guard mpv != nil else { return }
        let shouldResume = wasPlayingBeforeBackground
        setStringProperty("vid", "auto")
        clearCleanEndState()

        if let target = lifecyclePositionMs {
            foregroundRestoreTargetMs = target
            foregroundRestoreDeadline = Date().addingTimeInterval(4)
            let rawPositionMs = milliseconds(from: readDoubleProperty("time-pos"))
            if rawPositionMs == nil
                || abs((rawPositionMs ?? target) - target) > 1_500
                || getFlag("eof-reached") {
                seekToMs(target)
            }
        }

        isApplicationBackgrounded = false
        if shouldResume {
            playPlayback()
        } else {
            // Preserve an explicit user pause across app switching.
            pausePlayback()
        }
    }

    private func publishLifecycleSnapshot() {
        if let duration = lifecycleDurationMs, duration > 0 {
            durationMs = duration
        }
        if let position = lifecyclePositionMs {
            positionMs = position
            bufferedMs = max(bufferedMs, position)
        }
        hasCoherentTimeSample = durationMs > 0 && positionMs >= 0 && positionMs < durationMs
        isAtEndOfFile = false
        isPlayerLoading = false
        isPlayerPlaying = false
        isPlayerEnded = false
    }

    // MARK: - Playback API

    func loadFile(_ urlString: String) {
        pendingURL = urlString
        if Thread.isMainThread {
            attemptStartPendingLoad()
        } else {
            DispatchQueue.main.async { [weak self] in self?.attemptStartPendingLoad() }
        }
    }

    private func attemptStartPendingLoad() {
        guard let url = pendingURL, mpv != nil else { return }
        guard isViewLoaded, view.bounds.width > 1, view.bounds.height > 1 else { return }
        pendingURL = nil
        lifecyclePositionMs = nil
        lifecycleDurationMs = nil
        lastVerifiedPositionMs = nil
        lastVerifiedDurationMs = nil
        lastVerifiedWasPlaying = false
        foregroundRestoreTargetMs = nil
        foregroundRestoreDeadline = nil
        lifecycleRestoreFailed = false
        hasCoherentTimeSample = false
        isAtEndOfFile = false
        layoutMetalLayer()
        clearPlaybackError()
        resetDisplayCriteriaProbe()
        // Do not leave the prior title's HDR criteria active while this file
        // is loading. The new stream's own VIDEO_RECONFIG will apply fresh
        // criteria once its color parameters are known.
        clearDisplayCriteria()
        isPlayerLoading = true
        isPlayerEnded = false
        command("loadfile", args: [url, "replace"])
        setAspectMode(.fit)
    }

    func playPlayback() {
        guard mpv != nil else { return }
        lastVerifiedWasPlaying = true
        setFlag("pause", false)
    }

    func pausePlayback() {
        guard mpv != nil else { return }
        lastVerifiedWasPlaying = false
        setFlag("pause", true)
    }

    func seekToMs(_ ms: Int64) {
        guard mpv != nil else { return }
        rememberExplicitSeek(to: ms)
        command("seek", args: [String(format: "%.3f", Double(ms) / 1000.0), "absolute"])
    }

    func seekByMs(_ ms: Int64) {
        guard mpv != nil else { return }
        rememberExplicitSeek(to: positionMs + ms)
        command("seek", args: [String(format: "%.3f", Double(ms) / 1000.0), "relative"])
    }

    private func rememberExplicitSeek(to requestedMs: Int64) {
        let upperBound = durationMs > 0 ? max(durationMs - 1, 0) : Int64.max
        lastVerifiedPositionMs = min(max(requestedMs, 0), upperBound)
        if durationMs > 0 {
            lastVerifiedDurationMs = durationMs
        }
    }

    func setSpeed(_ speed: Float) {
        guard mpv != nil else { return }
        var s = Double(speed)
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &s)
    }

    /// Decoded video dimensions (0 until the first frame reports params).
    var videoFrameSize: CGSize {
        let w = getInt("video-params/w")
        let h = getInt("video-params/h")
        guard w > 1, h > 1 else { return .zero }
        return CGSize(width: w, height: h)
    }

    /// Actual profile parsed by FFmpeg from the selected HEVC track.
    var dolbyVisionProfile: Int {
        getInt("current-tracks/video/dolby-vision-profile")
    }

    /// AVPlayer must own the window's dynamic-range request while it presents
    /// the local Dolby Vision playlist.
    func suspendDisplayCriteriaForNativePlayback() {
        clearDisplayCriteria()
    }

    func restoreDisplayCriteriaAfterNativePlayback() {
        resetDisplayCriteriaProbe()
        scheduleDisplayCriteriaProbe()
    }

    /// Keep mpv in letterbox FIT. Fill/stretch are SwiftUI scaleEffect on the host.
    func setAspectMode(_ mode: PlayerAspectMode) {
        guard mpv != nil else { return }
        setDoubleProperty("video-zoom", 0)
        setDoubleProperty("video-pan-x", 0)
        setDoubleProperty("video-pan-y", 0)
        setDoubleProperty("panscan", 0)
        setFlag("keepaspect", true)
        setStringProperty("video-unscaled", "no")
        metalLayer.contentsGravity = .resize
        _ = mode
    }

    func setMuted(_ muted: Bool) {
        guard mpv != nil else { return }
        setFlag("mute", muted)
    }

    /// mpv `sub-delay`, in seconds; positive shows captions later.
    func setSubtitleDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        var value = seconds
        mpv_set_property(mpv, "sub-delay", MPV_FORMAT_DOUBLE, &value)
    }

    /// mpv `audio-delay`, in seconds; positive delays the audio.
    func setAudioDelay(_ seconds: Double) {
        guard mpv != nil else { return }
        var value = seconds
        mpv_set_property(mpv, "audio-delay", MPV_FORMAT_DOUBLE, &value)
    }

    /// PCM software amplification, expressed in dB. mpv's `volume` is a linear
    /// percentage (100 = unchanged), so convert: percent = 10^(dB/20) · 100.
    /// `volume-max` is raised at init so the full +10 dB (~316%) is allowed.
    func setAudioVolumeGain(dB: Double) {
        guard mpv != nil else { return }
        var value = pow(10.0, dB / 20.0) * 100.0
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &value)
    }

    // MARK: - Track selection

    func selectAudio(_ trackId: Int) {
        guard mpv != nil else { return }
        var id = Int64(trackId)
        mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &id)
    }

    func selectSubtitle(_ trackId: Int) {
        guard mpv != nil else { return }
        if trackId < 0 {
            setStringProperty("sid", "no")
        } else {
            var id = Int64(trackId)
            mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &id)
        }
    }

    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {
        guard mpv != nil else { return }
        command("sub-add", args: [
            subtitle.url,
            select ? "select" : "auto",
            subtitle.label ?? "",
            subtitle.language
        ])
    }

    func addAudioUrl(_ url: String) {
        pendingAudioURL = url
        guard mpv != nil, !isPlayerLoading else { return }
        attachPendingAudioIfNeeded()
    }

    private func attachPendingAudioIfNeeded() {
        guard let url = pendingAudioURL else { return }
        pendingAudioURL = nil
        command("audio-add", args: [url, "select"])
    }

    /// Pushes the user's saved subtitle appearance (Settings → Subtitle Style)
    /// into libmpv. Safe to call repeatedly — invoked once after init and again
    /// on every FILE_LOADED so the styling lands on each track that gets parsed.
    func applySubtitleStyle() {
        guard mpv != nil else { return }
        let style = SubtitleStyle.current
        setStringProperty("sub-scale", String(format: "%.3f", style.subScale))
        setStringProperty("sub-bold", style.bold ? "yes" : "no")
        setStringProperty("sub-outline-size", String(format: "%.3f", style.subOutlineSize))
        setStringProperty("sub-margin-y", String(style.subMarginY))
        setStringProperty("sub-margin-x", String(style.subMarginX))
        setStringProperty("sub-spacing", String(style.subSpacing))
        setStringProperty("sub-shadow-offset", "0")
        setStringProperty("sub-border-style", "outline-and-shadow")
        setStringProperty("sub-color", style.subColor)
        setStringProperty("sub-outline-color", style.subOutlineColor)
    }

    func destroyPlayer() {
        NotificationCenter.default.removeObserver(self)
        pendingURL = nil
        clearDisplayCriteria()
        clearPlaybackError()
        guard let ctx = mpv else { return }
        mpv = nil  // nil first so the event loop stops reading
        mpv_terminate_destroy(ctx)
    }

    // MARK: - State Update

    /// Lightweight state refresh — called by the view model poll (every 250ms).
    func refreshPlaybackState() {
        guard mpv != nil else { return }
        if isApplicationBackgrounded || lifecycleRestoreFailed {
            publishLifecycleSnapshot()
            return
        }

        let duration = readDoubleProperty("duration")
        let position = readDoubleProperty("time-pos")
        let cached = readDoubleProperty("demuxer-cache-time") ?? 0
        let speed = getDouble("speed")
        let paused = getFlag("pause")
        let eofReached = getFlag("eof-reached")
        let idle = getFlag("core-idle")
        let seeking = getFlag("seeking")
        let bufferingCache = getFlag("paused-for-cache")

        isAtEndOfFile = eofReached

        if let target = foregroundRestoreTargetMs {
            let sampledPositionMs = milliseconds(from: position)
            let restored = duration != nil
                && sampledPositionMs != nil
                && abs((sampledPositionMs ?? target) - target) <= 5_000
                && !eofReached

            if !restored {
                if let deadline = foregroundRestoreDeadline, Date() < deadline {
                    clearCleanEndState()
                    seekToMs(target)
                    publishLifecycleSnapshot()
                    return
                }

                // Never turn a failed lifecycle reattach into a completed
                // watch. Keep the verified snapshot and surface an error.
                setPlaybackError("Playback could not resume after returning to Nuvio.")
                lifecycleRestoreFailed = true
                publishLifecycleSnapshot()
                return
            }

            foregroundRestoreTargetMs = nil
            foregroundRestoreDeadline = nil
            lifecyclePositionMs = nil
            lifecycleDurationMs = nil
        }

        hasCoherentTimeSample = duration != nil && position != nil

        isPlayerLoading = (idle && !paused && !eofReached) || seeking || bufferingCache
        isPlayerPlaying = !paused && !idle && !eofReached
        // Accept completion only after MPV's END_FILE event explicitly reports
        // EOF. The eof-reached property can race ahead of an END_FILE error.
        isPlayerEnded = eofReached
            && didReachCleanEndOfFile
            && currentErrorMessage.isEmpty
            && hasCoherentTimeSample

        if let durationMs = milliseconds(from: duration),
           let positionMs = milliseconds(from: position) {
            let cachedMs = milliseconds(from: cached) ?? 0
            let previousPositionMs = lastVerifiedPositionMs
            let referenceDurationMs = max(durationMs, lastVerifiedDurationMs ?? 0)
            let implausibleEndJump = referenceDurationMs >= 60_000
                && positionMs >= referenceDurationMs - 5_000
                && (previousPositionMs ?? positionMs) < referenceDurationMs * 85 / 100
                && positionMs - (previousPositionMs ?? positionMs) > 30_000

            if implausibleEndJump, let previousPositionMs {
                lifecyclePositionMs = previousPositionMs
                lifecycleDurationMs = referenceDurationMs
                foregroundRestoreTargetMs = previousPositionMs
                foregroundRestoreDeadline = Date().addingTimeInterval(4)
                clearCleanEndState()
                seekToMs(previousPositionMs)
                publishLifecycleSnapshot()
                return
            }

            if !eofReached,
               positionMs >= 0,
               positionMs < durationMs,
               !implausibleEndJump {
                lastVerifiedPositionMs = positionMs
                lastVerifiedDurationMs = durationMs
                lastVerifiedWasPlaying = !paused && !idle
            }
            self.durationMs = durationMs
            self.positionMs = max(positionMs, 0)
            self.bufferedMs = max(positionMs + cachedMs, 0)
        }
        currentSpeed = Float(speed > 0 ? speed : 1.0)
    }

    func updateState() {
        refreshPlaybackState()
        refreshTracks()
    }

    private func refreshTracks() {
        guard mpv != nil else { return }
        var audio = [TrackInfo]()
        var subs = [TrackInfo]()
        let count = getInt("track-list/count")
        var audioIdx = 0
        var subIdx = 0

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            let id = getInt("track-list/\(i)/id")
            let title = getTrackString(i, "title")
            let lang = getTrackString(i, "lang")
            let codec = getTrackString(i, "codec")
            let channelCount = getInt("track-list/\(i)/demux-channel-count")
            let selected = getFlag("track-list/\(i)/selected")
            let externalFilename = getTrackString(i, "external-filename")

            if type == "audio" {
                let sampleRate = getInt("track-list/\(i)/demux-samplerate")
                let languageName = Self.localizedLanguageName(lang)
                let display = Self.audioTrackName(title: title, languageName: languageName,
                                                  codec: codec, channelCount: channelCount,
                                                  fallback: "Track \(audioIdx + 1)")
                let detail = Self.audioTrackDetail(codec: codec, channels: channelCount, sampleRate: sampleRate)
                audio.append(TrackInfo(index: audioIdx, id: id, type: type, title: display, lang: lang,
                                       selected: selected, externalFilename: externalFilename,
                                       languageName: languageName, detail: detail))
                audioIdx += 1
            } else if type == "sub" {
                let display = trackTitle(title: title, lang: lang, codec: codec,
                                         channelCount: 0, fallback: "Subtitle \(subIdx + 1)")
                subs.append(TrackInfo(index: subIdx, id: id, type: type, title: display, lang: lang,
                                      selected: selected, externalFilename: externalFilename))
                subIdx += 1
            }
        }
        audioTracks = audio
        subtitleTracks = subs
    }

    private func getTrackString(_ index: Int, _ field: String) -> String {
        (getString("track-list/\(index)/\(field)") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trackTitle(title: String, lang: String, codec: String,
                            channelCount: Int, fallback: String) -> String {
        let base: String
        if !title.isEmpty {
            base = title
        } else if !lang.isEmpty {
            base = Locale.current.localizedString(forLanguageCode: lang) ?? lang
        } else {
            base = fallback
        }
        var details: [String] = []
        if channelCount == 2 { details.append("Stereo") }
        else if channelCount == 6 { details.append("5.1") }
        else if channelCount == 8 { details.append("7.1") }
        else if channelCount > 0 { details.append("\(channelCount)ch") }
        if !codec.isEmpty { details.append(codec.uppercased()) }
        let filtered = details.filter { !base.localizedCaseInsensitiveContains($0) }
        return filtered.isEmpty ? base : "\(base) (\(filtered.joined(separator: ", ")))"
    }

    /// Audio card title: the track's own name (or language) with a codec +
    /// channel-layout summary in parens — "LostFilm (AC-3 Stereo)".
    private static func audioTrackName(title: String, languageName: String,
                                       codec: String, channelCount: Int, fallback: String) -> String {
        let base: String
        if !title.isEmpty { base = title }
        else if !languageName.isEmpty { base = languageName }
        else { base = fallback }

        let summary = [prettyCodec(codec), channelLayout(channelCount)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return summary.isEmpty ? base : "\(base) (\(summary))"
    }

    /// Audio card detail line — "AC-3 | 6 ch | 48 kHz". Omits missing pieces.
    private static func audioTrackDetail(codec: String, channels: Int, sampleRate: Int) -> String {
        var parts: [String] = []
        let pretty = prettyCodec(codec)
        if !pretty.isEmpty { parts.append(pretty) }
        if channels > 0 { parts.append("\(channels) ch") }
        if sampleRate > 0 { parts.append("\(Int((Double(sampleRate) / 1000.0).rounded())) kHz") }
        return parts.joined(separator: " | ")
    }

    private static func localizedLanguageName(_ lang: String) -> String {
        let trimmed = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let name = Locale.current.localizedString(forLanguageCode: trimmed.lowercased()) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// Human channel layout name; falls back to a raw count.
    private static func channelLayout(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let n where n > 0: return "\(n)ch"
        default: return ""
        }
    }

    /// Displays common audio codecs the way listeners recognize them.
    private static func prettyCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "dts": return "DTS"
        case "dts-hd", "dtshd": return "DTS-HD"
        case "truehd": return "TrueHD"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "mp3": return "MP3"
        case "pcm", "pcm_s16le", "pcm_s24le": return "PCM"
        case "": return ""
        default: return codec.uppercased()
        }
    }

    // MARK: - Display mode matching (frame rate + HDR)
    //
    // tvOS never switches the HDMI output to HDR just because a Metal layer
    // renders PQ/HLG content — only AVFoundation players get that for free.
    // When "Match Content → Dynamic Range" is enabled on the Apple TV, apps
    // must request the switch through AVDisplayManager. tvOS 17 added a public
    // AVDisplayCriteria initializer, so build a format description carrying the
    // stream's color tags and hand it to the window. SDR streams must go through
    // the same path when Nuvio's Frame Rate Matching setting is enabled; gating
    // criteria on HDR alone leaves 23.976/24 fps SDR video juddering at 60 Hz.

    /// `-[UIWindow avDisplayManager]` is an ObjC *category* from AVKit: calling
    /// it creates no link-time symbol reference, so the linker drops AVKit from
    /// the binary and the selector doesn't exist at runtime (crashed on device
    /// with "unrecognized selector"). Referencing a real AVKit class forces the
    /// framework to be linked and loaded.
    private static let avKitLinkAnchor: AnyClass = AVDisplayManager.self

    /// The window we last set criteria on; doubles as the "criteria active" flag.
    private weak var displayCriteriaWindow: UIWindow?
    /// Criteria are applied at most once per loaded file (reset in
    /// `attemptStartPendingLoad`). Re-running on every VIDEO_RECONFIG would
    /// re-trigger HDMI mode switches — including the RECONFIG our own
    /// detach/reattach dance produces.
    private var didApplyDisplayCriteria = false
    /// True while the HDMI mode switch is settling and video is detached.
    private var isDisplaySwitchInFlight = false
    /// `VIDEO_RECONFIG` may arrive before SwiftUI has attached this controller
    /// to a window, or before MPV has populated the stream dimensions. Keep a
    /// short, coalesced probe alive for those races so HDR does not silently
    /// stay in SDR on a physical Apple TV.
    private var displayCriteriaProbeGeneration = 0
    private var displayCriteriaProbeAttempts = 0
    private var isDisplayCriteriaProbeScheduled = false
    private static let maximumDisplayCriteriaProbeAttempts = 15

    private enum DisplayCriteriaUpdateResult {
        case appliedOrAlreadyActive
        case retry
        case finished
    }

    private func resetDisplayCriteriaProbe() {
        displayCriteriaProbeGeneration &+= 1
        displayCriteriaProbeAttempts = 0
        isDisplayCriteriaProbeScheduled = false
    }

    private func scheduleDisplayCriteriaProbe(after delay: TimeInterval = 0) {
        #if !targetEnvironment(simulator)
        guard mpv != nil,
              !didApplyDisplayCriteria,
              !isDisplaySwitchInFlight,
              !isDisplayCriteriaProbeScheduled else { return }

        let generation = displayCriteriaProbeGeneration
        isDisplayCriteriaProbeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.displayCriteriaProbeGeneration else { return }
            self.isDisplayCriteriaProbeScheduled = false
            self.probeDisplayCriteria(generation: generation)
        }
        #endif
    }

    private func probeDisplayCriteria(generation: Int) {
        #if !targetEnvironment(simulator)
        guard generation == displayCriteriaProbeGeneration else { return }

        switch updateDisplayCriteria() {
        case .retry:
            guard displayCriteriaProbeAttempts < Self.maximumDisplayCriteriaProbeAttempts else {
                print("[MPV] HDR display switch skipped: video parameters did not become ready")
                return
            }
            displayCriteriaProbeAttempts += 1
            scheduleDisplayCriteriaProbe(after: 0.2)
        case .appliedOrAlreadyActive, .finished:
            break
        }
        #endif
    }

    private func updateDisplayCriteria() -> DisplayCriteriaUpdateResult {
        // AVDisplayManager isn't in the simulator SDK (there's no HDMI output
        // to switch); this whole path is device-only.
        #if !targetEnvironment(simulator)
        guard #available(tvOS 17.0, *) else { return .finished }
        guard mpv != nil, !isDisplaySwitchInFlight else { return .finished }

        let gamma = (getString("video-params/gamma") ?? "").lowercased()
        let primaries = (getString("video-params/primaries") ?? "").lowercased()
        // Dolby Vision Profile 5 can initially present as BT.709 rather than
        // PQ in video-params. Read the selected track's container metadata
        // before the HDR gate so it is not incorrectly dismissed as SDR.
        let dolbyVisionProfile = getInt("current-tracks/video/dolby-vision-profile")
        let dolbyVisionLevel = getInt("current-tracks/video/dolby-vision-level")
        let isDolbyVision = dolbyVisionProfile > 0

        // No video attached (e.g. our own `vid=no`, or backgrounding): leave
        // whatever criteria are in place alone.
        guard !gamma.isEmpty || !primaries.isEmpty else { return .retry }

        // MPV/FFmpeg have used both concise ("pq" / "hlg") and standards
        // names (ST 2084 / ARIB B-67) for the same transfer functions.
        let isHLG = gamma.contains("hlg") || gamma.contains("b67") || gamma.contains("arib")
        let isPQ = gamma.contains("pq") || gamma.contains("2084")
        let isHDR = isDolbyVision || isPQ || isHLG || primaries.contains("2020")
        let frameRateMode = ProfileSettings.current.string(forKey: SettingsKey.frameRateMatching) ?? "Always"
        let shouldMatchFrameRate = frameRateMode.caseInsensitiveCompare("Off") != .orderedSame
        guard isHDR || shouldMatchFrameRate else {
            clearDisplayCriteria()
            return .finished
        }
        guard !didApplyDisplayCriteria else { return .appliedOrAlreadyActive }
        guard let window = view.window else { return .retry }
        // Skip (SDR playback, no crash) rather than abort if the category is
        // ever missing again — e.g. a future tvOS removing it.
        _ = Self.avKitLinkAnchor
        guard window.responds(to: NSSelectorFromString("avDisplayManager")) else {
            print("[MPV] AVDisplayManager unavailable; HDR display switch skipped")
            return .finished
        }

        let width = getInt("video-params/w")
        let height = getInt("video-params/h")
        guard width > 0, height > 0 else { return .retry }

        var fps = getDouble("container-fps")
        if fps <= 0 { fps = getDouble("estimated-vf-fps") }
        if fps <= 0 { fps = 23.976 }

        // `video-format` is the decoded pixel format, not the encoded stream
        // codec. Use the selected track so AV1 HDR is not described as HEVC.
        let videoCodec = (getString("current-tracks/video/codec") ?? "").lowercased()
        let codecType: CMVideoCodecType
        switch videoCodec {
        case "h264": codecType = kCMVideoCodecType_H264
        case "av1": codecType = kCMVideoCodecType_AV1
        default: codecType = kCMVideoCodecType_HEVC
        }

        let extensions: [CFString: Any]
        if isHDR {
            let transfer: CFString = isHLG
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: transfer,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            ]
        }

        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            print("[MPV] Failed to build HDR format description (\(status))")
            return .finished
        }

        // This is parsed from the stream itself, unlike a source title such as
        // "4K WEBRip". Dolby Vision needs its per-frame metadata delivered by
        // the decoder/output path; the MPV Metal renderer cannot manufacture
        // that metadata for AVDisplayManager, so its compatible HDR10/PQ base
        // layer is requested here instead. The log makes the exact profile
        // visible on-device without incorrectly claiming a Dolby Vision output.
        let sourceRange: String
        // Honest labeling: MPV cannot emit native Dolby Vision over HDMI —
        // this path is the Android-equivalent STRIP_TO_HDR10 / PQ fallback.
        if isDolbyVision {
            sourceRange = "Dolby Vision profile \(dolbyVisionProfile), level \(dolbyVisionLevel) → HDR10/PQ (not native DV)"
        } else if isHLG {
            sourceRange = "HLG"
        } else if isHDR {
            sourceRange = "HDR10/PQ"
        } else {
            sourceRange = "SDR"
        }
        if isHDR {
            let targetTRC = isHLG ? "hlg" : "pq"
            // Keep the renderer's output colorimetry identical to the format
            // description sent to tvOS. Leaving these on `auto` can adapt a wide
            // gamut source to BT.709 and then have the TV interpret it as BT.2020,
            // which exaggerates reds, oranges, and skin tones.
            setStringProperty("target-prim", "bt.2020")
            setStringProperty("target-trc", targetTRC)
        } else {
            setStringProperty("target-prim", "auto")
            setStringProperty("target-trc", "auto")
        }
        print("[MPV] Display request: \(sourceRange); frameRateMode=\(frameRateMode), codec=\(videoCodec.isEmpty ? "unknown" : videoCodec), gamma=\(gamma), primaries=\(primaries), \(width)x\(height) @ \(fps)fps")

        // The HDMI mode switch tears down and rebuilds the display pipeline.
        // Presenting Vulkan frames into the CAMetalLayer while that happens
        // crashes MoltenVK, so idle mpv's video chain first (the same
        // detach/reattach the background/foreground path already survives),
        // request the switch, and only reattach once the switch has settled.
        didApplyDisplayCriteria = true
        isDisplaySwitchInFlight = true
        setStringProperty("vid", "no")

        let manager = window.avDisplayManager
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps),
            formatDescription: formatDescription
        )
        displayCriteriaWindow = window

        // Give the switch a beat to start before polling for completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reattachVideoWhenDisplaySettled(manager, attemptsLeft: 16)
        }
        return .appliedOrAlreadyActive
        #else
        return .finished
        #endif
    }

    #if !targetEnvironment(simulator)
    private func reattachVideoWhenDisplaySettled(_ manager: AVDisplayManager, attemptsLeft: Int) {
        guard mpv != nil else {
            isDisplaySwitchInFlight = false
            return
        }
        if manager.isDisplayModeSwitchInProgress && attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.reattachVideoWhenDisplaySettled(manager, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        isDisplaySwitchInFlight = false
        setStringProperty("vid", "auto")
    }
    #endif

    private func clearDisplayCriteria() {
        #if !targetEnvironment(simulator)
        displayCriteriaWindow?.avDisplayManager.preferredDisplayCriteria = nil
        displayCriteriaWindow = nil
        didApplyDisplayCriteria = false
        if mpv != nil {
            setStringProperty("target-prim", "auto")
            setStringProperty("target-trc", "auto")
        }
        #endif
    }

    // MARK: - Error tracking

    private func clearPlaybackError() {
        errorStateLock.lock()
        recentPlaybackLogs.removeAll(keepingCapacity: true)
        _currentErrorMessage = nil
        _didReachCleanEndOfFile = false
        errorStateLock.unlock()
    }

    private func clearCleanEndState() {
        errorStateLock.lock()
        _didReachCleanEndOfFile = false
        errorStateLock.unlock()
    }

    private func setCleanEndState(_ reachedEOF: Bool) {
        errorStateLock.lock()
        _didReachCleanEndOfFile = reachedEOF
        errorStateLock.unlock()
    }

    private func appendPlaybackLog(prefix: String, level: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard level == "warn" || level == "error" || level == "fatal" else { return }
        errorStateLock.lock()
        recentPlaybackLogs.append("[\(prefix)] \(trimmed)")
        if recentPlaybackLogs.count > 4 {
            recentPlaybackLogs.removeFirst(recentPlaybackLogs.count - 4)
        }
        errorStateLock.unlock()
    }

    private func setPlaybackError(_ fallback: String) {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        errorStateLock.lock()
        _didReachCleanEndOfFile = false
        var parts = recentPlaybackLogs.suffix(3)
        if !trimmedFallback.isEmpty && !parts.contains(trimmedFallback) {
            parts.append(trimmedFallback)
        }
        _currentErrorMessage = parts.isEmpty ? "Unable to play this stream." : parts.joined(separator: "\n")
        errorStateLock.unlock()
    }

    // MARK: - Event Loop

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                let event = mpv_wait_event(mpv, 0)
                guard let eventPtr = event else { break }
                if eventPtr.pointee.event_id == MPV_EVENT_NONE { break }

                switch eventPtr.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    DispatchQueue.main.async { self.updateState() }
                case MPV_EVENT_START_FILE:
                    self.clearPlaybackError()
                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async {
                        self.clearPlaybackError()
                        guard !self.rejectUnsupportedSimulatorCodecIfNeeded() else { return }
                        self.isPlayerLoading = false
                        self.attachPendingAudioIfNeeded()
                        self.applySubtitleStyle()
                        self.setAspectMode(.fit)
                        self.updateState()
                        self.resetDisplayCriteriaProbe()
                        self.scheduleDisplayCriteriaProbe()
                    }
                case MPV_EVENT_VIDEO_RECONFIG:
                    // Fires once decode starts and whenever the video params
                    // change — the earliest point video-params/* is reliable.
                    // A short retry covers the race where it fires before the
                    // view is attached to a UIWindow on physical Apple TV.
                    DispatchQueue.main.async { self.scheduleDisplayCriteriaProbe() }
                case MPV_EVENT_END_FILE:
                    if let data = eventPtr.pointee.data {
                        let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                        if endFile.reason == MPV_END_FILE_REASON_EOF {
                            self.setCleanEndState(true)
                        } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorText = String(cString: mpv_error_string(endFile.error))
                            self.setPlaybackError("[mpv] \(errorText)")
                            print("[MPV] End file error: \(errorText)")
                        } else {
                            self.setCleanEndState(false)
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(eventPtr.pointee.data)) {
                        let prefix = String(cString: msg.pointee.prefix!)
                        let level = String(cString: msg.pointee.level!)
                        let text = String(cString: msg.pointee.text!)
                        self.appendPlaybackLog(prefix: prefix, level: level, text: text)
                        print("[MPV][\(prefix)] \(level): \(text)", terminator: "")
                    }
                default:
                    break
                }
            }
        }
    }

    /// MoltenVK on the tvOS simulator can eventually trap while uploading an
    /// AV1 software-decoded frame through MTLSim shared memory. Stream labels
    /// are filtered before selection, but this verifies the actual container
    /// codec as a final safety net for unlabeled direct URLs.
    private func rejectUnsupportedSimulatorCodecIfNeeded() -> Bool {
        #if targetEnvironment(simulator)
        let codec = (getString("current-tracks/video/codec") ?? "").lowercased()
        guard codec == "av1" || codec == "av01" else { return false }

        setStringProperty("vid", "no")
        command("stop", checkForErrors: false)
        setPlaybackError("AV1 playback is unavailable in the Apple TV Simulator. Choose an H.264 or HEVC stream.")
        isPlayerLoading = false
        isPlayerPlaying = false
        isPlayerEnded = false
        return true
        #else
        return false
        #endif
    }

    // MARK: - MPV Helpers

    private func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) {
        guard mpv != nil else { return }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        let ret = mpv_command(mpv, &cargs)
        if checkForErrors { checkError(ret) }
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        return strArgs
    }

    private func readDoubleProperty(_ name: String) -> Double? {
        guard mpv != nil else { return nil }
        var data = Double()
        let result = mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        guard result >= 0, data.isFinite else { return nil }
        return data
    }

    private func getDouble(_ name: String) -> Double {
        readDoubleProperty(name) ?? 0
    }

    private func milliseconds(from seconds: Double?) -> Int64? {
        guard let seconds,
              seconds.isFinite,
              seconds >= 0,
              seconds <= Double(Int64.max) / 1000 else { return nil }
        return Int64(seconds * 1000)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        let str: String? = cstr == nil ? nil : String(cString: cstr!)
        mpv_free(cstr)
        return str
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func setStringProperty(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        checkError(mpv_set_property_string(mpv, name, value))
    }

    private func setDoubleProperty(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var data = value
        checkError(mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data))
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            print("[MPV] API error: \(String(cString: mpv_error_string(status)))")
        }
    }
}

// MARK: - Metal Layer

final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
