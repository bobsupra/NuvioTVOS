import Foundation
import XCTest
@testable import NuvioTV

// MARK: - Helpers

private final class CalendarMockHTTP: CalendarHTTPClient, @unchecked Sendable {
    /// Path suffix → (status, JSON body). The longest matching suffix wins.
    let routes: [String: (Int, String)]
    private let lock = NSLock()
    private var requested: [URL] = []

    init(_ routes: [String: (Int, String)]) { self.routes = routes }

    func get(_ url: URL) async throws -> (Data, Int) {
        lock.withLock { requested.append(url) }
        let match = routes.keys.filter { url.path.hasSuffix($0) }.max { $0.count < $1.count }
        guard let key = match, let route = routes[key] else { return (Data("{}".utf8), 404) }
        return (Data(route.1.utf8), route.0)
    }

    func count(containing fragment: String) -> Int {
        lock.withLock { requested.filter { $0.path.contains(fragment) }.count }
    }
}

private let today = CalendarDay(year: 2026, month: 10, day: 19)
private let periodFirst = CalendarDay(year: 2026, month: 9, day: 1)
private let periodLast = CalendarDay(year: 2026, month: 12, day: 31)

private func ep(_ season: Int, _ number: Int, _ date: String?, type: String? = nil) -> CalendarTmdb.Episode {
    CalendarTmdb.Episode(airDate: date, episodeNumber: number, seasonNumber: season, name: "E\(number)", episodeType: type)
}

private func calendarMeta(id: String, name: String, type: String = "series", tmdbId: Int? = nil) -> NuvioMeta {
    NuvioMeta(
        id: id,
        name: name,
        description: nil,
        posterUrl: nil,
        backgroundUrl: nil,
        logoUrl: nil,
        imdbId: nil,
        tmdbId: tmdbId,
        type: type,
        year: nil,
        genres: nil,
        rating: nil,
        releaseInfo: nil,
        runtime: nil,
        cast: nil,
        director: nil,
        writer: nil,
        certification: nil,
        country: nil,
        language: nil,
        released: nil,
        status: nil,
        videos: nil,
        trailerYtIds: nil,
        externalRatings: nil,
        posterShape: nil,
        isFromAddon: nil,
        landscapePosterUrl: nil
    )
}

final class CalendarLibrarySourceTests: XCTestCase {
    func testMergesAutomaticSeriesAfterManualFollows() {
        let manual = CalendarItem(id: "tt1", kind: .series, name: "Saved Manual Name", imdbId: "tt1")
        let enrichedWatched = calendarMeta(id: "tt1", name: "Watched Name", tmdbId: 1)
        let watchedOnly = calendarMeta(id: "tmdb:2", name: "Watched Only")
        let watchedMovie = calendarMeta(id: "tmdb:3", name: "Movie", type: "movie")
        let inProgress = calendarMeta(id: "tt4", name: "In Progress")
        let result = CalendarLibrarySource.calendarItems(
            manualFollows: [manual],
            watchedItems: [
                WatchedStoreItem(meta: enrichedWatched, watchedAt: Date()),
                WatchedStoreItem(meta: watchedOnly, watchedAt: Date()),
                WatchedStoreItem(meta: watchedMovie, watchedAt: Date()),
            ],
            continueWatchingItems: [
                ContinueWatchingItem(meta: inProgress, streamUrl: "", position: 1, duration: 10, lastWatchedAt: Date())
            ]
        )

        XCTAssertEqual(result.items.map(\.id), ["tt1", "tmdb:2", "tt4"])
        XCTAssertEqual(result.manualFollowItemIDs, ["series:tt1"])
        XCTAssertEqual(result.automaticFollowItemIDs, ["series:tt1", "series:tmdb:2", "series:tt4"])
        XCTAssertEqual(result.metas[0].name, "Saved Manual Name")
        XCTAssertEqual(result.metas[0].tmdbId, 1)
    }

    func testRawLocalProgressSeriesAreIncludedOutsideMaterializedPages() {
        let rawProgress = calendarMeta(id: "tt5", name: "", tmdbId: 5)
        let result = CalendarLibrarySource.calendarItems(
            manualFollows: [],
            watchedItems: [],
            continueWatchingItems: [],
            additionalContinueWatchingMetas: [rawProgress],
            additionalContinueWatchingIDs: ["tt5"]
        )

        XCTAssertEqual(result.items.map(\.id), ["tt5"])
        XCTAssertEqual(result.automaticFollowItemIDs, ["series:tt5"])
    }
}

@MainActor
final class CalendarManualFollowStoreTests: XCTestCase {
    func testProfileDeletionPurgesPayloadWithoutStoreObserver() throws {
        let profileID = "calendar-deletion-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            LargePayloadStore.remove(key: "calendarManualFollows.\(profileID)", directory: "calendarManualFollows")
        }

        let manager = try ProfileManager(baseDir: directory.path)
        try manager.replaceProfiles([
            Profile(id: profileID, name: "Calendar Test", isPinProtected: false, isAdmin: false, avatarId: "")
        ])
        let key = "calendarManualFollows.\(profileID)"
        XCTAssertTrue(LargePayloadStore.write(Data(#"{"version":1,"items":{}}"#.utf8), key: key, directory: "calendarManualFollows"))

        try manager.deleteProfile(id: profileID)

        XCTAssertNil(LargePayloadStore.read(key: key, directory: "calendarManualFollows"))
    }

    func testManualFollowsAreProfileScopedAndKeepAnimeAndMovieIds() {
        let profileOne = "calendar-tests-\(UUID().uuidString)"
        let profileTwo = "calendar-tests-\(UUID().uuidString)"
        defer {
            CalendarManualFollowStore.clear(profileID: profileOne)
            CalendarManualFollowStore.clear(profileID: profileTwo)
        }

        let anime = CalendarSuggestionItem(
            key: "series:tt123",
            kind: .series,
            type: "anime",
            tmdbId: nil,
            imdbId: "tt123",
            title: "Anime",
            posterURL: nil,
            year: 2026
        )
        let movie = CalendarSuggestionItem(
            key: "movie:9",
            kind: .movie,
            type: "movie",
            tmdbId: 9,
            imdbId: "tt9",
            title: "Old Movie",
            posterURL: nil,
            year: 1999
        )

        XCTAssertEqual(CalendarManualFollowStore.add([anime, movie], profileID: profileOne).count, 2)
        XCTAssertTrue(CalendarManualFollowStore.items(profileID: profileTwo).isEmpty)
        let saved = CalendarManualFollowStore.items(profileID: profileOne)
        XCTAssertEqual(saved["series:tt123"]?.type, "anime")
        XCTAssertEqual(saved["series:tt123"]?.imdbId, "tt123")
        XCTAssertEqual(saved["movie:9"]?.tmdbId, 9)
        XCTAssertEqual(saved["movie:9"]?.imdbId, "tt9")
        XCTAssertEqual(CalendarManualFollowStore.remove(["movie:9"], profileID: profileOne), ["movie:9"])
        XCTAssertNil(CalendarManualFollowStore.items(profileID: profileOne)["movie:9"])
    }
}

// MARK: - Days and grid

final class CalendarDayTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(CalendarDay(iso: "2026-10-19"), today)
        XCTAssertEqual(CalendarDay(iso: "2026-10-30T00:00:00.000Z"), CalendarDay(year: 2026, month: 10, day: 30))
        XCTAssertNil(CalendarDay(iso: nil))
        XCTAssertNil(CalendarDay(iso: "2026-02-30"))
        XCTAssertNil(CalendarDay(iso: "garbage!!!"))
    }

    func testArithmetic() {
        XCTAssertEqual(today.adding(days: 90), CalendarDay(year: 2027, month: 1, day: 17))
        XCTAssertEqual(CalendarDay(year: 2026, month: 1, day: 31).addingMonths(1), CalendarDay(year: 2026, month: 2, day: 28))
        XCTAssertEqual(CalendarDay(year: 2026, month: 1, day: 15).addingMonths(-1), CalendarDay(year: 2025, month: 12, day: 15))
        XCTAssertEqual(today.lastOfMonth, CalendarDay(year: 2026, month: 10, day: 31))
        XCTAssertEqual(CalendarDay(year: 2028, month: 2, day: 3).daysInMonth, 29)
        XCTAssertEqual(today.weekday, 2) // 19 Oct 2026 is a Monday
    }

