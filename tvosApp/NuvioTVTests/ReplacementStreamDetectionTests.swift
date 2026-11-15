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

    @MainActor
    func testExpectedDurationComesOnlyFromTheSameEpisode() {
        let meta = NuvioMeta(
            id: "tt-replacement-other-episode",
            name: "Series",
            type: "series",
            runtime: "22 min"
        )
        // Episode 110 was watched from a source that serves three episodes in one file.
        let longFileEntry = ContinueWatchingItem(
            meta: meta,
            streamUrl: "test://three-episodes-in-one-file",
            position: 600,
            duration: 4_250,
            lastWatchedAt: Date(),
            season: 1,
            episode: 110
        )

        XCTAssertEqual(
            PlayerViewModel.expectedDuration(for: meta, progressItem: longFileEntry, episode: (season: 1, episode: 110)),
            4_250
        )
        // Episode 112 is another file: the title's runtime applies.
        let expected = PlayerViewModel.expectedDuration(
            for: meta, progressItem: longFileEntry, episode: (season: 1, episode: 112)
        )
        XCTAssertEqual(expected, 1_320)
        // A single-episode file of 22 minutes is then not taken for an expired-link slate.
        XCTAssertFalse(PlayerViewModel.streamLooksLikeReplacement(
            loadedDuration: 1_344,
            pendingResumeSeconds: nil,
            expectedDurationSeconds: expected,
            isStandalonePlaybackSession: false,
            isLiveStream: false
        ))
        // With the other episode's length it was.
        XCTAssertTrue(PlayerViewModel.streamLooksLikeReplacement(
            loadedDuration: 1_344,
            pendingResumeSeconds: nil,
            expectedDurationSeconds: 4_250,
            isStandalonePlaybackSession: false,
            isLiveStream: false
        ))
    }
}
