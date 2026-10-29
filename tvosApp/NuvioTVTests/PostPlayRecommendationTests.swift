//
//  PostPlayRecommendationTests.swift
//  NuvioTVTests
//
//  Unit tests for Post-Play Recommendations logic, timing rules, state management,
//  and metadata formatting.
//

import Combine
import Foundation
import SwiftUI
import UIKit
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
            if values["is_movie"] == "true" {
                payload = #"{"outro":{"start_sec":5400,"end_sec":5800},"post_credits":{"start_sec":5600,"end_sec":5700}}"#
            } else {
                payload = "{}"
            }
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

@MainActor
private final class PlayerSurfaceBoundsProbeController: UIViewController {
    private(set) var mountCount = 0
    private(set) var unmountCount = 0
    private(set) var laidOutBounds: [CGSize] = []

    func recordMount() { mountCount += 1 }
    func recordUnmount() { unmountCount += 1 }
    func resetLayoutSamples() { laidOutBounds.removeAll() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.width > 0, view.bounds.height > 0 {
            laidOutBounds.append(view.bounds.size)
        }
    }
}

private struct PlayerSurfaceBoundsProbe: UIViewControllerRepresentable {
    let controller: PlayerSurfaceBoundsProbeController

    func makeUIViewController(context: Context) -> PlayerSurfaceBoundsProbeController {
        controller.recordMount()
        return controller
    }

    func updateUIViewController(_ controller: PlayerSurfaceBoundsProbeController, context: Context) {}

    static func dismantleUIViewController(
        _ controller: PlayerSurfaceBoundsProbeController,
        coordinator: ()
    ) {
        controller.recordUnmount()
    }
}

@MainActor
private final class PlayerSurfacePresentationTestState: ObservableObject {
    @Published var isMini = false
    @Published var isVisible = true
}

private struct PlayerSurfacePresentationMetric: Equatable {
    let size: CGSize
    let isMini: Bool
    let isVisible: Bool
}

@MainActor
private final class PlayerSurfacePresentationRecorder {
    private(set) var metrics: [PlayerSurfacePresentationMetric] = []
    private var expectedMatch: ((PlayerSurfacePresentationMetric) -> Bool)?
    private var expectedFulfillment: XCTestExpectation?

    func expect(
        _ match: @escaping (PlayerSurfacePresentationMetric) -> Bool,
        fulfillment: XCTestExpectation
    ) {
        expectedMatch = match
        expectedFulfillment = fulfillment
        if let latest = metrics.last, match(latest) {
            expectedFulfillment?.fulfill()
            expectedFulfillment = nil
            expectedMatch = nil
        }
    }

    func record(_ metric: PlayerSurfacePresentationMetric) {
        metrics.append(metric)
        guard let expectedFulfillment, expectedMatch?(metric) == true else { return }
        expectedFulfillment.fulfill()
        self.expectedFulfillment = nil
        expectedMatch = nil
    }
}

@available(tvOS 18.0, *)
private struct PlayerSurfacePresentationTestHost: View {
    @ObservedObject var state: PlayerSurfacePresentationTestState
    let controller: PlayerSurfaceBoundsProbeController
    let recorder: PlayerSurfacePresentationRecorder

    var body: some View {
        GeometryReader { geometry in
            let isMini = state.isMini
            let isVisible = state.isVisible
            let insets = geometry.safeAreaInsets
            let viewportSize = CGSize(
                width: geometry.size.width + insets.leading + insets.trailing,
                height: geometry.size.height + insets.top + insets.bottom
            )
            let miniSize = CGSize(width: 580, height: 326)
            ZStack {
                StablePlayerSurfacePresentation(
                    viewportSize: viewportSize,
                    presentationSize: isMini ? miniSize : viewportSize
                ) {
                    PlayerSurfaceBoundsProbe(controller: controller)
                }
                .onGeometryChange(for: PlayerSurfacePresentationMetric.self) { presentationGeometry in
                    PlayerSurfacePresentationMetric(
                        size: presentationGeometry.size,
                        isMini: isMini,
                        isVisible: isVisible
                    )
                } action: { metric in
                    recorder.record(metric)
                }
                .offset(x: isMini ? -60 : 0, y: isMini ? 50 : 0)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: isMini ? .topTrailing : .center
            )
            .zIndex(isMini ? 5 : 0)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
            .allowsHitTesting(isVisible)
            .animation(.easeInOut(duration: 0.16), value: isMini)
        }
    }
}

final class PostPlayRecommendationTests: XCTestCase {

