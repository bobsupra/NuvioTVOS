import XCTest
@testable import NuvioTV

final class SMBLibraryResolverTests: XCTestCase {

    // MARK: - Title Normalization

    func testNormalizeTitleCollapsesPunctuationAndWhitespace() {
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Dune: Part Two"), "duneparttwo")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Dune Part Two"), "duneparttwo")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("2001: A Space Odyssey"), "2001aspaceodyssey")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("2001 A Space Odyssey"), "2001aspaceodyssey")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Top Gun: Maverick"), "topgunmaverick")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Top Gun Maverick"), "topgunmaverick")
    }

    func testNormalizeTitleHandlesApostrophesAndQuotes() {
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Carlito's Way"), "carlitosway")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Carlito’s Way"), "carlitosway")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Carlitos Way"), "carlitosway")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Schindler's List"), "schindlerslist")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Schindlers List"), "schindlerslist")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("\"Heroes\""), "heroes")
    }

    func testNormalizeTitleNormalizesAmpersandsToAnd() {
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Fast & Furious"), "fastandfurious")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Fast and Furious"), "fastandfurious")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Fast&Furious"), "fastandfurious")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Fast &amp; Furious"), "fastandfurious")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Zack & Miri Make a Porno"), "zackandmirimakeaporno")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Zack and Miri Make a Porno"), "zackandmirimakeaporno")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("D&D"), "dandd")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("D and D"), "dandd")
    }

    func testNormalizeTitleFoldsDiacriticsAndHyphens() {
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Amélie"), "amelie")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Amelie"), "amelie")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Léon: The Professional"), "leontheprofessional")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Leon The Professional"), "leontheprofessional")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("WALL·E"), "walle")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("WALL-E"), "walle")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("WALL E"), "walle")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Spider-Man: No Way Home"), "spidermannowayhome")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Spider Man No Way Home"), "spidermannowayhome")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Face/Off"), "faceoff")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Face Off"), "faceoff")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("Airplane!"), "airplane")
    }

    func testNormalizeTitleEmptyOrPunctuationOnlyYieldsEmpty() {
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle(""), "")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("   "), "")
        XCTAssertEqual(SMBLibraryResolver.normalizeTitle("---:;!"), "")
    }

    // MARK: - Scoring & Resolution

    func testScoreMatchesDunePartTwoWithMissingColon() {
        let meta = NuvioMeta(id: "tt15239678", name: "Dune: Part Two", type: "movie", year: 2024)
        let query = SMBLibraryResolver.QueryKey(title: "Dune Part Two", year: 2024, isSeries: false)

        let score = SMBLibraryResolver.score(meta: meta, query: query)
        // 60 base + 30 same type + 20 exact year = 110
        XCTAssertEqual(score, 110)
        XCTAssertGreaterThanOrEqual(score, SMBLibraryResolver.minimumScore)
    }

    func testScoreMatches2001ASpaceOdysseyWithMissingColon() {
        let meta = NuvioMeta(id: "tt0062622", name: "2001: A Space Odyssey", type: "movie", year: 1968)
        let query = SMBLibraryResolver.QueryKey(title: "2001 A Space Odyssey", year: 1968, isSeries: false)

        let score = SMBLibraryResolver.score(meta: meta, query: query)
        XCTAssertEqual(score, 110)
        XCTAssertGreaterThanOrEqual(score, SMBLibraryResolver.minimumScore)
    }

    func testScoreMatchesTopGunMaverickWithMissingColon() {
        let meta = NuvioMeta(id: "tt1745960", name: "Top Gun: Maverick", type: "movie", year: 2022)
        let query = SMBLibraryResolver.QueryKey(title: "Top Gun Maverick", year: 2022, isSeries: false)

        let score = SMBLibraryResolver.score(meta: meta, query: query)
        XCTAssertEqual(score, 110)
        XCTAssertGreaterThanOrEqual(score, SMBLibraryResolver.minimumScore)
    }

    func testScoreMatchesCarlitosWayWithMissingApostrophe() {
        let meta = NuvioMeta(id: "tt0106519", name: "Carlito's Way", type: "movie", year: 1993)
        let query = SMBLibraryResolver.QueryKey(title: "Carlitos Way", year: 1993, isSeries: false)

        let score = SMBLibraryResolver.score(meta: meta, query: query)
        XCTAssertEqual(score, 110)
        XCTAssertGreaterThanOrEqual(score, SMBLibraryResolver.minimumScore)
    }

    func testScoreMatchesAmpersandEquivalents() {
        let meta = NuvioMeta(id: "tt1013752", name: "Fast & Furious", type: "movie", year: 2009)
        let query = SMBLibraryResolver.QueryKey(title: "Fast and Furious", year: 2009, isSeries: false)

        let score = SMBLibraryResolver.score(meta: meta, query: query)
        XCTAssertEqual(score, 110)
        XCTAssertGreaterThanOrEqual(score, SMBLibraryResolver.minimumScore)
    }

    func testScoreRejectsPrefixMatches() {
        // "Dune" must NOT match "Dune: Part Two"
        let meta = NuvioMeta(id: "tt15239678", name: "Dune: Part Two", type: "movie", year: 2024)
        let query = SMBLibraryResolver.QueryKey(title: "Dune", year: 2024, isSeries: false)

        let score = SMBLibraryResolver.score(meta: meta, query: query)
        XCTAssertEqual(score, 0)
    }

    func testScoreRejectsSequelsAndDifferentTitles() {
        let meta = NuvioMeta(id: "tt0078748", name: "Alien", type: "movie", year: 1979)
        let query = SMBLibraryResolver.QueryKey(title: "Aliens", year: 1979, isSeries: false)

        let score = SMBLibraryResolver.score(meta: meta, query: query)
        XCTAssertEqual(score, 0)
    }

    func testScoreDistinguishesMovieFromSeriesWithSameTitle() {
        let movieMeta = NuvioMeta(id: "tt0116282", name: "Fargo", type: "movie", year: 1996)
        let seriesMeta = NuvioMeta(id: "tt2802850", name: "Fargo", type: "series", year: 2014)

        let movieQuery = SMBLibraryResolver.QueryKey(title: "Fargo", year: 1996, isSeries: false)
        let seriesQuery = SMBLibraryResolver.QueryKey(title: "Fargo", year: 2014, isSeries: true)

        let movieToMovieScore = SMBLibraryResolver.score(meta: movieMeta, query: movieQuery)
        let seriesToMovieScore = SMBLibraryResolver.score(meta: seriesMeta, query: movieQuery)

        XCTAssertEqual(movieToMovieScore, 110) // 60 + 30 + 20
        XCTAssertLessThan(seriesToMovieScore, SMBLibraryResolver.minimumScore)

        let seriesToSeriesScore = SMBLibraryResolver.score(meta: seriesMeta, query: seriesQuery)
        let movieToSeriesScore = SMBLibraryResolver.score(meta: movieMeta, query: seriesQuery)

        XCTAssertEqual(seriesToSeriesScore, 110)
        XCTAssertLessThan(movieToSeriesScore, SMBLibraryResolver.minimumScore)
    }

    func testScoreYearProximityRefinement() {
        let metaExact = NuvioMeta(id: "tt1", name: "Example Movie", type: "movie", year: 2020)
        let metaOneOff = NuvioMeta(id: "tt2", name: "Example Movie", type: "movie", year: 2021)
        let metaFarOff = NuvioMeta(id: "tt3", name: "Example Movie", type: "movie", year: 2010)

        let query = SMBLibraryResolver.QueryKey(title: "Example Movie", year: 2020, isSeries: false)

        XCTAssertEqual(SMBLibraryResolver.score(meta: metaExact, query: query), 110) // 60 + 30 + 20
        XCTAssertEqual(SMBLibraryResolver.score(meta: metaOneOff, query: query), 95)  // 60 + 30 + 5
        XCTAssertEqual(SMBLibraryResolver.score(meta: metaFarOff, query: query), 75)  // 60 + 30 - 15
    }

    func testMediaFilenameParserTrimsEdgePunctuation() {
        let parsed = MediaFilenameParser.parse(filename: "Dune - Part Two - 2024.1080p.mkv")
        XCTAssertEqual(parsed?.title, "Dune - Part Two")
        XCTAssertEqual(parsed?.year, 2024)
    }
}
