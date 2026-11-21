import XCTest
@testable import NuvioTV

/// Kitsu as a source of its own: `kitsu:` titles read from Kitsu's JSON:API and built by the
/// AniList engine.
final class KitsuSourceTests: XCTestCase {
    func testKitsuIdsSayTheirSource() {
        XCTAssertEqual(AnimeSource.entry(from: "kitsu:41370")?.source, .kitsu)
        XCTAssertEqual(AnimeSource.entry(from: "Kitsu:41370:3")?.id, 41370)
        XCTAssertEqual(AnimeSource.kitsuID(from: "kitsu:41370:3"), 41370)
        XCTAssertNil(AnimeSource.kitsuID(from: "mal:41370"))
        XCTAssertEqual(AniListAccount.episodeNumber(in: "kitsu:41370:3"), 3, "watched Kitsu episodes are written")
        AnimeSource.$current.withValue(.kitsu) {
            XCTAssertEqual(AniListMetaBuilder.metaID(7), "kitsu:7")
            XCTAssertEqual(AniListMetaBuilder.episodeID(entry: 7, episode: 2), "kitsu:7:2")
            XCTAssertEqual(AniListMetaBuilder.aniListID(from: "kitsu:7:2"), 7)
        }
    }

    private let frieren = #"""
    {"data":{"id":"46474","type":"anime","attributes":{
      "canonicalTitle":"Sousou no Frieren","titles":{"en":"Frieren: Beyond Journey's End","en_jp":"Sousou no Frieren","ja_jp":"葬送のフリーレン","en_us":null},
      "abbreviatedTitles":["Frieren"],"synopsis":"An elf mage outlives her party.\n\n(Source: Crunchyroll)","averageRating":"89.42",
      "startDate":"2023-09-29","endDate":"2024-03-22","subtype":"TV","status":"finished",
      "posterImage":{"tiny":"t.jpg","large":"l.jpg","original":"o.jpg","meta":{"dimensions":{}}},"coverImage":null,
      "episodeCount":28,"episodeLength":24,"youtubeVideoId":"qgQb0qxEcZM","ageRating":"PG","nsfw":false},
      "relationships":{
        "genres":{"links":{},"data":[{"type":"genres","id":"2"}]},
        "mediaRelationships":{"data":[{"type":"mediaRelationships","id":"900"},{"type":"mediaRelationships","id":"901"}]},
        "episodes":{"links":{}}
      }},
     "included":[
      {"id":"2","type":"genres","attributes":{"name":"Adventure","slug":"adventure"}},
      {"id":"900","type":"mediaRelationships","attributes":{"role":"sequel"},
       "relationships":{"destination":{"data":{"type":"anime","id":"48000"}}}},
      {"id":"901","type":"mediaRelationships","attributes":{"role":"adaptation"},
       "relationships":{"destination":{"data":{"type":"manga","id":"55"}}}},
      {"id":"48000","type":"anime","attributes":{"canonicalTitle":"Sousou no Frieren 2nd Season","titles":{"en_jp":"Sousou no Frieren 2nd Season"},
       "subtype":"TV","status":"upcoming","startDate":"2026-01-16","posterImage":{"medium":"s2.jpg"}}},
      {"id":"55","type":"manga","attributes":{"canonicalTitle":"Sousou no Frieren"}}
     ]}
    """#

    func testAKitsuEntryReadsAsAnEntryWithItsRelations() throws {
        let document = try XCTUnwrap(KitsuSource.document(Data(frieren.utf8)))
        let anime = try XCTUnwrap(document.first)
        let media = KitsuSource.media(anime, lookup: document.lookup)
        XCTAssertEqual(media.id, 46474)
        XCTAssertEqual(media.format, "TV")
        XCTAssertEqual(media.status, "FINISHED")
        XCTAssertEqual(media.episodes, 28)
        XCTAssertEqual(media.duration, 24)
        XCTAssertEqual(media.averageScore, 89)
        XCTAssertEqual(media.title?.romaji, "Sousou no Frieren")
        XCTAssertEqual(media.title?.english, "Frieren: Beyond Journey's End")
        XCTAssertEqual(media.title?.native, "葬送のフリーレン")
        XCTAssertEqual(media.coverImage?.large, "l.jpg")
        XCTAssertEqual(media.description, "An elf mage outlives her party.")
        XCTAssertEqual(media.startDate, AniListDate(year: 2023, month: 9, day: 29))
        XCTAssertEqual(media.trailer?.id, "qgQb0qxEcZM")
        XCTAssertEqual(media.genres, ["Adventure"])
        XCTAssertEqual(media.isAdult, false)
        let edges = media.relations?.edges ?? []
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(edges.first?.relationType, "SEQUEL")
        XCTAssertEqual(edges.first?.node?.id, 48000)
        XCTAssertEqual(edges.first?.node?.format, "TV", "Kitsu gives the relation's format")
        XCTAssertEqual(edges.first?.node?.status, "NOT_YET_RELEASED")
        XCTAssertEqual(edges.first?.node?.coverImage?.large, "s2.jpg")
        XCTAssertEqual(edges.last?.node?.type, "MANGA")
    }

    func testAKitsuSequelIsASeasonByTheFormatKitsuGivesWithIt() throws {
        let document = try XCTUnwrap(KitsuSource.document(Data(frieren.utf8)))
        let first = KitsuSource.media(try XCTUnwrap(document.first), lookup: document.lookup)
        AnimeSource.$current.withValue(.kitsu) {
            let chain = AniListMetaBuilder.chain(from: first.id, entries: [first.id: first])
            XCTAssertEqual(chain.ids, [46474])
            XCTAssertEqual(chain.missing, [48000], "the sequel is fetched for its own relations")
        }
    }

    func testTheCastHasMainCharactersFirstWithTheirJapaneseVoices() throws {
        let json = #"""
        {"data":[
          {"id":"1","type":"mediaCharacters","attributes":{"role":"supporting"},
           "relationships":{"character":{"data":{"type":"characters","id":"20"}},"voices":{"data":[{"type":"characterVoices","id":"30"}]}}},
          {"id":"2","type":"mediaCharacters","attributes":{"role":"main"},
           "relationships":{"character":{"data":{"type":"characters","id":"21"}},
             "voices":{"data":[{"type":"characterVoices","id":"31"},{"type":"characterVoices","id":"32"}]}}}
         ],
         "included":[
          {"id":"20","type":"characters","attributes":{"canonicalName":"Himmel","image":{"original":"h.jpg"}}},
          {"id":"21","type":"characters","attributes":{"canonicalName":"Frieren","malId":1000,"image":{"original":"f.jpg"}}},
          {"id":"30","type":"characterVoices","attributes":{"locale":"ja_jp"},"relationships":{"person":{"data":{"type":"people","id":"40"}}}},
          {"id":"31","type":"characterVoices","attributes":{"locale":"en"},"relationships":{"person":{"data":{"type":"people","id":"41"}}}},
          {"id":"32","type":"characterVoices","attributes":{"locale":"ja_jp"},"relationships":{"person":{"data":{"type":"people","id":"42"}}}},
          {"id":"40","type":"people","attributes":{"name":"Nobuhiko Okamoto","image":{"original":"o.jpg"}}},
          {"id":"41","type":"people","attributes":{"name":"Mallorie Rodak"}},
          {"id":"42","type":"people","attributes":{"name":"Atsumi Tanezaki","malId":2000,"image":{"original":"t.jpg"}}}
         ]}
        """#
        let document = try XCTUnwrap(KitsuSource.document(Data(json.utf8)))
        let people = KitsuSource.people(from: document)
        XCTAssertEqual(people.map(\.name), ["Frieren", "Himmel"])
        XCTAssertEqual(people.first?.role, "Atsumi Tanezaki")
        XCTAssertEqual(people.first?.aniListCharacterID, 21)
        XCTAssertEqual(people.first?.aniListStaffID, 42)
        XCTAssertEqual(people.first?.aniListStaffImage, "t.jpg")
        XCTAssertEqual(people.first?.peopleSource, "kitsu")

        // MyAnimeList's pictures by the MAL ids Kitsu gives, Kitsu's where MAL has none.
        let mal = #"""
        {"data":[
          {"character":{"mal_id":1000,"name":"Frieren","images":{"jpg":{"image_url":"https://cdn.myanimelist.net/images/characters/frieren.jpg"}}},
           "role":"Main","voice_actors":[{"person":{"mal_id":2000,"name":"Tanezaki, Atsumi","images":{"jpg":{"image_url":"https://cdn.myanimelist.net/images/voiceactors/tanezaki.jpg"}}},"language":"Japanese"}]},
          {"character":{"mal_id":1001,"name":"Nobody","images":{"jpg":{"image_url":"https://cdn.myanimelist.net/images/questionmark_23.gif"}}},
           "role":"Supporting","voice_actors":[]}
         ]}
        """#
        let pictures = KitsuSource.malPictures(from: Data(mal.utf8))
        XCTAssertNil(pictures.characters[1001], "MAL's stand-in is no picture")
        let withMAL = KitsuSource.people(from: document, malPictures: pictures)
        XCTAssertEqual(withMAL.first?.profileURL, "https://cdn.myanimelist.net/images/characters/frieren.jpg")
        XCTAssertEqual(withMAL.first?.aniListStaffImage, "https://cdn.myanimelist.net/images/voiceactors/tanezaki.jpg")
        XCTAssertEqual(withMAL.last?.profileURL, "h.jpg")
    }

    func testKitsuScoreFollowsKitsuUntilSwitched() {
        let store = UserDefaults(suiteName: "KitsuSourceTests.score")!
        store.removePersistentDomain(forName: "KitsuSourceTests.score")
        XCTAssertFalse(KitsuSettings.showsScore(in: store))
        store.set(true, forKey: SettingsKey.kitsuEnabled)
        XCTAssertTrue(KitsuSettings.showsScore(in: store))
        store.set(false, forKey: SettingsKey.kitsuScore)
        XCTAssertFalse(KitsuSettings.showsScore(in: store))
        store.set(false, forKey: SettingsKey.kitsuEnabled)
        store.set(true, forKey: SettingsKey.kitsuScore)
        XCTAssertTrue(KitsuSettings.showsScore(in: store), "works with Kitsu off")
        XCTAssertEqual(AniListMetaBuilder.kitsuRating(entry: 7, score: 82)?.source, "kitsu")
        XCTAssertNil(AniListMetaBuilder.kitsuRating(entry: 7, score: 0))
        XCTAssertEqual(AddonRatingsService.heroRatingDisplayName(for: "kitsu"), "Kitsu")
    }

    func testKitsuCardsAreKitsuTitlesWithKitsusScore() throws {
        let document = try XCTUnwrap(KitsuSource.document(Data(frieren.utf8)))
        let cards = KitsuSource.cards(document.data + document.data, language: .romaji)
        XCTAssertEqual(cards.map(\.id), ["kitsu:46474"], "each title once")
        XCTAssertEqual(cards.first?.externalRatings?.first?.source, AniListMetaBuilder.kitsuRatingSource)
        XCTAssertEqual(cards.first?.externalRatings?.first?.value, 89)
    }

    func testCatalogPagesAskKitsuTheRightWay() throws {
        let trending = try XCTUnwrap(KitsuCatalogs.request(for: "kitsu-trending", page: 1))
        XCTAssertEqual(trending.path, "trending/anime")
        XCTAssertNil(KitsuCatalogs.request(for: "kitsu-trending", page: 2), "trending has one page")
        let airing = try XCTUnwrap(KitsuCatalogs.request(for: "kitsu-airing", page: 2))
        XCTAssertEqual(airing.path, "anime")
        let query = Dictionary(airing.query, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(query["filter[status]"], "current")
        XCTAssertEqual(query["sort"], "-user_count")
        XCTAssertEqual(query["page[offset]"], "20")
        let movies = Dictionary(try XCTUnwrap(KitsuCatalogs.request(for: "kitsu-type-movie", page: 1)).query, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(movies["filter[subtype]"], "movie")
        let genre = Dictionary(try XCTUnwrap(KitsuCatalogs.request(for: "kitsu-genre-Sci-Fi", page: 1)).query, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(genre["filter[genres]"], "Sci-Fi")
        XCTAssertNil(KitsuCatalogs.request(for: "kitsu-nonsense", page: 1))
    }

    func testKitsuWordsBecomeAniListsValues() {
        XCTAssertEqual(KitsuSource.format("movie"), "MOVIE")
        XCTAssertEqual(KitsuSource.format("special"), "SPECIAL")
        XCTAssertNil(KitsuSource.format("weird"))
        XCTAssertEqual(KitsuSource.status("current"), "RELEASING")
        XCTAssertEqual(KitsuSource.status("tba"), "NOT_YET_RELEASED")
        XCTAssertEqual(MALSource.relationType("spinoff"), "SPIN_OFF")
    }

    func testTheLoginAnswerGivesTokens() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = #"{"access_token":"abc","token_type":"bearer","expires_in":2591999,"refresh_token":"def","scope":"public"}"#
        let tokens = try KitsuAccount.parseTokens(Data(json.utf8), now: now)
        XCTAssertEqual(tokens.accessToken, "abc")
        XCTAssertEqual(tokens.refreshToken, "def")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(2_591_999))
        XCTAssertThrowsError(try KitsuAccount.parseTokens(Data(#"{"error":"invalid_grant"}"#.utf8)))
        let body = String(decoding: KitsuAccount.formBody(["username": "a@b.c", "password": "p&ss w"]), as: UTF8.self)
        XCTAssertEqual(body, "password=p%26ss%20w&username=a%40b.c")
    }
}
