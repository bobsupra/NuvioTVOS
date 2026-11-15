import XCTest
@testable import NuvioTV

final class PlexSkipMarkersTests: XCTestCase {
    private func marker(_ type: String, _ startMs: Int64, _ endMs: Int64, final: Bool? = nil) -> PlexClient.Marker {
        PlexClient.Marker(type: type, startTimeOffset: startMs, endTimeOffset: endMs, final: final)
    }

    func testDecodesMarkersFromMetadata() throws {
        let json = """
        {"MediaContainer":{"Metadata":[{"Marker":[
          {"id":517,"type":"credits","startTimeOffset":2798060,"endTimeOffset":2844512,"final":true},
          {"id":516,"type":"intro","startTimeOffset":61000,"endTimeOffset":120500}
        ]}]}}
        """
        struct Payload: Decodable {
            struct Container: Decodable { let Metadata: [Item]? }
            struct Item: Decodable { let Marker: [PlexClient.Marker]? }
            let MediaContainer: Container
        }
        let markers = try JSONDecoder().decode(Payload.self, from: Data(json.utf8)).MediaContainer.Metadata?.first?.Marker
        XCTAssertEqual(markers, [
            marker("credits", 2_798_060, 2_844_512, final: true),
            marker("intro", 61_000, 120_500)
        ])
    }

    func testEpisodeMarkersBecomeIntroAndEnding() {
        let intervals = PlexSkipMarkers.intervals(
            from: [marker("credits", 2_798_060, 2_844_512, final: true), marker("intro", 61_000, 120_500)],
            isMovie: false
        )
        XCTAssertEqual(intervals.map(\.type), ["intro", "credits"])
        XCTAssertEqual(intervals[0].startTime, 61, accuracy: 0.001)
        XCTAssertEqual(intervals[0].endTime, 120.5, accuracy: 0.001)
        XCTAssertTrue(intervals[0].isIntro)
        XCTAssertTrue(intervals[1].isEnding)
        XCTAssertEqual(Set(intervals.map(\.provider)), ["plex"])
    }

    func testMovieCreditsAndUnknownOrEmptyMarkers() {
        let intervals = PlexSkipMarkers.intervals(
            from: [marker("credits", 6_000_000, 6_300_000), marker("commercial", 10_000, 40_000), marker("intro", 5_000, 5_000)],
            isMovie: true
        )
        XCTAssertEqual(intervals.map(\.type), ["movie-credits"])
        XCTAssertTrue(intervals[0].isMovieCredits)
    }

    func testOnlyTheFinalCreditsAreTheEnding() {
        let intervals = PlexSkipMarkers.intervals(
            from: [marker("credits", 2_600_000, 2_700_000), marker("credits", 2_760_000, 2_840_000, final: true)],
            isMovie: false
        )
        XCTAssertEqual(intervals.map(\.type), [SkipInterval.creditsBeforeSceneType, "credits"])
        XCTAssertFalse(intervals[0].isEnding)
        XCTAssertEqual(intervals[0].label, "Skip Credits")
        XCTAssertTrue(intervals[1].isEnding)
    }

    func testWithoutAFinalFlagTheLastCreditsAreTheEnding() {
        let intervals = PlexSkipMarkers.intervals(
            from: [marker("credits", 6_500_000, 6_600_000), marker("credits", 6_000_000, 6_300_000)],
            isMovie: true
        )
        XCTAssertEqual(intervals.map(\.type), [SkipInterval.creditsBeforeSceneType, "movie-credits"])
    }

    func testFinalFlagDecodesFromANumber() throws {
        let json = #"[{"type":"credits","startTimeOffset":1,"endTimeOffset":2,"final":1},{"type":"intro","startTimeOffset":1,"endTimeOffset":2,"final":0}]"#
        let markers = try JSONDecoder().decode([PlexClient.Marker].self, from: Data(json.utf8))
        XCTAssertEqual(markers.map(\.final), [true, false])
    }

    func testPlexReplacesSameKindAndKeepsOtherKinds() {
        let plex = [
            SkipInterval(startTime: 61, endTime: 120, type: "intro", provider: "plex"),
            SkipInterval(startTime: 2798, endTime: 2844, type: "credits", provider: "plex")
        ]
        let others = [
            SkipInterval(startTime: 0, endTime: 30, type: "recap", provider: "introdb"),
            SkipInterval(startTime: 58, endTime: 118, type: "intro", provider: "introdb"),
            SkipInterval(startTime: 2790, endTime: 2840, type: "outro", provider: "introdb")
        ]
        let merged = PlexSkipMarkers.merged(plex: plex, others: others)
        XCTAssertEqual(merged.map(\.type), ["recap", "intro", "credits"])
        XCTAssertEqual(merged.map(\.provider), ["introdb", "plex", "plex"])
    }

    func testPlexCreditsStopAtAPostCreditsScene() {
        let plex = [SkipInterval(startTime: 6000, endTime: 6300, type: "movie-credits", provider: "plex")]
        let others = [SkipInterval(startTime: 6200, endTime: 6260, type: "post-credits", provider: "introdb")]
        let merged = PlexSkipMarkers.merged(plex: plex, others: others)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].type, "movie-credits")
        XCTAssertEqual(merged[0].endTime, 6200, accuracy: 0.001)
        XCTAssertTrue(merged[1].isPostCredits)
    }

    func testNoPlexMarkersLeavesOthersUntouched() {
        let others = [SkipInterval(startTime: 58, endTime: 118, type: "intro", provider: "introdb")]
        XCTAssertEqual(PlexSkipMarkers.merged(plex: [], others: others), others)
    }
}
