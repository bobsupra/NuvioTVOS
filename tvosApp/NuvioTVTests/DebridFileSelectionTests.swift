import XCTest
@testable import NuvioTV

final class DebridFileSelectionTests: XCTestCase {
    private struct File {
        let name: String
        let size: Int64
    }

    private func request(season: Int? = nil, episode: Int? = nil, fileIdx: Int? = nil) -> DebridRequest {
        DebridRequest(infoHash: "abc", fileIdx: fileIdx, sources: [], filename: nil, season: season, episode: episode)
    }

    private func select(_ files: [File], _ request: DebridRequest) -> String? {
        DebridFileSelection.select(from: files, request: request, name: { $0.name }, size: { $0.size })?.name
    }

    func testEpisodeSampleListedFirstIsSkipped() {
        let files = [
            File(name: "Show.S01E05.1080p-GRP-sample.mkv", size: 40_000_000),
            File(name: "Show.S01E05.1080p-GRP.mkv", size: 2_000_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 5)), "Show.S01E05.1080p-GRP.mkv")
    }

    func testSampleFolderIsSkipped() {
        let files = [
            File(name: "Sample/show.s01e05.mkv", size: 40_000_000),
            File(name: "show.s01e05.mkv", size: 1_500_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 5)), "show.s01e05.mkv")
    }

    func testLargestOfSeveralEpisodeMatchesWins() {
        let files = [
            File(name: "Show.S01E05.720p.mkv", size: 700_000_000),
            File(name: "Show.S01E05.2160p.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 5)), "Show.S01E05.2160p.mkv")
    }

    func testMovieFallbackSkipsSample() {
        let files = [
            File(name: "Movie.2024.1080p-sample.mkv", size: 80_000_000),
            File(name: "Movie.2024.1080p.mkv", size: 8_000_000_000),
        ]
        XCTAssertEqual(select(files, request()), "Movie.2024.1080p.mkv")
    }

    func testOnlyASampleIsStillPlayable() {
        let files = [File(name: "Show.S01E05-sample.mkv", size: 40_000_000)]
        XCTAssertEqual(select(files, request(season: 1, episode: 5)), "Show.S01E05-sample.mkv")
    }

    func testWordsContainingSampleAreNotSamples() {
        XCTAssertFalse(DebridVideo.isSample("Samples.Of.Life.S01E01.mkv"))
        XCTAssertFalse(DebridVideo.isSample("Resampled.Audio.mkv"))
        XCTAssertTrue(DebridVideo.isSample("show.s01e01.SAMPLE.mkv"))
    }
}
