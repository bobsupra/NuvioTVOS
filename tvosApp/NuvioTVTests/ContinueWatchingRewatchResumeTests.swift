import XCTest
@testable import NuvioTV

final class ContinueWatchingRewatchResumeTests: XCTestCase {
    func testUnwatchedMovieResumes() {
        XCTAssertFalse(ContentView.continueWatchingMovieStartsOver(isWatched: false, position: 7_480, duration: 13_698))
    }

    func testWatchedMovieRewatchInProgressResumes() {
        XCTAssertFalse(ContentView.continueWatchingMovieStartsOver(isWatched: true, position: 7_480, duration: 13_698))
    }

    func testWatchedMovieWithCompleteProgressStartsOver() {
        XCTAssertTrue(ContentView.continueWatchingMovieStartsOver(isWatched: true, position: 13_000, duration: 13_698))
    }

    func testWatchedMovieWithUnknownProgressStartsOver() {
        XCTAssertTrue(ContentView.continueWatchingMovieStartsOver(isWatched: true, position: 0, duration: 0))
        XCTAssertTrue(ContentView.continueWatchingMovieStartsOver(isWatched: true, position: 600, duration: 0))
    }
}
