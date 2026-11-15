import XCTest

@MainActor
final class IPTVRetirementCoordinatorTests: XCTestCase {
    enum Failure: Error { case read, write, delete, commit }

    final class Storage: IPTVRetirementStorage {
        var profiles: Set<String> = ["A", "B"]
        var sources: Set<String> = ["A", "B"]
        var pending: Set<String> = []
        var failRead = false
        var failJournal = false
        var failDelete = false
        func loadPending() throws -> Set<String> { pending }
        func savePendingDurably(_ ids: Set<String>) throws {
            if failJournal { throw Failure.write }
            pending = ids
        }
        func loadProfileIDsAuthoritatively() throws -> Set<String> {
            if failRead { throw Failure.read }
            return profiles
        }
        func deleteIPTVSources(profileID: String) throws {
            if failDelete { throw Failure.delete }
            sources.remove(profileID)
        }
    }

    func testFailedCommitKeepsOriginalSourcesOnRecovery() throws {
        let store = Storage()
        let coordinator = IPTVRetirementCoordinator(storage: store)
        XCTAssertThrowsError(try coordinator.retire(["A"]) { throw Failure.commit })
        XCTAssertEqual(store.pending, ["A"])
        try coordinator.recover()
        XCTAssertEqual(store.sources, ["A", "B"])
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testRecoveryFinishesCommittedDeletionAndKeepsOtherProfile() throws {
        let store = Storage()
        store.pending = ["A"]
        store.profiles.remove("A") // process ended after the profile commit
        try IPTVRetirementCoordinator(storage: store).recover()
        XCTAssertEqual(store.sources, ["B"])
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testUnreadableProfilesAndFailedDeleteKeepJournal() throws {
        let store = Storage()
        store.pending = ["A"]
        store.failRead = true
        let coordinator = IPTVRetirementCoordinator(storage: store)
        XCTAssertThrowsError(try coordinator.recover())
        XCTAssertEqual(store.pending, ["A"])
        store.failRead = false
        store.profiles.remove("A")
        store.failDelete = true
        XCTAssertThrowsError(try coordinator.recover())
        XCTAssertEqual(store.pending, ["A"])
        XCTAssertEqual(store.sources, ["A", "B"])
    }

    func testFailedJournalStopsProfileCommit() throws {
        let store = Storage()
        store.failJournal = true
        XCTAssertThrowsError(try IPTVRetirementCoordinator(storage: store).retire(["A"]) {
            store.profiles.remove("A")
        })
        XCTAssertTrue(store.profiles.contains("A"))
        XCTAssertEqual(store.sources, ["A", "B"])
    }
}
