import XCTest
@testable import NuvioTV

final class StreamListStyleTests: XCTestCase {
    func testTheDefaultsAreTheListAsItWas() {
        let style = StreamListStyle()
        let layout = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(layout.summaryWidth, 620)
        XCTAssertEqual(layout.panelWidth, 1920 * 0.56, accuracy: 0.001)
        XCTAssertEqual(layout.panelHeight, 720)
        XCTAssertEqual(layout.stackHeight, 838)
        XCTAssertTrue(layout.showsSummary)
        XCTAssertFalse(layout.showsHeader)
        XCTAssertEqual(style.font(34), 34)
        XCTAssertEqual(style.nameLines, 2)
        XCTAssertEqual(style.descriptionLines, 6)
        XCTAssertEqual(style.metrics.minHeight, 250)
        XCTAssertEqual(style.metrics.cardSpacing, 28)
    }

    func testWideNarrowsTheSummary() {
        var style = StreamListStyle()
        style.width = .wide
        let layout = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(layout.panelWidth, 1344)
        XCTAssertEqual(layout.summaryWidth, 376)
        XCTAssertTrue(layout.showsSummary)
    }

    func testFullPutsTheEpisodeAboveTheList() {
        var style = StreamListStyle()
        style.width = .full
        let layout = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(layout.panelWidth, 1792)
        XCTAssertFalse(layout.showsSummary)
        XCTAssertTrue(layout.showsHeader)
        XCTAssertEqual(layout.panelHeight, 720)
        XCTAssertEqual(layout.stackHeight, 90 + 112 + 720 + 40)

        style.height = .full
        let tall = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(tall.panelHeight, 750)
        XCTAssertEqual(tall.stackHeight, 1080 - 88)
        style.height = .standard

        style.episodeHeader = false
        let plain = style.layout(width: 1920, height: 1080)
        XCTAssertFalse(plain.showsHeader)
        XCTAssertFalse(plain.showsSummary)
        XCTAssertEqual(plain.panelHeight, 720)
    }

    func testTheTextScales() {
        var style = StreamListStyle()
        style.textScale = 60
        XCTAssertEqual(style.font(34), 20)
        style.textScale = 130
        XCTAssertEqual(style.font(34), 44)
        style.textScale = 50
        XCTAssertEqual(style.font(34), 17)
        style.textScale = 150
        XCTAssertEqual(style.font(34), 51)
        XCTAssertEqual(StreamListStyle.textScales.first, 50)
        XCTAssertEqual(StreamListStyle.textScales.last, 150)
    }

    func testTallAndFullHeightsUseMoreOfTheScreen() {
        var style = StreamListStyle()
        style.height = .tall
        let tall = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(tall.panelHeight, 820)
        XCTAssertTrue(tall.showsSummary)

        style.height = .full
        let full = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(full.panelHeight, 874)
        XCTAssertEqual(full.stackHeight, 1080 - 88)

        // A short screen never pushes the list off it.
        let short = style.layout(width: 1280, height: 720)
        XCTAssertEqual(short.panelHeight, 720 - 88 - 118)
    }

    func testDetailsBadgesAndLogoHaveTheirOwnSize() {
        var style = StreamListStyle()
        XCTAssertEqual(style.detailFont(26), 26)
        XCTAssertEqual(style.badgeScale, 1)
        XCTAssertEqual(style.metrics.logoSize, 96)

        style.detailSize = .small
        style.badgeSize = .large
        style.logoSize = .large
        XCTAssertEqual(style.detailFont(26), 22)
        XCTAssertEqual(style.badgeScale, 1.25, accuracy: 0.001)
        XCTAssertEqual(style.metrics.logoSize, 130)

        // They follow the text size too.
        style.textScale = 80
        style.detailSize = .large
        style.badgeSize = .small
        style.logoSize = .small
        XCTAssertEqual(style.detailFont(26), 24)
        XCTAssertEqual(style.badgeScale, 0.64, accuracy: 0.001)
        XCTAssertEqual(style.metrics.logoSize, 67)
        XCTAssertEqual(style.font(34), 27)
    }

