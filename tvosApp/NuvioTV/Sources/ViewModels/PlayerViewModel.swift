import Foundation
import Combine
import SwiftUI
import UIKit
import AVFoundation
import AVKit
import CoreMedia
import Libmpv

// MARK: - PlayerViewModel (MPV-backed)
//
// Drives playback through libmpv (gpu-next / VideoToolbox) instead of AVPlayer
// so that the universe of Stremio addon streams — MKV containers, AC3/EAC3/DTS
// audio, HEVC/AV1, etc. — actually plays on tvOS. AVPlayer rejected most of
// these with the "prohibitory" sign; MPV decodes them natively and fast.
//
// The published surface is kept identical to the old AVPlayer view model so the
// existing PlayerControls / settings sheet keep working unchanged.

@MainActor
class PlayerViewModel: ObservableObject {
    @Published var status: PlayerStatus = .idle
    @Published var time: PlayerTime = PlayerTime()
    @Published var subtitles: [SubtitleTrack] = []
    @Published var audioTracks: [AudioTrack] = []
    @Published var playbackSpeed: PlaybackSpeed = .normal
    @Published var qualities: [QualityOption] = [.auto]
    @Published var currentQuality: QualityOption = .auto
    @Published var showControls: Bool = true
    @Published var title: String = ""
    @Published var subtitle: String = ""

    /// The UIKit view controller that owns the Metal surface MPV renders into.
    /// PlayerView hosts this via a UIViewControllerRepresentable.
    let playerController = MPVPlayerViewController()

    private var pollTimer: Timer?
    private var controlsHideTimer: Timer?
    private var hasLoaded = false
    private var didShutdown = false
    private var activeMeta: NuvioMeta?
    private var activeStreamURL: String?
    private var pendingResumeSeconds: Double?
    private var didApplyResume = false
    private var pendingExternalSubtitles: [NuvioSubtitle] = []
    private var didAddExternalSubtitles = false
    private var didApplySubtitlePreference = false
    private var lastProgressSave = Date.distantPast
    private var controlsAutoHideSuspended = false

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

    deinit {
        let controller = playerController
        let poll = pollTimer
        let hide = controlsHideTimer
        trailerResolveTask?.cancel()
        Task { @MainActor in
            poll?.invalidate()
            hide?.invalidate()
            controller.destroyPlayer()
        }
    }

