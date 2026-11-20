import XCTest
@testable import NuvioTV

/// The AniList page a cast card of an AniList title opens: its voice actor, or the character.
final class AniListPeopleTests: XCTestCase {
    private let decoder = JSONDecoder()

    private let voiceActor = """
    {"data":{"Staff":{"id":95991,"name":{"full":"Natsuki Hanae","native":"花江夏樹"},"image":{"large":"https://img/s.jpg"},
     "description":"__Height:__ 168 cm\\n\\nHe voices [Tanjiro](https://anilist.co/character/126071). ~!He dies.!~ img220(https://x/y.jpg)",
     "dateOfBirth":{"year":1991,"month":6,"day":26},"dateOfDeath":{"year":null,"month":null,"day":null},"homeTown":" Kanagawa, Japan ",
     "characterMedia":{"edges":[
      {"characterRole":"MAIN","characters":[{"id":126071,"name":{"full":"Tanjiro Kamado"}}],
       "node":{"id":101922,"type":"ANIME","format":"TV","seasonYear":2019,"title":{"romaji":"Kimetsu no Yaiba"},
               "coverImage":{"large":"https://img/1.jpg"},"bannerImage":"https://img/b1.jpg"}},
      {"characterRole":"MAIN","characters":[{"id":126071,"name":{"full":"Tanjiro Kamado"}}],
       "node":{"id":142329,"type":"ANIME","format":"TV","seasonYear":2021,"title":{"romaji":"Kimetsu no Yaiba: Yuukaku-hen"}}},
      {"characterRole":"MAIN","characters":[{"id":126071,"name":{"full":"Tanjiro Kamado"}}],
       "node":{"id":112151,"type":"ANIME","format":"MOVIE","seasonYear":2020,"title":{"romaji":"Kimetsu no Yaiba: Mugen Ressha-hen"}}},
      {"characterRole":"MAIN","characters":[{"id":87275,"name":{"full":"Ken Kaneki"}}],
       "node":{"id":20605,"type":"ANIME","format":"TV","seasonYear":2014,"title":{"romaji":"Tokyo Ghoul"}}},
      {"characterRole":"MAIN","characters":[{"id":6,"name":{"full":"Someone"}}],
       "node":{"id":999,"type":"ANIME","format":"OVA","isAdult":true,"title":{"romaji":"Adult"}}},
      {"characterRole":"MAIN","characters":[{"id":126071,"name":{"full":"Tanjiro Kamado"}}],
       "node":{"id":101922,"type":"ANIME","format":"TV","seasonYear":2019,"title":{"romaji":"Kimetsu no Yaiba"}}}
     ]}}}}
    """

    private func staff() throws -> AniListStaff {
        try XCTUnwrap(decoder.decode(AniListStaffResponse.self, from: Data(voiceActor.utf8)).data?.Staff)
    }

    func testAVoiceActorsPageSaysWhomTheyVoiceInEachTitle() throws {
        let page = AniListPeople.staffPage(try staff(), fallbackName: "?", language: .romaji, showsAdult: false, collapsesSeasons: true)
        XCTAssertEqual(page.detail.name, "Natsuki Hanae")
        XCTAssertEqual(page.nativeName, "花江夏樹")
        XCTAssertEqual(page.detail.birthday, "1991-06-26")
        XCTAssertNil(page.detail.deathday)
        XCTAssertEqual(page.detail.placeOfBirth, "Kanagawa, Japan")
        XCTAssertEqual(page.detail.profileURL?.absoluteString, "https://img/s.jpg")
        XCTAssertEqual(page.detail.biography, "Height: 168 cm\n\nHe voices Tanjiro.", "no spoiler, picture or link markup")
        XCTAssertEqual(page.backdropURL?.absoluteString, "https://img/b1.jpg")

        XCTAssertEqual(page.rails.map(\.id), ["anilist-series", "anilist-movies"])
        let series = page.rails[0].items
        XCTAssertEqual(series.map(\.id), ["anilist:101922", "anilist:20605"], "a later season, a repeat and an adult title are left out")
        XCTAssertEqual(series.map(\.caption), ["Tanjiro Kamado · 2019", "Ken Kaneki · 2014"])
        XCTAssertEqual(series.first?.type, "series")
        XCTAssertEqual(series.first?.year, "2019")
        XCTAssertEqual(page.rails[1].items.map(\.id), ["anilist:112151"])
        XCTAssertEqual(page.rails[1].items.first?.type, "movie")
    }

    func testEachEntryKeepsEverySeasonOfARole() throws {
        let page = AniListPeople.staffPage(try staff(), fallbackName: "?", language: .romaji, showsAdult: true, collapsesSeasons: false)
        XCTAssertEqual(page.rails[0].items.map(\.id), ["anilist:101922", "anilist:142329", "anilist:20605", "anilist:999"])
    }

    func testACharacterPageSaysItsRoleInEachTitle() {
        let character = AniListCharacter(
            id: 126071,
            name: AniListName(full: "Tanjiro Kamado", native: "竈門炭治郎"),
            description: "Kind.",
            dateOfBirth: AniListDate(month: 7, day: 14),
            media: AniListRoleConnection(edges: [
                AniListRoleEdge(characterRole: "SUPPORTING", node: AniListMedia(id: 1, type: "ANIME", format: "TV", seasonYear: 2019)),
            ])
        )
        let page = AniListPeople.characterPage(character, fallbackName: "?", language: .romaji, showsAdult: false, collapsesSeasons: true)
        XCTAssertEqual(page.detail.birthday, "Jul 14")
        XCTAssertEqual(page.nativeName, "竈門炭治郎")
        XCTAssertEqual(page.rails.first?.items.first?.caption, "Supporting · 2019")
    }

    func testPartialBirthdaysSayWhatIsKnown() {
        XCTAssertEqual(AniListPeople.birthday(AniListDate(year: 1991, month: 6, day: 26)), "1991-06-26")
        XCTAssertEqual(AniListPeople.birthday(AniListDate(month: 6, day: 26)), "Jun 26")
        XCTAssertEqual(AniListPeople.birthday(AniListDate(year: 1991, month: 6)), "Jun 1991")
        XCTAssertEqual(AniListPeople.birthday(AniListDate(year: 1991)), "1991")
        XCTAssertNil(AniListPeople.birthday(AniListDate()))
        XCTAssertNil(AniListPeople.birthday(nil))
    }

    func testACastCardOpensItsVoiceActor() {
        let card = TmdbPersonMetadata(
            name: "Tanjiro Kamado", role: "Natsuki Hanae", profileURL: "https://img/c.jpg", tmdbId: nil,
            aniListCharacterID: 126071, aniListStaffID: 95991, aniListStaffImage: "https://img/s.jpg"
        )
        XCTAssertTrue(card.hasAniListPage)
        XCTAssertEqual(AniListPeople.category(for: card), "Voice actor · as Tanjiro Kamado")
        XCTAssertEqual(AniListPeople.name(for: card), "Natsuki Hanae")
        XCTAssertEqual(AniListPeople.portrait(for: card)?.absoluteString, "https://img/s.jpg")

        let alone = TmdbPersonMetadata(name: "Narrator", role: "Main", profileURL: nil, tmdbId: nil, aniListCharacterID: 7)
        XCTAssertEqual(AniListPeople.category(for: alone), "Character")
        XCTAssertNil(AniListPeople.name(for: alone))
        XCTAssertFalse(TmdbPersonMetadata(name: "Actor", role: nil, profileURL: nil, tmdbId: 5).hasAniListPage)
    }
}
