import XCTest
@testable import NuvioTV

final class SurpriseMeCandidatePoolTests: XCTestCase {
    private typealias Key = SurpriseMeCandidatePool.Key

    private func movie(_ id: String) -> NuvioMeta { NuvioMeta(id: id, name: id, type: "movie") }
    private func pick(_ id: String) -> SurpriseMeAIPick { SurpriseMeAIPick(meta: movie(id), reason: nil) }
    private let home = [NuvioMeta(id: "home", name: "home", type: "movie")]

    private func key(profile: String = "a", tmdb: Bool = true, history: Int = 10) -> Key {
        Key(profileScope: profile, useTMDB: tmdb, historySignature: history)
    }

    /// Prepares `key` and returns the ticket for a request made now.
    private func prepared(_ pool: inout SurpriseMeCandidatePool, _ key: Key) -> SurpriseMeCandidatePool.Ticket {
        _ = pool.prepare(for: key)
        return pool.ticket!
    }

    func testTurningTMDBOffDropsItsCandidatesAndTheAIQueue() {
        var pool = SurpriseMeCandidatePool()
        XCTAssertNil(pool.ticket)
        XCTAssertEqual(pool.prepare(for: key()), .candidatesStale)
        let on = pool.ticket!
        XCTAssertTrue(pool.needsOnlineCandidates)
        XCTAssertTrue(pool.accept(online: [movie("tmdb")], for: on))
        XCTAssertTrue(pool.accept(aiQueue: [pick("tmdb")], for: on))
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home", "tmdb"])

        XCTAssertEqual(pool.prepare(for: key(tmdb: false)), .candidatesStale)
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
        XCTAssertNil(pool.nextQueuedPick())
        XCTAssertFalse(pool.needsOnlineCandidates)
    }

    func testAnAnswerAfterTMDBWasTurnedOffIsIgnored() {
        var pool = SurpriseMeCandidatePool()
        let requested = prepared(&pool, key())
        _ = pool.prepare(for: key(tmdb: false))
        XCTAssertFalse(pool.stillCurrent(requested))
        XCTAssertFalse(pool.accept(online: [movie("late")], for: requested))
        XCTAssertFalse(pool.accept(aiQueue: [pick("late")], for: requested))
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
        XCTAssertNil(pool.nextQueuedPick())
    }

    func testAnAnswerFromBeforeTMDBWentOffAndOnAgainIsIgnored() {
        var pool = SurpriseMeCandidatePool()
        let firstOn = prepared(&pool, key())
        _ = pool.prepare(for: key(tmdb: false))
        let secondOn = prepared(&pool, key())
        XCTAssertEqual(firstOn.key, secondOn.key, "the same key twice")

        // The first request answers late, then the current one.
        XCTAssertFalse(pool.accept(online: [movie("old")], for: firstOn))
        XCTAssertFalse(pool.accept(aiQueue: [pick("old")], for: firstOn))
        XCTAssertFalse(pool.stillCurrent(firstOn))
        XCTAssertTrue(pool.accept(online: [movie("new")], for: secondOn))
        XCTAssertTrue(pool.accept(aiQueue: [pick("new")], for: secondOn))
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home", "new"])
        XCTAssertEqual(pool.nextQueuedPick()?.meta.id, "new")
    }

    func testAnAnswerFromBeforeSwitchingProfilesAwayAndBackIsIgnored() {
        var pool = SurpriseMeCandidatePool()
        let firstA = prepared(&pool, key(profile: "a"))
        XCTAssertEqual(pool.prepare(for: key(profile: "b")), .profileChanged)
        XCTAssertEqual(pool.prepare(for: key(profile: "a")), .profileChanged)

        XCTAssertFalse(pool.accept(online: [movie("old-a")], for: firstA))
        XCTAssertFalse(pool.accept(aiQueue: [pick("old-a")], for: firstA))
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
        XCTAssertTrue(pool.needsOnlineCandidates)
    }