    func testDayUsesGivenTimeZone() {
        let date = ISO8601DateFormatter().date(from: "2026-10-19T23:30:00Z")!
        XCTAssertEqual(CalendarDay(date: date, timeZone: TimeZone(identifier: "UTC")!), today)
        XCTAssertEqual(CalendarDay(date: date, timeZone: TimeZone(identifier: "Europe/Prague")!), today.adding(days: 1))
    }

    func testPeriod() {
        let period = CalendarBuilder.period(today: today)
        XCTAssertEqual(period.first, periodFirst)
        XCTAssertEqual(period.last, periodLast)
    }

    func testMonthGridStartsOnFirstWeekday() {
        // October 2026 starts on a Thursday.
        let monday = CalendarBuilder.monthGrid(for: today, firstWeekday: 2)
        XCTAssertEqual(monday.prefix(4).filter { $0 == nil }.count, 3)
        XCTAssertEqual(monday[3], CalendarDay(year: 2026, month: 10, day: 1))
        XCTAssertEqual(monday.count % 7, 0)
        XCTAssertEqual(monday.compactMap { $0 }.count, 31)

        let sunday = CalendarBuilder.monthGrid(for: today, firstWeekday: 1)
        XCTAssertEqual(sunday[4], CalendarDay(year: 2026, month: 10, day: 1))
        XCTAssertEqual(CalendarBuilder.weekdayOrder(firstWeekday: 2), [2, 3, 4, 5, 6, 7, 1])
    }
}

// MARK: - Series and movies

final class CalendarBuilderTests: XCTestCase {
    func testSeasonsToFetch() {
        let details = CalendarTmdb.TvDetails(
            id: 1, name: "Show",
            nextEpisodeToAir: ep(2, 5, "2026-10-25"),
            lastEpisodeToAir: ep(2, 4, "2026-10-18"),
            seasons: [
                .init(seasonNumber: 0, airDate: "2026-11-01"),
                .init(seasonNumber: 1, airDate: "2024-01-01"),
                .init(seasonNumber: 2, airDate: "2026-09-01"),
                .init(seasonNumber: 3, airDate: "2026-12-20"),
                .init(seasonNumber: 4, airDate: "2027-06-01"),
            ]
        )
        XCTAssertEqual(CalendarBuilder.seasonsToFetch(for: details, first: periodFirst, last: periodLast), [2, 3])
    }

    func testEndedShowStillShowsEpisodesFromThisPeriod() {
        let details = CalendarTmdb.TvDetails(id: 1, name: "Show", lastEpisodeToAir: ep(4, 10, "2026-09-20"))
        XCTAssertEqual(CalendarBuilder.seasonsToFetch(for: details, first: periodFirst, last: periodLast), [4])
        let old = CalendarTmdb.TvDetails(id: 1, name: "Show", lastEpisodeToAir: ep(4, 10, "2020-09-20"))
        XCTAssertEqual(CalendarBuilder.seasonsToFetch(for: old, first: periodFirst, last: periodLast), [])
    }

