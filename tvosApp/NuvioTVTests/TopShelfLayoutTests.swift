import Foundation
import XCTest
@testable import NuvioTV

final class TopShelfLayoutTests: XCTestCase {
    // MARK: Rows

    func testDefaultShowsTheFixedSectionsAndTheFirstCatalog() {
        let feeds = makeFeeds()
        let rows = TopShelfComposer.rows(configuration: .default) { feeds[$0] }
        XCTAssertEqual(rows.map(\.id), ["continueWatching", "upNext", "library", "catalog:popular"])
        XCTAssertEqual(rows.last?.title, "Popular")
    }

    func testChosenCatalogsComeInHomeOrderAfterTheChosenSections() {
        let feeds = makeFeeds()
        var configuration = TopShelfConfiguration.default
        configuration.includesUpNext = false
        configuration.includesLibrary = false
        configuration.catalogRowIDs = ["trending", "popular"]
        let rows = TopShelfComposer.rows(configuration: configuration) { feeds[$0] }
        XCTAssertEqual(rows.map(\.id), ["continueWatching", "catalog:popular", "catalog:trending"])
    }

    func testNoChosenCatalogShowsNoneAndGoneCatalogsFallBackToTheFirst() {
        let feeds = makeFeeds()
        var configuration = TopShelfConfiguration(
            includesContinueWatching: false, includesUpNext: false, includesLibrary: false, catalogRowIDs: [])
        XCTAssertTrue(TopShelfComposer.rows(configuration: configuration) { feeds[$0] }.isEmpty)
        configuration.catalogRowIDs = ["removed"]
        XCTAssertEqual(TopShelfComposer.rows(configuration: configuration) { feeds[$0] }.map(\.id), ["catalog:popular"])
    }

    func testCatalogFeedFromBeforeRowsIsTheFirstCatalog() {
        let legacy = TopShelfFeed(entries: entries("old", count: 3), title: "Popular - Movies")
        let rows = TopShelfComposer.rows(
            configuration: TopShelfConfiguration(includesContinueWatching: false, includesUpNext: false, includesLibrary: false)
        ) { $0 == .catalog ? legacy : nil }
        XCTAssertEqual(rows.map(\.id), ["catalog:catalog"])
        XCTAssertEqual(rows.first?.entries.count, 3)
        XCTAssertEqual(rows.first?.title, "Popular - Movies")
    }

    func testEmptySourcesAreLeftOut() {
        var feeds = makeFeeds()
        feeds[.upNext] = TopShelfFeed(entries: [], title: "Up Next")
        let rows = TopShelfComposer.rows(configuration: .default) { feeds[$0] }
        XCTAssertFalse(rows.contains { $0.id == "upNext" })
    }

    func testTodayComesAfterUpNextAndOnlyForItsDay() {
        var feeds = makeFeeds()
        let airing = TopShelfEntry(contentId: "tt-today", contentType: "series", title: "Airing", subtitle: "S2E5",
                                   imageURL: nil, progress: nil, action: .details, airDate: "2026-10-29")
        let yesterday = TopShelfEntry(contentId: "tt-old", contentType: "series", title: "Old", subtitle: nil,
                                      imageURL: nil, progress: nil, action: .details, airDate: "2026-10-28")
        feeds[.today] = TopShelfFeed(entries: [airing, yesterday], title: "Today")
        let rows = TopShelfComposer.rows(configuration: .default, today: "2026-10-29") { feeds[$0] }
        XCTAssertEqual(rows.map(\.id), ["continueWatching", "upNext", "today", "library", "catalog:popular"])
        XCTAssertEqual(rows.first { $0.id == "today" }?.entries.map(\.contentId), ["tt-today"])
        let nextDay = TopShelfComposer.rows(configuration: .default, today: "2026-10-30") { feeds[$0] }
        XCTAssertFalse(nextDay.contains { $0.id == "today" }, "past days leave the shelf without the app")
        var off = TopShelfConfiguration.default
        off.includesToday = false
        XCTAssertFalse(TopShelfComposer.rows(configuration: off, today: "2026-10-29") { feeds[$0] }.contains { $0.id == "today" })
    }

