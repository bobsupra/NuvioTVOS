import Foundation
import UIKit
import AVFoundation
import Combine
import AetherEngine

/// High-frequency state observed only by the subtitle overlay. Keeping it
/// separate prevents Aether's 10 Hz presentation clock from rebuilding the
/// whole player screen while still making cue changes immediately visible.
@MainActor
final class AetherSubtitleOverlayState: ObservableObject {
    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var sourceTime: Double = 0

    func updateCues(_ cues: [SubtitleCue]) {
        self.cues = cues
    }

    func updateSourceTime(_ seconds: Double) {
        sourceTime = seconds.isFinite ? max(0, seconds) : 0
    }

    func reset() {
        cues = []
        sourceTime = 0
    }
}

/// Keeps translation separate from the renderer's timing state: new text is
/// swapped in only after Gemini answers, so a slow/network-failed request
/// continues to show the original cue rather than delaying or hiding it.
@MainActor
final class AISubtitleTranslationState: ObservableObject {
    @Published private var translatedTextByCueID: [Int: String] = [:]
    @Published private var translatingCueIDs: Set<Int> = []

    /// Delivered once per playback session, allowing the player to use its
    /// established non-blocking toast presentation.
    var onFirstOutcome: ((Result<Void, Error>) -> Void)?

    private var tasks: [Int: Task<Void, Never>] = [:]
    private var sessionID = UUID()
    private var didReportOutcome = false
    private var failedCueIDs: Set<Int> = []
    private var manualActivation = false
    private var lastCues: [SubtitleCue] = []
    private var lastSourceTime: Double = 0
    private var currentSettings: AISubtitleTranslationSettings?
    private let prefetchWindowSeconds: Double = 8
    private let maximumConcurrentRequests = 2

    var isConfigured: Bool {
        let settings = AISubtitleTranslationSettings.current()
        return settings.isEnabled && !settings.apiKey.isEmpty
    }

    var isActive: Bool {
        let settings = AISubtitleTranslationSettings.current()
        return settings.isEnabled && !settings.apiKey.isEmpty && (settings.autoSelect || manualActivation)
    }

    func translatedText(for cueID: Int) -> String? {
        guard isActive else { return nil }
        return translatedTextByCueID[cueID]
    }

    func isTranslating(cueIDs: some Sequence<Int>) -> Bool {
        cueIDs.contains { translatingCueIDs.contains($0) }
    }

    func setManualActivation(_ enabled: Bool) {
        manualActivation = enabled
        if !enabled && !AISubtitleTranslationSettings.current().autoSelect {
            deactivate()
            return
        }
        update(cues: lastCues, at: lastSourceTime)
    }

