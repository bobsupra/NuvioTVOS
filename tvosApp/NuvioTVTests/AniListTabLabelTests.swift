import XCTest
@testable import NuvioTV

/// The names of an AniList title's season tabs ("Season 2", "Yuukaku-hen", "Movie · …").
final class AniListTabLabelTests: XCTestCase {
    func testARestThatOnlyNumbersAnEntryIsASeason() {
        let reZero = "Re:Zero kara Hajimeru Isekai Seikatsu"
        XCTAssertEqual(AniListMetaBuilder.seasonName("2nd Season", base: reZero), "Season 2")
        XCTAssertEqual(AniListMetaBuilder.seasonName("3rd Season", base: reZero), "Season 3")
        XCTAssertEqual(AniListMetaBuilder.seasonName("Second Season", base: "Haikyuu!!"), "Season 2")
        XCTAssertEqual(AniListMetaBuilder.seasonName("Season 2", base: "Shingeki no Kyojin"), "Season 2")
        XCTAssertEqual(AniListMetaBuilder.seasonName("Season II", base: "Shingeki no Kyojin"), "Season 2")
        XCTAssertEqual(AniListMetaBuilder.seasonName("II", base: "Mob Psycho 100"), "Season 2")
        XCTAssertEqual(AniListMetaBuilder.seasonName("XIX", base: "Mob Psycho 100"), "Season 19")
        XCTAssertEqual(AniListMetaBuilder.seasonName("2", base: "Kono Subarashii Sekai ni Shukufuku wo!"), "Season 2")
        XCTAssertEqual(
            AniListMetaBuilder.seasonName("II: Isekai Ittara Honki Dasu", base: "Mushoku Tensei: Isekai Ittara Honki Dasu"),
            "Season 2",
            "the words after the number are the first entry's"
        )
        XCTAssertEqual(AniListMetaBuilder.seasonName("2nd Season Part 2", base: reZero), "Season 2 Part 2")
        XCTAssertEqual(AniListMetaBuilder.seasonName("Season 3 Part 2", base: "Shingeki no Kyojin"), "Season 3 Part 2")
        XCTAssertEqual(AniListMetaBuilder.seasonName("Season 2: Kakusei-hen", base: "Kaiju Sentai"), "Season 2: Kakusei-hen")
    }

    func testOtherRestsAreNotSeasons() {
        XCTAssertNil(AniListMetaBuilder.seasonName("The Final Season", base: "Shingeki no Kyojin"))
        XCTAssertNil(AniListMetaBuilder.seasonName("Final Season", base: "Shingeki no Kyojin"))
        XCTAssertNil(AniListMetaBuilder.seasonName("Yuukaku-hen", base: "Kimetsu no Yaiba"))
        XCTAssertNil(AniListMetaBuilder.seasonName("100", base: "Mob"), "past 30")
        XCTAssertNil(AniListMetaBuilder.seasonName("I", base: "Mob"), "a lone I")
        XCTAssertNil(AniListMetaBuilder.seasonName("IIII", base: "Mob"), "not a roman number")
        XCTAssertNil(AniListMetaBuilder.seasonName("2 Hearts", base: "Mob"), "a bare number before other words")
        XCTAssertNil(AniListMetaBuilder.seasonName("", base: "Mob"))
    }

    private func tab(_ id: Int, _ name: String, _ year: Int, format: String = "TV") -> AniListMedia {
        AniListMedia(id: id, type: "ANIME", format: format, seasonYear: year, title: AniListTitle(romaji: name))
    }

    func testTabsAreSeasonsOnlyWhenTheirNamesNumberThem() {
        let attackOnTitan = [
            tab(1, "Shingeki no Kyojin", 2013),
            tab(2, "Shingeki no Kyojin Season 2", 2017),
            tab(3, "Shingeki no Kyojin Season 3 Part 2", 2019),
            tab(4, "Shingeki no Kyojin: The Final Season", 2020),
        ]
        XCTAssertEqual(AniListMetaBuilder.tabLabels(attackOnTitan, language: .romaji), [
            1: .init(name: "Season 1", year: 2013),
            2: .init(name: "Season 2", year: 2017),
            3: .init(name: "Season 3 Part 2", year: 2019),
            4: .init(name: "The Final Season", year: 2020),
        ])

        let demonSlayer = [
            tab(10, "Kimetsu no Yaiba", 2019),
            tab(11, "Kimetsu no Yaiba: Yuukaku-hen", 2021),
            tab(12, "Kimetsu no Yaiba: Mugen Ressha-hen", 2020, format: "MOVIE"),
        ]
        XCTAssertEqual(AniListMetaBuilder.tabLabels(demonSlayer, language: .romaji), [
            1: .init(name: "TV", year: 2019),
            2: .init(name: "Yuukaku-hen", year: 2021),
            3: .init(name: "Movie · Mugen Ressha-hen", year: 2020),
        ])
        XCTAssertEqual(AniListMetaBuilder.tabTitles(demonSlayer, language: .romaji)[2], "Yuukaku-hen · 2021")
    }

    func testANameThatWasNotShortenedIsNotReadAsASeason() {
        let tabs = [tab(1, "Kaiju Sentai", 2020), tab(2, "II", 2021)]
        XCTAssertEqual(AniListMetaBuilder.tabLabels(tabs, language: .romaji)[2], AniListMetaBuilder.TabLabel(name: "II", year: 2021))
        XCTAssertEqual(AniListMetaBuilder.tabLabels(tabs, language: .romaji)[1], AniListMetaBuilder.TabLabel(name: "TV", year: 2020))
    }

    func testATitleOfOneEntrySaysWhatItIs() {
        var series = tab(1, "Bocchi the Rock!", 2022)
        series.episodes = 12
        XCTAssertEqual(AniListMetaBuilder.tabLabels([series], language: .romaji), [1: .init(name: "TV · 12 episodes", year: 2022)])
        XCTAssertEqual(AniListMetaBuilder.singleTitle(tab(2, "Kaiju Sentai: The Movie", 2022, format: "MOVIE")), "Movie · 2022")
    }
}
