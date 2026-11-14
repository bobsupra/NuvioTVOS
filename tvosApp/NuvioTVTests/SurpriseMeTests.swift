import XCTest
@testable import NuvioTV

final class SurpriseMeTests: XCTestCase {
    private func movie(_ id: String, _ genres: [String], rating: Double? = nil) -> NuvioMeta {
        NuvioMeta(id: id, name: id, type: "movie", genres: genres, rating: rating)
    }

    func testProfileWeighsWatchedOverLibraryOverContinueWatching() {
        let profile = TasteProfile.build(
            watched: [movie("a", ["Sci-Fi"])],
            library: [movie("b", ["Comedy"])],
            continueWatching: [movie("c", ["Horror"])]
        )
        XCTAssertEqual(profile.topGenres, ["Sci-Fi", "Comedy", "Horror"])
        XCTAssertEqual(profile.weights["scifi"] ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(profile.weights["comedy"] ?? 0, 2.0 / 6.0, accuracy: 0.0001)
    }

    func testATitleCountsOncePerSource() {
        let episode = NuvioMeta(id: "show", name: "Show", type: "series", genres: ["Drama"])
        let profile = TasteProfile.build(
            watched: Array(repeating: episode, count: 50) + [movie("a", ["Action"])],
            library: [],
            continueWatching: []
        )
        XCTAssertEqual(profile.weights["drama"], profile.weights["action"])
    }

    func testEmptyHistoryGivesAnEmptyProfile() {
        XCTAssertTrue(TasteProfile.build(watched: [], library: [], continueWatching: []).isEmpty)
    }

    func testPickFavorsTheViewersGenres() {
        let profile = TasteProfile.build(
            watched: [movie("w1", ["Sci-Fi", "Action"]), movie("w2", ["Sci-Fi"])],
            library: [],
            continueWatching: []
        )
        let candidates = [
            movie("romcom", ["Romance", "Comedy"], rating: 9.5),
            movie("space", ["Sci-Fi"], rating: 7),
        ]
        let pick = SurpriseMe.pick(from: candidates, profile: profile, isWatched: { _ in false }, random: { 0 })
        XCTAssertEqual(pick?.id, "space")
        XCTAssertEqual(profile.matchingGenres(for: candidates[1]), ["Sci-Fi"])
    }

    func testPickSkipsWatchedSeriesAndAlreadyOffered() {
        let candidates = [
            movie("seen", ["Action"], rating: 9),
            NuvioMeta(id: "show", name: "Show", type: "series", genres: ["Action"], rating: 9),
            movie("offered", ["Action"], rating: 8),
            movie("fresh", ["Action"], rating: 5),
        ]
        let pick = SurpriseMe.pick(
            from: candidates,
            profile: .empty,
            isWatched: { $0.id == "seen" },
            excluding: ["offered"],
            random: { 0 }
        )
        XCTAssertEqual(pick?.id, "fresh")
    }

    func testWithoutHistoryTheBestRatedComesFirst() {
        let candidates = [movie("ok", ["Drama"], rating: 6), movie("great", ["Drama"], rating: 9)]
        XCTAssertEqual(
            SurpriseMe.pick(from: candidates, profile: .empty, isWatched: { _ in false }, random: { 0 })?.id,
            "great"
        )
    }

    func testOfferedTitlesComeBackWhenNothingElseIsLeft() {
        let candidates = [movie("only", ["Drama"])]
        XCTAssertEqual(
            SurpriseMe.pick(from: candidates, profile: .empty, isWatched: { _ in false }, excluding: ["only"])?.id,
            "only"
        )
        XCTAssertNil(SurpriseMe.pick(from: candidates, profile: .empty, isWatched: { _ in true }))
    }
}
