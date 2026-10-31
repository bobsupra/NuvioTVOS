import Foundation
import XCTest
@testable import NuvioTV

final class SeekrTrickplayTests: XCTestCase {
    func testTitlesFromNuvioIds() {
        XCTAssertEqual(SeekrTrickplay.title(contentId: "tt0133093", season: nil, episode: nil),
                       .movie(imdbID: "tt0133093", tmdbID: nil))
        XCTAssertEqual(SeekrTrickplay.title(contentId: " TT0944947 ", season: 1, episode: 5),
                       .episode(showIMDbID: "tt0944947", showTMDBID: nil, season: 1, episode: 5))
        XCTAssertEqual(SeekrTrickplay.title(contentId: "tt0944947:1:5", season: 1, episode: 5),
                       .episode(showIMDbID: "tt0944947", showTMDBID: nil, season: 1, episode: 5))
        XCTAssertEqual(SeekrTrickplay.title(contentId: "tmdb:603", season: nil, episode: nil),
                       .movie(imdbID: nil, tmdbID: 603))
        XCTAssertEqual(SeekrTrickplay.title(contentId: "tmdb:1399", season: 2, episode: 3),
                       .episode(showIMDbID: nil, showTMDBID: 1399, season: 2, episode: 3))
        XCTAssertNil(SeekrTrickplay.title(contentId: "kitsu:1", season: nil, episode: nil))
        XCTAssertNil(SeekrTrickplay.title(contentId: "tt", season: nil, episode: nil))
        XCTAssertNil(SeekrTrickplay.title(contentId: nil, season: nil, episode: nil))
        // An episode number without a season is no episode.
        XCTAssertEqual(SeekrTrickplay.title(contentId: "tt0133093", season: nil, episode: 4),
                       .movie(imdbID: "tt0133093", tmdbID: nil))
    }

    func testLookupURLSendsOneIdentifierAndTheLength() throws {
        let movie = try XCTUnwrap(SeekrTrickplay.lookupURL(
            for: .movie(imdbID: "tt0133093", tmdbID: 603), durationMs: 8_280_000))
        XCTAssertEqual(movie.absoluteString, "https://api.seekr.tv/sprites?duration_ms=8280000&imdb_id=tt0133093")

        let episode = try XCTUnwrap(SeekrTrickplay.lookupURL(
            for: .episode(showIMDbID: nil, showTMDBID: 1399, season: 1, episode: 5), durationMs: 3_300_000))
        XCTAssertEqual(episode.absoluteString,
                       "https://api.seekr.tv/sprites?duration_ms=3300000&show_tmdb_id=1399&season=1&episode=5")

        XCTAssertNil(SeekrTrickplay.lookupURL(for: .movie(imdbID: "tt0133093", tmdbID: nil), durationMs: 0))
        XCTAssertNil(SeekrTrickplay.lookupURL(for: .movie(imdbID: nil, tmdbID: nil), durationMs: 1_000))
    }

    func testLookupAnswer() throws {
        let body = Data("""
        {"media_type":"movie","tmdb_id":603,"title":"The Matrix",
         "vtt_url":"https://sprites.seekr.tv/603/8280000/thumbnails.vtt?exp=1749123456&sig=abc123",
         "source_duration_ms":8280000,"scale":1.0}
        """.utf8)
        let lookup = try XCTUnwrap(SeekrTrickplay.parseLookup(body))
        XCTAssertEqual(lookup.vttURL.host, "sprites.seekr.tv")
        XCTAssertEqual(lookup.scale, 1)
        XCTAssertEqual(lookup.expiresAt, Date(timeIntervalSince1970: 1_749_123_456))

        let scaled = try XCTUnwrap(SeekrTrickplay.parseLookup(Data(#"{"vtt_url":"https://s.example/t.vtt","scale":1.25}"#.utf8)))
        XCTAssertEqual(scaled.scale, 1.25)
        XCTAssertNil(scaled.expiresAt)
        let zero = try XCTUnwrap(SeekrTrickplay.parseLookup(Data(#"{"vtt_url":"https://s.example/t.vtt","scale":0}"#.utf8)))
        XCTAssertEqual(zero.scale, 1, "a scale that can't be one keeps the timeline")

        XCTAssertNil(SeekrTrickplay.parseLookup(Data(#"{"error":"not found"}"#.utf8)))
        XCTAssertNil(SeekrTrickplay.parseLookup(Data(#"{"vtt_url":"file:///etc/x.vtt"}"#.utf8)))
    }

    func testPositionsOnTheSpritesTimeline() {
        // scale = played length / source length, so the source position is the played one over it.
        XCTAssertEqual(SeekrTrickplay.sourceSeconds(100, scale: 1.25), 80)
        XCTAssertEqual(SeekrTrickplay.sourceSeconds(100, scale: 1), 100)
        XCTAssertEqual(SeekrTrickplay.sourceSeconds(100, scale: 0), 100)
        XCTAssertEqual(SeekrTrickplay.sourceSeconds(100, scale: .nan), 100)
    }

    func testRetryAfter() {
        XCTAssertEqual(SeekrTrickplay.retryAfter("30"), 30)
        XCTAssertEqual(SeekrTrickplay.retryAfter(" 5 "), 5)
        XCTAssertEqual(SeekrTrickplay.retryAfter("0"), 1)
        XCTAssertEqual(SeekrTrickplay.retryAfter(nil), 60)
        XCTAssertEqual(SeekrTrickplay.retryAfter("soon"), 60)
    }

    func testSeekrVTTReadsAsAStoryboard() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:10.000
        https://sprites.seekr.tv/603/8280000/sheet_001.jpg?exp=1749123456&sig=abc123#xywh=0,0,320,180

        00:00:10.000 --> 00:00:20.000
        https://sprites.seekr.tv/603/8280000/sheet_001.jpg?exp=1749123456&sig=abc123#xywh=320,0,320,180
        """
        let base = URL(string: "https://sprites.seekr.tv/603/8280000/thumbnails.vtt?exp=1749123456&sig=abc123")!
        XCTAssertNotNil(WebVTTStoryboardProvider.parse(vttContent: vtt, baseURL: base))
    }
}