    @MainActor
    @available(tvOS 18.0, *)
    func testMPVSurfaceKeepsNativeBoundsAndIdentityAcrossPostPlayTransitions() async throws {
        let state = PlayerSurfacePresentationTestState()
        let controller = PlayerSurfaceBoundsProbeController()
        let recorder = PlayerSurfacePresentationRecorder()
        let hostingController = UIHostingController(
            rootView: PlayerSurfacePresentationTestHost(
                state: state,
                controller: controller,
                recorder: recorder
            )
        )
        hostingController.additionalSafeAreaInsets = UIEdgeInsets(top: 36, left: 24, bottom: 28, right: 24)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "The hosted layout regression needs the active tvOS window scene"
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        let initialLayout = expectation(description: "fullscreen wrapper uses full viewport")
        recorder.expect({ !$0.isMini && $0.isVisible && $0.size.width > 0 }, fulfillment: initialLayout)
        hostingController.view.setNeedsLayout()
        window.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()
        await fulfillment(of: [initialLayout], timeout: 1.0)

        let nativeBounds = controller.view.bounds.size
        XCTAssertGreaterThan(hostingController.view.safeAreaInsets.top, 0)
        XCTAssertEqual(nativeBounds, hostingController.view.bounds.size)
        XCTAssertEqual(recorder.metrics.last?.size, nativeBounds)
        XCTAssertEqual(controller.mountCount, 1)
        controller.resetLayoutSamples()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let miniSize = CGSize(width: 580, height: 326)
        let miniLayout = expectation(description: "mini wrapper uses recommendation size")
        recorder.expect({ $0.isMini && $0.isVisible && $0.size == miniSize }, fulfillment: miniLayout)
        withAnimation(.easeInOut(duration: 0.16)) {
            state.isMini = true
        }
        hostingController.view.setNeedsLayout()
        window.layoutIfNeeded()
        await fulfillment(of: [miniLayout], timeout: 1.0)
        XCTAssertEqual(controller.view.bounds.size, nativeBounds)
        XCTAssertNotNil(controller.parent)
        XCTAssertEqual(controller.mountCount, 1)
        XCTAssertEqual(controller.unmountCount, 0)

        let hiddenLayout = expectation(description: "trailer/EOF hides without unmounting")
        recorder.expect({ $0.isMini && !$0.isVisible && $0.size == miniSize }, fulfillment: hiddenLayout)
        state.isVisible = false
        hostingController.view.setNeedsLayout()
        window.layoutIfNeeded()
        await fulfillment(of: [hiddenLayout], timeout: 1.0)
        XCTAssertEqual(controller.view.bounds.size, nativeBounds)
        XCTAssertNotNil(controller.view.superview)
        XCTAssertNotNil(controller.view.window, "The hidden MPV surface must remain attached to its window")
        XCTAssertEqual(controller.mountCount, 1)
        XCTAssertEqual(controller.unmountCount, 0)

        let restoredLayout = expectation(description: "fullscreen wrapper restores")
        recorder.expect({ !$0.isMini && $0.isVisible && $0.size == nativeBounds }, fulfillment: restoredLayout)
        state.isVisible = true
        withAnimation(.easeInOut(duration: 0.16)) {
            state.isMini = false
        }
        hostingController.view.setNeedsLayout()
        window.layoutIfNeeded()
        await fulfillment(of: [restoredLayout], timeout: 1.0)
        XCTAssertEqual(controller.view.bounds.size, nativeBounds)
        XCTAssertFalse(controller.laidOutBounds.isEmpty)
        XCTAssertTrue(controller.laidOutBounds.allSatisfy { $0 == nativeBounds })
        XCTAssertEqual(controller.mountCount, 1)
        XCTAssertEqual(controller.unmountCount, 0)
    }

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

