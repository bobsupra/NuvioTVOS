import XCTest
@testable import NuvioTV

final class IPTVChannelFilterTests: XCTestCase {
    func testSearchAndGroupAreAppliedTogether() {
        XCTAssertTrue(IPTVChannelFilter.matches(name: "News World", group: "News", query: "world", selectedGroup: "News"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "News World", group: "News", query: "world", selectedGroup: "Sports"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "News World", group: "News", query: "sports", selectedGroup: nil))
        XCTAssertTrue(IPTVChannelFilter.matches(name: "News World", group: nil, query: "  ", selectedGroup: nil))
    }

    func testSearchMatchesCurrentProgrammeTitle() {
        XCTAssertTrue(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "NASCAR", selectedGroup: nil, currentProgrammeTitle: "NASCAR Cup Series"))
        XCTAssertTrue(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "  nascar  ", selectedGroup: nil, currentProgrammeTitle: "NASCAR Cup Series"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "NASCAR", selectedGroup: nil))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "NASCAR", selectedGroup: "News", currentProgrammeTitle: "NASCAR Cup Series"))
    }

    func testSportsEventTitlesAreCaseInsensitiveAndTokenAware() {
        for title in ["NFL: Seahawks vs. Rams", "MLB Mariners at Yankees", "NHL Hockey", "Ice Hockey", "Live MMA", "PWHL Game", "NASCAR Cup Series", "UFC Fight Night", "Premier League", "UEFA Champions League", "Formula 1 Grand Prix"] {
            XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle(title), title)
        }
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("The NFL Network"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("Footballish drama"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("NCIS"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("Winter Storm Warning"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("Winter Storm at 6"))
    }

    func testSportsListingsExcludeStudioAndRecordedContent() {
        for title in ["NFL GameDay Studio", "NFL Live", "MLB Tonight", "MLB News", "NHL Highlights", "NASCAR Replay", "NASCAR Race Hub", "UFC Recap"] {
            XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle(title), title)
        }
        XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle("Seahawks vs. Rams"))
        XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle("Seattle Mariners at Boston"))
        XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle("Seattle Storm vs. Las Vegas Aces"))
    }
}
