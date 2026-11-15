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
}
