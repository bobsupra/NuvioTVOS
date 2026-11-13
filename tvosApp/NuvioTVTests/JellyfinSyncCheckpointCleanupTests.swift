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
}