    func testIntroDBMovieSkipIntervalsParsing() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntroDBMockURLProtocol.self]
        let service = IntroDBSkipService(session: URLSession(configuration: configuration))

        let intervals = await service.intervals(imdbId: "tt9999999", isMovie: true)
        XCTAssertEqual(intervals.count, 2)

        let credits = intervals.first(where: { $0.type == "movie-credits" })
        let postCredits = intervals.first(where: { $0.type == "post-credits" })

        XCTAssertNotNil(credits)
        XCTAssertNotNil(postCredits)
        // safeCredits clipped to start of post_credits scene (5600)
        XCTAssertEqual(credits?.startTime, 5400)
        XCTAssertEqual(credits?.endTime, 5600)
        XCTAssertEqual(postCredits?.startTime, 5600)
        XCTAssertEqual(postCredits?.endTime, 5700)
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

    func testSkipIntervalCategorization() {
        let intro1 = SkipInterval(startTime: 10, endTime: 30, type: "intro", provider: "introdb")
        let intro2 = SkipInterval(startTime: 10, endTime: 30, type: "op", provider: "introdb")
        let intro3 = SkipInterval(startTime: 10, endTime: 30, type: "opening", provider: "introdb")
        let intro4 = SkipInterval(startTime: 10, endTime: 30, type: "mixed-op", provider: "introdb")
        let recap = SkipInterval(startTime: 0, endTime: 10, type: "recap", provider: "introdb")
        let outro1 = SkipInterval(startTime: 500, endTime: 550, type: "outro", provider: "introdb")
        let outro2 = SkipInterval(startTime: 500, endTime: 550, type: "ed", provider: "introdb")
        let outro3 = SkipInterval(startTime: 500, endTime: 550, type: "ending", provider: "introdb")
        let outro4 = SkipInterval(startTime: 500, endTime: 550, type: "credits", provider: "introdb")
        let movieCredits = SkipInterval(startTime: 500, endTime: 550, type: "movie-credits", provider: "introdb")
        let postCredits = SkipInterval(startTime: 560, endTime: 580, type: "post-credits", provider: "introdb")

        XCTAssertTrue(intro1.isIntro)
        XCTAssertTrue(intro2.isIntro)
        XCTAssertTrue(intro3.isIntro)
        XCTAssertTrue(intro4.isIntro)
        XCTAssertFalse(intro1.isRecap)
        XCTAssertFalse(intro1.isEnding)
        XCTAssertFalse(intro1.isMovieCredits)
        XCTAssertFalse(intro1.isPostCredits)

        XCTAssertTrue(recap.isRecap)
        XCTAssertFalse(recap.isIntro)
        XCTAssertFalse(recap.isEnding)
        XCTAssertFalse(recap.isMovieCredits)
        XCTAssertFalse(recap.isPostCredits)

        XCTAssertTrue(outro1.isEnding)
        XCTAssertTrue(outro2.isEnding)
        XCTAssertTrue(outro3.isEnding)
        XCTAssertTrue(outro4.isEnding)
        XCTAssertFalse(outro1.isIntro)
        XCTAssertFalse(outro1.isRecap)
        XCTAssertFalse(outro1.isMovieCredits)
        XCTAssertFalse(outro1.isPostCredits)

        XCTAssertTrue(movieCredits.isMovieCredits)
        XCTAssertFalse(movieCredits.isEnding)
        XCTAssertFalse(movieCredits.isIntro)
        XCTAssertFalse(movieCredits.isRecap)
        XCTAssertFalse(movieCredits.isPostCredits)

        XCTAssertTrue(postCredits.isPostCredits)
        XCTAssertFalse(postCredits.isEnding)
        XCTAssertFalse(postCredits.isIntro)
        XCTAssertFalse(postCredits.isRecap)
        XCTAssertFalse(postCredits.isMovieCredits)

        // Labels
        XCTAssertEqual(movieCredits.label, "Skip Credits")
        XCTAssertEqual(movieCredits.label(targetsPostCredits: true), "Skip to Post-Credits")
        XCTAssertEqual(outro1.label(targetsPostCredits: true), "Skip to Post-Credits")

        // Post-credits following detection
        let intervals = [movieCredits, postCredits]
        let foundScene = movieCredits.followingPostCreditsScene(intervals: intervals, duration: 600)
        XCTAssertEqual(foundScene?.startTime, 560)
        XCTAssertEqual(foundScene?.type, "post-credits")

        // Heuristic fallback for significant gap (> 5s)
        let heuristicScene = movieCredits.followingPostCreditsScene(intervals: [movieCredits], duration: 560)
        XCTAssertEqual(heuristicScene?.startTime, 550)
        XCTAssertEqual(heuristicScene?.endTime, 560)
        XCTAssertEqual(heuristicScene?.provider, "heuristic")
    }

    func testAutoSkipSettingsKeysRegistered() {
        XCTAssertEqual(SettingsKey.autoSkipIntro, "nuvio.tv.settings.playback.autoSkipIntro")
        XCTAssertEqual(SettingsKey.autoSkipRecap, "nuvio.tv.settings.playback.autoSkipRecap")
        XCTAssertEqual(SettingsKey.autoSkipOutro, "nuvio.tv.settings.playback.autoSkipOutro")
        XCTAssertEqual(SettingsKey.autoSkipMovieCredits, "nuvio.tv.settings.playback.autoSkipMovieCredits")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.autoSkipIntro))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.autoSkipRecap))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.autoSkipOutro))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.autoSkipMovieCredits))
    }

    @MainActor
    func testAutoSkipEvaluationRules() {
        let viewModel = PlayerViewModel()
        let intro = SkipInterval(startTime: 10, endTime: 40, type: "intro", provider: "introdb")
        let recap = SkipInterval(startTime: 0, endTime: 10, type: "recap", provider: "introdb")
        let outro = SkipInterval(startTime: 500, endTime: 550, type: "outro", provider: "introdb")
        let movieCredits = SkipInterval(startTime: 500, endTime: 550, type: "movie-credits", provider: "introdb")
        let postCredits = SkipInterval(startTime: 560, endTime: 580, type: "post-credits", provider: "introdb")

        let store = ProfileSettings.current
        let origIntro = store.object(forKey: SettingsKey.autoSkipIntro)
        let origRecap = store.object(forKey: SettingsKey.autoSkipRecap)
        let origOutro = store.object(forKey: SettingsKey.autoSkipOutro)
        let origMovieCredits = store.object(forKey: SettingsKey.autoSkipMovieCredits)
        defer {
            store.set(origIntro, forKey: SettingsKey.autoSkipIntro)
            store.set(origRecap, forKey: SettingsKey.autoSkipRecap)
            store.set(origOutro, forKey: SettingsKey.autoSkipOutro)
            store.set(origMovieCredits, forKey: SettingsKey.autoSkipMovieCredits)
        }

        viewModel.autoSkipIntroEnabled = false
        viewModel.autoSkipRecapEnabled = false
        viewModel.autoSkipOutroEnabled = false
        viewModel.autoSkipMovieCreditsEnabled = false

        XCTAssertFalse(viewModel.shouldAutoSkip(interval: intro))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: recap))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: outro))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: movieCredits))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: postCredits))

        viewModel.autoSkipIntroEnabled = true
        XCTAssertTrue(viewModel.shouldAutoSkip(interval: intro))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: recap))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: outro))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: movieCredits))

        viewModel.autoSkipRecapEnabled = true
        XCTAssertTrue(viewModel.shouldAutoSkip(interval: recap))

        viewModel.autoSkipOutroEnabled = true
        XCTAssertTrue(viewModel.shouldAutoSkip(interval: outro))

        viewModel.autoSkipMovieCreditsEnabled = true
        XCTAssertTrue(viewModel.shouldAutoSkip(interval: movieCredits))
        // Post credits should never be auto-skipped
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: postCredits))

        let originalStatus = viewModel.status
        viewModel.status = .paused
        viewModel.beginScrub()
        XCTAssertTrue(viewModel.isScrubbing)
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: intro))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: movieCredits))
        viewModel.cancelScrub()
        XCTAssertFalse(viewModel.isScrubbing)
        viewModel.status = originalStatus

        viewModel.isHoldingSeek = true
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: intro))
        XCTAssertFalse(viewModel.shouldAutoSkip(interval: movieCredits))
        viewModel.isHoldingSeek = false
    }

    func testAutoSkipLocalizationKeysPresent() {
        XCTAssertEqual(L10n.string("playback_auto_skip_segments", fallback: ""), "Automatic Skipping")
        XCTAssertEqual(L10n.string("playback_auto_skip_segments_sub", fallback: ""), "Choose which segments skip automatically.")
        XCTAssertEqual(L10n.string("auto_skip_intro", fallback: ""), "Intro / Opening")
        XCTAssertEqual(L10n.string("auto_skip_intro_sub", fallback: ""), "Skip intros and anime openings automatically.")
        XCTAssertEqual(L10n.string("auto_skip_recap", fallback: ""), "Recap")
        XCTAssertEqual(L10n.string("auto_skip_recap_sub", fallback: ""), "Skip recap segments automatically.")
        XCTAssertEqual(L10n.string("auto_skip_outro", fallback: ""), "Outro / Ending")
        XCTAssertEqual(L10n.string("auto_skip_outro_sub", fallback: ""), "Skip outros and anime endings automatically.")
        XCTAssertEqual(L10n.string("auto_skip_movie_credits", fallback: ""), "End Credits")
        XCTAssertEqual(L10n.string("auto_skip_movie_credits_sub", fallback: ""), "Skip movie credits automatically, keeping post-credits scenes.")
        XCTAssertEqual(L10n.string("skip_movie_credits", fallback: ""), "Skip Credits")
        XCTAssertEqual(L10n.string("skip_to_post_credits", fallback: ""), "Skip to Post-Credits")
    }
}
