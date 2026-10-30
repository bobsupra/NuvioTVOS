import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine
import ImageIO
import CryptoKit
import AetherEngine
import AetherEngineSMB
import SwiftAssRenderer

@MainActor
private final class SceneFrameAnalysisResultBox {
    var capture: AetherEngine.VideoFrameAnalysisCapture?
}

private final class SceneAnalysisYieldLatch: @unchecked Sendable {
    private let signal: @Sendable () -> Bool
    private let lock = NSLock()
    private var observedYield = false

    init(signal: @escaping @Sendable () -> Bool) {
        self.signal = signal
    }

    func check() -> Bool {
        let value = signal()
        if value {
            lock.lock()
            observedYield = true
            lock.unlock()
        }
        return value
    }

    var didYield: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedYield
    }
}

struct AetherSceneFrameAnalysisIdentity: Equatable, @unchecked Sendable {
    let hostGeneration: UInt64
    let engineStartupGeneration: UInt64?
    let nativePlayer: AnyObject?
    let nativeItem: AnyObject?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hostGeneration == rhs.hostGeneration
            && lhs.engineStartupGeneration == rhs.engineStartupGeneration
            && lhs.nativePlayer === rhs.nativePlayer
            && lhs.nativeItem === rhs.nativeItem
    }
}

/// High-frequency state observed only by the subtitle overlay. Keeping it
/// separate prevents Aether's 10 Hz presentation clock from rebuilding the
/// whole player screen while still making cue changes immediately visible.
@MainActor
final class AetherSubtitleOverlayState: ObservableObject {
    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var sourceTime: Double = 0
    @Published private(set) var nativeVideoRect: CGRect?
    @Published private(set) var assRenderer: AssSubtitlesRenderer?
    @Published private(set) var isASSActive = false
    let assReloadSignal = PassthroughSubject<ASSRenderCoordinator.ReloadEvent, Never>()
    var onASSCanvasSizeChanged: ((AssSubtitlesRenderer) -> Void)?

    func updateCues(_ cues: [SubtitleCue]) {
        self.cues = cues
    }

    func updateSourceTime(_ seconds: Double) {
        sourceTime = seconds.isFinite ? max(0, seconds) : 0
    }

    func updateNativeVideoRect(_ rect: CGRect?) {
        let validRect = rect.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
        guard nativeVideoRect != validRect else { return }
        nativeVideoRect = validRect
    }

    func updateASS(renderer: AssSubtitlesRenderer?, isActive: Bool) {
        assRenderer = renderer
        isASSActive = isActive
    }

    func reset() {
        cues = []
        sourceTime = 0
        nativeVideoRect = nil
        assRenderer = nil
        isASSActive = false
    }
}

/// Keeps enough translated dialogue ready to absorb provider latency without
/// continuously translating far beyond the viewer's playback position.
enum AISubtitleAdaptiveBuffer {
    static let lowWatermark: TimeInterval = 20
    static let highWatermark: TimeInterval = 60

    static func shouldRefill(nextUntranslatedStart: Double, sourceTime: Double) -> Bool {
        max(0, nextUntranslatedStart - sourceTime) <= lowWatermark
    }

    static func isInsideRefillWindow(cueStart: Double, sourceTime: Double) -> Bool {
        cueStart <= sourceTime + highWatermark
    }
}

/// Keeps translation separate from the renderer's timing state: new text is
/// swapped in only after Gemini answers, so a slow/network-failed request
/// continues to show the original cue rather than delaying or hiding it.
@MainActor
final class AISubtitleTranslationState: ObservableObject {
    @Published private var translatedTextByCueID: [Int: String] = [:]
    @Published private var translatedTextBySource: [String: String] = [:]
    @Published private var translatingCueIDs: Set<Int> = []

    /// Delivers the first successful translation and the first later failure
    /// separately, so quota errors are not hidden by an earlier success toast.
    var onFirstOutcome: ((Result<Void, Error>) -> Void)?
    /// Lets Aether release its one-time cold-start playback hold when the
    /// active cue finishes translating (or definitively fails).
    var onCueTranslationResolved: ((Int) -> Void)?

    private struct PendingCue: Sendable {
        let id: Int
        let source: String
        let sourceIdentity: String
        let startTime: Double
        let endTime: Double
    }

    private var batchTask: Task<Void, Never>?
    private var delayedBatchTask: Task<Void, Never>?
    private var priorityTasks: [Int: Task<Void, Never>] = [:]
    private var sessionID = UUID()
    private var didReportSuccess = false
    private var didReportFailure = false
    private var failedCueIDs: Set<Int> = []
    private var hasPermanentProviderFailure = false
    private var manualActivation = false
    private var lastCues: [SubtitleCue] = []
    private var lastSourceTime: Double = 0
    private var currentSettings: AISubtitleTranslationSettings?
    private var nextBatchStartAt = Date.distantPast
    // Translate the urgent cue alone while one nearby lookahead batch runs in
    // parallel. This keeps first-text latency low without spending eight
    // requests on the startup/seek window.
    private let priorityLookaheadDuration: TimeInterval = 25
    private let maximumPriorityLookaheadCueCount = 12
    private let maximumConcurrentPriorityRequests = 1
    private var remainingPriorityCueIDs: [Int] = []
    private var urgentPriorityCueID: Int?
    private var needsPriorityPrefetch = true
    private let catchUpBatchInterval: TimeInterval = 0.35

    var isConfigured: Bool {
        let settings = AISubtitleTranslationSettings.current()
        return settings.isEnabled && !settings.apiKey.isEmpty
    }

    var isActive: Bool {
        let settings = AISubtitleTranslationSettings.current()
        return settings.isEnabled && !settings.apiKey.isEmpty && (settings.autoSelect || manualActivation)
    }

    func translatedText(for cue: SubtitleCue) -> String? {
        guard isActive else { return nil }
        let settings = currentSettings ?? AISubtitleTranslationSettings.current()
        return translation(for: cue, settings: settings)
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
        let didSeek = abs(sourceTime - lastSourceTime) > 10
        lastCues = cues
        lastSourceTime = sourceTime
        if didSeek {
            cancelTranslationWork()
            translatingCueIDs = []
            failedCueIDs = []
            sessionID = UUID()
            nextBatchStartAt = .distantPast
            remainingPriorityCueIDs = []
            urgentPriorityCueID = nil
            needsPriorityPrefetch = true
        }

        let settings = AISubtitleTranslationSettings.current()
        guard settings.isEnabled else {
            deactivate()
            return
        }
        guard cues.contains(where: { cue in
            guard let text = cue.text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            // Do not validate credentials or announce AI translation until the
            // selected track has supplied actual text cues.
            deactivate()
            return
        }
        guard !settings.apiKey.isEmpty else {
            deactivate()
            report(.failure(AISubtitleTranslationError.missingAPIKey))
            return
        }
        guard settings.autoSelect || manualActivation else {
            deactivate()
            return
        }
        if currentSettings != settings {
            cancelTranslationWork()
            translatedTextByCueID = [:]
            translatedTextBySource = [:]
            translatingCueIDs = []
            failedCueIDs = []
            hasPermanentProviderFailure = false
            sessionID = UUID()
            currentSettings = settings
            nextBatchStartAt = .distantPast
            remainingPriorityCueIDs = []
            urgentPriorityCueID = nil
            needsPriorityPrefetch = true
        }

        startNextBatchIfNeeded(settings: settings)
    }

    func reset() {
        cancelTranslationWork()
        translatedTextByCueID = [:]
        translatedTextBySource = [:]
        translatingCueIDs = []
        sessionID = UUID()
        didReportSuccess = false
        didReportFailure = false
        failedCueIDs = []
        hasPermanentProviderFailure = false
        manualActivation = false
        lastCues = []
        lastSourceTime = 0
        currentSettings = nil
        nextBatchStartAt = .distantPast
        remainingPriorityCueIDs = []
        urgentPriorityCueID = nil
        needsPriorityPrefetch = true
    }

    private func startNextBatchIfNeeded(settings: AISubtitleTranslationSettings) {
        guard !hasPermanentProviderFailure,
              batchTask == nil,
              delayedBatchTask == nil else { return }
        let now = Date()
        guard now >= nextBatchStartAt else {
            scheduleNextBatch(at: nextBatchStartAt, settings: settings)
            return
        }

        let candidateCues = lastCues
            .filter { cue in
                cue.endTime >= lastSourceTime &&
                translation(for: cue, settings: settings) == nil &&
                    !failedCueIDs.contains(cue.id) &&
                    cue.text != nil
            }
            .sorted { lhs, rhs in
                let lhsDistance = max(0, lhs.startTime - lastSourceTime)
                let rhsDistance = max(0, rhs.startTime - lastSourceTime)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.startTime < rhs.startTime
            }
            .compactMap { cue -> PendingCue? in
                guard let text = cue.text else { return nil }
                let source = Self.cleaned(text, stripHearingImpaired: settings.stripHearingImpaired)
                guard !source.isEmpty else {
                    translatedTextByCueID[cue.id] = ""
                    return nil
                }
                return PendingCue(
                    id: cue.id,
                    source: source,
                    sourceIdentity: Self.normalizedSource(source),
                    startTime: cue.startTime,
                    endTime: cue.endTime
                )
            }
        guard !candidateCues.isEmpty else { return }

        if needsPriorityPrefetch && remainingPriorityCueIDs.isEmpty {
            var lookaheadCues = candidateCues
                .filter { $0.startTime <= lastSourceTime + priorityLookaheadDuration }
            if lookaheadCues.isEmpty, let first = candidateCues.first {
                lookaheadCues = [first]
            }
            lookaheadCues = Array(lookaheadCues.prefix(maximumPriorityLookaheadCueCount))
            remainingPriorityCueIDs = lookaheadCues.map(\.id)
            urgentPriorityCueID = lookaheadCues.first(where: {
                $0.startTime <= lastSourceTime && $0.endTime >= lastSourceTime
            })?.id ?? lookaheadCues.first?.id
            needsPriorityPrefetch = false
        }
        let candidateCueIDs = Set(candidateCues.map(\.id))
        remainingPriorityCueIDs.removeAll { !candidateCueIDs.contains($0) }
        if let urgentPriorityCueID,
           !candidateCueIDs.contains(urgentPriorityCueID) {
            self.urgentPriorityCueID = nil
        }
        let availableCues = candidateCues.filter { !translatingCueIDs.contains($0.id) }

        if !remainingPriorityCueIDs.isEmpty {
            if let urgentPriorityCueID,
               let urgentCue = availableCues.first(where: { $0.id == urgentPriorityCueID }) {
                startPriorityTranslations(from: [urgentCue], settings: settings)
            }

            let lookaheadCues = availableCues.filter {
                remainingPriorityCueIDs.contains($0.id) && $0.id != urgentPriorityCueID
            }
            let lookaheadIDs = Set(
                AISubtitleBatching.batches(
                    lookaheadCues.map { .init(id: $0.id, text: $0.source) }
                )
                .first?
                .map(\.id) ?? []
            )
            let pendingLookaheadCues = lookaheadCues.filter { lookaheadIDs.contains($0.id) }
            if !pendingLookaheadCues.isEmpty {
                startBatchTranslation(pendingLookaheadCues, settings: settings)
            }
            return
        }

        guard let nextUntranslatedCue = availableCues.first,
              AISubtitleAdaptiveBuffer.shouldRefill(
                nextUntranslatedStart: nextUntranslatedCue.startTime,
                sourceTime: lastSourceTime
              ) else { return }
        let refillCues = availableCues.filter {
            AISubtitleAdaptiveBuffer.isInsideRefillWindow(
                cueStart: $0.startTime,
                sourceTime: lastSourceTime
            )
        }
        let pendingIDs = Set(
            AISubtitleBatching.batches(
                refillCues.map { .init(id: $0.id, text: $0.source) }
            )
            .first?
            .map(\.id) ?? []
        )
        let pendingCues = refillCues.filter { pendingIDs.contains($0.id) }
        guard !pendingCues.isEmpty else { return }

        startBatchTranslation(pendingCues, settings: settings)
    }

    private func startBatchTranslation(
        _ pendingCues: [PendingCue],
        settings: AISubtitleTranslationSettings
    ) {
        guard batchTask == nil, !pendingCues.isEmpty else { return }
        translatingCueIDs.formUnion(pendingCues.map(\.id))
        let activeSession = sessionID
        let profileScope = ProfileSettings.activeProfileScope
        batchTask = Task { [weak self] in
            do {
                var translations: [Int: String] = [:]
                var uncachedCues: [PendingCue] = []
                for cue in pendingCues {
                    if let cached = await AISubtitleTranslationCache.shared.translation(
                        for: cue.source,
                        targetLanguage: settings.targetLanguage,
                        model: settings.cacheModelIdentifier,
                        stripHearingImpaired: settings.stripHearingImpaired,
                        profileScope: profileScope
                    ) {
                        translations[cue.id] = cached
                    } else {
                        uncachedCues.append(cue)
                    }
                }

                if !uncachedCues.isEmpty {
                    let translated = try await AISubtitleBatchRecovery.translate(
                        uncachedCues.map { .init(id: $0.id, text: $0.source) }
                    ) { items in
                        try await AISubtitleTranslator.translateBatch(items, settings: settings)
                    }
                    var cacheEntries: [AISubtitleTranslationCache.PendingTranslation] = []
                    for cue in uncachedCues {
                        guard let text = translated[cue.id] else {
                            throw AISubtitleTranslationError.invalidResponse
                        }
                        let cleaned = Self.cleaned(
                            text,
                            stripHearingImpaired: settings.stripHearingImpaired
                        )
                        translations[cue.id] = cleaned
                        cacheEntries.append(
                            .init(translatedText: cleaned, source: cue.source)
                        )
                    }
                    await AISubtitleTranslationCache.shared.store(
                        cacheEntries,
                        targetLanguage: settings.targetLanguage,
                        model: settings.cacheModelIdentifier,
                        stripHearingImpaired: settings.stripHearingImpaired,
                        profileScope: profileScope
                    )
                }
                guard !Task.isCancelled,
                      let self,
                      self.sessionID == activeSession else { return }
                self.finishBatch(
                    cues: pendingCues,
                    translations: translations,
                    outcome: .success(())
                )
            } catch is CancellationError {
                guard let self, self.sessionID == activeSession else { return }
                self.batchTask = nil
                self.translatingCueIDs.subtract(pendingCues.map(\.id))
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sessionID == activeSession else { return }
                self.finishBatch(
                    cues: pendingCues,
                    translations: [:],
                    outcome: .failure(error)
                )
            }
        }
    }

    private func startPriorityTranslations(
        from availableCues: [PendingCue],
        settings: AISubtitleTranslationSettings
    ) {
        let availablePriorityCues = availableCues.filter { cue in
            remainingPriorityCueIDs.contains(cue.id) && priorityTasks[cue.id] == nil
        }
        let slots = maximumConcurrentPriorityRequests - priorityTasks.count
        guard slots > 0 else { return }

        let activeSession = sessionID
        let profileScope = ProfileSettings.activeProfileScope
        for cue in availablePriorityCues.prefix(slots) {
            translatingCueIDs.insert(cue.id)
            priorityTasks[cue.id] = Task { [weak self] in
                do {
                    let translated: String
                    if let cached = await AISubtitleTranslationCache.shared.translation(
                        for: cue.source,
                        targetLanguage: settings.targetLanguage,
                        model: settings.cacheModelIdentifier,
                        stripHearingImpaired: settings.stripHearingImpaired,
                        profileScope: profileScope
                    ) {
                        translated = cached
                    } else {
                        let response = try await AISubtitleTranslator.translate(cue.source, settings: settings)
                        translated = Self.cleaned(
                            response,
                            stripHearingImpaired: settings.stripHearingImpaired
                        )
                        await AISubtitleTranslationCache.shared.store(
                            translated,
                            for: cue.source,
                            targetLanguage: settings.targetLanguage,
                            model: settings.cacheModelIdentifier,
                            stripHearingImpaired: settings.stripHearingImpaired,
                            profileScope: profileScope
                        )
                    }
                    guard !Task.isCancelled,
                          let self,
                          self.sessionID == activeSession else { return }
                    self.finishPriorityCue(cue, translated: translated, outcome: .success(()))
                } catch is CancellationError {
                    guard let self, self.sessionID == activeSession else { return }
                    self.priorityTasks[cue.id] = nil
                    self.translatingCueIDs.remove(cue.id)
                    self.startNextBatchIfNeeded(
                        settings: self.currentSettings ?? AISubtitleTranslationSettings.current()
                    )
                } catch {
                    guard !Task.isCancelled,
                          let self,
                          self.sessionID == activeSession else { return }
                    self.finishPriorityCue(cue, translated: nil, outcome: .failure(error))
                }
            }
        }
    }

    private func finishPriorityCue(
        _ cue: PendingCue,
        translated: String?,
        outcome: Result<Void, Error>
    ) {
        priorityTasks[cue.id] = nil
        translatingCueIDs.remove(cue.id)
        if urgentPriorityCueID == cue.id { urgentPriorityCueID = nil }
        switch outcome {
        case .success:
            if let translated {
                translatedTextByCueID[cue.id] = translated
                translatedTextBySource[cue.sourceIdentity] = translated
            }
            remainingPriorityCueIDs.removeAll { $0 == cue.id }
            report(outcome)
            startNextBatchIfNeeded(settings: currentSettings ?? AISubtitleTranslationSettings.current())
        case .failure(let error):
            failedCueIDs.insert(cue.id)
            remainingPriorityCueIDs.removeAll { $0 == cue.id }
            if (error as? AISubtitleTranslationError)?.isPermanentLimitError == true {
                stopTranslationAfterPermanentProviderFailure()
            }
            report(outcome)
            if !hasPermanentProviderFailure {
                startNextBatchIfNeeded(settings: currentSettings ?? AISubtitleTranslationSettings.current())
            }
        }
        onCueTranslationResolved?(cue.id)
    }

    private func finishBatch(
        cues: [PendingCue],
        translations: [Int: String],
        outcome: Result<Void, Error>
    ) {
        batchTask = nil
        translatingCueIDs.subtract(cues.map(\.id))
        let completedIDs = Set(cues.map(\.id))
        remainingPriorityCueIDs.removeAll { completedIDs.contains($0) }
        switch outcome {
        case .success:
            translatedTextByCueID.merge(translations) { _, replacement in replacement }
            for cue in cues {
                if let translated = translations[cue.id] {
                    translatedTextBySource[cue.sourceIdentity] = translated
                }
            }
            if let nextStart = nextUntranslatedCueStart(settings: currentSettings),
               AISubtitleAdaptiveBuffer.shouldRefill(
                nextUntranslatedStart: nextStart,
                sourceTime: lastSourceTime
               ) {
                nextBatchStartAt = Date().addingTimeInterval(catchUpBatchInterval)
            } else {
                nextBatchStartAt = .distantPast
            }
            report(outcome)
            startNextBatchIfNeeded(settings: currentSettings ?? AISubtitleTranslationSettings.current())
        case .failure(let error):
            failedCueIDs.formUnion(cues.map(\.id))
            if (error as? AISubtitleTranslationError)?.isPermanentLimitError == true {
                stopTranslationAfterPermanentProviderFailure()
            }
            report(outcome)
            if !hasPermanentProviderFailure {
                startNextBatchIfNeeded(settings: currentSettings ?? AISubtitleTranslationSettings.current())
            }
        }
        cues.forEach { onCueTranslationResolved?($0.id) }
    }

    private func nextUntranslatedCueStart(
        settings: AISubtitleTranslationSettings?
    ) -> Double? {
        guard let settings else { return nil }
        return lastCues.lazy
            .filter { cue in
                cue.endTime >= self.lastSourceTime &&
                    !self.failedCueIDs.contains(cue.id) &&
                    cue.text != nil &&
                    self.translation(for: cue, settings: settings) == nil
            }
            .compactMap { cue -> Double? in
                guard let text = cue.text else { return nil }
                let source = Self.cleaned(
                    text,
                    stripHearingImpaired: settings.stripHearingImpaired
                )
                return source.isEmpty ? nil : cue.startTime
            }
            .min()
    }

    private func scheduleNextBatch(at date: Date, settings: AISubtitleTranslationSettings) {
        delayedBatchTask?.cancel()
        let activeSession = sessionID
        let delay = max(0, date.timeIntervalSinceNow)
        delayedBatchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.sessionID == activeSession else { return }
            self.delayedBatchTask = nil
            self.startNextBatchIfNeeded(settings: settings)
        }
    }

    private func report(_ outcome: Result<Void, Error>) {
        switch outcome {
        case .success where !didReportSuccess:
            didReportSuccess = true
            onFirstOutcome?(outcome)
        case .failure where !didReportFailure:
            didReportFailure = true
            onFirstOutcome?(outcome)
        default:
            break
        }
    }

    private func deactivate() {
        cancelTranslationWork()
        failedCueIDs = []
        hasPermanentProviderFailure = false
        currentSettings = nil
        sessionID = UUID()
        nextBatchStartAt = .distantPast
        remainingPriorityCueIDs = []
        urgentPriorityCueID = nil
        needsPriorityPrefetch = true
        if !translatedTextByCueID.isEmpty { translatedTextByCueID = [:] }
        if !translatedTextBySource.isEmpty { translatedTextBySource = [:] }
        if !translatingCueIDs.isEmpty { translatingCueIDs = [] }
    }

    private func cancelTranslationWork() {
        batchTask?.cancel()
        delayedBatchTask?.cancel()
        priorityTasks.values.forEach { $0.cancel() }
        batchTask = nil
        delayedBatchTask = nil
        priorityTasks = [:]
    }

    private func stopTranslationAfterPermanentProviderFailure() {
        hasPermanentProviderFailure = true
        cancelTranslationWork()
        translatingCueIDs = []
        remainingPriorityCueIDs = []
        urgentPriorityCueID = nil
        nextBatchStartAt = .distantPast
    }

