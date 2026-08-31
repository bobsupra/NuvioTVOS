//
//  PostPlayRecommendationController.swift
//  NuvioTV
//
//  Controller managing paged post-play recommendation candidate fetching,
//  metadata enrichment, trailer resolution, and countdown state for tvOS.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class PostPlayRecommendationController: ObservableObject {
    @Published private(set) var uiState = PostPlayRecommendationUiState()

    private var currentContentId: String?
    private var currentContentType: String?
    private var currentMeta: NuvioMeta?

    private var recommendationTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var countdownTimerTask: Task<Void, Never>?
    private var returnToPlayerAnimationTask: Task<Void, Never>?

    private var recommendationCandidates: [RelatedTitle] = []
    private var recommendationCache: [Int: PostPlayRecommendation] = [:]
    private var candidateResolutionTasks: [Int: Task<PostPlayRecommendation?, Never>] = [:]
    private var trailerResolutionTasks: [Int: Task<Void, Never>] = [:]

    private var recommendationLoadAttempted = false
    private var autoPlayTrailerEnabled = true
    private var hasReportedVisibility = false

    func start(contentId: String, contentType: String, meta: NuvioMeta) {
        stop()
        self.currentContentId = contentId
        self.currentContentType = contentType
        self.currentMeta = meta
        self.autoPlayTrailerEnabled = ProfileSettings.current.object(forKey: SettingsKey.trailersEnabled) as? Bool ?? true
    }

    func stop() {
        recommendationTask?.cancel()
        recommendationTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        countdownTimerTask?.cancel()
        countdownTimerTask = nil
        returnToPlayerAnimationTask?.cancel()
        returnToPlayerAnimationTask = nil

        candidateResolutionTasks.values.forEach { $0.cancel() }
        candidateResolutionTasks.removeAll()
        trailerResolutionTasks.values.forEach { $0.cancel() }
        trailerResolutionTasks.removeAll()

        recommendationCandidates.removeAll()
        recommendationCache.removeAll()
        recommendationLoadAttempted = false
        hasReportedVisibility = false
        uiState = PostPlayRecommendationUiState()
    }

    func updateTimeline(
        position: Double,
        duration: Double,
        isEnded: Bool,
        isNextEpisodeResolved: Bool,
        nextEpisodeHasAired: Bool?,
        endingStartTime: Double? = nil,
        hasBlockingOverlay: Bool,
        enabled: Bool
    ) {
        guard let meta = currentMeta else { return }

        let shouldUse = PostPlayRecommendationRules.shouldUsePostPlayRecommendation(
            contentType: currentContentType ?? meta.type,
            isNextEpisodeMetadataResolved: isNextEpisodeResolved,
            nextEpisodeHasAired: nextEpisodeHasAired,
            enabled: enabled
        )

        if !shouldUse {
            if uiState.isVisible || uiState.recommendation != nil || uiState.isLoadingRecommendation {
                stop()
            }
            return
        }

        if uiState.hasReturnedToPlayer { return }

        let effectiveDuration = duration > 0 ? duration : 0
        guard effectiveDuration > 10 else { return }

        // 1. Prefetch recommendations at 90% progress or 10 min remaining
        if !recommendationLoadAttempted &&
            PostPlayRecommendationRules.shouldPrefetchPostPlayRecommendation(
                positionSeconds: position,
                durationSeconds: effectiveDuration
            ) {
            loadRecommendations(for: meta)
        }

        guard let recommendation = uiState.recommendation else { return }

        // 2. Evaluate visibility threshold (IntroDB credits start, 2 min lead-time fallback, or ended)
        let shouldTrigger = PostPlayRecommendationRules.shouldTriggerPostPlayRecommendation(
            positionSeconds: position,
            durationSeconds: effectiveDuration,
            isEnded: isEnded,
            endingStartTime: endingStartTime
        )

        if !uiState.isVisible {
            if !shouldTrigger || hasBlockingOverlay { return }

            uiState.isVisible = true
            if recommendation.hasTrailer && autoPlayTrailerEnabled {
                uiState.countdownSeconds = PostPlayRecommendationRules.trailerCountdownSeconds
                startCountdownTimer()
            } else {
                uiState.countdownSeconds = nil
            }
            return
        }

        // 3. If playback ends while overlay is already visible with trailer countdown active -> start trailer
        if isEnded && uiState.countdownSeconds != nil && !uiState.isTrailerPlaying {
            startTrailer()
        }
    }

    func showImmediately() {
        guard !uiState.isVisible, let recommendation = uiState.recommendation else { return }
        uiState.isVisible = true
        if recommendation.hasTrailer && autoPlayTrailerEnabled {
            uiState.countdownSeconds = PostPlayRecommendationRules.trailerCountdownSeconds
            startCountdownTimer()
        } else {
            uiState.countdownSeconds = nil
        }
    }

    func showPreviousRecommendation() {
        selectRecommendation(offset: -1)
    }

    func showNextRecommendation() {
        selectRecommendation(offset: 1)
    }

    func startTrailer() {
        guard uiState.recommendation?.hasTrailer == true, !uiState.isTrailerPlaying else { return }
        countdownTimerTask?.cancel()
        countdownTimerTask = nil
        uiState.countdownSeconds = nil
        uiState.isTrailerPlaying = true
        uiState.hasAutoPlayedTrailer = true
    }

    func stopTrailer() {
        uiState.isTrailerPlaying = false
    }

    func onTrailerEnded() {
        uiState.isTrailerPlaying = false
        uiState.countdownSeconds = nil
        uiState.hasAutoPlayedTrailer = true
    }

    func returnToPlayer() {
        guard uiState.canReturnToPlayer else { return }
        recommendationTask?.cancel()
        recommendationTask = nil
        countdownTimerTask?.cancel()
        countdownTimerTask = nil

        uiState = uiState.returnToPlayer()

        returnToPlayerAnimationTask?.cancel()
        returnToPlayerAnimationTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(PostPlayRecommendationRules.transitionDurationSeconds * 1_000_000_000))
            if !Task.isCancelled {
                uiState = PostPlayRecommendationUiState(hasReturnedToPlayer: true)
            }
        }
    }

    // MARK: - Private Loading & Paging

    private func loadRecommendations(for meta: NuvioMeta) {
        recommendationLoadAttempted = true
        uiState.isLoadingRecommendation = true

        recommendationTask?.cancel()
        recommendationTask = Task {
            let candidates = await fetchFilteredCandidates(for: meta)
            guard !Task.isCancelled else { return }

            if candidates.isEmpty {
                uiState.isLoadingRecommendation = false
                return
            }

            recommendationCandidates = candidates

            // Start candidate resolutions concurrently
            for (idx, candidate) in candidates.enumerated() {
                startCandidateResolution(index: idx, candidate: candidate)
            }

            guard let firstResolved = await awaitCandidateResolution(index: 0) else {
                uiState.isLoadingRecommendation = false
                return
            }

            guard !Task.isCancelled else { return }
            recommendationCache[0] = firstResolved
            uiState.recommendation = firstResolved
            uiState.recommendationIndex = 0
            uiState.recommendationCount = candidates.count
            uiState.isLoadingRecommendation = false
            uiState.isLoadingTrailer = true

            // Prefetch details and trailers for all remaining candidates
            prefetchRemainingCandidateDetails()
            // Also resolve trailer for first item
            resolveTrailerForCandidate(index: 0, recommendation: firstResolved)
        }
    }

    private func fetchFilteredCandidates(for meta: NuvioMeta) async -> [RelatedTitle] {
        let rawCandidates: [RelatedTitle]
        if TraktSettingsStore.moreLikeThisSource == .trakt && TraktAuthStore.state.isAuthenticated {
            rawCandidates = await TraktDetailsService.fetchRelated(for: meta, limit: 16)
        } else {
            rawCandidates = await TmdbDetailsService.fetchMoreLikeThis(for: meta, limit: 16)
        }

        let watchedRecords = WatchProgressLedger.records()
        let watchedContentIds = Set(watchedRecords.filter { WatchProgressLedger.isComplete($0) }.map(\.contentId))
        let watchedVideoIds = Set(watchedRecords.filter { WatchProgressLedger.isComplete($0) }.map(\.videoId))

        let currentId = meta.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentImdbId = meta.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let hideUnreleased = ProfileSettings.current.object(forKey: SettingsKey.hideUnreleased) as? Bool ?? false
        let currentYear = Calendar.current.component(.year, from: Date())

        var filtered: [RelatedTitle] = []
        for candidate in rawCandidates {
            let candidateId = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if candidateId == currentId || (currentImdbId != nil && candidateId == currentImdbId) {
                continue
            }
            if watchedContentIds.contains(candidate.id) || watchedVideoIds.contains(candidate.id) {
                continue
            }
            if hideUnreleased, let yearStr = candidate.year, let year = Int(yearStr), year > currentYear {
                continue
            }
            if filtered.contains(where: { $0.id == candidate.id }) {
                continue
            }
            filtered.append(candidate)
        }

        guard !filtered.isEmpty else { return [] }

        // Place a candidate with a backdrop as the primary first item if possible
        var prioritized: [RelatedTitle] = []
        if let firstWithBackdrop = filtered.first(where: { !($0.backdropURL?.isEmpty ?? true) }) {
            prioritized.append(firstWithBackdrop)
            for item in filtered where item.id != firstWithBackdrop.id {
                prioritized.append(item)
            }
        } else {
            prioritized = filtered
        }

        return Array(prioritized.prefix(PostPlayRecommendationRules.maxRecommendations))
    }

    private func startCandidateResolution(index: Int, candidate: RelatedTitle) {
        guard candidateResolutionTasks[index] == nil else { return }
        candidateResolutionTasks[index] = Task { () -> PostPlayRecommendation? in
            let baseMeta = candidate.asMeta
            let localizedMeta = await TmdbDetailsService.localizedMetadata(for: baseMeta)
            guard !Task.isCancelled else { return nil }

            let genres = localizedMeta.genres ?? baseMeta.genres ?? []
            let releaseInfo = localizedMeta.releaseInfo ?? baseMeta.releaseInfo ?? candidate.year
            let runtime = localizedMeta.runtime ?? baseMeta.runtime
            let certification = localizedMeta.certification ?? baseMeta.certification
            let rating = localizedMeta.rating ?? baseMeta.rating ?? candidate.rating
            let tmdbRating = localizedMeta.rating ?? candidate.rating

            return PostPlayRecommendation(
                id: candidate.id,
                contentType: candidate.type,
                title: localizedMeta.name.isEmpty ? candidate.name : localizedMeta.name,
                poster: localizedMeta.posterUrl ?? candidate.posterURL,
                backdrop: localizedMeta.backgroundUrl ?? candidate.backdropURL ?? localizedMeta.posterUrl ?? candidate.posterURL,
                logo: localizedMeta.logoUrl,
                description: localizedMeta.description ?? candidate.overview,
                releaseInfo: releaseInfo,
                rating: rating,
                genres: genres,
                runtime: runtime,
                tmdbId: localizedMeta.tmdbId,
                tmdbRating: tmdbRating,
                certification: certification,
                externalRatings: localizedMeta.externalRatings
            )
        }
    }

    private func awaitCandidateResolution(index: Int) async -> PostPlayRecommendation? {
        if let cached = recommendationCache[index] {
            return cached
        }
        if let task = candidateResolutionTasks[index] {
            let result = await task.value
            if let result {
                recommendationCache[index] = result
            }
            return result
        }
        if index < recommendationCandidates.count {
            startCandidateResolution(index: index, candidate: recommendationCandidates[index])
            let result = await candidateResolutionTasks[index]?.value
            if let result {
                recommendationCache[index] = result
            }
            return result
        }
        return nil
    }

    private func prefetchRemainingCandidateDetails() {
        prefetchTask?.cancel()
        prefetchTask = Task {
            for (index, _) in recommendationCandidates.enumerated() where index > 0 {
                guard !Task.isCancelled else { return }
                if let resolved = await awaitCandidateResolution(index: index) {
                    resolveTrailerForCandidate(index: index, recommendation: resolved)
                }
            }
        }
    }

    private func resolveTrailerForCandidate(index: Int, recommendation: PostPlayRecommendation) {
        guard trailerResolutionTasks[index] == nil else { return }
        trailerResolutionTasks[index] = Task {
            let meta = recommendation.asMeta
            if let ytId = await YouTubeTrailerResolver.preferredTrailerYouTubeId(for: meta),
               let previewSource = await YouTubeTrailerResolver.shared.resolvePreview(
                   youtubeVideoId: ytId,
                   title: recommendation.title,
                   year: recommendation.releaseInfo
               ) {
                guard !Task.isCancelled else { return }
                var updated = recommendation
                updated.trailerVideoUrl = previewSource.videoUrl
                updated.trailerAudioUrl = previewSource.audioUrl
                updated.trailerHeaders = previewSource.requestHeaders
                recommendationCache[index] = updated
                if uiState.recommendationIndex == index {
                    uiState.recommendation = updated
                    uiState.isLoadingTrailer = false
                }
            } else {
                if uiState.recommendationIndex == index {
                    uiState.isLoadingTrailer = false
                }
            }
        }
    }

    private func selectRecommendation(offset: Int) {
        guard uiState.isVisible, !uiState.isChangingRecommendation else { return }
        let targetIndex = uiState.recommendationIndex + offset
        guard targetIndex >= 0, targetIndex < recommendationCandidates.count else { return }

        countdownTimerTask?.cancel()
        countdownTimerTask = nil
        uiState.isTrailerPlaying = false
        autoPlayTrailerEnabled = false
        uiState.isChangingRecommendation = true
        uiState.countdownSeconds = nil

        selectionTask?.cancel()
        selectionTask = Task {
            let resolved = await awaitCandidateResolution(index: targetIndex)
            guard !Task.isCancelled, let resolved else {
                uiState.isChangingRecommendation = false
                return
            }

            uiState.recommendation = resolved
            uiState.recommendationIndex = targetIndex
            uiState.isChangingRecommendation = false
            uiState.isLoadingTrailer = !resolved.hasTrailer

            resolveTrailerForCandidate(index: targetIndex, recommendation: resolved)
        }
    }

    private func startCountdownTimer() {
        guard autoPlayTrailerEnabled,
              countdownTimerTask == nil,
              !uiState.isTrailerPlaying,
              !uiState.hasAutoPlayedTrailer,
              uiState.recommendation?.hasTrailer == true else {
            return
        }

        countdownTimerTask = Task {
            for seconds in (1...PostPlayRecommendationRules.trailerCountdownSeconds).reversed() {
                guard !Task.isCancelled else { return }
                uiState.countdownSeconds = seconds
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if !Task.isCancelled {
                startTrailer()
            }
        }
    }
}
