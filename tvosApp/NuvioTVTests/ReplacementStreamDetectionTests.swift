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
}