    /// Removes the common SDH / hearing-impaired annotations before the cue is
    /// sent and after the model responds. Dialogue on the same cue is retained.
    static func cleaned(_ text: String, stripHearingImpaired: Bool) -> String {
        var result = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"\{(\\(?:an\d+|pos\([^)]*\)|fn[^{}\\\s]+|r[^{}\\\s]+|fad\([^)]*\)|fade\([^)]*\)|[1-4]?c&[Hh]?[0-9A-Fa-f]+&?|[1-4]?a&[Hh]?[0-9A-Fa-f]+&?|alpha&[Hh]?[0-9A-Fa-f]+&?|[biuso]\d+|fs\d+|fsc[xy]\d+|fsp\d+|fr[xyz]?\d+|fe\d+|k[f|o]?\d+|q\d+|p\d+|pbo\d+|bord\d+|shad\d+|blur\d+|be\d+|clip\([^)]*\)|iclip\([^)]*\)|t\([^)]*\)|move\([^)]*\)|org\([^)]*\))[^{}\\]*)+\}"#,
                with: "",
                options: .regularExpression
            )
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

    /// Aether can recreate a cue with a new ID after seeking. Keep the
    /// on-screen translation associated with its normalized source text too.
    static func normalizedSource(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translation(
        for cue: SubtitleCue,
        settings: AISubtitleTranslationSettings
    ) -> String? {
        if let translated = translatedTextByCueID[cue.id] {
            return translated
        }
        guard let source = cue.text else { return nil }
        let cleaned = Self.cleaned(source, stripHearingImpaired: settings.stripHearingImpaired)
        return translatedTextBySource[Self.normalizedSource(cleaned)]
    }
}

enum AISubtitleTranslationError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case service(statusCode: Int, message: String, retryAfter: TimeInterval?)

    var isRetryable: Bool {
        switch self {
        case .service(let statusCode, _, _):
            return !isPermanentLimitError
                && (statusCode == 429 || (500...599).contains(statusCode))
        case .missingAPIKey, .invalidResponse:
            return false
        }
    }

    var isPermanentLimitError: Bool {
        guard case .service(_, let message, let retryAfter) = self else { return false }
        // Providers commonly describe temporary RPM/TPM throttles as a
        // "quota" error. A retry hint means the condition is temporary.
        guard retryAfter == nil else { return false }
        return Self.isPermanentQuotaOrBillingLimit(message)
    }

    var shouldSplitBatch: Bool {
        switch self {
        case .invalidResponse:
            return true
        case .service(let statusCode, let message, _):
            let normalized = message.lowercased()
            return statusCode == 413
                || ((400...499).contains(statusCode)
                    && ["too large", "context length", "token limit", "maximum tokens", "request size"]
                        .contains { normalized.contains($0) })
        case .missingAPIKey:
            return false
        }
    }

    var retryAfter: TimeInterval? {
        guard case .service(_, _, let retryAfter) = self else { return nil }
        return retryAfter
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key for the selected provider in Settings → Integrations → AI Subtitles."
        case .invalidResponse:
            return "The AI subtitle provider returned no translated text. Original subtitles will remain visible."
        case .service where isPermanentLimitError:
            return "AI subtitle translation stopped because the provider reported a quota, billing, credit, or daily limit. Original subtitles will remain visible."
        case .service(_, let message, _):
            return message
        }
    }

    private static func isPermanentQuotaOrBillingLimit(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return [
            "billing",
            "credit",
            "daily limit",
            "daily-limit",
            "daily quota",
            "quota exhausted",
            "quota_exhausted",
            "insufficient quota",
            "insufficient funds",
            "payment required",
        ].contains { normalized.contains($0) }
    }
}

struct AISubtitleTranslationItem: Sendable {
    let id: Int
    let text: String
}

/// Batches always end at a cue boundary. The estimates deliberately reserve
/// room for the translation prompt, JSON envelope, and a longer translated
/// response, not just the source text sent to the provider.
enum AISubtitleBatching {
    static let maximumCueCount = 40
    static let maximumEstimatedRequestBytes = 24_000
    static let maximumEstimatedRequestTokens = 6_000

    static func batches(_ items: [AISubtitleTranslationItem]) -> [[AISubtitleTranslationItem]] {
        guard !items.isEmpty else { return [] }
        var result: [[AISubtitleTranslationItem]] = []
        var batch: [AISubtitleTranslationItem] = []

        for item in items {
            let candidate = batch + [item]
            if !batch.isEmpty && !fits(candidate) {
                result.append(batch)
                batch = [item]
            } else {
                batch = candidate
            }
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }

    static func splitInHalf(_ items: [AISubtitleTranslationItem]) -> (
        [AISubtitleTranslationItem], [AISubtitleTranslationItem]
    ) {
        let midpoint = items.count / 2
        return (Array(items[..<midpoint]), Array(items[midpoint...]))
    }

    static func estimatedInputTokens(for items: [AISubtitleTranslationItem]) -> Int {
        let sourceBytes = items.reduce(0) { $0 + $1.text.utf8.count }
        // Subtitle text is mostly Latin but names and CJK content can cost
        // more; three bytes per token is a conservative lightweight estimate.
        return (sourceBytes + 2) / 3
    }

    static func estimatedRequestBytes(for items: [AISubtitleTranslationItem]) -> Int {
        let sourceBytes = items.reduce(0) { $0 + $1.text.utf8.count }
        let jsonAndIDOverhead = items.count * 48
        let promptReserve = 1_800
        let outputReserve = Int(Double(sourceBytes) * 1.8) + items.count * 64
        return promptReserve + sourceBytes + jsonAndIDOverhead + outputReserve
    }

    static func estimatedRequestTokens(for items: [AISubtitleTranslationItem]) -> Int {
        let input = estimatedInputTokens(for: items)
        let promptAndJSONReserve = 420 + items.count * 12
        let translatedOutputReserve = Int(Double(input) * 1.8)
        return promptAndJSONReserve + input + translatedOutputReserve
    }

    static func outputTokenLimit(for items: [AISubtitleTranslationItem]) -> Int {
        let sourceTokens = estimatedInputTokens(for: items)
        let jsonOverhead = items.count * 8 + 160
        let output = Int(Double(sourceTokens) * 1.8) + jsonOverhead
        return min(2_048, max(512, output))
    }

    private static func fits(_ items: [AISubtitleTranslationItem]) -> Bool {
        // A single cue cannot be split further. Send it by itself so a
        // provider-specific size error can be surfaced without dropping it.
        guard items.count > 1 else { return true }
        return items.count <= maximumCueCount
            && estimatedRequestBytes(for: items) <= maximumEstimatedRequestBytes
            && estimatedRequestTokens(for: items) <= maximumEstimatedRequestTokens
    }
}

enum AISubtitleBatchRecovery {
    static let maximumInvalidResponseSplitDepth = 2

    static func translate(
        _ items: [AISubtitleTranslationItem],
        operation: @escaping ([AISubtitleTranslationItem]) async throws -> [Int: String]
    ) async throws -> [Int: String] {
        try await translate(
            items,
            invalidResponseSplitDepth: 0,
            operation: operation
        )
    }

    private static func translate(
        _ items: [AISubtitleTranslationItem],
        invalidResponseSplitDepth: Int,
        operation: @escaping ([AISubtitleTranslationItem]) async throws -> [Int: String]
    ) async throws -> [Int: String] {
        do {
            let translations = try await operation(items)
            try validate(translations, for: items)
            return translations
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard items.count > 1,
                  let translationError = error as? AISubtitleTranslationError,
                  translationError.shouldSplitBatch else {
                throw error
            }
            let nextInvalidResponseSplitDepth: Int
            if case .invalidResponse = translationError {
                guard invalidResponseSplitDepth < maximumInvalidResponseSplitDepth else {
                    throw error
                }
                nextInvalidResponseSplitDepth = invalidResponseSplitDepth + 1
            } else {
                // Explicit request-size/context errors may keep splitting down
                // to one cue; malformed model output gets only a small budget.
                nextInvalidResponseSplitDepth = invalidResponseSplitDepth
            }
            let (first, second) = AISubtitleBatching.splitInHalf(items)
            let firstTranslations = try await translate(
                first,
                invalidResponseSplitDepth: nextInvalidResponseSplitDepth,
                operation: operation
            )
            let secondTranslations = try await translate(
                second,
                invalidResponseSplitDepth: nextInvalidResponseSplitDepth,
                operation: operation
            )
            var combined = firstTranslations
            for (id, text) in secondTranslations {
                guard combined[id] == nil else {
                    throw AISubtitleTranslationError.invalidResponse
                }
                combined[id] = text
            }
            try validate(combined, for: items)
            return combined
        }
    }

    private static func validate(
        _ translations: [Int: String],
        for items: [AISubtitleTranslationItem]
    ) throws {
        let expectedIDs = Set(items.map(\.id))
        guard expectedIDs.count == items.count,
              translations.count == expectedIDs.count,
              Set(translations.keys) == expectedIDs,
              translations.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AISubtitleTranslationError.invalidResponse
        }
    }
}

enum AISubtitleRetryPolicy {
    static let maximumAttempts = 5

    /// `completedAttempts` includes the failed request that just completed.
    static func delay(
        for error: Error,
        completedAttempts: Int,
        jitterMultiplier: Double? = nil
    ) -> TimeInterval? {
        guard completedAttempts < maximumAttempts else { return nil }
        if let error = error as? AISubtitleTranslationError,
           error.isRetryable {
            if let retryAfter = error.retryAfter { return retryAfter }
        } else if let error = error as? URLError,
                  error.code != .cancelled {
            // Network transport errors have no server retry hint.
        } else {
            return nil
        }
        let baseDelay = min(60, pow(2, Double(completedAttempts - 1)) * 4)
        let jitter = jitterMultiplier ?? Double.random(in: 0.85...1.15)
        return min(60, baseDelay * min(1.15, max(0.85, jitter)))
    }

