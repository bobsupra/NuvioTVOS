import XCTest
@testable import NuvioTV

final class DebridFileSelectionTests: XCTestCase {
    private struct File {
        let name: String
        let size: Int64
    }

    private func request(season: Int? = nil, episode: Int? = nil, fileIdx: Int? = nil, filename: String? = nil) -> DebridRequest {
        DebridRequest(infoHash: "abc", fileIdx: fileIdx, sources: [], filename: filename, season: season, episode: episode)
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

    func testEpisodeMatchingIgnoresParentFoldersAndNumberPrefixes() {
        let files = [
            File(name: "Show.S01E02/Show.S01E20.mkv", size: 9_000_000_000),
            File(name: "Other\\Show.S01E02.mkv", size: 700_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 2)), "Other\\Show.S01E02.mkv")
        XCTAssertFalse(DebridVideo.matchesEpisode("Show.S01E02/Show.S01E20.mkv", season: 1, episode: 2))
    }

    func testMultipleExplicitEpisodeTokensMatchWithoutNumberPrefixConfusion() {
        let name = "Show.S01E02E03.1080p.mkv"
        XCTAssertTrue(DebridVideo.matchesEpisode(name, season: 1, episode: 2))
        XCTAssertTrue(DebridVideo.matchesEpisode(name, season: 1, episode: 3))
        XCTAssertFalse(DebridVideo.matchesEpisode(name, season: 1, episode: 30))
        XCTAssertFalse(DebridVideo.matchesEpisode(name, season: 2, episode: 3))
        XCTAssertFalse(DebridVideo.matchesEpisode("Show.S01E02E30.mkv", season: 1, episode: 3))

        let files = [
            File(name: name, size: 700_000_000),
            File(name: "Show.S01E04.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 3)), name)
    }

    func testFolderOnlyEpisodeCanUseAddonFileIndex() {
        let files = [
            File(name: "Show.S01E02/Video.mkv", size: 700_000_000),
            File(name: "Show.S01E20/Video.mkv", size: 9_000_000_000),
        ]
        XCTAssertFalse(DebridVideo.matchesEpisode(files[0].name, season: 1, episode: 2))
        XCTAssertEqual(select(files, request(season: 1, episode: 2, fileIdx: 0)), files[0].name)
    }

    func testExactAddonPathCanIdentifyEpisodeInNearestFolder() {
        let files = [
            File(name: "Show.S01E02/Video.mkv", size: 700_000_000),
            File(name: "Show.S01E20/Video.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 2, filename: "Show.S01E02/Video.mkv")),
            files[0].name
        )
    }

    func testExactAddonPathDoesNotLetFolderOverrideEpisodeInFilename() {
        let files = [
            File(name: "Show.S01E02/Show.S01E20.mkv", size: 9_000_000_000),
            File(name: "Show.S01E02.mkv", size: 700_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 2, filename: files[0].name)),
            files[1].name
        )
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

    func testUniqueAddonFilenameSelectsRequestedRelease() {
        let files = [
            File(name: "Pack/Show.S01E05.720p.mkv", size: 700_000_000),
            File(name: "Pack/Show.S01E05.2160p.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 5, filename: "show.s01e05.720p.mkv")),
            "Pack/Show.S01E05.720p.mkv"
        )
    }

    func testAmbiguousBasenameFallsBackToExistingEpisodeSelection() {
        let files = [
            File(name: "A/Show.S01E05.mkv", size: 700_000_000),
            File(name: "B/Show.S01E05.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 5, filename: "Show.S01E05.mkv")),
            "B/Show.S01E05.mkv"
        )
    }

    func testExactPathDisambiguatesMatchingBasenames() {
        let files = [
            File(name: "A/Show.S01E05.mkv", size: 700_000_000),
            File(name: "B/Show.S01E05.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 5, filename: "A\\Show.S01E05.mkv")),
            "A/Show.S01E05.mkv"
        )
    }

    func testRelativeAddonPathDisambiguatesMatchingBasenames() {
        let files = [
            File(name: "Pack/Season A/Show.S01E05.mkv", size: 700_000_000),
            File(name: "Pack/Season B/Show.S01E05.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 5, filename: "Season A/Show.S01E05.mkv")),
            files[0].name
        )
    }

    func testExactCaseFilenameWinsBeforeCaseInsensitiveMatch() {
        let files = [
            File(name: "Pack/Show.S01E05.mkv", size: 700_000_000),
            File(name: "Pack/show.s01e05.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 5, filename: "Show.S01E05.mkv")),
            "Pack/Show.S01E05.mkv"
        )
    }

    func testAddonFilenameCannotOverrideEpisodeOrSampleProtection() {
        let files = [
            File(name: "Show.S01E04.mkv", size: 1_000_000_000),
            File(name: "Show.S01E05.sample.mkv", size: 40_000_000),
            File(name: "Show.S01E05.mkv", size: 2_000_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 5, filename: "Show.S01E04.mkv")), "Show.S01E05.mkv")
        XCTAssertEqual(select(files, request(season: 1, episode: 5, filename: "Show.S01E05.sample.mkv")), "Show.S01E05.mkv")
    }

    func testUniqueAddonFilenameTakesPrecedenceOverConflictingIndex() {
        let files = [
            File(name: "Show.S01E05.720p.mkv", size: 700_000_000),
            File(name: "Show.S01E05.2160p.mkv", size: 9_000_000_000),
        ]
        XCTAssertEqual(
            select(files, request(season: 1, episode: 5, fileIdx: 1, filename: files[0].name)),
            files[0].name
        )
    }

    func testEpisodeMatchTakesPrecedenceOverConflictingIndex() {
        let files = [
            File(name: "Show.S01E04.mkv", size: 1_000_000_000),
            File(name: "Show.S01E05.mkv", size: 2_000_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 5, fileIdx: 0)), files[1].name)
    }

    func testExplicitIndexMaySelectSampleWhenNoEpisodeMatches() {
        let files = [
            File(name: "Show.S01E04.sample.mkv", size: 40_000_000),
            File(name: "Show.S01E04.mkv", size: 1_000_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 5, fileIdx: 0)), files[0].name)
    }

    func testUnmatchedEpisodeAndOutOfRangeIndexCurrentlyFallsBackToLargest() {
        let files = [
            File(name: "Show.S01E04.mkv", size: 1_000_000_000),
            File(name: "Show.S01E06.mkv", size: 2_000_000_000),
        ]
        XCTAssertEqual(select(files, request(season: 1, episode: 5, fileIdx: 9)), files[1].name)
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

    func testSampleInEpisodeTitleDoesNotHideTheFullFile() {
        let files = [
            File(name: "Sample.of.Life/Sample.of.Life.S01E05.1080p.mkv", size: 2_000_000_000),
            File(name: "Sample.of.Life/Sample.of.Life.S01E05.sample.mkv", size: 40_000_000),
        ]
        XCTAssertFalse(DebridVideo.isSample(files[0].name))
        XCTAssertTrue(DebridVideo.isSample(files[1].name))
        XCTAssertEqual(select(files, request(season: 1, episode: 5)), files[0].name)
        XCTAssertTrue(DebridVideo.isSample("Sample/Show.S01E05.mkv"))
    }
}
