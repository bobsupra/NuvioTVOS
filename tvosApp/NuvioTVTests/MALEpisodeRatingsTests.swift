import XCTest
@testable import NuvioTV

/// Each anime episode's MyAnimeList score from Tenrai (`MALEpisodeRatings`).
final class MALEpisodeRatingsTests: XCTestCase {
    private let frierenPage = Data("""
    {"pagination":{"last_visible_page":1,"has_next_page":false},
     "data":[
       {"mal_id":1,"title":"The Journey's End","score":4.29,"filler":false,"recap":false},
       {"mal_id":2,"title":"It Didn't Have to Be Magic…","score":4.32,"filler":false,"recap":false},
       {"mal_id":3,"title":"Nobody voted","score":0,"filler":false,"recap":false},
       {"mal_id":4,"title":"Not scored yet","score":null,"filler":false,"recap":false}
     ]}
    """.utf8)

    func testScoresAreReadByEpisodeAndUnvotedOnesLeftOut() {
        let scores = MALEpisodeRatings.scores(fromPage: frierenPage)
        XCTAssertEqual(scores, [1: 4.29, 2: 4.32])
        XCTAssertNil(MALEpisodeRatings.scores(fromPage: Data("not json".utf8)))
    }

    func testAPageHoldsAHundredEpisodes() {
        XCTAssertEqual(MALEpisodeRatings.page(of: 1), 1)
        XCTAssertEqual(MALEpisodeRatings.page(of: 100), 1)
        XCTAssertEqual(MALEpisodeRatings.page(of: 101), 2)
        XCTAssertEqual(MALEpisodeRatings.page(of: 1_105), 12)
        XCTAssertEqual(
            MALEpisodeRatings.url(for: .init(malID: 52991, page: 1)).absoluteString,
            "https://api.tenrai.org/v1/anime/52991/episodes"
        )
        XCTAssertEqual(
            MALEpisodeRatings.url(for: .init(malID: 21, page: 12)).absoluteString,
            "https://api.tenrai.org/v1/anime/21/episodes?page=12"
        )
    }

    func testCinemetaEpisodesAreReadFromTheirIds() {
        XCTAssertEqual(MALEpisodeRatings.cinemetaEpisode("tt0388629:2:5")?.imdb, "tt0388629")
        XCTAssertEqual(MALEpisodeRatings.cinemetaEpisode("tt0388629:2:5")?.season, 2)
        XCTAssertEqual(MALEpisodeRatings.cinemetaEpisode("tt0388629:2:5")?.episode, 5)
        XCTAssertNil(MALEpisodeRatings.cinemetaEpisode("tt0388629:0:1"), "specials aren't on MAL's list")
        XCTAssertNil(MALEpisodeRatings.cinemetaEpisode("tt0388629"))
        XCTAssertNil(MALEpisodeRatings.cinemetaEpisode("kitsu:1:5"))
    }

    func testTheMALIdComesFromAniList() {
        XCTAssertEqual(MALEpisodeRatings.malID(fromAniList: Data(#"{"data":{"Media":{"idMal":52991}}}"#.utf8)), 52991)
        XCTAssertNil(MALEpisodeRatings.malID(fromAniList: Data(#"{"data":{"Media":{"idMal":null}}}"#.utf8)))
    }

    func testScoresShowAsOnMAL() {
        let rating = MALEpisodeRatings.rating(4.76)
        XCTAssertEqual(rating.source, MALEpisodeRatings.source)
        XCTAssertEqual(rating.max, 5)
        XCTAssertEqual(MALEpisodeRatings.formatted(rating.value), "4.76")
        XCTAssertEqual(MALEpisodeRatings.formatted(4.7), "4.70")
    }

    func testTenraisAnswers() {
        XCTAssertEqual(MALEpisodeScoreStore.answer(status: 200, retryAfter: nil, data: frierenPage), .scores([1: 4.29, 2: 4.32]))
        XCTAssertEqual(MALEpisodeScoreStore.answer(status: 404, retryAfter: nil, data: Data()), .scores([:]))
        XCTAssertEqual(MALEpisodeScoreStore.answer(status: 429, retryAfter: "30", data: Data()), .wait(30))
        XCTAssertEqual(MALEpisodeScoreStore.answer(status: 429, retryAfter: nil, data: Data()), .wait(60))
        XCTAssertEqual(MALEpisodeScoreStore.answer(status: 500, retryAfter: nil, data: Data()), .failed)
        XCTAssertEqual(MALEpisodeScoreStore.answer(status: 200, retryAfter: nil, data: Data("<html>".utf8)), .failed)
    }

    func testAPageIsAskedOnceAndNothingWhileTenraiSaysToWait() async {
        let calls = Calls()
        let store = MALEpisodeScoreStore { url in
            await calls.add(url)
            return url.absoluteString.contains("/anime/1/") ? .scores([1: 4.32]) : .wait(120)
        }
        let start = Date()
        let first = await store.scores(for: .init(malID: 1, page: 1), now: start)
        let again = await store.scores(for: .init(malID: 1, page: 1), now: start.addingTimeInterval(60))
        XCTAssertEqual(first, [1: 4.32])
        XCTAssertEqual(again, [1: 4.32])
        let afterCalls = await calls.count
        XCTAssertEqual(afterCalls, 1)

        _ = await store.scores(for: .init(malID: 2, page: 1), now: start)
        _ = await store.scores(for: .init(malID: 3, page: 1), now: start.addingTimeInterval(10))
        let waitingCalls = await calls.count
        XCTAssertEqual(waitingCalls, 2, "while waiting, nothing new is asked")

        // Kept 12 hours.
        _ = await store.scores(for: .init(malID: 1, page: 1), now: start.addingTimeInterval(13 * 3600))
        let laterCalls = await calls.count
        XCTAssertEqual(laterCalls, 3)
    }
}

private actor Calls {
    private(set) var urls: [URL] = []
    var count: Int { urls.count }
    func add(_ url: URL) { urls.append(url) }
}
