import XCTest
@testable import NuvioTV

/// MyAnimeList as a source of its own: `mal:` titles read from Tenrai (else MAL's own API) and
/// built by the AniList engine.
final class MALSourceTests: XCTestCase {
    func testIDsSayTheirSourceAndEntry() {
        XCTAssertEqual(AnimeSource.entry(from: "mal:5114")?.source, .mal)
        XCTAssertEqual(AnimeSource.entry(from: "MAL:5114:3")?.id, 5114)
        XCTAssertEqual(AnimeSource.entry(from: "anilist:21")?.source, .anilist)
        XCTAssertNil(AnimeSource.entry(from: "tt0388629"))
        XCTAssertNil(AnimeSource.entry(from: "mal:abc"))
        XCTAssertEqual(AnimeSource.malID(from: "mal:52991:7"), 52991)
        XCTAssertNil(AnimeSource.malID(from: "anilist:52991"))
        XCTAssertTrue(AnimeSource.isAnimeTitleID("anilist:21"))
        XCTAssertFalse(AnimeSource.isAnimeTitleID("tt0388629"))
    }

    func testTheEngineMakesMALIdsWhileAMALTitleIsBuilt() {
        XCTAssertEqual(AniListMetaBuilder.metaID(5), "anilist:5")
        XCTAssertNil(AniListMetaBuilder.aniListID(from: "mal:5"), "outside, a mal: id isn't AniList's")
        AnimeSource.$current.withValue(.mal) {
            XCTAssertEqual(AniListMetaBuilder.metaID(5), "mal:5")
            XCTAssertEqual(AniListMetaBuilder.episodeID(entry: 5, episode: 2), "mal:5:2")
            XCTAssertEqual(AniListMetaBuilder.aniListID(from: "mal:5:2"), 5)
            XCTAssertNil(AniListMetaBuilder.aniListID(from: "anilist:5"))
        }
        XCTAssertEqual(AniListAccount.episodeNumber(in: "mal:52991:7"), 7)
    }

    func testMALTitlesFollowTheSettings() throws {
        let suite = "MALSourceTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MALSettings.opensTitles(in: store), "MyAnimeList off")
        store.set(true, forKey: SettingsKey.malEnabled)
        XCTAssertTrue(MALSettings.opensTitles(in: store), "on by default with MyAnimeList")
        store.set(false, forKey: SettingsKey.malTitles)
        XCTAssertFalse(MALSettings.opensTitles(in: store))
    }

