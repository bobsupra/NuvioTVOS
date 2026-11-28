import XCTest
@testable import NuvioTV

final class SceneModelCacheCleanupTests: XCTestCase {
    private var caches: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        caches = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneModelCacheCleanupTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "SceneModelCacheCleanupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: caches)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var root: URL { caches.appendingPathComponent(SceneModelCacheCleanup.folderName, isDirectory: true) }

    private func addCompiledModel(_ name: String) throws {
        let entry = root.appendingPathComponent("24K157/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: entry.appendingPathComponent("bnns_program.bnnsir"))
    }

    private func clean(installPath: String) -> Int {
        SceneModelCacheCleanup.removeCopiesFromEarlierInstalls(caches: caches, installPath: installPath, defaults: defaults)
    }

    func testCopiesFromAnEarlierInstallAreRemovedOnTheFirstLoad() throws {
        try addCompiledModel("FROM-EARLIER-INSTALL")

        XCTAssertGreaterThan(clean(installPath: "/Install-A/NuvioTV.app"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCopiesMadeByThisInstallAreKept() throws {
        _ = clean(installPath: "/Install-A/NuvioTV.app")
        try addCompiledModel("FROM-THIS-INSTALL")

        XCTAssertEqual(clean(installPath: "/Install-A/NuvioTV.app"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testTheNextInstallRemovesThePreviousOnesCopies() throws {
        _ = clean(installPath: "/Install-A/NuvioTV.app")
        try addCompiledModel("FROM-INSTALL-A")

        XCTAssertGreaterThan(clean(installPath: "/Install-B/NuvioTV.app"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNothingToRemoveIsFine() {
        XCTAssertEqual(clean(installPath: "/Install-A/NuvioTV.app"), 0)
    }
}
