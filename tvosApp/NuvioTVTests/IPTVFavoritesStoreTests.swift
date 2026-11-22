import XCTest
@testable import NuvioTV

final class IPTVFavoritesStoreTests: XCTestCase {
    func testFavoritesAreScopedAndDoNotExposeChannelIdentifiers() throws {
        let suiteOne = "iptv-favorites-\(UUID().uuidString)"
        let suiteTwo = "iptv-favorites-\(UUID().uuidString)"
        let one = try XCTUnwrap(UserDefaults(suiteName: suiteOne))
        let two = try XCTUnwrap(UserDefaults(suiteName: suiteTwo))
        defer { one.removePersistentDomain(forName: suiteOne); two.removePersistentDomain(forName: suiteTwo) }
        let source = UUID()
        let other = UUID()
        let key = IPTVFavoritesStore.key(sourceID: source, channelID: "https://example.test/live?token=secret")
        let otherKey = IPTVFavoritesStore.key(sourceID: other, channelID: "channel")
        XCTAssertFalse(key.contains("secret"))
        IPTVFavoritesStore(defaults: one).save([key, otherKey])
        XCTAssertTrue(IPTVFavoritesStore(defaults: two).load().isEmpty)
        XCTAssertEqual(IPTVFavoritesStore.removingSource(source, from: IPTVFavoritesStore(defaults: one).load()), [otherKey])
    }

    func testFavoriteOrderPersistsAndReconcilesLegacyPlaylistOrder() throws {
        let suite = "iptv-favorite-order-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IPTVFavoritesStore(defaults: defaults)
        let favorites: Set<String> = ["legacy-a", "legacy-b", "moved", "stale"]
        store.saveOrder(["stale", "moved"])

        let reconciled = store.reconciledOrder(store.loadOrder(), playlistOrder: ["legacy-b", "legacy-a"], favorites: favorites)
        XCTAssertEqual(reconciled, ["stale", "moved", "legacy-b", "legacy-a"])
        store.saveOrder(reconciled)
        XCTAssertEqual(store.loadOrder(), reconciled)
        XCTAssertEqual(store.reconciledOrder(reconciled, playlistOrder: [], favorites: ["moved", "legacy-a"]), ["moved", "legacy-a"])
    }

    func testLegacyOrderBuildsInPlaylistOrderAsSourcesLoadAndSurvivesReload() throws {
        let suite = "iptv-favorite-sources-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IPTVFavoritesStore(defaults: defaults)
        let favorites: Set<String> = ["source-a-2", "source-a-1", "source-b-2", "source-b-1"]

        var order = store.reconciledOrder([], playlistOrder: ["source-a-2", "source-a-1"], favorites: favorites)
        store.saveOrder(order)
        XCTAssertEqual(order, ["source-a-2", "source-a-1"])

        order = store.reconciledOrder(store.loadOrder(), playlistOrder: ["source-b-2", "source-b-1"], favorites: favorites)
        store.saveOrder(order)
        XCTAssertEqual(store.loadOrder(), ["source-a-2", "source-a-1", "source-b-2", "source-b-1"])
        XCTAssertEqual(store.reconciledOrder(store.loadOrder(), playlistOrder: [], favorites: favorites), store.loadOrder())
    }

    func testDuplicatePersistedOrderKeysAreDeduplicated() throws {
        let suite = "iptv-favorite-duplicates-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["same", "same", "other"], forKey: "nuvio.tv.iptv.favorites.order.v1")
        XCTAssertEqual(IPTVFavoritesStore(defaults: defaults).loadOrder(), ["same", "other"])
    }
}