    static func retryAfter(from headerValue: String, now: Date = Date()) -> TimeInterval? {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

actor AISubtitleRequestPacer {
    struct Scope: Hashable, Sendable {
        let provider: String
        let model: String
    }

    static let shared = AISubtitleRequestPacer()

    private let minimumSpacing: TimeInterval
    private var nextStartByScope: [Scope: Date] = [:]
    private var acquisitionCountByScope: [Scope: Int] = [:]

    init(minimumSpacing: TimeInterval = 0.35) {
        self.minimumSpacing = max(0, minimumSpacing)
    }

    func acquire(provider: String, model: String) async throws {
        let scope = Scope(provider: provider.lowercased(), model: model.lowercased())
        let now = Date()
        let scheduled = max(now, nextStartByScope[scope] ?? now)
        nextStartByScope[scope] = scheduled.addingTimeInterval(minimumSpacing)
        acquisitionCountByScope[scope, default: 0] += 1
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
    }

    func acquisitionCount(provider: String, model: String) -> Int {
        acquisitionCountByScope[
            Scope(provider: provider.lowercased(), model: model.lowercased())
        ] ?? 0
    }
}

enum AISubtitleTranslator {
    static func translate(
        _ source: String,
        settings: AISubtitleTranslationSettings,
        session: URLSession = .shared,
        pacer: AISubtitleRequestPacer = .shared
    ) async throws -> String {
        guard !settings.apiKey.isEmpty else { throw AISubtitleTranslationError.missingAPIKey }
        return try await execute(settings: settings, pacer: pacer) {
            switch settings.provider {
            case .gemini:
                return try await GeminiSubtitleTranslator.translate(
                    source,
                    to: settings.targetLanguage,
                    model: settings.model,
                    apiKey: settings.apiKey,
                    session: session
                )
            case .openRouter:
                return try await OpenRouterSubtitleTranslator.translate(
                    source,
                    to: settings.targetLanguage,
                    model: settings.model,
                    apiKey: settings.apiKey,
                    session: session
                )
            }
        }
    }

    static func translateBatch(
        _ items: [AISubtitleTranslationItem],
        settings: AISubtitleTranslationSettings,
        session: URLSession = .shared,
        pacer: AISubtitleRequestPacer = .shared
    ) async throws -> [Int: String] {
        guard !settings.apiKey.isEmpty else { throw AISubtitleTranslationError.missingAPIKey }
        return try await execute(settings: settings, pacer: pacer) {
            switch settings.provider {
            case .gemini:
                return try await GeminiSubtitleTranslator.translateBatch(
                    items,
                    to: settings.targetLanguage,
                    model: settings.model,
                    apiKey: settings.apiKey,
                    session: session
                )
            case .openRouter:
                return try await OpenRouterSubtitleTranslator.translateBatch(
                    items,
                    to: settings.targetLanguage,
                    model: settings.model,
                    apiKey: settings.apiKey,
                    session: session
                )
            }
        }
    }

    private static func execute<T>(
        settings: AISubtitleTranslationSettings,
        pacer: AISubtitleRequestPacer,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var completedAttempts = 0
        while true {
            try Task.checkCancellation()
            try await pacer.acquire(provider: settings.provider.rawValue, model: settings.model)
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                completedAttempts += 1
                guard let delay = AISubtitleRetryPolicy.delay(
                    for: error,
                    completedAttempts: completedAttempts
                ) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

enum GeminiSubtitleTranslator {
    typealias BatchItem = AISubtitleTranslationItem

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
        let topP: Double?
        let topK: Int?
        let maxOutputTokens: Int
        let responseMimeType: String?
        let thinkingConfig: ThinkingConfig

        private enum CodingKeys: String, CodingKey {
            case temperature
            case topP
            case topK
            case maxOutputTokens
            case responseMimeType
            case thinkingConfig
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(temperature, forKey: .temperature)
            try container.encodeIfPresent(topP, forKey: .topP)
            try container.encodeIfPresent(topK, forKey: .topK)
            try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
            try container.encodeIfPresent(responseMimeType, forKey: .responseMimeType)
            try container.encode(thinkingConfig, forKey: .thinkingConfig)
        }
    }

    private struct ThinkingConfig: Encodable {
        /// Gemini 3's minimum level is the closest supported equivalent to
        /// disabling reasoning; its API does not permit turning it fully off.
        let thinkingLevel: String
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
        let thought: Bool?
    }

    private struct ErrorBody: Decodable {
        let error: APIError?
    }

    private struct APIError: Decodable {
        let message: String?
    }

    private struct BatchInput: Encodable {
        let id: Int
        let text: String
    }

    private struct BatchOutput: Decodable {
        let id: Int
        let text: String
    }

    static func translate(
        _ source: String,
        to targetLanguage: String,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        let prompt = """
        Translate the film or television subtitle enclosed in <subtitle> into \(targetLanguage).
        Return only natural subtitle text. Preserve meaning, dialogue tone, character voice, proper names, and line breaks; do not add labels, explanations, quotation marks, or annotations.
        <subtitle>
        \(source)
        </subtitle>
        """
        let body = RequestBody(
            contents: [Content(parts: [Part(text: prompt)])],
            generationConfig: generationConfig(
                model: model,
                maxOutputTokens: 256,
                responseMimeType: nil
            )
        )
        let text = try await generate(
            body,
            model: model,
            apiKey: apiKey,
            timeout: 12,
            session: session
        )
        guard !text.isEmpty else { throw AISubtitleTranslationError.invalidResponse }
        return text
    }

    static func translateBatch(
        _ items: [BatchItem],
        to targetLanguage: String,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let source = try String(
            decoding: JSONEncoder().encode(items.map { BatchInput(id: $0.id, text: $0.text) }),
            as: UTF8.self
        )
        let prompt = """
        Translate every film or television subtitle in the JSON array into \(targetLanguage).
        Return only a JSON array. Each output object must contain the original integer `id` and its translated `text`.
        Include every input id exactly once. Use neighbouring cues only to resolve dialogue context. Preserve meaning, tone, character voice, proper names, and line breaks. Do not add labels, explanations, quotation marks, or annotations.
        <subtitles>
        \(source)
        </subtitles>
        """
        let body = RequestBody(
            contents: [Content(parts: [Part(text: prompt)])],
            generationConfig: generationConfig(
                model: model,
                maxOutputTokens: AISubtitleBatching.outputTokenLimit(for: items),
                // Gemma 4 supports generateContent, but it is not listed for
                // Gemini structured output. Its prompt still requests JSON.
                responseMimeType: isGemma4(model) ? nil : "application/json"
            )
        )
        let response = try await generate(
            body,
            model: model,
            apiKey: apiKey,
            timeout: 30,
            session: session
        )
        guard let outputs = try? JSONDecoder().decode(
            [BatchOutput].self,
            from: Data(stripMarkdownCodeFence(from: response).utf8)
        ) else {
            throw AISubtitleTranslationError.invalidResponse
        }
        let expectedIDs = Set(items.map(\.id))
        var translations: [Int: String] = [:]
        for output in outputs {
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard expectedIDs.contains(output.id), !text.isEmpty, translations[output.id] == nil else {
                throw AISubtitleTranslationError.invalidResponse
            }
            translations[output.id] = text
        }
        guard translations.count == expectedIDs.count else {
            throw AISubtitleTranslationError.invalidResponse
        }
        return translations
    }

    private static func generate(
        _ body: RequestBody,
        model: String,
        apiKey: String,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> String {
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw AISubtitleTranslationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AISubtitleTranslationError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let serviceError = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw AISubtitleTranslationError.service(
                statusCode: http.statusCode,
                message: serviceError?.error?.message ?? "Gemini request failed (HTTP \(http.statusCode)).",
                retryAfter: retryAfter(from: http)
            )
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = decoded.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stripGemmaThoughtChannel(from: text, model: model)
    }

    private static func generationConfig(
        model: String,
        maxOutputTokens: Int,
        responseMimeType: String?
    ) -> GenerationConfig {
        let gemma4 = isGemma4(model)
        return GenerationConfig(
            temperature: gemma4 ? 1.0 : 0.1,
            topP: gemma4 ? 0.95 : nil,
            topK: gemma4 ? 64 : nil,
            maxOutputTokens: maxOutputTokens,
            responseMimeType: responseMimeType,
            thinkingConfig: ThinkingConfig(thinkingLevel: "minimal")
        )
    }

    private static func isGemma4(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gemma-4-")
    }

    private static func stripGemmaThoughtChannel(from text: String, model: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGemma4(model),
              let marker = trimmed.range(of: "<channel|>", options: .backwards) else {
            return trimmed
        }
        return String(trimmed[marker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripMarkdownCodeFence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let withoutOpeningFence = trimmed.drop { $0 != "\n" }.dropFirst()
        return String(withoutOpeningFence)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return AISubtitleRetryPolicy.retryAfter(from: value)
    }
}

enum OpenRouterSubtitleTranslator {
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let systemPrompt = "You are an expert film and television subtitle translator. Translate only dialogue and on-screen text. Preserve meaning, tone, character voice, proper names, and subtitle line breaks. Do not add explanations, summaries, censoring, or annotations. Follow the requested output format exactly."

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let reasoning: Reasoning?

        private enum CodingKeys: String, CodingKey {
            case model, messages, temperature, reasoning
            case maxTokens = "max_tokens"
        }
    }

    private struct Reasoning: Encodable {
        let enabled: Bool
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct ResponseBody: Decodable {
        let choices: [Choice]?
    }

    private struct Choice: Decodable {
        let message: ResponseMessage?
    }

    private struct ResponseMessage: Decodable {
        let content: String?
    }

    private struct ErrorBody: Decodable {
        let error: APIError?
    }

    private struct APIError: Decodable {
        let message: String?
    }

    private struct BatchInput: Encodable {
        let id: Int
        let text: String
    }

    private struct BatchOutput: Decodable {
        let id: Int
        let text: String
    }

    static func translate(
        _ source: String,
        to targetLanguage: String,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        let prompt = """
        Translate the film or television subtitle enclosed in <subtitle> into \(targetLanguage).
        Return only natural subtitle text. Preserve meaning, dialogue tone, character voice, proper names, and line breaks; do not add labels, explanations, quotation marks, or annotations.
        <subtitle>
        \(source)
        </subtitle>
        """
        let text = try await complete(
            model: model,
            prompt: prompt,
            apiKey: apiKey,
            maxTokens: 256,
            timeout: 12,
            session: session
        )
        guard !text.isEmpty else { throw AISubtitleTranslationError.invalidResponse }
        return text
    }

    static func translateBatch(
        _ items: [AISubtitleTranslationItem],
        to targetLanguage: String,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let source = try String(
            decoding: JSONEncoder().encode(items.map { BatchInput(id: $0.id, text: $0.text) }),
            as: UTF8.self
        )
        let prompt = """
        Translate every film or television subtitle in the JSON array into \(targetLanguage).
        Return only a JSON array. Each output object must contain the original integer `id` and its translated `text`.
        Include every input id exactly once. Use neighbouring cues only to resolve dialogue context. Preserve meaning, tone, character voice, proper names, and line breaks. Do not add labels, explanations, quotation marks, or annotations.
        <subtitles>
        \(source)
        </subtitles>
        """
        let response = try await complete(
            model: model,
            prompt: prompt,
            apiKey: apiKey,
            maxTokens: batchOutputTokenLimit(for: items),
            timeout: 30,
            session: session
        )
        guard let outputs = try? JSONDecoder().decode(
            [BatchOutput].self,
            from: Data(stripMarkdownCodeFence(from: response).utf8)
        ) else {
            throw AISubtitleTranslationError.invalidResponse
        }
        let expectedIDs = Set(items.map(\.id))
        var translations: [Int: String] = [:]
        for output in outputs {
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard expectedIDs.contains(output.id), !text.isEmpty, translations[output.id] == nil else {
                throw AISubtitleTranslationError.invalidResponse
            }
            translations[output.id] = text
        }
        guard translations.count == expectedIDs.count else {
            throw AISubtitleTranslationError.invalidResponse
        }
        return translations
    }

    private static func complete(
        model: String,
        prompt: String,
        apiKey: String,
        maxTokens: Int,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> String {
        let body = RequestBody(
            model: model,
            messages: [
                Message(role: "system", content: systemPrompt),
                Message(role: "user", content: prompt),
            ],
            temperature: 0.1,
            maxTokens: maxTokens,
            reasoning: Reasoning(enabled: false)
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AISubtitleTranslationError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let serviceError = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw AISubtitleTranslationError.service(
                statusCode: http.statusCode,
                message: serviceError?.error?.message ?? "OpenRouter request failed (HTTP \(http.statusCode)).",
                retryAfter: retryAfter(from: http)
            )
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        return decoded.choices?
            .compactMap { $0.message?.content }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Translation does not benefit from hidden reasoning. The dynamic
    /// completion cap also prevents a short batch from consuming the former
    /// blanket 4,096-token allowance.
    static func batchOutputTokenLimit(for items: [AISubtitleTranslationItem]) -> Int {
        AISubtitleBatching.outputTokenLimit(for: items)
    }

    private static func stripMarkdownCodeFence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let withoutOpeningFence = trimmed.drop { $0 != "\n" }.dropFirst()
        return String(withoutOpeningFence)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return AISubtitleRetryPolicy.retryAfter(from: value)
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
        sourceURL: URL? = nil,
        httpHeaders: [String: String] = [:]
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
                    httpHeaders: headers(for: url, matching: sourceURL, from: httpHeaders)
                )
            )
            urlsByTrackID[id] = subtitle.url
        }
        return AetherExternalSubtitleRegistration(tracks: tracks, urlsByTrackID: urlsByTrackID)
    }

    /// Reuse video request headers only for subtitles on that same HTTP origin.
    static func headers(for subtitleURL: URL, matching sourceURL: URL?, from headers: [String: String]) -> [String: String] {
        guard !headers.isEmpty,
              let sourceURL,
              let subtitleScheme = subtitleURL.scheme?.lowercased(),
              let sourceScheme = sourceURL.scheme?.lowercased(),
              let subtitleHost = subtitleURL.host,
              let sourceHost = sourceURL.host,
              ["http", "https"].contains(subtitleScheme),
              subtitleScheme == sourceScheme,
              subtitleHost.caseInsensitiveCompare(sourceHost) == .orderedSame else {
            return [:]
        }
        let defaultPort = sourceScheme == "https" ? 443 : 80
        guard (subtitleURL.port ?? defaultPort) == (sourceURL.port ?? defaultPort) else {
            return [:]
        }
        return headers
    }
}

enum AetherPlaybackLifecyclePolicy {
    static let maximumActiveCancellationRetries = 1

    static func shouldReloadAfterBackground(state: PlaybackState) -> Bool {
        switch state {
        case .playing, .paused, .loading, .seeking:
            return true
        default:
            return false
        }
    }

    static func shouldResumeAfterBackground(
        state: PlaybackState,
        isPlayerPlaying: Bool,
        isTransportPlaying: Bool,
        previousIntent: Bool
    ) -> Bool {
        previousIntent
            || state == .playing
            || (state != .paused && (isPlayerPlaying || isTransportPlaying))
    }

    enum ReloadFailureDisposition: Equatable {
        case ignore
        case keepPending
        case retryAfterTaskClears
        case report
    }

    static func reloadFailureDisposition(
        isCancellation: Bool,
        tokenIsCurrent: Bool,
        applicationIsActive: Bool,
        activeCancellationRetryCount: Int
    ) -> ReloadFailureDisposition {
        guard tokenIsCurrent else { return .ignore }
        guard applicationIsActive else { return .keepPending }
        if isCancellation {
            return activeCancellationRetryCount < maximumActiveCancellationRetries
                ? .retryAfterTaskClears
                : .report
        }
        return .report
    }
}

/// Pure sampling and lookup rules for the bounded seek-thumbnail index.
enum HybridSeekThumbnailPolicy {
    static let fineBucketSeconds: Double = 0.5
    static let coarseIntervalSeconds: Double = 60
    static let maximumCoarseSamples = 120
    static let maximumPreviewTimeError: Double = 0.5

    static func fineBucket(for seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int(floor(seconds / fineBucketSeconds))
    }

    static func coarseSampleTimes(
        duration: Double,
        interval: Double = coarseIntervalSeconds,
        maximumSamples: Int = maximumCoarseSamples
    ) -> [Double] {
        guard duration.isFinite, duration >= interval, interval >= coarseIntervalSeconds,
              maximumSamples > 0 else { return [] }
        let count = min(maximumSamples, max(1, Int(ceil(duration / interval))))
        let chronological = (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
        var ordered: [Double] = []
        ordered.reserveCapacity(count)

        // Breadth-first subdivision: midpoint, quarters, eighths, ... gives
        // useful coverage across the whole title before local refinement.
        var ranges: [(Int, Int)] = [(0, count - 1)]
        while !ranges.isEmpty {
            let (lower, upper) = ranges.removeFirst()
            guard lower <= upper else { continue }
            let middle = (lower + upper) / 2
            ordered.append(chronological[middle])
            if lower < middle { ranges.append((lower, middle - 1)) }
            if middle < upper { ranges.append((middle + 1, upper)) }
        }
        return ordered.filter { $0 > 0 && $0 < duration }
    }

    static func coarseLookupTolerance(
        duration: Double,
        interval: Double = coarseIntervalSeconds,
        maximumSamples: Int = maximumCoarseSamples
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        // Coarse entries provide nearest-neighbor fallback coverage within a tight bounds
        // (<= 10 seconds) so distant frames are never shown as misleading matches.
        return min(10.0, max(2.0, duration / Double(max(1, maximumSamples * 6))))
    }

    static func acceptsCoarse(
        sampleSeconds: Double,
        targetSeconds: Double,
        duration: Double,
        interval: Double = coarseIntervalSeconds
    ) -> Bool {
        guard sampleSeconds.isFinite, targetSeconds.isFinite else { return false }
        return abs(sampleSeconds - targetSeconds)
            <= coarseLookupTolerance(duration: duration, interval: interval)
    }
}

// MARK: - Trickplay Protocol & Caching

/// Common interface for trickplay thumbnail providers (WebVTT, BIF, or custom sprite sheets).
protocol TrickplayProviding: AnyObject, Sendable {
    func thumbnail(at seconds: Double) async -> CGImage?
}

/// High-performance persistent disk cache for video seek preview stills.
/// Stores lightweight compressed JPEGs (~15 KB) under `Caches/Trickplay/<streamKey>/`.
/// Uses memory-mapped reads (`.mappedIfSafe`) to return `CGImage` in ~0.5 ms.
actor TrickplayDiskCache {
    static let shared = TrickplayDiskCache()

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let maxDiskBytes: Int64 = 100 * 1024 * 1024 // 100 MB budget
    private var lastPruneTime = Date.distantPast

    init(directoryOverride: URL? = nil) {
        if let override = directoryOverride {
            self.baseDirectory = override
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.baseDirectory = caches.appendingPathComponent("Trickplay", isDirectory: true)
        }
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Fast, deterministic identifier for a stream source.
    static func streamKey(for urlString: String, duration: Double = 0) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        let seed = trimmed + (duration > 0 ? "_\(Int(duration))" : "")
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }

    /// Canonical content identifier hashing IMDb/Cinemeta ID, season, episode, and duration bucket.
    /// Uses 10-second duration buckets like VortX to prevent different cuts/releases from sharing previews.
    static func canonicalKey(
        contentId: String?,
        season: Int? = nil,
        episode: Int? = nil,
        duration: Double? = nil,
        fallbackURL: String = ""
    ) -> String {
        let id = (contentId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !id.isEmpty {
            let s = season ?? 0
            let e = episode ?? 0
            let durBucket = duration.map { Int(floor($0 / 10.0)) * 10 } ?? 0
            let raw = "\(id):\(s):\(e):\(durBucket)"
            let digest = SHA256.hash(data: Data(raw.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "canon_\(hex.prefix(16))"
        }
        return streamKey(for: fallbackURL, duration: duration ?? 0)
    }

    private func itemDirectory(for streamKey: String) -> URL {
        baseDirectory.appendingPathComponent(streamKey, isDirectory: true)
    }

    /// Looks up a cached frame and its true timestamp for a given stream key.
    func lookupWithTimestamp(streamKey: String, seconds: Double, tolerance: Double = 2.0) -> (image: CGImage, seconds: Double)? {
        guard !streamKey.isEmpty, seconds.isFinite, seconds >= 0 else { return nil }
        let targetBucket = Int(seconds.rounded())
        let dir = itemDirectory(for: streamKey)

        // 1. Direct hit on exact rounded second
        let exactFile = dir.appendingPathComponent("\(targetBucket).jpg")
        if let image = loadImage(at: exactFile) {
            return (image, Double(targetBucket))
        }

        // 2. Tolerance search for nearest neighbor within tolerance
        let maxDelta = max(0, Int(ceil(tolerance)))
        if maxDelta > 0 {
            for delta in 1...maxDelta {
                let minusFile = dir.appendingPathComponent("\(targetBucket - delta).jpg")
                if let image = loadImage(at: minusFile) {
                    return (image, Double(targetBucket - delta))
                }
                let plusFile = dir.appendingPathComponent("\(targetBucket + delta).jpg")
                if let image = loadImage(at: plusFile) {
                    return (image, Double(targetBucket + delta))
                }
            }
        }
        return nil
    }

    /// Looks up a cached frame for a given stream key and timestamp.
    /// Returns immediately via memory mapping if found on disk.
    func lookup(streamKey: String, seconds: Double, tolerance: Double = 2.0) -> CGImage? {
        lookupWithTimestamp(streamKey: streamKey, seconds: seconds, tolerance: tolerance)?.image
    }

    /// Asynchronously stores an image to the persistent trickplay disk store.
    func store(image: CGImage, streamKey: String, seconds: Double) {
        guard !streamKey.isEmpty, seconds.isFinite, seconds >= 0 else { return }
        let bucket = Int(seconds.rounded())
        let dir = itemDirectory(for: streamKey)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(bucket).jpg")

        guard let data = encodeJPEG(image: image, quality: 0.72) else { return }
        try? data.write(to: file, options: .atomic)

        let now = Date()
        if now.timeIntervalSince(lastPruneTime) > 300 {
            lastPruneTime = now
            pruneIfNeeded()
        }
    }

    private func loadImage(at url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    private func encodeJPEG(image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        let type = "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Clears frames for a specific stream.
    func clear(streamKey: String) {
        let dir = itemDirectory(for: streamKey)
        try? fileManager.removeItem(at: dir)
    }

    /// Lists all stored JPEG frames for a given stream key, sorted by timestamp.
    func listStoredFrames(streamKey: String) -> [(seconds: Double, fileURL: URL)] {
        guard !streamKey.isEmpty else { return [] }
        let dir = itemDirectory(for: streamKey)
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [(seconds: Double, fileURL: URL)] = []
        for file in files where file.pathExtension.lowercased() == "jpg" {
            let name = file.deletingPathExtension().lastPathComponent
            if let sec = Double(name) {
                result.append((seconds: sec, fileURL: file))
            }
        }
        return result.sorted(by: { $0.seconds < $1.seconds })
    }

    /// Enforces total cache budget by evicting oldest modified directories.
    private func pruneIfNeeded() {
        guard let enumerator = fileManager.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        var itemDirs: [(url: URL, modified: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let dirSize = calculateDirectorySize(at: fileURL)
                totalSize += dirSize
                itemDirs.append((url: fileURL, modified: mod, size: dirSize))
            }
        }

        if totalSize > maxDiskBytes {
            itemDirs.sort { $0.modified < $1.modified }
            for item in itemDirs {
                try? fileManager.removeItem(at: item.url)
                totalSize -= item.size
                if totalSize <= maxDiskBytes * 3 / 4 {
                    break
                }
            }
        }
    }

    private func calculateDirectorySize(at url: URL) -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var size: Int64 = 0
        for file in files {
            size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return size
    }
}

/// WebVTT storyboard trickplay provider.
/// Parses WebVTT cue playlists with `#xywh=x,y,w,h` sprite coordinates
/// and crops thumbnail sub-rectangles with 0% video decoder overhead.
actor WebVTTStoryboardProvider: TrickplayProviding {
    struct Cue: Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let imageURL: URL
        let rect: CGRect
    }

    private let cues: [Cue]
    private var spriteCache: [URL: CGImage] = [:]

    init(cues: [Cue]) {
        self.cues = cues.sorted(by: { $0.startSeconds < $1.startSeconds })
    }

    /// Parses a standard WebVTT storyboard string and a base URL for resolving relative sprite sheet paths.
    nonisolated static func parse(vttContent: String, baseURL: URL) -> WebVTTStoryboardProvider? {
        var parsedCues: [Cue] = []
        let lines = vttContent.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2,
                   let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                   let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces)) {
                    if i + 1 < lines.count {
                        let payload = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let cue = parseCuePayload(payload, start: start, end: end, baseURL: baseURL) {
                            parsedCues.append(cue)
                            i += 1
                        }
                    }
                }
            }
            i += 1
        }

        guard !parsedCues.isEmpty else { return nil }
        return WebVTTStoryboardProvider(cues: parsedCues)
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let components = raw.components(separatedBy: ":")
        guard !components.isEmpty else { return nil }
        var seconds: Double = 0
        if components.count == 3 {
            guard let h = Double(components[0]),
                  let m = Double(components[1]),
                  let s = Double(components[2]) else { return nil }
            seconds = h * 3600 + m * 60 + s
        } else if components.count == 2 {
            guard let m = Double(components[0]),
                  let s = Double(components[1]) else { return nil }
            seconds = m * 60 + s
        } else {
            return Double(raw)
        }
        return seconds
    }

    private static func parseCuePayload(
        _ payload: String,
        start: Double,
        end: Double,
        baseURL: URL
    ) -> Cue? {
        let parts = payload.components(separatedBy: "#xywh=")
        guard parts.count == 2 else { return nil }
        let urlPart = parts[0].trimmingCharacters(in: .whitespaces)
        let coordPart = parts[1].trimmingCharacters(in: .whitespaces)

        let coords = coordPart.components(separatedBy: ",").compactMap { Double($0) }
        guard coords.count == 4 else { return nil }
        let rect = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3])

        let imageURL: URL
        if let direct = URL(string: urlPart), direct.scheme != nil {
            imageURL = direct
        } else {
            imageURL = baseURL.deletingLastPathComponent().appendingPathComponent(urlPart)
        }

        return Cue(startSeconds: start, endSeconds: end, imageURL: imageURL, rect: rect)
    }

    func thumbnail(at seconds: Double) async -> CGImage? {
        guard !cues.isEmpty, seconds.isFinite, seconds >= 0 else { return nil }
        var low = 0
        var high = cues.count - 1
        var matched: Cue?

        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if seconds < cue.startSeconds {
                high = mid - 1
            } else if seconds >= cue.endSeconds {
                low = mid + 1
            } else {
                matched = cue
                break
            }
        }

        guard let targetCue = matched ?? cues.last(where: { $0.startSeconds <= seconds }) ?? cues.first else {
            return nil
        }

        let spriteSheet = await loadSpriteSheet(for: targetCue.imageURL)
        return spriteSheet?.cropping(to: targetCue.rect)
    }

    private func loadSpriteSheet(for url: URL) async -> CGImage? {
        if let cached = spriteCache[url] {
            return cached
        }

        guard let data = try? await URLSession.shared.data(from: url).0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        spriteCache[url] = image
        if spriteCache.count > 10 {
            spriteCache.remove(at: spriteCache.startIndex)
        }

        return image
    }
}

/// Resolves remote WebVTT storyboards and sprite sheets asynchronously.
actor TrickplayResolver {
    static let shared = TrickplayResolver()

    /// Checks direct trickplay URL or community trickplay endpoints.
    func resolve(
        contentId: String?,
        season: Int? = nil,
        episode: Int? = nil,
        duration: Double? = nil,
        directTrickplayURL: URL? = nil
    ) async -> (any TrickplayProviding)? {
        // 1. Direct trickplay URL from stream add-on metadata
        if let direct = directTrickplayURL {
            if let provider = await fetchStoryboard(from: direct) {
                return provider
            }
        }

        // 2. Canonical content identity lookup
        let id = (contentId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return nil }

        let s = season ?? 0
        let e = episode ?? 0
        let server = await MainActor.run {
            ProfileSettings.current.string(forKey: SettingsKey.trickplayServer)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !server.isEmpty, let baseURL = URL(string: server) else { return nil }

        var bucketsToTry: [Int] = []
        if let dur = duration, dur > 0 {
            let baseBucket = Int(floor(dur / 10.0)) * 10
            bucketsToTry = [baseBucket, max(0, baseBucket - 10), baseBucket + 10]
        } else {
            bucketsToTry = [0]
        }

        for durBucket in bucketsToTry {
            let raw = "\(id):\(s):\(e):\(durBucket)"
            let digest = SHA256.hash(data: Data(raw.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let shortHash = String(hex.prefix(16))

            let candidateKeys = [shortHash, "canon_\(shortHash)", hex]
            for key in candidateKeys {
                let manifestURL = baseURL
                    .appendingPathComponent("tp", isDirectory: true)
                    .appendingPathComponent(key, isDirectory: true)
                    .appendingPathComponent("index.vtt", isDirectory: false)
                if let provider = await fetchStoryboard(from: manifestURL) {
                    return provider
                }
            }
        }

        return nil
    }

    func fetchStoryboard(from vttURL: URL) async -> WebVTTStoryboardProvider? {
        var request = URLRequest(url: vttURL)
        request.timeoutInterval = 8.0
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let vttString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return WebVTTStoryboardProvider.parse(vttContent: vttString, baseURL: vttURL)
    }
}

/// Generates WebVTT cue playlists and combined sprite sheet images from locally harvested frames.
enum TrickplayStoryboardBuilder {
    struct StoryboardBundle: Sendable {
        let vttContent: String
        let spriteJPEGData: Data
        let frameCount: Int
    }

    /// Builds a sprite sheet and WebVTT cue manifest from cached frames if coverage threshold is reached.
    static func buildStoryboard(
        frames: [(seconds: Double, fileURL: URL)],
        duration: Double,
        columns: Int = 10,
        thumbWidth: CGFloat = 160,
        thumbHeight: CGFloat = 90
    ) -> StoryboardBundle? {
        guard frames.count >= 15 else { return nil }
        let totalCount = frames.count
        let rows = Int(ceil(Double(totalCount) / Double(columns)))
        let totalWidth = CGFloat(columns) * thumbWidth
        let totalHeight = CGFloat(rows) * thumbHeight

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: totalHeight), format: format)

        var loadedImages: [(index: Int, rect: CGRect, image: UIImage)] = []
        for (i, frame) in frames.enumerated() {
            let col = i % columns
            let row = i / columns
            let rect = CGRect(
                x: CGFloat(col) * thumbWidth,
                y: CGFloat(row) * thumbHeight,
                width: thumbWidth,
                height: thumbHeight
            )
            if let image = UIImage(contentsOfFile: frame.fileURL.path) {
                loadedImages.append((index: i, rect: rect, image: image))
            }
        }

        guard !loadedImages.isEmpty else { return nil }

        let spriteImage = renderer.image { _ in
            for item in loadedImages {
                item.image.draw(in: item.rect)
            }
        }

        guard let jpegData = spriteImage.jpegData(compressionQuality: 0.75) else {
            return nil
        }

        var vtt = "WEBVTT\n\n"
        for (i, frame) in frames.enumerated() {
            let col = i % columns
            let row = i / columns
            let x = Int(CGFloat(col) * thumbWidth)
            let y = Int(CGFloat(row) * thumbHeight)
            let w = Int(thumbWidth)
            let h = Int(thumbHeight)

            let start = frame.seconds
            let end: Double
            if i + 1 < frames.count {
                end = frames[i + 1].seconds
            } else {
                end = min(start + 10.0, max(start + 1.0, duration))
            }

            let startStr = formatVTTTimestamp(start)
            let endStr = formatVTTTimestamp(end)
            vtt += "\(startStr) --> \(endStr)\n"
            vtt += "sprite.jpg#xywh=\(x),\(y),\(w),\(h)\n\n"
        }

        return StoryboardBundle(
            vttContent: vtt,
            spriteJPEGData: jpegData,
            frameCount: loadedImages.count
        )
    }

    private static func formatVTTTimestamp(_ seconds: Double) -> String {
        let totalSeconds = max(0, seconds)
        let hours = Int(totalSeconds / 3600)
        let minutes = Int((totalSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(totalSeconds.truncatingRemainder(dividingBy: 60))
        let millis = Int((totalSeconds - floor(totalSeconds)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}

/// Manages community storyboard generation and background upload to VortX / community trickplay servers.
actor TrickplayUploader {
    static let shared = TrickplayUploader()

    private var uploadedKeys: Set<String> = []
    private var inFlightKeys: Set<String> = []

    func uploadIfEligible(
        canonicalKey: String,
        duration: Double
    ) async {
        guard !canonicalKey.isEmpty, duration > 30 else { return }
        guard !uploadedKeys.contains(canonicalKey) else { return }
        guard !inFlightKeys.contains(canonicalKey) else { return }

        let server = await MainActor.run {
            ProfileSettings.current.string(forKey: SettingsKey.trickplayServer)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !server.isEmpty, let baseURL = URL(string: server) else { return }

        let frames = await TrickplayDiskCache.shared.listStoredFrames(streamKey: canonicalKey)
        guard frames.count >= 15 else { return }

        guard let bundle = TrickplayStoryboardBuilder.buildStoryboard(
            frames: frames,
            duration: duration
        ) else { return }

        inFlightKeys.insert(canonicalKey)
        defer { inFlightKeys.remove(canonicalKey) }

        let uploadURL = baseURL
            .appendingPathComponent("tp", isDirectory: true)
            .appendingPathComponent(canonicalKey, isDirectory: false)

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        if let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"vtt\"; filename=\"index.vtt\"\r\nContent-Type: text/vtt\r\n\r\n".data(using: .utf8),
           let footer = "\r\n".data(using: .utf8),
           let vttData = bundle.vttContent.data(using: .utf8) {
            body.append(header)
            body.append(vttData)
            body.append(footer)
        }

        if let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"sprite\"; filename=\"sprite.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8),
           let footer = "\r\n--\(boundary)--\r\n".data(using: .utf8) {
            body.append(header)
            body.append(bundle.spriteJPEGData)
            body.append(footer)
        }

        request.httpBody = body
        request.timeoutInterval = 30.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                uploadedKeys.insert(canonicalKey)
            }
        } catch {
            // Upload failure is non-fatal; will retry on subsequent sessions
        }
    }
}

/// Session-scoped, bounded hybrid cache. Fine entries use half-second buckets;
/// coarse entries are nearest-neighbor fallbacks within the same precision bound.
actor HybridSeekThumbnailIndex {
    enum Kind: Sendable { case fine, coarse }

    private struct Entry {
        let image: CGImage
        let seconds: Double
        let kind: Kind
        let cost: Int
        var lastAccess: UInt64
    }

    private let byteLimit = 32 * 1024 * 1024
    private let entryLimit = 256
    private var fine: [Int: Entry] = [:]
    private var coarse: [Int: Entry] = [:]
    private var totalCost = 0
    private var accessCounter: UInt64 = 0
    private var generation: UInt64 = 0
    private var streamKey: String = ""
    private var externalTrickplayProvider: (any TrickplayProviding)?

    func setExternalTrickplayProvider(_ provider: (any TrickplayProviding)?) {
        self.externalTrickplayProvider = provider
    }

    func reset(generation: UInt64, streamKey: String = "") {
        guard generation >= self.generation else { return }
        fine.removeAll(keepingCapacity: true)
        coarse.removeAll(keepingCapacity: true)
        totalCost = 0
        accessCounter = 0
        self.generation = generation
        self.streamKey = streamKey
        self.externalTrickplayProvider = nil
    }

    func lookup(seconds: Double, duration: Double, generation: UInt64) async -> CGImage? {
        guard self.generation == generation, duration.isFinite, duration > 0 else { return nil }

        // Tier 1: External Storyboard / BIF (0ms instant crop)
        if let external = externalTrickplayProvider {
            if let image = await external.thumbnail(at: seconds) {
                return image
            }
        }

        // Tier 2: In-memory fine bucket
        if let bucket = HybridSeekThumbnailPolicy.fineBucket(for: seconds),
           var entry = fine[bucket] {
            guard abs(entry.seconds - seconds)
                    <= HybridSeekThumbnailPolicy.maximumPreviewTimeError else { return nil }
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            fine[bucket] = entry
            return entry.image
        }

        // Tier 3: In-memory nearest RAM thumbnail (coarse bucket fallback)
        if let nearest = coarse.min(by: {
            abs($0.value.seconds - seconds) < abs($1.value.seconds - seconds)
        }), HybridSeekThumbnailPolicy.acceptsCoarse(
            sampleSeconds: nearest.value.seconds,
            targetSeconds: seconds,
            duration: duration
        ) {
            accessCounter &+= 1
            var entry = nearest.value
            entry.lastAccess = accessCounter
            coarse[nearest.key] = entry
            return entry.image
        }

        // Tier 4: Persistent Disk Cache (~0.5ms memory-mapped read)
        if !streamKey.isEmpty {
            let tolerance = HybridSeekThumbnailPolicy.coarseLookupTolerance(duration: duration)
            if let diskHit = await TrickplayDiskCache.shared.lookupWithTimestamp(streamKey: streamKey, seconds: seconds, tolerance: tolerance) {
                // Promote to in-memory cache using actual disk frame timestamp
                let kind: Kind = abs(diskHit.seconds - seconds) <= HybridSeekThumbnailPolicy.maximumPreviewTimeError ? .fine : .coarse
                self.store(diskHit.image, seconds: diskHit.seconds, kind: kind, generation: generation, persistToDisk: false)
                return diskHit.image
            }
        }

        return nil
    }

    func hasCoarse(at seconds: Double, generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        return coarse.values.contains { abs($0.seconds - seconds) < 0.01 }
    }

    func store(
        _ image: CGImage,
        seconds: Double,
        kind: Kind,
        generation: UInt64,
        persistToDisk: Bool = true
    ) {
        guard self.generation == generation, seconds.isFinite else { return }
        let cost = max(1, image.width * image.height * 4)
        guard cost <= byteLimit else { return }
        accessCounter &+= 1
        let entry = Entry(image: image, seconds: seconds, kind: kind, cost: cost, lastAccess: accessCounter)
        switch kind {
        case .fine:
            guard let bucket = HybridSeekThumbnailPolicy.fineBucket(for: seconds) else { return }
            if let old = fine.updateValue(entry, forKey: bucket) { totalCost -= old.cost }
        case .coarse:
            let key = Int((seconds * 1000).rounded())
            if let old = coarse.updateValue(entry, forKey: key) { totalCost -= old.cost }
        }
        totalCost += cost
        evictIfNeeded()

        if persistToDisk, !streamKey.isEmpty {
            let key = streamKey
            Task {
                await TrickplayDiskCache.shared.store(image: image, streamKey: key, seconds: seconds)
            }
        }
    }

    private func evictIfNeeded() {
        while totalCost > byteLimit || fine.count + coarse.count > entryLimit {
            let fineCandidate = fine.min { $0.value.lastAccess < $1.value.lastAccess }
            let coarseCandidate = coarse.min { $0.value.lastAccess < $1.value.lastAccess }
            guard let fineCandidate, let coarseCandidate else {
                if let fineCandidate {
                    totalCost -= fine.removeValue(forKey: fineCandidate.key)?.cost ?? 0
                } else if let coarseCandidate {
                    totalCost -= coarse.removeValue(forKey: coarseCandidate.key)?.cost ?? 0
                }
                continue
            }
            if fineCandidate.value.lastAccess <= coarseCandidate.value.lastAccess {
                totalCost -= fine.removeValue(forKey: fineCandidate.key)?.cost ?? 0
            } else {
                totalCost -= coarse.removeValue(forKey: coarseCandidate.key)?.cost ?? 0
            }
        }
    }
}

/// Long-lived wrapper around a single `AetherEngine` instance (reused across titles).
private final class StartupProgressGenerationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var latestGeneration: UInt64?

    var generation: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return latestGeneration
    }

    func record(_ progress: StartupProgress?) {
        guard let generation = progress?.generation else { return }
        lock.lock()
        latestGeneration = max(latestGeneration ?? generation, generation)
        lock.unlock()
    }
}

enum AetherStartupLoadPresentationPolicy {
    static func isPresented(
        expectedLoadGeneration: UInt64,
        ownerLoadGeneration: UInt64?,
        engineGenerationFloor: UInt64?,
        progressGeneration: UInt64?,
        checkpointIsPresenting: Bool
    ) -> Bool {
        guard ownerLoadGeneration == expectedLoadGeneration,
              let engineGenerationFloor,
              let progressGeneration,
              progressGeneration >= engineGenerationFloor,
              checkpointIsPresenting else { return false }
        return true
    }
}

struct AetherStartupLoadCheckpointWitness {
    let ownerLoadGeneration: UInt64?
    let engineGenerationFloor: UInt64?
    let progressGeneration: UInt64?
    let checkpoint: StartupCheckpoint?
}

enum AetherDiscStartupWatchdogGracePolicy {
    /// The URL or filename hint scopes the exception; sourceOpened does not
    /// claim that the engine has positively identified a disc container.
    static func shouldGrantGrace(
        request: PlaybackLoadRequest?,
        backend: PlayerBackendKind,
        loadGeneration: UInt64,
        dispatchedLoadGeneration: UInt64?,
        progress: AetherStartupLoadCheckpointWitness?,
        graceAlreadyGranted: Bool
    ) -> Bool {
        guard !graceAlreadyGranted,
              backend == .aether,
              dispatchedLoadGeneration == loadGeneration,
              let request,
              !request.isLiveStream,
              !request.isSports,
              PlaybackBackendPolicy.isRemoteHTTP(request.videoURL.absoluteString),
              PlaybackBackendPolicy.isDiscImage(request.videoURL.absoluteString, filename: request.filename),
              let progress,
              progress.ownerLoadGeneration == loadGeneration,
              let generationFloor = progress.engineGenerationFloor,
              let progressGeneration = progress.progressGeneration,
              progressGeneration >= generationFloor,
              let checkpoint = progress.checkpoint,
              checkpoint >= .sourceOpened else {
            return false
        }
        return true
    }
}

@MainActor
final class AetherPlaybackController: UIViewController, PlaybackEngineControlling, ScrubThumbnailProviding {
    private struct StartupBenchmarkLoadOwner {
        let loadGeneration: UInt64
        let engineGenerationFloor: UInt64
        let token: UUID?
        var engineGeneration: UInt64?
    }

    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
    var onWillSuspendPlayback: (() -> Void)?
    var onDidRestorePlayback: (() -> Void)?
    /// Terminal load/runtime failures the coordinator may use for MPV fallback.
    var onTerminalError: ((String) -> Void)?

    let engine: AetherEngine
    let playerView = AetherPlayerView()
    let subtitleOverlayState = AetherSubtitleOverlayState()
    let subtitleTranslationState = AISubtitleTranslationState()
    private lazy var assCoordinator = ASSRenderCoordinator(player: engine)
    private var activeASSTrackID: Int?
    private var activeASSHeader: String?

    private var cancellables = Set<AnyCancellable>()
    private var loadGeneration: UInt64 = 0
    private var lastKnownPositionMs: Int64 = 0
    private var lastKnownDurationMs: Int64 = 0
    private var lastKnownSourceTimeSeconds: Double = 0
    private var externalSubtitleURLsByTrackID: [Int: String] = [:]
    private var currentHTTPHeaders: [String: String] = [:]
    private var currentHTTPHeaderSourceURL: URL?
    private var didReportTerminalError = false
    private var sourceProbe: SourceProbe?
    private var subtitleDelaySeconds: Double = 0
    private var lastPassiveCaptureTime: Double = -100
    private var isPerformingPassiveCapture = false
    private(set) var contentCanonicalKey: String?
    private var currentStreamKey: String = ""
    private var aiSubtitleStartupHoldCueID: Int?
    private var aiSubtitleStartupHoldTimeoutTask: Task<Void, Never>?
    private var didAttemptAISubtitleStartupHold = false
    private let aiSubtitleStartupHoldTimeout: TimeInterval = 6
    private var needsForegroundReload = false
    private var playbackWasPlayingBeforeBackground = false
    private var foregroundReloadTask: Task<Void, Never>?
    private var foregroundReloadActiveCancellationRetryCount = 0
    private var artworkLoadTask: Task<Void, Never>?
    private var nowPlayingInfo: [String: Any] = [:]
    private var lifecycleReloadToken: UInt64 = 0
    /// Software playback has no SegmentCache-backed still source. Keep one
    /// session-scoped extractor for that route instead of creating a decoder
    /// for every scrub target.
    private var softwareFrameExtractor: FrameExtractor?
    private var didPrewarmSoftwareFrameExtractor = false
    private var didLogSoftwareThumbnailResult = false
    private var softwareFrameExtractorCleanupTask: Task<Void, Never>?
    private var softwareFrameExtractorCleanupGeneration: UInt64 = 0
    private let hybridThumbnailIndex = HybridSeekThumbnailIndex()
    private var thumbnailSourceContext: PlaybackThumbnailSourceContext?
    private var thumbnailIndexResetTask: Task<Void, Never>?
    private var externalTrickplayProvider: (any TrickplayProviding)?
    private var thumbnailRequestSequence: UInt64 = 0
    private var activeThumbnailCancellation: PlaybackThumbnailRequestCancellation?
    private var activeThumbnailTask: Task<CGImage?, Never>?
    private var activeThumbnailTaskRequestID: UInt64?
    private var externalProviderGeneration: UInt64 = 0
    private var engineAuxiliaryCleanupTask: Task<Void, Never>?
    private var engineAuxiliaryCleanupRequestID: UInt64 = 0
    var coarseThumbnailTask: Task<Void, Never>?
    private var coarseThumbnailTaskToken: UInt64 = 0
    private var coarseSampleTimes: [Double] = []
    private var coarseSampleCursor = 0
    private var coarseResumeNotBefore = Date.distantPast
    private var coarseThumbnailUnavailable = false
    private var coarseThumbnailComplete = false
    private var isRemoteStream = false
    private var isLocalPlaybackCache = false

    // MARK: PlaybackEngineControlling surface

    private var isAwaitingEngineLoad = false
    private var engineLoadInitialPhase: PlaybackPhase? = nil
    private var lastAppliedPlaybackPhase: PlaybackPhase?
    private var lastDiagnosticSnapshotUptime: TimeInterval = 0
    private var diagnosticPlayIntent = "unknown"

    var onFirstFrameReady: (() -> Void)?
    var hasFirstFrameReadyForDisplay: Bool {
        guard !isAwaitingEngineLoad else { return false }
        return engine.hasFirstFrameReadyForDisplay
    }
    private(set) var audioTracks: [PlaybackTrackInfo] = []
    private(set) var subtitleTracks: [PlaybackTrackInfo] = []
    var discTitles: [PlaybackDiscTitleInfo] {
        engine.discTitles.map {
            PlaybackDiscTitleInfo(
                id: $0.id,
                name: $0.name,
                durationSeconds: $0.durationSeconds,
                chapterCount: $0.chapterCount
            )
        }
    }
    var selectedDiscTitleId: Int? {
        engine.selectedDiscTitle?.id
    }
    private(set) var isPlayerLoading = true
    private(set) var isPlayerPlaying = false
    var isTransportPlaying: Bool {
        guard !isAwaitingEngineLoad else { return false }
        return engine.isTransportPlaying
    }
    private(set) var isPlayerEnded = false
    private(set) var isAtEndOfFile = false
    private(set) var hasCoherentTimeSample = false
    private(set) var durationMs: Int64 = 0
    private(set) var positionMs: Int64 = 0
    private(set) var bufferedMs: Int64 = 0
    private(set) var currentSpeed: Float = 1
    private(set) var currentErrorMessage = ""
    private(set) var videoFrameSize: CGSize = .zero
    private(set) var currentAspectMode: PlayerAspectMode = .fit
    /// Subtitle evaluation clock (Aether `sourceTime`).
    private(set) var sourceTimeSeconds: Double = 0
    private(set) var subtitleCues: [SubtitleCue] = []
    
    func currentSubtitleText(at time: Double) -> String? {
        let active = subtitleCues.filter { cue in
            time >= cue.startTime && time <= cue.endTime
        }
        let texts = active.compactMap(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n")
    }
    private(set) var capabilities = PlaybackEngineCapabilities.aether
    var isPictureInPictureActive: Bool { engine.pictureInPictureActive }

    @Published private(set) var startupProgress: StartupProgress?
    var onStartupProgressChanged: ((StartupProgress?) -> Void)?
    private let startupProgressGenerationObserver = StartupProgressGenerationObserver()
    private var startupBenchmarkLoadOwner: StartupBenchmarkLoadOwner?

    func hasPresentedCurrentLoad(generation: UInt64) -> Bool {
        let progress = engine.startupProgress
        let owner = startupBenchmarkLoadOwner
        return AetherStartupLoadPresentationPolicy.isPresented(
            expectedLoadGeneration: generation,
            ownerLoadGeneration: owner?.loadGeneration,
            engineGenerationFloor: owner?.engineGenerationFloor,
            progressGeneration: progress?.generation,
            checkpointIsPresenting: progress?.checkpoint == .presenting
        )
    }

    var startupLoadCheckpointWitness: AetherStartupLoadCheckpointWitness {
        let progress = engine.startupProgress
        let owner = startupBenchmarkLoadOwner
        return AetherStartupLoadCheckpointWitness(
            ownerLoadGeneration: owner?.loadGeneration,
            engineGenerationFloor: owner?.engineGenerationFloor,
            progressGeneration: progress?.generation,
            checkpoint: progress?.checkpoint
        )
    }

    var loadingStepMessage: String? {
        guard let stage = engine.startupProgress?.stage else {
            return isPlayerLoading ? L10n.string("player_loading_buffering", fallback: "Buffering…") : nil
        }
        switch stage {
        case .connecting:
            return L10n.string("player_loading_preparing", fallback: "Connecting to stream…")
        case .openingContainer:
            return L10n.string("player_loading_detecting_format", fallback: "Detecting stream format…")
        case .analyzingStreams:
            return L10n.string("player_loading_detecting_format", fallback: "Analyzing streams…")
        case .preparingDisplay:
            return L10n.string("player_loading_preparing", fallback: "Matching display settings…")
        case .selectingRoute:
            return L10n.string("player_loading_building", fallback: "Selecting playback decoder…")
        case .buildingSession:
            return L10n.string("player_loading_building", fallback: "Building player engine…")
        case .preparingPlayback:
            return L10n.string("player_loading_buffering", fallback: "Buffering stream…")
        case .awaitingFirstFrame, .presenting:
            return L10n.string("player_loading_starting", fallback: "Starting stream…")
        }
    }

    /// True when the active Aether session can provide a scrub still. Native
    /// cache-backed stills stay the first choice; software video and local/hybrid-cached
    /// sessions use one retained independent FrameExtractor.
    var supportsScrubThumbnails: Bool {
        engine.supportsCacheBackedStills
            || isLocalPlaybackCache
            || (!isRemoteStream && engine.playbackBackend == .software)
    }

    static func shouldUseBoundedProgressiveScrubPreview(
        requestIsLive: Bool,
        engineIsLive: Bool,
        route: VideoRoute,
        isKnownHLS: Bool,
        sourceURL: URL?,
        sourceContainerFormat: String?
    ) -> Bool {
        guard !requestIsLive, !engineIsLive, route != .remoteBypass, !isKnownHLS,
              let sourceURL,
              let scheme = sourceURL.scheme?.lowercased(),
              ["file", "http", "https"].contains(scheme) else { return false }
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard !["iso", "img", "udf"].contains(fileExtension) else { return false }
        guard !PlaybackThumbnailSourceFallback.isKnownHLSURL(sourceURL) else { return false }

        let knownVideoExtensions: Set<String> = [
            "3gp", "avi", "flv", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "m2ts", "mts", "ts", "webm"
        ]
        if knownVideoExtensions.contains(fileExtension) { return true }

        // Suffixless direct-download URLs are common. Use the already-loaded demuxer identity to
        // admit known progressive containers while leaving unknown manifest-like sources legacy.
        let knownContainers: Set<String> = [
            "asf", "avi", "flv", "matroska", "mov", "mpeg", "mpegts", "mp4", "ogg", "webm"
        ]
        let containers = (sourceContainerFormat ?? "").lowercased().split(separator: ",")
        return containers.contains { knownContainers.contains(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    static func acceptsBoundedScrubFrame(_ frame: ScrubFrame?, at seconds: Double) -> Bool {
        guard let frame, seconds.isFinite, frame.actualSeconds.isFinite,
              abs(frame.actualSeconds - seconds) <= HybridSeekThumbnailPolicy.maximumPreviewTimeError else { return false }
        return frame.validRange?.contains(seconds) ?? true
    }

    @MainActor
    static func boundedProgressiveScrubFrame(
        at seconds: Double,
        resident: @MainActor () async -> ScrubFrame?,
        ownsSource: @MainActor () -> Bool,
        cleanup: @MainActor () async -> Void,
        isCurrent: @MainActor () -> Bool,
        fallback: @MainActor () async -> BoundedStillFrame?
    ) async -> BoundedStillFrame? {
        let frame = await resident()
        // A source replacement owns the engine's new auxiliary contexts; the old request must not close them.
        guard ownsSource() else { return nil }
        await cleanup()
        // Superseded requests on the same source still drain their decoder, then stop before publication/fallback.
        guard isCurrent() else { return nil }
        if acceptsBoundedScrubFrame(frame, at: seconds), let frame {
            return BoundedStillFrame(image: frame.image, actualSeconds: frame.actualSeconds)
        }
        return await fallback()
    }

    private func usesBoundedProgressiveScrubPreview(_ context: PlaybackThumbnailSourceContext?) -> Bool {
        guard let context, context.generation == loadGeneration, !isAwaitingEngineLoad else { return false }
        // Usenet: previews only from what playback already buffered.
        guard !UsenetStreamServer.isStreamURL(context.playbackURL) else { return false }
        return Self.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: context.isLive,
            engineIsLive: engine.isLive,
            route: engine.videoRoute,
            isKnownHLS: context.isKnownHLS,
            sourceURL: context.headerSourceURL ?? context.playbackURL,
            sourceContainerFormat: engine.sourceContainerFormat
        )
    }

    private func getOrCreateFrameExtractor() -> FrameExtractor? {
        if let softwareFrameExtractor {
            return softwareFrameExtractor
        }
        guard let created = engine.makeFrameExtractor() else {
            print("[Aether] Scrub thumbnail fallback extractor unavailable")
            return nil
        }
        softwareFrameExtractor = created
        didLogSoftwareThumbnailResult = false
        print("[Aether] Created scrub thumbnail fallback extractor")
        return created
    }

    /// Lazily opens the retained extractor so the first visible scrub
    /// request does not pay the demuxer-open cost.
    func prepareScrubThumbnailExtractor() {
        guard !isAwaitingEngineLoad else { return }
        if usesBoundedProgressiveScrubPreview(thumbnailSourceContext) { return }
        guard isLocalPlaybackCache || (!isRemoteStream && engine.playbackBackend == .software) else { return }
        guard engine.playbackPhase == .paused, !isTransportPlaying else { return }
        guard !didPrewarmSoftwareFrameExtractor else { return }
        guard let extractor = getOrCreateFrameExtractor() else { return }
        didPrewarmSoftwareFrameExtractor = true
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            await extractor.prewarm()
            guard let self, self.loadGeneration == generation else { return }
        }
    }

    func cachedScrubThumbnail(atSeconds seconds: Double, duration: Double) async -> CGImage? {
        let generation = loadGeneration
        let requestID = beginScrubThumbnailRequest()
        let providerGeneration = externalProviderGeneration
        guard !isAwaitingEngineLoad else { return nil }
        if let externalTrickplayProvider {
            let image = await externalTrickplayProvider.thumbnail(at: seconds)
            guard isCurrentScrubThumbnailRequest(
                requestID, generation: generation, providerGeneration: providerGeneration) else { return nil }
            if let image { return image }
        }
        let image = await hybridThumbnailIndex.lookup(
            seconds: seconds,
            duration: duration,
            generation: generation
        )
        guard isCurrentScrubThumbnailRequest(
            requestID, generation: generation, providerGeneration: providerGeneration) else { return nil }
        return image
    }

    func scrubThumbnail(
        atSeconds seconds: Double,
        maxWidth: Int = 360,
        precise: Bool = true
    ) async -> CGImage? {
        let generation = loadGeneration
        let sourceContext = thumbnailSourceContext
        let previousTask = activeThumbnailTask
        let cleanupTask = softwareFrameExtractorCleanupTask
        let cleanupGeneration = softwareFrameExtractorCleanupGeneration
        let engineCleanupTask = engineAuxiliaryCleanupTask
        let engineCleanupRequestID = engineAuxiliaryCleanupRequestID
        let requestID = beginScrubThumbnailRequest()
        let providerGeneration = externalProviderGeneration
        let cancellation = PlaybackThumbnailRequestCancellation()
        activeThumbnailCancellation = cancellation
        let work: Task<CGImage?, Never> = Task {
            @MainActor [weak self, previousTask, cleanupTask, engineCleanupTask] in
            _ = await previousTask?.value
            _ = await cleanupTask?.value
            _ = await engineCleanupTask?.value
            guard let self,
                  self.isCurrentScrubThumbnailRequest(
                    requestID, generation: generation, providerGeneration: providerGeneration,
                    cancellation: cancellation) else { return nil }
            if self.softwareFrameExtractorCleanupGeneration == cleanupGeneration {
                self.softwareFrameExtractorCleanupTask = nil
            }
            if self.engineAuxiliaryCleanupRequestID == engineCleanupRequestID {
                self.engineAuxiliaryCleanupTask = nil
            }
            return await withTaskCancellationHandler {
                await self.generateScrubThumbnail(
                    atSeconds: seconds,
                    maxWidth: maxWidth,
                    precise: precise,
                    generation: generation,
                    requestID: requestID,
                    providerGeneration: providerGeneration,
                    sourceContext: sourceContext,
                    cancellation: cancellation
                )
            } onCancel: {
                cancellation.cancel()
            }
        }
        activeThumbnailTask = work
        activeThumbnailTaskRequestID = requestID
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            cancellation.cancel()
            work.cancel()
        }
        if activeThumbnailTaskRequestID == requestID {
            activeThumbnailTask = nil
            activeThumbnailTaskRequestID = nil
        }
        if thumbnailRequestSequence == requestID,
           activeThumbnailCancellation === cancellation {
            activeThumbnailCancellation = nil
        }
        return result
    }

    /// Scene adapter preserves primary capture results and permits only the DV5 resident failure
    /// allowlist to use the bounded, mandatory-RPU original-source path.
    func captureSceneFrameForAnalysis(maxWidth: Int = 960) async -> AetherEngine.VideoFrameAnalysisCapture {
        let generation = loadGeneration
        let engineSnapshot = engine
        let captureIdentity = sceneFrameAnalysisIdentity(for: engineSnapshot, hostGeneration: generation)
        let sourceContext = thumbnailSourceContext
        let previousTask = activeThumbnailTask
        let softwareCleanupTask = softwareFrameExtractorCleanupTask
        let softwareCleanupGeneration = softwareFrameExtractorCleanupGeneration
        let engineCleanupTask = engineAuxiliaryCleanupTask
        let engineCleanupRequestID = engineAuxiliaryCleanupRequestID
        let requestID = beginScrubThumbnailRequest()
        let providerGeneration = externalProviderGeneration
        let cancellation = PlaybackThumbnailRequestCancellation()
        activeThumbnailCancellation = cancellation
        let captureBox = SceneFrameAnalysisResultBox()
        let width = min(960, max(1, maxWidth))

        let work: Task<CGImage?, Never> = Task { @MainActor
            [weak self, previousTask, softwareCleanupTask, engineCleanupTask] in
            _ = await previousTask?.value
            _ = await softwareCleanupTask?.value
            _ = await engineCleanupTask?.value
            guard let self,
                  self.isCurrentSceneFrameRequest(
                    requestID, generation: generation, providerGeneration: providerGeneration,
                    sourceContext: sourceContext, engine: engineSnapshot,
                    captureIdentity: captureIdentity, cancellation: cancellation) else {
                return nil
            }
            if self.softwareFrameExtractorCleanupGeneration == softwareCleanupGeneration {
                self.softwareFrameExtractorCleanupTask = nil
            }
            if self.engineAuxiliaryCleanupRequestID == engineCleanupRequestID {
                self.engineAuxiliaryCleanupTask = nil
            }
            let capture = await self.generateSceneFrameAnalysisCapture(
                engine: engineSnapshot,
                sourceContext: sourceContext,
                maxWidth: width,
                requestID: requestID,
                generation: generation,
                providerGeneration: providerGeneration,
                captureIdentity: captureIdentity,
                cancellation: cancellation
            )
            captureBox.capture = capture
            return capture.image
        }
        activeThumbnailTask = work
        activeThumbnailTaskRequestID = requestID
        _ = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            cancellation.cancel()
            work.cancel()
        }
        if activeThumbnailTaskRequestID == requestID {
            activeThumbnailTask = nil
            activeThumbnailTaskRequestID = nil
        }
        if thumbnailRequestSequence == requestID,
           activeThumbnailCancellation === cancellation {
            activeThumbnailCancellation = nil
        }
        return captureBox.capture ?? AetherEngine.VideoFrameAnalysisCapture(
            image: nil, sourceTime: engineSnapshot.clock.currentTime,
            diagnostics: "route=scene-adapter reason=cancelled-or-superseded")
    }

    private func generateSceneFrameAnalysisCapture(
        engine engineSnapshot: AetherEngine,
        sourceContext: PlaybackThumbnailSourceContext?,
        maxWidth: Int,
        requestID: UInt64,
        generation: UInt64,
        providerGeneration: UInt64,
        captureIdentity: AetherSceneFrameAnalysisIdentity,
        cancellation: PlaybackThumbnailRequestCancellation
    ) async -> AetherEngine.VideoFrameAnalysisCapture {
        let primary = await engineSnapshot.captureVideoFrameForAnalysis(maxWidth: maxWidth)
        guard isCurrentSceneFrameRequest(
            requestID, generation: generation, providerGeneration: providerGeneration,
            sourceContext: sourceContext, engine: engineSnapshot,
            captureIdentity: captureIdentity, cancellation: cancellation) else {
            return AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: primary.sourceTime,
                diagnostics: "route=scene-adapter reason=cancelled-or-superseded primary={\(primary.diagnostics)}")
        }
        let sourceProfile = engineSnapshot.sourceDVProfile
        let sourceEligible = sourceContext != nil && usesBoundedProgressiveScrubPreview(sourceContext)
        let yieldLatch = SceneAnalysisYieldLatch(signal: engineSnapshot.frameAnalysisYieldSignal())
        // This is sampled only after the primary capture attempt. Scene time is elapsed Aether time.
        let targetSeconds = engineSnapshot.clock.currentTime
        let limits = ProbeLimits(
            maxInputBytes: 64 * 1024 * 1024,
            maxPackets: 4_096,
            maxPacketBytes: 16 * 1024 * 1024,
            timeBudget: 3)
        return await Self.resolveSceneCaptureAfterPrimary(
            primary,
            sourceDVProfile: sourceProfile,
            sourceEligible: sourceEligible,
            targetSeconds: targetSeconds,
            shouldYield: { yieldLatch.check() },
            didYield: { yieldLatch.didYield },
            isCurrent: {
                self.isCurrentSceneFrameRequest(
                    requestID, generation: generation, providerGeneration: providerGeneration,
                    sourceContext: sourceContext, engine: engineSnapshot,
                    captureIdentity: captureIdentity, cancellation: cancellation)
            },
            fallback: {
                guard let sourceContext else { return nil }
                return await PlaybackThumbnailSourceFallback.boundedSnapshot(
                    sourceContext: sourceContext,
                    atSeconds: targetSeconds,
                    maxWidth: maxWidth,
                    cancellation: cancellation,
                    isCurrent: {
                        self.isCurrentSceneFrameRequest(
                            requestID, generation: generation, providerGeneration: providerGeneration,
                            sourceContext: sourceContext, engine: engineSnapshot,
                            captureIdentity: captureIdentity, cancellation: cancellation)
                    },
                    requiredDolbyVisionReshaping: true,
                    limits: limits,
                    yieldWhile: { yieldLatch.check() })
            })
    }

    @MainActor
    static func resolveSceneCaptureAfterPrimary(
        _ primary: AetherEngine.VideoFrameAnalysisCapture,
        sourceDVProfile: Int?,
        sourceEligible: Bool,
        targetSeconds: Double,
        shouldYield: (@Sendable () -> Bool)? = nil,
        didYield: (@Sendable () -> Bool)? = nil,
        isCurrent: @MainActor () -> Bool,
        fallback: @MainActor () async -> BoundedStillFrame?
    ) async -> AetherEngine.VideoFrameAnalysisCapture {
        guard isCurrent() else {
            return AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: targetSeconds,
                diagnostics: "route=scene-adapter reason=cancelled-or-superseded primary={\(primary.diagnostics)}")
        }
        guard primary.image == nil,
              (sourceDVProfile == 5 || sourceDVProfile == nil),
              sourceEligible,
              Self.isRecoverableDV5ResidentCaptureFailure(primary.diagnostics) else { return primary }
        guard targetSeconds.isFinite, targetSeconds >= 0 else {
            return AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: primary.sourceTime,
                diagnostics: "route=bounded-dovi-source reason=invalid-target primary={\(primary.diagnostics)}")
        }
        guard shouldYield?() != true, didYield?() != true else {
            return AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: targetSeconds,
                diagnostics: "route=bounded-dovi-source reason=playback-priority-yield primary={\(primary.diagnostics)}")
        }
        let still = await fallback()
        guard isCurrent() else {
            return AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: targetSeconds,
                diagnostics: "route=bounded-dovi-source reason=cancelled-or-superseded primary={\(primary.diagnostics)}")
        }
        guard shouldYield?() != true, didYield?() != true else {
            return AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: targetSeconds,
                diagnostics: "route=bounded-dovi-source reason=playback-priority-yield primary={\(primary.diagnostics)}")
        }
        guard let still, let actualSeconds = still.actualSeconds, actualSeconds.isFinite,
              abs(actualSeconds - targetSeconds) <= HybridSeekThumbnailPolicy.maximumPreviewTimeError else {
            return AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: targetSeconds,
                diagnostics: "route=bounded-dovi-source reason=bounded-source-unavailable primary={\(primary.diagnostics)} targetTime=\(String(format: "%.3f", targetSeconds))")
        }
        return AetherEngine.VideoFrameAnalysisCapture(
            image: still.image,
            sourceTime: actualSeconds,
            diagnostics: "route=bounded-dovi-source reason=ok actualTime=\(String(format: "%.3f", actualSeconds)) primary={\(primary.diagnostics)}"
        )
    }