    func testDayIsTheLocalCalendarDay() {
        let utc = TimeZone(identifier: "UTC")!
        let prague = TimeZone(identifier: "Europe/Prague")!
        let lateEvening = Date(timeIntervalSince1970: 1_793_316_600) // 2026-10-29 23:30 UTC
        XCTAssertEqual(TopShelfComposer.day(of: lateEvening, timeZone: utc), "2026-10-29")
        XCTAssertEqual(TopShelfComposer.day(of: lateEvening, timeZone: prague), "2026-10-30")
    }

    // MARK: Ratings

    func testRatingsRenameTheCarouselImageSoNewScoresRedrawIt() {
        let entry = TopShelfEntry(contentId: "tt1", contentType: "movie", title: "A", subtitle: nil, imageURL: nil,
                                  progress: nil, action: .details, carouselArtworkFileName: "top-shelf-c1.jpg")
        let imdb = TopShelfRatingBadge(source: "imdb", name: "IMDb", value: "8.1", iconAssetName: "rating_imdb",
                                       iconURL: nil, iconWidth: 68)
        let newer = TopShelfRatingBadge(source: "imdb", name: "IMDb", value: "8.2", iconAssetName: "rating_imdb",
                                        iconURL: nil, iconWidth: 68)
        XCTAssertEqual(TopShelfFeedStore.carouselImageName(for: entry, badges: nil), "top-shelf-c1.jpg")
        XCTAssertEqual(TopShelfFeedStore.carouselImageName(for: entry, badges: []), "top-shelf-c1.jpg")
        let rated = TopShelfFeedStore.carouselImageName(for: entry, badges: [imdb])
        XCTAssertNotEqual(rated, "top-shelf-c1.jpg")
        XCTAssertEqual(rated, TopShelfFeedStore.carouselImageName(for: entry, badges: [imdb]))
        XCTAssertNotEqual(rated, TopShelfFeedStore.carouselImageName(for: entry, badges: [newer]))
    }

    func testRatingsAreFreshForADay() {
        let now = Date()
        XCTAssertTrue(TopShelfRatingsStore.isFresh(.init(badges: [], fetchedAt: now.addingTimeInterval(-3_600)), now: now))
        XCTAssertFalse(TopShelfRatingsStore.isFresh(.init(badges: [], fetchedAt: now.addingTimeInterval(-90_000)), now: now))
        XCTAssertFalse(TopShelfRatingsStore.isFresh(nil, now: now))
    }

    // MARK: Carousel

    func testCarouselGivesEverySourceItsShareThenTopsUpInTurn() {
        let rows = [
            row("continueWatching", entries("cw", count: 10)),
            row("catalog:popular", entries("pop", count: 15)),
        ]
        let slots = TopShelfComposer.carousel(from: rows)
        XCTAssertEqual(slots.count, 15)
        // A share of 7 each, then one more round from the first source; grouped by source.
        XCTAssertEqual(slots.filter { $0.rowID == "continueWatching" }.count, 8)
        XCTAssertEqual(slots.filter { $0.rowID == "catalog:popular" }.count, 7)
        XCTAssertEqual(slots.first?.rowID, "continueWatching")
        XCTAssertEqual(slots.last?.rowID, "catalog:popular")
    }

    func testCarouselGivesASmallSourceAllItHasAndShowsATitleOnce() {
        let shared = entry("tt-shared")
        let rows = [
            row("continueWatching", [shared, entry("cw-2")]),
            row("library", entries("lib", count: 2)),
            row("catalog:popular", [shared] + entries("pop", count: 20)),
        ]
        let slots = TopShelfComposer.carousel(from: rows)
        XCTAssertEqual(slots.count, 15)
        XCTAssertEqual(slots.filter { $0.entry.contentId == "tt-shared" }.count, 1)
        XCTAssertEqual(slots.first { $0.entry.contentId == "tt-shared" }?.rowID, "continueWatching")
        XCTAssertEqual(slots.filter { $0.rowID == "catalog:popular" }.count, 11)
    }

    func testCarouselShareIsAtLeastThree() {
        let rows = (0..<6).map { row("catalog:c\($0)", entries("c\($0)", count: 10)) }
        let slots = TopShelfComposer.carousel(from: rows)
        XCTAssertEqual(slots.count, 15)
        XCTAssertEqual(slots.filter { $0.rowID == "catalog:c0" }.count, 3)
        XCTAssertEqual(slots.filter { $0.rowID == "catalog:c5" }.count, 0)
    }

