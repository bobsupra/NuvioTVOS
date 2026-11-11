import XCTest
@testable import NuvioTV

final class IPTVRecentChannelStoreTests: XCTestCase {
    func testRecentChannelIsScopedAndRemovedOnlyWithItsSource() throws {
        let domain = "iptv-recent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = IPTVRecentChannelStore(defaults: defaults)
        let source = UUID()
        let key = IPTVFavoritesStore.key(sourceID: source, channelID: "https://example.test/live?token=secret")
        store.save(key)
        XCTAssertEqual(store.sourceID(), source)
        XCTAssertFalse(try XCTUnwrap(store.load()).contains("secret"))
        store.removeIfOwned(by: UUID())
        XCTAssertEqual(store.load(), key)
        store.removeIfOwned(by: source)
        XCTAssertNil(store.load())
        store.save("malformed")
        XCTAssertNil(store.sourceID())
    }
}