    private func isCurrentSceneFrameRequest(
        _ requestID: UInt64,
        generation: UInt64,
        providerGeneration: UInt64,
        sourceContext: PlaybackThumbnailSourceContext?,
        engine engineSnapshot: AetherEngine,
        captureIdentity: AetherSceneFrameAnalysisIdentity,
        cancellation: PlaybackThumbnailRequestCancellation
    ) -> Bool {
        guard isCurrentScrubThumbnailRequest(
            requestID, generation: generation, providerGeneration: providerGeneration,
            cancellation: cancellation),
              thumbnailSourceContext == sourceContext,
              engine === engineSnapshot,
              sceneFrameAnalysisIdentity(for: engineSnapshot, hostGeneration: generation) == captureIdentity
        else { return false }
        return true
    }

    private func sceneFrameAnalysisIdentity(
        for engine: AetherEngine,
        hostGeneration: UInt64
    ) -> AetherSceneFrameAnalysisIdentity {
        let player = engine.nativePlayerLayer?.player ?? engine.currentAVPlayer
        return AetherSceneFrameAnalysisIdentity(
            hostGeneration: hostGeneration,
            engineStartupGeneration: engine.startupProgress?.generation,
            nativePlayer: player,
            nativeItem: player?.currentItem
        )
    }

