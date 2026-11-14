import Foundation
import CoreGraphics
import Combine
import AetherEngine

private enum SceneMusicRecognitionPolicy {
    static let automaticShazamRecognitionEnabled = false
}

@MainActor
final class SceneCoordinator: ObservableObject {
    @Published private(set) var currentSnapshot: SceneSnapshot = .empty
    @Published private(set) var castCandidates: [SceneCastCandidate] = []
    @Published private(set) var isPanelOpen: Bool = false
    var isFrameSamplingActive: Bool { samplingTask != nil }
    
    private let frameProvider: any SceneFrameProviding
    private let castProvider: any SceneCastProviding
    private let soundtrackProvider: any SceneSoundtrackProviding
    private let actorRecognition: ActorRecognitionService
    private let musicRecognition: MusicRecognitionService
    private let audioTapBroker: PlaybackAudioTapBroker?
    private let resultCache: SceneResultCache
    private let subtitleScraper: SceneSubtitleTimelineScraper
    
    private var underlyingMusicStatus: SceneMusicStatus = .disabled
    private var context: SceneContext?
    private var availableSubtitles: [NuvioSubtitle] = []
    private var samplingTask: Task<Void, Never>?
    private var audioSubscriptionId: UUID?
    private var activeAnalysisID: UUID?
    private var analysisTask: Task<Void, Never>?
    private var isAnalyzingFrame: Bool { activeAnalysisID != nil }
    private var isFetchingCast: Bool = false
    private var isFetchingSoundtrack: Bool = false
    private var pendingPausedFrameGeneration: UInt64?
    private var needsFrameAnalysisAfterCastLoad: Bool = false
    private var lastAnalyzedFrameSourceTime: Double?
    private var currentGeneration: UInt64 = 0
    private var isPlayingProvider: () -> Bool = { false }
    private var sourceTimeProvider: () -> Double = { 0 }
    private var activeSubtitleTextProvider: () -> String? = { nil }
    
    init(
        frameProvider: any SceneFrameProviding,
        castProvider: any SceneCastProviding = TmdbSceneCastProvider(),
        soundtrackProvider: any SceneSoundtrackProviding = CommunitySceneSoundtrackProvider(),
        actorRecognition: ActorRecognitionService = ActorRecognitionService(),
        musicRecognition: MusicRecognitionService = MusicRecognitionService(),
        audioTapBroker: PlaybackAudioTapBroker? = nil,
        resultCache: SceneResultCache = SceneResultCache(),
        subtitleScraper: SceneSubtitleTimelineScraper = SceneSubtitleTimelineScraper()
    ) {
        self.frameProvider = frameProvider
        self.castProvider = castProvider
        self.soundtrackProvider = soundtrackProvider
        self.actorRecognition = actorRecognition
        self.musicRecognition = musicRecognition
        self.audioTapBroker = audioTapBroker
        self.resultCache = resultCache
        self.subtitleScraper = subtitleScraper
        
        setupMusicCallbacks()
    }
    
