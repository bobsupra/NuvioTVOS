import XCTest
@testable import NuvioTV

final class DetailsLargeSeriesEpisodeIndexTests: XCTestCase {
    private func episodes(season: Int, numbers: ClosedRange<Int>) -> [NuvioVideo] {
        numbers.map { number in
            NuvioVideo(
                id: "onepiece:\(season):\(number)",
                title: "Episode \(number)",
                season: season,
                episode: number
            )
        }
    }

    func testHugeSeasonShrinkingKeepsTheRailInBounds() {
        let oldEpisodes = episodes(season: 1, numbers: 1...1200)
        let newEpisodes = episodes(season: 1, numbers: 1...10)

        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: oldEpisodes,
                updatedEpisodes: newEpisodes,
                index: 1199
            ),
            9
        )
    }

    func testMetadataInsertionPreservesFocusedEpisodeIdentity() {
        let oldEpisodes = episodes(season: 1, numbers: 10...20)
        let updatedEpisodes = episodes(season: 1, numbers: 1...20)

        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: oldEpisodes,
                updatedEpisodes: updatedEpisodes,
                index: 5
            ),
            14
        )
    }

    func testMetadataUpdateReordersSameEpisodeWithoutJumpingToWrongCard() {
        let oldEpisodes = episodes(season: 1, numbers: 1...3)
        let newEpisodes = [oldEpisodes[2], oldEpisodes[0], oldEpisodes[1]]

        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: oldEpisodes,
                updatedEpisodes: newEpisodes,
                index: 2
            ),
            0
        )
    }

    func testNewSeasonStartsAtFirstEpisode() {
        let previousSeason = episodes(season: 1, numbers: 1...100)
        let nextSeason = episodes(season: 30, numbers: 1...40)

        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: previousSeason,
                updatedEpisodes: nextSeason,
                index: 0
            ),
            0
        )
    }

    func testEmptyOrInvalidIndicesAreSafe() {
        let previous = episodes(season: 1, numbers: 1...5)
        let updated = episodes(season: 1, numbers: 1...2)

        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: previous,
                updatedEpisodes: [],
                index: 4
            ),
            0
        )
        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: previous,
                updatedEpisodes: updated,
                index: -1
            ),
            0
        )
        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: previous,
                updatedEpisodes: updated,
                index: 99
            ),
            1
        )
    }
}
