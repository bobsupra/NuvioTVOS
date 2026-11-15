import XCTest
@testable import NuvioTV

/// IPTV sources (with their credentials) are kept per profile id, and profile ids are reused.
/// Deleting a profile, here or on another device, must take its sources along, leave every
/// other profile's alone, and stop a save still pending for it.
final class IPTVProfileCleanupTests: XCTestCase {
    private final class MemoryStorage: IPTVSourceStorage {
        var data: [String: Data] = [:]
        func read(profileID: String) throws -> Data? { data[profileID] }
        func write(_ value: Data, profileID: String) throws { data[profileID] = value }
        func remove(profileID: String) throws { data.removeValue(forKey: profileID) }
    }

    private var savedStorage: (any IPTVSourceStorage)!
    private var backend = MemoryStorage()
    private var removed = ""
    private var kept = ""
    private var directory: URL!
    private var previousActive: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedStorage = IPTVSourceStore.defaultStorage
        backend = MemoryStorage()
        IPTVSourceStore.defaultStorage = backend
        removed = "iptv-removed-\(UUID().uuidString)"
        kept = "iptv-kept-\(UUID().uuidString)"
        previousActive = UserDefaults.standard.string(forKey: "nuvio.active_profile_id")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("iptv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Written before the manager starts, so no stored profiles are migrated or touched.
        let profiles = [Profile(id: removed, name: "A"), Profile(id: kept, name: "B")]
        try JSONEncoder().encode(profiles.map(StoredProfile.init(from:)))
            .write(to: directory.appendingPathComponent("nuvio-profiles.json"))
    }

    override func tearDown() {
        IPTVSourceStore.defaultStorage = savedStorage
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.set(previousActive, forKey: "nuvio.active_profile_id")
        for id in [removed, kept] {
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)")
        }
        super.tearDown()
    }

    private func source(_ name: String) -> IPTVSource {
        IPTVSource(id: UUID(), name: name, playlistURL: "https://example.test/\(name)?token=secret")
    }

    /// Both profiles with a source, a favourite and a last channel.
    private func seed() throws -> (removedSource: IPTVSource, keptSource: IPTVSource) {
        let store = IPTVSourceStore()
        let removedSource = source("removed"), keptSource = source("kept")
        try store.save([removedSource], profileID: removed)
        try store.save([keptSource], profileID: kept)
        for (id, src) in [(removed, removedSource), (kept, keptSource)] {
            let defaults = ProfileSettings.store(for: id)
            let key = IPTVFavoritesStore.key(sourceID: src.id, channelID: "channel")
            IPTVFavoritesStore(defaults: defaults).save([key])
            IPTVRecentChannelStore(defaults: defaults).save(key)
        }
        return (removedSource, keptSource)
    }

    private func assertRemovedProfileIsEmptyAndKeptOneIntact(_ keptSource: IPTVSource,
                                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let store = IPTVSourceStore()
        XCTAssertEqual(try store.load(profileID: removed), [], "a reused id must not inherit the sources", file: file, line: line)
        XCTAssertTrue(IPTVFavoritesStore(defaults: ProfileSettings.store(for: removed)).load().isEmpty, file: file, line: line)
        XCTAssertNil(IPTVRecentChannelStore(defaults: ProfileSettings.store(for: removed)).load(), file: file, line: line)

        XCTAssertEqual(try store.load(profileID: kept), [keptSource], file: file, line: line)
        XCTAssertEqual(IPTVFavoritesStore(defaults: ProfileSettings.store(for: kept)).load().count, 1, file: file, line: line)
        XCTAssertNotNil(IPTVRecentChannelStore(defaults: ProfileSettings.store(for: kept)).load(), file: file, line: line)
    }

    func testAProfileRemovedBySyncTakesItsIPTVSourcesAlong() throws {
        let (_, keptSource) = try seed()
        let manager = try ProfileManager(baseDir: directory.path)

        // Deleted on another device: the next sync replaces the list without it.
        try manager.replaceProfiles([Profile(id: kept, name: "B")])

        try assertRemovedProfileIsEmptyAndKeptOneIntact(keptSource)
    }

    func testDeletingAProfileTakesItsIPTVSourcesAlong() throws {
        let (_, keptSource) = try seed()
        let manager = try ProfileManager(baseDir: directory.path)

        try manager.deleteProfile(id: removed)

        try assertRemovedProfileIsEmptyAndKeptOneIntact(keptSource)
    }

    func testABrandNewProfileCanSaveItsFirstSource() throws {
        // Nothing was ever saved or removed for this profile id.
        let fresh = "iptv-fresh-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(fresh)") }
        let generation = IPTVSourceStore.generation(for: fresh)
        XCTAssertEqual(generation, 0)

        let first = source("first")
        XCTAssertTrue(try IPTVSourceStore().save([first], profileID: fresh, ifGeneration: generation))
        XCTAssertEqual(try IPTVSourceStore().load(profileID: fresh), [first])
    }

    func testAGenerationCapturedBeforeDeletionIsRejectedForANewProfile() throws {
        let fresh = "iptv-fresh-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(fresh)") }
        let beforeDeletion = IPTVSourceStore.generation(for: fresh)
        IPTVSourceStore.removeProfile(fresh)
        XCTAssertFalse(try IPTVSourceStore().save([source("late")], profileID: fresh, ifGeneration: beforeDeletion))
        XCTAssertEqual(try IPTVSourceStore().load(profileID: fresh), [])
        // A load started after the deletion saves normally.
        let afterDeletion = IPTVSourceStore.generation(for: fresh)
        XCTAssertTrue(try IPTVSourceStore().save([source("new")], profileID: fresh, ifGeneration: afterDeletion))
    }

    func testASavePendingWhenTheProfileIsDeletedSavesNothing() throws {
        let (_, keptSource) = try seed()
        let store = IPTVSourceStore()
        // A playlist load started on each profile, saving its source when it finishes.
        let removedGeneration = IPTVSourceStore.generation(for: removed)
        let keptGeneration = IPTVSourceStore.generation(for: kept)

        IPTVSourceStore.removeProfile(removed)

        XCTAssertFalse(try store.save([source("late")], profileID: removed, ifGeneration: removedGeneration))
        XCTAssertEqual(try store.load(profileID: removed), [])
        let added = source("added")
        XCTAssertTrue(try store.save([keptSource, added], profileID: kept, ifGeneration: keptGeneration))
        XCTAssertEqual(try store.load(profileID: kept), [keptSource, added])
    }
}
