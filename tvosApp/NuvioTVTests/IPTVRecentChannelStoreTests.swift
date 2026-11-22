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

    func testLegacyStringLoadsAndMigratesOnRecord() throws {
        let domain = "iptv-recent-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = IPTVRecentChannelStore(defaults: defaults)
        let first = IPTVFavoritesStore.key(sourceID: UUID(), channelID: "one")
        let second = IPTVFavoritesStore.key(sourceID: UUID(), channelID: "two")
        defaults.set(first, forKey: "nuvio.tv.iptv.recentChannel.v1")
        XCTAssertEqual(store.loadAll(), [first])
        store.save(second)
        XCTAssertEqual(store.loadAll(), [second, first])
    }

    func testHistoryIsNewestFirstDeduplicatedAndCapped() throws {
        let domain = "iptv-recent-order-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = IPTVRecentChannelStore(defaults: defaults)
        let keys = (0..<34).map { IPTVFavoritesStore.key(sourceID: UUID(), channelID: "channel-\($0)") }
        for key in keys { store.save(key) }
        store.save(keys[33])
        XCTAssertEqual(store.loadAll().count, 32)
        XCTAssertEqual(store.loadAll().first, keys[33])
        XCTAssertFalse(store.loadAll().contains(keys[0]))
    }

    func testRemovingSourceRetainsOtherSourceHistory() throws {
        let domain = "iptv-recent-removal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = IPTVRecentChannelStore(defaults: defaults)
        let removedSource = UUID()
        let keptSource = UUID()
        let kept = IPTVFavoritesStore.key(sourceID: keptSource, channelID: "kept")
        store.save(kept)
        store.save(IPTVFavoritesStore.key(sourceID: removedSource, channelID: "removed"))
        store.removeIfOwned(by: removedSource)
        XCTAssertEqual(store.loadAll(), [kept])
    }
}
