import Foundation
import UIKit
import AVFoundation
import Combine
import AetherEngine

/// Long-lived wrapper around a single `AetherEngine` instance (reused across titles).
@MainActor
final class AetherPlaybackController: UIViewController, PlaybackEngineControlling {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
    /// Terminal load/runtime failures the coordinator may use for MPV fallback.
    var onTerminalError: ((String) -> Void)?

    let engine: AetherEngine
    let playerView = AetherPlayerView()

    private var cancellables = Set<AnyCancellable>()
    private var loadGeneration: UInt64 = 0
    private var lastKnownPositionMs: Int64 = 0
    private var lastKnownDurationMs: Int64 = 0
    private var lastKnownSourceTimeSeconds: Double = 0
    private var pendingExternalSubtitles: [NuvioSubtitle] = []
    private var externalSubtitleURLsByTrackID: [Int: String] = [:]
    private var currentHTTPHeaders: [String: String] = [:]
    private var didReportTerminalError = false
    private var sourceProbe: SourceProbe?

    // MARK: PlaybackEngineControlling surface

    private(set) var audioTracks: [PlaybackTrackInfo] = []
    private(set) var subtitleTracks: [PlaybackTrackInfo] = []
    private(set) var isPlayerLoading = true
    private(set) var isPlayerPlaying = false
    private(set) var isPlayerEnded = false
    private(set) var isAtEndOfFile = false
    private(set) var hasCoherentTimeSample = false
    private(set) var durationMs: Int64 = 0
    private(set) var positionMs: Int64 = 0
    private(set) var bufferedMs: Int64 = 0
    private(set) var currentSpeed: Float = 1
    private(set) var currentErrorMessage = ""
    private(set) var videoFrameSize: CGSize = .zero
    /// Subtitle evaluation clock (Aether `sourceTime`).
    private(set) var sourceTimeSeconds: Double = 0
    private(set) var subtitleCues: [SubtitleCue] = []
    private(set) var capabilities = PlaybackEngineCapabilities.aether

    var playbackDebugInfo: PlaybackDebugInfo {
        let width = Int(engine.sourceVideoWidth > 0 ? engine.sourceVideoWidth : sourceProbe?.videoWidth ?? 0)
        let height = Int(engine.sourceVideoHeight > 0 ? engine.sourceVideoHeight : sourceProbe?.videoHeight ?? 0)
        let fps = engine.sourceVideoFrameRate ?? sourceProbe?.videoFrameRate
        let sourceRange = Self.dynamicRangeLabel(
            engine.sourceVideoFormat,
            dolbyVisionProfile: engine.sourceDVProfile ?? sourceProbe?.dvProfile
        )
        let outputRange = Self.dynamicRangeLabel(engine.videoFormat, dolbyVisionProfile: nil)
        let range = engine.sourceVideoFormat == engine.videoFormat
            ? sourceRange
            : "\(sourceRange) → \(outputRange)"
        let selectedAudio = audioTracks.first(where: \.selected) ?? audioTracks.first
        let audio = selectedAudio.map {
            $0.detail.isEmpty ? $0.title : $0.detail
        } ?? "Unknown"

        return PlaybackDebugInfo(
            player: "AetherEngine",
            pipeline: engine.playbackBackend.rawValue.capitalized,
            videoCodec: Self.codecLabel(sourceProbe?.videoCodecName),
            dynamicRange: range,
            resolution: width > 0 && height > 0 ? "\(width)×\(height)" : "Unknown",
            frameRate: fps.map { String(format: "%.3f fps", $0) } ?? "Unknown fps",
            audio: audio
        )
    }

