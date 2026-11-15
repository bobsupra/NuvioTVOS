import XCTest
@testable import NuvioTV

@MainActor
final class TrackingAddonLibraryChangesTests: XCTestCase {
    private var savedReport: ((Bool, NuvioMeta, String?) -> Void)!
    private var reported: [String] = []
    private var reportedProfiles: [String?] = []
    /// Stands in for the active profile and library account.
    private var activeOwner = "a"

    private func owner(_ profile: String) -> TrackingAddonLibraryChanges.Owner {
        .init(profileID: profile, isCurrent: { [unowned self] in self.activeOwner == profile })
    }

    override func setUp() async throws {
        try await super.setUp()
        savedReport = TrackingAddonLibraryChanges.report
        reported = []
        reportedProfiles = []
        activeOwner = "a"
        TrackingAddonLibraryChanges.report = { [weak self] isInLibrary, meta, profileID in
            self?.reported.append("\(isInLibrary ? "add" : "remove") \(meta.id)")
            self?.reportedProfiles.append(profileID)
        }
    }

    override func tearDown() async throws {
        TrackingAddonLibraryChanges.report = savedReport
        try await super.tearDown()
    }

    private func title(_ id: String) -> NuvioMeta { NuvioMeta(id: "\(id)-\(UUID().uuidString)", name: id, type: "movie") }

    func testOnlyAConfirmedChangeIsReported() async {
        let meta = title("tt1")
        var results: [Bool] = []
        await TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: { false }, completion: { results.append($0) }).value
        XCTAssertEqual(reported, [], "a failed add must not reach tracking add-ons")
        await TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: { true }, completion: { results.append($0) }).value
        XCTAssertEqual(reported, ["add \(meta.id)"])
        XCTAssertEqual(results, [false, true])
    }

    func testRapidChangesToOneTitleAreConfirmedAndReportedInOrder() async {
        let meta = title("tt2")
        var ran: [String] = []
        // The add is slow and the remove fast; the remove still waits for the add.
        TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: {
            try? await Task.sleep(nanoseconds: 200_000_000)
            ran.append("add")
            return true
        })
        let last = TrackingAddonLibraryChanges.perform(false, meta: meta, owner: owner("a"), mutation: {
            ran.append("remove")
            return true
        })
        await last.value
        XCTAssertEqual(ran, ["add", "remove"])
        XCTAssertEqual(reported, ["add \(meta.id)", "remove \(meta.id)"])
    }

    func testAFailedChangeInTheMiddleIsLeftOut() async {
        let meta = title("tt3")
        TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: { true })
        TrackingAddonLibraryChanges.perform(false, meta: meta, owner: owner("a"), mutation: { false })
        await TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: { true }).value
        XCTAssertEqual(reported, ["add \(meta.id)", "add \(meta.id)"])
    }

    func testAChangeCancelledBeforeItRunsDoesNothing() async {
        let meta = title("tt4")
        var ran = 0
        let first = TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return true
        })
        var cancelledResult: Bool?
        let second = TrackingAddonLibraryChanges.perform(false, meta: meta, owner: owner("a"), mutation: {
            ran += 1
            return true
        }, completion: { cancelledResult = $0 })
        second.cancel()
        await first.value
        await second.value
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(cancelledResult, false)
        XCTAssertEqual(reported, ["add \(meta.id)"])
    }

    func testDifferentTitlesDoNotWaitForEachOther() async {
        let slow = title("slow"), fast = title("fast")
        let gate = expectation(description: "slow may finish")
        let slowTask = TrackingAddonLibraryChanges.perform(true, meta: slow, owner: owner("a"), mutation: {
            await self.fulfillment(of: [gate], timeout: 2)
            return true
        })
        await TrackingAddonLibraryChanges.perform(true, meta: fast, owner: owner("a"), mutation: { true }).value
        XCTAssertEqual(reported, ["add \(fast.id)"])
        gate.fulfill()
        await slowTask.value
        XCTAssertEqual(reported, ["add \(fast.id)", "add \(slow.id)"])
    }

    // MARK: Profile and account ownership

    func testAChangeQueuedBeforeAProfileSwitchNeverRuns() async {
        let meta = title("tt5")
        let started = expectation(description: "first change started")
        let gate = expectation(description: "first change may finish")
        let first = TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: {
            started.fulfill()
            await self.fulfillment(of: [gate], timeout: 2)
            return true
        })
        var ranForA = 0
        var result: Bool?
        let queued = TrackingAddonLibraryChanges.perform(false, meta: meta, owner: owner("a"), mutation: {
            ranForA += 1
            return true
        }, completion: { result = $0 })

        await fulfillment(of: [started], timeout: 2)
        // The user switches to B (or logs out, or relinks) while it waits its turn.
        activeOwner = "b"
        gate.fulfill()
        await first.value
        await queued.value

        XCTAssertEqual(ranForA, 0, "must not run against B's library account")
        XCTAssertEqual(result, false)
        XCTAssertEqual(reported, ["add \(meta.id)"])
        XCTAssertEqual(reportedProfiles, ["a"])
    }

    func testAChangeInFlightDuringASwitchIsReportedForItsOwnProfile() async {
        let meta = title("tt6")
        let started = expectation(description: "request in flight")
        let gate = expectation(description: "service answers")
        let change = TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: {
            started.fulfill()
            await self.fulfillment(of: [gate], timeout: 2)
            return true
        })
        await fulfillment(of: [started], timeout: 2)
        activeOwner = "b"
        gate.fulfill()
        await change.value

        // A's library did change, so A's tracking add-ons hear of it, with A's consent.
        XCTAssertEqual(reported, ["add \(meta.id)"])
        XCTAssertEqual(reportedProfiles, ["a"])
    }

    func testAChangeWhoseOwnerIsNoLongerCurrentAtTheStartDoesNothing() async {
        let meta = title("tt7")
        activeOwner = "b"
        var ran = false
        await TrackingAddonLibraryChanges.perform(true, meta: meta, owner: owner("a"), mutation: {
            ran = true
            return true
        }).value
        XCTAssertFalse(ran)
        XCTAssertEqual(reported, [])
    }
}

