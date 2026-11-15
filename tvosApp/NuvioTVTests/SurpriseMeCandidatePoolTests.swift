import XCTest
@testable import NuvioTV

final class SurpriseMeCandidatePoolTests: XCTestCase {
    private typealias Key = SurpriseMeCandidatePool.Key

    private func movie(_ id: String) -> NuvioMeta { NuvioMeta(id: id, name: id, type: "movie") }
    private func pick(_ id: String) -> SurpriseMeAIPick { SurpriseMeAIPick(meta: movie(id), reason: nil) }
    private let home = [NuvioMeta(id: "home", name: "home", type: "movie")]

    private func key(profile: String = "a", tmdb: Bool = true, history: Int = 10) -> Key {
        Key(profileScope: profile, useTMDB: tmdb, historyCount: history)
    }

    func testTurningTMDBOffDropsItsCandidatesAndTheAIQueue() {
        var pool = SurpriseMeCandidatePool()
        let on = key()
        XCTAssertEqual(pool.prepare(for: on), .candidatesStale)
        XCTAssertTrue(pool.needsOnlineCandidates)
        XCTAssertTrue(pool.accept(online: [movie("tmdb")], for: on))
        XCTAssertTrue(pool.accept(aiQueue: [pick("tmdb")], for: on))
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home", "tmdb"])

        XCTAssertEqual(pool.prepare(for: key(tmdb: false)), .candidatesStale)
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
        XCTAssertNil(pool.nextQueuedPick())
        XCTAssertFalse(pool.needsOnlineCandidates)
    }

    func testARequestThatAnswersAfterTMDBWasTurnedOffIsIgnored() {
        var pool = SurpriseMeCandidatePool()
        let requested = key()
        _ = pool.prepare(for: requested)
        // TMDB is turned off while the request is out.
        _ = pool.prepare(for: key(tmdb: false))
        XCTAssertFalse(pool.accept(online: [movie("late")], for: requested))
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
        XCTAssertFalse(pool.accept(aiQueue: [pick("late")], for: requested))
        XCTAssertNil(pool.nextQueuedPick())
    }

    func testAnotherProfileGetsNothingGatheredForThePreviousOne() {
        var pool = SurpriseMeCandidatePool()
        let profileA = key(profile: "a")
        _ = pool.prepare(for: profileA)
        pool.accept(online: [movie("for-a")], for: profileA)
        pool.accept(aiQueue: [pick("for-a")], for: profileA)

        XCTAssertEqual(pool.prepare(for: key(profile: "b")), .profileChanged)
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
        XCTAssertNil(pool.nextQueuedPick())
        XCTAssertTrue(pool.needsOnlineCandidates, "B gathers its own")
        // A's request answering late doesn't fill B's pool.
        XCTAssertFalse(pool.accept(online: [movie("for-a")], for: profileA))
    }

    func testCandidatesAreGatheredAgainWhenTheHistoryChanges() {
        var pool = SurpriseMeCandidatePool()
        let before = key(history: 10)
        _ = pool.prepare(for: before)
        pool.accept(online: [movie("old")], for: before)
        XCTAssertFalse(pool.needsOnlineCandidates)

        XCTAssertEqual(pool.prepare(for: key(history: 11)), .candidatesStale)
        XCTAssertTrue(pool.needsOnlineCandidates)
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home"])
    }

    func testTheSameKeyKeepsWhatWasGathered() {
        var pool = SurpriseMeCandidatePool()
        let current = key()
        _ = pool.prepare(for: current)
        pool.accept(online: [movie("kept")], for: current)
        pool.accept(aiQueue: [pick("first"), pick("second")], for: current)

        XCTAssertEqual(pool.prepare(for: current), .unchanged)
        XCTAssertEqual(pool.candidates(home: home).map(\.id), ["home", "kept"])
        XCTAssertEqual(pool.nextQueuedPick()?.meta.id, "first")
        XCTAssertEqual(pool.nextQueuedPick()?.meta.id, "second")
        XCTAssertNil(pool.nextQueuedPick())
    }
}