    // MARK: Configuration

    func testConfigurationReadsMissingAndUnknownValuesAsDefaults() throws {
        let partial = try JSONDecoder().decode(
            TopShelfConfiguration.self,
            from: Data(#"{"style":"sideways","includesLibrary":false,"catalogRowIDs":["a"]}"#.utf8))
        XCTAssertEqual(partial.style, .carouselDetails)
        XCTAssertTrue(partial.includesContinueWatching)
        XCTAssertFalse(partial.includesLibrary)
        XCTAssertEqual(partial.catalogRowIDs, ["a"])
        let empty = try JSONDecoder().decode(TopShelfConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .default)
    }

    func testEntryFromAnEarlierFeedStillDecodes() throws {
        let json = #"{"contentId":"tt1","contentType":"movie","title":"A","progress":0.5,"artworkFileName":"top-shelf-a1.jpg"}"#
        let entry = try JSONDecoder().decode(TopShelfEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.artworkFileName, "top-shelf-a1.jpg")
        XCTAssertNil(entry.carouselArtworkFileName)
        XCTAssertNil(entry.summary)
        XCTAssertEqual(entry.deepLinkURL?.host, "continue-watching")
        XCTAssertEqual(entry.detailsURL?.host, "details")
    }

    func testRuntimeTextBecomesMinutes() {
        XCTAssertEqual(TopShelfEntry.runtimeMinutes("142 min"), 142)
        XCTAssertEqual(TopShelfEntry.runtimeMinutes("2h 22m"), 142)
        XCTAssertEqual(TopShelfEntry.runtimeMinutes("2 hr 5 min"), 125)
        XCTAssertEqual(TopShelfEntry.runtimeMinutes("1:58"), 118)
        XCTAssertEqual(TopShelfEntry.runtimeMinutes("45"), 45)
        XCTAssertNil(TopShelfEntry.runtimeMinutes("N/A"))
        XCTAssertNil(TopShelfEntry.runtimeMinutes(nil))
    }

    // MARK: Artwork sources

    func testArtworkIsFetchedAtTheLargestSizeTheHostServesThenAsGiven() {
        func candidates(_ text: String) -> [String] {
            TopShelfFeedStore.highResolutionCandidates(for: text).map(\.absoluteString)
        }
        XCTAssertEqual(candidates("https://image.tmdb.org/t/p/w1280/abc.jpg"),
                       ["https://image.tmdb.org/t/p/original/abc.jpg", "https://image.tmdb.org/t/p/w1280/abc.jpg"])
        XCTAssertEqual(candidates("https://image.tmdb.org/t/p/original/abc.jpg"),
                       ["https://image.tmdb.org/t/p/original/abc.jpg"])
        XCTAssertEqual(candidates("https://images.metahub.space/background/medium/tt0111161/img"),
                       ["https://images.metahub.space/background/large/tt0111161/img",
                        "https://images.metahub.space/background/medium/tt0111161/img"])
        XCTAssertEqual(candidates("https://assets.fanart.tv/preview/movies/1/moviebackground/a.jpg"),
                       ["https://assets.fanart.tv/fanart/movies/1/moviebackground/a.jpg",
                        "https://assets.fanart.tv/preview/movies/1/moviebackground/a.jpg"])
        XCTAssertEqual(candidates("https://cdn.example.test/art.jpg"), ["https://cdn.example.test/art.jpg"])
    }

    // MARK: Pruning

    func testPruningKeepsBothRendersOfShownTitlesAndDropsUnchosenCatalogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shownCard = "top-shelf-a1.jpg", shownCarousel = "top-shelf-a2.jpg"
        let hiddenCard = "top-shelf-b1.jpg", hiddenCarousel = "top-shelf-b2.jpg"
        for name in [shownCard, shownCarousel, hiddenCard, hiddenCarousel] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        let shown = TopShelfEntry(contentId: "tt-a", contentType: "movie", title: "A", subtitle: nil, imageURL: nil,
                                  progress: nil, action: .details, artworkFileName: shownCard,
                                  carouselArtworkFileName: shownCarousel)
        let hidden = TopShelfEntry(contentId: "tt-b", contentType: "movie", title: "B", subtitle: nil, imageURL: nil,
                                   progress: nil, action: .details, artworkFileName: hiddenCard,
                                   carouselArtworkFileName: hiddenCarousel)
        let feed = TopShelfFeed(entries: [], rows: [
            TopShelfFeedRow(id: "popular", title: "Popular", entries: [shown]),
            TopShelfFeedRow(id: "trending", title: "Trending", entries: [hidden]),
        ])
        try JSONEncoder().encode(feed).write(to: directory.appendingPathComponent(TopShelfSection.catalog.feedFileName))
        TopShelfConfigurationStore.write(TopShelfConfiguration(catalogRowIDs: ["popular"]), in: directory)

        TopShelfArtworkPruner.prune(in: directory)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertTrue(remaining.isSuperset(of: [shownCard, shownCarousel]))
        XCTAssertTrue(remaining.isDisjoint(with: [hiddenCard, hiddenCarousel]))
    }

    func testPruningKeepsThePostersOfShownTitles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-posters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shown = posterEntry("tt-a", poster: "https://image.tmdb.org/t/p/w500/a.jpg")
        let hidden = posterEntry("tt-b", poster: "https://image.tmdb.org/t/p/w500/b.jpg")
        let shownPoster = try XCTUnwrap(TopShelfFeedStore.posterArtworkName(for: shown))
        let hiddenPoster = try XCTUnwrap(TopShelfFeedStore.posterArtworkName(for: hidden))
        for name in [shownPoster, hiddenPoster] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        let feed = TopShelfFeed(entries: [], rows: [
            TopShelfFeedRow(id: "popular", title: "Popular", entries: [shown]),
            TopShelfFeedRow(id: "trending", title: "Trending", entries: [hidden]),
        ])
        try JSONEncoder().encode(feed).write(to: directory.appendingPathComponent(TopShelfSection.catalog.feedFileName))
        TopShelfConfigurationStore.write(TopShelfConfiguration(style: .posters, catalogRowIDs: ["popular"]), in: directory)

        TopShelfArtworkPruner.prune(in: directory)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertTrue(remaining.contains(shownPoster))
        XCTAssertFalse(remaining.contains(hiddenPoster))
    }

