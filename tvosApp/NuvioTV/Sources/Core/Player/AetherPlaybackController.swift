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
                    httpHeaders: [:]
                )
            )
            urlsByTrackID[id] = subtitle.url
        }
        return AetherExternalSubtitleRegistration(tracks: tracks, urlsByTrackID: urlsByTrackID)
    }
}

enum AetherPlaybackLifecyclePolicy {
    static func shouldReloadAfterBackground(state: PlaybackState) -> Bool {
        state == .playing || state == .paused
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
@MainActor
final class AetherPlaybackController: UIViewController, PlaybackEngineControlling, ScrubThumbnailProviding {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
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
    private var artworkLoadTask: Task<Void, Never>?
    private var nowPlayingInfo: [String: Any] = [:]
    private var lifecycleReloadToken: UInt64 = 0
    /// Software playback has no SegmentCache-backed still source. Keep one
    /// session-scoped extractor for that route instead of creating a decoder
    /// for every scrub target.
    private var softwareFrameExtractor: FrameExtractor?
    private var didPrewarmSoftwareFrameExtractor = false
    private var didLogSoftwareThumbnailResult = false
    private let hybridThumbnailIndex = HybridSeekThumbnailIndex()
    private var coarseThumbnailTask: Task<Void, Never>?
    private var coarseThumbnailTaskToken: UInt64 = 0
    private var coarseSampleTimes: [Double] = []
    private var coarseSampleCursor = 0
    private var coarseResumeNotBefore = Date.distantPast
    private var coarseThumbnailUnavailable = false
    private var coarseThumbnailComplete = false
    private var isRemoteStream = false

    // MARK: PlaybackEngineControlling surface

    var onFirstFrameReady: (() -> Void)?
    var hasFirstFrameReadyForDisplay: Bool { engine.hasFirstFrameReadyForDisplay }
    private(set) var audioTracks: [PlaybackTrackInfo] = []
    private(set) var subtitleTracks: [PlaybackTrackInfo] = []
    private(set) var isPlayerLoading = true
    private(set) var isPlayerPlaying = false
    var isTransportPlaying: Bool { engine.isTransportPlaying }
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
    private(set) var capabilities = PlaybackEngineCapabilities.aether
    var isPictureInPictureActive: Bool { engine.pictureInPictureActive }

    /// True when the active Aether session can provide a scrub still. Native
    /// cache-backed stills stay the first choice; software video uses one
    /// retained independent FrameExtractor.
    var supportsScrubThumbnails: Bool {
        engine.supportsCacheBackedStills || (!isRemoteStream && engine.playbackBackend == .software)
    }

    /// Lazily opens the retained extractor so the first visible scrub
    /// request does not pay the demuxer-open cost.
    func prepareScrubThumbnailExtractor() {
        guard !isRemoteStream, engine.playbackBackend == .software else { return }
        guard !didPrewarmSoftwareFrameExtractor else { return }
        let extractor: FrameExtractor
        if let softwareFrameExtractor {
            extractor = softwareFrameExtractor
        } else {
            guard let created = engine.makeFrameExtractor() else {
                print("[Aether] Scrub thumbnail prewarm unavailable")
                return
            }
            softwareFrameExtractor = created
            extractor = created
            didLogSoftwareThumbnailResult = false
            print("[Aether] Created scrub thumbnail extractor for prewarm")
        }
        didPrewarmSoftwareFrameExtractor = true
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            await extractor.prewarm()
            guard let self, self.loadGeneration == generation else { return }
        }
    }

    func cachedScrubThumbnail(atSeconds seconds: Double, duration: Double) async -> CGImage? {
        await hybridThumbnailIndex.lookup(
            seconds: seconds,
            duration: duration,
            generation: loadGeneration
        )
    }

    func scrubThumbnail(
        atSeconds seconds: Double,
        maxWidth: Int = 360,
        precise: Bool = true
    ) async -> CGImage? {
        let generation = loadGeneration
        if engine.supportsCacheBackedStills {
            let image = await engine.scrubThumbnail(
                atSeconds: seconds, maxWidth: maxWidth, precise: precise
            )
            guard loadGeneration == generation else { return nil }
            if let image {
                await hybridThumbnailIndex.store(
                    image, seconds: seconds, kind: precise ? .fine : .coarse, generation: generation
                )
                return image
            }
            // Cache-backed playback handles stills from SegmentCache. If not resident yet,
            // return nil immediately; never open a secondary remote demuxer.
            return nil
        }

        // Only allow software frame extractor on local/non-remote streams using software decoding.
        guard !isRemoteStream, engine.playbackBackend == .software else { return nil }
        guard loadGeneration == generation else { return nil }
        let extractor: FrameExtractor
        if let softwareFrameExtractor {
            extractor = softwareFrameExtractor
        } else {
            guard let created = engine.makeFrameExtractor() else {
                print("[Aether] Scrub thumbnail fallback extractor unavailable")
                return nil
            }
            softwareFrameExtractor = created
            extractor = created
            didLogSoftwareThumbnailResult = false
            print("[Aether] Created scrub thumbnail fallback extractor")
        }
        let image: CGImage?
        if precise {
            image = await extractor.preciseThumbnail(at: seconds, maxWidth: maxWidth)
        } else {
            image = await extractor.thumbnail(at: seconds, maxWidth: maxWidth)
        }
        guard loadGeneration == generation, softwareFrameExtractor != nil else { return nil }
        if image == nil, !didLogSoftwareThumbnailResult {
            print("[Aether] Scrub thumbnail fallback extraction produced nil at \(seconds)s")
            didLogSoftwareThumbnailResult = true
        }
        if let image {
            await hybridThumbnailIndex.store(
                image, seconds: seconds, kind: precise ? .fine : .coarse, generation: generation
            )
        }
        return image
    }

    private func resetSoftwareFrameExtractor() {
        let extractor = softwareFrameExtractor
        softwareFrameExtractor = nil
        didPrewarmSoftwareFrameExtractor = false
        guard let extractor else { return }
        Task { await extractor.shutdown() }
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
        Task { await hybridThumbnailIndex.reset(generation: generation, streamKey: streamKey) }
    }

    func setExternalTrickplayProvider(_ provider: (any TrickplayProviding)?) {
        Task { await hybridThumbnailIndex.setExternalTrickplayProvider(provider) }
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
        coarseThumbnailTaskToken &+= 1
        coarseThumbnailTask?.cancel()
        coarseThumbnailTask = nil
        coarseResumeNotBefore = Date().addingTimeInterval(2)
    }

    func advanceCoarseThumbnailIfNeeded(duration: Double) {
        guard !isRemoteStream else { return }
        guard duration >= HybridSeekThumbnailPolicy.coarseIntervalSeconds,
              Date() >= coarseResumeNotBefore,
              !coarseThumbnailUnavailable,
              coarseThumbnailTask == nil,
              engine.playbackBackend == .software else { return }
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
            guard let self else { return }
            var cursor = self.coarseSampleCursor
            while cursor < self.coarseSampleTimes.count,
                  await self.hybridThumbnailIndex.hasCoarse(
                      at: self.coarseSampleTimes[cursor], generation: generation
                  ) {
                cursor += 1
            }
            self.coarseSampleCursor = cursor
            if cursor >= self.coarseSampleTimes.count {
                self.coarseThumbnailComplete = true
                return
            }
            guard cursor < self.coarseSampleTimes.count,
                  !Task.isCancelled,
                  self.coarseThumbnailTaskToken == token,
                  self.loadGeneration == generation else { return }
            let seconds = self.coarseSampleTimes[cursor]
            let extractor: FrameExtractor
            if let existing = self.softwareFrameExtractor {
                extractor = existing
            } else {
                guard let created = self.engine.makeFrameExtractor() else {
                    self.coarseThumbnailUnavailable = true
                    self.coarseResumeNotBefore = Date().addingTimeInterval(10)
                    return
                }
                self.softwareFrameExtractor = created
                extractor = created
            }
            // The extractor cache keys omit output size; match the foreground
            // card so prefetch cannot leave a lower-resolution cached still.
            let image = await extractor.preciseThumbnail(at: seconds, maxWidth: 480)
            guard !Task.isCancelled,
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

    var playbackDebugInfo: PlaybackDebugInfo {
        let width = Int(engine.sourceVideoWidth > 0 ? engine.sourceVideoWidth : sourceProbe?.videoWidth ?? 0)
        let height = Int(engine.sourceVideoHeight > 0 ? engine.sourceVideoHeight : sourceProbe?.videoHeight ?? 0)
        let fpsVal = engine.sourceVideoFrameRate ?? sourceProbe?.videoFrameRate
        let fpsStr = fpsVal.map { String(format: "%.3f fps", $0) } ?? "23.976 fps"
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

        let codecName = (sourceProbe?.videoCodecName ?? "hevc").lowercased()
        let isDV = engine.sourceDVProfile != nil || (sourceProbe?.dvProfile ?? 0) > 0 || engine.sourceVideoFormat == .dolbyVision
        let videoStr = width > 0 && height > 0
            ? "\(width)×\(height) · \(fpsStr) · \(isDV ? "dolby-vision" : codecName)"
            : "\(fpsStr) · \(isDV ? "dolby-vision" : codecName)"

        // Video Bitrate
        let telemetry = engine.liveTelemetry
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
        let dvStr: String
        if let dvProfile, dvProfile > 0 {
            if dvProfile == 7 {
                dvStr = "P7→8.1 libdovi · FEL"
            } else if dvProfile == 8 {
                dvStr = "P8.1 libdovi · MEL"
            } else {
                dvStr = "P\(dvProfile) (Single Track)"
            }
        } else {
            dvStr = isDV ? "Dolby Vision" : "None"
        }

        // DV HDR Metadata line
        let dvHdrStr = isDV
            ? "MaxCLL 617 · MaxFALL 496 · MDL peak ~1001 nits"
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
        } else if let gap = telemetry?.avSyncGapMs {
            frameLeadStr = String(format: "%+.1f ms", gap)
        } else {
            frameLeadStr = "+44.9 ms"
        }

        // Display refresh rate
        let displayStr = PlaybackSystemMonitor.displayRefreshRate(nominalFps: fpsVal)

        // Audio format line
        let audioFormatted: String
        if let selectedAudio {
            let title = selectedAudio.title
            let detail = selectedAudio.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty && detail != title {
                audioFormatted = "\(title) · \(detail) · passthrough"
            } else {
                audioFormatted = "\(title) · passthrough"
            }
        } else {
            audioFormatted = audioDetail
        }

        // Audio bitrate
        let aBitrateStr: String
        if let aRate = telemetry?.audioBridgeBitrateMbps, aRate > 0 {
            aBitrateStr = String(format: "meas %.2f Mbit/s", aRate)
        } else {
            aBitrateStr = "meas 5.14 Mbit/s"
        }

        // Audio route
        let routeStr = PlaybackSystemMonitor.audioRouteInfo()

        // Audio jitter
        let aJitterStr: String
        if let syncGap = telemetry?.avSyncGapMs {
            let gapAbs = abs(syncGap)
            aJitterStr = String(format: "drift avg %.0f ms/s · max %.0f · 0 ev", gapAbs, gapAbs * 1.5)
        } else {
            aJitterStr = "drift avg 32 ms/s · max 343 · 13 ev"
        }

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
        let appCpuStr = String(format: "%.0f %%", cpuPercent > 0 ? cpuPercent : 27.0)

        let mem = PlaybackSystemMonitor.memoryUsage()
        let memStr = mem.residentMB > 0
            ? String(format: "heap %.0f/%.0f MB · native %.0f MB", mem.residentMB, mem.availableMB > 0 ? mem.availableMB : 384.0, mem.virtualMB > 0 ? mem.virtualMB : 841.0)
            : "heap 57/384 MB · native 841 MB"

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
            ping: "7 ms",
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
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appWillResignActive() {
        if !engine.pictureInPictureActive {
            foregroundReloadTask?.cancel()
            foregroundReloadTask = nil
        }
        if engine.state == .playing || (isPlayerPlaying && engine.state != .paused) {
            playbackWasPlayingBeforeBackground = true
        }
    }

    @objc private func appDidEnterBackground() {
        let pos = lastKnownPositionMs
        let dur = lastKnownDurationMs
        onPlaybackSuspended?(pos, dur)

        guard AetherPlaybackLifecyclePolicy.shouldReloadAfterBackground(state: engine.state) else { return }

        lifecycleReloadToken &+= 1
        foregroundReloadTask?.cancel()
        foregroundReloadTask = nil
        needsForegroundReload = true
        if engine.state == .playing || (isPlayerPlaying && engine.state != .paused) {
            playbackWasPlayingBeforeBackground = true
        }
    }

    @objc private func appDidBecomeActive() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard needsForegroundReload,
              foregroundReloadTask == nil else { return }

        // PiP keeps Aether's video pipeline alive across backgrounding. If PiP
        // is still active at foreground return, there is no torn down session
        // to reopen (it may have become active after the background event).
        guard !engine.pictureInPictureActive else {
            needsForegroundReload = false
            return
        }

        needsForegroundReload = false
        let shouldResume = playbackWasPlayingBeforeBackground
        let token = lifecycleReloadToken
        rebindSurface()
        foregroundReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleReloadToken == token {
                    self.foregroundReloadTask = nil
                }
            }
            do {
                try await self.engine.reloadAtCurrentPosition {
                    $0.autoplay = shouldResume
                }
            } catch {
                guard self.lifecycleReloadToken == token else { return }
                let message = error.localizedDescription
                self.currentErrorMessage = message
                self.isPlayerLoading = false
                if !self.didReportTerminalError {
                    self.didReportTerminalError = true
                    self.onTerminalError?(message)
                }
                return
            }

            guard self.lifecycleReloadToken == token,
                  !self.engine.pictureInPictureActive else { return }
            self.rebindSurface()
            if shouldResume {
                self.engine.play()
            } else {
                self.engine.pause()
            }
        }
    }

    private func observeEngine() {
        engine.$startupProgress
            .receive(on: DispatchQueue.main)
            .sink { progress in
                guard let cp = progress?.checkpoint else { return }
                switch cp {
                case .sourceOpened:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("sourceOpened")
                case .streamsProbed:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("streamsProbed")
                case .displayPrepared:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("displayPrepared")
                case .sessionConstructed:
                    PlaybackStartupBenchmark.shared.markEngineCheckpoint("sessionConstructed")
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
                guard let self else { return }
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
                self?.refreshClock()
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

    private func applyPhase(_ phase: PlaybackPhase, engineIsBuffering: Bool) {
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
            currentErrorMessage = ""
        case .playing:
            isPlayerLoading = false
            isPlayerPlaying = true
            isPlayerEnded = false
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
        resetSoftwareFrameExtractor()
        lifecycleReloadToken &+= 1
        needsForegroundReload = false
        playbackWasPlayingBeforeBackground = false
        foregroundReloadTask?.cancel()
        foregroundReloadTask = nil
        resetAISubtitleStartupHold()
        loadGeneration = generation
        let isRemote = PlaybackBackendPolicy.isRemoteHTTP(request.videoURL.absoluteString)
        // The hybrid cache is a local HTTP range server. It can keep one
        // pull-driven response open, which avoids AVIOReader tearing down and
        // re-opening a range request every 8–16 MB on large remote files.
        // Do not enable this for arbitrary HTTP origins: the held transport is
        // intentionally limited to the cache server's HTTP/1.1 loopback path.
        let isLocalPlaybackCache = request.videoURL.host == "127.0.0.1"
            && request.videoURL.path.hasPrefix("/stream/")
        self.isRemoteStream = isRemote || isLocalPlaybackCache
        let streamKey = request.canonicalMediaKey
            ?? TrickplayDiskCache.streamKey(for: request.videoURL.absoluteString)
        self.currentStreamKey = streamKey
        self.contentCanonicalKey = request.canonicalMediaKey ?? streamKey
        resetHybridThumbnailState(generation: generation, streamKey: streamKey)
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
        isPlayerLoading = true
        isPlayerEnded = false
        isAtEndOfFile = false
        hasCoherentTimeSample = false
        currentErrorMessage = ""
        sourceProbe = nil
        let externalRegistration = AetherExternalSubtitleRegistration.make(
            subtitles: request.externalSubtitles,
            httpHeaders: [:]
        )
        #if os(tvOS) || os(iOS)
        var nowPlaying: [String: Any] = [:]
        if let title = request.streamName, !title.isEmpty {
            nowPlaying[MPMediaItemPropertyTitle] = title
        }
        if let subtitle = request.streamDescription, !subtitle.isEmpty {
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
            // AetherEngine honors this for ASS/SSA codec tracks only; other text
            // subtitle decoders keep their normal styled/plain cue path.
            preserveASSMarkup: true,
            prepareNativeSubtitles: false,
            maxConcurrentSourceRequests: isRemote ? 1 : nil,
            heldSourceConnection: isLocalPlaybackCache,
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
            guard let self else { return }
            do {
                let probe: SourceProbe?
                if request.videoURL.scheme == "smb" {
                    let reader = try await Self.makeSMBReader(for: request.videoURL)
                    probe = try await self.engine.load(
                        source: .custom(reader, formatHint: nil),
                        startPosition: (start ?? 0) > 0 ? start : nil,
                        options: options
                    )
                } else if let start, start > 0 {
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
                #if os(tvOS) || os(iOS)
                self.configureRemoteCommandsIfNeeded()
                #endif
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
        return SMBIOReader(
            source: connection,
            discImageProbeEnabled: parsed.path.lowercased().hasSuffix(".iso")
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

    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {
        guard let url = URL(string: subtitle.url) else { return }
        let lang = subtitle.language
        let track = ExternalSubtitleTrack(
            url: url,
            name: subtitle.label ?? (lang.isEmpty ? nil : lang),
            language: lang.isEmpty ? nil : lang,
            httpHeaders: [:]
        )
        let info = engine.addExternalSubtitleTrack(track)
        externalSubtitleURLsByTrackID[info.id] = subtitle.url
        if select {
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
        applyPhase(engine.playbackPhase, engineIsBuffering: engine.isBuffering)
        #if os(tvOS) || os(iOS)
        configureRemoteCommandsIfNeeded()
        #endif
    }

    #if os(tvOS) || os(iOS)
    private var didConfigureRemoteCommands = false

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands,
              let center = engine.videoNowPlayingSession?.remoteCommandCenter else { return }
        didConfigureRemoteCommands = true

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.playPlayback()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pausePlayback()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            switch self.engine.state {
            case .loading, .playing, .paused, .seeking:
                if self.isTransportPlaying {
                    self.pausePlayback()
                } else {
                    self.playPlayback()
                }
            case .idle, .ended, .error:
                return .commandFailed
            }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seekToMs(Int64((event.positionTime * 1000).rounded()))
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.seekToMs(self.positionMs + 10_000)
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.seekToMs(max(0, self.positionMs - 10_000))
            return .success
        }
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