    static func sceneFrameAnalysisIdentityMatches(
        _ captured: AetherSceneFrameAnalysisIdentity,
        current: AetherSceneFrameAnalysisIdentity
    ) -> Bool {
        captured == current
    }

    private static func isRecoverableDV5ResidentCaptureFailure(_ diagnostics: String) -> Bool {
        var route: String?
        var reason: String?
        for field in diagnostics.split(whereSeparator: \.isWhitespace) {
            if field.hasPrefix("route=") { route = String(field.dropFirst("route=".count)) }
            if field.hasPrefix("reason=") { reason = String(field.dropFirst("reason=".count)) }
        }
        guard route == "resident-dovi-rpu" else { return false }
        return [
            "resident-dv-decode-failed-or-budget-expired",
            "resident-decode-budget-expired",
            "resident-segment-cache-miss",
            "resident-segment-read-failed",
        ].contains(reason ?? "")
    }

    private func generateScrubThumbnail(
        atSeconds seconds: Double,
        maxWidth: Int,
        precise: Bool,
        generation: UInt64,
        requestID: UInt64,
        providerGeneration: UInt64,
        sourceContext: PlaybackThumbnailSourceContext?,
        cancellation: PlaybackThumbnailRequestCancellation
    ) async -> CGImage? {
        guard !isAwaitingEngineLoad,
              isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                            providerGeneration: providerGeneration,
                                            cancellation: cancellation) else { return nil }
        if let external = externalTrickplayProvider {
            let externalImage = await external.thumbnail(at: seconds)
            guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                                 providerGeneration: providerGeneration,
                                                 cancellation: cancellation) else { return nil }
            if let externalImage { return externalImage }
        }
        let cached = await hybridThumbnailIndex.lookup(
            seconds: seconds,
            duration: durationMs > 0 ? Double(durationMs) / 1000.0 : 3600.0,
            generation: generation
        )
        guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation) else { return nil }
        if let cached { return cached }
        if usesBoundedProgressiveScrubPreview(sourceContext) {
            let still = await Self.boundedProgressiveScrubFrame(
                at: seconds,
                resident: {
                    await engine.scrubPreviewFrame(
                        atSeconds: seconds,
                        refined: true,
                        maxWidth: maxWidth,
                        isCancelled: { cancellation.isCancelled })
                },
                ownsSource: {
                    loadGeneration == generation
                        && thumbnailSourceContext == sourceContext
                        && !isAwaitingEngineLoad
                },
                cleanup: {
                    await engine.closeAuxiliaryScrubExtractorsAndWait()
                },
                isCurrent: {
                    isCurrentScrubThumbnailRequest(
                        requestID, generation: generation, providerGeneration: providerGeneration,
                        cancellation: cancellation)
                },
                fallback: {
                    guard let sourceContext else { return nil }
                    return await PlaybackThumbnailSourceFallback.boundedSnapshot(
                        sourceContext: sourceContext,
                        atSeconds: seconds,
                        maxWidth: maxWidth,
                        cancellation: cancellation,
                        isCurrent: {
                            self.isCurrentScrubThumbnailRequest(
                                requestID, generation: generation, providerGeneration: providerGeneration,
                                cancellation: cancellation)
                        })
                })
            guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                                 providerGeneration: providerGeneration,
                                                 cancellation: cancellation),
                  let still, let actual = still.actualSeconds, actual.isFinite else { return nil }
            await hybridThumbnailIndex.store(
                still.image, seconds: actual, kind: .fine, generation: generation)
            guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                                 providerGeneration: providerGeneration,
                                                 cancellation: cancellation) else { return nil }
            return still.image
        }

        return await generateLegacyScrubThumbnail(
            atSeconds: seconds, maxWidth: maxWidth, precise: precise,
            generation: generation, requestID: requestID,
            providerGeneration: providerGeneration, cancellation: cancellation)
    }

    private func generateLegacyScrubThumbnail(
        atSeconds seconds: Double,
        maxWidth: Int,
        precise: Bool,
        generation: UInt64,
        requestID: UInt64,
        providerGeneration: UInt64,
        cancellation: PlaybackThumbnailRequestCancellation
    ) async -> CGImage? {
        if engine.supportsCacheBackedStills {
            let image = await engine.scrubThumbnail(atSeconds: seconds, maxWidth: maxWidth, precise: precise)
            guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                                 providerGeneration: providerGeneration,
                                                 cancellation: cancellation) else { return nil }
            if let image {
                await hybridThumbnailIndex.store(
                    image, seconds: seconds, kind: precise ? .fine : .coarse, generation: generation)
                guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                                     providerGeneration: providerGeneration,
                                                     cancellation: cancellation) else { return nil }
                return image
            }
            guard isLocalPlaybackCache || !isRemoteStream else { return nil }
        }

        guard isLocalPlaybackCache || (!isRemoteStream && engine.playbackBackend == .software),
              isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation),
              let extractor = getOrCreateFrameExtractor() else { return nil }
        let image: CGImage?
        if precise {
            image = await extractor.preciseThumbnail(at: seconds, maxWidth: maxWidth)
        } else {
            image = await extractor.thumbnail(at: seconds, maxWidth: maxWidth)
        }
        guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                             providerGeneration: providerGeneration,
                                             cancellation: cancellation),
              softwareFrameExtractor != nil else { return nil }
        if image == nil, !didLogSoftwareThumbnailResult {
            print("[Aether] Scrub thumbnail fallback extraction produced nil at \(seconds)s")
            didLogSoftwareThumbnailResult = true
        }
        if let image {
            await hybridThumbnailIndex.store(
                image, seconds: seconds, kind: precise ? .fine : .coarse, generation: generation)
            guard isCurrentScrubThumbnailRequest(requestID, generation: generation,
                                                 providerGeneration: providerGeneration,
                                                 cancellation: cancellation) else { return nil }
        }
        return image
    }

    private func beginScrubThumbnailRequest() -> UInt64 {
        thumbnailRequestSequence &+= 1
        activeThumbnailTask?.cancel()
        activeThumbnailCancellation?.cancel()
        activeThumbnailCancellation = nil
        return thumbnailRequestSequence
    }

    private func isCurrentScrubThumbnailRequest(
        _ requestID: UInt64,
        generation: UInt64,
        providerGeneration: UInt64,
        cancellation: PlaybackThumbnailRequestCancellation? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              !isAwaitingEngineLoad,
              thumbnailRequestSequence == requestID,
              loadGeneration == generation,
              externalProviderGeneration == providerGeneration,
              thumbnailSourceContext?.generation == generation else { return false }
        if let cancellation {
            guard !cancellation.isCancelled, activeThumbnailCancellation === cancellation else { return false }
        }
        return true
    }

    private func cancelScrubThumbnailWork() {
        thumbnailRequestSequence &+= 1
        activeThumbnailTask?.cancel()
        activeThumbnailCancellation?.cancel()
        activeThumbnailCancellation = nil
    }

    private func resetSoftwareFrameExtractor() {
        let extractor = softwareFrameExtractor
        softwareFrameExtractor = nil
        didPrewarmSoftwareFrameExtractor = false
        guard let extractor else { return }
        softwareFrameExtractorCleanupGeneration &+= 1
        let cleanupGeneration = softwareFrameExtractorCleanupGeneration
        let previousCleanup = softwareFrameExtractorCleanupTask
        softwareFrameExtractorCleanupTask = Task { [weak self] in
            await previousCleanup?.value
            await extractor.shutdown()
            guard let self,
                  self.softwareFrameExtractorCleanupGeneration == cleanupGeneration else { return }
            self.softwareFrameExtractorCleanupTask = nil
        }
    }

    private func resetHybridThumbnailState(generation: UInt64, streamKey: String = "") {
        lastPassiveCaptureTime = -100
        isPerformingPassiveCapture = false
        coarseThumbnailTaskToken &+= 1
        coarseThumbnailTask?.cancel()
        coarseThumbnailTask = nil
        coarseSampleTimes = []
        coarseSampleCursor = 0
        coarseResumeNotBefore = Date().addingTimeInterval(3)
        coarseThumbnailUnavailable = false
        coarseThumbnailComplete = false
        let index = hybridThumbnailIndex
        let resetTask = Task { await index.reset(generation: generation, streamKey: streamKey) }
        thumbnailIndexResetTask = resetTask
    }

    func setExternalTrickplayProvider(_ provider: (any TrickplayProviding)?) {
        cancelScrubThumbnailWork()
        externalProviderGeneration &+= 1
        let providerGeneration = externalProviderGeneration
        let generation = loadGeneration
        externalTrickplayProvider = provider
        let resetTask = thumbnailIndexResetTask
        Task { [weak self] in
            await resetTask?.value
            guard let self,
                  self.loadGeneration == generation,
                  self.externalProviderGeneration == providerGeneration else { return }
            await self.hybridThumbnailIndex.setExternalTrickplayProvider(provider)
        }
    }

    /// Passively harvests stills into the local trickplay cache during normal playback.
    /// Operates directly on the decoded presentation buffer in GPU/VRAM:
    /// 0 additional HTTP requests, 0 secondary demuxers, 0 secondary decoders.
    private func recordPassivePlaybackThumbnailIfNeeded(atSeconds sourceTime: Double) {
        guard sourceTime.isFinite, sourceTime >= 0 else { return }
        guard isTransportPlaying, isPlayerPlaying, !isPlayerLoading else { return }
        guard Date() >= coarseResumeNotBefore else { return }
        guard abs(sourceTime - lastPassiveCaptureTime) >= 10.0 else { return }
        guard !isPerformingPassiveCapture else { return }

        lastPassiveCaptureTime = sourceTime
        isPerformingPassiveCapture = true
        let generation = self.loadGeneration
        let targetSeconds = sourceTime

        // Capture already-decoded video frame directly from active display pipeline
        guard let capturedImage = engine.captureCurrentVideoFrame(maxWidth: 320) else {
            isPerformingPassiveCapture = false
            return
        }

        let key = self.contentCanonicalKey ?? self.currentStreamKey
        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isPerformingPassiveCapture = false
                }
            }
            guard let self, self.loadGeneration == generation else { return }

            // Store directly in RAM coarse cache
            await self.hybridThumbnailIndex.store(
                capturedImage,
                seconds: targetSeconds,
                kind: .coarse,
                generation: generation,
                persistToDisk: false
            )

            // Persist to disk store in background
            if !key.isEmpty {
                await TrickplayDiskCache.shared.store(
                    image: capturedImage,
                    streamKey: key,
                    seconds: targetSeconds
                )
            }
        }
    }

    /// Stop coarse work immediately when a user starts seeking. The software
    /// extractor is retained so its next foreground request supersedes the
    /// canceled coarse decode.
    func suspendCoarseThumbnailWork() {
        cancelScrubThumbnailWork()
        coarseThumbnailTaskToken &+= 1
        coarseThumbnailTask?.cancel()
        coarseThumbnailTask = nil
        coarseResumeNotBefore = Date().addingTimeInterval(2)
    }

    /// Release paused-only thumbnail decoders as soon as playback actually resumes,
    /// including engine-driven resumes that do not pass through playPlayback().
    private func releaseAuxiliaryThumbnailWorkForPlayback() {
        cancelScrubThumbnailWork()
        suspendCoarseThumbnailWork()
        let generation = loadGeneration
        let sourceContext = thumbnailSourceContext
        let cleanupEngine = engine
        engineAuxiliaryCleanupRequestID &+= 1
        let cleanupRequestID = engineAuxiliaryCleanupRequestID
        let previousCleanup = engineAuxiliaryCleanupTask
        engineAuxiliaryCleanupTask = Task { @MainActor [weak self, cleanupEngine, previousCleanup] in
            _ = await previousCleanup?.value
            guard let self, self.engineAuxiliaryCleanupRequestID == cleanupRequestID else { return }
            guard self.loadGeneration == generation, !self.isAwaitingEngineLoad else {
                self.engineAuxiliaryCleanupTask = nil
                return
            }
            guard !Task.isCancelled, self.thumbnailSourceContext == sourceContext else {
                self.engineAuxiliaryCleanupTask = nil
                return
            }
            await cleanupEngine.closeAuxiliaryScrubExtractorsAndWait()
            if self.engineAuxiliaryCleanupRequestID == cleanupRequestID {
                self.engineAuxiliaryCleanupTask = nil
            }
        }
        didPrewarmSoftwareFrameExtractor = false
        if let extractor = softwareFrameExtractor {
            Task { await extractor.closeAuxiliaryContext() }
        }
    }

    static func shouldReleaseAuxiliaryThumbnailWork(
        for phase: PlaybackPhase,
        after previousPhase: PlaybackPhase?
    ) -> Bool {
        phase == .playing && previousPhase != .playing
    }

    func advanceCoarseThumbnailIfNeeded(duration: Double) {
        guard !isAwaitingEngineLoad else { return }
        if usesBoundedProgressiveScrubPreview(thumbnailSourceContext) { return }
        guard !isRemoteStream || isLocalPlaybackCache else { return }
        guard engine.playbackPhase == .paused, !isTransportPlaying else { return }
        guard duration >= HybridSeekThumbnailPolicy.coarseIntervalSeconds,
              Date() >= coarseResumeNotBefore,
              !coarseThumbnailUnavailable,
              coarseThumbnailTask == nil,
              (engine.playbackBackend == .software || isLocalPlaybackCache) else { return }
        let samples = HybridSeekThumbnailPolicy.coarseSampleTimes(duration: duration)
        guard !samples.isEmpty else { return }
        if coarseSampleTimes.count != samples.count ||
           coarseSampleTimes.last != samples.last {
            coarseSampleTimes = samples
            coarseSampleCursor = 0
            coarseThumbnailComplete = false
        }
        guard !coarseThumbnailComplete,
              coarseSampleCursor < coarseSampleTimes.count else {
            coarseThumbnailComplete = true
            return
        }
        let token = coarseThumbnailTaskToken
        let generation = loadGeneration
        coarseThumbnailTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.coarseThumbnailTaskToken == token {
                    self.coarseThumbnailTask = nil
                }
            }
            guard let self, self.engine.playbackPhase == .paused, !self.isTransportPlaying else { return }
            var cursor = self.coarseSampleCursor
            while cursor < self.coarseSampleTimes.count {
                let hasCoarse = await self.hybridThumbnailIndex.hasCoarse(
                    at: self.coarseSampleTimes[cursor], generation: generation
                )
                guard self.engine.playbackPhase == .paused, !self.isTransportPlaying else { return }
                if !hasCoarse { break }
                cursor += 1
            }
            self.coarseSampleCursor = cursor
            if cursor >= self.coarseSampleTimes.count {
                self.coarseThumbnailComplete = true
                return
            }
            guard cursor < self.coarseSampleTimes.count,
                  !Task.isCancelled,
                  self.engine.playbackPhase == .paused,
                  !self.isTransportPlaying,
                  self.coarseThumbnailTaskToken == token,
                  self.loadGeneration == generation else { return }
            let seconds = self.coarseSampleTimes[cursor]
            guard let extractor = self.getOrCreateFrameExtractor() else {
                self.coarseThumbnailUnavailable = true
                self.coarseResumeNotBefore = Date().addingTimeInterval(10)
                return
            }
            // The extractor cache keys omit output size; match the foreground
            // card so prefetch cannot leave a lower-resolution cached still.
            let image = await extractor.preciseThumbnail(at: seconds, maxWidth: 480)
            guard !Task.isCancelled,
                  self.engine.playbackPhase == .paused,
                  !self.isTransportPlaying,
                  self.coarseThumbnailTaskToken == token,
                  self.loadGeneration == generation else { return }
            self.coarseResumeNotBefore = Date().addingTimeInterval(1)
            if let image {
                await self.hybridThumbnailIndex.store(
                    image, seconds: seconds, kind: .coarse, generation: generation
                )
            }
            // A nil is a completed attempt for this sample, not a reason to
            // retry forever; move on and let later samples provide coverage.
            self.coarseSampleCursor = cursor + 1
            if self.coarseSampleCursor >= self.coarseSampleTimes.count {
                self.coarseThumbnailComplete = true
            }
        }
    }

    var engineVersion: String? {
        AetherEngine.version
    }

    var supportsAudioProcessing: Bool {
        engine.supportsAudioProcessing
    }

    var playbackDebugInfo: PlaybackDebugInfo {
        let width = Int(engine.sourceVideoWidth > 0 ? engine.sourceVideoWidth : sourceProbe?.videoWidth ?? 0)
        let height = Int(engine.sourceVideoHeight > 0 ? engine.sourceVideoHeight : sourceProbe?.videoHeight ?? 0)
        let fpsVal = engine.sourceVideoFrameRate ?? sourceProbe?.videoFrameRate
        let fpsStr = fpsVal.map { String(format: "%.3f fps", $0) } ?? ""
        let sourceRange = Self.dynamicRangeLabel(
            engine.sourceVideoFormat,
            dolbyVisionProfile: engine.sourceDVProfile ?? sourceProbe?.dvProfile
        )
        let outputRange = Self.dynamicRangeLabel(engine.videoFormat, dolbyVisionProfile: nil)
        let range = engine.sourceVideoFormat == engine.videoFormat
            ? sourceRange
            : "\(sourceRange) → \(outputRange)"
        let selectedAudio = audioTracks.first(where: \.selected) ?? audioTracks.first
        let audioDetail = selectedAudio.map {
            $0.detail.isEmpty ? $0.title : $0.detail
        } ?? "Unknown"
        let selectedSourceAudio = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex })
            ?? engine.audioTracks.first
        let audioSource = Self.audioSourceDiagnostics(
            for: selectedSourceAudio,
            activeDecoder: engine.activeAudioDecoder,
            isLoading: engine.state == .loading
        )

        let codecName = (sourceProbe?.videoCodecName ?? "hevc").lowercased()
        let isDV = engine.sourceDVProfile != nil || (sourceProbe?.dvProfile ?? 0) > 0 || engine.sourceVideoFormat == .dolbyVision
        let videoStr = width > 0 && height > 0
            ? "\(width)×\(height) · \(fpsStr) · \(isDV ? "dolby-vision" : codecName)"
            : "\(fpsStr) · \(isDV ? "dolby-vision" : codecName)"

        // Video Bitrate
        let telemetry = engine.liveTelemetry
        let avSyncGapMs = telemetry?.avSyncGapMs.flatMap { $0.isFinite ? $0 : nil }
        var vBitrateParts: [String] = []
        if engine.sourceVideoBitrate > 0 {
            vBitrateParts.append(String(format: "avg mux %.1f Mbit/s", Double(engine.sourceVideoBitrate) / 1_000_000.0))
        } else if let avgBitrate = telemetry?.averageBitrateMbps, avgBitrate > 0 {
            vBitrateParts.append(String(format: "avg mux %.1f Mbit/s", avgBitrate))
        }
        if let instBitrate = telemetry?.instantBitrateMbps, instBitrate > 0 {
            vBitrateParts.append(String(format: "now %.1f Mbit/s", instBitrate))
        } else if vBitrateParts.isEmpty {
            vBitrateParts.append("now -- Mbit/s")
        }
        let vBitrateStr = vBitrateParts.joined(separator: " · ")

        // Dolby Vision line
        let dvProfile = engine.sourceDVProfile ?? sourceProbe?.dvProfile
        let dvStr = Self.dolbyVisionRouteDescription(
            sourceProfile: dvProfile,
            conversion: engine.dolbyVisionConversion,
            felComposedFrameCount: engine.dolbyVisionFELComposedFrameCount
        ) ?? (isDV ? "Dolby Vision" : "None")

        // DV HDR Metadata line
        let dvHdrStr = isDV
            ? "Dolby Vision (Metadata unavailable)"
            : (sourceRange.contains("HDR") ? "BT.2020 · PQ Transfer" : "BT.709 · Standard Dynamic Range")

        // Decoder
        let decoderStr: String
        if let active = engine.activeVideoDecoder, !active.isEmpty {
            decoderStr = active
        } else if engine.playbackBackend == .native {
            decoderStr = isDV ? "c2.apple.dolby-vision.dvhe.decoder" : "com.apple.videotoolbox (Hardware)"
        } else {
            decoderStr = "Aether.\(sourceProbe?.videoCodecName ?? "libavcodec") (Software)"
        }

        // Dropped frames
        let droppedCount = telemetry?.droppedFrameCount ?? 0
        let droppedStr = "\(droppedCount) frames"

        // Frame lead / Cushion
        let frameLeadStr: String
        if let cushion = telemetry?.displayCushionSeconds {
            frameLeadStr = String(format: "+%.1f ms", cushion * 1000.0)
        } else if let avSyncGapMs {
            frameLeadStr = formattedAVSyncGap(avSyncGapMs)
        } else {
            frameLeadStr = "Unavailable"
        }

        // Display refresh rate
        let displayStr = PlaybackSystemMonitor.displayRefreshRate(nominalFps: fpsVal)

        let deliveryStr = Self.audioDeliveryDescription(
            engine.audioDelivery,
            decoder: audioSource.pipeline
        )
        let structuredAudioPipeline = engine.state == .loading || engine.audioDelivery == .none
            ? nil
            : deliveryStr

        // Audio format line
        let audioFormatted: String
        if let selectedAudio {
            let title = selectedAudio.title
            let detail = selectedAudio.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty && detail != title {
                audioFormatted = "\(title) · \(detail) · \(deliveryStr)"
            } else {
                audioFormatted = "\(title) · \(deliveryStr)"
            }
        } else {
            audioFormatted = audioDetail.isEmpty ? deliveryStr : "\(audioDetail) · \(deliveryStr)"
        }

        // Audio bitrate
        let aBitrateStr: String
        if let aRate = telemetry?.audioBridgeBitrateMbps, aRate > 0 {
            aBitrateStr = String(format: "meas %.2f Mbit/s", aRate)
        } else {
            aBitrateStr = ""
        }

        // Audio route
        let routeStr = PlaybackSystemMonitor.audioRouteInfo()

        // Audio jitter
        let aJitterStr = formattedAVSyncGap(avSyncGapMs)

        // Network buffer
        let bufferSec: Double
        let bufferStr: String
        if bufferedMs > positionMs {
            bufferSec = Double(bufferedMs - positionMs) / 1000.0
            bufferStr = String(format: "%.1f s ahead", bufferSec)
        } else if let fwd = telemetry?.forwardBufferSeconds, fwd > 0 {
            bufferSec = fwd
            bufferStr = String(format: "%.1f s ahead", bufferSec)
        } else if engine.playbackBackend == .software {
            let cushion = telemetry?.displayCushionSeconds ?? 0.3
            bufferSec = cushion
            bufferStr = String(format: "%.1f s cushion (Direct queue)", cushion)
        } else {
            bufferSec = 0.0
            bufferStr = "0.0 s ahead"
        }

        // Network speed
        let speedStr: String
        if let tp = telemetry?.networkThroughputMbps, tp > 0 {
            speedStr = String(format: "est %.1f Mbit/s", tp)
        } else {
            speedStr = "est -- Mbit/s"
        }

        // Network loaded
        let loadedBytes = telemetry?.networkTransferredBytes ?? telemetry?.demuxerBytesFetched ?? telemetry?.cachedBytes ?? 0
        let loadedStr = loadedBytes > 0
            ? ByteCountFormatter.string(fromByteCount: loadedBytes, countStyle: .file)
            : "--"

        // Network stalls
        let stallsCount = telemetry?.producerRestartCount ?? 0

        // System
        let cpuPercent = PlaybackSystemMonitor.cpuUsage()
        let appCpuStr = cpuPercent > 0 ? String(format: "%.0f %%", cpuPercent) : "-- %"

        let mem = PlaybackSystemMonitor.memoryUsage()
        let memStr = mem.residentMB > 0
            ? String(format: "heap %.0f/%.0f MB · native %.0f MB", mem.residentMB, max(0.0, mem.availableMB), max(0.0, mem.virtualMB))
            : "Unavailable"

        let thermal = PlaybackSystemMonitor.thermalInfo()
        let socTempStr = thermal.tempString
        let cpuClockStr = PlaybackSystemMonitor.cpuInfo()

        return PlaybackDebugInfo(
            player: "AetherEngine",
            pipeline: engine.playbackBackend.rawValue.capitalized,
            videoCodec: Self.codecLabel(sourceProbe?.videoCodecName),
            dynamicRange: range,
            resolution: width > 0 && height > 0 ? "\(width)×\(height)" : "Unknown",
            frameRate: fpsStr,
            audio: audioFormatted,
            audioSourceCodec: audioSource.codec,
            audioSourceChannels: audioSource.channels,
            audioSpatialFormat: audioSource.spatialFormat,
            audioPipeline: structuredAudioPipeline,
            avSyncGapMs: avSyncGapMs,
            video: videoStr,
            hdr: sourceRange,
            vBitrate: vBitrateStr,
            dv: dvStr,
            dvHdr: dvHdrStr,
            decoder: decoderStr,
            dropped: droppedStr,
            droppedCount: droppedCount,
            frameLead: frameLeadStr,
            display: displayStr,
            aBitrate: aBitrateStr,
            underruns: "0 · native 0",
            underrunsCount: 0,
            route: routeStr,
            aJitter: aJitterStr,
            buffer: bufferStr,
            bufferSeconds: bufferSec,
            speed: speedStr,
            ping: "--",
            loaded: loadedStr,
            stalls: "\(stallsCount)",
            stallsCount: stallsCount,
            appCpu: appCpuStr,
            appCpuPercent: cpuPercent,
            memory: memStr,
            socTemp: socTempStr,
            isThermalElevated: thermal.isElevated,
            cpuClock: cpuClockStr,
            diagnostics: engine.displayDebugLines
        )
    }

    /// Creates an Aether host when the engine can be initialized. A failed
    /// construction is returned to the session coordinator so Auto can select
    /// MPVKit and an explicitly forced Aether session can show a recoverable
    /// error instead of crashing during view-model initialization.
    init?(engine: AetherEngine? = nil) {
        PlaybackDiagnosticLogStore.installAetherEngineHandlerIfNeeded()
        guard let resolvedEngine = engine ?? (try? AetherEngine()) else {
            return nil
        }
        self.engine = resolvedEngine
        super.init(nibName: nil, bundle: nil)
        subtitleOverlayState.onASSCanvasSizeChanged = { [weak self] renderer in
            self?.assCoordinator.canvasDidChange(for: renderer)
        }
        assCoordinator.onRendererChanged = { [weak self] renderer in
            guard let self else { return }
            self.subtitleOverlayState.updateASS(renderer: renderer, isActive: self.activeASSTrackID != nil)
        }
        assCoordinator.reloadSignal
            .sink { [weak self] event in self?.subtitleOverlayState.assReloadSignal.send(event) }
            .store(in: &cancellables)
        #if os(tvOS) || os(iOS)
        self.engine.ownsVideoNowPlayingSession = true
        #endif
        subtitleTranslationState.onCueTranslationResolved = { [weak self] cueID in
            self?.releaseAISubtitleStartupHold(for: cueID)
        }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebindSurface()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        rebindSurface()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerView.setNeedsLayout()
        playerView.layoutIfNeeded()
    }

    func rebindSurface() {
        // `AetherPlayerView.attach` repairs a layer that AVKit/SwiftUI removed
        // or reparented while the controller was in PiP. Keep this operation
        // idempotent: PlayerView's representable update runs frequently, and
        // detaching on every update needlessly churns the render surface.
        engine.bind(view: playerView)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    deinit {
        foregroundReloadTask?.cancel()
        activeThumbnailTask?.cancel()
        activeThumbnailCancellation?.cancel()
        coarseThumbnailTask?.cancel()
        if let extractor = softwareFrameExtractor {
            Task { await extractor.shutdown() }
        }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appWillResignActive() {
        let observedResumeIntent = AetherPlaybackLifecyclePolicy.shouldResumeAfterBackground(
            state: engine.state,
            isPlayerPlaying: isPlayerPlaying,
            isTransportPlaying: isTransportPlaying,
            previousIntent: playbackWasPlayingBeforeBackground
        )
        if !engine.pictureInPictureActive {
            let mark = lifecycleReloadToken
            onWillSuspendPlayback?()
            guard lifecycleReloadToken == mark else { return }
        }
        foregroundReloadActiveCancellationRetryCount = 0
        screensaverDebugLog("[ScreensaverDebug][AetherController] appWillResignActive: state=\(engine.state), isPlayerPlaying=\(isPlayerPlaying), lastKnownPos=\(lastKnownPositionMs)ms, clock=\(engine.clock.currentTime)")
        let interruptedReload = foregroundReloadTask != nil
        if !engine.pictureInPictureActive {
            // Invalidate the task before cancellation so its catch path cannot
            // publish an expected background interruption as a terminal error.
            lifecycleReloadToken &+= 1
            if interruptedReload {
                needsForegroundReload = true
            }
            foregroundReloadTask?.cancel()
            foregroundReloadTask = nil
        }
        playbackWasPlayingBeforeBackground = observedResumeIntent
        screensaverDebugLog("[ScreensaverDebug][AetherController] appWillResignActive: computed playbackWasPlayingBeforeBackground=\(playbackWasPlayingBeforeBackground)")
        #if os(tvOS)
        let pos = lastKnownPositionMs
        let dur = lastKnownDurationMs
        onPlaybackSuspended?(pos, dur)
        #endif

        let shouldReload = AetherPlaybackLifecyclePolicy.shouldReloadAfterBackground(state: engine.state)
        screensaverDebugLog("[ScreensaverDebug][AetherController] appWillResignActive: shouldReload=\(shouldReload)")
        guard shouldReload || interruptedReload else { return }
        needsForegroundReload = true
        screensaverDebugLog("[ScreensaverDebug][AetherController] appWillResignActive: set needsForegroundReload=true, playbackWasPlayingBeforeBackground=\(playbackWasPlayingBeforeBackground)")
    }

    @objc private func appDidEnterBackground() {
        let observedResumeIntent = AetherPlaybackLifecyclePolicy.shouldResumeAfterBackground(
            state: engine.state,
            isPlayerPlaying: isPlayerPlaying,
            isTransportPlaying: isTransportPlaying,
            previousIntent: playbackWasPlayingBeforeBackground
        )
        if !engine.pictureInPictureActive {
            let mark = lifecycleReloadToken
            onWillSuspendPlayback?()
            guard lifecycleReloadToken == mark else { return }
        }
        foregroundReloadActiveCancellationRetryCount = 0
        let pos = lastKnownPositionMs
        let dur = lastKnownDurationMs
        screensaverDebugLog("[ScreensaverDebug][AetherController] appDidEnterBackground: state=\(engine.state), isPlayerPlaying=\(isPlayerPlaying), pos=\(pos)ms, dur=\(dur)ms, clock=\(engine.clock.currentTime)")
        onPlaybackSuspended?(pos, dur)

        let interruptedReload = foregroundReloadTask != nil
        let shouldReload = AetherPlaybackLifecyclePolicy.shouldReloadAfterBackground(state: engine.state)
        screensaverDebugLog("[ScreensaverDebug][AetherController] appDidEnterBackground: shouldReload=\(shouldReload)")
        guard shouldReload || interruptedReload else { return }

        lifecycleReloadToken &+= 1
        if interruptedReload {
            needsForegroundReload = true
        }
        foregroundReloadTask?.cancel()
        foregroundReloadTask = nil
        needsForegroundReload = true
        if !playbackWasPlayingBeforeBackground {
            playbackWasPlayingBeforeBackground = observedResumeIntent
        }
        screensaverDebugLog("[ScreensaverDebug][AetherController] appDidEnterBackground: set needsForegroundReload=true, playbackWasPlayingBeforeBackground=\(playbackWasPlayingBeforeBackground)")
    }

    @objc private func appDidBecomeActive() {
        screensaverDebugLog("[ScreensaverDebug][AetherController] appDidBecomeActive: appState=\(UIApplication.shared.applicationState.rawValue), needsReload=\(needsForegroundReload), hasTask=\(foregroundReloadTask != nil), wasPlaying=\(playbackWasPlayingBeforeBackground), pip=\(engine.pictureInPictureActive)")
        guard UIApplication.shared.applicationState == .active else { return }
        if !needsForegroundReload, foregroundReloadTask == nil {
            onDidRestorePlayback?()
            return
        }
        guard needsForegroundReload, foregroundReloadTask == nil else { return }

        // PiP keeps Aether's video pipeline alive across backgrounding. If PiP
        // is still active at foreground return, there is no torn down session
        // to reopen (it may have become active after the background event).
        guard !engine.pictureInPictureActive else {
            needsForegroundReload = false
            playbackWasPlayingBeforeBackground = false
            onDidRestorePlayback?()
            return
        }

        needsForegroundReload = false
        let shouldResume = playbackWasPlayingBeforeBackground
        let token = lifecycleReloadToken
        screensaverDebugLog("[ScreensaverDebug][AetherController] appDidBecomeActive: starting foreground reload task with shouldResume=\(shouldResume), token=\(token)")
        rebindSurface()
        var shouldRetryAfterTaskClears = false
        foregroundReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleReloadToken == token {
                    self.foregroundReloadTask = nil
                    if shouldRetryAfterTaskClears {
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.lifecycleReloadToken == token,
                                  self.foregroundReloadTask == nil,
                                  self.needsForegroundReload,
                                  UIApplication.shared.applicationState == .active,
                                  self.foregroundReloadActiveCancellationRetryCount == AetherPlaybackLifecyclePolicy.maximumActiveCancellationRetries else { return }
                            self.appDidBecomeActive()
                        }
                    }
                }
            }
            do {
                screensaverDebugLog("[ScreensaverDebug][AetherController] calling engine.reloadAtCurrentPosition()")
                try await self.engine.reloadAtCurrentPosition()
                screensaverDebugLog("[ScreensaverDebug][AetherController] engine.reloadAtCurrentPosition completed")
            } catch {
                let disposition = AetherPlaybackLifecyclePolicy.reloadFailureDisposition(
                    isCancellation: error is CancellationError || Task.isCancelled,
                    tokenIsCurrent: self.lifecycleReloadToken == token,
                    applicationIsActive: UIApplication.shared.applicationState == .active,
                    activeCancellationRetryCount: self.foregroundReloadActiveCancellationRetryCount
                )
                switch disposition {
                case .ignore:
                    return
                case .keepPending:
                    self.needsForegroundReload = true
                    return
                case .retryAfterTaskClears:
                    self.needsForegroundReload = true
                    self.foregroundReloadActiveCancellationRetryCount += 1
                    shouldRetryAfterTaskClears = true
                    return
                case .report:
                    break
                }
                let message = error.localizedDescription
                screensaverDebugLog("[ScreensaverDebug][AetherController] engine.reloadAtCurrentPosition FAILED: \(message)")
                self.currentErrorMessage = message
                self.isPlayerLoading = false
                if !self.didReportTerminalError {
                    self.didReportTerminalError = true
                    self.onTerminalError?(message)
                }
                return
            }

            guard self.lifecycleReloadToken == token,
                  !self.engine.pictureInPictureActive else {
                screensaverDebugLog("[ScreensaverDebug][AetherController] reload completed but token mismatch or pip active")
                return
            }
            guard !Task.isCancelled else {
                self.needsForegroundReload = true
                return
            }
            guard UIApplication.shared.applicationState == .active else {
                self.needsForegroundReload = true
                return
            }
            self.foregroundReloadActiveCancellationRetryCount = 0
            self.rebindSurface()
            let resumeAfterReload = shouldResume || self.playbackWasPlayingBeforeBackground
            screensaverDebugLog("[ScreensaverDebug][AetherController] reload completed, asserting post-reload state: resumeAfterReload=\(resumeAfterReload)")
            if resumeAfterReload && !self.isWatchPartyControlled {
                self.engine.play()
            } else {
                self.engine.pause()
            }
            guard self.lifecycleReloadToken == token,
                  !Task.isCancelled,
                  UIApplication.shared.applicationState == .active else {
                self.needsForegroundReload = true
                return
            }
            self.playbackWasPlayingBeforeBackground = false
            self.onDidRestorePlayback?()
        }
    }

    private func observeEngine() {
        engine.$startupProgress
            .handleEvents(receiveOutput: { [startupProgressGenerationObserver] progress in
                startupProgressGenerationObserver.record(progress)
            })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self else { return }
                self.startupProgress = progress
                self.onStartupProgressChanged?(progress)
                guard let progress,
                      progress.generation == self.engine.startupProgress?.generation else { return }
                guard var owner = self.startupBenchmarkLoadOwner,
                      owner.loadGeneration == self.loadGeneration,
                      let token = owner.token else { return }
                if owner.engineGeneration == nil {
                    guard progress.checkpoint == .dispatched,
                          progress.generation >= owner.engineGenerationFloor else { return }
                    owner.engineGeneration = progress.generation
                    self.startupBenchmarkLoadOwner = owner
                }
                guard owner.engineGeneration == progress.generation else { return }
                let cp = progress.checkpoint
                switch cp {
                case .dispatched:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("dispatched", token: token)
                case .sourceOpened:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("sourceOpened", token: token)
                case .streamsProbed:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("streamsProbed", token: token)
                case .displayPrepared:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("displayPrepared", token: token)
                case .sessionConstructed:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("sessionConstructed", token: token)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // `.stalled` outranks `.rebuffering` in the engine's phase fold, so the buffer axis
        // has to be observed alongside it to tell a masked reconnect from a frozen picture.
        Publishers.CombineLatest(engine.$playbackPhase, engine.$isBuffering)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, isBuffering in
                self?.applyPhase(phase, engineIsBuffering: isBuffering)
            }
            .store(in: &cancellables)

        engine.$hasFirstFrameReadyForDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                guard let self, !self.isAwaitingEngineLoad else { return }
                if isReady {
                    if self.isPlayerLoading {
                        self.isPlayerLoading = false
                        self.isPlayerPlaying = true
                    }
                    self.onFirstFrameReady?()
                }
            }
            .store(in: &cancellables)

        engine.clock.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isAwaitingEngineLoad else { return }
                self.refreshClock()
            }
            .store(in: &cancellables)

        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sourceTime in
                guard let self else { return }
                self.subtitleOverlayState.updateSourceTime(sourceTime)
                self.subtitleOverlayState.updateNativeVideoRect(self.engine.nativePlayerLayer?.videoRect)
                if self.activeASSTrackID == nil {
                    self.subtitleTranslationState.update(
                        cues: self.subtitleCues,
                        at: sourceTime - self.subtitleDelaySeconds
                    )
                    self.beginAISubtitleStartupHoldIfNeeded(
                        cues: self.subtitleCues,
                        sourceTime: sourceTime - self.subtitleDelaySeconds
                    )
                }
                self.recordPassivePlaybackThumbnailIfNeeded(atSeconds: sourceTime)
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.mapAudioTracks(tracks)
            }
            .store(in: &cancellables)

        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.mapAudioTracks(self.engine.audioTracks)
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.mapSubtitleTracks(tracks)
            }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.mapSubtitleTracks(self.engine.subtitleTracks)
            }
            .store(in: &cancellables)

        engine.$sidecarASSHeader
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshASSRenderer(for: self.engine.subtitleTracks)
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                self.subtitleCues = cues
                self.subtitleOverlayState.updateCues(cues)
                if self.activeASSTrackID == nil {
                    self.subtitleTranslationState.update(
                        cues: cues,
                        at: self.engine.clock.sourceTime - self.subtitleDelaySeconds
                    )
                    self.beginAISubtitleStartupHoldIfNeeded(
                        cues: cues,
                        sourceTime: self.engine.clock.sourceTime - self.subtitleDelaySeconds
                    )
                }
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

    func applyPhase(_ phase: PlaybackPhase, engineIsBuffering: Bool) {
        if isAwaitingEngineLoad {
            if phase != engineLoadInitialPhase {
                isAwaitingEngineLoad = false
                engineLoadInitialPhase = nil
            } else {
                isPlayerLoading = true
                isPlayerPlaying = false
                isPlayerEnded = false
                isAtEndOfFile = false
                refreshClock()
                return
            }
        }
        if Self.shouldReleaseAuxiliaryThumbnailWork(for: phase, after: lastAppliedPlaybackPhase) {
            releaseAuxiliaryThumbnailWorkForPlayback()
        }
        lastAppliedPlaybackPhase = phase
        switch phase {
        case .idle:
            isPlayerLoading = false
            isPlayerPlaying = false
            isPlayerEnded = false
        case .loading:
            if engine.hasFirstFrameReadyForDisplay || isTransportPlaying {
                isPlayerLoading = false
                isPlayerPlaying = true
            } else {
                isPlayerLoading = true
                isPlayerPlaying = false
            }
            isPlayerEnded = false
        case .playing:
            isPlayerLoading = false
            isPlayerPlaying = true
            isPlayerEnded = false
            clearTerminalErrorAfterVerifiedRecovery()
        case .paused:
            isPlayerLoading = false
            isPlayerPlaying = false
            isPlayerEnded = false
        case .seeking:
            isPlayerLoading = true
            isPlayerPlaying = false
        case .rebuffering, .stalled:
            // Only flag loading if playback has actually halted / stopped while actively attempting to play.
            // If frames are still actively rolling (isTransportPlaying / isPlayerPlaying / hasFirstFrameReadyForDisplay),
            // keep loading hidden so the spinner does not obscure rolling video.
            // If the transport is intentionally paused, do NOT flag loading so pause doesn't show a spinner.
            if !isTransportPlaying && engine.state == .paused {
                isPlayerLoading = false
                isPlayerPlaying = false
            } else {
                let isActivelyPlaying = isTransportPlaying || isPlayerPlaying || engine.hasFirstFrameReadyForDisplay
                isPlayerLoading = !isActivelyPlaying
                isPlayerPlaying = isActivelyPlaying
            }
        case .ended:
            isPlayerLoading = false
            isPlayerPlaying = false
            isPlayerEnded = true
            isAtEndOfFile = true
        case .error(let message):
            if needsForegroundReload || foregroundReloadTask != nil {
                // Aether may briefly report an error while its lifecycle
                // reload is being canceled or reopened. The reload task owns
                // the terminal result for this interval.
                isPlayerLoading = true
                isPlayerPlaying = false
                isPlayerEnded = false
                break
            }
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

    @discardableResult
    func clearTerminalErrorAfterVerifiedRecovery() -> Bool {
        guard case .playing = engine.playbackPhase,
              isPlayerPlaying,
              !isPlayerLoading,
              engine.hasFirstFrameReadyForDisplay || engine.isTransportPlaying else { return false }
        currentErrorMessage = ""
        didReportTerminalError = false
        return true
    }

    private func refreshClock() {
        guard !isAwaitingEngineLoad else {
            positionMs = 0
            durationMs = 0
            bufferedMs = 0
            sourceTimeSeconds = 0
            lastKnownPositionMs = 0
            lastKnownDurationMs = 0
            lastKnownSourceTimeSeconds = 0
            hasCoherentTimeSample = false
            return
        }
        let current = engine.clock.currentTime
        let source = engine.clock.sourceTime
        let buffered = engine.clock.bufferedPosition
        sourceTimeSeconds = source.isFinite ? max(0, source) : 0
        let sampledPositionMs = Int64((max(0, current) * 1000).rounded())
        bufferedMs = Int64((max(0, buffered) * 1000).rounded())
        if current.isFinite, current >= 0, engine.duration > 0 {
            // Prevent teardown/suspension 0-clock sample from clobbering an established playback position
            if sampledPositionMs > 0 || lastKnownPositionMs == 0 || engine.state == .seeking {
                lastKnownPositionMs = sampledPositionMs
                positionMs = sampledPositionMs
                hasCoherentTimeSample = true
            } else if lastKnownPositionMs > 0 {
                // When returning from background while paused or reconnecting, preserve the established position
                // rather than exposing a transient 0.0 clock sample.
                positionMs = lastKnownPositionMs
                hasCoherentTimeSample = true
            } else {
                positionMs = sampledPositionMs
                hasCoherentTimeSample = true
            }
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

    private func beginAISubtitleStartupHoldIfNeeded(
        cues: [SubtitleCue],
        sourceTime: Double
    ) {
        guard !didAttemptAISubtitleStartupHold,
              aiSubtitleStartupHoldCueID == nil,
              isPlayerPlaying,
              subtitleTranslationState.isActive,
              let activeCue = cues.first(where: {
                  $0.startTime <= sourceTime &&
                      $0.endTime >= sourceTime &&
                      !($0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
              }),
              subtitleTranslationState.translatedText(for: activeCue) == nil,
              subtitleTranslationState.isTranslating(cueIDs: [activeCue.id]) else { return }

        didAttemptAISubtitleStartupHold = true
        aiSubtitleStartupHoldCueID = activeCue.id
        engine.pause()

        aiSubtitleStartupHoldTimeoutTask?.cancel()
        aiSubtitleStartupHoldTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64((self?.aiSubtitleStartupHoldTimeout ?? 0) * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.releaseAISubtitleStartupHold()
        }
    }

    private func releaseAISubtitleStartupHold(for cueID: Int? = nil, resume: Bool = true) {
        guard let heldCueID = aiSubtitleStartupHoldCueID,
              cueID == nil || cueID == heldCueID else { return }
        aiSubtitleStartupHoldTimeoutTask?.cancel()
        aiSubtitleStartupHoldTimeoutTask = nil
        aiSubtitleStartupHoldCueID = nil
        if resume { engine.play() }
    }

    private func resetAISubtitleStartupHold() {
        aiSubtitleStartupHoldTimeoutTask?.cancel()
        aiSubtitleStartupHoldTimeoutTask = nil
        aiSubtitleStartupHoldCueID = nil
        didAttemptAISubtitleStartupHold = false
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
                isForced: t.isForced,
                isNativelyRenderedSubtitle: t.isNativelyRenderedSubtitle,
                languageName: t.language ?? "",
                detail: t.codec
            )
        }
        refreshASSRenderer(for: tracks)
    }

    private func refreshASSRenderer(for tracks: [TrackInfo]) {
        let selected = tracks.first { $0.id == engine.activeSubtitleTrackIndex }
        let codec = selected?.codec.lowercased() ?? ""
        let isASS = codec.hasPrefix("ass") || codec.hasPrefix("ssa")
            || selected?.assHeader != nil
            || (selected?.isExternal == true && engine.sidecarASSHeader != nil)
        guard let selected,
              !selected.isNativelyRenderedSubtitle,
              isASS else {
            if activeASSTrackID != nil {
                activeASSTrackID = nil
                activeASSHeader = nil
                assCoordinator.deactivate()
                subtitleOverlayState.updateASS(renderer: nil, isActive: false)
            }
            return
        }
        let rawHeader = selected.isExternal ? engine.sidecarASSHeader : selected.assHeader
        let header = resolvedASSHeader(rawHeader)
        if activeASSTrackID != selected.id || activeASSHeader != header {
            assCoordinator.deactivate()
            activeASSTrackID = selected.id
            activeASSHeader = header
            resetAISubtitleStartupHold()
            subtitleTranslationState.reset()
            assCoordinator.activate(header: header, itemID: currentStreamKey)
        }
        subtitleOverlayState.updateASS(renderer: assCoordinator.renderer, isActive: true)
    }

    /// CodecPrivate occasionally omits PlayRes, which leaves libass on its
    /// legacy 384×288 canvas and scales authored font sizes too large at 1080p.
    private func resolvedASSHeader(_ header: String?) -> String {
        let measuredSourceSize = videoFrameSize.width > 1 && videoFrameSize.height > 1
            ? videoFrameSize
            : CGSize(width: CGFloat(engine.sourceVideoWidth), height: CGFloat(engine.sourceVideoHeight))
        let sourceSize = measuredSourceSize.width > 1 && measuredSourceSize.height > 1
            ? measuredSourceSize
            : CGSize(width: 1920, height: 1080)
        let cleanHeader = header?.replacingOccurrences(of: "\0", with: "") ?? ""
        func declaredPlayRes(_ key: String) -> Double? {
            for line in cleanHeader.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.lowercased().hasPrefix(key.lowercased() + ":"),
                      let value = Double(trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)),
                      value.isFinite, value > 0 else { continue }
                return value
            }
            return nil
        }
        let declaredX = declaredPlayRes("PlayResX")
        let declaredY = declaredPlayRes("PlayResY")
        let sourceAspect = sourceSize.width / sourceSize.height
        let playResX = Int((declaredX ?? declaredY.map { $0 * sourceAspect } ?? sourceSize.width).rounded())
        let playResY = Int((declaredY ?? declaredX.map { $0 / sourceAspect } ?? sourceSize.height).rounded())
        let needsPlayResX = declaredX == nil
        let needsPlayResY = declaredY == nil
        guard needsPlayResX || needsPlayResY else { return cleanHeader }

        var additions = ""
        if needsPlayResX { additions += "\nPlayResX: \(playResX)" }
        if needsPlayResY { additions += "\nPlayResY: \(playResY)" }
        if let marker = cleanHeader.range(of: "[Script Info]", options: .caseInsensitive) {
            var result = cleanHeader
            result.insert(contentsOf: additions, at: marker.upperBound)
            return result
        }
        return "[Script Info]\nScriptType: v4.00+\nPlayResX: \(playResX)\nPlayResY: \(playResY)\n\n\(cleanHeader)"
    }

    static func dolbyVisionRouteDescription(
        sourceProfile: Int?,
        conversion: DolbyVisionConversion?,
        felComposedFrameCount: Int?
    ) -> String? {
        if let felComposedFrameCount {
            return felComposedFrameCount > 0
                ? "P7 FEL · \(felComposedFrameCount) frames composed"
                : "P7 FEL route · awaiting composition"
        }
        if conversion == .profile7ToProfile81 {
            return "P7→8.1 libdovi"
        }
        guard let sourceProfile, sourceProfile > 0 else { return nil }
        switch sourceProfile {
        case 7: return "P7"
        case 8: return "P8"
        default: return "P\(sourceProfile) (Single Track)"
        }
    }

    static func audioSourceDiagnostics(
        for track: TrackInfo?,
        activeDecoder: String?,
        isLoading: Bool = false
    ) -> (codec: String?, channels: Int?, spatialFormat: String?, pipeline: String?) {
        let codec = track?.codec.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = track?.profile?.lowercased() ?? ""
        let pipeline = activeDecoder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visiblePipeline = !isLoading && pipeline?.isEmpty == false ? pipeline : nil
        let pipelineEvidence = visiblePipeline?.lowercased() ?? ""
        let spatialFormat: String?
        if track?.isAtmos == true || profile.contains("atmos") || profile.contains("joc")
            || pipelineEvidence.contains("atmos") || pipelineEvidence.contains("joc") {
            spatialFormat = "Atmos"
        } else if profile.contains("dts:x") || pipelineEvidence.contains("dts:x") {
            spatialFormat = "DTS:X"
        } else {
            spatialFormat = nil
        }
        return (
            codec?.isEmpty == false ? codec : nil,
            track.flatMap { $0.channels > 0 ? $0.channels : nil },
            spatialFormat,
            visiblePipeline
        )
    }

    static func audioDeliveryDescription(_ delivery: AudioDelivery, decoder: String?) -> String {
        let activeDecoder = decoder?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch delivery {
        case .none:
            return "Unavailable"
        case .noAudioInSource:
            return "None (Silent Source)"
        case .streamCopy:
            return "Stream-copy (fMP4 bitstream preserved)"
        case .bridged:
            guard let activeDecoder, !activeDecoder.isEmpty else { return "Bridged (re-encode)" }
            return "Bridged (\(activeDecoder))"
        case .decoded:
            guard let activeDecoder, !activeDecoder.isEmpty else { return "Decoded (Software PCM)" }
            return "Decoded (\(activeDecoder))"
        case .droppedNoPipeline:
            return "Dropped (Pipeline failure or unsupported codec)"
        case .playerManaged:
            return "Player-managed (AVFoundation)"
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
        cancelScrubThumbnailWork()
        thumbnailSourceContext = nil
        externalProviderGeneration &+= 1
        externalTrickplayProvider = nil
        teardownRemoteCommands()
        remoteCommandsAllowed = true
        diagnosticPlayIntent = request.autoplay ? "play" : "pause"
        lastDiagnosticSnapshotUptime = 0
        let currentEngineGeneration = max(
            engine.startupProgress?.generation ?? 0,
            startupProgressGenerationObserver.generation ?? 0
        )
        startupBenchmarkLoadOwner = StartupBenchmarkLoadOwner(
            loadGeneration: generation,
            engineGenerationFloor: currentEngineGeneration &+ 1,
            token: request.startupBenchmarkToken,
            engineGeneration: nil
        )
        lifecycleReloadToken &+= 1
        needsForegroundReload = false
        foregroundReloadActiveCancellationRetryCount = 0
        playbackWasPlayingBeforeBackground = false
        foregroundReloadTask?.cancel()
        foregroundReloadTask = nil
        resetAISubtitleStartupHold()
        loadGeneration = generation
        let isRemote = PlaybackBackendPolicy.isRemoteHTTP(request.videoURL.absoluteString)
        let isRemoteHLS = PlaybackBackendPolicy.isHLS(request.videoURL.absoluteString)
            || request.videoURL.pathExtension.lowercased() == "m3u8"
            || request.videoURL.absoluteString.contains(".m3u8")
            || request.videoURL.host?.contains("googlevideo.com") == true
            || request.streamDescription == PlaybackMarkers.trailerSubtitle
        // The hybrid cache is a local HTTP range server on 127.0.0.1.
        // Holding the source connection open (AE#377) avoids AVIOReader repeatedly
        // terminating and renegotiating range requests every 8–16 MB, preventing
        // CDN rate-limiting/throttling on both loopback and direct remote streams.
        let isLocalPlaybackCache = request.videoURL.host == "127.0.0.1"
            && request.videoURL.path.hasPrefix("/stream/")
        // The local Usenet stream is loopback too, but every read downloads
        // articles: it is played like a remote source (one held connection)
        // and never read for thumbnails.
        let isUsenetStream = UsenetStreamServer.isStreamURL(request.videoURL)
        self.isLocalPlaybackCache = isLocalPlaybackCache
        self.isRemoteStream = isRemote || isLocalPlaybackCache || isUsenetStream
        let streamKey = request.canonicalMediaKey
            ?? TrickplayDiskCache.streamKey(for: request.videoURL.absoluteString)
        self.currentStreamKey = streamKey
        self.contentCanonicalKey = request.canonicalMediaKey ?? streamKey
        thumbnailSourceContext = PlaybackThumbnailSourceContext(
            generation: generation,
            playbackURL: request.videoURL,
            headerSourceURL: request.httpHeaderSourceURL,
            requestHeaders: request.httpHeaders,
            isLive: request.isLiveStream,
            isKnownHLS: isRemoteHLS
                || PlaybackThumbnailSourceFallback.isKnownHLSURL(request.httpHeaderSourceURL),
            streamKey: streamKey
        )
        resetHybridThumbnailState(generation: generation, streamKey: streamKey)
        resetSoftwareFrameExtractor()
        if let trickplayURL = request.trickplayURL {
            Task { [weak self, generation] in
                if let provider = await TrickplayResolver.shared.fetchStoryboard(from: trickplayURL) {
                    guard let self, self.loadGeneration == generation else { return }
                    self.setExternalTrickplayProvider(provider)
                }
            }
        }
        subtitleDelaySeconds = request.subtitleDelaySeconds
        assCoordinator.setSubtitleDelay(subtitleDelaySeconds)
        setAspectMode(request.aspectMode)
        didReportTerminalError = false
        isAwaitingEngineLoad = true
        engineLoadInitialPhase = engine.playbackPhase
        isPlayerLoading = true
        isPlayerEnded = false
        isAtEndOfFile = false
        hasCoherentTimeSample = false
        positionMs = 0
        durationMs = 0
        bufferedMs = 0
        sourceTimeSeconds = 0
        lastKnownPositionMs = 0
        lastKnownDurationMs = 0
        lastKnownSourceTimeSeconds = 0
        currentErrorMessage = ""
        sourceProbe = nil
        let externalRegistration = AetherExternalSubtitleRegistration.make(
            subtitles: request.externalSubtitles,
            sourceURL: request.httpHeaderSourceURL ?? request.videoURL,
            httpHeaders: request.httpHeaders
        )
        #if os(tvOS) || os(iOS)
        var nowPlaying: [String: Any] = [:]
        if let title = request.nowPlayingTitle ?? request.streamName, !title.isEmpty {
            nowPlaying[MPMediaItemPropertyTitle] = title
        }
        if let subtitle = request.nowPlayingTitle != nil ? request.nowPlayingSubtitle : request.streamDescription, !subtitle.isEmpty {
            nowPlaying[MPMediaItemPropertyArtist] = subtitle
        }
        nowPlaying[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        nowPlayingInfo = nowPlaying
        if !nowPlaying.isEmpty {
            engine.setVideoNowPlayingInfo(nowPlaying)
        }
        artworkLoadTask?.cancel()
        if let artworkURL = request.artworkURL {
            artworkLoadTask = Task { [weak self, generation] in
                guard let image = await BackdropImageCache.shared.image(for: artworkURL) else { return }
                guard let self, self.loadGeneration == generation else { return }
                #if os(tvOS) || os(iOS)
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var updated = self.nowPlayingInfo
                updated[MPMediaItemPropertyArtwork] = artwork
                self.nowPlayingInfo = updated
                self.engine.setVideoNowPlayingInfo(updated)
                #endif
            }
        }
        #endif
        externalSubtitleURLsByTrackID = externalRegistration.urlsByTrackID
        currentHTTPHeaders = request.httpHeaders
        currentHTTPHeaderSourceURL = request.httpHeaderSourceURL ?? request.videoURL
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
        activeASSTrackID = nil
        activeASSHeader = nil
        assCoordinator.deactivate()
        subtitleOverlayState.reset()
        subtitleTranslationState.reset()
        videoFrameSize = .zero

        let frameRateMode = ProfileSettings.current.string(forKey: SettingsKey.frameRateMatching) ?? "Always"
        let matchContent = request.matchContentEnabled
            && frameRateMode.caseInsensitiveCompare("Off") != .orderedSame

        // Supported HDR formats do not establish the display's current output mode.
        // Use current EDR headroom as the positive HDR signal for this load.
        let panelInHDR = (view.window?.screen ?? UIScreen.main).currentEDRHeadroom > 1.001
        var panelPresentsDV = false
        if #available(tvOS 11.0, *) {
            panelPresentsDV = AVPlayer.availableHDRModes.contains(.dolbyVision)
        }

        let isLive = request.isLiveStream || request.isSports
        let preferDualLayerDolbyVision = ProfileSettings.current.bool(forKey: SettingsKey.preferDualLayerDolbyVision)
        // Bound find_stream_info probe budget for remote VOD streams (#68).
        // The 50 MiB default reads over the network to completion for sparse attachments (fonts, cover art),
        // adding ~6-8s of startup latency. Bounding to 15 MiB / 10s safely resolves all video/audio tracks
        // while avoiding multi-chunk remote stall. Local SMB and Live IPTV retain the full engine defaults.
        let isRemoteVOD = (isRemote || isLocalPlaybackCache || isUsenetStream) && !isLive
        let probeBudgetBytes: Int64? = isRemoteVOD ? 15 * 1024 * 1024 : nil
        let maxAnalyzeDurationMicroseconds: Int64? = isRemoteVOD ? 10 * 1_000_000 : nil

        let options = LoadOptions(
            httpHeaders: request.httpHeaders,
            discImageHint: PlaybackBackendPolicy.isDiscImage(
                request.videoURL.absoluteString, filename: request.filename),
            preferDualLayerDolbyVision: preferDualLayerDolbyVision,
            matchContentEnabled: matchContent,
            panelIsInHDRMode: panelInHDR,
            panelPresentsDolbyVision: panelPresentsDV,
            audioBridgeMode: .surroundCompat,
            // Read the active profile for each load; unsupported sources keep the normal bridge.
            objectAudioRendering: SpatialAudioSettings.rendering(),
            isLive: isLive,
            liveEdgeCushionSeconds: isLive ? 3.0 : nil,
            liveJoinStartsImmediately: true,
            nativeRemoteHLS: isRemoteHLS,
            // AetherEngine honors this for ASS/SSA codec tracks only; other text
            // subtitle decoders keep their normal styled/plain cue path.
            preserveASSMarkup: true,
            prepareNativeSubtitles: false,
            maxConcurrentSourceRequests: isRemote || isUsenetStream ? 1 : nil,
            heldSourceConnection: isLocalPlaybackCache || isRemote || isUsenetStream,
            probesize: probeBudgetBytes,
            maxAnalyzeDuration: maxAnalyzeDurationMicroseconds,
            preferredAudioLanguages: request.preferredAudioLanguages,
            preferredSubtitleLanguages: request.preferredSubtitleLanguages,
            externalSubtitles: externalRegistration.tracks,
            forwardBufferSegments: request.cacheProfile.aetherForwardBufferSegments(isBackedByHybridDiskCache: isLocalPlaybackCache),
            autoplay: request.autoplay,
            audioDelaySeconds: request.audioDelaySeconds
        )

        let start = request.resumePositionSeconds
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.loadGeneration == gen else { return }
            do {
                let probe: SourceProbe?
                if request.videoURL.scheme == "smb" {
                    let reader = try await Self.makeSMBReader(for: request.videoURL)
                    guard !Task.isCancelled, self.loadGeneration == gen else {
                        reader.close()
                        return
                    }
                    probe = try await self.engine.load(
                        source: .custom(reader, formatHint: nil),
                        startPosition: (start ?? 0) > 0 ? start : nil,
                        options: options
                    )
                } else if let start, start > 0 {
                    guard !Task.isCancelled, self.loadGeneration == gen else { return }
                    probe = try await self.engine.load(
                        url: request.videoURL,
                        startPosition: start,
                        options: options
                    )
                } else {
                    guard !Task.isCancelled, self.loadGeneration == gen else { return }
                    probe = try await self.engine.load(url: request.videoURL, options: options)
                }
                guard !Task.isCancelled, self.loadGeneration == gen else { return }
                self.isAwaitingEngineLoad = false
                self.engineLoadInitialPhase = nil
                self.sourceProbe = probe
                self.isPlayerLoading = false
                self.setSpeed(request.playbackRate)
                #if os(tvOS) || os(iOS)
                self.configureRemoteCommandsIfNeeded()
                #endif
            } catch {
                guard !Task.isCancelled, self.loadGeneration == gen else { return }
                self.isAwaitingEngineLoad = false
                self.engineLoadInitialPhase = nil
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

    private static func makeSMBReader(for url: URL) async throws -> SMBIOReader {
        let parsed = try SMBURL.parse(url.absoluteString)
        guard let server = SMBServerStore.shared.servers.first(where: {
            $0.host.caseInsensitiveCompare(url.host ?? "") == .orderedSame && $0.port == url.port
        }) else {
            throw SMBConnection.SMBError(message: "No configured SMB server for \(url.host ?? "?")")
        }
        let connection = try await SMBConnection.connect(
            server: parsed.server,
            share: parsed.share,
            path: parsed.path,
            auth: SMBSessionManager.shared.authMode(for: server)
        )
        let ext = (parsed.path as NSString).pathExtension.lowercased()
        return SMBIOReader(
            source: connection,
            discImageProbeEnabled: ["iso", "img", "udf"].contains(ext)
        )
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

    func playPlayback() {
        cancelScrubThumbnailWork()
        diagnosticPlayIntent = "play"
        screensaverDebugLog("[ScreensaverDebug][AetherController] playPlayback() called: state=\(engine.state), clock=\(engine.clock.currentTime)")
        if foregroundReloadTask != nil {
            playbackWasPlayingBeforeBackground = true
        }
        engine.play()
    }
    func pausePlayback() {
        diagnosticPlayIntent = "pause"
        screensaverDebugLog("[ScreensaverDebug][AetherController] pausePlayback() called: state=\(engine.state), clock=\(engine.clock.currentTime)")
        engine.pause()
    }

    func seekToMs(_ ms: Int64) {
        screensaverDebugLog("[ScreensaverDebug][AetherController] seekToMs(\(ms)) called: lastKnownPos=\(lastKnownPositionMs)ms, clock=\(engine.clock.currentTime)")
        lastKnownPositionMs = max(0, ms)
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
        currentAspectMode = mode
        switch mode {
        case .fit:
            playerView.transform = .identity
            engine.videoGravity = .resizeAspect
        case .fill:
            playerView.transform = .identity
            engine.videoGravity = .resizeAspectFill
        case .zoom:
            engine.videoGravity = .resizeAspect
            playerView.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
        case .stretch:
            playerView.transform = .identity
            engine.videoGravity = .resize
        }
    }

    func setSubtitleDelay(_ seconds: Double) {
        // Host overlay evaluates cues at sourceTime - delay; use the same clock
        // for prefetching so negative subtitle delays do not miss their cue.
        subtitleDelaySeconds = seconds
        assCoordinator.setSubtitleDelay(seconds)
        if activeASSTrackID == nil {
            subtitleTranslationState.update(
                cues: subtitleCues,
                at: engine.clock.sourceTime - subtitleDelaySeconds
            )
        }
    }

    func setAudioDelay(_ seconds: Double) {
        engine.setAudioDelay(seconds)
    }

    func setAudioVolumeGain(dB: Double) {
        // No public Aether amplification API.
        _ = dB
    }

    func setAudioProcessing(dialogue: EnhanceDialogueMode, reduceLoud: Bool) {
        guard engine.supportsAudioProcessing else { return }
        let mode: AudioDialogueEnhancement
        switch dialogue {
        case .off: mode = .off
        case .enhance: mode = .enhance
        case .boost: mode = .boost
        }
        engine.setAudioProcessing(dialogue: mode, reduceLoudSounds: reduceLoud)
    }

    func selectAudio(_ trackId: Int) {
        engine.selectAudioTrack(index: trackId)
        mapAudioTracks(engine.audioTracks)
    }

    func selectSubtitle(_ trackId: Int) {
        if trackId < 0 {
            engine.clearSubtitle()
        } else {
            engine.selectSubtitleTrack(index: trackId)
        }
        mapSubtitleTracks(engine.subtitleTracks)
    }

    func selectDiscTitle(_ id: Int) {
        engine.selectTitle(id: id)
    }

    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {
        guard let url = URL(string: subtitle.url) else { return }
        let lang = subtitle.language
        let track = ExternalSubtitleTrack(
            url: url,
            name: subtitle.label ?? (lang.isEmpty ? nil : lang),
            language: lang.isEmpty ? nil : lang,
            httpHeaders: AetherExternalSubtitleRegistration.headers(
                for: url,
                matching: currentHTTPHeaderSourceURL,
                from: currentHTTPHeaders
            )
        )
        let info = engine.addExternalSubtitleTrack(track)
        externalSubtitleURLsByTrackID[info.id] = subtitle.url
        if select, engine.activeSubtitleTrackIndex != info.id {
            engine.selectSubtitleTrack(index: info.id)
        }
        mapSubtitleTracks(engine.subtitleTracks)
    }

    func addAudioUrl(_ url: String) {
        // Not supported — dual-URL sessions must use MPV.
        print("[Aether] addAudioUrl ignored (use MPV for separate audio URL): \(url.prefix(80))")
    }

    func applySubtitleStyle() {
        // Host overlay owns styling.
    }

    func destroyPlayer() {
        remoteCommandsAllowed = false
        teardownRemoteCommands()
        cancelScrubThumbnailWork()
        thumbnailSourceContext = nil
        externalProviderGeneration &+= 1
        externalTrickplayProvider = nil
        if let key = contentCanonicalKey {
            let durationSec = Double(durationMs) / 1000.0
            Task.detached(priority: .utility) {
                await TrickplayUploader.shared.uploadIfEligible(canonicalKey: key, duration: durationSec)
            }
        }
        contentCanonicalKey = nil
        resetSoftwareFrameExtractor()
        lifecycleReloadToken &+= 1
        needsForegroundReload = false
        playbackWasPlayingBeforeBackground = false
        foregroundReloadTask?.cancel()
        foregroundReloadTask = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        nowPlayingInfo = [:]
        resetAISubtitleStartupHold()
        isAwaitingEngineLoad = false
        engineLoadInitialPhase = nil
        loadGeneration += 1
        resetHybridThumbnailState(generation: loadGeneration)
        engine.pictureInPictureActive = false
        // Stop audio/video transport immediately without blocking view dismissal for synchronous display criteria handshake
        engine.stop(resetDisplayCriteria: false)
        let retainedEngine = engine
        DispatchQueue.main.async {
            retainedEngine.stop(resetDisplayCriteria: true)
        }
        subtitleCues = []
        activeASSTrackID = nil
        activeASSHeader = nil
        assCoordinator.deactivate()
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
        currentHTTPHeaderSourceURL = nil
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
        if isAwaitingEngineLoad {
            if engine.playbackPhase != engineLoadInitialPhase {
                isAwaitingEngineLoad = false
                engineLoadInitialPhase = nil
            } else {
                isPlayerLoading = true
                isPlayerPlaying = false
                isPlayerEnded = false
                isAtEndOfFile = false
                hasCoherentTimeSample = false
                positionMs = 0
                durationMs = 0
                bufferedMs = 0
                sourceTimeSeconds = 0
                appendDiagnosticStateSampleIfDue()
                return
            }
        }
        refreshClock()
        mapAudioTracks(engine.audioTracks)
        mapSubtitleTracks(engine.subtitleTracks)
        applyPhase(engine.playbackPhase, engineIsBuffering: engine.isBuffering)
        appendDiagnosticStateSampleIfDue()
        #if os(tvOS) || os(iOS)
        configureRemoteCommandsIfNeeded()
        #endif
    }

    private func appendDiagnosticStateSampleIfDue() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastDiagnosticSnapshotUptime >= 5 else { return }
        lastDiagnosticSnapshotUptime = uptime

        let state: String
        if isPlayerLoading {
            state = "loading"
        } else if isPlayerEnded {
            state = "ended"
        } else if isPlayerPlaying {
            state = "playing"
        } else {
            state = "paused"
        }
        let phaseLabel: String
        switch engine.playbackPhase {
        case .idle: phaseLabel = "idle"
        case .loading: phaseLabel = "loading"
        case .playing: phaseLabel = "playing"
        case .paused: phaseLabel = "paused"
        case .seeking: phaseLabel = "seeking"
        case .rebuffering: phaseLabel = "rebuffering"
        case .stalled(let reconnecting): phaseLabel = "stalled(reconnecting=\(reconnecting))"
        case .ended: phaseLabel = "ended"
        case .error: phaseLabel = "error"
        }
        let telemetry = engine.liveTelemetry
        let consumerBytes = telemetry?.networkTransferredBytes.map(String.init) ?? "unknown"
        let demuxerInput = isLocalPlaybackCache
            ? "hybrid-cache-loopback"
            : (isRemoteStream ? "direct-remote-source" : "local-or-custom-source")
        let message = "state=\(state) phase=\(phaseLabel) intent=\(diagnosticPlayIntent) "
            + "positionMs=\(positionMs) bufferedMs=\(bufferedMs) "
            + "demuxerInput=\(demuxerInput) demuxerReadBytes=\(telemetry?.demuxerBytesFetched ?? 0) "
            + "consumerReadBytes=\(consumerBytes) localHLSServerBytesSent=\(telemetry?.serverBytesSentLifetime ?? 0) "
            + "producerRestarts=\(telemetry?.producerRestartCount ?? 0) cacheBytes=\(telemetry?.cachedBytes ?? 0)"
        PlaybackDiagnosticLogStore.shared.append(source: "AetherState", message: message)
    }

    #if os(tvOS) || os(iOS)
    private var didConfigureRemoteCommands = false
    private var remoteCommandsAllowed = true
    private var remoteCommandCenter: MPRemoteCommandCenter?
    private let remoteCommandTargets = PlayerRemoteCommandTargets()
    private var watchPartyRemoteIntent: (@MainActor (PlayerRemoteIntent) -> Bool)?
    private var watchPartyPiPIntent: (@MainActor (PlayerRemoteIntent, @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?
    var isWatchPartyControlled: Bool { watchPartyRemoteIntent != nil }
    var canUseWatchPartySoftwarePiP: Bool {
        isWatchPartyControlled && watchPartyPiPIntent != nil && remoteCommandsAllowed
            && engine.nativePlayerLayer == nil && engine.softwarePiPSource != nil
    }

    func setWatchPartyPiPIntent(_ handler: (@MainActor (PlayerRemoteIntent, @escaping @MainActor () -> Void, @escaping @MainActor () -> Void) -> Void)?) {
        watchPartyPiPIntent = handler
    }

    func performWatchPartyPiPIntent(_ intent: PlayerRemoteIntent, onApplied: @escaping @MainActor () -> Void = {},
                                   completion: @escaping @MainActor () -> Void) {
        guard canUseWatchPartySoftwarePiP, let handler = watchPartyPiPIntent else { completion(); return }
        handler(intent, onApplied, completion)
    }

    func setWatchPartyRemoteIntent(_ handler: (@MainActor (PlayerRemoteIntent) -> Bool)?) {
        let rebind = didConfigureRemoteCommands
        if rebind { teardownRemoteCommands() }
        watchPartyRemoteIntent = handler
        if rebind { configureRemoteCommandsIfNeeded() }
    }

    func stopWatchPartyRemoteCommands() {
        watchPartyPiPIntent = nil
        watchPartyRemoteIntent = { _ in false }
        remoteCommandsAllowed = false
        teardownRemoteCommands()
    }

    private func configureRemoteCommandsIfNeeded() {
        guard remoteCommandsAllowed, let center = engine.videoNowPlayingSession?.remoteCommandCenter else { return }
        if didConfigureRemoteCommands, remoteCommandCenter === center { return }
        teardownRemoteCommands()
        didConfigureRemoteCommands = true
        remoteCommandCenter = center
        installRemoteCommands(center)
    }

    private func installRemoteCommands(_ center: MPRemoteCommandCenter) {
        let action: @MainActor @Sendable (PlayerRemoteIntent) -> Void = { [weak self] intent in
            guard let self else { return }
            if let handler = self.watchPartyRemoteIntent { _ = handler(intent); return }
            if case .toggle = intent {
                switch self.engine.state {
                case .loading, .playing, .paused, .seeking: break
                case .idle, .ended, .error: return
                }
            }
            guard let intent = intent.localIntent(positionMs: self.positionMs, isPlaying: self.isTransportPlaying) else { return }
            switch intent {
            case .play: self.playPlayback()
            case .pause: self.pausePlayback()
            case .seek(let position): self.seekToMs(position)
            default: break
            }
        }
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        remoteCommandTargets.add(center.playCommand, intent: .play, action: action)
        remoteCommandTargets.add(center.pauseCommand, intent: .pause, action: action)
        remoteCommandTargets.add(center.togglePlayPauseCommand, intent: .toggle, action: action)
        remoteCommandTargets.add(center.changePlaybackPositionCommand, resolve: { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return nil }
            return .position(event.positionTime)
        }, action: action)
        remoteCommandTargets.add(center.skipForwardCommand, intent: .skip(10), action: action)
        remoteCommandTargets.add(center.skipBackwardCommand, intent: .skip(-10), action: action)
    }

    private func teardownRemoteCommands() {
        remoteCommandTargets.stop()
        remoteCommandCenter = nil
        didConfigureRemoteCommands = false
    }
    #endif

    /// Snapshot for coordinator handoff.
    func coherentSourceTimeSeconds() -> Double {
        if hasCoherentTimeSample {
            return sourceTimeSeconds
        }
        return lastKnownSourceTimeSeconds
    }
}