    private let frieren = #"""
    {"data":{"mal_id":52991,"title":"Sousou no Frieren","title_english":"Frieren: Beyond Journey's End","title_japanese":"葬送のフリーレン",
    "title_synonyms":["Frieren at the Funeral"],
    "images":{"jpg":{"image_url":"https://cdn.myanimelist.net/images/anime/1015/138006.jpg","large_image_url":"https://cdn.myanimelist.net/images/anime/1015/138006l.jpg"}},
    "trailer":{"youtube_id":"qgQb0qxEcZM","url":null},"type":"TV","source":"Manga","episodes":28,"status":"Finished Airing",
    "aired":{"from":"2023-09-29T00:00:00+00:00","prop":{"from":{"day":29,"month":9,"year":2023},"to":{"day":22,"month":3,"year":2024}}},
    "duration":"24 min per ep","rating":"PG-13 - Teens 13 or older","score":9.3,"scored_by":500000,
    "synopsis":"An elf mage outlives her party.\n\n[Written by MAL Rewrite]","season":"fall","year":2023,
    "studios":[{"mal_id":11,"type":"anime","name":"Madhouse"}],
    "genres":[{"mal_id":2,"type":"anime","name":"Adventure"},{"mal_id":8,"type":"anime","name":"Drama"}],"explicit_genres":[],
    "relations":[
      {"relation":"Adaptation","entry":[{"mal_id":126287,"type":"manga","name":"Sousou no Frieren"}]},
      {"relation":"Sequel","entry":[{"mal_id":59978,"type":"anime","name":"Sousou no Frieren 2nd Season"}]}
    ]}}
    """#

    func testTenraisFullAnswerReadsAsAnEntry() throws {
        let details = try XCTUnwrap(MALSource.decoder.decode(TenraiOne<TenraiDetails>.self, from: Data(frieren.utf8)).data)
        let media = MALSource.media(details, hints: [59978: "TV"])
        XCTAssertEqual(media.id, 52991)
        XCTAssertEqual(media.idMal, 52991)
        XCTAssertEqual(media.format, "TV")
        XCTAssertEqual(media.status, "FINISHED")
        XCTAssertEqual(media.episodes, 28)
        XCTAssertEqual(media.duration, 24)
        XCTAssertEqual(media.malScore, 9.3)
        XCTAssertEqual(media.averageScore, 93)
        XCTAssertEqual(media.title?.english, "Frieren: Beyond Journey's End")
        XCTAssertEqual(media.title?.native, "葬送のフリーレン")
        XCTAssertEqual(media.coverImage?.large, "https://cdn.myanimelist.net/images/anime/1015/138006l.jpg")
        XCTAssertEqual(media.description, "An elf mage outlives her party.")
        XCTAssertEqual(media.startDate, AniListDate(year: 2023, month: 9, day: 29))
        XCTAssertEqual(media.endDate, AniListDate(year: 2024, month: 3, day: 22))
        XCTAssertEqual(media.trailer?.id, "qgQb0qxEcZM")
        XCTAssertEqual(media.genres, ["Adventure", "Drama"])
        XCTAssertEqual(media.isAdult, false)
        XCTAssertEqual(media.studios?.nodes?.first?.name, "Madhouse")
        let edges = media.relations?.edges ?? []
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(edges.first?.relationType, "ADAPTATION")
        XCTAssertEqual(edges.first?.node?.type, "MANGA")
        XCTAssertEqual(edges.last?.relationType, "SEQUEL")
        XCTAssertEqual(edges.last?.node?.format, "TV", "the offline tables' format")
        XCTAssertEqual(MALSource.relationIDs(details), [59978], "manga left out")
    }

    func testMALsOwnAnswerReadsAsAnEntry() throws {
        let json = #"""
        {"id":52991,"title":"Sousou no Frieren","main_picture":{"medium":"m.jpg","large":"l.jpg"},
        "alternative_titles":{"synonyms":["Frieren at the Funeral"],"en":"Frieren: Beyond Journey's End","ja":"葬送のフリーレン"},
        "start_date":"2023-09-29","end_date":"2024-03-22","synopsis":"An elf mage.","mean":9.3,"media_type":"tv",
        "status":"finished_airing","genres":[{"id":2,"name":"Adventure"}],"num_episodes":28,"average_episode_duration":1475,
        "rating":"pg_13","start_season":{"year":2023,"season":"fall"},"studios":[{"id":11,"name":"Madhouse"}],"source":"manga",
        "related_anime":[{"node":{"id":59978,"title":"Sousou no Frieren 2nd Season","main_picture":{"medium":"s.jpg","large":"sl.jpg"}},
          "relation_type":"sequel","relation_type_formatted":"Sequel"}],
        "recommendations":[{"node":{"id":5114,"title":"Fullmetal Alchemist: Brotherhood","main_picture":{"medium":"f.jpg"}},"num_recommendations":12}]}
        """#
        let anime = try MALSource.decoder.decode(MALOfficialAnime.self, from: Data(json.utf8))
        let media = MALSource.media(anime, hints: [59978: "TV"])
        XCTAssertEqual(media.format, "TV")
        XCTAssertEqual(media.status, "FINISHED")
        XCTAssertEqual(media.duration, 24)
        XCTAssertEqual(media.season, "FALL")
        XCTAssertEqual(media.seasonYear, 2023)
        XCTAssertEqual(media.title?.english, "Frieren: Beyond Journey's End")
        XCTAssertEqual(media.coverImage?.large, "l.jpg")
        XCTAssertEqual(media.endDate, AniListDate(year: 2024, month: 3, day: 22))
        XCTAssertEqual(media.malScore, 9.3)
        let sequel = media.relations?.edges?.first
        XCTAssertEqual(sequel?.relationType, "SEQUEL")
        XCTAssertEqual(sequel?.node?.coverImage?.large, "sl.jpg")
        XCTAssertEqual(sequel?.node?.format, "TV")
        XCTAssertEqual(media.recommendations?.nodes?.first?.mediaRecommendation?.id, 5114)
        XCTAssertEqual(media.recommendations?.nodes?.first?.mediaRecommendation?.coverImage?.large, "f.jpg")
    }

    func testMALsWordsBecomeAniListsValues() {
        XCTAssertEqual(MALSource.format(tenraiType: "TV Special"), "SPECIAL")
        XCTAssertEqual(MALSource.format(officialType: "tv_special"), "SPECIAL")
        XCTAssertEqual(MALSource.format(tenraiType: "Movie"), "MOVIE")
        XCTAssertNil(MALSource.format(tenraiType: "Unknown"))
        XCTAssertEqual(MALSource.status("Currently Airing"), "RELEASING")
        XCTAssertEqual(MALSource.status("not_yet_aired"), "NOT_YET_RELEASED")
        XCTAssertEqual(MALSource.relationType("Side story"), "SIDE_STORY")
        XCTAssertEqual(MALSource.relationType("parent_story"), "PARENT")
        XCTAssertEqual(MALSource.relationType("Spin-off"), "SPIN_OFF")
        XCTAssertEqual(MALSource.minutes("1 hr 45 min"), 105)
        XCTAssertEqual(MALSource.minutes("24 min per ep"), 24)
        XCTAssertNil(MALSource.minutes("Unknown"))
        XCTAssertEqual(MALSource.date("2017-01"), AniListDate(year: 2017, month: 1))
        XCTAssertEqual(MALSource.date("1991-07-26T00:00:00+00:00"), AniListDate(year: 1991, month: 7, day: 26))
        XCTAssertEqual(MALSource.personName("Kamado, Tanjirou"), "Tanjirou Kamado")
        XCTAssertEqual(MALSource.personName("Madhouse"), "Madhouse")
        XCTAssertEqual(MALSource.normalizedFormat("TV Special"), "SPECIAL")
        XCTAssertNil(MALSource.normalizedFormat("UNKNOWN"))
    }

    func testRelationsWithoutFormatsAreFetchedBeforeTheChainGoesOn() {
        // Goblin Slayer on MAL: each entry names its relations only.
        func named(_ id: Int) -> AniListMedia { AniListMedia(id: id, type: "ANIME") }
        func entry(_ id: Int, _ format: String, _ year: Int, prequel: Int? = nil, sequel: Int? = nil) -> AniListMedia {
            var edges: [AniListRelationEdge] = []
            if let prequel { edges.append(AniListRelationEdge(relationType: "PREQUEL", node: named(prequel))) }
            if let sequel { edges.append(AniListRelationEdge(relationType: "SEQUEL", node: named(sequel))) }
            return AniListMedia(
                id: id, type: "ANIME", format: format, startDate: AniListDate(year: year),
                relations: AniListRelationConnection(edges: edges)
            )
        }
        AnimeSource.$current.withValue(.mal) {
            var entries = [1: entry(1, "TV", 2018, sequel: 2)]
            var chain = AniListMetaBuilder.chain(from: 1, entries: entries)
            XCTAssertEqual(chain.ids, [1])
            XCTAssertEqual(chain.missing, [2], "a sequel of unknown format is fetched first")
            entries[2] = entry(2, "MOVIE", 2020, prequel: 1, sequel: 3)
            chain = AniListMetaBuilder.chain(from: 1, entries: entries)
            XCTAssertEqual(chain.missing, [3], "past the film")
            entries[3] = entry(3, "TV", 2023, prequel: 2)
            chain = AniListMetaBuilder.chain(from: 1, entries: entries)
            XCTAssertEqual(chain.ids, [1, 3])
            XCTAssertTrue(chain.missing.isEmpty)
            XCTAssertEqual(AniListMetaBuilder.chain(from: 3, entries: entries).ids, [1, 3], "back from the second season too")
        }
        // AniList's relations carry their formats: nothing more is asked for them.
        XCTAssertTrue(AniListMetaBuilder.chain(from: 1, entries: [1: entry(1, "TV", 2018, sequel: 2)]).missing.isEmpty)
    }

    func testTheCastHasMainCharactersFirstWithTheirJapaneseVoices() {
        let json = #"""
        {"data":[
          {"character":{"mal_id":2,"name":"Himmel","images":{"jpg":{"image_url":"h.jpg"}}},"role":"Supporting",
           "voice_actors":[{"person":{"mal_id":20,"name":"Okamoto, Nobuhiko","images":{"jpg":{"image_url":"o.jpg"}}},"language":"Japanese"}]},
          {"character":{"mal_id":1,"name":"Frieren","images":{"jpg":{"image_url":"f.jpg"}}},"role":"Main",
           "voice_actors":[{"person":{"mal_id":11,"name":"Smith, Mallorie"},"language":"English"},
                           {"person":{"mal_id":10,"name":"Tanezaki, Atsumi","images":{"jpg":{"image_url":"t.jpg"}}},"language":"Japanese"}]}
        ]}
        """#
        let people = MALSource.people(from: Data(json.utf8))
        XCTAssertEqual(people.map(\.name), ["Frieren", "Himmel"])
        XCTAssertEqual(people.first?.role, "Atsumi Tanezaki")
        XCTAssertEqual(people.first?.profileURL, "f.jpg")
        XCTAssertEqual(people.first?.aniListCharacterID, 1)
        XCTAssertEqual(people.first?.aniListStaffID, 10)
        XCTAssertEqual(people.first?.aniListStaffImage, "t.jpg")
        XCTAssertEqual(people.first?.peopleSource, "mal")
        XCTAssertEqual(people.first?.hasAniListPage, true)
    }

    func testMALCardsAreMALTitlesWithMALsScore() {
        let item = TenraiAnime(malID: 5114, title: "Fullmetal Alchemist: Brotherhood", type: "TV", year: 2009, score: 9.1)
        let cards = MALSource.cards([item, item], language: .romaji)
        XCTAssertEqual(cards.map(\.id), ["mal:5114"], "each title once")
        XCTAssertEqual(cards.first?.type, "series")
        XCTAssertEqual(cards.first?.year, 2009)
        XCTAssertEqual(cards.first?.externalRatings?.first?.source, MdbListDetailsService.providerMyAnimeList)
        XCTAssertEqual(cards.first?.externalRatings?.first?.value, 9.1)
    }

    func testAnAiringSeasonCountsWhatAniZipListsAsAired() throws {
        let episodes = [
            "1": AniZipEpisode(airdate: "2026-10-01"),
            "2": AniZipEpisode(airdate: "2026-10-08"),
            "3": AniZipEpisode(airdate: "2026-10-15"),
        ]
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        XCTAssertEqual(AniListMetaBuilder.airedOnAniZip(episodes, now: now), 2)
        let media = AniListMedia(id: 1, type: "ANIME", format: "TV", status: "RELEASING")
        AnimeSource.$current.withValue(.mal) {
            let videos = AniListMetaBuilder.episodes(of: media, season: 1, aniZip: episodes, now: now)
            XCTAssertEqual(videos.map(\.id), ["mal:1:1", "mal:1:2"])
        }
    }

    func testMALEpisodesAreScoredByTheirOwnEntry() async {
        let target = await MALEpisodeRatings.target(forEpisodeID: "mal:52991:7")
        XCTAssertEqual(target, MALEpisodeRatings.Target(malID: 52991, episode: 7))
        let film = await MALEpisodeRatings.target(forEpisodeID: "mal:52991")
        XCTAssertNil(film)
    }

    func testRelatedEntriesTakeThePicturesFoundLater() {
        let title = RelatedTitle(id: "mal:99001", type: "series", name: "Sequel", posterURL: nil, year: "Sequel", rating: nil, overview: nil)
        XCTAssertNil(MALSource.RelatedPictures.filled([title]).first?.posterURL)
        MALSource.RelatedPictures.store(99001, poster: "p.jpg", year: 2024)
        XCTAssertEqual(MALSource.RelatedPictures.filled([title]).first?.posterURL, "p.jpg")
        XCTAssertEqual(MALSource.RelatedPictures.filled([title]).first?.year, "Sequel", "the label stays")
    }

    func testTenraiIsAskedTwiceASecondAtMost() {
        let now = Date()
        func wait(_ sent: [Date], blocked: Date? = nil, interactive: Bool = true) -> TimeInterval {
            TenraiClient.readyTime(sent: sent, now: now, blockedUntil: blocked, interactive: interactive, othersWaiting: false)
                .timeIntervalSince(now)
        }
        XCTAssertEqual(wait([]), 0, accuracy: 0.001)
        XCTAssertEqual(wait([now.addingTimeInterval(-0.2)]), 0.3, accuracy: 0.001)
        let lastMinute = (0..<35).map { now.addingTimeInterval(-50 + Double($0)) }
        XCTAssertEqual(wait(lastMinute, interactive: false), 10, accuracy: 0.001, "35 a minute for what nobody waits on")
        XCTAssertEqual(wait(lastMinute), 0, accuracy: 0.001, "the viewer's: 50 a minute")
        XCTAssertEqual(wait([], blocked: now.addingTimeInterval(30)), 30, accuracy: 0.001, "as long as a 429 says")
        XCTAssertEqual(TenraiClient.retryAfter("12"), 12)
        XCTAssertEqual(TenraiClient.retryAfter(nil), TenraiClient.defaultRetry)
    }
}
