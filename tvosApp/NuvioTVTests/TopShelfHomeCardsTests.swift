import Foundation
import XCTest
@testable import NuvioTV

final class TopShelfHomeCardsTests: XCTestCase {
    func testHomeScreenCardsDefaultToContinueWatching() {
        let configuration = TopShelfConfiguration.default
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.style, .featuredCards)
        XCTAssertEqual(configuration.homeScreenRowID, "continueWatching")
        let feeds = makeFeeds()
        XCTAssertEqual(TopShelfComposer.rows(configuration: configuration) { feeds[$0] }.map(\.id),
                       ["continueWatching"])
    }

    func testDisabledCardsReturnNoRowsWithoutReadingFeeds() {
        var configuration = TopShelfConfiguration.default
        configuration.isEnabled = false
        XCTAssertTrue(TopShelfComposer.rows(configuration: configuration) { _ in
            XCTFail("Disabled cards must not load feeds")
            return nil
        }.isEmpty)
    }

    func testHomeScreenRowSelectionIsExclusiveAndDoesNotSubstituteMissingCatalogs() {
        let feeds = makeFeeds()
        var configuration = TopShelfConfiguration.default
        configuration.homeScreenRowID = "catalog:trending"
        XCTAssertEqual(TopShelfComposer.rows(configuration: configuration) { feeds[$0] }.map(\.id),
                       ["catalog:trending"])
        configuration.homeScreenRowID = "catalog:removed"
        XCTAssertTrue(TopShelfComposer.rows(configuration: configuration) { feeds[$0] }.isEmpty)
    }

    func testFeaturedLayoutUsesOneHeroAndTheRemainingPosters() {
        let titles = entries("featured", count: 4)
        let sections = TopShelfComposer.featuredSections(from: [row("catalog:popular", titles)])
        XCTAssertEqual(sections.map { $0.entries.count }, [1, 3])
        XCTAssertEqual(sections.first?.title, "Featured")
        XCTAssertEqual(sections.flatMap(\.entries).map(\.contentId), titles.map(\.contentId))
        XCTAssertTrue(TopShelfComposer.featuredSections(from: []).isEmpty)
        XCTAssertEqual(TopShelfComposer.featuredSections(from: [row("continueWatching", Array(titles.prefix(1)))]).count, 1)
    }

    func testHomeScreenChoicesRoundTripAndOlderChoicesStayCompatible() throws {
        var configuration = TopShelfConfiguration.default
        configuration.isEnabled = false
        configuration.homeScreenRowID = "catalog:trending"
        let decoded = try JSONDecoder().decode(TopShelfConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        let legacy = try JSONDecoder().decode(TopShelfConfiguration.self,
            from: Data(#"{"style":"posters","includesLibrary":false,"catalogRowIDs":["popular"]}"#.utf8))
        XCTAssertTrue(legacy.isEnabled)
        XCTAssertNil(legacy.homeScreenRowID)
        XCTAssertEqual(legacy.style, .posters)
        XCTAssertEqual(legacy.catalogRowIDs, ["popular"])
    }

    func testUntouchedOldDefaultMigratesButCustomLayoutsAndDisabledCardsDoNot() throws {
        var legacy = TopShelfConfiguration()
        legacy.starringLabel = "Cast"
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        fields.removeValue(forKey: "isEnabled")
        let oldData = try JSONSerialization.data(withJSONObject: fields)
        let upgraded = TopShelfConfigurationStore.migratingUntouchedDefaults(legacy, data: oldData)
        XCTAssertEqual(upgraded.homeScreenRowID, "continueWatching")
        XCTAssertEqual(upgraded.style, .featuredCards)
        XCTAssertEqual(upgraded.starringLabel, "Cast")
        legacy.style = .posters
        XCTAssertEqual(TopShelfConfigurationStore.migratingUntouchedDefaults(legacy, data: oldData), legacy)
        var disabled = TopShelfConfiguration.default
        disabled.isEnabled = false
        let newData = try JSONEncoder().encode(disabled)
        XCTAssertEqual(TopShelfConfigurationStore.migratingUntouchedDefaults(disabled, data: newData), disabled)
    }

    func testInAppLabelsFollowFocusAndHiddenAlwaysWins() {
        XCTAssertTrue(CardLabelVisibility.always.isVisible(isFocused: false))
        XCTAssertTrue(CardLabelVisibility.always.isVisible(isFocused: true))
        XCTAssertFalse(CardLabelVisibility.focused.isVisible(isFocused: false))
        XCTAssertTrue(CardLabelVisibility.focused.isVisible(isFocused: true))
        XCTAssertFalse(CardLabelVisibility.hidden.isVisible(isFocused: false))
        XCTAssertFalse(CardLabelVisibility.hidden.isVisible(isFocused: true))
    }

    func testTopShelfLabelsDefaultToHiddenAndUseOriginalArtwork() throws {
        XCTAssertFalse(TopShelfConfiguration.default.showsEpisodeLabels)
        let entry = TopShelfEntry(contentId: "show", contentType: "series", title: "Show",
            subtitle: "S4 E15 · 15m left", imageURL: "https://example.com/poster.jpg",
            backdropURL: "https://example.com/backdrop.jpg", progress: 0.5, action: .details)
        XCTAssertEqual(TopShelfFeedStore.sectionedArtworkURL(for: entry, poster: true,
            showsEpisodeLabels: false)?.absoluteString, entry.posterSourceURL)
        XCTAssertEqual(TopShelfFeedStore.sectionedArtworkURL(for: entry, poster: false,
            showsEpisodeLabels: false)?.absoluteString, entry.cardSourceURL)
        var configuration = TopShelfConfiguration.default
        configuration.showsEpisodeLabels = true
        let decoded = try JSONDecoder().decode(TopShelfConfiguration.self,
            from: JSONEncoder().encode(configuration))
        XCTAssertTrue(decoded.showsEpisodeLabels)
    }

    private func makeFeeds() -> [TopShelfSection: TopShelfFeed] {
        [
            .continueWatching: TopShelfFeed(entries: entries("cw", count: 4), title: "Continue Watching"),
            .upNext: TopShelfFeed(entries: entries("next", count: 2), title: "Up Next"),
            .library: TopShelfFeed(entries: entries("lib", count: 5), title: "Library"),
            .catalog: TopShelfFeed(entries: [], rows: [
                TopShelfFeedRow(id: "popular", title: "Popular", entries: entries("pop", count: 15)),
                TopShelfFeedRow(id: "empty", title: "Empty", entries: []),
                TopShelfFeedRow(id: "trending", title: "Trending", entries: entries("trend", count: 15)),
            ]),
        ]
    }

    private func row(_ id: String, _ entries: [TopShelfEntry]) -> TopShelfRow {
        TopShelfRow(id: id, section: id.hasPrefix("catalog") ? .catalog : .continueWatching, title: id, entries: entries)
    }

    private func entries(_ prefix: String, count: Int) -> [TopShelfEntry] {
        (0..<count).map { entry("\(prefix)-\($0)") }
    }

    private func posterEntry(_ id: String, poster: String?, backdrop: String? = nil,
                             subtitle: String? = nil) -> TopShelfEntry {
        TopShelfEntry(contentId: id, contentType: "movie", title: id, subtitle: subtitle, imageURL: poster,
                      backdropURL: backdrop, progress: nil, action: .details)
    }

    private func entry(_ id: String) -> TopShelfEntry {
        TopShelfEntry(contentId: id, contentType: "movie", title: id, subtitle: nil, imageURL: nil,
                      progress: nil, action: .details)
    }
}
