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
}
