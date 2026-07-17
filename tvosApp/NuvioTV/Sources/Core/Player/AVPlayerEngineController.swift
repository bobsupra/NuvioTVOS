import AVFoundation
import AVKit
import UIKit

/// AVFoundation host used for native Dolby Vision (and Atmos when the asset
/// carries it). tvOS only engages true Dolby Vision mode through this path —
/// the MPV Metal renderer cannot deliver per-frame DV metadata to HDMI.
///
/// Uses `AVPlayerViewController` (not a bare `AVPlayerLayer`). On Apple TV,
/// HDR / Dolby Vision often plays audio-only with a black frame when rendered
/// only through `AVPlayerLayer`; AVKit's player controller owns the display
/// pipeline that switches Match Content dynamic range correctly.
@MainActor
final class AVPlayerEngineController: UIViewController, PlaybackEngineControlling {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
    /// AVPlayer can report an item as ready even when its video track is not
    /// decodable on this device (commonly Dolby Vision profile 7 / `dvhe`).
    /// The owner uses this to retry the same URL through MPV's HDR base layer.
    var onNativeVideoUnavailable: ((String, String) -> Void)?
    /// Fires once AVKit confirms that a real video frame can be displayed.
    var onVideoReady: ((String) -> Void)?

    private(set) var player: AVPlayer?
    /// System player chrome host — video surface lives inside this VC.
    private let playerViewController = AVPlayerViewController()

    var audioTracks: [TrackInfo] = []
    var subtitleTracks: [TrackInfo] = []

    var isPlayerLoading: Bool = true
    var isPlayerPlaying: Bool = false
    var isPlayerEnded: Bool = false
    private(set) var isAtEndOfFile: Bool = false
    private(set) var hasCoherentTimeSample: Bool = false
    var durationMs: Int64 = 0
    var positionMs: Int64 = 0
    var bufferedMs: Int64 = 0
    var currentSpeed: Float = 1.0
    private(set) var currentErrorMessage: String = ""

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var emptyObservation: NSKeyValueObservation?
    private var itemErrorObservation: NSKeyValueObservation?
    private var outputObscuredObservation: NSKeyValueObservation?
    private var readyForDisplayObservation: NSKeyValueObservation?
    private var pendingURL: String?
    private var pendingSeekMs: Int64?
    private var activeURL: String?
    private var pendingAudioURL: String?
    private var pendingExternalSubtitles: [(NuvioSubtitle, Bool)] = []
    private var didReachCleanEnd = false
    private var isDestroyed = false
    private var didEmbedPlayerViewController = false
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var wasPlayingBeforeBackground = false
    private var lifecyclePositionMs: Int64?
    private var compatibilityCheckTask: Task<Void, Never>?
    private var videoReadinessTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var didRequestNativeFallback = false
    private var didSignalVideoReady = false

    var videoFrameSize: CGSize {
        guard let size = player?.currentItem?.presentationSize,
              size.width > 1, size.height > 1 else { return .zero }
        return size
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        embedPlayerViewControllerIfNeeded()
        setupNotifications()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerViewController.view.frame = view.bounds
        attemptStartPendingLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        embedPlayerViewControllerIfNeeded()
        // Re-bind after the VC is in a window — fixes black video when load
        // raced ahead of hierarchy attachment.
        if let player {
            playerViewController.player = player
        }
        attemptStartPendingLoad()
    }

    private func embedPlayerViewControllerIfNeeded() {
        guard !didEmbedPlayerViewController else {
            playerViewController.view.frame = view.bounds
            return
        }
        didEmbedPlayerViewController = true

        playerViewController.showsPlaybackControls = false
        playerViewController.view.backgroundColor = .black
        // Remote events stay with SwiftUI chrome; AVKit must not steal focus.
        playerViewController.view.isUserInteractionEnabled = false
        #if os(tvOS)
        playerViewController.transportBarCustomMenuItems = []
        #endif

        addChild(playerViewController)
        playerViewController.view.frame = view.bounds
        playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerViewController.view)
        playerViewController.didMove(toParent: self)

