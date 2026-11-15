import XCTest
@testable import NuvioTV

/// Interrupted Jellyfin syncs keep the server's library listing in checkpoint pages; sign-out
/// must not leave them on the device for the next account.
final class JellyfinSyncCheckpointCleanupTests: XCTestCase {
    private let directory = "jellyfinSyncCheckpoints"

    func testEraseAllRemovesLeftoverCheckpointFiles() {
        let key = "jellyfinSyncPage.test-\(UUID().uuidString)"
        XCTAssertTrue(LargePayloadStore.write(Data("listing".utf8), key: key, directory: directory))
        XCTAssertNotNil(LargePayloadStore.read(key: key, directory: directory))

        JellyfinSyncCheckpoints.eraseAll()

        XCTAssertNil(LargePayloadStore.read(key: key, directory: directory))
    }

    func testRemovingAServerWithoutACheckpointIsHarmless() {
        JellyfinSyncCheckpoints.remove(profileID: "profile-\(UUID().uuidString)", serverID: UUID().uuidString)
    }

    private func page(_ profileID: String, _ serverID: String) -> String {
        JellyfinSyncCheckpoints.pageKey(
            profileID: profileID, serverID: serverID, runID: "run", entity: "movies", startIndex: 0
        )
    }

    private func write(_ key: String) {
        XCTAssertTrue(LargePayloadStore.write(Data("listing".utf8), key: key, directory: directory))
    }

    private func exists(_ key: String) -> Bool {
        LargePayloadStore.read(key: key, directory: directory) != nil
    }

    func testRemovingAServerDeletesPagesItsCheckpointNeverListed() {
        // The app stopped after writing a page but before saving the checkpoint.
        let profile = "profile-\(UUID().uuidString)", otherProfile = "profile-\(UUID().uuidString)"
        let server = UUID().uuidString, otherServer = UUID().uuidString
        let orphan = page(profile, server)
        let sameProfileOtherServer = page(profile, otherServer)
        let otherProfileSameServer = page(otherProfile, server)
        [orphan, sameProfileOtherServer, otherProfileSameServer].forEach(write)

        JellyfinSyncCheckpoints.remove(profileID: profile, serverID: server)

        XCTAssertFalse(exists(orphan))
        XCTAssertTrue(exists(sameProfileOtherServer))
        XCTAssertTrue(exists(otherProfileSameServer))
        JellyfinSyncCheckpoints.remove(profileID: profile, serverID: otherServer)
        JellyfinSyncCheckpoints.remove(profileID: otherProfile, serverID: server)
        XCTAssertFalse(exists(sameProfileOtherServer))
        XCTAssertFalse(exists(otherProfileSameServer))
    }

    func testRemovingAServerWithAnUnreadableCheckpointDeletesItsPages() {
        let profile = "profile-\(UUID().uuidString)", server = UUID().uuidString
        let checkpoint = JellyfinSyncCheckpoints.checkpointKey(profileID: profile, serverID: server)
        XCTAssertTrue(LargePayloadStore.write(Data("not json".utf8), key: checkpoint, directory: directory))
        let listing = page(profile, server)
        write(listing)

        JellyfinSyncCheckpoints.remove(profileID: profile, serverID: server)

        XCTAssertFalse(exists(checkpoint))
        XCTAssertFalse(exists(listing))
    }

    func testPagesInTheOldUnattributableFormatAreRemoved() {
        // Before pages carried their profile and server; nothing reads these now.
        let legacy = "jellyfinSyncPage." + String(repeating: "ab", count: 32)
        let current = page("profile-\(UUID().uuidString)", UUID().uuidString)
        write(legacy)
        write(current)

        JellyfinSyncCheckpoints.remove(profileID: "profile-\(UUID().uuidString)", serverID: UUID().uuidString)

        XCTAssertFalse(exists(legacy))
        XCTAssertTrue(exists(current))
        LargePayloadStore.remove(key: current, directory: directory)
    }

    func testStoredKeysCanBeListed() {
        let key = "jellyfinSyncPage.v2.test/\(UUID().uuidString)+=?"
        write(key)
        XCTAssertTrue(LargePayloadStore.keys(directory: directory).contains(key))
        LargePayloadStore.remove(key: key, directory: directory)
        XCTAssertFalse(LargePayloadStore.keys(directory: directory).contains(key))
    }

    // MARK: Resuming a sync

    private func items(_ ids: [String]) throws -> [JellyfinMediaItem] {
        let json = "[" + ids.map { #"{"id":"\#($0)","name":"\#($0)","type":"Movie"}"# }.joined(separator: ",") + "]"
        return try JSONDecoder().decode([JellyfinMediaItem].self, from: Data(json.utf8))
    }

    private func identity(_ profile: String, _ server: String, libraries: [String] = ["movies"]) -> JellyfinSyncCheckpoint.Identity {
        .init(profileID: profile, serverID: server, baseURL: "http://jellyfin.local", userID: "user", selectedLibraryIDs: libraries)
    }

    func testResumingKeepsListedPagesAndRemovesUnlistedOnes() throws {
        let profile = "profile-\(UUID().uuidString)", server = UUID().uuidString, otherServer = UUID().uuidString
        let first = try JellyfinSyncCheckpointStore(identity: identity(profile, server))
        _ = try first.record(JellyfinItemsPage(items: try items(["a", "b"]), startIndex: 0, nextStartIndex: 2, totalRecordCount: 3), for: "movies")
        _ = try first.record(JellyfinItemsPage(items: try items(["c"]), startIndex: 2, nextStartIndex: 3, totalRecordCount: 3), for: "movies")

        // Left by a run that stopped before listing it, and another server's page.
        let unlisted = JellyfinSyncCheckpoints.pageKey(
            profileID: profile, serverID: server, runID: "interrupted-run", entity: "movies", startIndex: 0
        )
        let otherServersPage = page(profile, otherServer)
        write(unlisted)
        write(otherServersPage)

        // The app restarts and the same sync resumes.
        let resumed = try JellyfinSyncCheckpointStore(identity: identity(profile, server))
        XCTAssertEqual(try resumed.items(for: "movies").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(resumed.nextStartIndex(for: "movies"), 3)
        XCTAssertFalse(exists(unlisted))
        XCTAssertTrue(exists(otherServersPage))

        resumed.remove()
        JellyfinSyncCheckpoints.remove(profileID: profile, serverID: otherServer)
        XCTAssertFalse(exists(JellyfinSyncCheckpoints.checkpointKey(profileID: profile, serverID: server)))
    }

    func testANewRunForTheSameServerStartsWithoutTheOldPages() throws {
        let profile = "profile-\(UUID().uuidString)", server = UUID().uuidString
        let first = try JellyfinSyncCheckpointStore(identity: identity(profile, server))
        _ = try first.record(JellyfinItemsPage(items: try items(["a"]), startIndex: 0, nextStartIndex: 1, totalRecordCount: 1), for: "movies")

        // Different libraries selected: a new run, not a resume.
        let fresh = try JellyfinSyncCheckpointStore(identity: identity(profile, server, libraries: ["shows"]))
        XCTAssertEqual(try fresh.items(for: "movies"), [])
        XCTAssertEqual(fresh.nextStartIndex(for: "movies"), 0)
        let prefix = JellyfinSyncCheckpointStore.pagePrefix(
            forKey: JellyfinSyncCheckpoints.checkpointKey(profileID: profile, serverID: server)
        )
        XCTAssertTrue(LargePayloadStore.keys(directory: directory).filter { $0.hasPrefix(prefix) }.isEmpty)
        fresh.remove()
    }
}
