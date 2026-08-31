//
//  PostPlayRecommendationModels.swift
//  NuvioTV
//
//  Data models and rules for paged post-play recommendations on tvOS.
//

import Foundation

enum PostPlayFocusItem: Hashable {
    case primaryAction
    case trailerAction
    case prevAction
    case nextAction
    case miniPlayer
}

struct PostPlayRecommendation: Identifiable, Equatable {
    let id: String
    let contentType: String
    let title: String
    let poster: String?
    let backdrop: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let rating: Double?
    let genres: [String]
    let runtime: String?
    let tmdbId: Int?
    let tmdbRating: Double?
    let certification: String?
    let externalRatings: [NuvioExternalRating]?
    var trailerVideoUrl: String?
    var trailerAudioUrl: String?
    var trailerHeaders: [String: String]

    init(
        id: String,
        contentType: String,
        title: String,
        poster: String? = nil,
        backdrop: String? = nil,
        logo: String? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        rating: Double? = nil,
        genres: [String] = [],
        runtime: String? = nil,
        tmdbId: Int? = nil,
        tmdbRating: Double? = nil,
        certification: String? = nil,
        externalRatings: [NuvioExternalRating]? = nil,
        trailerVideoUrl: String? = nil,
        trailerAudioUrl: String? = nil,
        trailerHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.contentType = contentType
        self.title = title
        self.poster = poster
        self.backdrop = backdrop
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.rating = rating
        self.genres = genres
        self.runtime = runtime
        self.tmdbId = tmdbId
        self.tmdbRating = tmdbRating
        self.certification = certification
        self.externalRatings = externalRatings
        self.trailerVideoUrl = trailerVideoUrl
        self.trailerAudioUrl = trailerAudioUrl
        self.trailerHeaders = trailerHeaders
    }

    var hasTrailer: Bool {
        guard let trailerVideoUrl else { return false }
        return !trailerVideoUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isSeries: Bool {
        ["series", "show", "tv", "tvshow"].contains(contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var metadataLine: String {
        var parts: [String] = []
        if let releaseInfo, !releaseInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(releaseInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: ", "))
        }
        if let runtime, !runtime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = runtime.trimmingCharacters(in: .whitespacesAndNewlines)
            if let minutes = Int(clean) {
                parts.append("\(minutes) min")
            } else {
                parts.append(clean)
            }
        }
        if let certification, !certification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(certification.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.joined(separator: " • ")
    }

    var asMeta: NuvioMeta {
        NuvioMeta(
            id: id,
            name: title,
            description: description,
            posterUrl: poster,
            backgroundUrl: backdrop,
            logoUrl: logo,
            imdbId: id.hasPrefix("tt") ? id : nil,
            tmdbId: tmdbId,
            type: contentType,
            year: releaseInfo.flatMap(Int.init),
            genres: genres.isEmpty ? nil : genres,
            rating: rating,
            releaseInfo: releaseInfo,
            runtime: runtime,
            cast: nil,
            director: nil,
            writer: nil,
            certification: certification,
            country: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: externalRatings
        )
    }
}

struct PostPlayRecommendationUiState: Equatable {
    var recommendation: PostPlayRecommendation? = nil
    var recommendationIndex: Int = 0
    var recommendationCount: Int = 0
    var isLoadingRecommendation: Bool = false
    var isChangingRecommendation: Bool = false
    var isLoadingTrailer: Bool = false
    var isVisible: Bool = false
    var hasReturnedToPlayer: Bool = false
    var countdownSeconds: Int? = nil
    var isTrailerPlaying: Bool = false
    var hasAutoPlayedTrailer: Bool = false