    func testEpisodeEntriesStayInsideThePeriod() {
        let item = CalendarItem(id: "tt1", kind: .series, name: "Library Name")
        let details = CalendarTmdb.TvDetails(id: 7, name: "TMDB Name", posterPath: "/p.jpg")
        let episodes = [
            ep(2, 1, "2026-08-31"),
            ep(2, 2, "2026-09-01"),
            ep(2, 3, "2026-12-31"),
            ep(2, 4, "2027-01-01"),
            ep(2, 5, nil),
            ep(2, 2, "2026-09-01"),
            ep(0, 1, "2026-10-01"),
        ]
        let entries = CalendarBuilder.episodeEntries(item: item, details: details, episodes: episodes, first: periodFirst, last: periodLast)
        XCTAssertEqual(entries.map(\.episodeNumber), [2, 3])
        XCTAssertEqual(entries.first?.title, "Library Name")
        XCTAssertEqual(entries.first?.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w342/p.jpg")
    }

    func testReleaseKinds() {
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(1, 1, nil), season: 1, number: 1), .seriesPremiere)
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(3, 1, nil), season: 3, number: 1), .seasonPremiere)
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(3, 8, nil, type: "finale"), season: 3, number: 8), .seasonFinale)
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(3, 4, nil, type: "standard"), season: 3, number: 4), .episode)
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(0, 1, nil), season: 0, number: 1), .episode)
    }

    func testMovieRegionThenFallbacks() {
        let item = CalendarItem(id: "tmdb:9", kind: .movie)
        let regional = CalendarTmdb.MovieDetails(id: 9, title: "Film", releaseDate: "2026-11-01", countries: [
            .init(country: "CZ", releaseDates: [
                .init(releaseDate: "2026-11-05T00:00:00.000Z", type: 3),
                .init(releaseDate: "2026-12-20T00:00:00.000Z", type: 4),
                .init(releaseDate: "2026-10-01T00:00:00.000Z", type: 1),
            ]),
            .init(country: "US", releaseDates: [.init(releaseDate: "2026-10-30T00:00:00.000Z", type: 3)]),
        ])
        XCTAssertEqual(
            CalendarBuilder.movieEntries(item: item, details: regional, region: "CZ", first: periodFirst, last: periodLast).map(\.releaseKind),
            [.theatrical, .digital]
        )

        let usOnly = CalendarTmdb.MovieDetails(id: 9, title: "Film", releaseDate: "2026-11-01", countries: [
            .init(country: "US", releaseDates: [.init(releaseDate: "2026-11-20T00:00:00.000Z", type: 4)]),
        ])
        XCTAssertEqual(
            CalendarBuilder.movieEntries(item: item, details: usOnly, region: "CZ", first: periodFirst, last: periodLast).map(\.releaseKind),
            [.digital]
        )

        let bare = CalendarTmdb.MovieDetails(id: 9, title: "Film", releaseDate: "2026-11-01")
        XCTAssertEqual(
            CalendarBuilder.movieEntries(item: item, details: bare, region: "CZ", first: periodFirst, last: periodLast).map(\.date.iso),
            ["2026-11-01"]
        )
    }

    func testGroupingSortsDaysAndTitles() {
        let day1 = CalendarDay(year: 2026, month: 10, day: 20)
        let a = CalendarEntry(itemId: "a", kind: .series, tmdbId: 1, title: "Zeta", date: day1, releaseKind: .episode, seasonNumber: 1, episodeNumber: 2)
        let b = CalendarEntry(itemId: "b", kind: .series, tmdbId: 2, title: "alpha", date: day1, releaseKind: .episode, seasonNumber: 1, episodeNumber: 1)
        let c = CalendarEntry(itemId: "c", kind: .movie, tmdbId: 3, title: "Film", date: today, releaseKind: .digital)
        let days = CalendarBuilder.groupByDay([a, b, c])
        XCTAssertEqual(days.map(\.date), [today, day1])
        XCTAssertEqual(days[1].entries.map(\.itemId), ["b", "a"])
    }

    func testDecodesTmdbPayloads() throws {
        let tv = #"""
        {"id":1396,"name":"Show","poster_path":"/x.jpg","status":"Returning Series",
         "next_episode_to_air":{"air_date":"2026-10-25","episode_number":5,"season_number":2,"still_path":null,"episode_type":"standard","id":1},
         "last_episode_to_air":null,"seasons":[{"air_date":"2026-09-01","episode_count":10,"season_number":2,"id":5}],"extra":true}
        """#
        let details = try JSONDecoder().decode(CalendarTmdb.TvDetails.self, from: Data(tv.utf8))
        XCTAssertEqual(details.nextEpisodeToAir?.episodeNumber, 5)
        XCTAssertNil(details.lastEpisodeToAir)

        let movie = #"""
        {"id":9,"title":"Film","release_date":"2026-11-01","release_dates":{"results":[{"iso_3166_1":"CZ","release_dates":[{"release_date":"2026-11-05T00:00:00.000Z","type":3,"note":""}]}]}}
        """#
        let movieDetails = try JSONDecoder().decode(CalendarTmdb.MovieDetails.self, from: Data(movie.utf8))
        XCTAssertEqual(movieDetails.releaseDates?.results?.first?.releaseDates?.first?.type, 3)
    }
}

// MARK: - Calendar Back navigation

final class CalendarBackFocusTests: XCTestCase {
    private let firstDay = CalendarDay(year: 2026, month: 11, day: 5)
    private let laterDay = CalendarDay(year: 2026, month: 11, day: 17)

    private func event(_ id: Int, on date: CalendarDay) -> CalendarEntry {
        CalendarEntry(
            itemId: "tt\(id)",
            kind: .series,
            tmdbId: id,
            title: "Show \(id)",
            date: date,
            releaseKind: .episode,
            seasonNumber: 1,
            episodeNumber: 1
        )
    }

    func testBackFromFocusedEventUsesItsActualDay() {
        let first = event(10, on: firstDay)
        let later = event(20, on: laterDay)
        let sections = [
            CalendarDaySection(date: firstDay, entries: [first]),
            CalendarDaySection(date: laterDay, entries: [later])
        ]
        XCTAssertEqual(
            CalendarBackTarget.day(for: .entry(later.id), selectedDay: firstDay, sections: sections),
            laterDay
        )
    }

    func testBackFromFirstDayRemainsOnThatDay() {
        let first = event(10, on: firstDay)
        let sections = [CalendarDaySection(date: firstDay, entries: [first])]
        XCTAssertEqual(
            CalendarBackTarget.day(for: .entry(first.id), selectedDay: firstDay, sections: sections),
            firstDay
        )
    }

    func testBackFromDisappearingEntryFallsBackToSelectedDay() {
        XCTAssertEqual(
            CalendarBackTarget.day(for: .entry("missing"), selectedDay: firstDay, sections: []),
            firstDay
        )
    }

    func testBackOutsideEventPanelRemainsNativeSidebarAction() {
        let sections = [CalendarDaySection(date: firstDay, entries: [event(10, on: firstDay)])]
        XCTAssertNil(CalendarBackTarget.day(for: .day(firstDay), selectedDay: firstDay, sections: sections))
        XCTAssertNil(CalendarBackTarget.day(for: .nextMonth, selectedDay: firstDay, sections: sections))
        XCTAssertNil(CalendarBackTarget.day(for: nil, selectedDay: firstDay, sections: sections))
    }
}

// MARK: - Service

final class CalendarServiceTests: XCTestCase {
    private func service(_ http: CalendarMockHTTP, ids: [String: Int]) -> CalendarService {
        CalendarService(client: CalendarTmdb.Client(apiKey: "k", http: http), maxConcurrent: 2, region: "CZ") { item in
            ids[item.id]
        }
    }

    func testLoadsShowsAndMoviesAndReportsSkips() async throws {
        let http = CalendarMockHTTP([
            "/tv/1396": (200, #"{"id":1396,"name":"Show A","next_episode_to_air":{"air_date":"2026-10-20","episode_number":3,"season_number":2},"seasons":[{"season_number":2,"air_date":"2026-10-06"}]}"#),
            "/tv/1396/season/2": (200, #"{"episodes":[{"air_date":"2026-10-06","episode_number":1,"season_number":2},{"air_date":"2026-10-20","episode_number":3,"season_number":2},{"air_date":"2026-10-27","episode_number":4,"season_number":2,"episode_type":"finale"}]}"#),
            "/tv/2": (200, #"{"id":2,"name":"Ended","next_episode_to_air":null,"last_episode_to_air":{"air_date":"2019-05-19","episode_number":6,"season_number":8}}"#),
            "/tv/3": (500, "oops"),
            "/movie/9": (200, #"{"id":9,"title":"Film","release_date":"2026-11-01","release_dates":{"results":[]}}"#),
        ])
        let items = [
            CalendarItem(id: "tt0903747", kind: .series, name: "Show A"),
            CalendarItem(id: "tmdb:1396", kind: .series),
            CalendarItem(id: "tmdb:2", kind: .series),
            CalendarItem(id: "tmdb:3", kind: .series),
            CalendarItem(id: "kitsu:5", kind: .series),
            CalendarItem(id: "tmdb:9", kind: .movie),
        ]
        let ids = ["tt0903747": 1396, "tmdb:1396": 1396, "tmdb:2": 2, "tmdb:3": 3, "tmdb:9": 9]
        let result = try await service(http, ids: ids).load(items: items, first: periodFirst, last: periodLast)

        XCTAssertEqual(result.days.map(\.date.iso), ["2026-10-06", "2026-10-20", "2026-10-27", "2026-11-01"])
        XCTAssertEqual(result.days[0].entries.first?.releaseKind, .seasonPremiere)
        XCTAssertEqual(result.days[2].entries.first?.releaseKind, .seasonFinale)

        let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.item.id, $0.reason) })
        XCTAssertNil(reasons["tmdb:2"], "nothing in the period is not a problem")
        XCTAssertEqual(reasons["tmdb:3"], .failed("HTTP 500"))
        XCTAssertEqual(reasons["kitsu:5"], .unsupportedId)
        XCTAssertNil(reasons["tmdb:1396"], "the duplicate is dropped silently")
        XCTAssertEqual(http.count(containing: "/tv/1396/season/2"), 1)
    }

    func testManualAndWatchedShowsProduceEntriesWithSeparateSources() async throws {
        let http = CalendarMockHTTP([
            "/tv/1": (200, #"{"id":1,"name":"Library Show","seasons":[{"season_number":1,"air_date":"2026-10-01"}]}"#),
            "/tv/1/season/1": (200, #"{"episodes":[{"air_date":"2026-10-20","episode_number":1,"season_number":1}]}"#),
            "/tv/2": (200, #"{"id":2,"name":"Watched Show","seasons":[{"season_number":1,"air_date":"2026-10-01"}]}"#),
            "/tv/2/season/1": (200, #"{"episodes":[{"air_date":"2026-10-21","episode_number":1,"season_number":1}]}"#),
        ])
        let manualItem = CalendarItem(id: "tt1", kind: .series, name: "Saved Manual Name", imdbId: "tt1")
        let manualAlias = CalendarItem(id: "tmdb:1", kind: .series, name: "Manual Alias", tmdbId: 1)
        let watchedOnlyItem = CalendarItem(id: "tmdb:2", kind: .series, name: "Watched Show")
        let result = try await service(http, ids: ["tt1": 1, "tmdb:1": 1, "tmdb:2": 2]).load(
            items: [manualItem, manualAlias, watchedOnlyItem],
            first: periodFirst,
            last: periodLast,
            manualFollowItemIDs: [manualItem.sourceIdentityKey],
            automaticFollowItemIDs: [watchedOnlyItem.sourceIdentityKey]
        )

        XCTAssertEqual(Set(result.days.flatMap(\.entries).map(\.tmdbId)), [1, 2])
        XCTAssertEqual(result.manualFollowKeys, ["series:1"])
        XCTAssertEqual(result.manualFollowItems["series:1"]?.name, "Saved Manual Name")
        XCTAssertEqual(result.manualFollowItems["series:1"]?.tmdbId, 1)
        XCTAssertEqual(result.automaticFollowItems["series:2"]?.name, "Watched Show")
        XCTAssertEqual(result.automaticFollowItems["series:2"]?.tmdbId, 2)
    }

    func testResolvedTMDBMetadataFillsAutomaticSuggestionTitleAndArtwork() async throws {
        let http = CalendarMockHTTP([
            "/tv/5": (200, #"{"id":5,"name":"Resolved title","poster_path":"/poster.jpg","seasons":[]}"#),
        ])
        let item = CalendarItem(id: "tt5", kind: .series, imdbId: "tt5")
        let result = try await service(http, ids: ["tt5": 5]).load(
            items: [item],
            first: periodFirst,
            last: periodLast,
            manualFollowItemIDs: [],
            automaticFollowItemIDs: [item.sourceIdentityKey]
        )

        XCTAssertEqual(result.automaticFollowItems["series:5"]?.name, "Resolved title")
        XCTAssertEqual(
            result.automaticFollowItems["series:5"]?.posterURL,
            "https://image.tmdb.org/t/p/w342/poster.jpg"
        )
    }

    func testLongReleasedMoviesAreNotRequested() async throws {
        let http = CalendarMockHTTP([:])
        let old = CalendarItem(id: "tmdb:11", kind: .movie, year: 1999)
        let result = try await service(http, ids: ["tmdb:11": 11]).load(items: [old], first: periodFirst, last: periodLast)
        XCTAssertEqual(http.count(containing: "/movie/"), 0)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testEntriesKeepTheLibraryType() {
        let item = CalendarItem(id: "tt9", kind: .series, type: "anime")
        let details = CalendarTmdb.TvDetails(id: 9, name: "Show")
        let entries = CalendarBuilder.episodeEntries(item: item, details: details, episodes: [ep(1, 2, "2026-10-20")], first: periodFirst, last: periodLast)
        XCTAssertEqual(entries.first?.itemType, "anime")
    }

    func testRejectedKeyFailsTheWholeLoad() async {
        let http = CalendarMockHTTP(["/tv/1": (401, #"{"status_code":7}"#)])
        do {
            _ = try await service(http, ids: ["tmdb:1": 1]).load(items: [CalendarItem(id: "tmdb:1", kind: .series)], first: periodFirst, last: periodLast)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CalendarLoadError, .invalidApiKey)
        }
    }

    func testMissingKey() async {
        let s = CalendarService(client: CalendarTmdb.Client(apiKey: " ", http: CalendarMockHTTP([:])), region: "CZ") { _ in nil }
        do {
            _ = try await s.load(items: [], first: periodFirst, last: periodLast)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CalendarLoadError, .tmdbNotConfigured)
        }
    }

    func testSeasonPageFailureFallsBackToKnownEpisodes() async throws {
        let http = CalendarMockHTTP([
            "/tv/4": (200, #"{"id":4,"name":"Show","next_episode_to_air":{"air_date":"2026-10-22","episode_number":7,"season_number":1}}"#),
            "/tv/4/season/1": (500, ""),
        ])
        let result = try await service(http, ids: ["tmdb:4": 4]).load(items: [CalendarItem(id: "tmdb:4", kind: .series)], first: periodFirst, last: periodLast)
        XCTAssertEqual(result.days.first?.entries.first?.episodeNumber, 7)
    }

    func testConcurrentMapKeepsOrder() async {
        let s = service(CalendarMockHTTP([:]), ids: [:])
        let out = await s.concurrentMap(Array(0..<20)) { value -> Int in
            try? await Task.sleep(nanoseconds: UInt64((20 - value) * 1_000_000))
            return value * 2
        }
        XCTAssertEqual(out, (0..<20).map { $0 * 2 })
    }
}

// MARK: - Suggestions

final class CalendarSuggestionTests: XCTestCase {
    func testAnimeSeasons() {
        XCTAssertEqual(CalendarSuggestions.animeSeason(containing: today).first.iso, "2026-10-01")
        XCTAssertEqual(CalendarSuggestions.animeSeason(containing: today).last.iso, "2026-12-31")
        let feb = CalendarSuggestions.animeSeason(containing: CalendarDay(year: 2027, month: 2, day: 14))
        XCTAssertEqual(feb.first.iso, "2027-01-01")
        XCTAssertEqual(feb.last.iso, "2027-03-31")
        let jun = CalendarSuggestions.animeSeason(containing: CalendarDay(year: 2027, month: 6, day: 30))
        XCTAssertEqual(jun.first.iso, "2027-04-01")
        XCTAssertEqual(jun.last.iso, "2027-06-30")
    }

    func testRequests() {
        let anime = CalendarSuggestions.request(for: .animeThisSeason, today: today, region: "CZ")
        XCTAssertEqual(anime.path, "discover/tv")
        XCTAssertEqual(anime.query["with_genres"], "16")
        XCTAssertEqual(anime.query["with_origin_country"], "JP")
        XCTAssertEqual(anime.query["air_date.gte"], "2026-10-01")
        XCTAssertEqual(anime.query["air_date.lte"], "2026-12-31")

        let airing = CalendarSuggestions.request(for: .airingNow, today: today, region: "CZ")
        XCTAssertEqual(airing.query["air_date.lte"], "2026-11-02")

        let movies = CalendarSuggestions.request(for: .upcomingMovies, today: today, region: "CZ")
        XCTAssertEqual(movies, CalendarSuggestionRequest(path: "movie/upcoming", query: ["region": "CZ"]))
        XCTAssertEqual(CalendarSuggestionList.upcomingMovies.kind, .movie)
    }

    func testTodayListsUseTodayOnly() {
        let anime = CalendarSuggestions.request(for: .animeToday, today: today, region: "CZ")
        XCTAssertEqual(anime.query["air_date.gte"], "2026-10-19")
        XCTAssertEqual(anime.query["air_date.lte"], "2026-10-19")
        XCTAssertEqual(anime.query["with_origin_country"], "JP")
        let series = CalendarSuggestions.request(for: .seriesToday, today: today, region: "CZ")
        XCTAssertEqual(series.query["air_date.lte"], "2026-10-19")
        XCTAssertEqual(series.query["without_genres"], CalendarSuggestions.airingNowExcludedGenres)
    }

    func testListStopsAtTheLastPage() async throws {
        let http = CalendarMockHTTP([
            "/movie/upcoming": (200, #"{"results":[{"id":5,"title":"M"}],"total_pages":1}"#),
        ])
        let results = try await CalendarTmdb.Client(apiKey: "k", http: http).list("movie/upcoming", pages: 5)
        XCTAssertEqual(results.map(\.id), [5])
        XCTAssertEqual(http.count(containing: "/movie/upcoming"), 1)
    }

    func testMosaicLayout() {
        XCTAssertEqual(CalendarFormat.mosaicLayout(count: 20, capacity: 6).shown, 5)
        XCTAssertEqual(CalendarFormat.mosaicLayout(count: 20, capacity: 6).overflow, 15)
        XCTAssertEqual(CalendarFormat.mosaicLayout(count: 6, capacity: 6).overflow, 0)
        XCTAssertEqual(CalendarFormat.mosaicLayout(count: 20, capacity: 12).overflow, 9)
        XCTAssertEqual(CalendarFormat.mosaicLayout(count: 2, capacity: 6).shown, 2)
    }

    func testListPagesAreMergedWithoutDuplicates() async throws {
        let http = CalendarMockHTTP([
            "/discover/tv": (200, #"{"results":[{"id":1,"name":"A","first_air_date":"2026-10-03"},{"id":2,"name":"B"}]}"#),
        ])
        let client = CalendarTmdb.Client(apiKey: "k", http: http)
        let results = try await client.list("discover/tv", pages: 2)
        XCTAssertEqual(results.map(\.id), [1, 2])
        XCTAssertEqual(results.first?.year, 2026)
        XCTAssertEqual(http.count(containing: "/discover/tv"), 2)
    }
}

// MARK: - Anime today (AniList + Simkl)

private final class CalendarAnimeMockHTTP: CalendarAnimeHTTPClient, @unchecked Sendable {
    let anilist: String
    /// AniList id → arm-server JSON.
    let arm: [Int: String]
    /// AniList id → Location header of the Simkl redirect.
    let redirects: [Int: String]
    /// Simkl path ("/anime/1") → details JSON.
    let details: [String: String]

    init(anilist: String, arm: [Int: String] = [:], redirects: [Int: String], details: [String: String]) {
        self.anilist = anilist
        self.arm = arm
        self.redirects = redirects
        self.details = details
    }

    private func anilistId(in url: URL, name: String) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value.flatMap(Int.init)
    }

    func post(_ url: URL, json: Data) async throws -> (Data, Int) {
        (Data(anilist.utf8), 200)
    }

    func getWithoutRedirect(_ url: URL, headers: [String: String]) async throws -> (Data, Int, String?) {
        if url.path == "/api/v2/ids" {
            if let id = anilistId(in: url, name: "id"), let body = arm[id] { return (Data(body.utf8), 200, nil) }
            return (Data("null".utf8), 200, nil)
        }
        if url.path == "/redirect" {
            if let id = anilistId(in: url, name: "anilist"), let location = redirects[id] { return (Data(), 301, location) }
            return (Data(), 404, nil)
        }
        if let body = details[url.path] { return (Data(body.utf8), 200, nil) }
        return (Data(), 404, nil)
    }
}

final class CalendarAnimeTodayTests: XCTestCase {
    private let prague = TimeZone(identifier: "Europe/Prague")!

    func testArmParse() {
        let ids = CalendarAnimeToday.Arm.parse(Data(#"{"anilist":21,"imdb":"tt0388629","themoviedb":37854,"anime-planet":"one-piece"}"#.utf8))
        XCTAssertEqual(ids, .init(tmdb: 37854, imdb: "tt0388629"))
        XCTAssertEqual(CalendarAnimeToday.Arm.parse(Data("null".utf8)), .init(tmdb: nil, imdb: nil))
    }

    func testSimklTargetFromLocation() {
        XCTAssertEqual(CalendarAnimeToday.Simkl.simklTarget(fromLocation: "https://simkl.com/anime/3012710/hello-i-am-a-witch")?.id, "3012710")
        XCTAssertEqual(CalendarAnimeToday.Simkl.simklTarget(fromLocation: "/anime/42?x=1")?.type, "anime")
        XCTAssertEqual(CalendarAnimeToday.Simkl.simklTarget(fromLocation: "https://simkl.com/tv/7/slug")?.type, "tv")
        XCTAssertNil(CalendarAnimeToday.Simkl.simklTarget(fromLocation: "https://simkl.com/search/"))
    }

    func testDayBoundsFollowLocalTime() {
        // 2026-10-19 23:30 in Prague = 21:30 UTC.
        let late = Date(timeIntervalSince1970: 1_792_445_400)
        let bounds = CalendarAnimeToday.dayBounds(of: late, timeZone: prague)
        XCTAssertEqual(bounds.end.timeIntervalSince(bounds.start), 86_400)
        XCTAssertLessThanOrEqual(bounds.start, late)
        XCTAssertGreaterThan(bounds.end, late)
    }

    func testLoadResolvesIdsAndKeepsUnknownTitles() async throws {
        let anilist = #"""
        {"data":{"Page":{"pageInfo":{"hasNextPage":false},"airingSchedules":[
          {"airingAt":1792413000,"episode":3,"media":{"id":10,"format":"TV","countryOfOrigin":"JP","isAdult":false,
            "title":{"romaji":"Majo","english":"Hello, I am a Witch"},"coverImage":{"large":"https://img/a.jpg"},"startDate":{"year":2026}}},
          {"airingAt":1792400000,"episode":1,"media":{"id":20,"format":"TV_SHORT","countryOfOrigin":"JP","isAdult":false,
            "title":{"romaji":"Yuusanchi","english":null},"coverImage":null,"startDate":{"year":2026}}},
          {"airingAt":1792401000,"episode":5,"media":{"id":30,"format":"ONA","countryOfOrigin":"CN","isAdult":false,
            "title":{"romaji":"Donghua","english":null}}},
          {"airingAt":1792402000,"episode":2,"media":{"id":40,"format":"TV","countryOfOrigin":"JP","isAdult":true,
            "title":{"romaji":"Adult","english":null}}},
          {"airingAt":1792415000,"episode":7,"media":{"id":50,"format":"TV","countryOfOrigin":"JP","isAdult":false,
            "title":{"romaji":"Goblin","english":null}}},
          {"airingAt":1792420000,"episode":4,"media":{"id":10,"format":"TV","countryOfOrigin":"JP","isAdult":false,
            "title":{"romaji":"Majo","english":"Hello, I am a Witch"}}}
        ]}}}
        """#
        let http = CalendarAnimeMockHTTP(
            anilist: anilist,
            arm: [
                10: #"{"anilist":10,"myanimelist":1,"imdb":"tt43650300","themoviedb":313068}"#,
                50: #"{"anilist":50,"myanimelist":2}"#,
            ],
            redirects: [50: "https://simkl.com/anime/3046168/goblin"],
            details: ["/anime/3046168": #"{"ids":{"simkl":3046168,"imdb":"tt43691383","tmdb":"316694"}}"#]
        )
        let items = try await CalendarAnimeToday.load(
            now: Date(timeIntervalSince1970: 1_792_410_000),
            timeZone: prague,
            http: http,
            clientID: "test-\(UUID().uuidString)"
        )
        XCTAssertEqual(items.map(\.title), ["Yuusanchi", "Hello, I am a Witch", "Goblin"])
        // Not on arm, found on Simkl.
        XCTAssertEqual(items[2].key, "series:316694")
        XCTAssertEqual(items[2].imdbId, "tt43691383")
        XCTAssertFalse(items[0].isAddable)
        XCTAssertEqual(items[1].key, "series:313068")
        XCTAssertEqual(items[1].imdbId, "tt43650300")
        XCTAssertEqual(items[1].tmdbId, 313068)
        XCTAssertEqual(items[1].posterURL?.absoluteString, "https://img/a.jpg")
        XCTAssertNotNil(items[1].detail)
    }

    func testItemsMergeTitlesWithTheSameTmdbId() {
        let at = Date(timeIntervalSince1970: 1_792_410_000)
        let airings = [
            CalendarAnimeToday.Airing(anilistId: 1, title: "A", posterURL: nil, airingAt: at, episode: 1, year: 2026, isMovie: false),
            CalendarAnimeToday.Airing(anilistId: 2, title: "A mini", posterURL: nil, airingAt: at.addingTimeInterval(60), episode: 1, year: 2026, isMovie: false),
            CalendarAnimeToday.Airing(anilistId: 3, title: "Film", posterURL: nil, airingAt: at.addingTimeInterval(120), episode: nil, year: 2026, isMovie: true),
        ]
        let ids: [Int: CalendarAnimeToday.Ids] = [
            1: .init(tmdb: 5, imdb: "tt1"),
            2: .init(tmdb: 5, imdb: "tt1"),
            3: .init(tmdb: 9, imdb: nil),
        ]
        let items = CalendarAnimeToday.items(airings, ids: ids, timeZone: prague)
        XCTAssertEqual(items.map(\.key), ["series:5", "movie:9"])
        XCTAssertEqual(items[1].kind, .movie)
    }
}

// MARK: - Anime today: TMDB and IMDb ids

private final class AnimeIdsMockHTTP: CalendarAnimeHTTPClient, @unchecked Sendable {
    /// AniList id → arm-server (status, JSON); unknown ids answer "null".
    var arm: [Int: (Int, String)] = [:]
    /// AniList id → its relations as (relationType, id, format).
    var relations: [Int: [(String, Int, String)]] = [:]
    /// AniList id → Location header of the Simkl redirect.
    var redirects: [Int: String] = [:]
    /// Simkl path ("/anime/1") → details JSON.
    var details: [String: String] = [:]
    private let lock = NSLock()
    private var calls: [String] = []

    var log: [String] { lock.withLock { calls } }

    private func record(_ call: String) {
        lock.withLock { calls.append(call) }
    }

    private func query(_ name: String, in url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value.flatMap(Int.init)
    }

    func post(_ url: URL, json: Data) async throws -> (Data, Int) {
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        let id = (object?["variables"] as? [String: Any])?["id"] as? Int ?? -1
        record("relations:\(id)")
        let edges = (relations[id] ?? []).map { relation in
            #"{"relationType":"\#(relation.0)","node":{"id":\#(relation.1),"type":"ANIME","format":"\#(relation.2)"}}"#
        }
        let body = #"{"data":{"Media":{"relations":{"edges":[\#(edges.joined(separator: ","))]}}}}"#
        return (Data(body.utf8), 200)
    }

    func getWithoutRedirect(_ url: URL, headers: [String: String]) async throws -> (Data, Int, String?) {
        if url.path == "/api/v2/ids" {
            let id = query("id", in: url) ?? -1
            record("arm:\(id)")
            if let answer = arm[id] { return (Data(answer.1.utf8), answer.0, nil) }
            return (Data("null".utf8), 200, nil)
        }
        if url.path == "/redirect" {
            let id = query("anilist", in: url) ?? -1
            record("simkl:\(id)")
            if let location = redirects[id] { return (Data(), 301, location) }
            return (Data(), 404, nil)
        }
        if let body = details[url.path] { return (Data(body.utf8), 200, nil) }
        return (Data(), 404, nil)
    }
}

final class CalendarAnimeIdTests: XCTestCase {
    private func airing(_ id: Int, prequels: [Int]? = [], isMovie: Bool = false) -> CalendarAnimeToday.Airing {
        CalendarAnimeToday.Airing(
            anilistId: id, title: "A\(id)", posterURL: nil, airingAt: Date(timeIntervalSince1970: 1_792_410_000),
            episode: 1, year: 2026, isMovie: isMovie, prequelIds: prequels
        )
    }

    private func resolver(
        _ http: AnimeIdsMockHTTP,
        clientID: String = "",
        tmdb: CalendarTmdb.Client? = nil,
        cache: CalendarAnimeToday.IdCache = CalendarAnimeToday.IdCache()
    ) -> CalendarAnimeToday.Resolver {
        CalendarAnimeToday.Resolver(http: http, clientID: clientID, tmdb: tmdb, cache: cache)
    }

    func testArmParseReadsTheTvdbId() {
        XCTAssertEqual(
            CalendarAnimeToday.Arm.parse(Data(#"{"anilist":1,"thetvdb":4242}"#.utf8)),
            .init(tmdb: nil, imdb: nil, tvdb: 4242)
        )
        XCTAssertEqual(
            CalendarAnimeToday.Arm.parse(Data(#"{"anilist":1,"thetvdb":"4242","themoviedb":9}"#.utf8)),
            .init(tmdb: 9, imdb: nil, tvdb: 4242)
        )
    }

    func testOnlyAnimeSeriesPrequelsCount() throws {
        let json = #"""
        {"edges":[
          {"relationType":"PREQUEL","node":{"id":1,"type":"ANIME","format":"TV"}},
          {"relationType":"PREQUEL","node":{"id":2,"type":"ANIME","format":"MOVIE"}},
          {"relationType":"PREQUEL","node":{"id":3,"type":"MANGA","format":"MANGA"}},
          {"relationType":"SEQUEL","node":{"id":4,"type":"ANIME","format":"TV"}},
          {"relationType":"SIDE_STORY","node":{"id":5,"type":"ANIME","format":"ONA"}},
          {"relationType":"PREQUEL","node":{"id":6,"type":"ANIME","format":"ONA"}},
          {"relationType":"PREQUEL","node":{"id":7,"type":"ANIME","format":"TV_SHORT"}},
          {"relationType":"PREQUEL","node":{"id":8,"type":"ANIME","format":"SPECIAL"}}
        ]}
        """#
        let relations = try JSONDecoder().decode(CalendarAnimeToday.AniList.Relations.self, from: Data(json.utf8))
        XCTAssertEqual(relations.prequelIds, [1, 6, 7])
    }

    func testTheTvdbIdIsTurnedIntoTheTmdbShow() async {
        let http = AnimeIdsMockHTTP()
        http.arm = [101: (200, #"{"anilist":101,"thetvdb":4242}"#)]
        let tmdbHTTP = CalendarMockHTTP(["/find/4242": (200, #"{"tv_results":[{"id":777}],"movie_results":[]}"#)])
        let tmdb = CalendarTmdb.Client(apiKey: "test", http: tmdbHTTP)
        let resolution = await resolver(http, tmdb: tmdb).resolve(airing(101))
        XCTAssertEqual(resolution, .init(ids: .init(tmdb: 777, imdb: nil, tvdb: 4242), isFinal: true))
        // Found without asking for earlier seasons.
        XCTAssertFalse(http.log.contains { $0.hasPrefix("relations:") })
    }

    func testNewSeasonTakesTheIdsOfAnEarlierOne() async {
        let http = AnimeIdsMockHTTP()
        // Season 3 (201) and season 2 (200) aren't on arm yet; season 1 (199) is.
        http.relations = [200: [("PREQUEL", 199, "TV"), ("PREQUEL", 150, "MOVIE")]]
        http.arm = [199: (200, #"{"anilist":199,"themoviedb":555,"imdb":"tt0555"}"#)]
        let resolution = await resolver(http).resolve(airing(201, prequels: [200]))
        XCTAssertEqual(resolution, .init(ids: .init(tmdb: 555, imdb: "tt0555"), isFinal: true))
        XCTAssertEqual(http.log, ["arm:201", "arm:200", "relations:200", "arm:199"])
    }

    func testPrequelWalkStopsAfterThreeSeasons() async {
        let http = AnimeIdsMockHTTP()
        http.relations = [
            304: [("PREQUEL", 303, "TV")],
            303: [("PREQUEL", 302, "TV")],
            302: [("PREQUEL", 301, "TV")],
        ]
        http.arm = [301: (200, #"{"anilist":301,"themoviedb":1}"#)]
        let resolution = await resolver(http).resolve(airing(305, prequels: [304]))
        XCTAssertEqual(resolution, .init(ids: .init(tmdb: nil, imdb: nil), isFinal: true))
        XCTAssertEqual(http.log, ["arm:305", "arm:304", "relations:304", "arm:303", "relations:303", "arm:302"])
    }

    func testMoviesDontTakeAnEarlierSeasonsIds() async {
        let http = AnimeIdsMockHTTP()
        http.arm = [400: (200, #"{"anilist":400,"themoviedb":2}"#)]
        let resolution = await resolver(http).resolve(airing(401, prequels: [400], isMovie: true))
        XCTAssertEqual(resolution.ids, .init(tmdb: nil, imdb: nil))
        XCTAssertEqual(http.log, ["arm:401"])
    }

    func testSimklIsAskedLast() async {
        let http = AnimeIdsMockHTTP()
        http.relations = [500: []]
        http.redirects = [501: "https://simkl.com/anime/9/slug"]
        http.details = ["/anime/9": #"{"ids":{"simkl":9,"imdb":"tt0009","tmdb":"99"}}"#]
        let resolution = await resolver(http, clientID: "test").resolve(airing(501, prequels: [500]))
        XCTAssertEqual(resolution.ids.tmdb, 99)
        XCTAssertEqual(resolution.ids.imdb, "tt0009")
        XCTAssertTrue(resolution.isFinal)
        XCTAssertEqual(http.log, ["arm:501", "arm:500", "relations:500", "simkl:501"])
    }

    func testPrequelsAreAskedForWhenTheScheduleDidntBringThem() async {
        let http = AnimeIdsMockHTTP()
        http.relations = [801: [("PREQUEL", 800, "TV")]]
        http.arm = [800: (200, #"{"anilist":800,"themoviedb":8}"#)]
        let resolution = await resolver(http).resolve(airing(801, prequels: nil))
        XCTAssertEqual(resolution.ids.tmdb, 8)
        XCTAssertEqual(http.log, ["arm:801", "relations:801", "arm:800"])
    }

    func testAFilmsTheTvdbIdIsNotUsed() async {
        let http = AnimeIdsMockHTTP()
        http.arm = [901: (200, #"{"anilist":901,"thetvdb":4242}"#)]
        let tmdbHTTP = CalendarMockHTTP(["/find/4242": (200, #"{"tv_results":[{"id":777}]}"#)])
        let tmdb = CalendarTmdb.Client(apiKey: "test", http: tmdbHTTP)
        let resolution = await resolver(http, tmdb: tmdb).resolve(airing(901, isMovie: true))
        XCTAssertEqual(resolution, .init(ids: .init(tmdb: nil, imdb: nil), isFinal: true))
        XCTAssertEqual(tmdbHTTP.count(containing: "/find"), 0)
    }

    func testTheTvdbIdWithoutTmdbIsAskedAgainLater() async {
        let http = AnimeIdsMockHTTP()
        http.arm = [902: (200, #"{"anilist":902,"thetvdb":4242}"#)]
        let resolution = await resolver(http).resolve(airing(902))
        XCTAssertFalse(resolution.isFinal)
    }

    func testAnAnswerAfterAFailureIsShownButNotRemembered() async {
        let http = AnimeIdsMockHTTP()
        http.arm = [701: (503, ""), 700: (200, #"{"anilist":700,"themoviedb":7}"#)]
        let cache = CalendarAnimeToday.IdCache()
        let ids = await resolver(http, cache: cache).ids(for: [airing(701, prequels: [700])])
        XCTAssertEqual(ids[701]?.tmdb, 7)
        let cached = await cache.get(701)
        XCTAssertNil(cached)
    }

    func testFailedLookupIsNotRemembered() async {
        let http = AnimeIdsMockHTTP()
        http.arm = [601: (503, "")]
        let cache = CalendarAnimeToday.IdCache()
        let ids = await resolver(http, cache: cache).ids(for: [airing(601)])
        XCTAssertNil(ids[601])
        let cached = await cache.get(601)
        XCTAssertNil(cached)

        // A title no source knows is remembered as such.
        let unknown = await resolver(http, cache: cache).ids(for: [airing(602)])
        XCTAssertEqual(unknown[602], .init(tmdb: nil, imdb: nil))
        let remembered = await cache.get(602)
        XCTAssertEqual(remembered, .init(tmdb: nil, imdb: nil))
    }
}

// MARK: - Anime broadcast times in the calendar

private final class CalendarAnimeTimesMockHTTP: CalendarAnimeHTTPClient, @unchecked Sendable {
    /// arm path + id ("/api/v2/themoviedb:5") → JSON.
    let arm: [String: String]
    let anilist: String
    private let lock = NSLock()
    private var posted = 0

    init(arm: [String: String], anilist: String) {
        self.arm = arm
        self.anilist = anilist
    }

    var postCount: Int { lock.withLock { posted } }

    func post(_ url: URL, json: Data) async throws -> (Data, Int) {
        lock.withLock { posted += 1 }
        return (Data(anilist.utf8), 200)
    }

    func getWithoutRedirect(_ url: URL, headers: [String: String]) async throws -> (Data, Int, String?) {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        if let body = arm["\(url.path):\(id)"] { return (Data(body.utf8), 200, nil) }
        return (Data("[]".utf8), 200, nil)
    }
}

final class CalendarAnimeTimesTests: XCTestCase {
    private let prague = TimeZone(identifier: "Europe/Prague")!

    private func entry(_ show: Int, ep: Int, on day: CalendarDay, anime: Bool = true) -> CalendarEntry {
        var e = CalendarEntry(itemId: "tt\(show)", kind: .series, tmdbId: show, title: "S\(show)", date: day,
                              releaseKind: .episode, seasonNumber: 1, episodeNumber: ep)
        e.isAnime = anime
        return e
    }

    /// Unix time of a Prague wall-clock moment.
    private func at(_ day: CalendarDay, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = prague
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    func testDetectsJapaneseAnime() throws {
        let json = #"{"id":1,"name":"A","genres":[{"id":16,"name":"Animation"}],"origin_country":["JP"]}"#
        let details = try JSONDecoder().decode(CalendarTmdb.TvDetails.self, from: Data(json.utf8))
        XCTAssertTrue(details.isJapaneseAnime)
        let cn = #"{"id":2,"name":"B","genres":[{"id":16}],"origin_country":["CN"]}"#
        XCTAssertFalse(try JSONDecoder().decode(CalendarTmdb.TvDetails.self, from: Data(cn.utf8)).isJapaneseAnime)
    }

    func testParseArmIds() {
        let ids = CalendarAnimeTimes.parseArmIds(Data(#"[{"anilist":5,"imdb":"tt1"},{"anilist":7},{"anilist":5}]"#.utf8))
        XCTAssertEqual(ids, [5, 7])
        XCTAssertEqual(CalendarAnimeTimes.parseArmIds(Data(#"{"anilist":9}"#.utf8)), [9])
        XCTAssertEqual(CalendarAnimeTimes.parseArmIds(Data("null".utf8)), [])
    }

    func testLateNightEpisodeMovesToTheLocalDay() {
        let tmdbDay = CalendarDay(year: 2026, month: 10, day: 20)
        let local = tmdbDay.adding(days: -1)
        let airings: [Int: [CalendarAnimeTimes.Airing]] = [
            1: [.init(mediaId: 100, episode: 3, at: at(local, 18, 30))],
        ]
        let out = CalendarAnimeTimes.match([entry(1, ep: 3, on: tmdbDay)], airings: airings, timeZone: prague)
        XCTAssertEqual(out[0].date, local)
        XCTAssertEqual(out[0].airTime, at(local, 18, 30))
    }

    func testUnmatchedAndNonAnimeKeepTheirDate() {
        let day = CalendarDay(year: 2026, month: 10, day: 20)
        let airings: [Int: [CalendarAnimeTimes.Airing]] = [
            1: [.init(mediaId: 100, episode: 3, at: at(day.adding(days: -5), 18))],
            2: [.init(mediaId: 200, episode: 1, at: at(day, 10))],
        ]
        let out = CalendarAnimeTimes.match(
            [entry(1, ep: 3, on: day), entry(2, ep: 1, on: day, anime: false)],
            airings: airings, timeZone: prague
        )
        XCTAssertEqual(out.map(\.date), [day, day])
        XCTAssertNil(out[0].airTime)
        XCTAssertNil(out[1].airTime)
    }

    func testDoubleEpisodeDayUsesEachAiringOnce() {
        let day = CalendarDay(year: 2026, month: 10, day: 20)
        let airings: [Int: [CalendarAnimeTimes.Airing]] = [
            1: [
                .init(mediaId: 100, episode: 2, at: at(day, 17, 30)),
                .init(mediaId: 100, episode: 1, at: at(day, 17)),
            ],
        ]
        let out = CalendarAnimeTimes.match([entry(1, ep: 1, on: day), entry(1, ep: 2, on: day)],
                                           airings: airings, timeZone: prague)
        XCTAssertEqual(out[0].airTime, at(day, 17))
        XCTAssertEqual(out[1].airTime, at(day, 17, 30))
    }

    func testApplyLooksUpArmByTmdbThenImdb() async {
        let day = CalendarDay(year: 2026, month: 10, day: 20)
        let local = day.adding(days: -1)
        let airingAt = Int(at(local, 23, 45).timeIntervalSince1970)
        let http = CalendarAnimeTimesMockHTTP(
            arm: [
                "/api/v2/themoviedb:1": #"[{"anilist":100}]"#,
                "/api/v2/imdb:tt2": #"[{"anilist":200}]"#,
            ],
            anilist: #"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"airingSchedules":[{"airingAt":\#(airingAt),"episode":4,"mediaId":200}]}}}"#
        )
        let times = CalendarAnimeTimes(http: http, timeZone: prague, cache: .init())
        let out = await times.apply(
            to: [entry(1, ep: 1, on: day), entry(2, ep: 4, on: day)],
            imdbByTmdb: [2: "tt2"],
            first: CalendarDay(year: 2026, month: 10, day: 1),
            last: CalendarDay(year: 2026, month: 10, day: 31)
        )
        XCTAssertEqual(out[0].date, day)
        XCTAssertEqual(out[1].date, local)
        XCTAssertEqual(http.postCount, 1)
    }
}

// MARK: - Readable titles

final class CalendarReadableTitleTests: XCTestCase {
    func testDetectsNonLatinScript() {
        XCTAssertTrue(CalendarText.isNonLatin("薬屋のひとりごと"))
        XCTAssertTrue(CalendarText.isNonLatin("나 혼자만 레벨업"))
        XCTAssertFalse(CalendarText.isNonLatin("The Apothecary Diaries"))
        XCTAssertFalse(CalendarText.isNonLatin("Šílenství"))
        XCTAssertTrue(CalendarText.isNonLatin("क्योंकि सास भी कभी बहू थी"))
        XCTAssertTrue(CalendarText.isNonLatin("บุพเพสันนิวาส"))
        XCTAssertFalse(CalendarText.isNonLatin("Слово пацана"))
        XCTAssertTrue(CalendarText.readsNonLatin("hi-IN"))
        XCTAssertFalse(CalendarText.readsNonLatin("cs-CZ"))
    }

    func testTvDetailsFallsBackToEnglish() throws {
        let json = #"""
        {"id":1,"name":"薬屋のひとりごと","translations":{"translations":[
          {"iso_639_1":"ja","data":{"name":""}},
          {"iso_639_1":"en","data":{"name":"The Apothecary Diaries"}}]}}
        """#
        let details = try JSONDecoder().decode(CalendarTmdb.TvDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.readableName, "The Apothecary Diaries")
        XCTAssertEqual(CalendarTmdb.TvDetails(id: 2, name: "Ordinace").readableName, "Ordinace")
    }

    func testCalendarUsesReadableNameAndDropsCJKEpisodeTitles() {
        let item = CalendarItem(id: "tt1", kind: .series, name: "薬屋のひとりごと")
        let details = CalendarTmdb.TvDetails(id: 1, name: "薬屋のひとりごと", translations: .init(translations: [
            .init(language: "en", data: .init(name: "The Apothecary Diaries")),
        ]))
        let episodes = [CalendarTmdb.Episode(airDate: "2026-10-20", episodeNumber: 1, seasonNumber: 3, name: "第1話")]
        let entries = CalendarBuilder.episodeEntries(
            item: item, details: details, episodes: episodes,
            first: CalendarDay(year: 2026, month: 10, day: 1), last: CalendarDay(year: 2026, month: 10, day: 31)
        )
        XCTAssertEqual(entries.first?.title, "The Apothecary Diaries")
        XCTAssertNil(entries.first?.episodeName)
    }
}

// MARK: - Opening an episode whose season numbering differs

final class DetailsEpisodeFocusTests: XCTestCase {
    private let videos = [
        NuvioVideo(id: "tt1:2:3", title: "Old S2E3", season: 2, episode: 3, released: "2005-03-01T00:00:00.000Z"),
        NuvioVideo(id: "tt1:17:3", title: "TYBW", season: 17, episode: 3, released: "2026-10-19T15:00:00.000Z"),
        NuvioVideo(id: "tt1:17:4", title: "TYBW next", season: 17, episode: 4, released: "2026-10-26T15:00:00.000Z"),
    ]

    func testSameNumberWinsWhenItsDateAgrees() {
        let focus = DetailsEpisodeFocus(metaID: "tt1", season: 17, episode: 4, airDate: CalendarDay(year: 2026, month: 10, day: 27))
        XCTAssertEqual(focus.pick(from: videos)?.id, "tt1:17:4")
    }

    func testFindsTheEpisodeByDateWhenSeasonsDiffer() {
        // TMDB calls it S2E3; the addon has it as S17E3.
        let focus = DetailsEpisodeFocus(metaID: "tt1", season: 2, episode: 3, airDate: CalendarDay(year: 2026, month: 10, day: 19))
        XCTAssertEqual(focus.pick(from: videos)?.id, "tt1:17:3")
    }

    func testFallsBackToTheNumberWithoutADateMatch() {
        let focus = DetailsEpisodeFocus(metaID: "tt1", season: 2, episode: 3, airDate: CalendarDay(year: 2030, month: 1, day: 1))
        XCTAssertEqual(focus.pick(from: videos)?.id, "tt1:2:3")
        let noDate = DetailsEpisodeFocus(metaID: "tt1", season: 2, episode: 3)
        XCTAssertEqual(noDate.pick(from: videos)?.id, "tt1:2:3")
    }
}

// MARK: - "In calendar" list

final class CalendarLibraryListTests: XCTestCase {
    func testUnnamedAutomaticItemUsesResolvedTMDBIDInsteadOfBlankTitle() {
        let items = CalendarSuggestions.calendarItems(
            manualFollows: [:],
            automaticFollows: ["series:5": CalendarItem(id: "tt5", kind: .series, tmdbId: 5)],
            resolvedManualFollows: [:],
            nextDates: [:],
            skipped: [:],
            today: CalendarDay(year: 2026, month: 10, day: 19)
        )

        XCTAssertEqual(items.first?.title, "TMDB # 5")
    }

    func testResolvedTMDBKeyBridgesManualIMDbFollowToAutomaticAlias() {
        let today = CalendarDay(year: 2026, month: 10, day: 19)
        let manualItem = CalendarItem(id: "tt123", kind: .series, type: "anime", name: "Anime", imdbId: "tt123")
        let automaticAlias = CalendarItem(id: "tmdb:123", kind: .series, name: "Anime", tmdbId: 123)
        let manual: [String: CalendarItem] = ["series:tt123": manualItem]
        let resolved: [String: CalendarItem] = ["series:123": manualItem]
        let automatic: [String: CalendarItem] = ["series:123": automaticAlias]

        let current = CalendarSuggestions.calendarItems(
            manualFollows: manual,
            automaticFollows: automatic,
            resolvedManualFollows: resolved,
            nextDates: [:],
            skipped: [:],
            today: today
        )
        let categorySuggestion = CalendarSuggestionItem(
            key: "series:123", kind: .series, tmdbId: 123, imdbId: nil,
            title: "Anime", posterURL: nil, year: nil
        )
        let matchedManualKey = CalendarManualFollowStore.matchingKey(
            for: categorySuggestion,
            in: manual,
            resolvedManualFollows: resolved
        )

        XCTAssertEqual(current.count, 1)
        XCTAssertTrue(current[0].isAutomaticallyFollowed)
        XCTAssertEqual(matchedManualKey, "series:tt123")

        let afterManualRemoval = CalendarSuggestions.calendarItems(
            manualFollows: [:],
            automaticFollows: automatic,
            resolvedManualFollows: resolved,
            nextDates: [:],
            skipped: [:],
            today: today
        )
        XCTAssertEqual(afterManualRemoval.count, 1)
        XCTAssertTrue(afterManualRemoval[0].isAutomaticallyFollowed)
    }

    func testListsManualAndAutomaticFollowsAndKeepsOldMoviesRemovable() {
        let today = CalendarDay(year: 2026, month: 10, day: 19)
        let manual: [String: CalendarItem] = [
            "series:2": CalendarItem(id: "tt2", kind: .series, name: "Zeta", imdbId: "tt2", tmdbId: 2),
            "series:1": CalendarItem(id: "tt1", kind: .series, name: "Beta", imdbId: "tt1", tmdbId: 1),
            "movie:3": CalendarItem(id: "tmdb:3", kind: .movie, name: "Gamma", year: 1999, tmdbId: 3),
        ]
        let automatic = [
            "series:2": CalendarItem(id: "tt2", kind: .series, name: "Zeta", imdbId: "tt2", tmdbId: 2),
            "series:4": CalendarItem(id: "tt4", kind: .series, name: "Auto Only", imdbId: "tt4", tmdbId: 4),
        ]
        let items = CalendarSuggestions.calendarItems(
            manualFollows: manual,
            automaticFollows: automatic,
            resolvedManualFollows: [
                "series:1": manual["series:1"]!,
                "series:2": manual["series:2"]!,
                "movie:3": manual["movie:3"]!,
            ],
            nextDates: ["series:1": today, "series:2": today.adding(days: 1)],
            skipped: [:],
            today: today
        )
        XCTAssertEqual(items.map(\.title), ["Auto Only", "Beta", "Gamma", "Zeta"])
        XCTAssertEqual(items[1].tmdbId, 1)
        XCTAssertEqual(items[1].imdbId, "tt1")
        XCTAssertEqual(items.first?.isAutomaticallyFollowed, true)
        XCTAssertEqual(items.first?.type, "series")
        XCTAssertEqual(items.first(where: { $0.title == "Gamma" })?.tmdbId, 3)
        XCTAssertEqual(items.first(where: { $0.title == "Zeta" })?.isAutomaticallyFollowed, true)
        XCTAssertEqual(CalendarSuggestionList.inCalendar.group, .calendar)
    }
}
