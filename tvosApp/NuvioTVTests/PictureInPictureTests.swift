import XCTest
import AVKit
import AVFoundation
@testable import NuvioTV

@MainActor
final class PictureInPictureTests: XCTestCase {
    private func makeTestMeta(id: String, name: String, type: String) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: id,
            tmdbId: nil,
            type: type,
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil
        )
    }

    func testPictureInPictureManagerInitialState() {
        let manager = PictureInPictureManager.shared
        XCTAssertEqual(manager.isPictureInPictureSupported, AVPictureInPictureController.isPictureInPictureSupported())
        XCTAssertFalse(manager.isPictureInPictureActive)
    }

    func testActivePlaybackContextEquality() {
        let url = URL(string: "https://example.com/stream.m3u8")!
        let meta = makeTestMeta(id: "tt1234567", name: "Sample Movie", type: "movie")
        let context1 = ActivePlaybackContext(
            url: url,
            meta: meta,
            subtitle: "1080p",
            httpHeaders: ["Authorization": "Bearer token"],
            externalSubtitles: [],
            resumeFrom: 120.0,
            episodes: [],
            currentEpisode: nil,
            autoPlayNextEnabled: true,
            autoPlayNextCountdownSeconds: 10,
            playbackOrigin: .main
        )

        let context2 = ActivePlaybackContext(
            url: url,
            meta: meta,
            subtitle: "1080p",
            httpHeaders: ["Authorization": "Bearer token"],
            externalSubtitles: [],
            resumeFrom: 120.0,
            episodes: [],
            currentEpisode: nil,
            autoPlayNextEnabled: true,
            autoPlayNextCountdownSeconds: 10,
            playbackOrigin: .main
        )

        XCTAssertEqual(context1, context2)
    }

    func testActivePlaybackContextPreservesPlaybackOrigin() {
        let context = ActivePlaybackContext(
            url: URL(string: "https://example.com/library.mp4")!,
            meta: makeTestMeta(id: "library-title", name: "Library Movie", type: "movie"),
            subtitle: "Library",
            playbackOrigin: .cloudLibrary
        )

        XCTAssertEqual(context.playbackOrigin, .cloudLibrary)
    }

    func testSessionRegistrationAndInvalidation() {
        let manager = PictureInPictureManager.shared
        let coordinator = PlaybackSessionCoordinator()
        let url = URL(string: "https://example.com/test.mp4")!
        let meta = makeTestMeta(id: "tt9999999", name: "Test Show", type: "series")
        let context = ActivePlaybackContext(
            url: url,
            meta: meta,
            subtitle: "S1 E1",
            playbackOrigin: .details
        )

        manager.registerSession(coordinator: coordinator, context: context)
        XCTAssertNotNil(manager.activeCoordinator)
        XCTAssertNotNil(manager.activeAetherController)
        XCTAssertEqual(manager.activeContext?.url, url)

        manager.invalidateSession()
        XCTAssertNil(manager.activeCoordinator)
        XCTAssertNil(manager.activeAetherController)
        XCTAssertNil(manager.activeContext)
        XCTAssertFalse(manager.isPictureInPictureActive)
    }

    func testPlayerViewModelPiPBinding() {
        let viewModel = PlayerViewModel()
        XCTAssertEqual(viewModel.isPictureInPictureSupported, PictureInPictureManager.shared.isPictureInPictureSupported)
        XCTAssertEqual(viewModel.isPictureInPictureActive, PictureInPictureManager.shared.isPictureInPictureActive)
    }

    func testRestoreUICallbackFlow() {
        let manager = PictureInPictureManager.shared
        let coordinator = PlaybackSessionCoordinator()
        let url = URL(string: "https://example.com/movie.mp4")!
        let meta = makeTestMeta(id: "tt8888888", name: "Restore Movie", type: "movie")
        let context = ActivePlaybackContext(
            url: url,
            meta: meta,
            subtitle: "HD",
            playbackOrigin: .main
        )

        manager.registerSession(coordinator: coordinator, context: context)

        var didRestore = false
        manager.onRestoreUI = { restoredContext, completion in
            XCTAssertEqual(restoredContext.url, url)
            XCTAssertEqual(restoredContext.meta.id, "tt8888888")
            didRestore = true
            completion(true)
        }

        // Simulate restore trigger
        manager.onRestoreUI?(context) { success in
            XCTAssertTrue(success)
        }
        XCTAssertTrue(didRestore)

        manager.invalidateSession()
    }
}
