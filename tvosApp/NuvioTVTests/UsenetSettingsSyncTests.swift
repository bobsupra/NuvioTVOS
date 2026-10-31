import Foundation
import XCTest
@testable import NuvioTV

final class UsenetSettingsSyncTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "usenet-settings-sync-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private func server(_ id: String, host: String = "news.example.test") -> UsenetSavedServer {
        UsenetSavedServer(id: id, name: "Provider \(id)", host: host, port: 563, useSSL: true,
                          username: "user-\(id)", connections: 20, isEnabled: true)
    }

    // MARK: Export

    func testNeverChosenLeavesTheAccountCopyAlone() {
        UsenetSettings.setServers([server("a")], store: store)
        XCTAssertNil(UsenetSettings.syncChoice(store: store))
        XCTAssertNil(UsenetSettingsSync.export(store: store, existing: nil) { _ in "secret" })
        let existing: [String: Any] = ["enabled": true, "servers": []]
        let kept = UsenetSettingsSync.export(store: store, existing: existing) { _ in "secret" }
        XCTAssertEqual(kept?["enabled"] as? Bool, true)
        XCTAssertNotNil(kept?["servers"])
    }

    func testOffKeepsOnlyTheChoice() throws {
        UsenetSettings.setServers([server("a")], store: store)
        UsenetSettings.setSyncChoice(false, store: store)
        let payload = try XCTUnwrap(UsenetSettingsSync.export(
            store: store, existing: ["enabled": true, "servers": [["id": "a"]]]) { _ in "secret" })
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload["enabled"] as? Bool, false)
    }

    func testOnExportsServersPasswordsAndSettings() throws {
        UsenetSettings.setServers([server("a"), server("b", host: "eu.example.test")], store: store)
        UsenetSettings.setProfile(.highThroughput, store: store)
        UsenetSettings.setPrefersOwnServers(true, store: store)
        UsenetSettings.setSpeedLimitMbps(50, store: store)
        UsenetSettings.setSyncChoice(true, store: store)
        let payload = try XCTUnwrap(UsenetSettingsSync.export(store: store, existing: nil) { "pw-\($0)" })
        XCTAssertEqual(payload["enabled"] as? Bool, true)
        XCTAssertEqual(payload["profile"] as? String, "highThroughput")
        XCTAssertEqual(payload["preferOwnServers"] as? Bool, true)
        XCTAssertEqual(payload["speedLimitMbps"] as? Int, 50)
        let servers = try XCTUnwrap(payload["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.map { $0["id"] as? String }, ["a", "b"])
        XCTAssertEqual(servers.map { $0["password"] as? String }, ["pw-a", "pw-b"])
        XCTAssertEqual(servers.last?["host"] as? String, "eu.example.test")
        // The account stores JSON.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }

    // MARK: Import

    func testImportBringsServersPasswordsAndTheChoiceBack() throws {
        let source = UserDefaults(suiteName: "\(suiteName)-source")!
        defer { source.removePersistentDomain(forName: "\(suiteName)-source") }
        UsenetSettings.setServers([server("a"), server("b")], store: source)
        UsenetSettings.setProfile(.lowMemory, store: source)
        UsenetSettings.setSpeedLimitMbps(25, store: source)
        UsenetSettings.setSyncChoice(true, store: source)
        let exported = try XCTUnwrap(UsenetSettingsSync.export(store: source, existing: nil) { "pw-\($0)" })
        // Through JSON, as the account returns it.
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: exported)) as? [String: Any])

        var saved: [String: String] = [:]
        var removed: [String] = []
        UsenetSettings.setServers([server("old")], store: store)
        UsenetSettingsSync.importPayload(
            remote, store: store,
            savePassword: { saved[$1] = $0 },
            removePassword: { removed.append($0) })

        XCTAssertEqual(UsenetSettings.servers(store: store).map(\.id), ["a", "b"])
        XCTAssertEqual(UsenetSettings.servers(store: store).first, server("a"))
        XCTAssertEqual(saved, ["a": "pw-a", "b": "pw-b"])
        XCTAssertEqual(removed, ["old"])
        XCTAssertEqual(UsenetSettings.profile(store: store), .lowMemory)
        XCTAssertEqual(UsenetSettings.speedLimitMbps(store: store), 25)
        XCTAssertEqual(UsenetSettings.syncChoice(store: store), true)
    }

    func testImportOfOffTurnsTheChoiceOffAndKeepsLocalServers() {
        UsenetSettings.setServers([server("a")], store: store)
        UsenetSettings.setSyncChoice(true, store: store)
        UsenetSettingsSync.importPayload(
            ["enabled": false], store: store,
            savePassword: { _, _ in XCTFail("no password expected") },
            removePassword: { _ in XCTFail("no removal expected") })
        XCTAssertEqual(UsenetSettings.syncChoice(store: store), false)
        XCTAssertEqual(UsenetSettings.servers(store: store).map(\.id), ["a"])
    }

    func testNothingInTheAccountChangesNothing() {
        UsenetSettings.setServers([server("a")], store: store)
        UsenetSettingsSync.importPayload(
            nil, store: store,
            savePassword: { _, _ in XCTFail("no password expected") },
            removePassword: { _ in XCTFail("no removal expected") })
        XCTAssertNil(UsenetSettings.syncChoice(store: store))
        XCTAssertEqual(UsenetSettings.servers(store: store).map(\.id), ["a"])
    }

    func testAnEmptyPasswordRemovesTheSavedOne() {
        var removed: [String] = []
        UsenetSettingsSync.importPayload(
            ["enabled": true, "servers": [["id": "a", "host": "news.example.test", "port": 119, "password": ""]]],
            store: store,
            savePassword: { _, _ in XCTFail("no password expected") },
            removePassword: { removed.append($0) })
        XCTAssertEqual(removed, ["a"])
        let imported = UsenetSettings.servers(store: store)
        XCTAssertEqual(imported.map(\.port), [119])
        XCTAssertEqual(imported.first?.isEnabled, true)
    }

    func testAPasswordChangeIsVisibleToTheSync() {
        let before = store.integer(forKey: UsenetSettings.credentialsRevisionKey)
        // upsert saves to the active profile's Keychain scope; clean it up.
        defer { UsenetCredentialStore.remove(forServerID: "a") }
        UsenetSettings.upsert(server("a"), password: "secret", store: store)
        XCTAssertEqual(store.integer(forKey: UsenetSettings.credentialsRevisionKey), before + 1)
        XCTAssertTrue(UsenetSettings.syncObservedKeys.contains(UsenetSettings.credentialsRevisionKey))
        XCTAssertTrue(UsenetSettings.syncObservedKeys.contains(UsenetSettings.syncToAccountKey))
    }
}