    init(
        recommendation: PostPlayRecommendation? = nil,
        recommendationIndex: Int = 0,
        recommendationCount: Int = 0,
        isLoadingRecommendation: Bool = false,
        isChangingRecommendation: Bool = false,
        isLoadingTrailer: Bool = false,
        isVisible: Bool = false,
        hasReturnedToPlayer: Bool = false,
        countdownSeconds: Int? = nil,
        isTrailerPlaying: Bool = false,
        hasAutoPlayedTrailer: Bool = false
    ) {
        self.recommendation = recommendation
        self.recommendationIndex = recommendationIndex
        self.recommendationCount = recommendationCount
        self.isLoadingRecommendation = isLoadingRecommendation
        self.isChangingRecommendation = isChangingRecommendation
        self.isLoadingTrailer = isLoadingTrailer
        self.isVisible = isVisible
        self.hasReturnedToPlayer = hasReturnedToPlayer
        self.countdownSeconds = countdownSeconds
        self.isTrailerPlaying = isTrailerPlaying
        self.hasAutoPlayedTrailer = hasAutoPlayedTrailer
    }

    var canNavigatePrevious: Bool {
        !isChangingRecommendation && recommendationIndex > 0
    }

    var canNavigateNext: Bool {
        !isChangingRecommendation && recommendationIndex < recommendationCount - 1
    }

    var canReturnToPlayer: Bool {
        isVisible && !isTrailerPlaying && !hasReturnedToPlayer
    }

    var blocksNaturalCompletion: Bool {
        recommendation != nil || isVisible || hasReturnedToPlayer || isLoadingRecommendation
    }

    func returnToPlayer() -> PostPlayRecommendationUiState {
        guard canReturnToPlayer else { return self }
        var copy = self
        copy.isVisible = false
        copy.hasReturnedToPlayer = true
        copy.countdownSeconds = nil
        return copy
    }
}

enum PostPlayRecommendationRules {
    static let prefetchProgress: Double = 0.90
    static let prefetchRemainingSeconds: Double = 600.0 // 10 minutes
    static let creditsLeadSeconds: Double = 120.0 // 2 minutes lead-time fallback for credits
    static let trailerCountdownSeconds: Int = 5
    static let maxRecommendations: Int = 4
    static let transitionDurationSeconds: Double = 0.42

    static func shouldUsePostPlayRecommendation(
        contentType: String?,
        isNextEpisodeMetadataResolved: Bool,
        nextEpisodeHasAired: Bool?,
        enabled: Bool = true
    ) -> Bool {
        guard enabled else { return false }
        guard let rawType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        if ["movie", "film"].contains(rawType) {
            return true
        }
        if ["series", "tv", "show", "tvshow"].contains(rawType) {
            // For series, post-play recommendations trigger when there is no follow-up episode
            // or the next episode has not aired yet (season/series finale).
            return isNextEpisodeMetadataResolved && nextEpisodeHasAired != true
        }
        return false
    }

    static func shouldPrefetchPostPlayRecommendation(
        positionSeconds: Double,
        durationSeconds: Double
    ) -> Bool {
        guard durationSeconds > 0 else { return false }
        let position = min(max(0, positionSeconds), durationSeconds)
        let remaining = durationSeconds - position
        let progress = position / durationSeconds
        return progress >= prefetchProgress || remaining <= prefetchRemainingSeconds
    }

    static func shouldTriggerPostPlayRecommendation(
        positionSeconds: Double,
        durationSeconds: Double,
        isEnded: Bool,
        endingStartTime: Double? = nil
    ) -> Bool {
        if isEnded { return true }
        guard durationSeconds > 10 else { return false }
        let position = min(max(0, positionSeconds), durationSeconds)
        let remaining = durationSeconds - position

        // 1. If IntroDB credits/outro marker is present and playback has reached it:
        if let endingStart = endingStartTime, endingStart > 0 {
            if position >= max(0, endingStart - 0.5) {
                return true
            }
        }

        // 2. Lead-time fallback: 2 minutes (120s) before file end, provided progress >= 80%
        let progress = position / durationSeconds
        if progress >= 0.80 && remaining <= creditsLeadSeconds {
            return true
        }

        return false
    }

    static func postPlayRecommendationCountdownSeconds(
        positionSeconds: Double,
        durationSeconds: Double
    ) -> Int? {
        guard durationSeconds > 0 else { return nil }
        let remaining = max(0, durationSeconds - positionSeconds)
        if remaining > Double(trailerCountdownSeconds) { return nil }
        return min(trailerCountdownSeconds, max(1, Int(ceil(remaining))))
    }
}