    func testSpacingChangesTheLinesNotTheCards() {
        var style = StreamListStyle()
        XCTAssertEqual(style.metrics.lineSpacing, 14)
        XCTAssertEqual(style.detailLineSpacing, 5)
        style.spacing = .tight
        XCTAssertEqual(style.metrics.lineSpacing, 7)
        XCTAssertEqual(style.detailLineSpacing, 2.5, accuracy: 0.001)
        style.spacing = .loose
        XCTAssertEqual(style.metrics.lineSpacing, 22)
        XCTAssertEqual(style.detailLineSpacing, 8, accuracy: 0.001)
        XCTAssertEqual(style.metrics.cardSpacing, 28)
    }

    func testTheSummaryLine() {
        var style = StreamListStyle()
        XCTAssertEqual(style.summary, "Text 100 % · Default cards · Default width")
        style.textScale = 90
        style.cardSize = .compact
        style.width = .full
        style.height = .tall
        XCTAssertEqual(style.summary, "Text 90 % · Compact cards · Full width · Tall height")
    }

    func testStoredValuesOutsideTheChoicesFallBack() {
        let style = StreamListStyle(
            textScale: 75, cardSize: "huge", width: "giant",
            nameLines: 0, descriptionLines: 0, episodeHeader: false, expandFocused: true,
            detailSize: "tiny", badgeSize: "", logoSize: "xl", spacing: "wide", height: "max")
        XCTAssertEqual(style.textScale, 100)
        XCTAssertEqual(style.detailSize, .standard)
        XCTAssertEqual(style.badgeSize, .standard)
        XCTAssertEqual(style.logoSize, .standard)
        XCTAssertEqual(style.spacing, .standard)
        XCTAssertEqual(style.height, .standard)
        XCTAssertEqual(style.cardSize, .standard)
        XCTAssertEqual(style.width, .standard)
        XCTAssertNil(style.nameLines)
        XCTAssertNil(style.descriptionLines)
        XCTAssertTrue(style.expandFocused)
    }

    func testCompactCardsHaveNoMinimumHeight() {
        var style = StreamListStyle()
        style.cardSize = .compact
        XCTAssertEqual(style.metrics.minHeight, 0)
        XCTAssertLessThan(style.metrics.cardSpacing, StreamListStyle().metrics.cardSpacing)
    }

    func testTheSettingsLabelsGoBothWays() {
        XCTAssertEqual(StreamListStyle.textScaleLabel(115), "115 %")
        XCTAssertEqual(StreamListStyle.textScale(fromLabel: "115 %"), 115)
        XCTAssertEqual(StreamListStyle.linesLabel(0), "All")
        XCTAssertEqual(StreamListStyle.linesLabel(10), "10")
        XCTAssertEqual(StreamListStyle.lines(fromLabel: "All"), 0)
        XCTAssertEqual(StreamListStyle.lines(fromLabel: "3"), 3)
    }

    func testTheStyleIsReadFromTheProfileSettings() throws {
        let name = "StreamListStyleTests"
        let settings = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { settings.removePersistentDomain(forName: name) }
        XCTAssertEqual(StreamListStyle.current(in: settings), StreamListStyle())

        settings.set(80, forKey: SettingsKey.streamListTextScale)
        settings.set("compact", forKey: SettingsKey.streamListCardSize)
        settings.set("full", forKey: SettingsKey.streamListWidth)
        settings.set(0, forKey: SettingsKey.streamListDescriptionLines)
        settings.set(false, forKey: SettingsKey.streamListEpisodeHeader)
        settings.set("large", forKey: SettingsKey.streamListDetailSize)
        settings.set("small", forKey: SettingsKey.streamListBadgeSize)
        settings.set("large", forKey: SettingsKey.streamListLogoSize)
        settings.set("loose", forKey: SettingsKey.streamListSpacing)
        settings.set("tall", forKey: SettingsKey.streamListHeight)
        let style = StreamListStyle.current(in: settings)
        XCTAssertEqual(style.textScale, 80)
        XCTAssertEqual(style.cardSize, .compact)
        XCTAssertEqual(style.width, .full)
        XCTAssertEqual(style.nameLines, 2)
        XCTAssertNil(style.descriptionLines)
        XCTAssertFalse(style.episodeHeader)
        XCTAssertEqual(style.detailSize, .large)
        XCTAssertEqual(style.badgeSize, .small)
        XCTAssertEqual(style.logoSize, .large)
        XCTAssertEqual(style.spacing, .loose)
        XCTAssertEqual(style.height, .tall)
    }
}
