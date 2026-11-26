import Foundation
import XCTest
@testable import NuvioTV

private let homeToday = CalendarDay(year: 2026, month: 10, day: 25)

private func makeEntry(
    _ itemId: String,
    kind: CalendarMediaKind = .series,
    tmdbId: Int,
    release: CalendarReleaseKind = .episode,
    season: Int? = 1,
    episode: Int? = 1,
    airTime: Date? = nil,
    on day: CalendarDay = homeToday
) -> CalendarEntry {
    var entry = CalendarEntry(
        itemId: itemId,
        itemType: kind == .series ? "series" : "movie",
        kind: kind,
        tmdbId: tmdbId,
        title: "Title \(itemId)",
        date: day,
        releaseKind: release,
        seasonNumber: kind == .series ? season : nil,
        episodeNumber: kind == .series ? episode : nil,
        episodeName: kind == .series ? "Episode name" : nil,
        posterURL: URL(string: "https://img/\(itemId).jpg"),
        stillURL: kind == .series ? URL(string: "https://img/\(itemId)-still.jpg") : nil
    )
    entry.airTime = airTime
    return entry
}

private func makeResult(_ entries: [CalendarEntry]) -> CalendarResult {
    let days = Dictionary(grouping: entries, by: \.date)
        .map { CalendarDaySection(date: $0.key, entries: $0.value) }
        .sorted { $0.date < $1.date }
    return CalendarResult(
        firstDay: homeToday.adding(days: -30),
        lastDay: homeToday.adding(days: 60),
        days: days,
        skipped: []
    )
}

final class CalendarHomeTodayTests: XCTestCase {
    private let time: (Date) -> String = { _ in "21:00" }

    func testOneCardPerTitleInTheCalendarsOrder() {
        let at = Date(timeIntervalSince1970: 1_792_950_000)
        let row = CalendarHomeToday.build(
            from: makeResult([
                makeEntry("tt1", tmdbId: 1, episode: 5, airTime: at),
                // The second half of a double episode.
                makeEntry("tt1", tmdbId: 1, episode: 6, airTime: at),
                makeEntry("kitsu:7", tmdbId: 7, season: 2, episode: 3),
                makeEntry("tt9", kind: .movie, tmdbId: 9, release: .digital),
                makeEntry("tt8", tmdbId: 8, on: homeToday.adding(days: 1)),
            ]),
            today: homeToday,
            hideSpoilers: false,
            time: time
        )
        XCTAssertEqual(row.metas.map(\.id), ["tt1", "kitsu:7", "tt9"])
        XCTAssertEqual(row.entries["tt1"]?.episodeNumber, 5)

        XCTAssertEqual(row.labels["tt1"], .init(
            episode: "S1E5", episodeTitle: "Episode name", badge: "21:00", artworkURL: "https://img/tt1-still.jpg"
        ))
        XCTAssertEqual(row.labels["kitsu:7"]?.episode, "S2E3")
        XCTAssertEqual(row.labels["kitsu:7"]?.badge, "AIRING TODAY")
        XCTAssertNil(row.labels["tt9"]?.episode)
        XCTAssertEqual(row.labels["tt9"]?.badge, CalendarFormat.releaseLabel(.digital))
    }

    func testCardsOpenTheLibraryTitle() {
        let row = CalendarHomeToday.build(
            from: makeResult([makeEntry("tt1", tmdbId: 1), makeEntry("tt9", kind: .movie, tmdbId: 9, release: .digital)]),
            today: homeToday,
            hideSpoilers: false,
            time: time
        )
        let series = row.metas[0]
        XCTAssertEqual(series.type, "series")
        XCTAssertEqual(series.imdbId, "tt1")
        XCTAssertEqual(series.tmdbId, 1)
        XCTAssertEqual(series.posterUrl, "https://img/tt1.jpg")
        // The episode's picture stays on the card, not in the hero.
        XCTAssertNil(series.backgroundUrl)
        XCTAssertEqual(row.metas[1].type, "movie")
    }

    func testCardsCarryShowBackdropWithoutLeakingEpisodeStill() {
        let entry = CalendarEntry(
            itemId: "tt1",
            itemType: "series",
            kind: .series,
            tmdbId: 1,
            title: "Show",
            date: homeToday,
            releaseKind: .episode,
            seasonNumber: 2,
            episodeNumber: 5,
            episodeName: "Spoiler Title",
            posterURL: URL(string: "https://img/poster.jpg"),
            stillURL: URL(string: "https://img/episode-still.jpg"),
            backdropURL: URL(string: "https://img/show-backdrop.jpg")
        )
        let row = CalendarHomeToday.build(
            from: makeResult([entry]),
            today: homeToday,
            hideSpoilers: true,
            time: time
        )
        XCTAssertEqual(row.metas.first?.backgroundUrl, "https://img/show-backdrop.jpg")
        XCTAssertNil(row.labels["tt1"]?.artworkURL)
    }

    func testCinemaReleasesAreLeftOut() {
        let row = CalendarHomeToday.build(
            from: makeResult([makeEntry("tt9", kind: .movie, tmdbId: 9, release: .theatrical)]),
            today: homeToday,
            hideSpoilers: false,
            time: time
        )
        XCTAssertTrue(row.isEmpty)
    }

    func testHiddenSpoilersDropTheEpisodesNameAndPicture() {
        let row = CalendarHomeToday.build(
            from: makeResult([makeEntry("tt1", tmdbId: 1)]),
            today: homeToday,
            hideSpoilers: true,
            time: time
        )
        XCTAssertEqual(row.labels["tt1"]?.episode, "S1E1")
        XCTAssertNil(row.labels["tt1"]?.episodeTitle)
        XCTAssertNil(row.labels["tt1"]?.artworkURL)
    }

    func testTheRowSettingIsSyncedAndResetWithTheOthers() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.homeCalendarToday))
    }

    func testNoCalendarMeansNoRow() {
        XCTAssertTrue(CalendarHomeToday.build(from: nil, today: homeToday, hideSpoilers: false, time: time).isEmpty)
    }

    func testWaitsUntilJustAfterMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Prague"))
        let lateEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 50)))
        XCTAssertEqual(CalendarHomeToday.secondsUntilTomorrow(from: lateEvening, calendar: calendar), 605, accuracy: 0.001)
        let almostMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 59, second: 59)))
        XCTAssertEqual(CalendarHomeToday.secondsUntilTomorrow(from: almostMidnight, calendar: calendar), 60, accuracy: 0.001)
        // The night the clocks go back has 25 hours.
        let dstNight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 0)))
        XCTAssertEqual(CalendarHomeToday.secondsUntilTomorrow(from: dstNight, calendar: calendar), 25 * 3600 + 5, accuracy: 0.001)
    }
}
