import XCTest
@testable import NuvioTV

final class DetailsCreditLineTests: XCTestCase {
    private func series(director: [String]? = nil, writer: [String]? = nil) -> NuvioMeta {
        NuvioMeta(id: "tt1", name: "Show", type: "series", director: director, writer: writer)
    }

    private func movie(director: [String]? = nil, writer: [String]? = nil) -> NuvioMeta {
        NuvioMeta(id: "tt2", name: "Film", type: "movie", director: director, writer: writer)
    }

    private func label(_ key: String, _ fallback: String, _ names: String) -> String {
        L10n.format(key, fallback: fallback, names)
    }

    func testASeriesCreatorComesOnlyFromTMDBsCreatedBy() {
        let meta = series(director: ["Episode Director"], writer: ["Episode Writer"])
        XCTAssertEqual(
            DetailsCreditLine.text(for: meta, creators: ["Vince Gilligan"]),
            label("details_credit_creator", "Creator: %@", "Vince Gilligan")
        )
        XCTAssertEqual(
            DetailsCreditLine.text(for: meta, creators: ["Matt Duffer", "Ross Duffer", "Third"]),
            label("details_credit_creators", "Creators: %@", "Matt Duffer, Ross Duffer")
        )
    }

    func testWithoutAKnownCreatorASeriesShowsTheRoleItHas() {
        // Writers and directors of a series aren't its creator.
        XCTAssertEqual(
            DetailsCreditLine.text(for: series(director: ["D"], writer: ["W1", "W2"]), creators: []),
            label("details_credit_writers", "Writers: %@", "W1, W2")
        )
        XCTAssertEqual(
            DetailsCreditLine.text(for: series(director: ["D"]), creators: []),
            label("details_credit_director", "Director: %@", "D")
        )
        XCTAssertNil(DetailsCreditLine.text(for: series(), creators: []))
    }

    func testAMovieShowsItsDirectorThenItsWriter() {
        XCTAssertEqual(
            DetailsCreditLine.text(for: movie(director: ["A", "B"], writer: ["W"]), creators: []),
            label("details_credit_directors", "Directors: %@", "A, B")
        )
        XCTAssertEqual(
            DetailsCreditLine.text(for: movie(writer: ["W"]), creators: []),
            label("details_credit_writer", "Writer: %@", "W")
        )
        // A movie has no creator line even if some list said one.
        XCTAssertEqual(
            DetailsCreditLine.text(for: movie(director: ["A"]), creators: ["Someone"]),
            label("details_credit_director", "Director: %@", "A")
        )
    }

    func testBlankNamesAreIgnored() {
        XCTAssertEqual(
            DetailsCreditLine.text(for: series(writer: [" ", "W"]), creators: [""]),
            label("details_credit_writer", "Writer: %@", "W")
        )
    }

    func testCreatorsAreThePeopleCreditedAsCreator() {
        let people = [
            TmdbPersonMetadata(name: "Creator A", role: TmdbPersonMetadata.creatorRole, profileURL: nil, tmdbId: 1, credit: .creator),
            TmdbPersonMetadata(name: "Director B", role: "Director", profileURL: nil, tmdbId: 2, credit: .director),
            TmdbPersonMetadata(name: "Actor C", role: "Walter White", profileURL: nil, tmdbId: 3, credit: .cast),
        ]
        XCTAssertEqual(DetailsCreditLine.creators(in: people), ["Creator A"])
    }

    func testAnActorPlayingACharacterCalledCreatorIsNotTheCreator() {
        let people = [
            TmdbPersonMetadata(name: "Actor D", role: "Creator", profileURL: nil, tmdbId: 4, credit: .cast),
            // From a source that doesn't say what the credit is (AniList, fallbacks).
            TmdbPersonMetadata(name: "Unknown E", role: "Creator", profileURL: nil, tmdbId: 5),
        ]
        XCTAssertEqual(DetailsCreditLine.creators(in: people), [])
        let meta = NuvioMeta(id: "tt3", name: "Show", type: "series", writer: ["W"])
        XCTAssertEqual(
            DetailsCreditLine.text(for: meta, creators: DetailsCreditLine.creators(in: people)),
            label("details_credit_writer", "Writer: %@", "W")
        )
    }

    // MARK: Person cards

    func testPersonCardsLocalizeCreatorAndDirectorButKeepCharacterNames() {
        let creator = TmdbPersonMetadata(name: "A", role: "Creator", profileURL: nil, tmdbId: 1, credit: .creator)
        let director = TmdbPersonMetadata(name: "B", role: "Director", profileURL: nil, tmdbId: 2, credit: .director)
        XCTAssertEqual(creator.displayRole, L10n.string("details_person_creator", fallback: "Creator"))
        XCTAssertEqual(director.displayRole, L10n.string("details_director", fallback: "Director"))

        // A character's name is shown exactly as TMDB gives it, even "Creator" or "Director".
        let playingCreator = TmdbPersonMetadata(name: "C", role: "Creator", profileURL: nil, tmdbId: 3, credit: .cast)
        let playingDirector = TmdbPersonMetadata(name: "D", role: " Director ", profileURL: nil, tmdbId: 4, credit: .cast)
        let character = TmdbPersonMetadata(name: "E", role: "Walter White", profileURL: nil, tmdbId: 5, credit: .cast)
        XCTAssertEqual(playingCreator.displayRole, "Creator")
        XCTAssertEqual(playingDirector.displayRole, "Director")
        XCTAssertEqual(character.displayRole, "Walter White")

        // Sources without a credit type keep their role as given; blank roles show nothing.
        XCTAssertEqual(TmdbPersonMetadata(name: "F", role: "Main", profileURL: nil, tmdbId: nil).displayRole, "Main")
        XCTAssertNil(TmdbPersonMetadata(name: "G", role: "  ", profileURL: nil, tmdbId: nil, credit: .cast).displayRole)
    }
}