    private func setupMusicCallbacks() {
        Task { [weak self] in
            await self?.musicRecognition.setStatusCallback { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.underlyingMusicStatus = status
                    self.updateMusicStatus(status)
                }
            }
        }
    }
    
    func setPlaybackProviders(
        isPlaying: @escaping () -> Bool,
        sourceTime: @escaping () -> Double,
        activeSubtitleText: @escaping () -> String? = { nil }
    ) {
        self.isPlayingProvider = isPlaying
        self.sourceTimeProvider = sourceTime
        self.activeSubtitleTextProvider = activeSubtitleText
    }
    
    var isAnime: Bool { context?.isAnime == true }
    
    private func candidateActors(from candidates: [SceneCastCandidate]) -> [SceneRecognizedActor] {
        candidates.map { candidate in
            SceneRecognizedActor(
                id: candidate.id,
                name: candidate.name,
                character: candidate.character,
                profileURL: candidate.profileURL,
                confidence: 1.0,
                tmdbId: candidate.tmdbId
            )
        }
    }
    
    private func isSameMediaContext(_ a: SceneContext?, _ b: SceneContext?) -> Bool {
        guard let a, let b else { return false }
        return a.canonicalId == b.canonicalId &&
            a.timelineGeneration == b.timelineGeneration &&
            a.season == b.season &&
            a.episode == b.episode &&
            a.isAnime == b.isAnime
    }

    func updateContext(_ context: SceneContext) {
        if let current = self.context, !isSameMediaContext(current, context) {
            resetSession()
        }
        self.context = context
    }
    
    /// Proactively warms TMDB cast candidates, soundtrack metadata, and face embeddings in the background
    /// so that the first frame matches with zero latency when InSight is opened.
    func prewarm(context: SceneContext) {
        updateContext(context)
        fetchCastIfNeeded()
        fetchSoundtrackIfNeeded()
    }

    func updateAvailableSubtitles(_ subtitles: [NuvioSubtitle]) {
        self.availableSubtitles = subtitles
        triggerSubtitleTimelineScrapingIfNeeded()
    }

    private func triggerSubtitleTimelineScrapingIfNeeded() {
        guard let context, !castCandidates.isEmpty, !availableSubtitles.isEmpty else { return }
        let subs = availableSubtitles
        let candidates = castCandidates
        Task { [weak self, subs, candidates, context] in
            guard let self else { return }
            await self.subtitleScraper.scrapeNamedSubtitleTimeline(
                subtitles: subs,
                candidates: candidates,
                context: context,
                resultCache: self.resultCache
            )
            await MainActor.run {
                guard self.isPanelOpen, self.isSameMediaContext(self.context, context) else { return }
                self.evaluateActiveSong(at: self.sourceTimeProvider())
            }
        }
    }
    
    // MARK: - Panel Open / Close Lifecycle
    
    func openPanel() {
        guard !isPanelOpen else { return }
        isPanelOpen = true
        currentGeneration &+= 1
        
        if isAnime, !castCandidates.isEmpty {
            updateActorStatus(.recognized(candidateActors(from: castCandidates)))
        } else {
            updateActorStatus(.analyzing)
        }
        
        let gen = currentGeneration
        let isPlaying = isPlayingProvider()
        let currentTime = sourceTimeProvider()
        
        // 1. Warm / Fetch cast references & soundtrack metadata
        fetchCastIfNeeded()
        fetchSoundtrackIfNeeded()
        
        // 2. Evaluate currently active song at this timestamp
        evaluateActiveSong(at: currentTime)
        
        // 3. Start music recognition in parallel
        startMusicRecognition(isPlaying: isPlaying, sourceTime: currentTime)
        
        // 4. Start frame sampling loop (every 1.5 seconds)
        startFrameSampling(generation: gen)
    }
    
    func closePanel() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        currentGeneration &+= 1
        analysisTask?.cancel()
        pendingPausedFrameGeneration = nil
        needsFrameAnalysisAfterCastLoad = false
        lastAnalyzedFrameSourceTime = nil
        stopSampling()
        stopMusicRecognition()
        let cancellationCutoff = Date()
        Task { await actorRecognition.cancelReferencePreparation(startedBefore: cancellationCutoff) }
    }
    
    func handleSeek() {
        currentGeneration &+= 1
        let generation = currentGeneration
        stopSampling()
        analysisTask?.cancel()
        pendingPausedFrameGeneration = nil
        needsFrameAnalysisAfterCastLoad = false
        lastAnalyzedFrameSourceTime = nil
        let currentTime = sourceTimeProvider()
        
        let initialActors: [SceneRecognizedActor]
        let initialActorStatus: SceneActorStatus
        if isAnime, !castCandidates.isEmpty {
            let animeActors = candidateActors(from: castCandidates)
            initialActors = animeActors
            initialActorStatus = .recognized(animeActors)
        } else {
            initialActors = []
            initialActorStatus = .analyzing
        }
        
        currentSnapshot = SceneSnapshot(
            timestamp: currentTime,
            actors: initialActors,
            song: nil,
            actorStatus: initialActorStatus,
            musicStatus: isPlayingProvider() ? .listening : .requiresPlayback,
            generation: currentGeneration
        )
        evaluateActiveSong(at: currentTime)
        Task { [weak self] in
            guard let self else { return }
            await self.actorRecognition.resetTemporalTracking()
            await self.musicRecognition.reportSeek()
            guard self.isPanelOpen, self.currentGeneration == generation else { return }
            self.startFrameSampling(generation: generation)
        }
    }
    
    func handlePlaybackPaused(captureFrame: Bool = true) {
        stopSampling()
        Task {
            await musicRecognition.reportPlaybackPaused()
        }
        guard isPanelOpen else { return }
        evaluateActiveSong(at: sourceTimeProvider())
        if captureFrame, !isAnime {
            captureAndAnalyzeCurrentFrame(forGeneration: currentGeneration)
        }
    }

    func handleSubtitleTextChange(_ text: String) {
        guard isPanelOpen, !isAnime, !text.isEmpty, !castCandidates.isEmpty else { return }
        let time = sourceTimeProvider()
        let candidates = self.castCandidates
        let gen = self.currentGeneration
        
        Task { [weak self, text, candidates, time, gen] in
            guard let self else { return }
            let detectedActors = await self.actorRecognition.processSubtitleDialogue(
                text: text,
                candidates: candidates,
                sourceTime: time
            )
            guard !detectedActors.isEmpty else { return }
            let allActive = await self.actorRecognition.currentTrackedActors(at: time)
            await MainActor.run {
                guard self.isPanelOpen, self.currentGeneration == gen else { return }
                self.updateActorStatus(.recognized(allActive))
            }
        }
    }

    func handlePlaybackResumed() {
        pendingPausedFrameGeneration = nil
        let isPlaying = isPlayingProvider()
        let currentTime = sourceTimeProvider()
        evaluateActiveSong(at: currentTime)
        startMusicRecognition(isPlaying: isPlaying, sourceTime: currentTime)
        if isPanelOpen, samplingTask == nil {
            startFrameSampling(generation: currentGeneration)
        }
    }
    
    func resetSession() {
        currentGeneration &+= 1
        isPanelOpen = false
        analysisTask?.cancel()
        pendingPausedFrameGeneration = nil
        needsFrameAnalysisAfterCastLoad = false
        isFetchingCast = false
        isFetchingSoundtrack = false
        stopSampling()
        stopMusicRecognition()
        castCandidates.removeAll()
        availableSubtitles.removeAll()
        lastAnalyzedFrameSourceTime = nil
        underlyingMusicStatus = .disabled
        currentSnapshot = .empty
        let cancellationCutoff = Date()
        Task {
            await actorRecognition.cancelReferencePreparation(startedBefore: cancellationCutoff)
            await actorRecognition.resetTemporalTracking()
            await musicRecognition.reset()
            await subtitleScraper.reset()
        }
    }
    
    // MARK: - Cast Preparation
    
    private func fetchCastIfNeeded() {
        guard let context, castCandidates.isEmpty, !isFetchingCast else { return }
        isFetchingCast = true
        print("[Scene] fetchCastIfNeeded() started for \"\(context.title)\" (canonicalId: \(context.canonicalId), tmdbId: \(String(describing: context.tmdbId)), isAnime: \(context.isAnime))")
        
        Task { [weak self, context] in
            let candidates: [SceneCastCandidate]
            do {
                candidates = try await self?.castProvider.fetchCast(context: context) ?? []
            } catch {
                print("[Scene] ⚠️ fetchCast failed or threw an error for \"\(context.title)\": \(error.localizedDescription)")
                candidates = []
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingCast = false
                guard self.isSameMediaContext(self.context, context) else { return }
                self.castCandidates = candidates
                print("[Scene] Updated castCandidates (\(candidates.count) candidates)")
                self.triggerSubtitleTimelineScrapingIfNeeded()
                
                if context.isAnime {
                    let animeActors = self.candidateActors(from: candidates)
                    if self.isPanelOpen {
                        self.updateActorStatus(animeActors.isEmpty
                            ? .unavailable(reason: "No cast candidates available for this episode")
                            : .recognized(animeActors))
                    }
                } else {
                    if self.isPanelOpen, self.currentSnapshot.actors.isEmpty {
                        self.updateActorStatus(candidates.isEmpty
                            ? .unavailable(reason: "No cast candidates available for this title")
                            : .preparingReferences)
                    }
                    Task {
                        await self.actorRecognition.preloadReferences(candidates: candidates)
                    }
                    if self.isPanelOpen, !candidates.isEmpty {
                        if self.isAnalyzingFrame {
                            self.needsFrameAnalysisAfterCastLoad = true
                        } else {
                            self.captureAndAnalyzeCurrentFrame()
                        }
                    }
                }
            }
        }
    }
    
    private func fetchSoundtrackIfNeeded() {
        guard let context, !isFetchingSoundtrack else { return }
        isFetchingSoundtrack = true
        print("[Scene] fetchSoundtrackIfNeeded() started for \"\(context.title)\" (canonicalId: \(context.canonicalId))")
        
        Task { [weak self, context] in
            let intervals: [SceneTimelineInterval]
            do {
                intervals = try await self?.soundtrackProvider.fetchSoundtrack(context: context) ?? []
            } catch {
                print("[Scene] ⚠️ fetchSoundtrack failed or threw an error for \"\(context.title)\": \(error.localizedDescription)")
                intervals = []
            }
            guard let self else { return }
            if !intervals.isEmpty {
                await self.resultCache.storeTimelineIntervals(intervals)
                print("[Scene] Stored \(intervals.count) soundtrack intervals for \"\(context.title)\"")
            }
            await MainActor.run {
                self.isFetchingSoundtrack = false
                guard self.isPanelOpen, self.isSameMediaContext(self.context, context) else { return }
                self.evaluateActiveSong(at: self.sourceTimeProvider())
            }
        }
    }

    /// Checks if a song interval matches the current playback timestamp.
    /// Songs will automatically appear when their playback window starts and disappear when it finishes.
    func evaluateActiveSong(at sourceTime: Double) {
        guard let context, isPanelOpen else { return }
        let gen = currentGeneration
        Task { [weak self, context, sourceTime, gen] in
            guard let self else { return }
            var activeSong = await self.resultCache.findTimelineSong(for: context, sourceTime: sourceTime)
            if let song = activeSong, song.artworkURL == nil {
                activeSong = await SceneSongMetadataEnricher.shared.enrich(song: song)
                if let enriched = activeSong {
                    await self.resultCache.storeTimelineInterval(SceneTimelineInterval(
                        id: "enriched-\(enriched.id)",
                        canonicalId: context.canonicalId,
                        season: context.season,
                        episode: context.episode,
                        startTime: enriched.startTime ?? sourceTime,
                        endTime: enriched.endTime ?? (sourceTime + 60.0),
                        actors: [],
                        song: enriched,
                        sceneDescription: enriched.sceneDescription
                    ))
                }
            }
            await MainActor.run {
                guard self.isPanelOpen, self.currentGeneration == gen else { return }
                if let activeSong {
                    if self.currentSnapshot.song?.id != activeSong.id || (self.currentSnapshot.song?.artworkURL == nil && activeSong.artworkURL != nil) {
                        print("[Scene] 🎵 Song active at \(String(format: "%.1f", sourceTime))s: \"\(activeSong.title)\" by \(activeSong.artist) (art: \(activeSong.artworkURL != nil))")
                        self.updateMusicStatus(.matched(activeSong))
                    }
                } else {
                    // If a song is currently shown but its time window has ended, make it disappear!
                    if let currentSong = self.currentSnapshot.song {
                        if !currentSong.isActive(at: sourceTime) {
                            print("[Scene] ⏹️ Song finished at \(String(format: "%.1f", sourceTime))s: \"\(currentSong.title)\"")
                            let isPlaying = self.isPlayingProvider()
                            let fallbackStatus: SceneMusicStatus
                            switch self.underlyingMusicStatus {
                            case .unavailable, .failed:
                                fallbackStatus = self.underlyingMusicStatus
                            default:
                                fallbackStatus = isPlaying ? .listening : .requiresPlayback
                            }
                            self.updateMusicStatus(fallbackStatus)
                        }
                    }
                }
            }
        }
    }
    
    func fetchPersonDetail(personId: Int) async -> ScenePersonDetail? {
        await castProvider.fetchPersonDetail(personId: personId)
    }
    
    func fetchPersonBiography(personId: Int) async -> String? {
        await castProvider.fetchPersonBiography(personId: personId)
    }
    
    // MARK: - Frame Sampling Loop
    
    private func startFrameSampling(generation: UInt64) {
        samplingTask?.cancel()
        samplingTask = nil
        
        // Initial immediate sample & song check
        evaluateActiveSong(at: sourceTimeProvider())
        let isPlaying = isPlayingProvider()
        if !isAnime {
            if isAnalyzingFrame, !isPlaying {
                pendingPausedFrameGeneration = generation
            } else {
                captureAndAnalyzeCurrentFrame(forGeneration: generation)
            }
        }
        // A paused open/seek needs a settled one-shot frame, never a polling task.
        guard isPlaying else { return }
        
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds cadence
                guard !Task.isCancelled else { break }
                
                await MainActor.run {
                    guard let self, self.isPanelOpen, self.currentGeneration == generation else { return }
                    self.evaluateActiveSong(at: self.sourceTimeProvider())
                    if self.isPlayingProvider(), !self.isAnime {
                        self.captureAndAnalyzeCurrentFrame()
                    }
                }
            }
        }
    }
    
    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }
    
    private func captureAndAnalyzeCurrentFrame(forGeneration requestedGeneration: UInt64? = nil) {
        let gen = requestedGeneration ?? currentGeneration
        guard isPanelOpen, currentGeneration == gen else { return }
        guard !isAnalyzingFrame else {
            if !isPlayingProvider() {
                pendingPausedFrameGeneration = gen
            }
            return
        }
        guard let context else { return }

        let requestedTime = sourceTimeProvider()
        let isPaused = !isPlayingProvider()
        let providerWasSupported = frameProvider.isSupported
        let analysisID = UUID()
        activeAnalysisID = analysisID
        let candidates = self.castCandidates
        let currentSubtitle = activeSubtitleTextProvider()
        let frameProvider = self.frameProvider
        let actorRecognition = self.actorRecognition
        let resultCache = self.resultCache
        let sourceTime = self.sourceTimeProvider

        // Capture shares the same single-flight owner as recognition. This prevents concurrent
        // AVPlayerItemVideoOutput probes while the native provider is waiting for a displayed frame.
        analysisTask = Task { @MainActor [weak self, context, requestedTime, gen, isPaused, analysisID, candidates, currentSubtitle, providerWasSupported, frameProvider, actorRecognition, resultCache, sourceTime] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishFrameAnalysis(id: analysisID)
                }
            }
            guard self?.frameAnalysisIsCurrent(
                id: analysisID,
                generation: gen,
                context: context,
                providerWasSupported: providerWasSupported
            ) == true else { return }

            let frame = await frameProvider.captureCurrentFrame(maxWidth: 960, context: context)
            guard self?.frameAnalysisIsCurrent(
                id: analysisID,
                generation: gen,
                context: context,
                providerWasSupported: providerWasSupported
            ) == true else { return }

            guard let frame else {
                print("[Scene] ⚠️ Frame capture returned nil (isSupported=\(frameProvider.isSupported), message=\(frameProvider.capabilityMessage ?? "none"))")
                if !providerWasSupported {
                    guard let self,
                          self.frameAnalysisIsCurrent(
                            id: analysisID,
                            generation: gen,
                            context: context,
                            providerWasSupported: providerWasSupported
                          ) else { return }
                    let msg = frameProvider.capabilityMessage ?? "Frame capture unsupported"
                    self.updateActorStatus(.unavailable(reason: msg))
                }
                guard let timelineMatch = await resultCache.findTimelineInterval(
                    for: context,
                    sourceTime: requestedTime
                ), self?.frameAnalysisIsCurrent(
                    id: analysisID,
                    generation: gen,
                    context: context,
                    providerWasSupported: providerWasSupported
                ) == true else {
                    if let self, self.frameAnalysisIsCurrent(
                        id: analysisID,
                        generation: gen,
                        context: context,
                        providerWasSupported: providerWasSupported
                    ) {
                        let activeTracked = await self.actorRecognition.currentTrackedActors(at: requestedTime)
                        if !activeTracked.isEmpty {
                            self.updateActorStatus(.recognized(activeTracked))
                        } else if case .analyzing = self.currentSnapshot.actorStatus {
                            self.updateActorStatus(.noMatch)
                        }
                    }
                    return
                }
                for actor in timelineMatch.actors {
                    guard self?.frameAnalysisIsCurrent(
                        id: analysisID,
                        generation: gen,
                        context: context,
                        providerWasSupported: providerWasSupported
                    ) == true else { return }
                    await actorRecognition.recordConfirmedActor(actor, at: requestedTime)
                }
                guard let self,
                      self.frameAnalysisIsCurrent(
                    id: analysisID,
                    generation: gen,
                    context: context,
                    providerWasSupported: providerWasSupported
                      ) else { return }
                self.updateActorStatus(.recognized(timelineMatch.actors))
                return
            }
            guard frame.sessionID == context.sessionID,
                  frame.generation == context.timelineGeneration,
                  frame.sourceTime.isFinite else { return }
            let time = frame.sourceTime
            if !isPaused, let previousTime = self?.lastAnalyzedFrameSourceTime,
               abs(time - previousTime) < 0.01 {
                return
            }
            guard self?.frameAnalysisIsCurrent(
                id: analysisID,
                generation: gen,
                context: context,
                providerWasSupported: providerWasSupported
            ) == true else { return }
            self?.lastAnalyzedFrameSourceTime = time
            let captureDetails = frame.captureDiagnostics.map { " capture={\($0)}" } ?? ""
            print("[Scene] Captured frame (\(frame.pixelSize.width)x\(frame.pixelSize.height)) at \(time)s (candidates: \(candidates.count))\(captureDetails)")

            let status = await actorRecognition.analyzeFrame(
                frame,
                candidates: candidates,
                sourceTime: time,
                isPaused: isPaused,
                activeSubtitleText: currentSubtitle
            )
            guard self?.frameAnalysisIsCurrent(
                id: analysisID,
                generation: gen,
                context: context,
                providerWasSupported: providerWasSupported
            ) == true else { return }
            // Fall back to or augment with verified timeline interval
            var resolvedStatus = status
            if case .noMatch = status {
                if let timelineMatch = await resultCache.findTimelineInterval(for: context, sourceTime: time) {
                    guard self?.frameAnalysisIsCurrent(
                        id: analysisID,
                        generation: gen,
                        context: context,
                        providerWasSupported: providerWasSupported
                    ) == true else { return }
                    for actor in timelineMatch.actors {
                        guard self?.frameAnalysisIsCurrent(
                            id: analysisID,
                            generation: gen,
                            context: context,
                            providerWasSupported: providerWasSupported
                        ) == true else { return }
                        await actorRecognition.recordConfirmedActor(actor, at: time)
                    }
                    resolvedStatus = .recognized(timelineMatch.actors)
                }
            } else if case .unavailable = status {
                if let timelineMatch = await resultCache.findTimelineInterval(for: context, sourceTime: time) {
                    guard self?.frameAnalysisIsCurrent(
                        id: analysisID,
                        generation: gen,
                        context: context,
                        providerWasSupported: providerWasSupported
                    ) == true else { return }
                    for actor in timelineMatch.actors {
                        guard self?.frameAnalysisIsCurrent(
                            id: analysisID,
                            generation: gen,
                            context: context,
                            providerWasSupported: providerWasSupported
                        ) == true else { return }
                        await actorRecognition.recordConfirmedActor(actor, at: time)
                    }
                    resolvedStatus = .recognized(timelineMatch.actors)
                }
            } else if case .recognized(let visualActors) = status {
                if let timelineMatch = await resultCache.findTimelineInterval(for: context, sourceTime: time) {
                    guard self?.frameAnalysisIsCurrent(
                        id: analysisID,
                        generation: gen,
                        context: context,
                        providerWasSupported: providerWasSupported
                    ) == true else { return }
                    for actor in timelineMatch.actors {
                        guard self?.frameAnalysisIsCurrent(
                            id: analysisID,
                            generation: gen,
                            context: context,
                            providerWasSupported: providerWasSupported
                        ) == true else { return }
                        await actorRecognition.recordConfirmedActor(actor, at: time)
                    }
                    var combinedActors = visualActors
                    for actor in timelineMatch.actors {
                        if !combinedActors.contains(where: { $0.id == actor.id }) {
                            combinedActors.append(actor)
                        }
                    }
                    resolvedStatus = .recognized(combinedActors)
                }
            }

            let finalStatus = resolvedStatus
            guard let self,
                  self.frameAnalysisIsCurrent(
                id: analysisID,
                generation: gen,
                context: context,
                providerWasSupported: providerWasSupported
                  ), abs(sourceTime() - time) <= 15.0 else { return }

            // Do not clobber recognized actors during transient analyzing frames
            if case .analyzing = finalStatus, !self.currentSnapshot.actors.isEmpty {
                return
            }

            self.updateActorStatus(finalStatus)

            // Store recognized actors in dynamic result cache.
            if case .recognized(let actors) = finalStatus {
                let snapshot = SceneSnapshot(
                    timestamp: time,
                    actors: actors,
                    song: self.currentSnapshot.song,
                    actorStatus: finalStatus,
                    musicStatus: self.currentSnapshot.musicStatus,
                    generation: gen
                )
                Task { [context, snapshot, time, resultCache] in
                    await resultCache.store(snapshot: snapshot, context: context, sourceTime: time)
                }
            }
        }
    }

    private func frameAnalysisIsCurrent(
        id: UUID,
        generation: UInt64,
        context: SceneContext,
        providerWasSupported: Bool
    ) -> Bool {
        guard !Task.isCancelled,
              activeAnalysisID == id,
              isPanelOpen,
              currentGeneration == generation,
              frameProvider.isSupported == providerWasSupported,
              let currentContext = self.context else { return false }
        return isSameMediaContext(currentContext, context)
            && currentContext.sessionID == context.sessionID
    }

    private func finishFrameAnalysis(id: UUID) {
        guard activeAnalysisID == id else { return }
        activeAnalysisID = nil
        analysisTask = nil
        if needsFrameAnalysisAfterCastLoad {
            needsFrameAnalysisAfterCastLoad = false
            captureAndAnalyzeCurrentFrame()
        } else {
            capturePendingPausedFrameIfNeeded()
        }
    }

    private func capturePendingPausedFrameIfNeeded() {
        guard let pendingGeneration = pendingPausedFrameGeneration else { return }
        pendingPausedFrameGeneration = nil
        guard isPanelOpen,
              currentGeneration == pendingGeneration,
              !isPlayingProvider() else {
            return
        }
        captureAndAnalyzeCurrentFrame(forGeneration: pendingGeneration)
    }
    
    // MARK: - Music Recognition
    
    private func startMusicRecognition(isPlaying: Bool, sourceTime: Double) {
        guard SceneMusicRecognitionPolicy.automaticShazamRecognitionEnabled else { return }
        guard let audioTapBroker else {
            updateMusicStatus(.unavailable(reason: "Audio tap broker unavailable on this backend"))
            return
        }
        
        if audioSubscriptionId == nil {
            let (subId, stream) = audioTapBroker.subscribe()
            self.audioSubscriptionId = subId
            Task { [weak self, stream, isPlaying, sourceTime] in
                await self?.musicRecognition.startListening(
                    stream: stream,
                    isPlaying: isPlaying,
                    currentSourceTime: sourceTime
                )
            }
        }
    }
    
    private func stopMusicRecognition() {
        if let subId = audioSubscriptionId {
            audioTapBroker?.unsubscribe(id: subId)
            self.audioSubscriptionId = nil
        }
        Task { [weak self] in
            await self?.musicRecognition.stopListening()
        }
    }
    
    // MARK: - State Updates
    
    func updateActorStatus(_ status: SceneActorStatus) {
        let actors = status.actors
        currentSnapshot = SceneSnapshot(
            timestamp: sourceTimeProvider(),
            actors: actors,
            song: currentSnapshot.song,
            actorStatus: status,
            musicStatus: currentSnapshot.musicStatus,
            generation: currentGeneration
        )
    }
    
    private func updateMusicStatus(_ status: SceneMusicStatus) {
        let resolvedSong: SceneRecognizedSong?
        switch status {
        case .matched(let song):
            resolvedSong = song
        case .listening, .noMatch, .requiresPlayback, .disabled, .unavailable, .failed:
            if let existingSong = currentSnapshot.song, existingSong.isActive(at: sourceTimeProvider()) {
                resolvedSong = existingSong
            } else {
                resolvedSong = status.matchedSong
            }
        }
        
        currentSnapshot = SceneSnapshot(
            timestamp: sourceTimeProvider(),
            actors: currentSnapshot.actors,
            song: resolvedSong,
            actorStatus: currentSnapshot.actorStatus,
            musicStatus: status,
            generation: currentGeneration
        )
    }
}
