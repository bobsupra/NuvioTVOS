import Foundation
import XCTest
@testable import NuvioTV

private let sampleDay = CalendarDay(year: 2026, month: 10, day: 25)

private func makeEntry(
    _ itemId: String,
    kind: CalendarMediaKind = .series,
    tmdbId: Int,
    release: CalendarReleaseKind = .episode,
    season: Int? = 1,
    episode: Int? = 1,
    airTime: Date? = nil,
    on day: CalendarDay = sampleDay
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
        firstDay: sampleDay.adding(days: -30),
        lastDay: sampleDay.adding(days: 60),
        days: days,
        skipped: []
    )
}

final class CalendarSnapshotTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-snapshot-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func sample() -> CalendarResult {
        var timed = makeEntry("tt1", tmdbId: 1, airTime: Date(timeIntervalSince1970: 1_792_950_000))
        timed.airTimeSource = .tvmaze
        timed.isAnime = true
        var result = makeResult([timed, makeEntry("tt9", kind: .movie, tmdbId: 9, release: .digital)])
        result = CalendarResult(
            firstDay: result.firstDay,
            lastDay: result.lastDay,
            days: result.days,
            skipped: [
                CalendarSkippedItem(item: CalendarItem(id: "x:1", kind: .series), reason: .unsupportedId),
                CalendarSkippedItem(item: CalendarItem(id: "tt5", kind: .movie, name: "Five"), reason: .failed("timeout")),
            ],
            manualFollowKeys: ["series:1", "movie:9"],
            manualFollowItems: ["series:1": CalendarItem(id: "tt1", kind: .series, type: "series", name: "One")],
            automaticFollowItems: ["series:2": CalendarItem(id: "tt2", kind: .series, name: "Two")]
        )
        return result
    }

    func testRoundTrip() async throws {
        let store = CalendarSnapshotStore(url: url)
        let loadedAt = Date(timeIntervalSince1970: 1_792_900_000)
        let snapshot = CalendarSnapshot(settings: "profile|key", day: sampleDay, loadedAt: loadedAt, result: sample())
        await store.write(snapshot, sequence: 1)

        let stored = await CalendarSnapshotStore(url: url).read()
        let read = try XCTUnwrap(stored)
        XCTAssertEqual(read.day, sampleDay)
        XCTAssertEqual(read.loadedAt, loadedAt)
        XCTAssertEqual(read.result.days, sample().days)
        XCTAssertEqual(read.result.skipped, sample().skipped)
        XCTAssertEqual(read.result.manualFollowKeys, ["series:1", "movie:9"])
        XCTAssertEqual(read.result.manualFollowItems["series:1"]?.name, "One")
        XCTAssertEqual(read.result.automaticFollowItems["series:2"]?.name, "Two")
        XCTAssertEqual(read.result.allEntries.first?.airTimeSource, .tvmaze)
    }

    func testSettingsAreNeverWrittenAsTheyAre() throws {
        let snapshot = CalendarSnapshot(settings: "profile|secret-tmdb-key", day: sampleDay, loadedAt: Date(), result: sample())
        let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(text.contains("secret-tmdb-key"))
        XCTAssertEqual(snapshot.settingsDigest.count, 64)
    }

    func testOnlyARecentSnapshotWithTheSameSettingsIsUsed() {
        let now = Date(timeIntervalSince1970: 1_792_950_000)
        func snapshot(age: TimeInterval) -> CalendarSnapshot {
            CalendarSnapshot(settings: "a", day: sampleDay, loadedAt: now.addingTimeInterval(-age), result: sample())
        }
        XCTAssertTrue(snapshot(age: 3600).isUsable(settings: "a", now: now))
        XCTAssertFalse(snapshot(age: 3600).isUsable(settings: "b", now: now))
        XCTAssertFalse(snapshot(age: CalendarSnapshot.maxAge + 1).isUsable(settings: "a", now: now))
        // Made "in the future": the clock was set back.
        XCTAssertFalse(snapshot(age: -3600).isUsable(settings: "a", now: now))
        var old = snapshot(age: 60)
        old.version = CalendarSnapshot.currentVersion + 1
        XCTAssertFalse(old.isUsable(settings: "a", now: now))
        // A few days old is still shown while a new one loads.
        XCTAssertTrue(snapshot(age: 3 * 24 * 3600).isUsable(settings: "a", now: now))
    }

    func testASnapshotFromOtherShowsIsShownButNotCurrent() {
        let snapshot = CalendarSnapshot(
            settings: "a", sources: "watched:tt77|progress:tt88", day: sampleDay, loadedAt: Date(), result: sample()
        )
        XCTAssertTrue(snapshot.isUsable(settings: "a", now: Date()))
        XCTAssertTrue(snapshot.hasSources("watched:tt77|progress:tt88"))
        XCTAssertFalse(snapshot.hasSources("watched:tt77|progress:"))
        let text = String(decoding: (try? JSONEncoder().encode(snapshot)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.contains("tt77"))
    }

    func testAnOlderSaveDoesNotReplaceANewerOne() async throws {
        let store = CalendarSnapshotStore(url: url)
        let newer = CalendarSnapshot(settings: "a", day: sampleDay, loadedAt: Date(timeIntervalSince1970: 2), result: sample())
        let older = CalendarSnapshot(settings: "a", day: sampleDay, loadedAt: Date(timeIntervalSince1970: 1), result: sample())
        await store.write(newer, sequence: 2)
        await store.write(older, sequence: 1)
        let stored = await store.read()
        let read = try XCTUnwrap(stored)
        XCTAssertEqual(read.loadedAt, Date(timeIntervalSince1970: 2))
    }

    func testClearingRemovesTheSavedCalendar() async {
        let store = CalendarSnapshotStore(url: url)
        await store.write(CalendarSnapshot(settings: "a", day: sampleDay, loadedAt: Date(), result: sample()), sequence: 1)
        await store.clear()
        let read = await store.read()
        XCTAssertNil(read)
    }

    func testMissingOrBrokenFileReadsAsNothing() async throws {
        let store = CalendarSnapshotStore(url: url)
        let missing = await store.read()
        XCTAssertNil(missing)
        try Data("{".utf8).write(to: url)
        let broken = await store.read()
        XCTAssertNil(broken)
    }
}