    func update(cues: [SubtitleCue], at sourceTime: Double) {
        lastCues = cues
        lastSourceTime = sourceTime

        let settings = AISubtitleTranslationSettings.current()
        guard settings.isEnabled else {
            deactivate()
            return
        }
        guard !settings.apiKey.isEmpty else {
            deactivate()
            reportOnce(.failure(AISubtitleTranslationError.missingAPIKey))
            return
        }
        guard settings.autoSelect || manualActivation else {
            deactivate()
            return
        }
        if currentSettings != settings {
            tasks.values.forEach { $0.cancel() }
            tasks = [:]
            translatedTextByCueID = [:]
            translatingCueIDs = []
            failedCueIDs = []
            sessionID = UUID()
            currentSettings = settings
        }

        // Cue translation cannot begin only at presentation time: a regular API
        // round trip often exceeds the first second of a subtitle. Prefer active
        // cues, then warm a short upcoming window, while bounding API pressure.
        let candidateCues = cues.filter {
            $0.endTime >= sourceTime && $0.startTime <= sourceTime + prefetchWindowSeconds
        }
        .sorted { lhs, rhs in
            let lhsDistance = max(0, lhs.startTime - sourceTime)
            let rhsDistance = max(0, rhs.startTime - sourceTime)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.startTime < rhs.startTime
        }
        for cue in candidateCues {
            guard tasks.count < maximumConcurrentRequests else { break }
            guard translatedTextByCueID[cue.id] == nil,
                  tasks[cue.id] == nil,
                  !failedCueIDs.contains(cue.id),
                  let text = cue.text else { continue }
            let source = Self.cleaned(text, stripHearingImpaired: settings.stripHearingImpaired)
            guard !source.isEmpty else {
                translatedTextByCueID[cue.id] = ""
                continue
            }
            translate(cueID: cue.id, source: source, settings: settings)
        }
    }

    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        translatedTextByCueID = [:]
        translatingCueIDs = []
        sessionID = UUID()
        didReportOutcome = false
        failedCueIDs = []
        manualActivation = false
        lastCues = []
        lastSourceTime = 0
        currentSettings = nil
    }

    private func translate(
        cueID: Int,
        source: String,
        settings: AISubtitleTranslationSettings
    ) {
        let activeSession = sessionID
        let profileScope = ProfileSettings.activeProfileScope
        translatingCueIDs.insert(cueID)
        tasks[cueID] = Task { [weak self] in
            do {
                if let cached = await AISubtitleTranslationCache.shared.translation(
                    for: source,
                    targetLanguage: settings.targetLanguage,
                    model: settings.model,
                    stripHearingImpaired: settings.stripHearingImpaired,
                    profileScope: profileScope
                ) {
                    guard !Task.isCancelled,
                          let self,
                          self.sessionID == activeSession else { return }
                    self.translatedTextByCueID[cueID] = cached
                    self.finish(cueID: cueID, outcome: .success(()))
                    return
                }
                let translated = try await GeminiSubtitleTranslator.translate(
                    source,
                    to: settings.targetLanguage,
                    model: settings.model,
                    apiKey: settings.apiKey
                )
                let cleaned = Self.cleaned(
                    translated,
                    stripHearingImpaired: settings.stripHearingImpaired
                )
                await AISubtitleTranslationCache.shared.store(
                    cleaned,
                    for: source,
                    targetLanguage: settings.targetLanguage,
                    model: settings.model,
                    stripHearingImpaired: settings.stripHearingImpaired,
                    profileScope: profileScope
                )
                guard !Task.isCancelled,
                      let self,
                      self.sessionID == activeSession else { return }
                self.translatedTextByCueID[cueID] = cleaned
                self.finish(cueID: cueID, outcome: .success(()))
            } catch is CancellationError {
                guard let self, self.sessionID == activeSession else { return }
                self.tasks[cueID] = nil
                self.translatingCueIDs.remove(cueID)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sessionID == activeSession else { return }
                self.finish(cueID: cueID, outcome: .failure(error))
            }
        }
    }

    private func finish(cueID: Int, outcome: Result<Void, Error>) {
        tasks[cueID] = nil
        translatingCueIDs.remove(cueID)
        if case .failure = outcome {
            failedCueIDs.insert(cueID)
        }
        reportOnce(outcome)
    }

    private func reportOnce(_ outcome: Result<Void, Error>) {
        guard !didReportOutcome else { return }
        didReportOutcome = true
        onFirstOutcome?(outcome)
    }

    private func deactivate() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        failedCueIDs = []
        currentSettings = nil
        sessionID = UUID()
        if !translatedTextByCueID.isEmpty { translatedTextByCueID = [:] }
        if !translatingCueIDs.isEmpty { translatingCueIDs = [] }
    }

    /// Removes the common SDH / hearing-impaired annotations before the cue is
    /// sent and after the model responds. Dialogue on the same cue is retained.
    static func cleaned(_ text: String, stripHearingImpaired: Bool) -> String {
        var result = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripHearingImpaired else { return result }
        result = result
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^\)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[♪♫]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

