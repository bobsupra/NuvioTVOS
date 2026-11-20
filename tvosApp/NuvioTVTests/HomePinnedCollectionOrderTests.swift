import XCTest
@testable import NuvioTV

/// Pinned collections stay above every other Home row, and follow the saved
/// Home order among themselves rather than the order of the collections list.
final class HomePinnedCollectionOrderTests: XCTestCase {
    private var savedLocalOrder: Data?
    private var savedSyncedOrder: Data?

    override func setUp() {
        super.setUp()
        savedLocalOrder = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogOrder)
        savedSyncedOrder = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogSyncedOrder)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogOrder)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogSyncedOrder)
    }

    override func tearDown() {
        restore(savedLocalOrder, forKey: SettingsKey.homeCatalogOrder)
        restore(savedSyncedOrder, forKey: SettingsKey.homeCatalogSyncedOrder)
        super.tearDown()
    }

    private func restore(_ data: Data?, forKey key: String) {
        if let data {
            _ = HomeCatalogPayloadStore.write(data, forKey: key)
        } else {
            HomeCatalogPayloadStore.remove(forKey: key)
        }
    }

    private func store(_ keys: [String], forKey key: String) {
        _ = HomeCatalogPayloadStore.write(try! JSONEncoder().encode(keys), forKey: key)
    }

    private func collection(_ id: String, pinned: Bool) -> TVHomeSection {
        TVHomeSection(id: "\(TVHomeSection.collectionIdPrefix)\(id)", title: id, items: [], isPinnedCollection: pinned)
    }

    private let movies = TVHomeSection(id: "movies", title: "Movies", items: [])

    private func orderedIDs(_ sections: [TVHomeSection]) -> [String] {
        TVHomeCatalogOrder.applyKeepingPinnedCollectionsFirst(to: sections).map(\.id)
    }

    func testPinnedCollectionsFollowTheSavedOrderAmongThemselves() {
        // The collections list has Spotlight first; the saved Home order puts it
        // after Reality TV, with a catalog between them.
        store(["collection_reality", "movies", "collection_spotlight", "collection_kids"], forKey: SettingsKey.homeCatalogOrder)
        let ids = orderedIDs([
            collection("spotlight", pinned: true),
            collection("reality", pinned: true),
            movies,
            collection("kids", pinned: false)
        ])
        XCTAssertEqual(ids, ["collection_reality", "collection_spotlight", "movies", "collection_kids"])
    }

    func testTheAccountOrderAppliesWhenThereIsNoLocalOrder() {
        store(["collection_reality", "collection_spotlight"], forKey: SettingsKey.homeCatalogSyncedOrder)
        let ids = orderedIDs([movies, collection("spotlight", pinned: true), collection("reality", pinned: true)])
        XCTAssertEqual(ids, ["collection_reality", "collection_spotlight", "movies"])
    }

    func testAPinnedCollectionMissingFromTheSavedOrderComesAfterTheSavedOnes() {
        store(["collection_reality", "movies"], forKey: SettingsKey.homeCatalogOrder)
        let ids = orderedIDs([collection("new", pinned: true), movies, collection("reality", pinned: true)])
        XCTAssertEqual(ids, ["collection_reality", "collection_new", "movies"])
    }

    func testWithoutASavedOrderPinnedCollectionsKeepTheirListOrder() {
        let ids = orderedIDs([movies, collection("spotlight", pinned: true), collection("reality", pinned: true)])
        XCTAssertEqual(ids, ["collection_spotlight", "collection_reality", "movies"])
    }
}
