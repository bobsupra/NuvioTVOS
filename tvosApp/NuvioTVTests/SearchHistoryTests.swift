import XCTest
@testable import NuvioTV

final class SearchHistoryTests: XCTestCase {
    func testSanitizeDiscardsShortAndEmptyQueries() {
        let input = ["", " ", "S", "a", "  b  "]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertTrue(output.isEmpty)
    }

    func testSanitizePrunesSubstringsAndPrefixes() {
        let input = ["Silo", "Sil", "Si", "S"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Silo"])
    }

    func testSanitizeDeduplicatesCaseInsensitively() {
        let input = ["Silo", "silo", "SILO"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Silo"])
    }

    func testSanitizePreservesDistinctQueries() {
        let input = ["Star Wars", "Star Trek", "Dune"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Star Wars", "Star Trek", "Dune"])
    }

    func testSanitizeRespectsMaxCount() {
        let input = (1...12).map { "Movie \($0)" }
        let output = SearchHistoryStore.sanitize(input, maxCount: 8)
        XCTAssertEqual(output.count, 8)
        XCTAssertEqual(output.first, "Movie 1")
        XCTAssertEqual(output.last, "Movie 8")
    }

    func testCommitReplacesIntermediateTypingPrefixes() {
        var current: [String] = []
        var session: String? = nil

        // User types 'S' (ignored because < 2)
        (current, session) = SearchHistoryStore.commit("S", current: current, sessionQuery: session)
        XCTAssertEqual(current, [])
        XCTAssertNil(session)

        // User types 'Si'
        (current, session) = SearchHistoryStore.commit("Si", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Si"])
        XCTAssertEqual(session, "Si")

        // User types 'Sil'
        (current, session) = SearchHistoryStore.commit("Sil", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sil"])
        XCTAssertEqual(session, "Sil")

        // User types 'Silo'
        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo"])
        XCTAssertEqual(session, "Silo")
    }

    func testCommitHandlesBackspacingInSameSession() {
        var current: [String] = []
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo"])

        // User backspaces to "Sil" in same session
        (current, session) = SearchHistoryStore.commit("Sil", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sil"])
        XCTAssertEqual(session, "Sil")

        // User changes to "Sila"
        (current, session) = SearchHistoryStore.commit("Sila", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sila"])
        XCTAssertEqual(session, "Sila")
    }

    func testCommitPreservesUnrelatedQueries() {
        var current = ["Dune", "Inception"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo", "Dune", "Inception"])
    }

    func testCommitMovesExistingQueryToFront() {
        var current = ["Dune", "Silo", "Batman"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo", "Dune", "Batman"])
    }

    func testCommitPrunesSubstringOfMultiWordQuery() {
        var current: [String] = []
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("The", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The"])

        (current, session) = SearchHistoryStore.commit("The Bat", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The Bat"])

        (current, session) = SearchHistoryStore.commit("The Batman", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The Batman"])
    }

    func testCommitPreservesDistinctPrefixShares() {
        var current = ["Star Wars"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Star Trek", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Star Trek", "Star Wars"])
    }
}