    func load(url: URL, meta: NuvioMeta, subtitle: String, externalSubtitles: [NuvioSubtitle] = [], resumeFrom: Double?) {
        let isTrailerPlayback = subtitle == PlaybackMarkers.trailerSubtitle
        self.title = meta.name
        self.subtitle = subtitle
        self.status = .buffering
        self.activeMeta = meta
        self.activeStreamURL = url.absoluteString
        self.pendingResumeSeconds = isTrailerPlayback ? nil : resumeFrom
        self.expectedDurationSeconds = isTrailerPlayback ? nil : Self.expectedDuration(for: meta)
        self.didDetectReplacementStream = false
        self.replacementStreamHits = 0
        self.pendingExternalSubtitles = externalSubtitles
        self.didAddExternalSubtitles = externalSubtitles.isEmpty
        self.didApplySubtitlePreference = false
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
                    self.playerController.loadFile(playbackSource.videoUrl)
                    if let audioUrl = playbackSource.audioUrl {
                        self.playerController.addAudioUrl(audioUrl)
                    }
                    self.startPolling()
                }
            }
            return
        }

        playerController.loadFile(url.absoluteString)
        startPolling()
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
        let c = playerController
        c.refreshPlaybackState()

        time = PlayerTime(
            current: Double(c.positionMs) / 1000.0,
            duration: Double(c.durationMs) / 1000.0
        )

        // An expired stream link is often answered with a short "slate" clip
        // (e.g. ElfHosted's "Link expired" video) that decodes cleanly, so it
        // never trips the mpv-error guard. Bail before any Continue Watching
        // write/clear so it can't overwrite or delete the real resume point.
        if subtitle != PlaybackMarkers.trailerSubtitle, detectReplacementStream(c) { return }

        applyPendingResumeIfNeeded()
        addPendingExternalSubtitlesIfNeeded()

        if c.isPlayerEnded {
            if let activeMeta, subtitle != PlaybackMarkers.trailerSubtitle {
                ContinueWatchingStore.remove(metaId: activeMeta.id)
                WatchedStore.markWatched(activeMeta)
            }
        } else {
            saveProgressIfNeeded()
        }

        // Don't clobber an explicit error state.
        if case .error = status { return }

        let previousStatus = status

        if !c.currentErrorMessage.isEmpty {
            status = .error(c.currentErrorMessage)
        } else if c.isPlayerEnded {
            status = .ended
        } else if c.isPlayerLoading {
            status = .buffering
        } else if c.isPlayerPlaying {
            status = .playing
        } else {
            status = .paused
        }

        // The controls are shown on launch (showControls defaults to true) but the
        // auto-hide timer is only armed by user transport actions. Arm it whenever
        // playback (re)starts so the initial controls fade on their own — without
        // this they linger until the user manually pauses/resumes. The scheduled
        // timer no-ops if controls are already hidden or auto-hide is suspended.
        if status == .playing, previousStatus != .playing, showControls {
            scheduleControlsHide()
        }

        playbackSpeed = PlaybackSpeed(rawValue: c.currentSpeed) ?? playbackSpeed
        syncTracks()
    }

    private func syncTracks() {
        let c = playerController

        audioTracks = c.audioTracks.map {
            AudioTrack(id: "\($0.id)", name: $0.title,
                       language: $0.lang, isSelected: $0.selected)
        }

        var subs = c.subtitleTracks.map {
            SubtitleTrack(id: "\($0.id)", name: $0.title,
                          language: $0.lang, isSelected: $0.selected)
        }
        let anySelected = subs.contains { $0.isSelected }
        subs.insert(SubtitleTrack(id: "off", name: "Off", language: "",
                                  isSelected: !anySelected), at: 0)
        subtitles = subs
        applySubtitlePreferenceIfNeeded()
    }

    // MARK: - Transport

    func play() {
        if status == .ended { seek(to: 0) }
        playerController.playPlayback()
        status = .playing
        showControls = true
        scheduleControlsHide()
    }

    func pause() {
        playerController.pausePlayback()
        status = .paused
        showControls = true
        saveProgress(force: true)
        scheduleControlsHide()
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        pollTimer?.invalidate()
        pollTimer = nil
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        trailerResolveTask?.cancel()
        trailerResolveTask = nil
        playerController.pausePlayback()
        saveProgress(force: true)
        playerController.destroyPlayer()
        status = .idle
    }

    func togglePlayPause() {
        if status == .playing { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        playerController.seekToMs(Int64(seconds * 1000))
    }

    func skipForward() {
        playerController.seekByMs(15_000)
        showControls = true
        scheduleControlsHide()
    }

    func skipBackward() {
        playerController.seekByMs(-15_000)
        showControls = true
        scheduleControlsHide()
    }

    func setSpeed(_ speed: PlaybackSpeed) {
        playbackSpeed = speed
        playerController.setSpeed(speed.rawValue)
    }

    func applySubtitleStyle() {
        playerController.applySubtitleStyle()
    }

    // MARK: - Track selection

    func selectSubtitle(_ track: SubtitleTrack) {
        if track.id == "off" {
            playerController.selectSubtitle(-1)
        } else if let id = Int(track.id) {
            playerController.selectSubtitle(id)
        }
        subtitles = subtitles.map { var t = $0; t.isSelected = (t.id == track.id); return t }
    }

    private func addPendingExternalSubtitlesIfNeeded() {
        guard !didAddExternalSubtitles, !pendingExternalSubtitles.isEmpty else { return }
        pendingExternalSubtitles.forEach { subtitle in
            playerController.addSubtitleUrl(subtitle.url)
        }
        didAddExternalSubtitles = true
    }

    private func applySubtitlePreferenceIfNeeded() {
        guard !didApplySubtitlePreference else { return }
        guard ProfileSettings.current.bool(forKey: SettingsKey.smartSubtitleMatching) else { return }

        let preferredLanguages = SubtitleLanguagePreferences.orderedFromDefaults()
        guard !preferredLanguages.isEmpty else {
            didApplySubtitlePreference = true
            return
        }

        var matchingTrack: SubtitleTrack?
        for language in preferredLanguages {
            matchingTrack = subtitles.first { track in
                track.id != "off" &&
                (SubtitleLanguagePreferences.matches(track.language, target: language) ||
                 SubtitleLanguagePreferences.matches(track.name, target: language))
            }
            if matchingTrack != nil { break }
        }
        guard let matchingTrack else { return }

        didApplySubtitlePreference = true
        selectSubtitle(matchingTrack)
    }

    func selectAudio(_ track: AudioTrack) {
        if let id = Int(track.id) {
            playerController.selectAudio(id)
        }
        audioTracks = audioTracks.map { var t = $0; t.isSelected = (t.id == track.id); return t }
    }

    // MARK: - Controls visibility

    func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.controlsAutoHideSuspended else { return }
                if self.status == .playing || self.status == .paused {
                    self.showControls = false
                }
            }
        }
    }

    func toggleControls() {
        showControls.toggle()
        if showControls { scheduleControlsHide() }
    }

    func revealControls() {
        showControls = true
        if status == .playing || status == .paused {
            scheduleControlsHide()
        }
    }

    func setControlsAutoHideSuspended(_ suspended: Bool) {
        controlsAutoHideSuspended = suspended
        if suspended {
            controlsHideTimer?.invalidate()
            showControls = true
        } else if showControls {
            scheduleControlsHide()
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
        guard let activeMeta,
              let activeStreamURL,
              time.duration > 0,
              subtitle != PlaybackMarkers.trailerSubtitle,
              !loadedStreamLooksLikeReplacement(),
              force || time.current >= 10 else {
            return
        }

        ContinueWatchingStore.save(
            meta: activeMeta,
            streamUrl: activeStreamURL,
            position: time.current,
            duration: time.duration
        )
        lastProgressSave = Date()
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
    private func detectReplacementStream(_ c: MPVPlayerViewController) -> Bool {
        if didDetectReplacementStream { return true }

        // Judge only once the file has loaded; while opening, mpv reports a
        // zero/partial duration that would read as a false mismatch.
        guard !c.isPlayerLoading, loadedStreamLooksLikeReplacement() else {
            replacementStreamHits = 0
            return false
        }

        replacementStreamHits += 1
        guard replacementStreamHits >= Self.replacementConfirmTicks else { return false }

        didDetectReplacementStream = true
        playerController.pausePlayback()
        status = .error("This stream link has expired. Go back and start it again to load a fresh stream.")
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

// MARK: - Track Info

struct TrackInfo {
    let index: Int
    let id: Int
    let type: String
    let title: String
    let lang: String
    let selected: Bool
}

// MARK: - Network buffer sizing

/// libmpv network-cache sizes, driven by Settings → Playback → Network Cache.
/// `forwardBuffer` is how far ahead mpv prefetches ("preload"); `backBuffer`
/// keeps already-played data resident for instant backward seeks. Values are
/// libmpv bytesize strings (e.g. `"1024MiB"`).
///
/// The buffer is a cap, not a fixed allocation, but it fills fastest on exactly
/// the heavy content (fast host, high-bitrate 4K) where tvOS is most likely to
/// jetsam the app. "Large" opts into the full 1 GB regardless; "Auto" scales the
/// ceiling to the device's RAM so a 2 GB Apple TV HD isn't pushed toward an OOM
/// kill while a 4 GB Apple TV 4K still gets the big preload.
struct PlaybackCacheSettings {
    let forwardBuffer: String
    let backBuffer: String

    static var current: PlaybackCacheSettings {
        switch ProfileSettings.current.string(forKey: SettingsKey.networkCache) ?? "Auto" {
        case "Small":
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        case "Medium":
            return PlaybackCacheSettings(forwardBuffer: "512MiB", backBuffer: "128MiB")
        case "Large":
            return PlaybackCacheSettings(forwardBuffer: "1024MiB", backBuffer: "256MiB")
        default:
            return auto
        }
    }

    /// Ceiling scaled to total device RAM (`physicalMemory` is bytes):
    /// > 3.5 GB → 1 GB, ~3 GB → 512 MiB, ≤ 2 GB (Apple TV HD) → 256 MiB.
    private static var auto: PlaybackCacheSettings {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gib > 3.5 {
            return PlaybackCacheSettings(forwardBuffer: "1024MiB", backBuffer: "256MiB")
        } else if gib > 2.5 {
            return PlaybackCacheSettings(forwardBuffer: "512MiB", backBuffer: "128MiB")
        } else {
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        }
    }
}

// MARK: - MPV Player View Controller (tvOS)
//
// Self-contained libmpv host. Ported from the iOS bridge, with the Kotlin/
// Compose plumbing and iOS-only UIViewController overrides (home indicator,
// status-bar, screen-edge gestures — none exist on tvOS) removed.

final class MPVPlayerViewController: UIViewController {

    private static let defaultAudioOutput = "audiounit"

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
    var durationMs: Int64 = 0
    var positionMs: Int64 = 0
    var bufferedMs: Int64 = 0
    var currentSpeed: Float = 1.0
    var currentErrorMessage: String {
        errorStateLock.lock(); defer { errorStateLock.unlock() }
        return _currentErrorMessage ?? ""
    }
    private var _currentErrorMessage: String?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        metalLayer.contentsGravity = .resizeAspect
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
        checkError(mpv_set_option_string(mpv, "audio-channels", "auto"))
        checkError(mpv_set_option_string(mpv, "audio-fallback-to-null", "yes"))

        // Network buffering. Stremio/debrid links are bursty and often throttle,
        // so prefetch aggressively: `demuxer-max-bytes` is the forward ("preload")
        // buffer — up to ~1 GB by default — and `demuxer-max-back-bytes` keeps
        // already-played data so backward seeks are instant instead of re-fetched.
        // `cache-secs`/`demuxer-readahead-secs` are set high enough that the byte
        // caps, not a time window, are what bound how much gets pulled ahead. Sizes
        // follow Settings → Playback → Network Cache.
        let cache = PlaybackCacheSettings.current
        checkError(mpv_set_option_string(mpv, "cache", "yes"))
        checkError(mpv_set_option_string(mpv, "cache-secs", "3600"))
        checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "3600"))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", cache.forwardBuffer))
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", cache.backBuffer))
        checkError(mpv_set_option_string(mpv, "vulkan-swap-mode", "fifo"))
        checkError(mpv_set_option_string(mpv, "vulkan-queue-count", "1"))
        checkError(mpv_set_option_string(mpv, "vulkan-async-compute", "no"))
        checkError(mpv_set_option_string(mpv, "vulkan-async-transfer", "no"))
        checkError(mpv_set_option_string(mpv, "vulkan-disable-interop", "yes"))
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        checkError(mpv_set_option_string(mpv, "subs-match-os-language", "yes"))
        checkError(mpv_set_option_string(mpv, "subs-fallback", "yes"))
        // Honor the user's saved subtitle appearance on every track, including
        // embedded ASS/SSA (without `yes` mpv would ignore our color/size there),
        // and let `sub-margin-y` lift captions off the bottom edge.
        checkError(mpv_set_option_string(mpv, "sub-ass-override", "yes"))
        checkError(mpv_set_option_string(mpv, "sub-use-margins", "yes"))
        checkError(mpv_set_option_string(mpv, "sub-ass-force-margins", "yes"))
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))
        checkError(mpv_set_option_string(mpv, "target-colorspace-hint", "yes"))
        checkError(mpv_set_option_string(mpv, "tone-mapping", "auto"))
        checkError(mpv_set_option_string(mpv, "hdr-compute-peak", "yes"))
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
        pausePlayback()
        setStringProperty("vid", "no")
    }

    @objc private func enterForeground() {
        guard mpv != nil else { return }
        setStringProperty("vid", "auto")
        playPlayback()
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
        layoutMetalLayer()
        clearPlaybackError()
        didApplyDisplayCriteria = false
        isPlayerLoading = true
        isPlayerEnded = false
        command("loadfile", args: [url, "replace"])
    }

    func playPlayback() {
        guard mpv != nil else { return }
        setFlag("pause", false)
    }

    func pausePlayback() {
        guard mpv != nil else { return }
        setFlag("pause", true)
    }

    func seekToMs(_ ms: Int64) {
        guard mpv != nil else { return }
        command("seek", args: [String(format: "%.3f", Double(ms) / 1000.0), "absolute"])
    }

    func seekByMs(_ ms: Int64) {
        guard mpv != nil else { return }
        command("seek", args: [String(format: "%.3f", Double(ms) / 1000.0), "relative"])
    }

    func setSpeed(_ speed: Float) {
        guard mpv != nil else { return }
        var s = Double(speed)
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &s)
    }

    func setMuted(_ muted: Bool) {
        guard mpv != nil else { return }
        setFlag("mute", muted)
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

    func addSubtitleUrl(_ url: String) {
        guard mpv != nil else { return }
        command("sub-add", args: [url, "select"])
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
        let duration = getDouble("duration")
        let position = getDouble("time-pos")
        let cached = getDouble("demuxer-cache-time")
        let speed = getDouble("speed")
        let paused = getFlag("pause")
        let eofReached = getFlag("eof-reached")
        let idle = getFlag("core-idle")
        let seeking = getFlag("seeking")
        let bufferingCache = getFlag("paused-for-cache")

        isPlayerLoading = (idle && !paused && !eofReached) || seeking || bufferingCache
        isPlayerPlaying = !paused && !idle && !eofReached
        // `eof-reached` is also set when a file ends because of an error (e.g. an expired
        // stream link). Only report a clean end-of-stream when there is no active playback
        // error, otherwise the watch-progress layer would mark the title as "completed" and
        // drop it from Continue Watching.
        isPlayerEnded = eofReached && _currentErrorMessage == nil
        durationMs = Int64(duration * 1000)
        positionMs = Int64(max(position, 0) * 1000)
        bufferedMs = Int64(max(position + cached, 0) * 1000)
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

            if type == "audio" {
                let display = trackTitle(title: title, lang: lang, codec: codec,
                                         channelCount: channelCount, fallback: "Track \(audioIdx + 1)")
                audio.append(TrackInfo(index: audioIdx, id: id, type: type, title: display, lang: lang, selected: selected))
                audioIdx += 1
            } else if type == "sub" {
                let display = trackTitle(title: title, lang: lang, codec: codec,
                                         channelCount: 0, fallback: "Subtitle \(subIdx + 1)")
                subs.append(TrackInfo(index: subIdx, id: id, type: type, title: display, lang: lang, selected: selected))
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

    // MARK: - HDR display mode switching
    //
    // tvOS never switches the HDMI output to HDR just because a Metal layer
    // renders PQ/HLG content — only AVFoundation players get that for free.
    // When "Match Content → Dynamic Range" is enabled on the Apple TV, apps
    // must request the switch through AVDisplayManager. tvOS 17 added a public
    // AVDisplayCriteria initializer, so build a format description carrying the
    // stream's color tags (BT.2020 + PQ/HLG) and hand it to the window. Also
    // carries the container frame rate, so "Match Frame Rate" works too.

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

    private func updateDisplayCriteria() {
        // AVDisplayManager isn't in the simulator SDK (there's no HDMI output
        // to switch); this whole path is device-only.
        #if !targetEnvironment(simulator)
        guard #available(tvOS 17.0, *) else { return }
        guard mpv != nil, !isDisplaySwitchInFlight else { return }

        let gamma = (getString("video-params/gamma") ?? "").lowercased()
        let primaries = (getString("video-params/primaries") ?? "").lowercased()

        // No video attached (e.g. our own `vid=no`, or backgrounding): leave
        // whatever criteria are in place alone.
        guard !gamma.isEmpty || !primaries.isEmpty else { return }

        let isHDR = gamma == "pq" || gamma == "hlg" || primaries.contains("2020")
        guard isHDR else {
            clearDisplayCriteria()
            return
        }
        guard !didApplyDisplayCriteria, let window = view.window else { return }
        // Skip (SDR playback, no crash) rather than abort if the category is
        // ever missing again — e.g. a future tvOS removing it.
        _ = Self.avKitLinkAnchor
        guard window.responds(to: NSSelectorFromString("avDisplayManager")) else {
            print("[MPV] AVDisplayManager unavailable; HDR display switch skipped")
            return
        }

        let width = getInt("video-params/w")
        let height = getInt("video-params/h")
        guard width > 0, height > 0 else { return }

        var fps = getDouble("container-fps")
        if fps <= 0 { fps = getDouble("estimated-vf-fps") }
        if fps <= 0 { fps = 23.976 }

        let codecType: CMVideoCodecType
        switch (getString("video-format") ?? "").lowercased() {
        case "h264": codecType = kCMVideoCodecType_H264
        case "av1": codecType = kCMVideoCodecType_AV1
        default: codecType = kCMVideoCodecType_HEVC
        }

        let transfer: CFString = gamma == "hlg"
            ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]

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
            return
        }

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
        #endif
    }

    // MARK: - Error tracking

    private func clearPlaybackError() {
        errorStateLock.lock()
        recentPlaybackLogs.removeAll(keepingCapacity: true)
        _currentErrorMessage = nil
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
                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async {
                        self.clearPlaybackError()
                        self.isPlayerLoading = false
                        self.attachPendingAudioIfNeeded()
                        self.applySubtitleStyle()
                        self.updateState()
                    }
                case MPV_EVENT_VIDEO_RECONFIG:
                    // Fires once decode starts and whenever the video params
                    // change — the earliest point video-params/* is reliable.
                    DispatchQueue.main.async { self.updateDisplayCriteria() }
                case MPV_EVENT_END_FILE:
                    if let data = eventPtr.pointee.data {
                        let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                        if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorText = String(cString: mpv_error_string(endFile.error))
                            self.setPlaybackError("[mpv] \(errorText)")
                            print("[MPV] End file error: \(errorText)")
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

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
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
