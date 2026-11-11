import XCTest
@testable import NuvioTV

final class IPTVSourceStoreTests: XCTestCase {
    private final class MemoryStorage: IPTVSourceStorage {
        var data: [String: Data] = [:]
        var shouldFail = false
        func read(profileID: String) throws -> Data? { data[profileID] }
        func write(_ value: Data, profileID: String) throws {
            if shouldFail { throw IPTVSourceStoreError.invalidSource }
            data[profileID] = value
        }
        func remove(profileID: String) throws {
            if shouldFail { throw IPTVSourceStoreError.invalidSource }
            data.removeValue(forKey: profileID)
        }
    }

    func testSourcesRemainScopedAndCanBeRemoved() throws {
        let backend = MemoryStorage()
        let store = IPTVSourceStore(storage: backend)
        let source = IPTVSource(id: UUID(), name: "News", playlistURL: "https://example.test/list?token=fixture")
        try store.save([source], profileID: "one")
        XCTAssertEqual(try store.load(profileID: "one"), [source])
        XCTAssertTrue(try store.load(profileID: "two").isEmpty)
        try store.save([], profileID: "one")
        XCTAssertTrue(try store.load(profileID: "one").isEmpty)
    }

    func testInvalidInputAndWriteFailureDoNotReplacePreviousSource() throws {
        let backend = MemoryStorage()
        let store = IPTVSourceStore(storage: backend)
        let source = IPTVSource(id: UUID(), name: "News", playlistURL: "https://example.test/list")
        try store.save([source], profileID: "one")
        XCTAssertThrowsError(try store.save([source, source], profileID: "one"))
        XCTAssertThrowsError(try store.save([IPTVSource(id: UUID(), name: "Bad", playlistURL: "file:///tmp/list")], profileID: "one"))
        backend.shouldFail = true
        XCTAssertThrowsError(try store.save([], profileID: "one"))
        XCTAssertEqual(try store.load(profileID: "one"), [source])
    }

    func testReadsEarlierM3UFormatAndStoresXtreamCredentialsSeparatelyByProfile() throws {
        let backend = MemoryStorage()
        let store = IPTVSourceStore(storage: backend)
        let id = UUID()
        backend.data["old"] = Data("[{\"id\":\"\(id.uuidString)\",\"name\":\"News\",\"playlistURL\":\"https://example.test/list\"}]".utf8)
        XCTAssertEqual(try store.load(profileID: "old").first?.kind, .m3u)
        XCTAssertEqual(try store.load(profileID: "old").first?.xtreamOutput, .mpegTS)
        let source = IPTVSource(id: UUID(), name: "Live", playlistURL: "https://example.test:8443", kind: .xtream, username: "test-user", password: "test-password")
        try store.save([source], profileID: "one")
        XCTAssertEqual(try store.load(profileID: "one"), [source])
        XCTAssertTrue(try store.load(profileID: "two").isEmpty)
        var incomplete = source
        incomplete.password = nil
        XCTAssertThrowsError(try store.save([incomplete], profileID: "one"))
        XCTAssertEqual(try store.load(profileID: "one"), [source])
    }

    func testXtreamFormatPersists() throws {
        let backend = MemoryStorage()
        let store = IPTVSourceStore(storage: backend)
        let source = IPTVSource(id: UUID(), name: "HLS", playlistURL: "https://example.test", kind: .xtream, username: "user", password: "pass", xtreamOutput: .hls)
        try store.save([source], profileID: "one")
        XCTAssertEqual(try store.load(profileID: "one").first?.xtreamOutput, .hls)
    }

    func testStalkerRequiresMACAndExplicitValidPortal() throws {
        let backend = MemoryStorage()
        let store = IPTVSourceStore(storage: backend)
        let source = IPTVSource(id: UUID(), name: "Portal", playlistURL: "https://example.test/server/load.php", kind: .stalker, mac: "00:1A:79:01:02:03")
        try store.save([source], profileID: "one")
        XCTAssertEqual(try store.load(profileID: "one"), [source])
        var invalid = source
        invalid.mac = "invalid"
        XCTAssertThrowsError(try store.save([invalid], profileID: "one"))
        XCTAssertEqual(try store.load(profileID: "one"), [source])
    }

    func testEditingSourceKeepsIdentityAndFailedWriteKeepsOldValue() throws {
        let backend = MemoryStorage()
        let store = IPTVSourceStore(storage: backend)
        let original = IPTVSource(id: UUID(), name: "Live", playlistURL: "https://example.test/list")
        try store.save([original], profileID: "one")
        var edited = original
        edited.playlistURL = "https://example.test/new-list"
        backend.shouldFail = true
        XCTAssertThrowsError(try store.save([edited], profileID: "one"))
        XCTAssertEqual(try store.load(profileID: "one"), [original])
        backend.shouldFail = false
        try store.save([edited], profileID: "one")
        XCTAssertEqual(try store.load(profileID: "one").first?.id, original.id)
        XCTAssertEqual(try store.load(profileID: "one").first?.playlistURL, edited.playlistURL)
    }
}
