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

    func testMetadataProviderChangePreservesSeasonAndEpisode() {
        let original = episodes(season: 7, numbers: 1...20)
        let replacement = (1...20).map { number in
            NuvioVideo(
                id: "tmdb:123:7:\(number)",
                title: "Enriched episode \(number)",
                season: 7,
                episode: number
            )
        }

        XCTAssertEqual(
            TvDetailsEpisodeIndex.reconciled(
                previousEpisodes: original,
                updatedEpisodes: replacement,
                index: 17
            ),
            17
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

    func testLargeSeriesWindowRemainsBoundedWhenFocusRestoredDeepInSeason() {
        let indices = TvDetailsEpisodeIndex.windowIndices(
            totalEpisodes: 1200,
            scrollIndex: 0,
            targetIndex: 950,
            visibleCardCount: 6
        )

        // Must NOT expand across the entire 0...950 range (which previously materialized 951 cards)
        XCTAssertLessThanOrEqual(indices.count, 15)
        XCTAssertEqual(indices.first, 946)
        XCTAssertEqual(indices.last, 958)
        XCTAssertTrue(indices.contains(950))
    }

    func testLargeSeriesWindowClampingAtBoundaries() {
        let startIndices = TvDetailsEpisodeIndex.windowIndices(
            totalEpisodes: 1200,
            scrollIndex: 0,
            targetIndex: nil,
            visibleCardCount: 6
        )
        XCTAssertEqual(startIndices.first, 0)
        XCTAssertEqual(startIndices.last, 8)

        let endIndices = TvDetailsEpisodeIndex.windowIndices(
            totalEpisodes: 1200,
            scrollIndex: 1199,
            targetIndex: nil,
            visibleCardCount: 6
        )
        XCTAssertEqual(endIndices.first, 1195)
        XCTAssertEqual(endIndices.last, 1199)
    }

    func testReleaseDateCacheHandlesOverThousandEpisodes() {
        // Verify parsing 1200 distinct episode release dates works smoothly with the enlarged cache
        for episodeNum in 1...1200 {
            let day = (episodeNum % 28) + 1
            let month = ((episodeNum / 28) % 12) + 1
            let dateStr = String(format: "2020-%02d-%02dT00:00:00.000Z", month, day)
            XCTAssertTrue(EpisodeReleasePolicy.hasAired(dateStr))
        }
    }
}
