import Foundation
import XCTest
@testable import NuvioTV

final class PluginSettingsSyncTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    private let repositoryA = "https://a.example.test/manifest.json"
    private let repositoryB = "https://b.example.test/manifest.json"

    override func setUp() {
        super.setUp()
        suiteName = "plugin-settings-sync-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private func repository(_ url: String) -> PluginRepositoryRecord {
        PluginRepositoryRecord(
            manifestURL: url, name: "Repository", description: nil, version: "1", author: nil,
            scraperCount: 1, lastUpdated: nil, errorMessage: nil, alwaysReload: nil
        )
    }

    private func scraper(_ scraperID: String, in repositoryURL: String) -> PluginScraperRecord {
        PluginScraperRecord(
            id: PluginScraperRecord.makeID(repositoryURL: repositoryURL, scraperID: scraperID),
            repositoryURL: repositoryURL, scraperID: scraperID, name: scraperID, description: "",
            version: "1.0.0", filename: "\(scraperID).js", supportedTypes: ["movie", "tv"], enabled: true,
            manifestEnabled: true, hasSettings: true, logo: nil, contentLanguage: [], formats: nil
        )
    }

    private func state(repositories: [String], scrapers: [PluginScraperRecord]) -> PluginStore.State {
        PluginStore.State(pluginsEnabled: true, repositories: repositories.map(repository), scrapers: scrapers)
    }

    private func entries(_ payload: [String: Any]?) throws -> [String: [String: Any]] {
        let scrapers = try XCTUnwrap(payload?["scrapers"] as? [String: Any])
        return scrapers.compactMapValues { $0 as? [String: Any] }
    }

    // MARK: Export

    func testNeverChosenLeavesTheAccountCopyAlone() {
        let local = state(repositories: [repositoryA], scrapers: [scraper("one", in: repositoryA)])
        XCTAssertNil(PluginSettingsSync.syncChoice(store: store))
        XCTAssertNil(PluginSettingsSync.export(store: store, existing: nil, state: local) { _ in ["apiKey": "secret"] })
        let existing: [String: Any] = ["enabled": true, "scrapers": ["x": ["repository": repositoryA, "settings": ["k": "v"]]]]
        let kept = PluginSettingsSync.export(store: store, existing: existing, state: local) { _ in ["apiKey": "secret"] }
        XCTAssertEqual(kept?["enabled"] as? Bool, true)
        XCTAssertNotNil(kept?["scrapers"] as? [String: Any])
    }

    func testOffKeepsOnlyTheChoice() throws {
        PluginSettingsSync.setSyncChoice(false, store: store)
        let local = state(repositories: [repositoryA], scrapers: [scraper("one", in: repositoryA)])
        let payload = try XCTUnwrap(PluginSettingsSync.export(
            store: store,
            existing: ["enabled": true, "scrapers": ["x": ["repository": repositoryA, "settings": ["k": "v"]]]],
            state: local
        ) { _ in ["apiKey": "secret"] })
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload["enabled"] as? Bool, false)
    }

    func testOnExportsTheSettingsOfProvidersThatHaveSome() throws {
        PluginSettingsSync.setSyncChoice(true, store: store)
        let one = scraper("one", in: repositoryA)
        let two = scraper("two", in: repositoryA)
        let local = state(repositories: [repositoryA], scrapers: [one, two])
        let settings: [String: [String: Any]] = [one.id: ["apiKey": "secret", "quality": "1080p", "debrid": true]]
        let payload = try XCTUnwrap(PluginSettingsSync.export(store: store, existing: nil, state: local) {
            settings[$0] ?? [:]
        })
        XCTAssertEqual(payload["enabled"] as? Bool, true)
        let exported = try entries(payload)
        XCTAssertEqual(Array(exported.keys), [one.id], "a provider without settings is left out")
        XCTAssertEqual(exported[one.id]?["repository"] as? String, repositoryA)
        let values = try XCTUnwrap(exported[one.id]?["settings"] as? [String: Any])
        XCTAssertEqual(values["apiKey"] as? String, "secret")
        XCTAssertEqual(values["debrid"] as? Bool, true)
        // The account stores JSON.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }

    func testOnKeepsTheAccountSettingsOfProvidersStillDownloading() throws {
        PluginSettingsSync.setSyncChoice(true, store: store)
        let one = scraper("one", in: repositoryA)
        let waiting = scraper("waiting", in: repositoryB)
        let removed = scraper("removed", in: "https://gone.example.test/manifest.json")
        // Both repositories are listed (back from the account), only A's provider is downloaded.
        let local = state(repositories: [repositoryA, repositoryB], scrapers: [one])
        let existing: [String: Any] = [
            "enabled": true,
            "scrapers": [
                one.id: ["repository": repositoryA, "settings": ["apiKey": "old"]],
                waiting.id: ["repository": repositoryB, "settings": ["login": "me", "password": "pw"]],
                removed.id: ["repository": removed.repositoryURL, "settings": ["apiKey": "gone"]],
            ],
        ]
        let payload = try XCTUnwrap(PluginSettingsSync.export(store: store, existing: existing, state: local) {
            $0 == one.id ? ["apiKey": "new"] : [:]
        })
        let exported = try entries(payload)
        XCTAssertEqual(Set(exported.keys), [one.id, waiting.id])
        XCTAssertEqual((exported[one.id]?["settings"] as? [String: Any])?["apiKey"] as? String, "new", "this Apple TV's settings win")
        XCTAssertEqual((exported[waiting.id]?["settings"] as? [String: Any])?["password"] as? String, "pw")
    }

    func testOnDropsSettingsClearedHere() throws {
        PluginSettingsSync.setSyncChoice(true, store: store)
        let one = scraper("one", in: repositoryA)
        let local = state(repositories: [repositoryA], scrapers: [one])
        let existing: [String: Any] = ["enabled": true, "scrapers": [one.id: ["repository": repositoryA, "settings": ["apiKey": "old"]]]]
        let payload = PluginSettingsSync.export(store: store, existing: existing, state: local) { _ in [:] }
        XCTAssertEqual(try entries(payload).count, 0)
    }

    // MARK: Import

    func testImportBringsTheSettingsAndTheChoiceBack() throws {
        let source = UserDefaults(suiteName: "\(suiteName)-source")!
        defer { source.removePersistentDomain(forName: "\(suiteName)-source") }
        PluginSettingsSync.setSyncChoice(true, store: source)
        let one = scraper("one", in: repositoryA)
        let two = scraper("two", in: repositoryB)
        let exported = try XCTUnwrap(PluginSettingsSync.export(
            store: source, existing: nil, state: state(repositories: [repositoryA, repositoryB], scrapers: [one, two])
        ) { $0 == one.id ? ["apiKey": "secret", "limit": 20] : ["login": "me", "password": "pw"] })
        // Through JSON, as the account returns it.
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: exported)) as? [String: Any])

        // A reinstall: no providers downloaded yet, one provider's settings already the same.
        var saved: [String: [String: Any]] = [:]
        PluginSettingsSync.importPayload(
            remote, store: store,
            current: { $0 == two.id ? ["login": "me", "password": "pw"] : [:] },
            save: { saved[$1] = $0 })

        XCTAssertEqual(Array(saved.keys), [one.id], "settings that are already the same aren't saved again")
        XCTAssertEqual(saved[one.id]?["apiKey"] as? String, "secret")
        XCTAssertEqual(saved[one.id]?["limit"] as? Int, 20)
        XCTAssertEqual(PluginSettingsSync.syncChoice(store: store), true)
    }

    func testImportOfOffTurnsTheChoiceOffAndKeepsTheSettingsHere() {
        PluginSettingsSync.setSyncChoice(true, store: store)
        PluginSettingsSync.importPayload(
            ["enabled": false], store: store,
            current: { _ in [:] },
            save: { _, _ in XCTFail("nothing to save expected") })
        XCTAssertEqual(PluginSettingsSync.syncChoice(store: store), false)
    }

    func testNothingInTheAccountChangesNothing() {
        PluginSettingsSync.importPayload(
            nil, store: store,
            current: { _ in [:] },
            save: { _, _ in XCTFail("nothing to save expected") })
        XCTAssertNil(PluginSettingsSync.syncChoice(store: store))
    }

    // MARK: Changes here

    func testASettingsChangeIsVisibleToTheSync() {
        let defaults = ProfileSettings.current
        let key = PluginSettingsSync.revisionKey
        let hadRevision = defaults.object(forKey: key) != nil
        let scraperID = "https://sync.example.test/manifest.json:test-\(UUID().uuidString)"
        defer {
            PluginSettingsVault.remove(scraperID: scraperID)
            if !hadRevision { defaults.removeObject(forKey: key) }
        }
        let before = defaults.integer(forKey: key)
        XCTAssertTrue(PluginSettingsVault.save(["apiKey": "secret"], scraperID: scraperID))
        XCTAssertEqual(defaults.integer(forKey: key), before + 1)
        XCTAssertTrue(PluginSettingsVault.remove(scraperID: scraperID))
        XCTAssertEqual(defaults.integer(forKey: key), before + 2)
        // From the account: saved, but not counted as a change here.
        XCTAssertTrue(PluginSettingsVault.saveFromAccount(
            ["apiKey": "other"], scraperID: scraperID, profileScope: ProfileSettings.activeProfileScope))
        XCTAssertEqual(defaults.integer(forKey: key), before + 2)
        XCTAssertEqual(PluginSettingsVault.settings(scraperID: scraperID)["apiKey"] as? String, "other")
        XCTAssertTrue(PluginSettingsSync.syncObservedKeys.contains(PluginSettingsSync.revisionKey))
        XCTAssertTrue(PluginSettingsSync.syncObservedKeys.contains(PluginSettingsSync.syncToAccountKey))
    }
}
