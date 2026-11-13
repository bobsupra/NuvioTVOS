//
//  AIOSettingsSyncTests.swift
//  NuvioTVTests
//
//  AIOStreams in the Nuvio account (AIOSettingsSync): the
//  choice, Nuvio's settings for AIOStreams, and the configuration backup the
//  last one saved wins.
//

import Foundation
import XCTest
@testable import NuvioTV

final class AIOSettingsSyncTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "aio-settings-sync-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private func backup(_ savedAt: String, password: String = "pw", uuid: String? = nil, name: String = "mine") -> [String: Any] {
        var backup: [String: Any] = ["config": ["addonName": name, "presets": [["type": "torrentio"]]],
                                     "password": password, "savedAt": savedAt]
        if let uuid { backup["uuid"] = uuid }
        return backup
    }

    // MARK: Export

    func testNeverChosenLeavesTheAccountCopyAlone() {
        XCTAssertNil(AIOSettingsSync.syncChoice(store: store))
        XCTAssertNil(AIOSettingsSync.export(store: store, existing: nil, backup: backup("2026-11-01T10:00:00.000Z")))
        let existing: [String: Any] = ["enabled": true, "settings": ["startWithNuvio": true]]
        let kept = AIOSettingsSync.export(store: store, existing: existing, backup: nil)
        XCTAssertEqual(kept?["enabled"] as? Bool, true)
        XCTAssertNotNil(kept?["settings"])
    }

    func testOffKeepsOnlyTheChoice() throws {
        AIOSettingsSync.setSyncChoice(false, store: store)
        let payload = try XCTUnwrap(AIOSettingsSync.export(
            store: store, existing: ["enabled": true, "backup": backup("2026-11-01T10:00:00.000Z")], backup: nil))
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload["enabled"] as? Bool, false)
    }

    func testOnExportsTheSettingsAndTheBackupWithoutThisAppleTVsConfigurationID() throws {
        store.set(true, forKey: AIOStreamsHost.autoStartKey)
        store.set(false, forKey: AIOStreamsHost.addonKey)
        store.set("converted", forKey: AIOStreamsHost.animeRequestKey)
        store.set("ghcr.io/example/aiostreams", forKey: AIOStreamsHost.sourceKey)
        store.set(true, forKey: AIOStreamsHost.detailedLogKey)
        AIOSettingsSync.setSyncChoice(true, store: store)
        let payload = try XCTUnwrap(AIOSettingsSync.export(
            store: store, existing: nil, backup: backup("2026-11-01T10:00:00.000Z", uuid: "local-uuid")))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertEqual(payload["enabled"] as? Bool, true)
        let settings = try XCTUnwrap(payload["settings"] as? [String: Any])
        XCTAssertEqual(settings["startWithNuvio"] as? Bool, true)
        XCTAssertEqual(settings["useAddon"] as? Bool, false)
        XCTAssertEqual(settings["animeRequest"] as? String, "converted")
        XCTAssertEqual(settings["source"] as? String, "ghcr.io/example/aiostreams")
        XCTAssertEqual(settings["detailedLog"] as? Bool, true)
        let sent = try XCTUnwrap(payload["backup"] as? [String: Any])
        XCTAssertEqual(sent["password"] as? String, "pw", "stored as it is, without encryption")
        XCTAssertEqual(sent["savedAt"] as? String, "2026-11-01T10:00:00.000Z")
        XCTAssertNotNil(sent["config"])
        XCTAssertNil(sent["uuid"], "each Apple TV has its own configuration in its own AIOStreams")
    }

    func testOnWithDefaultsExportsTheDefaults() throws {
        AIOSettingsSync.setSyncChoice(true, store: store)
        let payload = try XCTUnwrap(AIOSettingsSync.export(store: store, existing: nil, backup: nil))
        let settings = try XCTUnwrap(payload["settings"] as? [String: Any])
        XCTAssertEqual(settings["startWithNuvio"] as? Bool, false)
        XCTAssertEqual(settings["useAddon"] as? Bool, true)
        XCTAssertEqual(settings["animeRequest"] as? String, "both")
        XCTAssertEqual(settings["source"] as? String, AIOStreamsHost.defaultSource)
        XCTAssertNil(payload["backup"], "no configuration yet")
    }

    func testTheNewerBackupGoesOutWhetherHereOrInTheAccount() throws {
        AIOSettingsSync.setSyncChoice(true, store: store)
        let older = backup("2026-11-01T10:00:00.000Z", name: "older")
        let newer = backup("2026-11-02T10:00:00.000Z", name: "newer")
        let fromHere = try XCTUnwrap(AIOSettingsSync.export(store: store, existing: ["enabled": true, "backup": older], backup: newer))
        XCTAssertEqual(((fromHere["backup"] as? [String: Any])?["config"] as? [String: Any])?["addonName"] as? String, "newer")
        let fromAccount = try XCTUnwrap(AIOSettingsSync.export(store: store, existing: ["enabled": true, "backup": newer], backup: older))
        XCTAssertEqual(((fromAccount["backup"] as? [String: Any])?["config"] as? [String: Any])?["addonName"] as? String, "newer",
                       "an Apple TV that hasn't pulled yet doesn't overwrite a newer configuration")
    }

    // MARK: Import

    func testImportOffTurnsTheChoiceOffAndKeepsEverythingHere() throws {
        AIOSettingsSync.setSyncChoice(true, store: store)
        store.set(true, forKey: AIOStreamsHost.autoStartKey)
        var saved: [[String: Any]] = []
        let imported = try XCTUnwrap(AIOSettingsSync.importPayload(
            ["enabled": false], store: store, localBackup: backup("2026-11-01T10:00:00.000Z")) { saved.append($0) })
        XCTAssertEqual(imported, AIOSettingsSync.Imported(settings: false, backup: false))
        XCTAssertEqual(AIOSettingsSync.syncChoice(store: store), false)
        XCTAssertTrue(store.bool(forKey: AIOStreamsHost.autoStartKey))
        XCTAssertTrue(saved.isEmpty)
        XCTAssertNil(AIOSettingsSync.importPayload(["enabled": false], store: store, localBackup: nil) { _ in },
                     "already off: nothing to do")
    }

    func testImportOnTakesTheSettingsAndANewerBackup() throws {
        var saved: [[String: Any]] = []
        let remote: [String: Any] = [
            "enabled": true,
            "settings": ["startWithNuvio": true, "useAddon": true, "animeRequest": "anilist",
                         "source": "ghcr.io/viren070/aiostreams", "detailedLog": false],
            "backup": backup("2026-11-02T10:00:00.000Z", password: "new-pw", name: "theirs"),
        ]
        let imported = try XCTUnwrap(AIOSettingsSync.importPayload(
            remote, store: store, localBackup: backup("2026-11-01T10:00:00.000Z", uuid: "local")) { saved.append($0) })
        XCTAssertEqual(imported, AIOSettingsSync.Imported(settings: true, backup: true))
        XCTAssertEqual(AIOSettingsSync.syncChoice(store: store), true)
        XCTAssertTrue(store.bool(forKey: AIOStreamsHost.autoStartKey))
        XCTAssertEqual(store.string(forKey: AIOStreamsHost.animeRequestKey), "anilist")
        XCTAssertTrue(store.bool(forKey: AIOSettingsSync.pendingBackupKey), "loaded into AIOStreams once it runs")
        let stored = try XCTUnwrap(saved.first)
        XCTAssertEqual((stored["config"] as? [String: Any])?["addonName"] as? String, "theirs")
        XCTAssertEqual(stored["password"] as? String, "new-pw")
        XCTAssertNil(stored["uuid"], "another password: a new configuration here")
    }

    func testImportWithTheSamePasswordKeepsThisAppleTVsConfiguration() throws {
        var saved: [[String: Any]] = []
        AIOSettingsSync.importPayload(
            ["enabled": true, "backup": backup("2026-11-02T10:00:00.000Z", password: "same", name: "theirs")],
            store: store, localBackup: backup("2026-11-01T10:00:00.000Z", password: "same", uuid: "local-uuid")
        ) { saved.append($0) }
        XCTAssertEqual(saved.first?["uuid"] as? String, "local-uuid", "the changes go into the configuration here; the addon keeps its address")
    }

    func testImportLeavesANewerOrTheSameBackupHereAlone() throws {
        var saved: [[String: Any]] = []
        let local = backup("2026-11-02T10:00:00.000Z", uuid: "local")
        for remoteTime in ["2026-11-01T10:00:00.000Z", "2026-11-02T10:00:00.000Z"] {
            let imported = AIOSettingsSync.importPayload(
                ["enabled": true, "backup": backup(remoteTime, name: "theirs")], store: store, localBackup: local) { saved.append($0) }
            XCTAssertEqual(imported?.backup, false)
        }
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(store.bool(forKey: AIOSettingsSync.pendingBackupKey))
    }

    func testImportOfTheSameSettingsChangesNothing() throws {
        AIOSettingsSync.setSyncChoice(true, store: store)
        store.set(true, forKey: AIOStreamsHost.autoStartKey)
        store.set("both", forKey: AIOStreamsHost.animeRequestKey)
        let imported = AIOSettingsSync.importPayload(
            ["enabled": true, "settings": ["startWithNuvio": true, "animeRequest": "both"]], store: store, localBackup: nil) { _ in }
        XCTAssertEqual(imported, AIOSettingsSync.Imported(settings: false, backup: false))
    }

    func testABackupWithoutAPasswordIsNotUsed() throws {
        var saved: [[String: Any]] = []
        AIOSettingsSync.importPayload(
            ["enabled": true, "backup": ["config": ["addonName": "x"], "savedAt": "2026-11-02T10:00:00.000Z"]],
            store: store, localBackup: nil) { saved.append($0) }
        XCTAssertTrue(saved.isEmpty)
    }

    func testTheWatchedValuesNoticeANewBackupAndTheChoice() {
        let before = AIOSettingsSync.observedValues(store: store)
        AIOSettingsSync.noteNewBackup(store: store)
        AIOSettingsSync.setSyncChoice(true, store: store)
        let after = AIOSettingsSync.observedValues(store: store)
        XCTAssertFalse(ProfileSettingsSnapshot.areEqual(before, after))
        XCTAssertEqual(after[AIOSettingsSync.backupRevisionKey] as? Int, 1)
    }
}