    func testAnotherProfileGetsNothingGatheredForThePreviousOne() {
        var pool = SurpriseMeCandidatePool()
        let profileA = prepared(&pool, key(profile: "a"))
        pool.accept(online: [movie("for-a")], for: profileA)
        pool.accept(aiQueue: [pick("for-a")], for: profileA)

        XCTAssertEqual(pool.prepare(for: key(profile: "b")), .profileChanged)
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
        XCTAssertNil(pool.nextQueuedPick())
        XCTAssertTrue(pool.needsOnlineCandidates, "B gathers its own")
        XCTAssertFalse(pool.accept(online: [movie("for-a")], for: profileA))
    }

    func testCandidatesAreGatheredAgainWhenTheHistoryChanges() {
        var pool = SurpriseMeCandidatePool()
        let before = prepared(&pool, key(history: 10))
        pool.accept(online: [movie("old")], for: before)
        XCTAssertFalse(pool.needsOnlineCandidates)

        XCTAssertEqual(pool.prepare(for: key(history: 11)), .candidatesStale)
        XCTAssertTrue(pool.needsOnlineCandidates)
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
    }

    func testTheSameKeyKeepsWhatWasGathered() {
        var pool = SurpriseMeCandidatePool()
        let current = prepared(&pool, key())
        pool.accept(online: [movie("kept")], for: current)
        pool.accept(aiQueue: [pick("first"), pick("second")], for: current)

        XCTAssertEqual(pool.prepare(for: key()), .unchanged)
        XCTAssertTrue(pool.stillCurrent(current))
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home", "kept"])
        XCTAssertEqual(pool.nextQueuedPick()?.meta.id, "first")
        XCTAssertEqual(pool.nextQueuedPick()?.meta.id, "second")
        XCTAssertNil(pool.nextQueuedPick())
    }

    // MARK: History signature

    func testTheHistorySignatureChangesWhenTitlesChangeButTheCountDoesNot() {
        let a = movie("tt1"), b = movie("tt2"), c = movie("tt3")
        let before = SurpriseMeHistory(watched: [a, b], library: [], continueWatching: [])
        let swapped = SurpriseMeHistory(watched: [a, c], library: [], continueWatching: [])
        XCTAssertEqual(before.titleCount, swapped.titleCount)
        XCTAssertNotEqual(before.signature, swapped.signature)

        // Order matters (TMDB is seeded from the most recent), and so does the list.
        XCTAssertNotEqual(before.signature, SurpriseMeHistory(watched: [b, a], library: [], continueWatching: []).signature)
        XCTAssertNotEqual(before.signature, SurpriseMeHistory(watched: [a], library: [b], continueWatching: []).signature)
        XCTAssertEqual(before.signature, SurpriseMeHistory(watched: [a, b], library: [], continueWatching: []).signature)
    }

    func testTheHistorySignatureChangesWhenATitlesGenresChange() {
        func meta(_ genres: [String]?) -> NuvioMeta { NuvioMeta(id: "tt1", name: "Film", type: "movie", genres: genres) }
        let drama = SurpriseMeHistory(watched: [meta(["Drama"])], library: [], continueWatching: [])
        let sciFi = SurpriseMeHistory(watched: [meta(["Drama", "Sci-Fi"])], library: [], continueWatching: [])
        XCTAssertNotEqual(drama.signature, sciFi.signature)
        XCTAssertNotEqual(drama.signature, SurpriseMeHistory(watched: [meta(nil)], library: [], continueWatching: []).signature)

        // The same genres in another order or spelling are the same taste.
        let reordered = SurpriseMeHistory(watched: [meta(["Sci-Fi", "Drama"])], library: [], continueWatching: [])
        let respelled = SurpriseMeHistory(watched: [meta(["drama", "Science Fiction"])], library: [], continueWatching: [])
        XCTAssertEqual(sciFi.signature, reordered.signature)
        XCTAssertEqual(sciFi.signature, respelled.signature)
    }
}