enum AISubtitleTranslationError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case service(message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Gemini API key in Settings → Integrations → AI Subtitles."
        case .invalidResponse:
            return "Gemini returned no translated text."
        case .service(let message):
            return message
        }
    }
}

enum GeminiSubtitleTranslator {
    private struct RequestBody: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct Content: Encodable {
        let parts: [Part]
    }

    private struct Part: Encodable {
        let text: String
    }

    private struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
    }

    private struct ResponseBody: Decodable {
        let candidates: [Candidate]?
    }

    private struct Candidate: Decodable {
        let content: ResponseContent?
    }

    private struct ResponseContent: Decodable {
        let parts: [ResponsePart]?
    }

    private struct ResponsePart: Decodable {
        let text: String?
    }

    private struct ErrorBody: Decodable {
        let error: APIError?
    }

    private struct APIError: Decodable {
        let message: String?
    }

    static func translate(
        _ source: String,
        to targetLanguage: String,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw AISubtitleTranslationError.invalidResponse
        }

        let prompt = """
        Translate the subtitle enclosed in <subtitle> into \(targetLanguage).
        Return only the natural translated subtitle text. Preserve dialogue line breaks; do not add labels, explanations, quotation marks, or annotations.
        <subtitle>
        \(source)
        </subtitle>
        """
        let body = RequestBody(
            contents: [Content(parts: [Part(text: prompt)])],
            generationConfig: GenerationConfig(temperature: 0.1, maxOutputTokens: 256)
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 12
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AISubtitleTranslationError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let serviceError = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw AISubtitleTranslationError.service(
                message: serviceError?.error?.message ?? "Gemini request failed (HTTP \(http.statusCode))."
            )
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = decoded.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw AISubtitleTranslationError.invalidResponse }
        return text
    }
}

@MainActor
enum AetherExternalSubtitleIdentity {
    static func accepted(
        _ subtitles: [NuvioSubtitle]
    ) -> [(subtitle: NuvioSubtitle, url: URL)] {
        subtitles.compactMap { subtitle in
            guard !subtitle.url.isEmpty, let url = URL(string: subtitle.url) else { return nil }
            return (subtitle, url)
        }
    }
}

@MainActor
struct AetherExternalSubtitleRegistration {
    let tracks: [ExternalSubtitleTrack]
    let urlsByTrackID: [Int: String]

    static func make(
        subtitles: [NuvioSubtitle],
        httpHeaders: [String: String]
    ) -> AetherExternalSubtitleRegistration {
        var tracks: [ExternalSubtitleTrack] = []
        var urlsByTrackID: [Int: String] = [:]
        for (subtitle, url) in AetherExternalSubtitleIdentity.accepted(subtitles) {
            let language = subtitle.language
            let id = AetherEngine.externalSubtitleTrackIDBase + tracks.count
            tracks.append(
                ExternalSubtitleTrack(
                    url: url,
                    name: subtitle.label ?? (language.isEmpty ? nil : language),
                    language: language.isEmpty ? nil : language,
                    httpHeaders: httpHeaders.isEmpty ? nil : httpHeaders
                )
            )
            urlsByTrackID[id] = subtitle.url
        }
        return AetherExternalSubtitleRegistration(tracks: tracks, urlsByTrackID: urlsByTrackID)
    }
}

/// Long-lived wrapper around a single `AetherEngine` instance (reused across titles).
@MainActor
final class AetherPlaybackController: UIViewController, PlaybackEngineControlling {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
    /// Terminal load/runtime failures the coordinator may use for MPV fallback.
    var onTerminalError: ((String) -> Void)?

    let engine: AetherEngine
    let playerView = AetherPlayerView()
    let subtitleOverlayState = AetherSubtitleOverlayState()
    let subtitleTranslationState = AISubtitleTranslationState()

