import XCTest
@testable import NuvioTV

final class ReplacementStreamDetectionTests: XCTestCase {
    @MainActor
    func testShortClipWithoutExpectedDurationOrResumeIsNotReplacement() {
        XCTAssertFalse(PlayerViewModel.streamLooksLikeReplacement(
            loadedDuration: 90,
            pendingResumeSeconds: nil,
            expectedDurationSeconds: nil,
            isStandalonePlaybackSession: false,
            isLiveStream: false
        ))
    }

    @MainActor
    func testShortClipComparedWithKnownLongTitleIsReplacement() {
        XCTAssertTrue(PlayerViewModel.streamLooksLikeReplacement(
            loadedDuration: 90,
            pendingResumeSeconds: nil,
            expectedDurationSeconds: 2_400,
            isStandalonePlaybackSession: false,
            isLiveStream: false
        ))
    }

    @MainActor
    func testResumeBeyondLoadedDurationIsReplacement() {
        XCTAssertTrue(PlayerViewModel.streamLooksLikeReplacement(
            loadedDuration: 90,
            pendingResumeSeconds: 600,
            expectedDurationSeconds: nil,
            isStandalonePlaybackSession: false,
            isLiveStream: false
        ))
    }

    @MainActor
    func testShortLiveStreamWithoutKnownMismatchIsNotReplacement() {
        XCTAssertFalse(PlayerViewModel.streamLooksLikeReplacement(
            loadedDuration: 90,
            pendingResumeSeconds: nil,
            expectedDurationSeconds: nil,
            isStandalonePlaybackSession: false,
            isLiveStream: true
        ))
    }

    @MainActor
    func testKnownDurationMismatchIsStillDetectedForLiveStream() {
        XCTAssertTrue(PlayerViewModel.streamLooksLikeReplacement(
            loadedDuration: 90,
            pendingResumeSeconds: nil,
            expectedDurationSeconds: 2_400,
            isStandalonePlaybackSession: false,
            isLiveStream: true
        ))
    }

    @MainActor
    func testExpectedDurationIgnoresSyntheticUpNextDurationAndKeepsWatchedDuration() {
        let meta = NuvioMeta(
            id: "tt-replacement-duration",
            name: "Episode",
            type: "series",
            runtime: "8 min"
        )
        let upNextEntry = ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 30,
            duration: 3_600,
            lastWatchedAt: Date(),
            season: 1,
            episode: 2,
            isUpNext: true
        )
        XCTAssertEqual(PlayerViewModel.expectedDuration(for: meta, progressItem: upNextEntry), 480)

        let watchedEntry = ContinueWatchingItem(
            meta: meta,
            streamUrl: "test://watched-episode",
            position: 300,
            duration: 2_400,
            lastWatchedAt: Date(),
            season: 1,
            episode: 1
        )
        XCTAssertEqual(PlayerViewModel.expectedDuration(for: meta, progressItem: watchedEntry), 2_400)
    }
}
