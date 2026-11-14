import XCTest
@testable import NuvioTV

@MainActor
final class EpisodeShuffleTests: XCTestCase {
    private let seriesID = "tt1"

    private func episodes(_ count: Int, season: Int = 1) -> [NuvioVideo] {
        (1...count).map { NuvioVideo(id: "tt1:\(season):\($0)", title: "E\($0)", season: season, episode: $0) }
    }

    func testShuffleIsOffUntilStarted() {
        let shuffle = EpisodeShuffle()
        XCTAssertFalse(shuffle.isActive(seriesID: seriesID))
        XCTAssertNil(shuffle.next(seriesID: seriesID, after: nil, episodes: episodes(3), isWatched: { _ in false }))
    }

    func testPlaysEveryEpisodeOnceBeforeRepeating() {
        let shuffle = EpisodeShuffle()
        let list = episodes(5)
        var played: [String] = []
        var current = shuffle.start(seriesID: seriesID, episodes: list, isWatched: { _ in false })
        while let episode = current, played.count < list.count {
            played.append(episode.id)
            current = shuffle.next(seriesID: seriesID, after: episode, episodes: list, isWatched: { _ in false })
        }
        XCTAssertEqual(Set(played), Set(list.map(\.id)))
        XCTAssertEqual(played.count, list.count)
        // A new round starts instead of ending shuffle.
        XCTAssertNotNil(current)
    }

    func testUpNextPickIsStableForTheSameEpisode() {
        let shuffle = EpisodeShuffle()
        let list = episodes(10)
        let first = shuffle.start(seriesID: seriesID, episodes: list, isWatched: { _ in false })
        let a = shuffle.next(seriesID: seriesID, after: first, episodes: list, isWatched: { _ in false })
        let b = shuffle.next(seriesID: seriesID, after: first, episodes: list, isWatched: { _ in false })
        XCTAssertEqual(a?.id, b?.id)
        XCTAssertNotEqual(a?.id, first?.id)
    }

    func testUnwatchedEpisodesComeFirst() {
        let shuffle = EpisodeShuffle(random: { 0 })
        let list = episodes(4)
        let watched: Set<String> = ["tt1:1:1", "tt1:1:2", "tt1:1:3"]
        let first = shuffle.start(seriesID: seriesID, episodes: list, isWatched: { watched.contains($0.id) })
        XCTAssertEqual(first?.id, "tt1:1:4")
    }

    func testSkipsSpecialsAndUnairedEpisodes() {
        let shuffle = EpisodeShuffle(random: { 0 })
        let list = [
            NuvioVideo(id: "tt1:0:1", title: "Special", season: 0, episode: 1),
            NuvioVideo(id: "tt1:1:1", title: "Future", season: 1, episode: 1, released: "2999-01-01"),
            NuvioVideo(id: "tt1:1:2", title: "Aired", season: 1, episode: 2, released: "2001-01-01"),
        ]
        XCTAssertEqual(shuffle.start(seriesID: seriesID, episodes: list, isWatched: { _ in false })?.id, "tt1:1:2")
    }

    func testShuffleIsOfferedOnlyForEpisodicShows() {
        // The Simpsons, The Office, Brooklyn Nine-Nine, a reality show
        XCTAssertTrue(EpisodeShuffle.suitsShuffle(genres: ["Animation", "Comedy"]))
        XCTAssertTrue(EpisodeShuffle.suitsShuffle(genres: ["Comedy"]))
        XCTAssertTrue(EpisodeShuffle.suitsShuffle(genres: ["Comedy", "Crime"]))
        XCTAssertTrue(EpisodeShuffle.suitsShuffle(genres: ["Reality-TV"]))
        XCTAssertTrue(EpisodeShuffle.suitsShuffle(genres: ["Talk Show"]))
        // Breaking Bad, Attack on Titan, a comedy-drama, unknown genres
        XCTAssertFalse(EpisodeShuffle.suitsShuffle(genres: ["Crime", "Drama", "Thriller"]))
        XCTAssertFalse(EpisodeShuffle.suitsShuffle(genres: ["Animation", "Action", "Drama"]))
        XCTAssertFalse(EpisodeShuffle.suitsShuffle(genres: ["Comedy", "Drama"]))
        XCTAssertFalse(EpisodeShuffle.suitsShuffle(genres: ["Animation", "Action"]))
        XCTAssertFalse(EpisodeShuffle.suitsShuffle(genres: nil))
    }

    func testStopEndsShuffle() {
        let shuffle = EpisodeShuffle()
        _ = shuffle.start(seriesID: seriesID, episodes: episodes(3), isWatched: { _ in false })
        XCTAssertTrue(shuffle.isActive(seriesID: seriesID))
        shuffle.stop(seriesID: seriesID)
        XCTAssertFalse(shuffle.isActive(seriesID: seriesID))
    }
}
