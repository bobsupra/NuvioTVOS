import XCTest
@testable import NuvioTV

final class MediaFilenameParserTests: XCTestCase {
    func testMovieWithYearAndReleaseTags() {
        let parsed = MediaFilenameParser.parse(filename: "Big.Buck.Bunny.2008.1080p.BluRay.x264-GROUP.mkv")
        XCTAssertEqual(parsed?.title, "Big Buck Bunny")
        XCTAssertEqual(parsed?.year, 2008)
        XCTAssertNil(parsed?.season)
        XCTAssertNil(parsed?.episode)
        XCTAssertFalse(parsed?.isSeries ?? true)
    }

    func testMovieWithParenthesizedYear() {
        let parsed = MediaFilenameParser.parse(filename: "The Big Lebowski (1998) 1080p BluRay x264-GROUP.mkv")
        XCTAssertEqual(parsed?.title, "The Big Lebowski")
        XCTAssertEqual(parsed?.year, 1998)
    }

    /// A title that itself starts with a year-like number must not be
    /// truncated to nothing — the cut only ever considers words after the
    /// first.
    func testTitleStartingWithYearLikeNumberIsNotTruncatedToEmpty() {
        let parsed = MediaFilenameParser.parse(filename: "2001.A.Space.Odyssey.1968.1080p.mkv")
        XCTAssertEqual(parsed?.title, "2001 A Space Odyssey")
        XCTAssertEqual(parsed?.year, 1968)
    }

    func testSeriesSxxEyyPattern() {
        let parsed = MediaFilenameParser.parse(filename: "Show.Name.S02E05.WEB.mkv")
        XCTAssertEqual(parsed?.title, "Show Name")
        XCTAssertEqual(parsed?.season, 2)
        XCTAssertEqual(parsed?.episode, 5)
        XCTAssertTrue(parsed?.isSeries ?? false)
    }

    func testSeriesLowercaseSxxEyy() {
        let parsed = MediaFilenameParser.parse(filename: "show.name.s1e2.mkv")
        XCTAssertEqual(parsed?.title, "show name")
        XCTAssertEqual(parsed?.season, 1)
        XCTAssertEqual(parsed?.episode, 2)
    }

    func testSeries1x05Pattern() {
        let parsed = MediaFilenameParser.parse(filename: "Show Name 1x05 Episode Title.mkv")
        XCTAssertEqual(parsed?.title, "Show Name")
        XCTAssertEqual(parsed?.season, 1)
        XCTAssertEqual(parsed?.episode, 5)
    }

    /// A bare resolution string ("1920x1080") must never be misread as a
    /// 1920th season, episode 1080.
    func testDoesNotMisreadResolutionAsSeasonEpisode() {
        let parsed = MediaFilenameParser.parse(filename: "Movie.Name.2020.1920x1080.mkv")
        XCTAssertNil(parsed?.season)
        XCTAssertNil(parsed?.episode)
        XCTAssertEqual(parsed?.year, 2020)
    }

    func testFolderProvidesShowTitleAndSeasonWhenFilenameIsABareEpisodeNumber() {
        let parsed = MediaFilenameParser.parse(
            filename: "03 - The Long Way Around.mkv",
            parentPath: "TV Shows/Show Name/Season 02"
        )
        XCTAssertEqual(parsed?.title, "Show Name")
        XCTAssertEqual(parsed?.season, 2)
        XCTAssertEqual(parsed?.episode, 3)
    }

    func testFolderSeasonWithSpelledOutEpisodeInFilename() {
        let parsed = MediaFilenameParser.parse(filename: "Episode 5.mkv", parentPath: "Shows/My Show/Season 3")
        XCTAssertEqual(parsed?.title, "My Show")
        XCTAssertEqual(parsed?.season, 3)
        XCTAssertEqual(parsed?.episode, 5)
    }

    func testDropsSamplesAndTrailers() {
        XCTAssertNil(MediaFilenameParser.parse(filename: "movie-sample.mkv"))
        XCTAssertNil(MediaFilenameParser.parse(filename: "Movie.Trailer.mkv"))
    }

    func testHandlesUnderscoreSeparators() {
        let parsed = MediaFilenameParser.parse(filename: "Movie_Name_2019_1080p.mkv")
        XCTAssertEqual(parsed?.title, "Movie Name")
        XCTAssertEqual(parsed?.year, 2019)
    }

    /// Splitting only on `.` and ` ` (never `-`) must leave a hyphenated
    /// title like "Spider-Man" intact.
    func testPreservesInternalHyphenInTitle() {
        let parsed = MediaFilenameParser.parse(filename: "Spider-Man.Into.the.Spider-Verse.2018.1080p.mkv")
        XCTAssertEqual(parsed?.title, "Spider-Man Into the Spider-Verse")
        XCTAssertEqual(parsed?.year, 2018)
    }

    func testMinimumFileSizeConstant() {
        XCTAssertEqual(MediaFilenameParser.minimumFileSizeBytes, 50 * 1024 * 1024)
    }
}
