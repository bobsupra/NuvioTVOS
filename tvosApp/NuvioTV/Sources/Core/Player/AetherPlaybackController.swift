import Foundation
import UIKit
import AVFoundation
import Combine
import AetherEngine
import AetherEngineSMB

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
    private var aiSubtitleStartupHoldCueID: Int?
    private var aiSubtitleStartupHoldTimeoutTask: Task<Void, Never>?
    private var didAttemptAISubtitleStartupHold = false
    private let aiSubtitleStartupHoldTimeout: TimeInterval = 6

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
    var isPictureInPictureActive: Bool { engine.pictureInPictureActive }

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
            audio: audio,
            diagnostics: engine.displayDebugLines
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
                self.beginAISubtitleStartupHoldIfNeeded(
                    cues: self.subtitleCues,
                    sourceTime: sourceTime - self.subtitleDelaySeconds
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
                self.beginAISubtitleStartupHoldIfNeeded(
                    cues: cues,
                    sourceTime: self.engine.clock.sourceTime - self.subtitleDelaySeconds
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
        resetAISubtitleStartupHold()
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
        resetAISubtitleStartupHold()
        loadGeneration += 1
        engine.pictureInPictureActive = false
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