        applyVideoGravity(.resizeAspect)
    }

    private func applyVideoGravity(_ gravity: AVLayerVideoGravity) {
        playerViewController.videoGravity = gravity
    }

    private func setupNotifications() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enterBackground() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enterForeground() }
        }
    }

    private func enterBackground() {
        wasPlayingBeforeBackground = isPlayerPlaying
        lifecyclePositionMs = positionMs
        if let pos = lifecyclePositionMs, durationMs > 0 {
            onPlaybackSuspended?(pos, durationMs)
        }
        player?.pause()
    }

    private func enterForeground() {
        if let pos = lifecyclePositionMs, pos > 0 {
            seekToMs(pos)
        }
        if wasPlayingBeforeBackground {
            player?.play()
        }
        lifecyclePositionMs = nil
        // Re-attach after background — some tvOS builds drop the visual surface.
        if let player {
            playerViewController.player = player
        }
    }

    // MARK: - Load

    func loadFile(_ urlString: String) {
        guard !isDestroyed else { return }
        pendingURL = urlString
        pendingSeekMs = nil
        activeURL = urlString
        loadGeneration &+= 1
        didRequestNativeFallback = false
        didSignalVideoReady = false
        compatibilityCheckTask?.cancel()
        videoReadinessTask?.cancel()
        isPlayerLoading = true
        isPlayerEnded = false
        isAtEndOfFile = false
        hasCoherentTimeSample = false
        didReachCleanEnd = false
        currentErrorMessage = ""
        durationMs = 0
        positionMs = 0
        bufferedMs = 0
        audioTracks = []
        subtitleTracks = []
        attemptStartPendingLoad()
    }

    private func attemptStartPendingLoad() {
        guard let urlString = pendingURL else { return }
        guard isViewLoaded, view.bounds.width > 1, view.bounds.height > 1 else { return }
        embedPlayerViewControllerIfNeeded()
        guard let url = URL(string: urlString) else {
            currentErrorMessage = "Invalid stream URL"
            isPlayerLoading = false
            return
        }
        pendingURL = nil
        rebuildPlayer(with: url)
    }

    private func rebuildPlayer(with url: URL) {
        tearDownPlayerObserversOnly()
        embedPlayerViewControllerIfNeeded()

        // Prefer streaming-friendly asset options for debrid progressive URLs.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        // This is true by default, but keep the native Dolby Vision path
        // explicit: AVFoundation must propagate the per-frame HDR metadata.
        item.appliesPerFrameHDRDisplayMetadata = true
        item.automaticallyPreservesTimeOffsetFromLive = false
        item.preferredForwardBufferDuration = 8

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        player = newPlayer

        // Critical: bind through AVPlayerViewController so tvOS can drive the
        // HDMI dynamic-range switch and actually composite DV/HDR frames.
        playerViewController.player = newPlayer
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1

        observe(item: item, player: newPlayer)
        let generation = loadGeneration
        compatibilityCheckTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            await self.validateVideoCompatibility(of: item, generation: generation)
        }
        newPlayer.play()
        isPlayerLoading = true
        isPlayerPlaying = true

        print("[AVPlayer] Loading \(url.absoluteString.prefix(120))… via AVPlayerViewController")

        Task { [weak self] in
            await self?.refreshTracksFromItem(item)
        }
        flushPendingAudioIfNeeded()
        flushPendingSubtitlesIfNeeded()
    }

    private func observe(item: AVPlayerItem, player: AVPlayer) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.handleItemStatus(item)
            }
        }
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.updateBufferingFlags(item: item)
            }
        }
        emptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.updateBufferingFlags(item: item)
            }
        }
        itemErrorObservation = item.observe(\.error, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, let error = item.error else { return }
                print("[AVPlayer] item error: \(error.localizedDescription)")
                self.requestNativeFallback(
                    error.localizedDescription,
                    generation: self.loadGeneration
                )
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentSpeed = player.rate == 0 ? self.currentSpeed : Float(player.rate)
                self.updateBufferingFlags(item: player.currentItem)
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlayerPlaying = player.timeControlStatus == .playing && !self.isPlayerEnded
                self.updateBufferingFlags(item: player.currentItem)
            }
        }
        outputObscuredObservation = player.observe(
            \.isOutputObscuredDueToInsufficientExternalProtection,
            options: [.new]
        ) { [weak self] player, _ in
            Task { @MainActor in
                guard player.isOutputObscuredDueToInsufficientExternalProtection else { return }
                self?.currentErrorMessage = "Video output is blocked by the display's HDCP connection."
                self?.isPlayerLoading = false
                self?.isPlayerPlaying = false
            }
        }
        readyForDisplayObservation = playerViewController.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            Task { @MainActor in
                guard let self,
                      controller.isReadyForDisplay,
                      self.player?.currentItem === item,
                      !self.didSignalVideoReady else { return }
                self.didSignalVideoReady = true
                self.videoReadinessTask?.cancel()
                self.videoReadinessTask = nil
                print("[AVPlayer] first video frame ready for display")
                if let activeURL = self.activeURL {
                    self.onVideoReady?(activeURL)
                }
            }
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.handlePeriodicTime(time)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.didReachCleanEnd = true
                self.isAtEndOfFile = true
                self.isPlayerEnded = true
                self.isPlayerPlaying = false
                self.isPlayerLoading = false
            }
        }
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            currentErrorMessage = ""
            refreshDuration(from: item)
            updateBufferingFlags(item: item)
            // Re-bind + play once the item is ready. Prevents a stuck black
            // frame when play() was called before the first video sample.
            if let player {
                playerViewController.player = player
                if let pendingSeekMs {
                    self.pendingSeekMs = nil
                    seekToMs(pendingSeekMs)
                }
                if !isPlayerEnded, player.rate == 0 {
                    player.play()
                }
            }
            let size = item.presentationSize
            print("[AVPlayer] readyToPlay presentationSize=\(size.width)x\(size.height) duration=\(durationMs)ms")
            armVideoReadinessWatchdog(generation: loadGeneration)
            Task { await refreshTracksFromItem(item) }
        case .failed:
            let message = item.error?.localizedDescription
                ?? "AVPlayer failed to open this stream"
            print("[AVPlayer] failed: \(message)")
            requestNativeFallback(message, generation: loadGeneration)
        case .unknown:
            isPlayerLoading = true
        @unknown default:
            break
        }
    }

    private func updateBufferingFlags(item: AVPlayerItem?) {
        guard let item else {
            isPlayerLoading = player == nil
            return
        }
        if item.status == .failed {
            isPlayerLoading = false
            return
        }
        // `isPlaybackLikelyToKeepUp` is only a prediction and may remain false
        // while progressive/debrid media is actively playing. AVPlayer's
        // time-control state is the authoritative signal for a stalled spinner.
        let waiting = player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        isPlayerLoading = (item.status == .unknown || waiting) && !isPlayerEnded
    }

    private func handlePeriodicTime(_ time: CMTime) {
        guard let item = player?.currentItem else { return }
        refreshDuration(from: item)

        let seconds = time.seconds
        if seconds.isFinite, seconds >= 0 {
            positionMs = Int64(seconds * 1000)
        }

        if let range = item.loadedTimeRanges.last?.timeRangeValue {
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            if end.isFinite {
                bufferedMs = Int64(max(end, 0) * 1000)
            }
        }

        hasCoherentTimeSample = durationMs > 0 && positionMs >= 0
        if hasCoherentTimeSample {
            isAtEndOfFile = positionMs >= max(durationMs - 250, 0) && didReachCleanEnd
            isPlayerEnded = isAtEndOfFile
        }
        updateBufferingFlags(item: item)
        isPlayerPlaying = player?.timeControlStatus == .playing && !isPlayerEnded
    }

    /// Verifies the actual video track instead of trusting release-name hints.
    /// Apple's native Dolby Vision sample entry is `dvh1` (profile 5); profile
    /// 8.4 uses `hvc1`. The common `dvhe` entry used by profile 7 remuxes is not
    /// a supported native AVFoundation Dolby Vision layout.
    private func validateVideoCompatibility(of item: AVPlayerItem, generation: Int) async {
        do {
            let tracks = try await item.asset.loadTracks(withMediaType: .video)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            guard !tracks.isEmpty else {
                requestNativeFallback("AVPlayer found no video track in this asset.", generation: generation)
                return
            }

            var decodability: [Bool] = []
            var sampleEntries: Set<String> = []
            for track in tracks {
                decodability.append(try await track.load(.isDecodable))
                let descriptions = try await track.load(.formatDescriptions)
                descriptions.forEach {
                    sampleEntries.insert(Self.fourCC(CMFormatDescriptionGetMediaSubType($0)))
                }
            }

            guard !Task.isCancelled, generation == loadGeneration else { return }
            let entries = sampleEntries.sorted().joined(separator: ", ")
            print("[AVPlayer] video tracks=\(tracks.count), decodable=\(decodability), sampleEntries=\(entries)")

            if !decodability.contains(true) {
                requestNativeFallback(
                    "The video track is not decodable by AVPlayer on this Apple TV.",
                    generation: generation
                )
            } else if sampleEntries.contains("dvhe") {
                requestNativeFallback(
                    "This Dolby Vision sample entry (dvhe/profile 7) is not supported by AVPlayer.",
                    generation: generation
                )
            }
        } catch {
            // AVPlayerItem still owns normal network/error reporting. A key-load
            // failure alone is not proof that the video is incompatible.
            print("[AVPlayer] video compatibility check unavailable: \(error.localizedDescription)")
        }
    }

    private func requestNativeFallback(_ reason: String, generation: Int) {
        guard generation == loadGeneration,
              !didRequestNativeFallback,
              let activeURL else { return }
        didRequestNativeFallback = true
        player?.pause()
        isPlayerLoading = true
        isPlayerPlaying = false
        print("[AVPlayer] Native video unavailable: \(reason)")
        if let onNativeVideoUnavailable {
            onNativeVideoUnavailable(activeURL, reason)
        } else {
            currentErrorMessage = reason
            isPlayerLoading = false
        }
    }

    private func armVideoReadinessWatchdog(generation: Int) {
        guard !playerViewController.isReadyForDisplay else { return }
        videoReadinessTask?.cancel()
        videoReadinessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self,
                  generation == self.loadGeneration,
                  !self.playerViewController.isReadyForDisplay else { return }
            self.requestNativeFallback(
                "AVPlayer did not produce a displayable video frame.",
                generation: generation
            )
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }

    private func refreshDuration(from item: AVPlayerItem) {
        let duration = item.duration
        if duration.isNumeric, !duration.isIndefinite {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                durationMs = Int64(seconds * 1000)
            }
        }
    }

    // MARK: - Tracks

    private func refreshTracksFromItem(_ item: AVPlayerItem) async {
        let asset = item.asset
        do {
            let _ = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
        } catch {
            return
        }

        var audio: [TrackInfo] = []
        var subs: [TrackInfo] = []

        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            for (index, option) in group.options.enumerated() {
                let lang = option.extendedLanguageTag ?? option.locale?.identifier ?? ""
                let name = option.displayName
                audio.append(
                    TrackInfo(
                        index: index,
                        id: index,
                        type: "audio",
                        title: name,
                        lang: lang,
                        selected: option == selected,
                        externalFilename: "",
                        languageName: option.displayName,
                        detail: option.mediaType.rawValue
                    )
                )
            }
        }

        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            for (index, option) in group.options.enumerated() {
                if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                   group.options.count > 1 {
                    continue
                }
                let lang = option.extendedLanguageTag ?? option.locale?.identifier ?? ""
                subs.append(
                    TrackInfo(
                        index: index,
                        id: index,
                        type: "sub",
                        title: option.displayName,
                        lang: lang,
                        selected: option == selected,
                        externalFilename: ""
                    )
                )
            }
        }

        audioTracks = audio
        subtitleTracks = subs
    }

    // MARK: - Transport

    func playPlayback() {
        guard let player else { return }
        if isPlayerEnded {
            seekToMs(0)
            isPlayerEnded = false
            isAtEndOfFile = false
            didReachCleanEnd = false
        }
        playerViewController.player = player
        player.play()
        isPlayerPlaying = true
    }

    func pausePlayback() {
        player?.pause()
        isPlayerPlaying = false
    }

    func seekToMs(_ ms: Int64) {
        guard let player else {
            pendingSeekMs = max(ms, 0)
            positionMs = max(ms, 0)
            return
        }
        let seconds = Double(ms) / 1000.0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        positionMs = max(ms, 0)
        hasCoherentTimeSample = durationMs > 0
        isPlayerEnded = false
        isAtEndOfFile = false
        didReachCleanEnd = false
    }

    func setSpeed(_ speed: Float) {
        currentSpeed = speed
        if isPlayerPlaying {
            player?.rate = speed
        }
    }

    func setAspectMode(_ mode: PlayerAspectMode) {
        switch mode {
        case .fit:
            applyVideoGravity(.resizeAspect)
        case .fill:
            applyVideoGravity(.resizeAspectFill)
        case .stretch:
            applyVideoGravity(.resize)
        }
    }

    func setSubtitleDelay(_ seconds: Double) {
        _ = seconds
    }

    func setAudioDelay(_ seconds: Double) {
        _ = seconds
    }

    func setAudioVolumeGain(dB: Double) {
        let linear = pow(10.0, dB / 20.0)
        player?.volume = Float(min(max(linear, 0), 1.0))
    }

    func selectAudio(_ trackId: Int) {
        guard let item = player?.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  trackId >= 0, trackId < group.options.count else { return }
            item.select(group.options[trackId], in: group)
            await refreshTracksFromItem(item)
        }
    }

    func selectSubtitle(_ trackId: Int) {
        guard let item = player?.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            if trackId < 0 {
                item.select(nil, in: group)
            } else if trackId < group.options.count {
                item.select(group.options[trackId], in: group)
            }
            await refreshTracksFromItem(item)
        }
    }

    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {
        pendingExternalSubtitles.append((subtitle, select))
        flushPendingSubtitlesIfNeeded()
    }

    private func flushPendingSubtitlesIfNeeded() {
        guard player?.currentItem != nil else { return }
        if !pendingExternalSubtitles.isEmpty {
            print("[AVPlayer] External subtitle side-load is limited; use MPVKit for full SRT/ASS support (\(pendingExternalSubtitles.count) skipped)")
            pendingExternalSubtitles.removeAll()
        }
    }

    func addAudioUrl(_ url: String) {
        pendingAudioURL = url
        flushPendingAudioIfNeeded()
    }

    private func flushPendingAudioIfNeeded() {
        if pendingAudioURL != nil {
            print("[AVPlayer] Secondary audio URL ignored (trailer dual-stream path is MPV-only)")
            pendingAudioURL = nil
        }
    }

    func applySubtitleStyle() {}

    func refreshPlaybackState() {
        guard let player, let item = player.currentItem else {
            if pendingURL != nil {
                isPlayerLoading = true
            }
            return
        }
        handlePeriodicTime(player.currentTime())
        updateBufferingFlags(item: item)
        if item.status == .failed, !didRequestNativeFallback {
            currentErrorMessage = item.error?.localizedDescription
                ?? currentErrorMessage
        }
    }

    func destroyPlayer() {
        isDestroyed = true
        pendingURL = nil
        pendingSeekMs = nil
        activeURL = nil
        compatibilityCheckTask?.cancel()
        compatibilityCheckTask = nil
        videoReadinessTask?.cancel()
        videoReadinessTask = nil
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        backgroundObserver = nil
        foregroundObserver = nil
        tearDownPlayerObserversOnly()
        playerViewController.player = nil
        player = nil
    }

    private func tearDownPlayerObserversOnly() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusObservation = nil
        rateObservation = nil
        timeControlObservation = nil
        keepUpObservation = nil
        emptyObservation = nil
        itemErrorObservation = nil
        outputObscuredObservation = nil
        readyForDisplayObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerViewController.player = nil
    }
}