    private var cancellables = Set<AnyCancellable>()
    private var loadGeneration: UInt64 = 0
    private var lastKnownPositionMs: Int64 = 0
    private var lastKnownDurationMs: Int64 = 0
    private var lastKnownSourceTimeSeconds: Double = 0
    private var externalSubtitleURLsByTrackID: [Int: String] = [:]
    private var currentHTTPHeaders: [String: String] = [:]
    private var didReportTerminalError = false
    private var sourceProbe: SourceProbe?
    private var subtitleDelaySeconds: Double = 0

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

        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sourceTime in
                guard let self else { return }
                self.subtitleOverlayState.updateSourceTime(sourceTime)
                self.subtitleTranslationState.update(
                    cues: self.subtitleCues,
                    at: sourceTime - self.subtitleDelaySeconds
                )
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
                guard let self else { return }
                self.subtitleCues = cues
                self.subtitleOverlayState.updateCues(cues)
                self.subtitleTranslationState.update(
                    cues: cues,
                    at: self.engine.clock.sourceTime - self.subtitleDelaySeconds
                )
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
            videoFrameSize = Self.displayVideoSize(
                codedWidth: engine.sourceVideoWidth,
                codedHeight: engine.sourceVideoHeight,
                pixelAspectRatio: engine.sourceVideoPixelAspectRatio
            )
        }
    }

    static func displayVideoSize(
        codedWidth: Int32,
        codedHeight: Int32,
        pixelAspectRatio: Double
    ) -> CGSize {
        guard codedWidth > 0, codedHeight > 0 else { return .zero }
        let ratio = pixelAspectRatio.isFinite && pixelAspectRatio > 0 ? pixelAspectRatio : 1
        return CGSize(
            width: CGFloat(codedWidth) * CGFloat(ratio),
            height: CGFloat(codedHeight)
        )
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
        subtitleTracks = tracks.enumerated().map { offset, t in
            PlaybackTrackInfo(
                index: offset,
                id: t.id,
                type: "sub",
                title: t.name,
                lang: t.language ?? "",
                selected: active == t.id,
                externalFilename: t.isExternal ? (externalSubtitleURLsByTrackID[t.id] ?? "") : "",
                isNativelyRenderedSubtitle: t.isNativelyRenderedSubtitle,
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
        subtitleDelaySeconds = request.subtitleDelaySeconds
        didReportTerminalError = false
        isPlayerLoading = true
        isPlayerEnded = false
        isAtEndOfFile = false
        hasCoherentTimeSample = false
        currentErrorMessage = ""
        sourceProbe = nil
        let externalRegistration = AetherExternalSubtitleRegistration.make(
            subtitles: request.externalSubtitles,
            httpHeaders: request.httpHeaders
        )
        externalSubtitleURLsByTrackID = externalRegistration.urlsByTrackID
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
        subtitleOverlayState.reset()
        subtitleTranslationState.reset()
        videoFrameSize = .zero

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

        let options = LoadOptions(
            httpHeaders: request.httpHeaders,
            matchContentEnabled: matchContent,
            panelIsInHDRMode: panelInHDR,
            audioBridgeMode: .surroundCompat,
            preserveASSMarkup: false,
            prepareNativeSubtitles: false,
            preferredAudioLanguages: request.preferredAudioLanguages,
            preferredSubtitleLanguages: request.preferredSubtitleLanguages,
            externalSubtitles: externalRegistration.tracks,
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
        // Host overlay evaluates cues at sourceTime - delay; use the same clock
        // for prefetching so negative subtitle delays do not miss their cue.
        subtitleDelaySeconds = seconds
        subtitleTranslationState.update(
            cues: subtitleCues,
            at: engine.clock.sourceTime - subtitleDelaySeconds
        )
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
        // @Published fires while registration is in progress, before the URL
        // association above exists. Remap once identity metadata is complete.
        mapSubtitleTracks(engine.subtitleTracks)
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
        subtitleOverlayState.reset()
        subtitleTranslationState.reset()
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
        videoFrameSize = .zero
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