    init(engine: AetherEngine? = nil) {
        if let engine {
            self.engine = engine
        } else {
            do {
                self.engine = try AetherEngine()
            } catch {
                // AetherEngine() is failable for rare resource setup failures.
                // Fall back to a second attempt; if it throws again, crash early
                // in debug so the spike surfaces immediately.
                self.engine = try! AetherEngine()
            }
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        engine.bind(view: playerView)
        observeEngine()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appDidEnterBackground() {
        let pos = lastKnownPositionMs
        let dur = lastKnownDurationMs
        onPlaybackSuspended?(pos, dur)
    }

    private func observeEngine() {
        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.applyPhase(phase)
            }
            .store(in: &cancellables)

        engine.clock.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshClock()
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.mapAudioTracks(tracks)
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.mapSubtitleTracks(tracks)
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                self?.subtitleCues = cues
            }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self else { return }
                self.durationMs = Int64((max(0, duration) * 1000).rounded())
                self.lastKnownDurationMs = self.durationMs
            }
            .store(in: &cancellables)
    }

    private func applyPhase(_ phase: PlaybackPhase) {
        switch phase {
        case .idle:
            isPlayerLoading = false
            isPlayerPlaying = false
            isPlayerEnded = false
        case .loading:
            isPlayerLoading = true
            isPlayerPlaying = false
            isPlayerEnded = false
            currentErrorMessage = ""
        case .playing:
            isPlayerLoading = false
            isPlayerPlaying = true
            isPlayerEnded = false
        case .paused:
            isPlayerLoading = false
            isPlayerPlaying = false
            isPlayerEnded = false
        case .seeking, .rebuffering:
            isPlayerLoading = true
            // Keep last isPlayerPlaying so UI does not flicker pause icons.
        case .stalled:
            isPlayerLoading = true
        case .ended:
            isPlayerLoading = false
            isPlayerPlaying = false
            isPlayerEnded = true
            isAtEndOfFile = true
        case .error(let message):
            isPlayerLoading = false
            isPlayerPlaying = false
            isPlayerEnded = false
            currentErrorMessage = message
            if !didReportTerminalError {
                didReportTerminalError = true
                onTerminalError?(message)
            }
        }
        refreshClock()
    }

    private func refreshClock() {
        let current = engine.clock.currentTime
        let source = engine.clock.sourceTime
        let buffered = engine.clock.bufferedPosition
        sourceTimeSeconds = source.isFinite ? max(0, source) : 0
        positionMs = Int64((max(0, current) * 1000).rounded())
        bufferedMs = Int64((max(0, buffered) * 1000).rounded())
        if current.isFinite, current >= 0, engine.duration > 0 {
            hasCoherentTimeSample = true
            lastKnownPositionMs = positionMs
        }
        if source.isFinite, source >= 0, engine.duration > 0 {
            lastKnownSourceTimeSeconds = source
        }
        if engine.duration > 0 {
            durationMs = Int64((engine.duration * 1000).rounded())
            lastKnownDurationMs = durationMs
        }
        if engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 {
            videoFrameSize = CGSize(
                width: CGFloat(engine.sourceVideoWidth),
                height: CGFloat(engine.sourceVideoHeight)
            )
        }
    }

    private func mapAudioTracks(_ tracks: [TrackInfo]) {
        // AetherEngine.TrackInfo imported as TrackInfo — Nuvio uses PlaybackTrackInfo.
        let active = engine.activeAudioTrackIndex
        audioTracks = tracks.enumerated().map { offset, t in
            PlaybackTrackInfo(
                index: offset,
                id: t.id,
                type: "audio",
                title: t.name,
                lang: t.language ?? "",
                selected: active == t.id,
                externalFilename: "",
                languageName: t.language ?? "",
                detail: audioDetail(t)
            )
        }
    }

    private func mapSubtitleTracks(_ tracks: [TrackInfo]) {
        let active = engine.activeSubtitleTrackIndex
        let externalTracks = tracks.filter(\.isExternal)
        for (track, subtitle) in zip(externalTracks, pendingExternalSubtitles) {
            externalSubtitleURLsByTrackID[track.id] = subtitle.url
        }
        subtitleTracks = tracks.enumerated().map { offset, t in
            PlaybackTrackInfo(
                index: offset,
                id: t.id,
                type: "sub",
                title: t.name,
                lang: t.language ?? "",
                selected: active == t.id,
                externalFilename: t.isExternal ? (externalSubtitleURLsByTrackID[t.id] ?? "") : "",
                languageName: t.language ?? "",
                detail: t.codec
            )
        }
    }

    private func audioDetail(_ t: TrackInfo) -> String {
        var parts: [String] = []
        if !t.codec.isEmpty { parts.append(t.codec.uppercased()) }
        if t.isAtmos {
            parts.append("Atmos")
        } else if t.channels > 0 {
            parts.append("\(t.channels) ch")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: Load

    func load(_ request: PlaybackLoadRequest, generation: UInt64) {
        loadGeneration = generation
        didReportTerminalError = false
        isPlayerLoading = true
        isPlayerEnded = false
        isAtEndOfFile = false
        hasCoherentTimeSample = false
        currentErrorMessage = ""
        sourceProbe = nil
        pendingExternalSubtitles = request.externalSubtitles
        externalSubtitleURLsByTrackID = [:]
        currentHTTPHeaders = request.httpHeaders
        lastKnownPositionMs = 0
        lastKnownDurationMs = 0
        lastKnownSourceTimeSeconds = 0
        positionMs = 0
        durationMs = 0
        bufferedMs = 0
        sourceTimeSeconds = 0
        currentSpeed = 1
        audioTracks = []
        subtitleTracks = []
        subtitleCues = []

        let frameRateMode = ProfileSettings.current.string(forKey: SettingsKey.frameRateMatching) ?? "Always"
        let matchContent = request.matchContentEnabled
            && frameRateMode.caseInsensitiveCompare("Off") != .orderedSame

        var panelInHDR = false
        if #available(tvOS 11.0, *) {
            // Prefer current EDR headroom when available; fall back to available HDR modes.
            panelInHDR = AVPlayer.availableHDRModes.contains(.hdr10)
                || AVPlayer.availableHDRModes.contains(.hlg)
                || AVPlayer.availableHDRModes.contains(.dolbyVision)
        }

        let external: [ExternalSubtitleTrack] = request.externalSubtitles.compactMap { sub in
            guard let url = URL(string: sub.url) else { return nil }
            let lang = sub.language
            return ExternalSubtitleTrack(
                url: url,
                name: sub.label ?? (lang.isEmpty ? nil : lang),
                language: lang.isEmpty ? nil : lang,
                httpHeaders: request.httpHeaders.isEmpty ? nil : request.httpHeaders
            )
        }

        let options = LoadOptions(
            httpHeaders: request.httpHeaders,
            matchContentEnabled: matchContent,
            panelIsInHDRMode: panelInHDR,
            audioBridgeMode: .surroundCompat,
            preserveASSMarkup: false,
            prepareNativeSubtitles: false,
            preferredAudioLanguages: request.preferredAudioLanguages,
            preferredSubtitleLanguages: request.preferredSubtitleLanguages,
            externalSubtitles: external,
            forwardBufferSegments: request.cacheProfile.aetherForwardBufferSegments,
            autoplay: request.autoplay
        )

        let start = request.resumePositionSeconds
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let probe: SourceProbe?
                if let start, start > 0 {
                    probe = try await self.engine.load(
                        url: request.videoURL,
                        startPosition: start,
                        options: options
                    )
                } else {
                    probe = try await self.engine.load(url: request.videoURL, options: options)
                }
                guard self.loadGeneration == gen else { return }
                self.sourceProbe = probe
                self.isPlayerLoading = false
                self.setSpeed(request.playbackRate)
            } catch {
                guard self.loadGeneration == gen else { return }
                let message = error.localizedDescription
                self.currentErrorMessage = message
                self.isPlayerLoading = false
                if !self.didReportTerminalError {
                    self.didReportTerminalError = true
                    self.onTerminalError?(message)
                }
            }
        }
    }

    func loadFile(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            currentErrorMessage = "Invalid URL"
            onTerminalError?("Invalid URL")
            return
        }
        loadGeneration += 1
        let request = PlaybackLoadRequest(
            videoURL: url,
            cacheProfile: PlaybackCacheProfile.fromSettings(
                ProfileSettings.current.string(forKey: SettingsKey.networkCache)
            ),
            assMode: PlaybackASSMode.fromSettings(
                ProfileSettings.current.string(forKey: SettingsKey.assOverrideMode)
            )
        )
        load(request, generation: loadGeneration)
    }

    func playPlayback() { engine.play() }
    func pausePlayback() { engine.pause() }

    func seekToMs(_ ms: Int64) {
        Task { @MainActor in
            await engine.seek(to: Double(ms) / 1000.0)
        }
    }

    func setSpeed(_ speed: Float) {
        let applied = min(max(speed, 0.25), engine.maxSupportedRate)
        currentSpeed = applied
        engine.setRate(applied)
    }

    func setAspectMode(_ mode: PlayerAspectMode) {
        switch mode {
        case .fit:
            engine.videoGravity = .resizeAspect
        case .fill:
            engine.videoGravity = .resizeAspectFill
        case .stretch:
            engine.videoGravity = .resize
        }
    }

    func setSubtitleDelay(_ seconds: Double) {
        // Host overlay evaluates cues at sourceTime - delay; nothing to push into Aether.
        _ = seconds
    }

    func setAudioDelay(_ seconds: Double) {
        // No public Aether API — coordinator should have handed off to MPV.
        _ = seconds
    }

    func setAudioVolumeGain(dB: Double) {
        // No public Aether amplification API.
        _ = dB
    }

    func selectAudio(_ trackId: Int) {
        engine.selectAudioTrack(index: trackId)
    }

    func selectSubtitle(_ trackId: Int) {
        if trackId < 0 {
            engine.clearSubtitle()
        } else {
            engine.selectSubtitleTrack(index: trackId)
        }
    }

    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {
        guard let url = URL(string: subtitle.url) else { return }
        let lang = subtitle.language
        let track = ExternalSubtitleTrack(
            url: url,
            name: subtitle.label ?? (lang.isEmpty ? nil : lang),
            language: lang.isEmpty ? nil : lang,
            httpHeaders: currentHTTPHeaders.isEmpty ? nil : currentHTTPHeaders
        )
        let info = engine.addExternalSubtitleTrack(track)
        externalSubtitleURLsByTrackID[info.id] = subtitle.url
        if !pendingExternalSubtitles.contains(where: { $0.url == subtitle.url }) {
            pendingExternalSubtitles.append(subtitle)
        }
        if select {
            engine.selectSubtitleTrack(index: info.id)
        }
    }

    func addAudioUrl(_ url: String) {
        // Not supported — dual-URL sessions must use MPV.
        print("[Aether] addAudioUrl ignored (use MPV for separate audio URL): \(url.prefix(80))")
    }

    func applySubtitleStyle() {
        // Host overlay owns styling.
    }

    func destroyPlayer() {
        loadGeneration += 1
        engine.stop(resetDisplayCriteria: true)
        subtitleCues = []
        audioTracks = []
        subtitleTracks = []
        isPlayerLoading = false
        isPlayerPlaying = false
        isPlayerEnded = false
        hasCoherentTimeSample = false
        lastKnownPositionMs = 0
        lastKnownDurationMs = 0
        lastKnownSourceTimeSeconds = 0
        sourceTimeSeconds = 0
        positionMs = 0
        durationMs = 0
        bufferedMs = 0
        externalSubtitleURLsByTrackID = [:]
        currentHTTPHeaders = [:]
        currentErrorMessage = ""
        didReportTerminalError = false
        sourceProbe = nil
    }

    private static func dynamicRangeLabel(_ format: VideoFormat, dolbyVisionProfile: Int?) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10/PQ"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        case .dolbyVision:
            return dolbyVisionProfile.map { "Dolby Vision P\($0)" } ?? "Dolby Vision"
        }
    }

    private static func codecLabel(_ codec: String?) -> String {
        switch (codec ?? "").lowercased() {
        case "hevc", "h265": return "HEVC"
        case "h264", "avc": return "H.264"
        case "av1", "av01": return "AV1"
        case "vp9": return "VP9"
        case "mpeg2video": return "MPEG-2"
        case "": return "Unknown"
        case let value: return value.uppercased()
        }
    }

    func refreshPlaybackState() {
        refreshClock()
        mapAudioTracks(engine.audioTracks)
        mapSubtitleTracks(engine.subtitleTracks)
        applyPhase(engine.playbackPhase)
    }

    /// Snapshot for coordinator handoff.
    func coherentSourceTimeSeconds() -> Double {
        if hasCoherentTimeSample {
            return sourceTimeSeconds
        }
        return lastKnownSourceTimeSeconds
    }
}
