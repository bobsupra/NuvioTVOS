import XCTest
@testable import NuvioTV

@MainActor
final class TrackingAddonLibraryChangesTests: XCTestCase {
    private var savedReport: ((Bool, NuvioMeta) -> Void)!
    private var reported: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        savedReport = TrackingAddonLibraryChanges.report
        reported = []
        TrackingAddonLibraryChanges.report = { [weak self] isInLibrary, meta in
            self?.reported.append("\(isInLibrary ? "add" : "remove") \(meta.id)")
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
        await TrackingAddonLibraryChanges.perform(true, meta: meta, mutation: { false }, completion: { results.append($0) }).value
        XCTAssertEqual(reported, [], "a failed add must not reach tracking add-ons")
        await TrackingAddonLibraryChanges.perform(true, meta: meta, mutation: { true }, completion: { results.append($0) }).value
        XCTAssertEqual(reported, ["add \(meta.id)"])
        XCTAssertEqual(results, [false, true])
    }

    func testRapidChangesToOneTitleAreConfirmedAndReportedInOrder() async {
        let meta = title("tt2")
        var ran: [String] = []
        // The add is slow and the remove fast; the remove still waits for the add.
        TrackingAddonLibraryChanges.perform(true, meta: meta, mutation: {
            try? await Task.sleep(nanoseconds: 200_000_000)
            ran.append("add")
            return true
        })
        let last = TrackingAddonLibraryChanges.perform(false, meta: meta, mutation: {
            ran.append("remove")
            return true
        })
        await last.value
        XCTAssertEqual(ran, ["add", "remove"])
        XCTAssertEqual(reported, ["add \(meta.id)", "remove \(meta.id)"])
    }

    func testAFailedChangeInTheMiddleIsLeftOut() async {
        let meta = title("tt3")
        TrackingAddonLibraryChanges.perform(true, meta: meta, mutation: { true })
        TrackingAddonLibraryChanges.perform(false, meta: meta, mutation: { false })
        await TrackingAddonLibraryChanges.perform(true, meta: meta, mutation: { true }).value
        XCTAssertEqual(reported, ["add \(meta.id)", "add \(meta.id)"])
    }

    func testAChangeCancelledBeforeItRunsDoesNothing() async {
        let meta = title("tt4")
        var ran = 0
        let first = TrackingAddonLibraryChanges.perform(true, meta: meta, mutation: {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return true
        })
        var cancelledResult: Bool?
        let second = TrackingAddonLibraryChanges.perform(false, meta: meta, mutation: {
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
        let slowTask = TrackingAddonLibraryChanges.perform(true, meta: slow, mutation: {
            await self.fulfillment(of: [gate], timeout: 2)
            return true
        })
        await TrackingAddonLibraryChanges.perform(true, meta: fast, mutation: { true }).value
        XCTAssertEqual(reported, ["add \(fast.id)"])
        gate.fulfill()
        await slowTask.value
        XCTAssertEqual(reported, ["add \(fast.id)", "add \(slow.id)"])
    }
}
