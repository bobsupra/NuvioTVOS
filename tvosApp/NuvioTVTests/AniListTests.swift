import ImageIO
import XCTest
@testable import NuvioTV

final class AniListTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func page(_ json: String) throws -> [AniListMedia] {
        try XCTUnwrap(decoder.decode(AniListPageResponse.self, from: Data(json.utf8)).data?.Page?.media)
    }

    /// Season 1 (TV) → Season 2 (TV) → Season 3 (TV, not fetched yet), with an OVA, a film
    /// and the manga around them.
    private let franchise = """
    {"data":{"Page":{"media":[
      {"id":101,"type":"ANIME","format":"TV","status":"FINISHED","episodes":2,"seasonYear":2020,
       "title":{"romaji":"Kaiju Sentai","english":"Monster Squad","native":"怪獣戦隊"},
       "coverImage":{"extraLarge":"https://img/101.jpg"},"bannerImage":"https://img/101b.jpg",
       "description":"A squad.<br><br><i>(Source: AniList)</i> &amp; more","averageScore":82,"genres":["Action"],
       "startDate":{"year":2020,"month":4,"day":3},"endDate":{"year":2020,"month":6,"day":19},"duration":24,
       "trailer":{"id":"abc123","site":"youtube"},
       "airingSchedule":{"nodes":[{"episode":1,"airingAt":1585900800},{"episode":2,"airingAt":1586505600}]},
       "streamingEpisodes":[{"title":"Episode 2 - The Return","thumbnail":"https://img/e2.jpg"},{"title":"Episode 1 - The Squad","thumbnail":"https://img/e1.jpg"}],
       "relations":{"edges":[
         {"relationType":"SEQUEL","node":{"id":102,"type":"ANIME","format":"TV","startDate":{"year":2021,"month":1}}},
         {"relationType":"SIDE_STORY","node":{"id":150,"type":"ANIME","format":"OVA","seasonYear":2020,"title":{"romaji":"Kaiju Sentai OVA"},"startDate":{"year":2020,"month":9}}},
         {"relationType":"ADAPTATION","node":{"id":900,"type":"MANGA","format":"MANGA","title":{"romaji":"Kaiju Sentai"}}}
       ]}},
      {"id":102,"type":"ANIME","format":"TV","status":"FINISHED","episodes":3,"seasonYear":2021,
       "title":{"romaji":"Kaiju Sentai 2nd Season"},"coverImage":{"large":"https://img/102.jpg"},
       "startDate":{"year":2021,"month":1,"day":8},"endDate":{"year":2021,"month":3,"day":26},
       "relations":{"edges":[
         {"relationType":"PREQUEL","node":{"id":101,"type":"ANIME","format":"TV","startDate":{"year":2020,"month":4}}},
         {"relationType":"SEQUEL","node":{"id":103,"type":"ANIME","format":"TV","startDate":{"year":2023,"month":7}}},
         {"relationType":"SEQUEL","node":{"id":160,"type":"ANIME","format":"MOVIE","seasonYear":2022,"title":{"romaji":"Kaiju Sentai: The Movie"},"startDate":{"year":2022,"month":5}}}
       ]}}
    ]}}}
    """

    private func entries() throws -> [Int: AniListMedia] {
        Dictionary(uniqueKeysWithValues: try page(franchise).map { ($0.id, $0) })
    }

    // MARK: Ids

    func testTheAniListIDIsReadFromTitleAndEpisodeIDs() {
        XCTAssertEqual(AniListMetaBuilder.aniListID(from: "anilist:154587"), 154587)
        XCTAssertEqual(AniListMetaBuilder.aniListID(from: "anilist:154587:5"), 154587)
        XCTAssertEqual(AniListMetaBuilder.aniListID(from: " ANILIST:12 "), 12)
        XCTAssertNil(AniListMetaBuilder.aniListID(from: "tt0903747"))
        XCTAssertNil(AniListMetaBuilder.aniListID(from: "anilist:"))
        XCTAssertNil(AniListMetaBuilder.aniListID(from: "kitsu:12"))
        XCTAssertEqual(AniListMetaBuilder.episodeID(entry: 182255, episode: 5), "anilist:182255:5")
    }

    // MARK: Text

    func testTitlesFollowTheChosenLanguageWithFallbacks() {
        let full = AniListTitle(romaji: "Sousou no Frieren", english: "Frieren: Beyond Journey's End", native: "葬送のフリーレン")
        XCTAssertEqual(AniListMetaBuilder.title(full, language: .romaji), "Sousou no Frieren")
        XCTAssertEqual(AniListMetaBuilder.title(full, language: .english), "Frieren: Beyond Journey's End")
        XCTAssertEqual(AniListMetaBuilder.title(full, language: .native), "葬送のフリーレン")
        let romajiOnly = AniListTitle(romaji: "Kaiju Sentai", english: " ", native: nil)
        XCTAssertEqual(AniListMetaBuilder.title(romajiOnly, language: .english), "Kaiju Sentai")
        XCTAssertEqual(AniListMetaBuilder.title(nil, language: .romaji), "Unknown")
    }

    func testDescriptionsLoseTheirHTML() {
        XCTAssertEqual(
            AniListMetaBuilder.plainText("A squad.<br><br><i>(Source: AniList)</i> &amp; more"),
            "A squad.\n\n(Source: AniList) & more"
        )
        XCTAssertNil(AniListMetaBuilder.plainText("<br>"))
        XCTAssertNil(AniListMetaBuilder.plainText(nil))
    }

    // MARK: Franchise

    func testPrequelsAndSequelsBecomeTabsAndFilmsDoNot() throws {
        let entries = try entries()
        let fromSecond = AniListMetaBuilder.chain(from: 102, entries: entries)
        XCTAssertEqual(fromSecond.ids, [101, 102])
        XCTAssertEqual(fromSecond.missing, [103])

        let fromFirst = AniListMetaBuilder.chain(from: 101, entries: entries)
        XCTAssertEqual(fromFirst.ids, [101, 102])
        XCTAssertEqual(fromFirst.missing, [103])
    }

    func testAnOVAOrAFilmIsATitleOfItsOwn() throws {
        var entries = try entries()
        let ova = AniListMedia(id: 150, type: "ANIME", format: "OVA")
        entries[150] = ova
        XCTAssertEqual(AniListMetaBuilder.chain(from: 150, entries: entries).ids, [150])
        XCTAssertTrue(AniListMetaBuilder.chain(from: 150, entries: entries).missing.isEmpty)
    }

    // MARK: Episodes

    func testEpisodesKeepAniListNumbersAndTheirEntryID() throws {
        let second = try XCTUnwrap(try entries()[102])
        let episodes = AniListMetaBuilder.episodes(of: second, season: 2)
        XCTAssertEqual(episodes.map(\.id), ["anilist:102:1", "anilist:102:2", "anilist:102:3"])
        XCTAssertEqual(episodes.map(\.season), [2, 2, 2])
        XCTAssertEqual(episodes.map(\.episode), [1, 2, 3])
        XCTAssertEqual(episodes.first?.title, "Episode 1")
        XCTAssertEqual(episodes.first?.released, "2021-01-08T00:00:00Z")
    }

    func testEpisodeTitlesComeFromAniZipThenFromStreamingEpisodes() throws {
        let first = try XCTUnwrap(try entries()[101])
        let aniZip = ["2": AniZipEpisode(title: ["en": "Homecoming"], image: "https://zip/2.jpg", overview: "They return.")]
        let episodes = AniListMetaBuilder.episodes(of: first, season: 1, aniZip: aniZip)
        XCTAssertEqual(episodes.map(\.title), ["The Squad", "Homecoming"])
        XCTAssertEqual(episodes[0].thumbnail, "https://img/e1.jpg")
        XCTAssertEqual(episodes[1].thumbnail, "https://zip/2.jpg")
        XCTAssertEqual(episodes[1].overview, "They return.")
        XCTAssertEqual(episodes[0].released, AniListMetaBuilder.isoDate(airingAt: 1585900800))
    }

    func testAnAiringSeriesWithoutATotalShowsUpToTheNextEpisode() {
        let airing = AniListMedia(
            id: 300, type: "ANIME", format: "TV", status: "RELEASING",
            nextAiringEpisode: AniListAiring(episode: 6, airingAt: 1_900_000_000)
        )
        let episodes = AniListMetaBuilder.episodes(of: airing, season: 1, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(episodes.count, 6)
        XCTAssertEqual(episodes.last?.released, AniListMetaBuilder.isoDate(airingAt: 1_900_000_000))
    }

    func testAnAnnouncedTitleWithoutEpisodesHasNone() {
        let announced = AniListMedia(id: 301, type: "ANIME", format: "TV", status: "NOT_YET_RELEASED")
        XCTAssertTrue(AniListMetaBuilder.episodes(of: announced, season: 1).isEmpty)
    }

    func testStreamingEpisodeTitlesAreReadInAnyOrder() {
        let parsed = AniListMetaBuilder.streamingEpisodes([
            AniListStreamingEpisode(title: "Episode 12 - Finale", thumbnail: "t12"),
            AniListStreamingEpisode(title: "Episode 3", thumbnail: "t3"),
            AniListStreamingEpisode(title: "Recap", thumbnail: "x"),
        ])
        XCTAssertEqual(parsed[12]?.title, "Finale")
        XCTAssertNil(parsed[3]?.title ?? nil)
        XCTAssertEqual(parsed[3]?.thumbnail, "t3")
        XCTAssertEqual(parsed.count, 2)
    }

    // MARK: Titles

    func testOneTitleCarriesEveryTabAndAsksAddOnsWithAniListIDs() throws {
        let entries = try entries()
        let tabs = [try XCTUnwrap(entries[101]), try XCTUnwrap(entries[102])]
        let episodes: [Int: [NuvioVideo]] = [
            101: AniListMetaBuilder.episodes(of: tabs[0], season: 1),
            102: AniListMetaBuilder.episodes(of: tabs[1], season: 2),
        ]
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: tabs, episodes: episodes, language: .romaji))
        XCTAssertEqual(meta.id, "anilist:101")
        XCTAssertEqual(meta.type, "series")
        XCTAssertEqual(meta.name, "Kaiju Sentai")
        XCTAssertEqual(meta.releaseInfo, "2020–2021")
        XCTAssertEqual(meta.runtime, "24 min")
        XCTAssertEqual(meta.trailerYtIds, ["abc123"])
        XCTAssertNil(meta.imdbId)
        XCTAssertNil(meta.rating)
        XCTAssertEqual(meta.externalRatings?.first?.source, "anilist")
        XCTAssertEqual(meta.externalRatings?.first?.max, 100)
        XCTAssertEqual(meta.videos?.count, 5)
        XCTAssertTrue(meta.isAnime)

        XCTAssertEqual(meta.streamId, "anilist:101")
        let secondSeasonFirst = try XCTUnwrap(meta.videos?.first { $0.season == 2 && $0.episode == 1 })
        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: secondSeasonFirst), "anilist:102:1")

        XCTAssertEqual(AniListMetaBuilder.tabTitles(tabs, language: .romaji), [1: "TV · 2020", 2: "2nd Season · 2021"])
    }

    func testAFilmIsAMovieWithoutAnEpisodeNumber() throws {
        let film = AniListMedia(id: 160, type: "ANIME", format: "MOVIE", status: "FINISHED", seasonYear: 2022,
                                title: AniListTitle(romaji: "Kaiju Sentai: The Movie"))
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: [film], episodes: [:], language: .romaji))
        XCTAssertEqual(meta.type, "movie")
        XCTAssertNil(meta.videos)
        XCTAssertEqual(meta.streamId, "anilist:160")
        XCTAssertEqual(meta.releaseInfo, "2022")
    }

    func testASingleEpisodeOVAIsASeriesWithEpisodeOne() throws {
        let ova = AniListMedia(id: 150, type: "ANIME", format: "OVA", status: "FINISHED", episodes: 1)
        let episodes = [150: AniListMetaBuilder.episodes(of: ova, season: 1)]
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: [ova], episodes: episodes, language: .romaji))
        XCTAssertEqual(meta.type, "series")
        let only = try XCTUnwrap(meta.videos?.first)
        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: only), "anilist:150:1")
    }

    func testAnEntryWhoseIDEqualsItsSeasonKeepsItsEpisodeID() throws {
        // Cowboy Bebop is AniList 1: "anilist:1:5" also ends in ":1:5" (season 1, episode 5).
        let bebop = AniListMedia(id: 1, type: "ANIME", format: "TV", status: "FINISHED", episodes: 26)
        let episodes = [1: AniListMetaBuilder.episodes(of: bebop, season: 1)]
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: [bebop], episodes: episodes, language: .romaji))
        let fifth = try XCTUnwrap(meta.videos?.first { $0.episode == 5 })
        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: fifth), "anilist:1:5")
    }

    func testTheRelatedRowSkipsTabsAndManga() throws {
        let entries = try entries()
        let tabs = [try XCTUnwrap(entries[101]), try XCTUnwrap(entries[102])]
        let related = AniListMetaBuilder.related(tabs: tabs, language: .romaji)
        XCTAssertEqual(related.map(\.id), ["anilist:160", "anilist:103", "anilist:150"])
        XCTAssertEqual(related.first?.type, "movie")
        XCTAssertEqual(related.first?.year, "Sequel · 2022")
        XCTAssertEqual(related.last?.year, "Side Story · 2020")
    }

    // MARK: Home, Search

    func testSeasonsFollowTheMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4))!
        XCTAssertEqual(AniListSeason.current(at: november, calendar: calendar).season, "FALL")
        XCTAssertEqual(AniListSeason.next(at: november, calendar: calendar).season, "WINTER")
        XCTAssertEqual(AniListSeason.next(at: november, calendar: calendar).year, 2027)
        let february = calendar.date(from: DateComponents(year: 2027, month: 2, day: 1))!
        XCTAssertEqual(AniListSeason.current(at: february, calendar: calendar).season, "WINTER")
        XCTAssertEqual(AniListSeason.next(at: february, calendar: calendar).season, "SPRING")
        XCTAssertEqual(AniListSeason.next(at: february, calendar: calendar).year, 2027)
    }

    func testTheHomeQueryDeclaresOnlyTheVariablesItsRowsUse() {
        let trendingOnly = AniListQueries.homeRows([AniListHomeRow.row(id: "trending")!])
        XCTAssertTrue(trendingOnly.contains("r_trending: Page"))
        XCTAssertFalse(trendingOnly.contains("$season"))
        XCTAssertFalse(trendingOnly.contains("$nextSeason"))

        let all = AniListQueries.homeRows(AniListHomeRow.standard)
        XCTAssertTrue(all.contains("$season: MediaSeason"))
        XCTAssertTrue(all.contains("$nextSeason: MediaSeason"))
        XCTAssertEqual(AniListHomeRow.standard.map(\.id), ["trending", "season", "nextseason", "popular", "top"])

        // A studio row asks Studio, which has no adult filter.
        let studio = AniListQueries.homeRows([AniListHomeRow.row(id: "studio-MAPPA")!])
        XCTAssertTrue(studio.contains(#"r_studio_MAPPA: Studio(search: "MAPPA")"#))
        XCTAssertFalse(studio.contains("$isAdult"))
    }

    func testEveryCatalogIdSaysHowItIsAsked() {
        XCTAssertEqual(AniListHomeRow.row(id: "genre-Slice of Life")?.arguments, #"genre: "Slice of Life", sort: [POPULARITY_DESC]"#)
        XCTAssertEqual(AniListHomeRow.row(id: "genre-Slice of Life")?.alias, "r_genre_Slice_of_Life")
        XCTAssertEqual(AniListHomeRow.row(id: "tag-Isekai")?.arguments, #"tag: "Isekai", minimumTagRank: 60, sort: [POPULARITY_DESC]"#)
        XCTAssertEqual(AniListHomeRow.row(id: "format-MOVIE")?.arguments, "format: MOVIE, sort: [POPULARITY_DESC]")
        XCTAssertNil(AniListHomeRow.row(id: "format-NOPE"), "only AniList's formats")
        XCTAssertEqual(AniListHomeRow.row(id: "country-CN")?.arguments, #"countryOfOrigin: "CN", sort: [POPULARITY_DESC]"#)
        XCTAssertEqual(AniListHomeRow.row(id: "studio-Kyoto Animation")?.studio, "Kyoto Animation")
        XCTAssertEqual(AniListHomeRow.row(id: "airing")?.arguments, "status: RELEASING, sort: [POPULARITY_DESC]")
        XCTAssertNil(AniListHomeRow.row(id: "unknown"))
        XCTAssertEqual(AniListQueries.quoted(#"say "hi""#), #""say \"hi\"""#)

        let page = AniListQueries.rowPage(AniListHomeRow.row(id: "trending")!, withGenre: true)
        XCTAssertTrue(page.contains("genre: $genre"))
        XCTAssertFalse(AniListQueries.rowPage(AniListHomeRow.row(id: "genre-Action")!, withGenre: true).contains("$genre"))
    }

    func testTheCatalogChoiceIsKeptInOrder() {
        let a = AnimeCatalogChoice(id: "tag-Isekai", title: "Isekai")
        let b = AnimeCatalogChoice(id: "genre-Action", title: "Action")
        var chosen = AnimeCatalogSelection.toggled(a, in: [])
        chosen = AnimeCatalogSelection.toggled(b, in: chosen)
        XCTAssertEqual(chosen.map(\.id), ["tag-Isekai", "genre-Action"])
        XCTAssertEqual(AnimeCatalogSelection.toggled(a, in: chosen).map(\.id), ["genre-Action"])
        XCTAssertEqual(AnimeCatalogSelection.decode(AnimeCatalogSelection.encode(chosen)), chosen)
        XCTAssertEqual(AnimeCatalogSelection.signature(chosen), AnimeCatalogSelection.signature(chosen))
    }

    func testStudioTitlesReadAsAPage() throws {
        let json = Data(#"{"data":{"r_studio_MAPPA":{"media":{"nodes":[{"id":1}]}},"r_trending":{"media":[{"id":2}]}}}"#.utf8)
        let pages = try JSONDecoder().decode(AniListAliasedPagesResponse.self, from: json).data ?? [:]
        XCTAssertEqual(pages["r_studio_MAPPA"]?.media?.map(\.id), [1])
        XCTAssertEqual(pages["r_trending"]?.media?.map(\.id), [2])
    }

    func testCinemetaDuplicatesAreRecognisedByNameAndYear() {
        let result = AniListService.SearchResult(
            items: [],
            names: [(name: AniListService.matchKey("Sousou no Frieren"), year: 2023),
                    (name: AniListService.matchKey("Frieren: Beyond Journey's End"), year: 2023)]
        )
        XCTAssertTrue(result.matches(NuvioMeta(id: "tt22248376", name: "Frieren: Beyond Journey's End", type: "series", year: 2023)))
        XCTAssertTrue(result.matches(NuvioMeta(id: "tt22248376", name: "FRIEREN - beyond journeys end", type: "series", year: 2024)))
        XCTAssertFalse(result.matches(NuvioMeta(id: "tt1", name: "Frieren", type: "series", year: 2023)))
        XCTAssertFalse(result.matches(NuvioMeta(id: "tt2", name: "Sousou no Frieren", type: "series", year: 2010)))
    }

    func testCardsKeepTheirAniListIDAndScore() throws {
        let first = try XCTUnwrap(try entries()[101])
        let card = AniListMetaBuilder.card(first, language: .english)
        XCTAssertEqual(card.id, "anilist:101")
        XCTAssertEqual(card.name, "Monster Squad")
        XCTAssertEqual(card.posterUrl, "https://img/101.jpg")
        XCTAssertEqual(card.backgroundUrl, "https://img/101b.jpg")
        XCTAssertNil(card.imdbId)
        XCTAssertEqual(card.externalRatings?.first?.value, 82)
    }

    // MARK: Client

    func testRequestBodiesAndCacheKeysAreStable() throws {
        let first = try AniListClient.body(query: "query", variables: ["b": 2, "a": nil])
        let second = try AniListClient.body(query: "query", variables: ["a": nil, "b": 2])
        XCTAssertEqual(first, second)
        XCTAssertEqual(AniListClient.cacheKey(for: first), AniListClient.cacheKey(for: second))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let variables = try XCTUnwrap(json["variables"] as? [String: Any])
        XCTAssertNil(variables["a"])
        XCTAssertEqual(variables["b"] as? Int, 2)
    }

    /// AniList reads `isAdult: null` as a filter that finds nothing, so "no filter" leaves the
    /// variable out, even when it arrives as an optional inside `Any?`.
    func testVariablesWithoutAValueAreLeftOut() throws {
        let showAdult: Bool? = nil
        let hideAdult: Bool? = false
        let season: String? = nil
        let body = try AniListClient.body(
            query: "query",
            variables: ["isAdult": showAdult, "season": season, "genre": nil, "perPage": 30]
        )
        let variables = try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["variables"] as? [String: Any])
        XCTAssertEqual(Set(variables.keys), ["perPage"])

        let hidden = try AniListClient.body(query: "query", variables: ["isAdult": hideAdult])
        let hiddenVariables = try XCTUnwrap((JSONSerialization.jsonObject(with: hidden) as? [String: Any])?["variables"] as? [String: Any])
        XCTAssertEqual(hiddenVariables["isAdult"] as? Bool, false)
        XCTAssertTrue(String(decoding: hidden, as: UTF8.self).contains("\"isAdult\":false"))
    }

    func testAnErrorAniListSendsAs200IsRecognised() {
        let onlyError = Data(#"{"errors":[{"message":"Max query complexity exceeded","status":400}],"data":null}"#.utf8)
        XCTAssertEqual(AniListClient.errorMessage(in: onlyError), "Max query complexity exceeded")
        XCTAssertFalse(AniListClient.hasData(onlyError))

        let partial = Data(#"{"errors":[{"message":"One page failed"}],"data":{"trending":{"media":[]},"top":null}}"#.utf8)
        XCTAssertEqual(AniListClient.errorMessage(in: partial), "One page failed")
        XCTAssertTrue(AniListClient.hasData(partial))

        let fine = Data(#"{"data":{"Page":{"media":[{"id":1}]}}}"#.utf8)
        XCTAssertNil(AniListClient.errorMessage(in: fine))
        XCTAssertEqual(
            AniListDiagnostics.describe(AniListClient.ClientError.answeredWithError("Max query complexity exceeded")),
            "AniList: Max query complexity exceeded"
        )
    }

    func testTheDiskCacheHonoursItsAge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AniListTests-\(UUID().uuidString)")
        let cache = AniListDiskCache(directory: directory)
        defer { cache.removeAll() }
        cache.write(Data("hello".utf8), key: "k")
        XCTAssertEqual(cache.read(key: "k", maxAge: 60), Data("hello".utf8))
        XCTAssertNotNil(cache.readWithAge(key: "k"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: directory.appendingPathComponent("k").path
        )
        XCTAssertNil(cache.read(key: "k", maxAge: 60))
        XCTAssertEqual(cache.read(key: "k", maxAge: .infinity), Data("hello".utf8))
    }

    func testSavedAnswersFromAnotherBuildAreDropped() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AniListTests-\(UUID().uuidString)")
        let cache = AniListDiskCache(directory: directory)
        defer { cache.removeAll() }
        cache.write(Data("old".utf8), key: "k")
        XCTAssertTrue(cache.removeAllIfWritten(byAnotherBuildThan: "2|1.0|7|100"))
        XCTAssertNil(cache.read(key: "k", maxAge: .infinity))

        cache.write(Data("new".utf8), key: "k")
        XCTAssertFalse(cache.removeAllIfWritten(byAnotherBuildThan: "2|1.0|7|100"))
        XCTAssertEqual(cache.read(key: "k", maxAge: .infinity), Data("new".utf8))

        XCTAssertTrue(cache.removeAllIfWritten(byAnotherBuildThan: "2|1.0|7|200"))
        XCTAssertNil(cache.read(key: "k", maxAge: .infinity))
        XCTAssertTrue(AniListDiskCache.currentBuild.hasPrefix("\(AniListDiskCache.formatVersion)|"))
    }

    // MARK: Pictures

    private let aniZipJSON = """
    {"episodes":{"1":{"title":{"en":"The Squad"},"image":"https://zip/1.jpg"}},
     "images":[{"coverType":"Banner","url":"https://tvdb/banner.jpg"},
               {"coverType":"Fanart","url":"http://tvdb/fanart.jpg"},
               {"coverType":"Clearlogo","url":"https://tvdb/logo.png"}],
     "mappings":{"anilist_id":101,"themoviedb_id":"8392","imdb_id":"tt1"}}
    """

    func testAniZipGivesTheTVDBBackgroundLogoAndTmdbID() throws {
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(aniZipJSON.utf8))
        XCTAssertEqual(response.fanart, "https://tvdb/fanart.jpg")
        XCTAssertEqual(response.clearLogo, "https://tvdb/logo.png")
        XCTAssertEqual(response.mappings?.themoviedbID, 8392)
        XCTAssertEqual(response.episodes?["1"]?.englishTitle, "The Squad")

        let numeric = try decoder.decode(AniZipMappingsResponse.self, from: Data(#"{"mappings":{"themoviedb_id":129}}"#.utf8))
        XCTAssertEqual(numeric.mappings?.themoviedbID, 129)
    }

    func testOnlyAWholeIMDbIDLeadsToMetahub() throws {
        let mapped = try decoder.decode(AniZipMappings.self, from: Data(#"{"imdb_id":" TT5370118 "}"#.utf8))
        XCTAssertEqual(mapped.imdbID, "tt5370118")
        XCTAssertNil(try decoder.decode(AniZipMappings.self, from: Data(#"{"imdb_id":"tt"}"#.utf8)).imdbID)
        XCTAssertNil(try decoder.decode(AniZipMappings.self, from: Data(#"{"imdb_id":null}"#.utf8)).imdbID)

        let metahub = try XCTUnwrap(AniListService.metahubArtwork(imdbID: "tt5370118"))
        XCTAssertEqual(metahub.logo.absoluteString, "https://images.metahub.space/logo/medium/tt5370118/img")
        XCTAssertEqual(metahub.background.absoluteString, "https://images.metahub.space/background/medium/tt5370118/img")
        XCTAssertNil(AniListService.metahubArtwork(imdbID: "anilist:21202"))
    }

    func testAnOddPartOfAniZipCostsOnlyThatPart() throws {
        let json = #"{"episodes":{"1":{"title":{"en":"The Squad"}}},"images":"none","mappings":[1]}"#
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.episodes?["1"]?.englishTitle, "The Squad")
        XCTAssertNil(response.fanart)
        XCTAssertNil(response.mappings)
    }

    func testTheBackgroundIsTheTVDBFanartBeforeAniListsBanner() throws {
        let entries = try entries()
        let tabs = [try XCTUnwrap(entries[101]), try XCTUnwrap(entries[102])]
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(aniZipJSON.utf8))

        // The second season's pictures serve when the first has none.
        let artwork = AniListMetaBuilder.Artwork(tabs: tabs, aniZip: [102: response])
        XCTAssertEqual(artwork, AniListMetaBuilder.Artwork(background: "https://tvdb/fanart.jpg", logo: "https://tvdb/logo.png"))
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: tabs, episodes: [:], language: .romaji, artwork: artwork))
        XCTAssertEqual(meta.backgroundUrl, "https://tvdb/fanart.jpg")
        XCTAssertEqual(meta.logoUrl, "https://tvdb/logo.png")

        let withoutAniZip = try XCTUnwrap(AniListMetaBuilder.meta(tabs: tabs, episodes: [:], language: .romaji))
        XCTAssertEqual(withoutAniZip.backgroundUrl, "https://img/101b.jpg")
        XCTAssertNil(withoutAniZip.logoUrl)
        XCTAssertEqual(AniListMetaBuilder.Artwork(tabs: tabs, aniZip: [:]), .empty)
    }

    /// A picture `width`×`height`: letters on a see-through background, or a filled still.
    private func picture(width: Int, height: Int, seeThrough: Bool, type: String = "public.png") throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1)
        if seeThrough {
            context.fill(CGRect(x: width / 10, y: height / 3, width: width * 8 / 10, height: height / 3))
        } else {
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testOnlyALogoStandsInTheHerosTitle() throws {
        XCTAssertTrue(AniListClient.looksLikeLogo(try picture(width: 400, height: 150, seeThrough: true)))
        // A still or a poster, in a PNG or a JPEG.
        XCTAssertFalse(AniListClient.looksLikeLogo(try picture(width: 400, height: 225, seeThrough: false)))
        XCTAssertFalse(AniListClient.looksLikeLogo(try picture(width: 400, height: 225, seeThrough: false, type: "public.jpeg")))
        XCTAssertFalse(AniListClient.looksLikeLogo(try picture(width: 200, height: 400, seeThrough: true)))
        XCTAssertFalse(AniListClient.looksLikeLogo(Data("<html>Not Found</html>".utf8)))
    }

    func testASecondSeasonTakesItsPicturesFromTheSeasonBefore() throws {
        func node(_ id: Int, _ format: String, _ year: Int, type: String = "ANIME") -> AniListMedia {
            AniListMedia(id: id, type: type, format: format, startDate: AniListDate(year: year, month: 1, day: 1))
        }
        let season3 = AniListMedia(id: 3, format: "TV", relations: AniListRelationConnection(edges: [
            AniListRelationEdge(relationType: "PREQUEL", node: node(1, "TV", 2020)),
            AniListRelationEdge(relationType: "PREQUEL", node: node(2, "TV", 2022)),
            AniListRelationEdge(relationType: "PREQUEL", node: node(9, "MOVIE", 2023)),
            AniListRelationEdge(relationType: "SEQUEL", node: node(4, "TV", 2026)),
            AniListRelationEdge(relationType: "ADAPTATION", node: node(5, "MANGA", 2018, type: "MANGA")),
        ]))
        XCTAssertEqual(AniListMetaBuilder.previousSeason(of: season3), 2)

        // After a film, with no season before it.
        let afterFilm = AniListMedia(id: 10, format: "TV", relations: AniListRelationConnection(edges: [
            AniListRelationEdge(relationType: "PREQUEL", node: node(9, "MOVIE", 2023)),
        ]))
        XCTAssertNil(AniListMetaBuilder.previousSeason(of: afterFilm))
        XCTAssertNil(AniListMetaBuilder.previousSeason(of: AniListMedia(id: 1, format: "TV")))

        let own = AniListMetaBuilder.Artwork(background: nil, logo: "https://tvdb/s2-logo.png")
        let earlier = AniListMetaBuilder.Artwork(background: "https://tvdb/s1-fanart.jpg", logo: "https://tvdb/s1-logo.png")
        XCTAssertFalse(own.isComplete)
        XCTAssertEqual(own.filled(by: earlier), AniListMetaBuilder.Artwork(background: "https://tvdb/s1-fanart.jpg", logo: "https://tvdb/s2-logo.png"))
        XCTAssertTrue(own.filled(by: earlier).isComplete)
    }

    func testArmServerGivesTheIMDbIdAniZipLacks() {
        let json = #"{"anidb":17617,"anilist":163132,"imdb":"tt21209876","themoviedb":null,"thetvdb":424536}"#
        XCTAssertEqual(AniListService.armIMDbID(in: Data(json.utf8)), "tt21209876")
        XCTAssertNil(AniListService.armIMDbID(in: Data(#"{"anilist":1,"imdb":null}"#.utf8)))
        XCTAssertNil(AniListService.armIMDbID(in: Data("null".utf8)))
        XCTAssertNil(AniListService.armIMDbID(in: Data(#"{"imdb":"21209876"}"#.utf8)))
    }

    func testACardCarriesItsYouTubeTrailerForTheHero() {
        let onYouTube = AniListMedia(id: 7, type: "ANIME", format: "TV", trailer: AniListTrailer(id: " dQw4w9WgXcQ ", site: "youtube"))
        XCTAssertEqual(AniListMetaBuilder.card(onYouTube, language: .romaji).trailerYtIds, ["dQw4w9WgXcQ"])
        let onDailymotion = AniListMedia(id: 8, type: "ANIME", format: "TV", trailer: AniListTrailer(id: "x7abc", site: "dailymotion"))
        XCTAssertNil(AniListMetaBuilder.card(onDailymotion, language: .romaji).trailerYtIds)
        XCTAssertNil(AniListMetaBuilder.card(AniListMedia(id: 9, type: "ANIME", format: "TV"), language: .romaji).trailerYtIds)
    }

    func testTheHeroNamesTheSeasonUnderTheSeriesLogo() throws {
        let card = AniListMetaBuilder.card(try XCTUnwrap(try entries()[102]), language: .romaji)
        XCTAssertEqual(AniListMetaBuilder.nameUnderLogo(card), card.name)
        let other = NuvioMeta(id: "tt0903747", name: "Breaking Bad", type: "series")
        XCTAssertNil(AniListMetaBuilder.nameUnderLogo(other))
    }

    func testTheHeroTakesTheTVDBPicturesAndKeepsTheRest() throws {
        let card = AniListMetaBuilder.card(try XCTUnwrap(try entries()[101]), language: .english)
        let hero = AniListMetaBuilder.applying(AniListMetaBuilder.Artwork(background: "https://tvdb/fanart.jpg", logo: nil), to: card)
        XCTAssertEqual(hero.id, card.id)
        XCTAssertEqual(hero.name, card.name)
        XCTAssertEqual(hero.backgroundUrl, "https://tvdb/fanart.jpg")
        XCTAssertNil(hero.logoUrl)
        XCTAssertEqual(hero.externalRatings, card.externalRatings)
        XCTAssertEqual(AniListMetaBuilder.applying(.empty, to: card), card)
    }

    // MARK: Episode labels

    /// Top Shelf: an AniList title takes the hero's backdrop and logo, its IMDb id (trailers) and
    /// its name under the logo; everything else stays.
    func testTopShelfEntriesTakeBetterArtwork() throws {
        let entry = TopShelfEntry(
            contentId: "anilist:166531", contentType: "series", title: "[Oshi no Ko] 2nd Season", subtitle: "E3",
            imageURL: "cover", backdropURL: "banner", progress: 0.5, action: .details,
            summary: "About", tmdbId: 203737, homeOrder: 2)
        let better = entry.with(backdropURL: "fanart", logoURL: "logo", imdbId: "tt21030032", logoCaption: entry.title)
        XCTAssertEqual(better.backdropURL, "fanart")
        XCTAssertEqual(better.logoURL, "logo")
        XCTAssertEqual(better.imdbId, "tt21030032")
        XCTAssertEqual(better.logoCaption, "[Oshi no Ko] 2nd Season")
        XCTAssertEqual(better.title, entry.title)
        XCTAssertEqual(better.subtitle, "E3")
        XCTAssertEqual(better.imageURL, "cover")
        XCTAssertEqual(better.progress, 0.5)
        XCTAssertEqual(better.action, .details)
        XCTAssertEqual(better.summary, "About")
        XCTAssertEqual(better.tmdbId, 203737)
        XCTAssertEqual(better.homeOrder, 2)
        // Feeds written before the caption existed still read.
        let old = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "logoCaption")
        let decoded = try JSONDecoder().decode(TopShelfEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.logoCaption)
        XCTAssertEqual(decoded.title, entry.title)
    }

    /// Settings → Rating Providers & Order: AniList is one of the rows, moved and switched like the others.
    func testAniListsScoreCanBeMovedAndSwitchedOff() throws {
        let suite = "anilist-ratings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let items = [(source: "anilist", value: 1), (source: "imdb", value: 2), (source: "myanimelist", value: 3)]
        func shown(includingDisabled: Bool = false) -> [String] {
            AddonRatingsService.sortRatings(items, by: { $0.source }, defaults: defaults, includesDisabled: includingDisabled).map(\.source)
        }

        XCTAssertEqual(shown(), ["imdb", "myanimelist", "anilist"])
        AddonRatingsService.setRatingOrder(["anilist", "imdb", "myanimelist"], defaults: defaults)
        XCTAssertEqual(shown(), ["anilist", "imdb", "myanimelist"])
        AddonRatingsService.setSourceEnabled("anilist", enabled: false, defaults: defaults)
        XCTAssertEqual(shown(), ["imdb", "myanimelist"])
        XCTAssertEqual(shown(includingDisabled: true), ["anilist", "imdb", "myanimelist"])
    }

    func testAniListEpisodesAreLabelledWithoutTheFirstSeason() {
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "anilist:101:1", season: 1, episode: 1), "E1")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "anilist:102:5", season: 2, episode: 5), "S2 E5")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "tt0903747:1:1", season: 1, episode: 1), "S1 E1")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "anilist:101", season: 1, episode: 3, separator: " · "), "E3")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "tt0903747", season: 5, episode: 14, separator: " · "), "S5 · E14")

        // Over the stream list.
        XCTAssertEqual(AniListMetaBuilder.episodeHeading(NuvioVideo(id: "anilist:101:4", title: "", season: 1, episode: 4)), "Episode 4")
        XCTAssertEqual(AniListMetaBuilder.episodeHeading(NuvioVideo(id: "anilist:102:4", title: "", season: 2, episode: 4)), "Season 2 · Episode 4")
        XCTAssertEqual(AniListMetaBuilder.episodeHeading(NuvioVideo(id: "tt1:1:4", title: "", season: 1, episode: 4)), "Season 1 · Episode 4")

        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S1, E1 • Episode 1", titleID: "anilist:101"), "E1 • Episode 1")
        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S2, E1 • Episode 1", titleID: "anilist:101"), "S2, E1 • Episode 1")
        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S1, E1 • Pilot", titleID: "tt0903747"), "S1, E1 • Pilot")
        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S1, E1 • Pilot", titleID: nil), "S1, E1 • Pilot")
    }

    // MARK: Search

    @MainActor
    func testSearchEnrichmentLeavesAniListCardsAsTheyAre() async throws {
        final class CountingRepository: MockCatalogRepository {
            var refreshed: [String] = []
            override func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
                refreshed.append(id)
                return NuvioMeta(id: id, name: "Naruto", backgroundUrl: "https://cinemeta/bg.jpg", imdbId: "tt0409591", type: "series", year: 2002)
            }
        }
        let aniList = NuvioMeta(id: "anilist:20", name: "Naruto", posterUrl: "https://img/20.jpg", type: "series", year: 2002)
        let cinemeta = NuvioMeta(id: "tt0409591", name: "Naruto", posterUrl: "https://cinemeta/20.jpg", imdbId: "tt0409591", type: "series", year: 2002)
        let repository = CountingRepository()

        XCTAssertFalse(SearchResultEnrichment.hasIncompleteLeadingResults([aniList]))
        XCTAssertTrue(SearchResultEnrichment.hasIncompleteLeadingResults([aniList, cinemeta]))

        let enriched = await SearchResultEnrichment.enrich([aniList, cinemeta], repository: repository)
        XCTAssertEqual(repository.refreshed, ["tt0409591"])
        XCTAssertEqual(enriched.map(\.id), ["anilist:20", "tt0409591"])
        XCTAssertEqual(enriched.first, aniList)
        XCTAssertNil(enriched.first?.imdbId)
    }

    func testASearchAniListDidNotAnswerIsMarked() {
        XCTAssertTrue(AniListService.SearchResult.failure.failed)
        XCTAssertFalse(AniListService.SearchResult.empty.failed)
    }

    // MARK: Status

    func testStatusTellsWhatHomeLastDidAndWhatReachedTheScreen() {
        AniListDiagnostics.reset()
        defer { AniListDiagnostics.reset() }
        let time: (Date) -> String = { _ in "21:38" }
        XCTAssertEqual(AniListDiagnostics.text(.home, timeStyle: time), "Not asked yet")

        let asked = Date(timeIntervalSince1970: 1_000)
        AniListDiagnostics.noteHomeOnScreen(rows: 2, at: asked.addingTimeInterval(-60))
        AniListDiagnostics.note(.home, "5 of 5 rows, 150 titles · from AniList", at: asked)
        // A count from an earlier load is left out.
        XCTAssertEqual(AniListDiagnostics.text(.home, timeStyle: time), "21:38 · 5 of 5 rows, 150 titles · from AniList")

        AniListDiagnostics.noteHomeOnScreen(rows: 5, at: asked.addingTimeInterval(2))
        XCTAssertEqual(AniListDiagnostics.text(.home, timeStyle: time), "21:38 · 5 of 5 rows, 150 titles · from AniList · 5 on screen")

        AniListDiagnostics.note(.search, "“naruto”: 12 results (9 series, 3 films) · saved answer", at: asked)
        XCTAssertEqual(AniListDiagnostics.text(.search, timeStyle: time), "21:38 · “naruto”: 12 results (9 series, 3 films) · saved answer")
        XCTAssertEqual(AniListDiagnostics.describe(AniListClient.ClientError.badResponse(400)), "HTTP 400")
    }

    // MARK: Home

    func testHomeTakesAniListsRowsOnlyWhenTheyAreReady() async {
        let ready = Task<[Int], Never> { [1, 2] }
        let readyValue = await CinemetaCatalogRepository.value(of: ready, within: 2)
        XCTAssertEqual(readyValue, [1, 2])

        let slow = Task<[Int], Never> {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return [3]
        }
        let started = Date()
        let slowValue = await CinemetaCatalogRepository.value(of: slow, within: 0.1)
        XCTAssertNil(slowValue)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        slow.cancel()
    }

    // MARK: Account

    func testThePastedTokenIsFoundInWhateverWasCopied() {
        XCTAssertEqual(AniListAccount.token(fromPasted: "  abc.def.ghi \n"), "abc.def.ghi")
        XCTAssertEqual(
            AniListAccount.token(fromPasted: "https://anilist.co/api/v2/oauth/pin#access_token=abc.def&token_type=Bearer&expires_in=31536000"),
            "abc.def"
        )
        XCTAssertEqual(AniListAccount.token(fromPasted: ""), "")
        XCTAssertEqual(
            AniListAccount.authorizeURL(clientID: " 12345 ")?.absoluteString,
            "https://anilist.co/api/v2/oauth/authorize?client_id=12345&response_type=token"
        )
        XCTAssertNil(AniListAccount.authorizeURL(clientID: "abc"))
        XCTAssertNil(AniListAccount.authorizeURL(clientID: ""))
        XCTAssertEqual(AniListAccount.token(fromPasted: "Bearer eyJabc.def.ghi"), "eyJabc.def.ghi")
    }

    func testThePhonesLoginReachesThisAppleTV() {
        func request(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

        // AniList sends the phone to the Redirect URL; the token is in the fragment, never sent.
        XCTAssertEqual(AniListLoginServer.parse(request("GET /anilist HTTP/1.1\nHost: 192.168.1.50:47811\n\n")), .page)
        XCTAssertEqual(AniListLoginServer.parse(request("GET /anilist?error=access_denied HTTP/1.1\n\n")), .page)
        XCTAssertEqual(AniListLoginServer.parse(request("GET /favicon.ico HTTP/1.1\n\n")), .notFound)
        XCTAssertEqual(AniListLoginServer.parse(Data("GET /anilist HTTP/1.1\r\nHost: x".utf8)), .incomplete)

        // The page posts the token back.
        let body = "access_token=eyJ0eXAi.eyJhdWQi.c2ln&state=abc123"
        let post = "POST /anilist/token HTTP/1.1\nContent-Type: application/x-www-form-urlencoded\nContent-Length: \(body.utf8.count)\n\n"
        XCTAssertEqual(AniListLoginServer.parse(request(post) + Data(body.utf8)), .token("eyJ0eXAi.eyJhdWQi.c2ln", state: "abc123"))
        XCTAssertEqual(AniListLoginServer.parse(request(post) + Data(body.prefix(10).utf8)), .incomplete)
        XCTAssertEqual(
            AniListLoginServer.parse(request("POST /anilist/token HTTP/1.1\nContent-Length: 14\n\n") + Data("access_token=a".utf8)),
            .token("a", state: nil)
        )
        XCTAssertEqual(AniListLoginServer.parse(request("POST /anilist/token HTTP/1.1\nContent-Length: 6\n\n") + Data("state=".utf8)), .invalid)
        XCTAssertEqual(AniListLoginServer.parse(request("POST /anilist/token HTTP/1.1\nTransfer-Encoding: chunked\n\n")), .invalid)
        XCTAssertEqual(AniListLoginServer.formFields("a=1%2B2&b=x+y&c"), ["a": "1+2", "b": "x y", "c": ""])

        XCTAssertTrue(AniListLoginServer.page.contains("fetch('/anilist/token'"))
        XCTAssertTrue(AniListLoginServer.page.contains("history.replaceState"))

        // The QR code's address carries the state the Apple TV waits for.
        XCTAssertEqual(
            AniListAccount.authorizeURL(clientID: "56063", state: "abc123")?.absoluteString,
            "https://anilist.co/api/v2/oauth/authorize?client_id=56063&response_type=token&state=abc123"
        )
        XCTAssertEqual(
            AniListAccount.authorizeURL(clientID: "56063", state: "a&b")?.absoluteString,
            "https://anilist.co/api/v2/oauth/authorize?client_id=56063&response_type=token"
        )
    }

    /// A token shaped like AniList's: an RS256 JWT with a 256-byte signature.
    private func jwt(aud: Any = "56063", sub: Any = "8395785", exp: Date = Date(timeIntervalSince1970: 1_825_000_000)) -> String {
        func part(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["typ": "JWT", "alg": "RS256", "jti": String(repeating: "a", count: 80)])
        let claims: [String: Any] = [
            "aud": aud, "jti": String(repeating: "b", count: 80), "iat": 1_760_000_000,
            "nbf": 1_760_000_000, "exp": exp.timeIntervalSince1970, "sub": sub, "scopes": [String](),
        ]
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let signature = Data((0..<256).map { UInt8($0 % 251) })
        return [part(header), part(payload), part(signature)].joined(separator: ".")
    }

    func testAWholeTokenIsReadWithoutAskingAniList() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let token = jwt()
        let (facts, problem) = AniListAccount.inspect(token, now: now)
        XCTAssertNil(problem)
        XCTAssertEqual(facts.parts, 3)
        XCTAssertEqual(facts.clientID, "56063")
        XCTAssertEqual(facts.userID, "8395785")
        XCTAssertEqual(facts.expires, Date(timeIntervalSince1970: 1_825_000_000))
        XCTAssertEqual(facts.summary, "token \(token.count) characters, 3 parts, client 56063")
        // Claims sent as numbers read the same.
        XCTAssertEqual(AniListAccount.inspect(jwt(aud: 56063, sub: 8395785), now: now).facts.clientID, "56063")
    }

    func testABrokenTokenIsCaughtBeforeAniListIsAsked() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let token = jwt()

        // Cut off inside the signature, inside the payload, or pasted twice.
        XCTAssertEqual(AniListAccount.inspect(String(token.dropLast(40)), now: now).problem, .incomplete(length: token.count - 40))
        XCTAssertEqual(AniListAccount.inspect(String(token.dropLast(37)), now: now).problem, .incomplete(length: token.count - 37))
        let firstTwo = token.split(separator: ".").prefix(2).joined(separator: ".")
        XCTAssertEqual(AniListAccount.inspect(firstTwo, now: now).problem, .incomplete(length: firstTwo.count))
        XCTAssertEqual(AniListAccount.inspect(token + token, now: now).problem, .incomplete(length: token.count * 2))

        // The Client Secret, or the Client ID.
        let secret = String(repeating: "x", count: 40)
        XCTAssertEqual(AniListAccount.inspect(secret, now: now).problem, .notAToken(length: 40))
        XCTAssertEqual(AniListAccount.inspect("56063", now: now).problem, .notAToken(length: 5))

        // Changed on the way: a dash made into "—", or an ellipsis where it was shortened.
        let dashed = token.replacingOccurrences(of: "-", with: "—")
        if dashed != token {
            XCTAssertEqual(AniListAccount.inspect(dashed, now: now).problem, .changed(length: dashed.count))
        }
        let shortened = String(token.prefix(500)) + "…"
        XCTAssertEqual(AniListAccount.inspect(shortened, now: now).problem, .changed(length: 501))

        // Past its year.
        let expired = jwt(exp: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(AniListAccount.inspect(expired, now: now).problem, .expired(Date(timeIntervalSince1970: 1_780_000_000)))
    }

    func testLoggingInWithABrokenTokenSaysWhyAndKeepsNothing() async {
        let saved = AniListAccount.storage
        AniListAccount.storage = AniListMemoryTokenStorage()
        defer { AniListAccount.storage = saved }
        let token = jwt()

        do {
            try await AniListAccount.logIn(pasted: String(token.prefix(600)), now: Date(timeIntervalSince1970: 1_790_000_000))
            XCTFail("A cut-off token must not be sent")
        } catch {
            XCTAssertEqual(error as? AniListAccount.AccountError, .badToken(.incomplete(length: 600)))
            XCTAssertEqual(error.localizedDescription, AniListAccount.TokenProblem.incomplete(length: 600).message)
        }
        XCTAssertNil(AniListAccount.storage.login(for: ProfileSettings.activeProfileScope))
        let note = AniListDiagnostics.entry(.account)?.text ?? ""
        XCTAssertTrue(note.hasPrefix("Log in stopped: The token arrived incomplete"), note)
        XCTAssertTrue(note.contains("· token 600 characters, 3 parts, client 56063"), note)
        XCTAssertFalse(note.contains(String(token.prefix(40))))
    }

    func testAniListsOwnWordsAreShownWithAFailure() {
        XCTAssertEqual(AniListDiagnostics.describe(AniListClient.ClientError.refused(404, "Not Found.")), "HTTP 404 · Not Found.")
        XCTAssertEqual(
            AniListAccount.AccountError.notAccepted("HTTP 400 · Invalid token").localizedDescription,
            "AniList didn't accept the token (HTTP 400 · Invalid token)."
        )
    }

    private func entry(_ status: String?, progress: Int = 0, repeatCount: Int = 0, started: Bool = true) -> AniListListEntry {
        AniListListEntry(id: 1, mediaId: 101, status: status, progress: progress, repeatCount: repeatCount,
                         startedAt: started ? AniListDate(year: 2026, month: 1, day: 1) : nil)
    }

    func testWatchingMovesProgressForwardOnly() {
        typealias Change = AniListAccount.Change
        // Not on a list: starts watching today.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 1, byPlaying: true), entry: nil, total: 12),
                       Change(status: "CURRENT", progress: 1, startsToday: true))
        // Planning: moves to Watching.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 3, byPlaying: true), entry: entry("PLANNING", started: false), total: 12),
                       Change(status: "CURRENT", progress: 3, startsToday: true))
        // Watching, an older episode again: nothing.
        XCTAssertNil(AniListAccount.change(for: .watched(episode: 4, byPlaying: true), entry: entry("CURRENT", progress: 5), total: 12))
        // Watching, the next one.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 6, byPlaying: true), entry: entry("CURRENT", progress: 5), total: 12),
                       Change(status: "CURRENT", progress: 6))
        // The last one completes it.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 12, byPlaying: true), entry: entry("CURRENT", progress: 11), total: 12),
                       Change(status: "COMPLETED", progress: 12, completesToday: true))
        // Airing with no known total never completes.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 30, byPlaying: true), entry: entry("CURRENT", progress: 29), total: nil),
                       Change(status: "CURRENT", progress: 30))
        // A film (one episode).
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 1, byPlaying: true), entry: nil, total: 1),
                       Change(status: "COMPLETED", progress: 1, startsToday: true, completesToday: true))
    }

    func testRewatchesAndCompletedEntries() {
        typealias Change = AniListAccount.Change
        // Playing the first episode of a completed series starts a rewatch; marking it doesn't.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 1, byPlaying: true), entry: entry("COMPLETED", progress: 12), total: 12),
                       Change(status: "REPEATING", progress: 1))
        XCTAssertNil(AniListAccount.change(for: .watched(episode: 1, byPlaying: false), entry: entry("COMPLETED", progress: 12), total: 12))
        XCTAssertNil(AniListAccount.change(for: .watched(episode: 5, byPlaying: true), entry: entry("COMPLETED", progress: 12), total: 12))
        // A rewatch counts on and ends as another completion.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 2, byPlaying: true), entry: entry("REPEATING", progress: 1, repeatCount: 1), total: 12),
                       Change(progress: 2))
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 12, byPlaying: true), entry: entry("REPEATING", progress: 11, repeatCount: 1), total: 12),
                       Change(status: "COMPLETED", progress: 12, repeatCount: 2, completesToday: true))
    }

    func testUnwatchingGoesBackToTheEpisodeBefore() {
        typealias Change = AniListAccount.Change
        XCTAssertEqual(AniListAccount.change(for: .unwatched(episode: 5), entry: entry("CURRENT", progress: 7), total: 12),
                       Change(progress: 4))
        XCTAssertEqual(AniListAccount.change(for: .unwatched(episode: 12), entry: entry("COMPLETED", progress: 12), total: 12),
                       Change(status: "CURRENT", progress: 11))
        XCTAssertNil(AniListAccount.change(for: .unwatched(episode: 9), entry: entry("CURRENT", progress: 7), total: 12))
        XCTAssertNil(AniListAccount.change(for: .unwatched(episode: 1), entry: nil, total: 12))
    }

    func testEpisodeNumbersAndEntriesOfATitle() throws {
        XCTAssertEqual(AniListAccount.episodeNumber(in: "anilist:102:5"), 5)
        XCTAssertNil(AniListAccount.episodeNumber(in: "anilist:102"))
        XCTAssertNil(AniListAccount.episodeNumber(in: "tt0903747:1:1"))
        let meta = NuvioMeta(id: "anilist:101", name: "Kaiju Sentai", type: "series", videos: [
            NuvioVideo(id: "anilist:101:1", title: "1", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "anilist:102:1", title: "1", season: 2, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "anilist:102:2", title: "2", season: 2, episode: 2, thumbnail: nil, overview: nil, released: nil, rating: nil),
        ])
        XCTAssertEqual(AniListAccount.entryIDs(of: meta), [101, 102])
        XCTAssertEqual(AniListAccount.entryIDs(of: NuvioMeta(id: "anilist:555", name: "Film", type: "movie")), [555])
    }

    func testListEntriesDecodeWithTheirRewatchCount() throws {
        let json = #"{"data":{"Page":{"mediaList":[{"id":9,"mediaId":21202,"status":"CURRENT","progress":4,"repeat":1,"score":80,"startedAt":{"year":2026,"month":11,"day":1},"media":{"id":21202,"episodes":10,"isFavourite":true}}]}}}"#
        let list = try XCTUnwrap(decoder.decode(AniListEntryPageResponse.self, from: Data(json.utf8)).data?.Page?.mediaList)
        XCTAssertEqual(list.first?.repeatCount, 1)
        XCTAssertEqual(list.first?.progress, 4)
        XCTAssertEqual(list.first?.score, 80)
        XCTAssertEqual(list.first?.media?.isFavourite, true)
    }

    // MARK: Cinemeta anime on AniList

    func testAirDaysAreComparedAsDays() {
        XCTAssertEqual(AniListMatcher.day(of: "2016-01-14T00:00:00.000Z"), "2016-01-14")
        XCTAssertNil(AniListMatcher.day(of: "2016"))
        XCTAssertEqual(AniListMatcher.daysBetween("2016-01-14", "2016-01-15"), 1)
        XCTAssertEqual(AniListMatcher.daysBetween("2016-01-15", "2016-01-14"), -1)
    }

    func testACinemetaEpisodeIsMatchedByItsAirDayThenByTheTVDBNumbers() {
        typealias Candidate = AniListMatcher.Candidate
        // A split season: TheTVDB S1E13 is the first episode of the second AniList entry.
        let candidates = [
            Candidate(entryID: 1, episode: 12, airDay: "2026-03-27", tvdbSeason: 1, tvdbEpisode: 12),
            Candidate(entryID: 2, episode: 1, airDay: "2026-07-03", tvdbSeason: 1, tvdbEpisode: 13),
            Candidate(entryID: 2, episode: 2, airDay: "2026-07-10", tvdbSeason: 1, tvdbEpisode: 14),
        ]
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: "2026-07-03", season: 1, episode: 13)?.episode, 1)
        // A day off for time zones.
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: "2026-07-11", season: 1, episode: 14), candidates[2])
        // IMDb numbers it differently: the day still wins.
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: "2026-07-03", season: 2, episode: 1), candidates[1])
        // No day: TheTVDB's numbers.
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: nil, season: 1, episode: 12), candidates[0])
        // Nothing that day and no numbers: nothing.
        XCTAssertNil(AniListMatcher.pick(from: candidates, airDay: "2026-05-01", season: 3, episode: 1))

        // Two episodes the same day: the numbers tell them apart, or nothing is written.
        let premiere = [
            Candidate(entryID: 5, episode: 1, airDay: "2026-01-10", tvdbSeason: 1, tvdbEpisode: 1),
            Candidate(entryID: 5, episode: 2, airDay: "2026-01-10", tvdbSeason: 1, tvdbEpisode: 2),
        ]
        XCTAssertEqual(AniListMatcher.pick(from: premiere, airDay: "2026-01-10", season: 1, episode: 2), premiere[1])
        XCTAssertNil(AniListMatcher.pick(from: premiere, airDay: "2026-01-10", season: 3, episode: 7))
    }

    func testAniZipEpisodesKeepTheirTheTVDBNumbersAndDays() throws {
        let json = #"{"episodes":{"1":{"seasonNumber":1,"episodeNumber":"13","absoluteEpisodeNumber":13,"airdate":"2026-07-03","title":{"en":"Again"}}}}"#
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(json.utf8))
        let episode = try XCTUnwrap(response.episodes?["1"])
        XCTAssertEqual(episode.seasonNumber, 1)
        XCTAssertEqual(episode.episodeNumber, 13)
        XCTAssertEqual(episode.airDay, "2026-07-03")
        XCTAssertEqual(episode.englishTitle, "Again")
    }

    // MARK: Offline tables

    /// Shaped like Fribb's mini file and anibridge's mappings (real ids and ranges).
    private func offlineSample() throws -> AniListOfflineMaps.Index {
        let fribb = """
        [
          {"type":"TV","anidb_id":17449,"anilist_id":150672,"imdb_id":["tt21030032"],"kitsu_id":46170,"mal_id":52034,"themoviedb_id":{"tv":203737},"tvdb_id":421069,"season":{"tvdb":1,"tmdb":1}},
          {"type":"TV","anidb_id":18086,"anilist_id":166531,"imdb_id":["tt21030032"],"kitsu_id":47759,"mal_id":55791,"themoviedb_id":{"tv":203737},"tvdb_id":421069,"season":{"tvdb":2,"tmdb":1}},
          {"type":"MOVIE","anidb_id":1,"anilist_id":129201,"imdb_id":["tt16360006"],"kitsu_id":44985,"themoviedb_id":{"movie":706510}},
          {"type":"TV","anidb_id":2,"anilist_id":5000,"tvdb_id":72025,"season":{"tvdb":3},"episode_offset":12,"kitsu_id":"77"},
          {"type":"TV","anidb_id":3,"mal_id":9}
        ]
        """
        let anibridge = """
        {
          "$meta": {"schema_version":"3.0.3","generated_on":"2026-11-06T08:50:08Z"},
          "anilist:150672": {"anidb:17449:R":{"1-11":"1-11"},"tvdb_show:421069:s1":{"1-11":"1-11"}},
          "anilist:166531": {"tmdb_show:203737:s1":{"1-13":"12-24"},"tvdb_show:421069:s2":{"1-13":"1-13"}},
          "anilist:185874": {"mal:60636":{"1-":"1-"},"tmdb_show:30984:s2":{"1-":"41-"},"tvdb_show:74796:s17":{"1-":"41-"}},
          "anilist:146065": {"tvdb_show:371310:s0":{"1":"2"},"tvdb_show:371310:s2":{"2-13":"1-12"}},
          "anilist:21": {"tvdb_show:81797:s0":{"542":"39"},"tvdb_show:81797:s15":{"517-541":"1-25","543-579":"26-62"},"tvdb_show:81797:s22":{"1086-1155":"1-70"}},
          "anilist:280": {"tvdb_show:307695:s1":{"1-51":"1-102|-2"}},
          "anilist:400": {"tvdb_show:75911:s1":{"1-24":"1-15,17-22,24-26"}},
          "anilist:177191": {"tmdb_movie:1287324":{"1-2":"1|2"},"imdb_movie:tt9584920":{"1-2":"1-2"}}
        }
        """
        return try AniListOfflineMaps.build(fribb: Data(fribb.utf8), anibridge: Data(anibridge.utf8), now: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testTheOfflineIndexJoinsFribbAndAnibridge() throws {
        let index = try offlineSample()
        XCTAssertEqual(index.anibridgeGenerated, "2026-11-06T08:50:08Z")
        let oshi2 = try XCTUnwrap(index.entries[166531])
        XCTAssertEqual(oshi2.kitsu, 47759)
        XCTAssertEqual(oshi2.imdb, "tt21030032")
        XCTAssertEqual(oshi2.tmdbTV, 203737)
        XCTAssertEqual(oshi2.tvdbSeason, 2)
        // TheTVDB's ranges only; TMDB's numbering (here S1E12–24) is not what add-ons go by.
        XCTAssertEqual(oshi2.ranges, [AniListOfflineMaps.EpisodeRange(tvdb: 421069, season: 2, source: "1-13", target: "1-13")])

        // Only in anibridge (newer than Fribb): its ids and ranges still count.
        let bleach = try XCTUnwrap(index.entries[185874])
        XCTAssertEqual(bleach.mal, 60636)
        XCTAssertEqual(bleach.tvdb, 74796)
        XCTAssertEqual(bleach.tmdbTV, 30984)

        XCTAssertEqual(index.entries[129201]?.tmdbMovie, 706510)
        XCTAssertTrue(index.entries[129201]?.isFilm == true)
        XCTAssertTrue(index.entries[177191]?.isFilm == true)
        XCTAssertEqual(index.entries[177191]?.imdb, "tt9584920")
        XCTAssertEqual(index.entries[5000]?.kitsu, 77)
        XCTAssertNil(index.entries[0])

        // Regular seasons before specials.
        XCTAssertEqual(index.entries[21]?.ranges?.map(\.season), [15, 15, 22, 0])
    }

    func testAniListEpisodesBecomeTheTVDBNumbers() throws {
        let index = try offlineSample()
        func numbers(_ id: Int, _ episode: Int) -> String? {
            guard let entry = index.entries[id], let found = AniListOfflineMaps.seasonEpisode(of: entry, episode: episode) else { return nil }
            return "\(found.tvdb) S\(found.season)E\(found.episode)"
        }
        XCTAssertEqual(numbers(166531, 1), "421069 S2E1")
        XCTAssertEqual(numbers(185874, 1), "74796 S17E41")      // a cour still airing
        XCTAssertEqual(numbers(185874, 9), "74796 S17E49")
        XCTAssertEqual(numbers(146065, 1), "371310 S0E2")       // episode 0 is a special
        XCTAssertEqual(numbers(146065, 2), "371310 S2E1")
        XCTAssertEqual(numbers(21, 1100), "81797 S22E15")       // absolute numbering
        XCTAssertEqual(numbers(21, 543), "81797 S15E26")
        XCTAssertEqual(numbers(21, 542), "81797 S0E39")
        XCTAssertEqual(numbers(400, 16), "75911 S1E17")         // skipped TheTVDB episodes
        XCTAssertEqual(numbers(400, 22), "75911 S1E24")
        XCTAssertNil(numbers(280, 3))                            // two TheTVDB episodes each: unplaceable
        XCTAssertNil(numbers(166531, 14))                        // past the end of the range
        XCTAssertEqual(numbers(5000, 2), "72025 S3E14")         // Fribb's season and offset
        XCTAssertNil(numbers(129201, 1))                         // a film has no episodes

        // And back.
        let oshi2 = try XCTUnwrap(index.entries[166531])
        XCTAssertEqual(AniListOfflineMaps.aniListEpisode(of: oshi2, tvdb: 421069, season: 2, episode: 5), 5)
        XCTAssertNil(AniListOfflineMaps.aniListEpisode(of: oshi2, tvdb: 421069, season: 1, episode: 5))
        let onePiece = try XCTUnwrap(index.entries[21])
        XCTAssertEqual(AniListOfflineMaps.aniListEpisode(of: onePiece, tvdb: 81797, season: 22, episode: 15), 1100)
        XCTAssertEqual(AniListOfflineMaps.aniListEpisode(of: try XCTUnwrap(index.entries[5000]), tvdb: 72025, season: 3, episode: 14), 2)
    }

    func testEpisodeRangeSpecs() {
        typealias M = AniListOfflineMaps
        XCTAssertEqual(M.segments("1-13"), [M.Segment(from: 1, to: 13)])
        XCTAssertEqual(M.segments("41-"), [M.Segment(from: 41, to: nil)])
        XCTAssertEqual(M.segments("542"), [M.Segment(from: 542, to: 542)])
        XCTAssertEqual(M.segments("1-15,17-22"), [M.Segment(from: 1, to: 15), M.Segment(from: 17, to: 22)])
        XCTAssertNil(M.segments("1-102|-2"))
        XCTAssertNil(M.segments("5-3"))
        XCTAssertNil(M.segments("x"))
        let runs = M.segments("1-15,17-22,24-")!
        XCTAssertEqual(M.position(of: 17, in: runs), 15)
        XCTAssertNil(M.position(of: 16, in: runs))
        XCTAssertEqual(M.position(of: 30, in: runs), 27)
        XCTAssertEqual(M.number(at: 15, in: runs), 17)
        XCTAssertEqual(M.number(at: 27, in: runs), 30)
        XCTAssertNil(M.number(at: 40, in: M.segments("1-13")!))
    }

    func testTheOfflineTablesAnswerFromTheCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anilist-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var index = try offlineSample()
        index.builtAt = Date()
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"))
        let maps = AniListOfflineMaps(directory: directory)

        let found = await maps.seasonEpisode(aniListID: 166531, episode: 3)
        XCTAssertEqual(found, AniListOfflineMaps.SeasonEpisode(tvdb: 421069, season: 2, episode: 3))
        let entry = await maps.entry(aniListID: 150672)
        XCTAssertEqual(entry?.kitsu, 46170)

        // A Cinemeta episode back to its AniList entry, by IMDb or TMDB.
        let season2 = await maps.aniListEpisode(imdb: "tt21030032", tmdbTV: nil, season: 2, episode: 4)
        XCTAssertEqual(season2?.aniListID, 166531)
        XCTAssertEqual(season2?.episode, 4)
        let season1 = await maps.aniListEpisode(imdb: nil, tmdbTV: 203737, season: 1, episode: 11)
        XCTAssertEqual(season1?.aniListID, 150672)
        let beyond = await maps.aniListEpisode(imdb: "tt21030032", tmdbTV: nil, season: 3, episode: 1)
        XCTAssertNil(beyond)

        let film = await maps.film(imdb: "tt16360006", tmdbMovie: nil)
        XCTAssertEqual(film, 129201)
        let byTMDB = await maps.film(imdb: nil, tmdbMovie: 706510)
        XCTAssertEqual(byTMDB, 129201)
        let shows = await maps.aniListIDs(tmdbTV: 203737, imdb: nil)
        XCTAssertEqual(shows, [150672, 166531])
        let status = await maps.status
        XCTAssertEqual(status, .ready(titles: index.entries.count, builtAt: index.builtAt))
    }

    /// STEEL BALL RUN 2nd STAGE: anibridge knows it only as TheTVDB's JoJo season 6; the IMDb id
    /// comes from the other JoJo entries of that TheTVDB show.
    func testANewSeasonTakesTheIMDbIdOfItsTheTVDBShow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anilist-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        typealias Entry = AniListOfflineMaps.Entry
        let index = AniListOfflineMaps.Index(version: AniListOfflineMaps.formatVersion, builtAt: Date(), anibridgeGenerated: nil, entries: [
            131942: Entry(imdb: "tt2359704", tvdb: 262954, tvdbSeason: 5, type: "ONA"),
            190327: Entry(imdb: "tt2359704", tvdb: 262954, tvdbSeason: 6, type: "ONA"),
            210482: Entry(type: "ONA", ranges: [AniListOfflineMaps.EpisodeRange(tvdb: 262954, season: 6, source: "1-11", target: "2-12")]),
            999: Entry(type: "ONA"),
        ])
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"))
        let maps = AniListOfflineMaps(directory: directory)

        let imdb = await maps.imdb(aniListID: 210482)
        XCTAssertEqual(imdb, "tt2359704")
        let own = await maps.imdb(aniListID: 190327)
        XCTAssertEqual(own, "tt2359704")
        let unknown = await maps.imdb(aniListID: 999)
        XCTAssertNil(unknown)
        let episode = await maps.seasonEpisode(aniListID: 210482, episode: 4)
        XCTAssertEqual(episode, AniListOfflineMaps.SeasonEpisode(tvdb: 262954, season: 6, episode: 5))
    }

    /// Fribb writes the offset as `{"tvdb": N, "tmdb": M}`; TheTVDB's is the one that counts.
    func testFribbsEpisodeOffsetIsTheTVDBOne() throws {
        let fribb = #"[{"type":"TV","anilist_id":7,"tvdb_id":5,"season":{"tvdb":2,"tmdb":1},"episode_offset":{"tvdb":12,"tmdb":3}}]"#
        let index = try AniListOfflineMaps.build(fribb: Data(fribb.utf8), anibridge: Data("{}".utf8))
        let entry = try XCTUnwrap(index.entries[7])
        XCTAssertEqual(entry.episodeOffset, 12)
        XCTAssertEqual(AniListOfflineMaps.seasonEpisode(of: entry, episode: 2), AniListOfflineMaps.SeasonEpisode(tvdb: 5, season: 2, episode: 14))
    }

    private func windows(_ ranges: [(Int, Int, String, String)], tvdb: Int = 9) -> [AniListOfflineMaps.Window] {
        var entries: [Int: AniListOfflineMaps.Entry] = [:]
        for (id, season, source, target) in ranges {
            var entry = entries[id] ?? AniListOfflineMaps.Entry(tvdb: tvdb, type: "TV")
            entry.ranges = (entry.ranges ?? []) + [AniListOfflineMaps.EpisodeRange(tvdb: tvdb, season: season, source: source, target: target)]
            entries[id] = entry
        }
        return AniListOfflineMaps.windows(ofTVDB: tvdb, entries: entries.map { ($0.key, $0.value) })
    }

    /// The season still airing: anibridge lists the episodes known so far (Yozakura 2nd Season
    /// Part 2 up to S2E14), the next ones continue that window.
    func testTheAiringWindowContinues() {
        typealias M = AniListOfflineMaps
        let show = windows([(1, 1, "1-12", "1-12"), (2, 2, "1-12", "1-12"), (3, 2, "1-2", "13-14")])
        XCTAssertEqual(M.seasonLengths(show), [1: 12, 2: 14])
        XCTAssertEqual(M.continuing(aniListID: 3, episode: 3, tvdb: 9, windows: show), M.SeasonEpisode(tvdb: 9, season: 2, episode: 15))
        XCTAssertNil(M.continuing(aniListID: 2, episode: 13, tvdb: 9, windows: show))     // not the last window
        XCTAssertNil(M.continuing(aniListID: 3, episode: 2, tvdb: 9, windows: show))      // still in its range
        XCTAssertEqual(M.pastSeasonEnd(season: 2, episode: 15, windows: show).map { "\($0.aniListID)#\($0.episode)" }, "3#3")
        // An open window has no end.
        XCTAssertNil(M.pastSeasonEnd(season: 1, episode: 60, windows: windows([(1, 1, "1-", "1-")])))
    }

    /// IMDb and Cinemeta run several cours as one season: Seihantai tt36034547 S1E25 is TheTVDB
    /// S2E13, the 2nd season's 13th episode.
    func testASeasonOverflowsIntoTheNextOnes() {
        typealias M = AniListOfflineMaps
        func hit(_ show: [M.Window], _ season: Int, _ episode: Int) -> String? {
            M.pastSeasonEnd(season: season, episode: episode, windows: show).map { "\($0.aniListID)#\($0.episode)" }
        }
        let seihantai = windows([(184951, 1, "1-12", "1-12"), (210031, 2, "1-13", "1-13")], tvdb: 457078)
        XCTAssertEqual(hit(seihantai, 1, 13), "210031#1")
        XCTAssertEqual(hit(seihantai, 1, 25), "210031#13")
        XCTAssertNil(hit(seihantai, 1, 12))                     // its own episode, not past the end
        XCTAssertEqual(hit(seihantai, 2, 14), "210031#14")      // the last season still airing

        let four = windows([(1, 1, "1-10", "1-10"), (2, 2, "1-10", "1-10"), (3, 3, "1-10", "1-10"), (4, 4, "1-10", "1-10")])
        XCTAssertEqual(hit(four, 1, 35), "4#5")                 // season 1 runs on through them all
        XCTAssertEqual(hit(four, 2, 15), "3#5")
        XCTAssertNil(hit(four, 2, 25))                          // a later season only into the next one
        XCTAssertNil(hit(four, 0, 3))
    }

    func testTheTablesContinueAndOverflowSeasons() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anilist-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        typealias M = AniListOfflineMaps
        let index = M.Index(version: M.formatVersion, builtAt: Date(), anibridgeGenerated: nil, entries: [
            184951: M.Entry(imdb: "tt36034547", tvdb: 457078, tvdbSeason: 1, type: "TV", ranges: [M.EpisodeRange(tvdb: 457078, season: 1, source: "1-12", target: "1-12")]),
            210031: M.Entry(imdb: "tt36034547", tvdb: 457078, tvdbSeason: 2, type: "TV", ranges: [M.EpisodeRange(tvdb: 457078, season: 2, source: "1-13", target: "1-13")]),
        ])
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"))
        let maps = M(directory: directory)

        let lumped = await maps.aniListEpisode(imdb: "tt36034547", tmdbTV: nil, season: 1, episode: 25)
        XCTAssertEqual(lumped.map { "\($0.aniListID)#\($0.episode)" }, "210031#13")
        let airing = await maps.seasonEpisode(aniListID: 210031, episode: 14)
        XCTAssertEqual(airing, M.SeasonEpisode(tvdb: 457078, season: 2, episode: 14))
        let finished = await maps.seasonEpisode(aniListID: 184951, episode: 13)
        XCTAssertNil(finished)
        let lengths = await maps.seasonLengths(tvdb: 457078)
        XCTAssertEqual(lengths, [1: 12, 2: 13])
    }

    /// TheTVDB's numbering as Cinemeta numbers it, which Stremio add-ons go by.
    func testEpisodesAreAskedByCinemetasNumbering() {
        typealias Video = AniListStreamIds.CinemetaSeries.Video
        func code(_ result: (season: Int, episode: Int)) -> String { "S\(result.season)E\(result.episode)" }
        // IMDb runs both cours as season 1, weekly from 2026-01-02.
        let lumped = (1...25).map { number in
            Video(season: 1, episode: number, released: AniListMatcher.utcDay(of: 1_767_312_000 + (number - 1) * 7 * 86_400) + "T00:00:00.000Z")
        }
        let lengths = [1: 12, 2: 13]
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((2, 13), videos: lumped, airDay: nil, tvdbLengths: lengths)), "S1E25")
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((2, 1), videos: lumped, airDay: nil, tvdbLengths: lengths)), "S1E13")
        let day25 = AniListMatcher.utcDay(of: 1_767_312_000 + 24 * 7 * 86_400)
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((2, 13), videos: lumped, airDay: day25, tvdbLengths: [:])), "S1E25")
        // Unchanged: Cinemeta lists it, lists nothing, has the season (an episode still to come),
        // a special, or the seasons before aren't known.
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((1, 5), videos: lumped, airDay: nil, tvdbLengths: lengths)), "S1E5")
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((2, 13), videos: [], airDay: nil, tvdbLengths: lengths)), "S2E13")
        let twoSeasons = [Video(season: 1, episode: 1, released: nil), Video(season: 2, episode: 1, released: nil)]
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((2, 14), videos: twoSeasons, airDay: nil, tvdbLengths: lengths)), "S2E14")
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((0, 3), videos: lumped, airDay: nil, tvdbLengths: lengths)), "S0E3")
        XCTAssertEqual(code(AniListStreamIds.cinemetaNumbering((2, 13), videos: lumped, airDay: nil, tvdbLengths: [2: 13])), "S2E13")
    }

    /// A season too new for the tables starts where Cinemeta has an episode released within three
    /// days of its start on AniList: STEEL BALL RUN 2nd STAGE (2026-09-24) is S6E2 onwards.
    func testANewSeasonStartsWhereCinemetaHasItsFirstEpisode() {
        typealias Video = AniListStreamIds.CinemetaSeries.Video
        let videos = [
            Video(season: 5, episode: 38, released: "2022-12-01T00:00:00.000Z"),
            Video(season: 6, episode: 1, released: "2026-03-19T00:00:00.000Z"),
            Video(season: 6, episode: 2, released: "2026-09-24T00:00:00.000Z"),
            Video(season: 6, episode: 3, released: "2026-10-01T00:00:00.000Z"),
            Video(season: 0, episode: 4, released: "2026-09-24T00:00:00.000Z"),
        ]
        func start(_ day: String) -> String? {
            AniListStreamIds.startEpisode(in: videos, startDay: day).map { "S\($0.season)E\($0.episode)" }
        }
        XCTAssertEqual(start("2026-09-25"), "S6E2")
        XCTAssertEqual(start("2026-03-17"), "S6E1")
        XCTAssertNil(start("2026-07-01"))
        // Released together (a batch on a streaming site): the first of them.
        let batch = (1...6).map { Video(season: 2, episode: $0, released: "2026-04-10T07:00:00.000Z") }
        XCTAssertEqual(AniListStreamIds.startEpisode(in: batch, startDay: "2026-04-10").map { "S\($0.season)E\($0.episode)" }, "S2E1")

        XCTAssertEqual(AniListStreamIds.isoDay(AniListDate(year: 2026, month: 9, day: 5)), "2026-09-05")
        XCTAssertNil(AniListStreamIds.isoDay(AniListDate(year: 2026, month: 9)))
    }

    func testAddOnsWithoutAniListIdsAreAskedByKitsuOrIMDb() throws {
        func manifest(_ json: String) throws -> StreamAddonManifest {
            try JSONDecoder().decode(StreamAddonManifest.self, from: Data(json.utf8))
        }
        let torrentio = try manifest(#"{"id":"torrentio","resources":["stream"],"types":["movie","series"],"idPrefixes":["tt","kitsu"]}"#)
        let imdbOnly = try manifest(#"{"id":"imdb","resources":["stream"],"types":["movie","series"],"idPrefixes":["tt"]}"#)
        let indexer = try manifest(#"{"id":"indexer","resources":["stream"],"types":["movie","series"],"idPrefixes":["anilist","tt"]}"#)
        let catalogOnly = try manifest(#"{"id":"catalog","resources":["catalog","meta"],"types":["series"],"idPrefixes":["tt"]}"#)
        let video = "anilist:166531:1"
        let alternatives = ["kitsu:47759:1", "tt21030032:2:1"]

        func id(_ manifest: StreamAddonManifest) -> String? {
            AniListStreamIds.requestID(for: manifest, resource: "stream", type: "series", videoId: video, alternatives: alternatives)
        }
        XCTAssertEqual(id(indexer), video)
        XCTAssertEqual(id(torrentio), "kitsu:47759:1")
        XCTAssertEqual(id(imdbOnly), "tt21030032:2:1")
        XCTAssertNil(id(catalogOnly))
        XCTAssertNil(AniListStreamIds.requestID(for: imdbOnly, resource: "stream", type: "series", videoId: video, alternatives: []))
    }

    func testANewSeasonIsPlacedByItsAirDayOnCinemeta() {
        typealias Video = AniListStreamIds.CinemetaSeries.Video
        let videos = [
            Video(season: 1, episode: 12, released: "2026-06-25T15:00:00.000Z"),
            Video(season: 2, episode: 1, released: "2026-07-09T15:00:00.000Z"),
            Video(season: 2, episode: 2, released: "2026-07-16T15:00:00.000Z"),
            Video(season: 0, episode: 3, released: "2026-07-16T10:00:00.000Z"),
        ]
        func place(_ list: [Video], _ day: String) -> String? {
            AniListStreamIds.episode(in: list, airDay: day).map { "S\($0.season)E\($0.episode)" }
        }
        XCTAssertEqual(place(videos, "2026-07-09"), "S2E1")
        XCTAssertEqual(place(videos, "2026-07-10"), "S2E1")   // a day off
        XCTAssertEqual(place(videos, "2026-07-16"), "S2E2")   // specials don't count
        XCTAssertNil(place(videos, "2026-08-01"))
        let twoThatDay = videos + [Video(season: 2, episode: 3, released: "2026-07-16T16:00:00.000Z")]
        XCTAssertNil(place(twoThatDay, "2026-07-16"))
    }

    func testOnlyCinemetaNumberingIsMatchedOffline() {
        XCTAssertTrue(AniListMatcher.isCinemetaNumbering("tt21030032:2:5", season: 2, episode: 5))
        XCTAssertFalse(AniListMatcher.isCinemetaNumbering("tt21030032:1:17", season: 2, episode: 5))
        XCTAssertFalse(AniListMatcher.isCinemetaNumbering("tmdb:203737:2:5", season: 2, episode: 5))
        XCTAssertFalse(AniListMatcher.isCinemetaNumbering(nil, season: 2, episode: 5))
    }

    func testTabsAreNamedByWhatTheyAddToTheSeries() {
        XCTAssertEqual(AniListMetaBuilder.shortName("Shingeki no Kyojin Season 3 Part 2", base: "Shingeki no Kyojin"), "Season 3 Part 2")
        XCTAssertEqual(AniListMetaBuilder.shortName("Naruto: Shippuuden", base: "Naruto"), "Shippuuden")
        XCTAssertEqual(AniListMetaBuilder.shortName("Kono Subarashii Sekai ni Shukufuku wo! 2", base: "Kono Subarashii Sekai ni Shukufuku wo!"), "2")
        XCTAssertEqual(AniListMetaBuilder.shortName("Narutoverse", base: "Naruto"), "Narutoverse", "a word isn't cut")
        XCTAssertEqual(AniListMetaBuilder.shortName("Mob Psycho 100 II", base: "Mob Psycho 100"), "II")
        XCTAssertEqual(AniListMetaBuilder.shortName("Bleach", base: "Ble"), "Bleach", "too little shared")
        XCTAssertEqual(AniListMetaBuilder.shortName("Re:Zero", base: "Re:Zero"), "")
    }
}
