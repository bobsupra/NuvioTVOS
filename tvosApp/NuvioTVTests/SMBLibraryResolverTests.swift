import XCTest
@testable import NuvioTV

/// Exercises `SMBLibraryResolver.score` directly — the actual matching
/// heuristic — rather than `resolve(_:serverID:)`, which calls the live
/// Cinemeta API and has no place in a unit test.
final class SMBLibraryResolverTests: XCTestCase {
    private func makeMeta(name: String, type: String = "movie", year: Int? = nil) -> NuvioMeta {
        NuvioMeta(
            id: "tt0000000", name: name, description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: type, year: year, genres: nil, rating: nil,
            releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil,
            certification: nil, country: nil, released: nil, status: nil, videos: nil,
            trailerYtIds: nil, externalRatings: nil
        )
    }

    func testExactTitleYearAndTypeMatchClearsThreshold() {
        let meta = makeMeta(name: "Big Buck Bunny", type: "movie", year: 2008)
        let query = SMBLibraryResolver.QueryKey(title: "Big Buck Bunny", year: 2008, isSeries: false)
        XCTAssertGreaterThanOrEqual(SMBLibraryResolver.score(meta: meta, query: query), SMBLibraryResolver.minimumScore)
    }

    /// A movie file that happens to share a title with an unrelated series
    /// must not clear the threshold on title alone — wrong type is a strong
    /// signal against the match, even with the year lining up.
    func testWrongTypeFallsBelowThresholdDespiteExactTitleAndYear() {
        let meta = makeMeta(name: "The Office", type: "series", year: 2005)
        let query = SMBLibraryResolver.QueryKey(title: "The Office", year: 2005, isSeries: false)
        XCTAssertLessThan(SMBLibraryResolver.score(meta: meta, query: query), SMBLibraryResolver.minimumScore)
    }

    func testFarOffYearScoresLowerThanExactYear() {
        let query = SMBLibraryResolver.QueryKey(title: "Movie Title", year: 2020, isSeries: false)
        let farOff = SMBLibraryResolver.score(meta: makeMeta(name: "Movie Title", type: "movie", year: 1999), query: query)
        let exact = SMBLibraryResolver.score(meta: makeMeta(name: "Movie Title", type: "movie", year: 2020), query: query)
        XCTAssertLessThan(farOff, exact)
    }

    func testAdjacentYearScoresBetweenExactAndFarOff() {
        let query = SMBLibraryResolver.QueryKey(title: "Movie Title", year: 2020, isSeries: false)
        let exact = SMBLibraryResolver.score(meta: makeMeta(name: "Movie Title", type: "movie", year: 2020), query: query)
        let adjacent = SMBLibraryResolver.score(meta: makeMeta(name: "Movie Title", type: "movie", year: 2021), query: query)
        let farOff = SMBLibraryResolver.score(meta: makeMeta(name: "Movie Title", type: "movie", year: 1990), query: query)
        XCTAssertLessThan(adjacent, exact)
        XCTAssertGreaterThan(adjacent, farOff)
    }

    func testCompletelyDifferentTitleScoresZero() {
        let meta = makeMeta(name: "Totally Unrelated Thing", type: "movie", year: 2008)
        let query = SMBLibraryResolver.QueryKey(title: "Big Buck Bunny", year: 2008, isSeries: false)
        XCTAssertEqual(SMBLibraryResolver.score(meta: meta, query: query), 0)
    }

    func testPrefixMatchScoresLowerThanExactButAboveZero() {
        let query = SMBLibraryResolver.QueryKey(title: "Show Name", year: nil, isSeries: true)
        let exact = SMBLibraryResolver.score(meta: makeMeta(name: "Show Name", type: "series"), query: query)
        let prefix = SMBLibraryResolver.score(meta: makeMeta(name: "Show Name Extended", type: "series"), query: query)
        XCTAssertLessThan(prefix, exact)
        XCTAssertGreaterThan(prefix, 0)
    }

    /// No year to compare (a series episode's filename often has none) must
    /// not be treated as a year mismatch.
    func testNoQueryYearAppliesNoYearAdjustment() {
        let withYear = SMBLibraryResolver.QueryKey(title: "Some Show", year: nil, isSeries: true)
        let scoreWithMetaYear = SMBLibraryResolver.score(
            meta: makeMeta(name: "Some Show", type: "series", year: 2019),
            query: withYear
        )
        let scoreNoMetaYear = SMBLibraryResolver.score(
            meta: makeMeta(name: "Some Show", type: "series", year: nil),
            query: withYear
        )
        XCTAssertEqual(scoreWithMetaYear, scoreNoMetaYear)
    }
}