    // MARK: Posters

    func testPostersAreRowsOfEveryChosenTitle() throws {
        let posters = try JSONDecoder().decode(TopShelfConfiguration.self, from: Data(#"{"style":"posters"}"#.utf8))
        XCTAssertEqual(posters.style, .posters)
        XCTAssertFalse(posters.style.isCarousel)
        XCTAssertTrue(TopShelfConfiguration.Style.carouselActions.isCarousel)
        let feeds = makeFeeds()
        let rows = TopShelfComposer.rows(configuration: posters) { feeds[$0] }
        XCTAssertEqual(TopShelfComposer.displayedEntries(configuration: posters, rows: rows).count,
                       rows.flatMap(\.entries).count)
    }

    func testPosterIsDrawnFromThePosterAndRedrawnForANewPill() {
        let poster = posterEntry("tt1", poster: "https://image.tmdb.org/t/p/w500/p.jpg",
                                 backdrop: "https://image.tmdb.org/t/p/w1280/b.jpg")
        XCTAssertEqual(poster.posterSourceURL, "https://image.tmdb.org/t/p/w500/p.jpg")
        let backdropOnly = posterEntry("tt1", poster: nil, backdrop: "https://image.tmdb.org/t/p/w1280/b.jpg")
        XCTAssertEqual(backdropOnly.posterSourceURL, "https://image.tmdb.org/t/p/w1280/b.jpg")
        XCTAssertNil(TopShelfFeedStore.posterArtworkName(for: posterEntry("tt1", poster: nil)))

        let name = TopShelfFeedStore.posterArtworkName(for: poster)
        XCTAssertEqual(name, TopShelfFeedStore.posterArtworkName(for: poster))
        XCTAssertNotEqual(name, TopShelfFeedStore.posterArtworkName(
            for: posterEntry("tt1", poster: "https://image.tmdb.org/t/p/w500/p.jpg",
                             backdrop: "https://image.tmdb.org/t/p/w1280/b.jpg", subtitle: "S1 · E2")))
        XCTAssertTrue(name?.hasPrefix("top-shelf-") == true)
    }

    func testMergedUpNextSharesContinueWatchingInHomeOrder() {
        func item(_ id: String, _ order: Int?) -> TopShelfEntry {
            TopShelfEntry(contentId: id, contentType: "series", title: id, subtitle: nil, imageURL: nil,
                          progress: nil, homeOrder: order)
        }
        let feeds: [TopShelfSection: TopShelfFeed] = [
            .continueWatching: TopShelfFeed(entries: [item("a", 0), item("c", 3)], title: "Continue Watching"),
            .upNext: TopShelfFeed(entries: [item("b", 1), item("d", 4), item("a", 2)], title: "Up Next"),
        ]
        var configuration = TopShelfConfiguration(mergesUpNext: true)
        let merged = TopShelfComposer.rows(configuration: configuration) { feeds[$0] }
        XCTAssertEqual(merged.map(\.id), ["continueWatching"])
        XCTAssertEqual(merged.first?.title, "Continue Watching")
        XCTAssertEqual(merged.first?.entries.map(\.contentId), ["a", "b", "c", "d"])

        configuration.mergesUpNext = false
        XCTAssertEqual(TopShelfComposer.rows(configuration: configuration) { feeds[$0] }.map(\.id),
                       ["continueWatching", "upNext"])
        // Up Next alone still shows, in the merged row.
        configuration = TopShelfConfiguration(mergesUpNext: true)
        let upNextOnly = TopShelfComposer.rows(configuration: configuration) { $0 == .upNext ? feeds[$0] : nil }
        XCTAssertEqual(upNextOnly.first?.entries.map(\.contentId), ["b", "a", "d"])
    }

    func testMergedUpNextFromAnOlderFeedFollowsContinueWatching() {
        let merged = TopShelfComposer.homeOrdered(entries("cw", count: 2), entries("next", count: 2))
        XCTAssertEqual(merged.map(\.contentId), ["cw-0", "cw-1", "next-0", "next-1"])
        XCTAssertFalse(TopShelfConfiguration.default.mergesUpNext)
    }

    // MARK: Trailers

    func testTrailersArePlayedUnlessTurnedOff() throws {
        XCTAssertTrue(TopShelfConfiguration.default.playsTrailers)
        let off = try JSONDecoder().decode(TopShelfConfiguration.self, from: Data(#"{"playsTrailers":false}"#.utf8))
        XCTAssertFalse(off.playsTrailers)
    }

    func testTrailerWithTheBestPictureIsPicked() {
        func pick(_ providers: [String]) -> String? {
            TopShelfTrailerPicker.best(providers.map {
                TopShelfTrailerLink(url: "https://cdn.example.test/\($0.count).m3u8", provider: $0)
            })?.provider
        }
        // Resolution first, then Dolby Vision over HDR, then the sound.
        XCTAssertEqual(pick(["Apple TV 1080p 5.1", "Plex 4K", "⭐ Apple TV 4K HDR 5.1", "Apple TV 4K DV Atmos"]),
                       "Apple TV 4K DV Atmos")
        XCTAssertEqual(pick(["⭐ Apple TV 1080p 5.1", "Plex 4K"]), "Plex 4K")
        XCTAssertEqual(pick(["MUBI 720p", "Plex 1080p"]), "Plex 1080p")
        // The same picture: Apple TV first, as on Details.
        XCTAssertEqual(pick(["Rotten Tomatoes 1080p", "Apple TV 1080p"]), "Apple TV 1080p")
        XCTAssertEqual(pick(["Apple TV 1080p", "Apple TV 1080p 5.1", "Apple TV 1080p Atmos"]), "Apple TV 1080p Atmos")
        XCTAssertNil(pick([]))
    }

    func testTrailerHLSBeatsASingleFileOfTheSamePicture() {
        let file = TopShelfTrailerLink(url: "https://cdn.example.test/a.mp4", provider: "Apple TV 1080p")
        let stream = TopShelfTrailerLink(url: "https://cdn.example.test/a.m3u8?x=1", provider: "Apple TV 1080p")
        XCTAssertEqual(TopShelfTrailerPicker.best([file, stream]), stream)
        XCTAssertEqual(TopShelfTrailerPicker.best([stream, stream]), stream)
    }

    func testTrailerioResponseKeepsOnlyWebLinks() throws {
        let json = #"""
        {"meta":{"id":"tt1","links":[
          {"trailers":"https://play-edge.itunes.apple.com/a/master.m3u8","provider":"Apple TV 4K HDR 5.1"},
          {"trailers":"  ","provider":"Empty"},
          {"trailers":"ftp://example.test/a.mp4","provider":"FTP"},
          {"provider":"No link"},
          {"trailers":"https://video.fandango.com/a.mp4"}
        ]}}
        """#
        let links = try XCTUnwrap(TopShelfTrailerResolver.links(from: Data(json.utf8)))
        XCTAssertEqual(links.map(\.url), ["https://play-edge.itunes.apple.com/a/master.m3u8",
                                          "https://video.fandango.com/a.mp4"])
        XCTAssertEqual(links.map(\.provider), ["Apple TV 4K HDR 5.1", ""])
        XCTAssertEqual(TopShelfTrailerResolver.links(from: Data(#"{"meta":null}"#.utf8)), [])
        XCTAssertNil(TopShelfTrailerResolver.links(from: Data("<html>busy</html>".utf8)))
    }

    func testTrailerIsLookedUpByIMDbIdAndKind() {
        func url(_ id: String, _ type: String, imdb: String? = nil) -> String? {
            TopShelfTrailerResolver.lookupURL(for: TopShelfEntry(
                contentId: id, contentType: type, title: id, subtitle: nil, imageURL: nil,
                progress: nil, imdbId: imdb))?.absoluteString
        }
        XCTAssertEqual(url("tt0816692", "movie"), "https://trailerio.cc/meta/movie/tt0816692.json")
        XCTAssertEqual(url("tt0903747:1:2", "series"), "https://trailerio.cc/meta/series/tt0903747.json")
        XCTAssertEqual(url("tmdb:1396", "tv", imdb: "tt0903747"), "https://trailerio.cc/meta/series/tt0903747.json")
        XCTAssertNil(url("kitsu:1", "anime"))
    }

    func testTitlesWithATrailerAreLookedUpEveryTimeAndThoseWithoutOnceADay() {
        typealias Record = TopShelfTrailerStore.Record
        let now = Date()
        let link = TopShelfTrailerLink(url: "https://cdn.example.test/a.m3u8", provider: "Apple TV 1080p")
        func needsLookup(_ record: Record?) -> Bool { TopShelfTrailerStore.needsLookup(record, now: now) }
        XCTAssertTrue(needsLookup(nil))
        XCTAssertTrue(needsLookup(Record(link: link, fetchedAt: now)))
        XCTAssertFalse(needsLookup(Record(link: nil, fetchedAt: now.addingTimeInterval(-3_600))))
        XCTAssertTrue(needsLookup(Record(link: nil, fetchedAt: now.addingTimeInterval(-90_000))))
    }

    func testSavedTrailersStandInAndTitlesNoLongerShownAreForgotten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-trailers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let link = TopShelfTrailerLink(url: "https://cdn.example.test/a.m3u8", provider: "Apple TV 1080p")
        // Neither title can be looked up (no IMDb id), so nothing goes online.
        TopShelfTrailerStore.write([
            "kitsu:1": .init(link: link, fetchedAt: now.addingTimeInterval(-600)),
            "kitsu:2": .init(link: nil, fetchedAt: now.addingTimeInterval(-600)),
            "kitsu:gone": .init(link: link, fetchedAt: now.addingTimeInterval(-600)),
        ], in: directory)
        let shown = ["kitsu:1", "kitsu:2"].map {
            TopShelfEntry(contentId: $0, contentType: "anime", title: $0, subtitle: nil, imageURL: nil, progress: nil)
        }
        let trailers = await TopShelfTrailerResolver.trailers(for: shown, in: directory, now: now)
        XCTAssertEqual(trailers, ["kitsu:1": link])
        XCTAssertEqual(Set(TopShelfTrailerStore.read(in: directory).keys), ["kitsu:1", "kitsu:2"])
    }

    // MARK: Helpers

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
