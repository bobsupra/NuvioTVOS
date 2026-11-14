import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class LastManualSourceStoreTests: XCTestCase {
    private func withStore(_ body: (UserDefaults) -> Void) {
        let name = "LastManualSourceStoreTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        body(store)
    }

    func testHistoryIsIndependentOfLastSourceFocusPreference() {
        withStore { store in
            let preference = SettingsKey.rememberLastSourceFocus
            store.set(false, forKey: preference)
            @MainActor
            func remember(_ source: String) {
                LastManualSourceStore.remember(sourceID: source, profileID: "a", metaID: "movie",
                    type: "movie", season: nil, episode: nil, store: store)
            }
            @MainActor
            func match() -> LastManualSourceStore.Match? {
                LastManualSourceStore.lastPlayedMatch(in: ["hash:first", "hash:second"], profileID: "a",
                    metaID: "movie", type: "movie", season: nil, episode: nil, store: store)
            }
            remember("hash:first")
            XCTAssertEqual(match()?.sourceID, "hash:first")
            XCTAssertNotNil(store.data(forKey: "nuvio.tv.manualSourceFocus.v1"))
            store.set(true, forKey: preference)
            XCTAssertEqual(match()?.sourceID, "hash:first")
            store.set(false, forKey: preference)
            remember("hash:second")
            XCTAssertEqual(match()?.sourceID, "hash:second")
            XCTAssertTrue(LastManualSourceStore.hasRememberedSource(profileID: "a", metaID: "movie",
                type: "movie", season: nil, episode: nil, store: store))
        }
    }

    func testExactMatchSurvivesReorderingWithoutUsingRowIndex() {
        withStore { store in
            let earliestPossibleSave = Date()
            LastManualSourceStore.remember(sourceID: "https://example.test/b", profileID: "a",
                metaID: "movie", type: "movie", season: nil, episode: nil, store: store)
            let latestPossibleSave = Date()
            let match = LastManualSourceStore.lastPlayedMatch(
                in: ["https://example.test/c", "https://example.test/a", "https://example.test/b"],
                profileID: "a", metaID: "movie", type: "movie", season: nil, episode: nil, store: store
            )
            XCTAssertEqual(match?.sourceID, "https://example.test/b")
            XCTAssertTrue(match.map { earliestPossibleSave...latestPossibleSave ~= $0.updatedAt } ?? false)
            XCTAssertEqual(LastManualSourceStore.matchingID(
                in: ["https://example.test/c", "https://example.test/a", "https://example.test/b"],
                profileID: "a", metaID: "movie", type: "movie", season: nil, episode: nil,
                store: store), "https://example.test/b")
            XCTAssertNil(LastManualSourceStore.matchingID(in: ["https://example.test/a"],
                profileID: "a", metaID: "movie", type: "movie", season: nil, episode: nil,
                store: store))
        }
    }

    func testProfileTitleAndEpisodeIsolation() {
        withStore { store in
            LastManualSourceStore.remember(sourceID: "hash:1", profileID: "a", metaID: "series",
                type: "series", season: 1, episode: 2, store: store)
            for (profile, title, season, episode) in [
                ("b", "series", 1, 2), ("a", "other", 1, 2),
                ("a", "series", 2, 2), ("a", "series", 1, 3)
            ] {
                XCTAssertNil(LastManualSourceStore.matchingID(in: ["hash:1"], profileID: profile,
                    metaID: title, type: "series", season: season, episode: episode, store: store))
            }
            XCTAssertEqual(LastManualSourceStore.matchingID(in: ["hash:1"], profileID: "a",
                metaID: "series", type: "series", season: 1, episode: 2, store: store), "hash:1")
        }
    }

    func testAmbiguousAndUnplayableFallbackIdentitiesAreNotRestored() {
        withStore { store in
            LastManualSourceStore.remember(sourceID: "hash:1", profileID: "a", metaID: "movie",
                type: "movie", season: nil, episode: nil, store: store)
            XCTAssertNil(LastManualSourceStore.matchingID(in: ["hash:1", "hash:1"], profileID: "a",
                metaID: "movie", type: "movie", season: nil, episode: nil, store: store))
            XCTAssertNil(LastManualSourceStore.lastPlayedMatch(in: ["hash:1", "hash:1"], profileID: "a",
                metaID: "movie", type: "movie", season: nil, episode: nil, store: store))
            LastManualSourceStore.remember(sourceID: "stream:display text", profileID: "a",
                metaID: "other", type: "movie", season: nil, episode: nil, store: store)
            XCTAssertFalse(LastManualSourceStore.hasRememberedSource(profileID: "a", metaID: "other",
                type: "movie", season: nil, episode: nil, store: store))
            LastManualSourceStore.remember(sourceID: "hash:1", profileID: "a", metaID: "series",
                type: "series", season: nil, episode: nil, store: store)
            XCTAssertFalse(LastManualSourceStore.hasRememberedSource(profileID: "a", metaID: "series",
                type: "series", season: nil, episode: nil, store: store))
        }
    }

    func testHistoryIsBoundedAndDoesNotPersistRawSourceCredentials() {
        withStore { store in
            for index in 0..<405 {
                LastManualSourceStore.remember(sourceID: "https://example.test/video?token=private-secret",
                    profileID: "private-profile", metaID: "movie-\(index)", type: "movie",
                    season: nil, episode: nil, store: store)
            }
            guard let data = store.data(forKey: "nuvio.tv.manualSourceFocus.v1") else {
                XCTFail("Expected persisted manual source history")
                return
            }
            let entries = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(entries.count, 400)
            let raw = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(raw.contains("private-secret"))
            XCTAssertFalse(raw.contains("private-profile"))
            XCTAssertFalse(raw.contains("example.test"))
        }
    }

    func testEraseAllPreventsHistoryLeakWhenAccountReusesProfileID() {
        withStore { store in
            let profileID = "1"
            let titleID = "movie-42"
            let sourceID = "hash:account-a"
            let unrelatedPreference = "test.unrelatedPreference"
            store.set("keep", forKey: unrelatedPreference)

            LastManualSourceStore.remember(
                sourceID: sourceID,
                profileID: profileID,
                metaID: titleID,
                type: "movie",
                season: nil,
                episode: nil,
                store: store
            )
            XCTAssertTrue(LastManualSourceStore.hasRememberedSource(
                profileID: profileID, metaID: titleID, type: "movie", season: nil, episode: nil,
                store: store
            ))

            LastManualSourceStore.eraseAll(store: store)
            store.set(true, forKey: SettingsKey.rememberLastSourceFocus) // Account B enables the setting.

            XCTAssertFalse(LastManualSourceStore.hasRememberedSource(
                profileID: profileID, metaID: titleID, type: "movie", season: nil, episode: nil,
                store: store
            ))
            XCTAssertNil(LastManualSourceStore.matchingID(
                in: [sourceID], profileID: profileID, metaID: titleID, type: "movie",
                season: nil, episode: nil, store: store
            ))

            LastManualSourceStore.eraseAll(store: store)
            XCTAssertTrue(store.bool(forKey: SettingsKey.rememberLastSourceFocus))
            XCTAssertEqual(store.string(forKey: unrelatedPreference), "keep")
            XCTAssertFalse(LastManualSourceStore.hasRememberedSource(
                profileID: profileID, metaID: titleID, type: "movie", season: nil, episode: nil,
                store: store
            ))
        }
    }
}
