import XCTest
@testable import NuvioTV

/// AniList's and MAL's reviews of an anime in details (`AnimeReviews`).
final class AnimeReviewsTests: XCTestCase {
    func testAniListReviewsReadAsCardsWithTheirSummaryAndScore() {
        let json = #"""
        {"data":{"Media":{"id":154587,"reviews":{"nodes":[
          {"id":1,"summary":"A quiet masterpiece.","body":"__Great__ start.\nimg220(https://x/y.png)\n~!Himmel dies!~ and [the OP](https://youtu.be/x) is **fine**.",
           "score":92,"rating":120,"ratingAmount":130,"createdAt":1700000000,"user":{"name":"Ayaka"}},
          {"id":2,"summary":"  ","body":"","score":40,"rating":3,"ratingAmount":9,"createdAt":1700000000,"user":{"name":"Empty"}}
        ]}}}}
        """#
        let reviews = AnimeReviews.aniListReviews(from: Data(json.utf8))
        XCTAssertEqual(reviews.count, 1, "a review with no text is left out")
        let first = reviews[0]
        XCTAssertEqual(first.author, "Ayaka")
        XCTAssertEqual(first.summary, "A quiet masterpiece.")
        XCTAssertEqual(first.scoreText, "92%")
        XCTAssertEqual(first.likes, 120)
        XCTAssertEqual(first.createdAt, "2023-11-14")
        XCTAssertEqual(first.comment, "Great start.\n\n[Spoiler] and the OP is fine.")
    }

    func testMALReviewsComeMostLikedFirstWithTheirVerdict() {
        let json = #"""
        {"data":[
          {"mal_id":10,"review":"Fine.","score":6,"date":"2024-01-02T10:00:00+00:00","tags":["Mixed Feelings"],"is_spoiler":false,
           "reactions":{"overall":5},"user":{"username":"low"}},
          {"mal_id":11,"review":"Loved it.\r\nTruly.","score":9,"date":"2024-03-04T10:00:00+00:00","tags":["Recommended"],"is_spoiler":true,
           "reactions":{"overall":50},"user":{"username":"high"}},
          {"mal_id":12,"review":"   ","score":1,"reactions":{"overall":99},"user":{"username":"blank"}}
        ]}
        """#
        let reviews = AnimeReviews.malReviews(from: Data(json.utf8))
        XCTAssertEqual(reviews.map(\.author), ["high", "low"])
        XCTAssertEqual(reviews[0].comment, "Loved it.\nTruly.")
        XCTAssertEqual(reviews[0].scoreText, "9/10")
        XCTAssertEqual(reviews[0].tag, "Recommended")
        XCTAssertTrue(reviews[0].spoiler)
        XCTAssertEqual(reviews[0].likes, 50)
        XCTAssertEqual(reviews[0].createdAt, "2024-03-04T10:00:00+00:00")
    }

    func testReviewSettingsFollowTheirIntegrationUntilSwitched() {
        let store = UserDefaults(suiteName: "AnimeReviewsTests.settings")!
        store.removePersistentDomain(forName: "AnimeReviewsTests.settings")
        XCTAssertFalse(AnimeReviews.shows(SettingsKey.malReviews, MALSettings.isEnabled(in:), in: store))
        store.set(true, forKey: SettingsKey.malEnabled)
        XCTAssertTrue(AnimeReviews.shows(SettingsKey.malReviews, MALSettings.isEnabled(in:), in: store))
        store.set(false, forKey: SettingsKey.malReviews)
        XCTAssertFalse(AnimeReviews.shows(SettingsKey.malReviews, MALSettings.isEnabled(in:), in: store))
        store.set(false, forKey: SettingsKey.malEnabled)
        store.set(true, forKey: SettingsKey.malReviews)
        XCTAssertTrue(AnimeReviews.shows(SettingsKey.malReviews, MALSettings.isEnabled(in:), in: store), "works with MAL off")
    }
}
