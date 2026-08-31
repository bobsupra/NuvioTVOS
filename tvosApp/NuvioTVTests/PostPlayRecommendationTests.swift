//
//  PostPlayRecommendationTests.swift
//  NuvioTVTests
//
//  Unit tests for Post-Play Recommendations logic, timing rules, state management,
//  and metadata formatting.
//

import Foundation
import XCTest
@testable import NuvioTV

private final class IntroDBMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let values = Dictionary(uniqueKeysWithValues: components.queryItems.orEmpty.map { ($0.name, $0.value ?? "") })
        let payload: String
        switch (values["season"], values["episode"]) {
        case ("1", "1"):
            payload = #"{"intro":{"start_sec":10,"end_sec":30},"outro":{"start_sec":500,"end_sec":550}}"#
        case ("1", "2"):
            payload = #"{"intro":{"start_sec":12,"end_sec":32}}"#
        default:
            payload = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Optional where Wrapped == [URLQueryItem] {
    var orEmpty: [URLQueryItem] { self ?? [] }
}

final class PostPlayRecommendationTests: XCTestCase {

    func testIntroDBSeasonConsensusRequiresTwoEpisodes() {
        let samples = [
            seasonSample(
                episode: 1,
                duration: 600,
                intervals: [SkipInterval(startTime: 553, endTime: 600, type: "outro", provider: "introdb")]
            )
        ]

        XCTAssertTrue(IntroDBSkipService.consensusIntervals(samples: samples, targetDuration: 720).isEmpty)
    }

    func testIntroDBSeasonConsensusUsesStartAndEndRelativeMedians() {
        let samples = [
            seasonSample(
                episode: 1,
                duration: 600,
                intervals: [
                    SkipInterval(startTime: 0, endTime: 8, type: "recap", provider: "introdb"),
                    SkipInterval(startTime: 10, endTime: 30, type: "intro", provider: "introdb"),
                    SkipInterval(startTime: 553, endTime: 600, type: "outro", provider: "introdb")
                ]
            ),
            seasonSample(
                episode: 2,
                duration: 660,
                intervals: [
                    SkipInterval(startTime: 1, endTime: 9, type: "recap", provider: "introdb"),
                    SkipInterval(startTime: 12, endTime: 32, type: "intro", provider: "introdb"),
                    SkipInterval(startTime: 614, endTime: 660, type: "outro", provider: "introdb")
                ]
            )
        ]

        let inferred = IntroDBSkipService.consensusIntervals(samples: samples, targetDuration: 720)

        XCTAssertEqual(inferred.first(where: { $0.type == "recap" })?.startTime, 0.5)
        XCTAssertEqual(inferred.first(where: { $0.type == "recap" })?.endTime, 8.5)
        XCTAssertEqual(inferred.first(where: { $0.type == "intro" })?.startTime, 11)
        XCTAssertEqual(inferred.first(where: { $0.type == "intro" })?.endTime, 31)
        XCTAssertEqual(inferred.first(where: { $0.type == "outro" })?.startTime, 673.5)
        XCTAssertEqual(inferred.first(where: { $0.type == "outro" })?.endTime, 720)
        XCTAssertTrue(inferred.allSatisfy { $0.provider == "introdb-season" })
    }

    func testIntroDBSeasonConsensusRejectsOutroOutlier() {
        let offsets: [Double] = [46, 47, 48, 180]
        let samples = offsets.enumerated().map { index, offset in
            seasonSample(
                episode: index + 1,
                duration: 600,
                intervals: [
                    SkipInterval(startTime: 600 - offset, endTime: 600, type: "outro", provider: "introdb")
                ]
            )
        }

        let inferred = IntroDBSkipService.consensusIntervals(samples: samples, targetDuration: 720)

        XCTAssertEqual(inferred.first?.startTime, 673)
        XCTAssertEqual(inferred.first?.endTime, 720)
    }

    func testIntroDBExactIntervalsWinWhileSeasonDataFillsMissingTypes() {
        let exact = [SkipInterval(startTime: 12, endTime: 32, type: "intro", provider: "introdb")]
        let inferred = [
            SkipInterval(startTime: 10, endTime: 30, type: "intro", provider: "introdb-season"),
            SkipInterval(startTime: 620, endTime: 670, type: "outro", provider: "introdb-season")
        ]

        let merged = IntroDBSkipService.mergingExactIntervals(exact, with: inferred)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first(where: { $0.type == "intro" })?.startTime, 12)
        XCTAssertEqual(merged.first(where: { $0.type == "intro" })?.provider, "introdb")
        XCTAssertEqual(merged.first(where: { $0.type == "outro" })?.provider, "introdb-season")
    }

    func testIntroDBCachedPartialExactRefreshesOnlyItsSeasonTemplate() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntroDBMockURLProtocol.self]
        let service = IntroDBSkipService(session: URLSession(configuration: configuration))

        _ = await service.intervals(imdbId: "tt1234567", season: 1, episode: 1, duration: 600)
        _ = await service.intervals(imdbId: "tt1234567", season: 1, episode: 2)
        let episodeTwo = await service.intervals(imdbId: "tt1234567", season: 1, episode: 2, duration: 720)
        let episodeThree = await service.intervals(imdbId: "tt1234567", season: 1, episode: 3, duration: 720)
        let otherSeason = await service.intervals(imdbId: "tt1234567", season: 2, episode: 3, duration: 720)

        XCTAssertEqual(episodeTwo.first(where: { $0.type == "intro" })?.startTime, 12)
        XCTAssertNil(episodeTwo.first(where: { $0.type == "outro" }))
        XCTAssertEqual(episodeThree.first(where: { $0.type == "intro" })?.startTime, 11)
        XCTAssertNil(episodeThree.first(where: { $0.type == "outro" }))
        XCTAssertTrue(otherSeason.isEmpty)
    }

    func testIntroDBRepeatedEpisodeSeedDoesNotInflateConfidence() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntroDBMockURLProtocol.self]
        let service = IntroDBSkipService(session: URLSession(configuration: configuration))
        let first = [SkipInterval(startTime: 553, endTime: 600, type: "outro", provider: "introdb")]
        let replacement = [SkipInterval(startTime: 554, endTime: 600, type: "outro", provider: "introdb")]

        service.seedSeasonTemplate(imdbId: "tt1234567", season: 1, episode: 1, intervals: first, duration: 600)
        service.seedSeasonTemplate(imdbId: "tt1234567", season: 1, episode: 1, intervals: replacement, duration: 600)
        let oneEpisode = await service.intervals(imdbId: "tt1234567", season: 1, episode: 9, duration: 720)

        XCTAssertNil(oneEpisode.first(where: { $0.type == "outro" }))

        service.seedSeasonTemplate(imdbId: "tt1234567", season: 1, episode: 2, intervals: first, duration: 600)
        let twoEpisodes = await service.intervals(imdbId: "tt1234567", season: 1, episode: 9, duration: 720)

        XCTAssertEqual(twoEpisodes.first(where: { $0.type == "outro" })?.startTime, 673.5)
    }

    private func seasonSample(
        episode: Int,
        duration: Double,
        intervals: [SkipInterval]
    ) -> IntroDBSkipService.SeasonSample {
        IntroDBSkipService.SeasonSample(episode: episode, intervals: intervals, duration: duration)
    }

    func testSettingsKeyRegistered() {
        XCTAssertEqual(SettingsKey.postPlayRecommendationsEnabled, "nuvio.tv.settings.playback.postPlayRecommendationsEnabled")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.postPlayRecommendationsEnabled))
    }

    func testShouldUsePostPlayRecommendationForMovies() {
        // Movies should always qualify when enabled
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldUsePostPlayRecommendation(
                contentType: "movie",
                isNextEpisodeMetadataResolved: false,
                nextEpisodeHasAired: nil,
                enabled: true
            )
        )

        // When setting is turned off, should not use
        XCTAssertFalse(
            PostPlayRecommendationRules.shouldUsePostPlayRecommendation(
                contentType: "movie",
                isNextEpisodeMetadataResolved: false,
                nextEpisodeHasAired: nil,
                enabled: false
            )
        )
    }

    func testShouldUsePostPlayRecommendationForSeries() {
        // Series with an aired next episode -> false (next episode countdown takes precedence)
        XCTAssertFalse(
            PostPlayRecommendationRules.shouldUsePostPlayRecommendation(
                contentType: "series",
                isNextEpisodeMetadataResolved: true,
                nextEpisodeHasAired: true,
                enabled: true
            )
        )

        // Series with no follow-up episode (season/series finale) -> true
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldUsePostPlayRecommendation(
                contentType: "series",
                isNextEpisodeMetadataResolved: true,
                nextEpisodeHasAired: nil,
                enabled: true
            )
        )

        // Series with unaired next episode -> true
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldUsePostPlayRecommendation(
                contentType: "series",
                isNextEpisodeMetadataResolved: true,
                nextEpisodeHasAired: false,
                enabled: true
            )
        )

        // Series where next episode metadata is not yet resolved -> false
        XCTAssertFalse(
            PostPlayRecommendationRules.shouldUsePostPlayRecommendation(
                contentType: "series",
                isNextEpisodeMetadataResolved: false,
                nextEpisodeHasAired: nil,
                enabled: true
            )
        )
    }

    func testPrefetchRules() {
        let duration: Double = 7200 // 2 hours

        // Early playback: 10% progress (720s) -> false
        XCTAssertFalse(
            PostPlayRecommendationRules.shouldPrefetchPostPlayRecommendation(
                positionSeconds: 720,
                durationSeconds: duration
            )
        )

        // 90% progress (6480s) -> true
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldPrefetchPostPlayRecommendation(
                positionSeconds: 6480,
                durationSeconds: duration
            )
        )

        // 10 minutes remaining (6600s) -> true
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldPrefetchPostPlayRecommendation(
                positionSeconds: 6600,
                durationSeconds: duration
            )
        )

        // Invalid duration -> false
        XCTAssertFalse(
            PostPlayRecommendationRules.shouldPrefetchPostPlayRecommendation(
                positionSeconds: 100,
                durationSeconds: 0
            )
        )
    }

    func testTriggerRulesWithCreditsAndLeadTime() {
        let duration: Double = 7200 // 2 hours

        // Mid-movie (1 hour in) with no ending marker -> false
        XCTAssertFalse(
            PostPlayRecommendationRules.shouldTriggerPostPlayRecommendation(
                positionSeconds: 3600,
                durationSeconds: duration,
                isEnded: false,
                endingStartTime: nil
            )
        )

        // Mid-movie (1 hour in) with ending marker at 6900s -> false
        XCTAssertFalse(
            PostPlayRecommendationRules.shouldTriggerPostPlayRecommendation(
                positionSeconds: 3600,
                durationSeconds: duration,
                isEnded: false,
                endingStartTime: 6900
            )
        )

        // When playhead reaches IntroDB credits marker (6900s) -> true
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldTriggerPostPlayRecommendation(
                positionSeconds: 6900,
                durationSeconds: duration,
                isEnded: false,
                endingStartTime: 6900
            )
        )

        // Fallback: 2 minutes (120s) before file end without IntroDB marker -> true
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldTriggerPostPlayRecommendation(
                positionSeconds: 7080,
                durationSeconds: duration,
                isEnded: false,
                endingStartTime: nil
            )
        )

        // Playback ended -> true
        XCTAssertTrue(
            PostPlayRecommendationRules.shouldTriggerPostPlayRecommendation(
                positionSeconds: 7200,
                durationSeconds: duration,
                isEnded: true,
                endingStartTime: nil
            )
        )
    }

    func testCountdownCalculation() {
        let duration: Double = 6000

        // 10s remaining -> nil (not within 5s window)
        XCTAssertNil(
            PostPlayRecommendationRules.postPlayRecommendationCountdownSeconds(
                positionSeconds: 5990,
                durationSeconds: duration
            )
        )

        // 4.5s remaining -> 5s countdown
        XCTAssertEqual(
            PostPlayRecommendationRules.postPlayRecommendationCountdownSeconds(
                positionSeconds: 5995.5,
                durationSeconds: duration
            ),
            5
        )

        // 2.1s remaining -> 3s countdown
        XCTAssertEqual(
            PostPlayRecommendationRules.postPlayRecommendationCountdownSeconds(
                positionSeconds: 5997.9,
                durationSeconds: duration
            ),
            3
        )

        // 0.2s remaining -> 1s countdown
        XCTAssertEqual(
            PostPlayRecommendationRules.postPlayRecommendationCountdownSeconds(
                positionSeconds: 5999.8,
                durationSeconds: duration
            ),
            1
        )
    }

    func testUiStateNavigationAndReturnToPlayer() {
        var state = PostPlayRecommendationUiState(
            recommendation: PostPlayRecommendation(
                id: "rec1",
                contentType: "movie",
                title: "Inception"
            ),
            recommendationIndex: 0,
            recommendationCount: 3,
            isVisible: true
        )

        // At index 0 of 3: can navigate next, cannot navigate previous
        XCTAssertFalse(state.canNavigatePrevious)
        XCTAssertTrue(state.canNavigateNext)
        XCTAssertTrue(state.canReturnToPlayer)
        XCTAssertTrue(state.blocksNaturalCompletion)

        // Return to player
        state = state.returnToPlayer()
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.hasReturnedToPlayer)
        XCTAssertNil(state.countdownSeconds)

        // Paging to index 1 of 3
        var pagedState = PostPlayRecommendationUiState(
            recommendation: PostPlayRecommendation(
                id: "rec2",
                contentType: "movie",
                title: "Interstellar"
            ),
            recommendationIndex: 1,
            recommendationCount: 3,
            isVisible: true
        )
        XCTAssertTrue(pagedState.canNavigatePrevious)
        XCTAssertTrue(pagedState.canNavigateNext)

        // While trailer is playing -> canReturnToPlayer is false
        pagedState.isTrailerPlaying = true
        XCTAssertFalse(pagedState.canReturnToPlayer)

        // When trailer is stopped -> canReturnToPlayer is true again
        pagedState.isTrailerPlaying = false
        XCTAssertTrue(pagedState.canReturnToPlayer)

        // At last index (2 of 3)
        pagedState.recommendationIndex = 2
        XCTAssertTrue(pagedState.canNavigatePrevious)
        XCTAssertFalse(pagedState.canNavigateNext)
    }

    func testRecommendationMetadataLine() {
        let recommendation = PostPlayRecommendation(
            id: "tt0137523",
            contentType: "movie",
            title: "Fight Club",
            releaseInfo: "1999",
            genres: ["Drama", "Thriller", "Action"],
            runtime: "139",
            certification: "R"
        )

        XCTAssertEqual(recommendation.metadataLine, "1999 • Drama, Thriller • 139 min • R")
        XCTAssertFalse(recommendation.isSeries)
        XCTAssertFalse(recommendation.hasTrailer)
    }
}
