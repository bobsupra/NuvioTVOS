import XCTest
@testable import NuvioTV

private final class WatchedStoreReconciliationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReentryCompleted = true
    private var storedReconciliationSucceeded = false
    private var observerDeliveryStarted = false

    func recordReentryCompleted(_ completed: Bool) {
        lock.lock()
        storedReentryCompleted = storedReentryCompleted && completed
        lock.unlock()
    }

    func beginObserverDelivery() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !observerDeliveryStarted else { return false }
        observerDeliveryStarted = true
        return true
    }

    func recordReconciliationSucceeded(_ succeeded: Bool) {
        lock.lock()
        storedReconciliationSucceeded = succeeded
        lock.unlock()
    }

    var reentryCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedReentryCompleted
    }

    var reconciliationSucceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedReconciliationSucceeded
    }
}

final class ContinueWatchingAndPlayerSyncTests: XCTestCase {
    private let dismissalTestProfileId = "continue-watching-sync-\(UUID().uuidString)"
    private var previousDismissalProfileId: String?

    override func setUp() {
        super.setUp()
        previousDismissalProfileId = ContinueWatchingDismissStore.activeProfileId
        ContinueWatchingDismissStore.setActiveProfile(dismissalTestProfileId)
        ContinueWatchingDismissStore.eraseProfile(dismissalTestProfileId)
    }

    override func tearDown() {
        ContinueWatchingDismissStore.eraseProfile(dismissalTestProfileId)
        ContinueWatchingDismissStore.setActiveProfile(previousDismissalProfileId)
        super.tearDown()
    }

    private func makeDismissalTestItem(contentId: String) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: NuvioMeta(id: contentId, name: "Dismiss test", type: "series"),
            streamUrl: "",
            position: 100,
            duration: 1_800,
            lastWatchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            season: 1,
            episode: 1
        )
    }

    private func makeEpisodeProgress(
        contentId: String,
        season: Int,
        episode: Int,
        position: Double,
        duration: Double = 1_000,
        lastWatchedAt: Date
    ) -> WatchProgressRecord {
        WatchProgressRecord(
            progressKey: WatchProgressLedger.progressKey(
                contentId: contentId,
                season: season,
                episode: episode
            ),
            contentId: contentId,
            contentType: "series",
            videoId: WatchProgressLedger.videoId(
                contentId: contentId,
                season: season,
                episode: episode
            ),
            season: season,
            episode: episode,
            position: position,
            duration: duration,
            lastWatchedAt: lastWatchedAt
        )
    }

    private func disableRemoteWatchedSyncForTest() -> () -> Void {
        let defaults = ProfileSettings.current
        let keys = [
            "nuvio.tv.trakt.auth.accessToken",
            "nuvio.tv.trakt.auth.refreshToken",
            SettingsKey.traktConnected,
            SettingsKey.traktWatchProgressSource
        ]
        let previousValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defaults.removeObject(forKey: keys[0])
        defaults.removeObject(forKey: keys[1])
        defaults.removeObject(forKey: keys[2])
        defaults.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: keys[3])
        return {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    // MARK: - Continue Watching Sync Tests

    func testContinueWatchingSortModeMapping() {
        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeToWire("Default"), "DEFAULT")
        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeToWire("Streaming Style"), "STREAMING_STYLE")
        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeToWire("Separate Upcoming Row"), "DEFAULT")
        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeToWire(nil), "DEFAULT")

        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeFromWire("STREAMING_STYLE"), "Streaming Style")
        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeFromWire("DEFAULT"), "Default")
        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeFromWire(nil), "Default")
        XCTAssertEqual(ContinueWatchingSyncMapper.sortModeFromWire("UNKNOWN"), "Default")
    }

    func testContinueWatchingExportPayload() {
        let payload = ContinueWatchingSyncMapper.exportPayload(
            upNextFromFurthestEpisode: true,
            showUnairedNextUp: false,
            continueWatchingSort: "Streaming Style",
            existingPayload: nil
        )

        XCTAssertFalse(payload.isEmpty)
        guard let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Failed to parse exported JSON payload")
            return
        }

        XCTAssertEqual(json["upNextFromFurthestEpisode"] as? Bool, true)
        XCTAssertEqual(json["show_unaired_next_up"] as? Bool, false)
        XCTAssertEqual(json["sort_mode"] as? String, "STREAMING_STYLE")
        XCTAssertEqual(json["isVisible"] as? Bool, true)
        XCTAssertEqual(json["style"] as? String, "Card")
    }

    func testContinueWatchingExportPreservesAuxiliaryFields() {
        ContinueWatchingDismissStore.replaceKeys(
            ["tt1234567|1|1", "tt7654321|2|3"],
            profileId: dismissalTestProfileId
        )
        let existingPayload = """
        {
            "isVisible": false,
            "style": "Poster",
            "use_episode_thumbnails_in_cw": false,
            "blur_continue_watching_next_up": true,
            "showResumePromptOnLaunch": false,
            "sort_mode": "DEFAULT"
        }
        """

        let payload = ContinueWatchingSyncMapper.exportPayload(
            localProfileId: dismissalTestProfileId,
            upNextFromFurthestEpisode: false,
            showUnairedNextUp: true,
            continueWatchingSort: "Streaming Style",
            existingPayload: existingPayload
        )

        guard let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Failed to parse exported JSON payload")
            return
        }

        XCTAssertEqual(json["isVisible"] as? Bool, false)
        XCTAssertEqual(json["style"] as? String, "Poster")
        XCTAssertEqual(json["use_episode_thumbnails_in_cw"] as? Bool, false)
        XCTAssertEqual(json["blur_continue_watching_next_up"] as? Bool, true)
        XCTAssertEqual((json["dismissedNextUpKeys"] as? [String])?.count, 2)
        XCTAssertEqual(json["showResumePromptOnLaunch"] as? Bool, false)
        XCTAssertEqual(json["upNextFromFurthestEpisode"] as? Bool, false)
        XCTAssertEqual(json["show_unaired_next_up"] as? Bool, true)
        XCTAssertEqual(json["sort_mode"] as? String, "STREAMING_STYLE")
    }

    func testContinueWatchingExportDoesNotResurrectClearedDismissals() {
        // Given existing payload had a dismissal for tt33546863
        let existingPayload = """
        {
            "dismissedNextUpKeys": ["tt33546863|-1|-1", "tt1234567|1|1"]
        }
        """
        // But local store only has tt1234567|1|1 because tt33546863 was cleared on watch
        ContinueWatchingDismissStore.replaceKeys(["tt1234567|1|1"], profileId: dismissalTestProfileId)

        let payload = ContinueWatchingSyncMapper.exportPayload(
            localProfileId: dismissalTestProfileId,
            upNextFromFurthestEpisode: true,
            showUnairedNextUp: true,
            continueWatchingSort: "Default",
            existingPayload: existingPayload
        )

        guard let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dismissed = json["dismissedNextUpKeys"] as? [String] else {
            XCTFail("Failed to parse exported JSON payload")
            return
        }

        XCTAssertEqual(dismissed, ["tt1234567|1|1"])
        XCTAssertFalse(dismissed.contains("tt33546863|-1|-1"))
    }

    func testContinueWatchingImportPayload() {
        let remoteJson = """
        {
            "isVisible": false,
            "upNextFromFurthestEpisode": false,
            "show_unaired_next_up": false,
            "sort_mode": "STREAMING_STYLE",
            "dismissedNextUpKeys": ["tt1234567|1|1"]
        }
        """

        let (isVisible, upNext, showUnaired, sortMode, dismissedKeys) = ContinueWatchingSyncMapper.importPayload(remoteJson)
        XCTAssertEqual(isVisible, false)
        XCTAssertEqual(upNext, false)
        XCTAssertEqual(showUnaired, false)
        XCTAssertEqual(sortMode, "Streaming Style")
        XCTAssertEqual(dismissedKeys, ["tt1234567|1|1"])
    }

    func testAndroidTraktDismissalStringSetRoundTripPreservesOtherPreferences() {
        let existing: [String: Any] = [
            "sync_enabled": ["type": "boolean", "value": true],
            "sort_order": ["type": "string", "value": "recent"]
        ]
        let exported = ContinueWatchingSyncMapper.exportAndroidTraktFeature(
            existing: existing,
            dismissedKeys: [
                "tt-plain",
                "tt-legacy|1|2",
                "tt-unit\u{1f}3\u{1f}4"
            ]
        )
        let entry = exported[ContinueWatchingSyncMapper.androidDismissedNextUpKeysKey] as? [String: Any]
        XCTAssertEqual(entry?["type"] as? String, "string_set")
        XCTAssertEqual(entry?["value"] as? [String], ["tt-legacy", "tt-plain", "tt-unit"])
        XCTAssertEqual((exported["sync_enabled"] as? [String: Any])?["value"] as? Bool, true)
        XCTAssertEqual((exported["sort_order"] as? [String: Any])?["value"] as? String, "recent")

        let imported = ContinueWatchingSyncMapper.androidDismissalKeys(from: exported)
        XCTAssertTrue(imported.isPresent)
        XCTAssertEqual(
            imported.keys,
            Set(["tt-legacy|-1|-1", "tt-plain|-1|-1", "tt-unit|-1|-1"])
        )
    }

    func testAndroidTraktDismissalImportNormalizesPlainAndLegacyIDs() {
        let feature: [String: Any] = [
            ContinueWatchingSyncMapper.androidDismissedNextUpKeysKey: [
                "type": "string_set",
                "value": [
                    " tt-plain ",
                    "tt-pipe|2|4",
                    "tt-unit\u{1f}3\u{1f}5"
                ]
            ]
        ]

        let imported = ContinueWatchingSyncMapper.androidDismissalKeys(from: feature)
        XCTAssertTrue(imported.isPresent)
        XCTAssertEqual(
            imported.keys,
            Set(["tt-plain|-1|-1", "tt-pipe|-1|-1", "tt-unit|-1|-1"])
        )
    }

    func testAndroidEmptyDismissalSetOverridesStaleLegacyPayload() {
        let androidFeature: [String: Any] = [
            ContinueWatchingSyncMapper.androidDismissedNextUpKeysKey: [
                "type": "string_set",
                "value": [String]()
            ]
        ]
        let legacyPayload: [String: Any] = [
            "dismissedNextUpKeys": ["tt-stale|-1|-1"]
        ]

        let imported = ContinueWatchingSyncMapper.dismissalKeysForImport(
            androidTraktFeature: androidFeature,
            legacyPayload: legacyPayload
        )

        XCTAssertTrue(imported.isPresent)
        XCTAssertEqual(imported.keys, [])
    }

    func testMalformedAndroidDismissalEntryDoesNotFallBackToStaleLegacyPayload() {
        let malformedFeatures: [[String: Any]] = [
            [
                ContinueWatchingSyncMapper.androidDismissedNextUpKeysKey: [
                    "type": "string",
                    "value": ["tt-android"]
                ]
            ],
            [
                ContinueWatchingSyncMapper.androidDismissedNextUpKeysKey: [
                    "type": "string_set",
                    "value": ["tt-android", 7]
                ]
            ]
        ]
        let legacyPayload: [String: Any] = [
            "dismissedNextUpKeys": ["tt-stale|-1|-1"]
        ]

        for feature in malformedFeatures {
            let imported = ContinueWatchingSyncMapper.dismissalKeysForImport(
                androidTraktFeature: feature,
                legacyPayload: legacyPayload
            )
            XCTAssertTrue(imported.isPresent)
            XCTAssertNil(imported.keys)
        }
    }

    func testAbsentAndroidDismissalEntryFallsBackToLegacyPayload() {
        let legacyPayload: [String: Any] = [
            "dismissedNextUpKeys": ["tt-legacy|2|3"]
        ]

        let imported = ContinueWatchingSyncMapper.dismissalKeysForImport(
            androidTraktFeature: ["other_setting": true],
            legacyPayload: legacyPayload
        )

        XCTAssertTrue(imported.isPresent)
        XCTAssertEqual(imported.keys, ["tt-legacy|2|3"])
    }

    func testClearedDismissalFiltersStaleImportedKeysAndExport() {
        let contentId = "tt-resumed-dismissal"
        ContinueWatchingDismissStore.dismiss(makeDismissalTestItem(contentId: contentId))
        ContinueWatchingDismissStore.clear(contentId: contentId)

        ContinueWatchingDismissStore.replaceKeys(
            ["\(contentId)|4|5", "tt-unrelated|1|1"],
            profileId: dismissalTestProfileId
        )

        XCTAssertEqual(ContinueWatchingDismissStore.keys(profileId: dismissalTestProfileId), ["tt-unrelated|1|1"])
        let payload = ContinueWatchingSyncMapper.exportPayload(
            localProfileId: dismissalTestProfileId,
            upNextFromFurthestEpisode: false,
            showUnairedNextUp: true,
            continueWatchingSort: "Default",
            existingPayload: nil
        )
        let json = try! XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(json["dismissedNextUpKeys"] as? [String], ["tt-unrelated|1|1"])
    }

    func testClearWithoutLocalDismissalPersistsMarkerAndBlocksStaleImport() {
        let contentId = "tt-clear-before-import"
        ContinueWatchingDismissStore.clear(contentId: " \(contentId) ")

        let markerStorageKey = "nuvio.tv.continueWatching.resumedContentIDs.\(dismissalTestProfileId)"
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: markerStorageKey), [contentId])

        ContinueWatchingDismissStore.replaceKeys(
            ["\(contentId)|-1|-1", "tt-preserved|2|3"],
            profileId: dismissalTestProfileId
        )
        XCTAssertEqual(ContinueWatchingDismissStore.keys(profileId: dismissalTestProfileId), ["tt-preserved|2|3"])

        ContinueWatchingDismissStore.eraseProfile(dismissalTestProfileId)
        XCTAssertNil(UserDefaults.standard.object(forKey: markerStorageKey))
    }

    func testPersistedResumeMarkerLoadsAndFiltersExportedKeys() {
        let profileId = "\(dismissalTestProfileId)-persisted"
        defer { ContinueWatchingDismissStore.eraseProfile(profileId) }
        let contentId = "tt-persisted-resume-marker"
        let markerStorageKey = "nuvio.tv.continueWatching.resumedContentIDs.\(profileId)"
        let dismissalStorageKey = "nuvio.tv.continueWatching.dismissedKeys.\(profileId)"
        UserDefaults.standard.set([contentId], forKey: markerStorageKey)
        UserDefaults.standard.set(["\(contentId)|-1|-1", "tt-persisted-unrelated|1|1"], forKey: dismissalStorageKey)

        let payload = ContinueWatchingSyncMapper.exportPayload(
            localProfileId: profileId,
            upNextFromFurthestEpisode: false,
            showUnairedNextUp: true,
            continueWatchingSort: "Default",
            existingPayload: nil
        )
        let json = try! XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(json["dismissedNextUpKeys"] as? [String], ["tt-persisted-unrelated|1|1"])
    }

    func testEraseAllProfilesRemovesResumeMarkersAndRestoresOtherStoredProfiles() {
        let defaults = UserDefaults.standard
        let relevantPrefixes = [
            "nuvio.tv.continueWatching.dismissedKeys",
            "nuvio.tv.continueWatching.pendingDismissedKeys",
            "nuvio.tv.continueWatching.resumedContentIDs"
        ]
        let previousValues = defaults.dictionaryRepresentation().filter { key, _ in
            relevantPrefixes.contains(where: key.hasPrefix)
        }
        defer {
            defaults.dictionaryRepresentation().keys
                .filter { key in relevantPrefixes.contains(where: key.hasPrefix) }
                .forEach { defaults.removeObject(forKey: $0) }
            previousValues.forEach { defaults.set($0.value, forKey: $0.key) }
        }

        let markerStorageKey = "nuvio.tv.continueWatching.resumedContentIDs.\(dismissalTestProfileId)"
        defaults.set(["tt-erase-all-marker"], forKey: markerStorageKey)
        ContinueWatchingDismissStore.eraseAllProfiles()

        XCTAssertNil(defaults.object(forKey: markerStorageKey))
    }

    func testClearMatchesCanonicalLegacyBareAndWildcardKeysButPreservesOtherTitles() {
        let legacyId = "tt-legacy-resumed"
        let bareId = "tt-bare-resumed"
        let wildcardId = "tt-wildcard-resumed"
        let canonicalId = "tt-canonical-resumed"
        [legacyId, bareId, wildcardId, canonicalId].forEach {
            ContinueWatchingDismissStore.clear(contentId: $0)
        }

        let legacySeparator = "\u{1f}"
        let importedKeys: Set<String> = [
            "\(legacyId)\(legacySeparator)1\(legacySeparator)2",
            bareId,
            "\(wildcardId)|-1|-1",
            "\(canonicalId)|3|4",
            "tt-kept-canonical|1|2",
            "tt-kept-legacy\(legacySeparator)4\(legacySeparator)5",
            " tt-kept-bare "
        ]

        ContinueWatchingDismissStore.replaceKeys(importedKeys, profileId: dismissalTestProfileId)

        XCTAssertEqual(
            ContinueWatchingDismissStore.keys(profileId: dismissalTestProfileId),
            ["tt-kept-canonical|1|2", "tt-kept-legacy\(legacySeparator)4\(legacySeparator)5", " tt-kept-bare "]
        )
    }

    func testExplicitRedismissThroughBothOverloadsRemovesResumeMarker() {
        let itemId = "tt-redismiss-item"
        ContinueWatchingDismissStore.clear(contentId: itemId)
        ContinueWatchingDismissStore.dismiss(makeDismissalTestItem(contentId: itemId))
        ContinueWatchingDismissStore.replaceKeys(["\(itemId)|2|3"], profileId: dismissalTestProfileId)
        XCTAssertEqual(ContinueWatchingDismissStore.keys(profileId: dismissalTestProfileId), ["\(itemId)|2|3"])

        let contentId = "tt-redismiss-content-id"
        ContinueWatchingDismissStore.clear(contentId: contentId)
        ContinueWatchingDismissStore.dismiss(contentId: contentId)
        ContinueWatchingDismissStore.replaceKeys(["\(contentId)|2|3"], profileId: dismissalTestProfileId)
        XCTAssertEqual(ContinueWatchingDismissStore.keys(profileId: dismissalTestProfileId), ["\(contentId)|2|3"])
    }

    func testResumeMarkersAreIsolatedByProfile() {
        let otherProfileId = "\(dismissalTestProfileId)-other"
        defer { ContinueWatchingDismissStore.eraseProfile(otherProfileId) }
        let contentId = "tt-profile-resume-marker"
        let staleKey = "\(contentId)|1|1"

        ContinueWatchingDismissStore.clear(contentId: contentId)
        ContinueWatchingDismissStore.setActiveProfile(otherProfileId)
        ContinueWatchingDismissStore.replaceKeys([staleKey], profileId: otherProfileId)
        XCTAssertEqual(ContinueWatchingDismissStore.keys(profileId: otherProfileId), [staleKey])

        ContinueWatchingDismissStore.setActiveProfile(dismissalTestProfileId)
        ContinueWatchingDismissStore.replaceKeys([staleKey], profileId: dismissalTestProfileId)
        XCTAssertTrue(ContinueWatchingDismissStore.keys(profileId: dismissalTestProfileId).isEmpty)
    }

    // MARK: - Player Settings Sync Tests

    func testPlayerSettingsMergeIsMobileFirstAndPreservesUnknownKeys() {
        let merged = PlayerSettingsSyncMapper.mergeRemoteSettings(
            mobile: ["stream_auto_play_mode": "FIRST_STREAM", "shared": "mobile"],
            tv: ["stream_auto_play_mode": "AUTO", "tv_only": true, "shared": "tv"]
        )
        XCTAssertEqual(merged["stream_auto_play_mode"] as? String, "FIRST_STREAM")
        XCTAssertEqual(merged["tv_only"] as? Bool, true)
        XCTAssertEqual(merged["shared"] as? String, "mobile")

        let overlaid = PlayerSettingsSyncMapper.overlayOwnedSettings(
            merged,
            with: ["smart_stream_selection": true, "shared": "tvos-owned"]
        )
        XCTAssertEqual(overlaid["stream_auto_play_mode"] as? String, "FIRST_STREAM")
        XCTAssertEqual(overlaid["tv_only"] as? Bool, true)
        XCTAssertEqual(overlaid["smart_stream_selection"] as? Bool, true)
        XCTAssertEqual(overlaid["shared"] as? String, "tvos-owned")
    }

    func testPlayerSettingsKeyMappingsCoverage() {
        let localKeys = PlayerSettingsSyncMapper.localToRemoteKeyMappings.map(\.local)
        XCTAssertTrue(localKeys.contains(SettingsKey.audioLanguage))
        XCTAssertTrue(localKeys.contains(SettingsKey.subtitleLanguage))
        XCTAssertTrue(localKeys.contains(SettingsKey.subtitleLanguageSecondary))
        XCTAssertTrue(localKeys.contains(SettingsKey.forcedSubtitles))
        XCTAssertTrue(localKeys.contains(SettingsKey.autoPlayNext))
        XCTAssertTrue(localKeys.contains(SettingsKey.autoPlayNextCountdown))
        XCTAssertTrue(localKeys.contains(SettingsKey.cachedOnlyStreams))
        XCTAssertTrue(localKeys.contains(SettingsKey.preserveAddonStreamOrder))
        XCTAssertTrue(localKeys.contains(SettingsKey.streamSortOption))
        XCTAssertTrue(localKeys.contains(SettingsKey.smartStreamSelection))
        XCTAssertTrue(localKeys.contains(SettingsKey.smartStreamUseTopResult))
        XCTAssertTrue(localKeys.contains(SettingsKey.smartStreamQuality))
        XCTAssertTrue(localKeys.contains(SettingsKey.externalPlayerForwardSubtitles))
        XCTAssertTrue(localKeys.contains(SettingsKey.frameRateMatching))
        XCTAssertTrue(localKeys.contains(SettingsKey.playerShowPiP))
        XCTAssertTrue(localKeys.contains(SettingsKey.playerShowEpisodes))
        XCTAssertTrue(localKeys.contains(SettingsKey.playerShowSources))
        XCTAssertTrue(localKeys.contains(SettingsKey.playerShowSubtitles))
        XCTAssertTrue(localKeys.contains(SettingsKey.seekPreviewEnabled))
        XCTAssertTrue(localKeys.contains(SettingsKey.showLoadingStatus))
        XCTAssertTrue(localKeys.contains(SettingsKey.streamAutoPlayPreferBingeGroup))
        XCTAssertTrue(localKeys.contains(SettingsKey.streamAutoPlayReuseBingeGroup))

        let remoteKeys = PlayerSettingsSyncMapper.remoteToLocalKeyMappings.map(\.remote)
        XCTAssertTrue(remoteKeys.contains("preferred_audio_language"))
        XCTAssertTrue(remoteKeys.contains("preferred_subtitle_language"))
        XCTAssertTrue(remoteKeys.contains("secondary_preferred_subtitle_language"))
        XCTAssertTrue(remoteKeys.contains("subtitle_use_forced_subtitles"))
        XCTAssertTrue(remoteKeys.contains("stream_auto_play_next_episode_enabled"))
        XCTAssertTrue(remoteKeys.contains("stream_auto_play_timeout_seconds"))
        XCTAssertTrue(remoteKeys.contains("stream_auto_play_prefer_binge_group"))
        XCTAssertTrue(remoteKeys.contains("stream_auto_play_reuse_binge_group"))
        XCTAssertTrue(remoteKeys.contains("stream_cached_only"))
        XCTAssertTrue(remoteKeys.contains("cached_only_streams"))
        XCTAssertTrue(remoteKeys.contains("preserve_addon_stream_order"))
        XCTAssertTrue(remoteKeys.contains("stream_sort_mode"))
        XCTAssertTrue(remoteKeys.contains("smart_stream_selection"))
        XCTAssertTrue(remoteKeys.contains("smart_stream_use_top_result"))
        XCTAssertTrue(remoteKeys.contains("smart_stream_quality"))
        XCTAssertTrue(remoteKeys.contains("external_player_forward_subtitles"))
        XCTAssertTrue(remoteKeys.contains("frame_rate_matching"))
        XCTAssertTrue(remoteKeys.contains("player_show_pip"))
        XCTAssertTrue(remoteKeys.contains("player_show_episodes"))
        XCTAssertTrue(remoteKeys.contains("player_show_sources"))
        XCTAssertTrue(remoteKeys.contains("player_show_subtitles"))
        XCTAssertTrue(remoteKeys.contains("seek_preview_enabled"))
        XCTAssertTrue(remoteKeys.contains("show_player_loading_status"))
        XCTAssertTrue(remoteKeys.contains("player_show_loading_status"))
    }

    func testAutoPlayModeWireMapping() {
        XCTAssertEqual(PlayerSettingsSyncMapper.autoPlayModeToWire(useTopResult: true, smartSelection: true, existingWireMode: nil), "FIRST_STREAM")
        XCTAssertEqual(PlayerSettingsSyncMapper.autoPlayModeToWire(useTopResult: false, smartSelection: true, existingWireMode: nil), "MANUAL")
        XCTAssertEqual(PlayerSettingsSyncMapper.autoPlayModeToWire(useTopResult: false, smartSelection: false, existingWireMode: "REGEX_MATCH"), "REGEX_MATCH")
        XCTAssertEqual(PlayerSettingsSyncMapper.autoPlayModeToWire(useTopResult: true, smartSelection: true, existingWireMode: "REGEX_MATCH"), "FIRST_STREAM")

        let first = PlayerSettingsSyncMapper.autoPlayModeFromWire("FIRST_STREAM")
        XCTAssertEqual(first?.useTopResult, true)
        XCTAssertEqual(first?.smartSelection, true)

        let manual = PlayerSettingsSyncMapper.autoPlayModeFromWire("MANUAL")
        XCTAssertEqual(manual?.useTopResult, false)
        XCTAssertEqual(manual?.smartSelection, false)

        let regex = PlayerSettingsSyncMapper.autoPlayModeFromWire("REGEX_MATCH")
        XCTAssertEqual(regex?.useTopResult, false)
        XCTAssertEqual(regex?.smartSelection, false)

        XCTAssertNil(PlayerSettingsSyncMapper.autoPlayModeFromWire(nil))
        XCTAssertNil(PlayerSettingsSyncMapper.autoPlayModeFromWire(""))
    }

    func testPlayerSettingsExportAutoPlayFirstSource() {
        let testProfileId = "test_player_export_\(UUID().uuidString)"
        let store = ProfileSettings.store(for: testProfileId)
        defer {
            store.removeObject(forKey: SettingsKey.smartStreamUseTopResult)
            store.removeObject(forKey: SettingsKey.smartStreamSelection)
        }

        store.set(true, forKey: SettingsKey.smartStreamUseTopResult)
        store.set(true, forKey: SettingsKey.smartStreamSelection)

        let exported = PlayerSettingsSyncMapper.exportPayload(
            localProfileId: testProfileId,
            existing: nil,
            encodeValue: { val in ["type": "mock", "value": val] }
        )

        let modeDict = exported[PlayerSettingsSyncMapper.streamAutoPlayModeRemoteKey] as? [String: Any]
        XCTAssertEqual(modeDict?["value"] as? String, "FIRST_STREAM")

        let topDict = exported[PlayerSettingsSyncMapper.smartStreamUseTopResultRemoteKey] as? [String: Any]
        XCTAssertEqual(topDict?["value"] as? Bool, true)

        store.set(false, forKey: SettingsKey.smartStreamUseTopResult)
        let exportedManual = PlayerSettingsSyncMapper.exportPayload(
            localProfileId: testProfileId,
            existing: exported,
            encodeValue: { val in ["type": "mock", "value": val] }
        )

        let modeDictManual = exportedManual[PlayerSettingsSyncMapper.streamAutoPlayModeRemoteKey] as? [String: Any]
        XCTAssertEqual(modeDictManual?["value"] as? String, "MANUAL")

        let topDictManual = exportedManual[PlayerSettingsSyncMapper.smartStreamUseTopResultRemoteKey] as? [String: Any]
        XCTAssertEqual(topDictManual?["value"] as? Bool, false)
    }

    func testPlayerSettingsImportAutoPlayFirstSource() {
        let testProfileId = "test_player_import_\(UUID().uuidString)"
        let store = ProfileSettings.store(for: testProfileId)
        defer {
            store.removeObject(forKey: SettingsKey.smartStreamUseTopResult)
            store.removeObject(forKey: SettingsKey.smartStreamSelection)
        }

        // Import FIRST_STREAM from remote (Android TV / mobile / desktop / website)
        let remoteFirstStream: [String: Any] = [
            PlayerSettingsSyncMapper.streamAutoPlayModeRemoteKey: [
                "type": "string",
                "value": "FIRST_STREAM"
            ]
        ]
        PlayerSettingsSyncMapper.importPayload(
            remoteFirstStream,
            localProfileId: testProfileId,
            decodeValue: { dict in dict["value"] }
        )
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamUseTopResult), true)
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamSelection), true)

        // Import MANUAL from remote (without explicit smart_stream_selection)
        let remoteManual: [String: Any] = [
            PlayerSettingsSyncMapper.streamAutoPlayModeRemoteKey: [
                "type": "string",
                "value": "MANUAL"
            ]
        ]
        PlayerSettingsSyncMapper.importPayload(
            remoteManual,
            localProfileId: testProfileId,
            decodeValue: { dict in dict["value"] }
        )
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamUseTopResult), false)
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamSelection), false)

        // Import MANUAL with explicit tvOS peer smart_stream_selection: true
        let remoteManualWithTvSmart: [String: Any] = [
            PlayerSettingsSyncMapper.streamAutoPlayModeRemoteKey: [
                "type": "string",
                "value": "MANUAL"
            ],
            PlayerSettingsSyncMapper.smartStreamSelectionRemoteKey: [
                "type": "boolean",
                "value": true
            ]
        ]
        PlayerSettingsSyncMapper.importPayload(
            remoteManualWithTvSmart,
            localProfileId: testProfileId,
            decodeValue: { dict in dict["value"] }
        )
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamUseTopResult), false)
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamSelection), true)

        // Legacy fallback: smart_stream_use_top_result without stream_auto_play_mode
        let remoteLegacyFallback: [String: Any] = [
            PlayerSettingsSyncMapper.smartStreamUseTopResultRemoteKey: [
                "type": "boolean",
                "value": true
            ]
        ]
        PlayerSettingsSyncMapper.importPayload(
            remoteLegacyFallback,
            localProfileId: testProfileId,
            decodeValue: { dict in dict["value"] }
        )
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamUseTopResult), true)
        XCTAssertEqual(store.bool(forKey: SettingsKey.smartStreamSelection), true)
    }

    // MARK: - MDBList Settings Sync Tests

    func testMdbListSettingsKeyMappingsCoverage() {
        let localKeys = MdbListSyncMapper.localToRemoteKeyMappings.map(\.local)
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListEnabled))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListApiKey))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListUseImdb))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListUseTmdb))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListUseTomatoes))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListUseMetacritic))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListUseTrakt))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListUseLetterboxd))
        XCTAssertTrue(localKeys.contains(SettingsKey.mdbListUseAudience))

        let remoteKeys = MdbListSyncMapper.remoteToLocalKeyMappings.map(\.remote)
        XCTAssertTrue(remoteKeys.contains("mdblist_enabled"))
        XCTAssertTrue(remoteKeys.contains("mdblist_api_key"))
        XCTAssertTrue(remoteKeys.contains("mdblist_use_imdb"))
        XCTAssertTrue(remoteKeys.contains("mdblist_use_tmdb"))
        XCTAssertTrue(remoteKeys.contains("mdblist_use_tomatoes"))
        XCTAssertTrue(remoteKeys.contains("mdblist_use_metacritic"))
        XCTAssertTrue(remoteKeys.contains("mdblist_use_trakt"))
        XCTAssertTrue(remoteKeys.contains("mdblist_use_letterboxd"))
        XCTAssertTrue(remoteKeys.contains("mdblist_use_audience"))
    }

    // MARK: - Theme / Focus Color Settings Sync Tests

    func testThemeSettingsSyncMapping() {
        // Test Pink / Rose theme mapping
        XCTAssertEqual(ThemeSettingsSyncMapper.themeToWire("Rose"), "ROSE")
        XCTAssertEqual(ThemeSettingsSyncMapper.themeToWire("Pink"), "ROSE")
        XCTAssertEqual(ThemeSettingsSyncMapper.wireToTheme("ROSE"), "Rose")

        // Test Sky / Ocean
        XCTAssertEqual(ThemeSettingsSyncMapper.themeToWire("Sky"), "OCEAN")
        XCTAssertEqual(ThemeSettingsSyncMapper.wireToTheme("OCEAN"), "Sky")

        // Test Emerald
        XCTAssertEqual(ThemeSettingsSyncMapper.themeToWire("Emerald"), "EMERALD")
        XCTAssertEqual(ThemeSettingsSyncMapper.wireToTheme("EMERALD"), "Emerald")

        // Test Amber
        XCTAssertEqual(ThemeSettingsSyncMapper.themeToWire("Amber"), "AMBER")
        XCTAssertEqual(ThemeSettingsSyncMapper.wireToTheme("AMBER"), "Amber")

        // Test Violet
        XCTAssertEqual(ThemeSettingsSyncMapper.themeToWire("Violet"), "VIOLET")
        XCTAssertEqual(ThemeSettingsSyncMapper.wireToTheme("VIOLET"), "Violet")

        // Test White
        XCTAssertEqual(ThemeSettingsSyncMapper.themeToWire("White"), "WHITE")
        XCTAssertEqual(ThemeSettingsSyncMapper.wireToTheme("WHITE"), "White")
    }

    // MARK: - Settings Sync Flush Tests

    @MainActor
    func testSettingsFlushPendingPushesDoesNotCrashWhenUnauthenticated() async {
        let manager = NuvioSyncManager()
        // Calling flush on a manager with no auth/profile should safely complete without throwing or hanging
        await manager.flushPendingPushesNow()
        manager.flushPendingPushes()
    }

    @MainActor
    func testProgressHeartbeatSyncDebounceAndFlush() async {
        XCTAssertEqual(NuvioSyncManager.progressHeartbeatInterval, 30.0)
        XCTAssertEqual(NuvioSyncManager.defaultPushDelay, 1.5)

        let manager = NuvioSyncManager()
        // Multiple rapid progress schedule calls should not crash or throw
        manager.schedulePush(scope: .progress, delay: NuvioSyncManager.progressHeartbeatInterval)
        manager.schedulePush(scope: .progress, delay: NuvioSyncManager.progressHeartbeatInterval)
        // Shorter delay (e.g. settings or immediate flush) accelerates
        manager.schedulePush(scope: .settings, delay: NuvioSyncManager.defaultPushDelay)
        await manager.flushPendingPushesNow()
    }

    @MainActor
    func testRemovalDuringUploadWithDelayedSettingsResponsePreservesDismissalAndSyncs() async {
        let meta = NuvioMeta(id: "tt-dismiss-race-\(UUID().uuidString)", name: "Race Item", type: "series")
        let item = ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 120,
            duration: 1_800,
            lastWatchedAt: Date(),
            season: 1,
            episode: 1
        )
        let profileId = dismissalTestProfileId

        // Initial setup: title is saved and visible in Continue Watching
        ContinueWatchingStore.save(meta: meta, streamUrl: "", position: 120, duration: 1_800)
        XCTAssertFalse(ContinueWatchingDismissStore.isDismissed(item))

        let manager = NuvioSyncManager()

        // 1. Simulate an upload in-flight
        manager.isPushExecuting = true

        // User removes the title while upload is running
        ContinueWatchingDismissStore.dismiss(item)
        ContinueWatchingDismissStore.dismiss(contentId: meta.id)
        XCTAssertTrue(ContinueWatchingDismissStore.isDismissed(item))

        // Removal records settings scope for push
        manager.pendingPushScopes.insert(.settings)

        // Active upload finishes
        manager.isPushExecuting = false

        // 2. Simulate settings pull becoming active (isApplyingRemote = true)
        manager.isApplyingRemote = true

        // While pull is active, uploads must not execute and must stay queued
        await manager.executePendingPushes()
        XCTAssertTrue(manager.isApplyingRemote)
        XCTAssertEqual(manager.pendingPushScopes, [.settings], "Upload must remain queued while a pull is applying")

        // 3. Delayed stale settings pull response arrives without the newly removed marker
        ContinueWatchingDismissStore.reconcileRemoteKeys([], profileId: profileId)

        // Verify the title REMAINS dismissed despite the stale response
        XCTAssertTrue(
            ContinueWatchingDismissStore.isDismissed(item),
            "Title must remain dismissed after receiving a delayed stale settings response"
        )
        let dismissedKeys = ContinueWatchingDismissStore.keys(profileId: profileId)
        XCTAssertFalse(dismissedKeys.isEmpty, "Dismissal keys must not be erased by stale remote response")

        // 4. Remote pull finishes, resuming queued uploads
        manager.isApplyingRemote = false
        manager.resumeQueuedPushesIfIdle()

        // Verify the dismissal eventually syncs to the server
        let exportFeature = ContinueWatchingSyncMapper.exportAndroidTraktFeature(
            existing: nil,
            dismissedKeys: ContinueWatchingDismissStore.keysForExport(profileId: profileId)
        )
        let sentKeys = ContinueWatchingSyncMapper.androidDismissalKeys(from: exportFeature).keys ?? []
        XCTAssertFalse(sentKeys.isEmpty, "Dismissal keys must be exportable to sync")

        ContinueWatchingDismissStore.acknowledgePushedKeys(sentKeys, profileId: profileId)

        // Title remains dismissed after acknowledging upload
        XCTAssertTrue(ContinueWatchingDismissStore.isDismissed(item))

        // Subsequent reconciliation with the newly synced remote keys keeps it dismissed
        ContinueWatchingDismissStore.reconcileRemoteKeys(sentKeys, profileId: profileId)
        XCTAssertTrue(ContinueWatchingDismissStore.isDismissed(item))
    }

    @MainActor
    func testFlushPendingPushesDrainsFollowUpWorkQueuedDuringActiveUpload() async {
        let manager = NuvioSyncManager()
        manager.isPushExecuting = true

        // Queue follow-up work while upload is executing
        manager.pendingPushScopes.insert(.settings)

        // In a background task, simulate the running upload finishing shortly
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms
            manager.isPushExecuting = false
        }

        // flushPendingPushesNow should await the in-flight upload AND drain the queued follow-up work
        await manager.flushPendingPushesNow()

        XCTAssertFalse(manager.isPushExecuting)
        XCTAssertTrue(manager.pendingPushScopes.isEmpty, "Follow-up work queued during active upload must be fully drained")
    }

    @MainActor
    func testFlushPendingPushesReturnsWhenRemoteApplyStartsDuringUploadWait() async {
        let manager = NuvioSyncManager()
        manager.isPushExecuting = true
        manager.pendingPushScopes.insert(.settings)

        let flushTask = Task { @MainActor in
            await manager.flushPendingPushesNow()
        }
        defer {
            flushTask.cancel()
            manager.isApplyingRemote = false
            manager.isPushExecuting = false
            manager.pendingPushScopes = []
        }

        // Let the flush enter its active-upload wait before a pull takes over.
        try? await Task.sleep(nanoseconds: 20_000_000)
        manager.isApplyingRemote = true
        manager.isPushExecuting = false

        let completed = expectation(description: "flush returns after remote apply begins")
        Task { @MainActor in
            await flushTask.value
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1.0)
        XCTAssertEqual(manager.pendingPushScopes, [.settings], "The pull must leave queued scopes for its normal finish path")
    }

    @MainActor
    func testCancelledFlushReturnsWhileUploadRemainsActive() async {
        let manager = NuvioSyncManager()
        manager.isPushExecuting = true
        manager.pendingPushScopes.insert(.settings)

        let flushTask = Task { @MainActor in
            await manager.flushPendingPushesNow()
        }
        defer {
            flushTask.cancel()
            manager.isPushExecuting = false
            manager.pendingPushScopes = []
        }

        // Allow the flush to suspend in its active-upload wait, then cancel it.
        try? await Task.sleep(nanoseconds: 20_000_000)
        flushTask.cancel()

        let completed = expectation(description: "cancelled flush returns")
        Task { @MainActor in
            await flushTask.value
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1.0)
        XCTAssertTrue(manager.isPushExecuting, "Cancellation must not modify the active upload state")
        XCTAssertEqual(manager.pendingPushScopes, [.settings], "Cancellation must preserve queued scopes")
    }

    // MARK: - WatchedStore & Re-watch Tests

    func testWatchedSnapshotWatchedAtWithAliasing() {
        let watchedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let seriesMeta = NuvioMeta(
            id: "tt1234567",
            name: "Test Show",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt1234567",
            tmdbId: 100,
            type: "series",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: []
        )
        let episodeItem = WatchedStoreItem(
            meta: seriesMeta,
            watchedAt: watchedDate,
            season: 1,
            episode: 1,
            sources: [TraktWatchProgressSource.nuvioSync.rawValue]
        )
        let movieMeta = NuvioMeta(
            id: "tt7654321",
            name: "Test Movie",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt7654321",
            tmdbId: 200,
            type: "movie",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: []
        )
        let movieItem = WatchedStoreItem(
            meta: movieMeta,
            watchedAt: watchedDate,
            season: nil,
            episode: nil,
            sources: [TraktWatchProgressSource.nuvioSync.rawValue]
        )

        let snapshot = WatchedSnapshot(items: [episodeItem, movieItem], source: .nuvioSync)

        // Exact match
        XCTAssertEqual(snapshot.watchedAt(metaId: "tt1234567", season: 1, episode: 1), watchedDate)
        // Alias match with imdb prefix
        XCTAssertEqual(snapshot.watchedAt(metaId: "imdb:tt1234567", season: 1, episode: 1), watchedDate)
        // Different episode returns nil
        XCTAssertNil(snapshot.watchedAt(metaId: "tt1234567", season: 1, episode: 2))

        // Movie match
        XCTAssertEqual(snapshot.watchedAt(metaId: "tt7654321"), watchedDate)
        XCTAssertEqual(snapshot.watchedAt(metaId: "imdb:tt7654321"), watchedDate)
        XCTAssertNil(snapshot.watchedAt(metaId: "tt9999999"))
    }

    func testContinueWatchingCandidatesAllowsRewatchingAfterWatchedStoreMark() {
        let movieMeta = NuvioMeta(
            id: "tt8888888",
            name: "Rewatch Movie",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt8888888",
            tmdbId: 300,
            type: "movie",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: []
        )

        let seriesMeta = NuvioMeta(
            id: "tt8888889",
            name: "Rewatch Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt8888889",
            tmdbId: 301,
            type: "series",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: []
        )

        let movieKey = WatchProgressLedger.progressKey(contentId: movieMeta.id, season: nil, episode: nil)
        let episodeKey = WatchProgressLedger.progressKey(contentId: seriesMeta.id, season: 1, episode: 1)

        defer {
            _ = WatchProgressLedger.remove(keys: [movieKey, episodeKey])
            if WatchedStore.contains(meta: movieMeta) {
                _ = WatchedStore.toggle(meta: movieMeta)
            }
            if WatchedStore.containsEpisode(meta: seriesMeta, season: 1, episode: 1) {
                _ = WatchedStore.toggleEpisode(meta: seriesMeta, season: 1, episode: 1)
            }
        }

        // Mark both as watched now
        XCTAssertTrue(WatchedStore.markWatched(movieMeta))
        XCTAssertTrue(WatchedStore.markWatched(seriesMeta, season: 1, episode: 1))

        guard let movieWatchedAt = WatchedStore.watchedAt(meta: movieMeta),
              let episodeWatchedAt = WatchedStore.watchedAt(meta: seriesMeta, season: 1, episode: 1) else {
            XCTFail("Watched dates should be recorded")
            return
        }

        // 1. Progress recorded BEFORE the watched mark must NOT be offered as a candidate
        let oldMovieRecord = WatchProgressRecord(
            progressKey: movieKey,
            contentId: movieMeta.id,
            contentType: movieMeta.type,
            videoId: movieMeta.id,
            season: nil,
            episode: nil,
            position: 300,
            duration: 1000,
            lastWatchedAt: movieWatchedAt.addingTimeInterval(-60),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(oldMovieRecord)
        XCTAssertFalse(WatchProgressLedger.continueWatchingCandidates().contains { $0.contentId == movieMeta.id })

        let oldEpisodeRecord = WatchProgressRecord(
            progressKey: episodeKey,
            contentId: seriesMeta.id,
            contentType: seriesMeta.type,
            videoId: "\(seriesMeta.id):1:1",
            season: 1,
            episode: 1,
            position: 300,
            duration: 1000,
            lastWatchedAt: episodeWatchedAt.addingTimeInterval(-60),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(oldEpisodeRecord)
        XCTAssertFalse(WatchProgressLedger.continueWatchingCandidates().contains { $0.contentId == seriesMeta.id })

        // 2. Progress recorded AFTER the watched mark (re-watch) MUST be offered as a candidate
        let newMovieRecord = WatchProgressRecord(
            progressKey: movieKey,
            contentId: movieMeta.id,
            contentType: movieMeta.type,
            videoId: movieMeta.id,
            season: nil,
            episode: nil,
            position: 300,
            duration: 1000,
            lastWatchedAt: movieWatchedAt.addingTimeInterval(60),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(newMovieRecord)
        XCTAssertTrue(WatchProgressLedger.continueWatchingCandidates().contains { $0.contentId == movieMeta.id })

        let newEpisodeRecord = WatchProgressRecord(
            progressKey: episodeKey,
            contentId: seriesMeta.id,
            contentType: seriesMeta.type,
            videoId: "\(seriesMeta.id):1:1",
            season: 1,
            episode: 1,
            position: 300,
            duration: 1000,
            lastWatchedAt: episodeWatchedAt.addingTimeInterval(60),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(newEpisodeRecord)
        XCTAssertTrue(WatchProgressLedger.continueWatchingCandidates().contains { $0.contentId == seriesMeta.id })
    }

    func testContinueWatchingCandidatesDropOlderEpisodeAfterNewerCompletion() {
        let contentId = "tt-cw-completed-latest-\(UUID().uuidString)"
        let profileId = "cw-completed-latest-\(UUID().uuidString)"
        let previousProfileId = WatchProgressLedger.activeProfileId
        WatchProgressLedger.setActiveProfile(profileId)
        defer {
            WatchProgressLedger.eraseProfile(profileId)
            WatchProgressLedger.setActiveProfile(previousProfileId)
        }

        let now = Date()
        let olderPartial = makeEpisodeProgress(
            contentId: contentId,
            season: 1,
            episode: 8,
            position: 300,
            lastWatchedAt: now.addingTimeInterval(-120)
        )
        let latestCompleted = makeEpisodeProgress(
            contentId: contentId,
            season: 1,
            episode: 10,
            position: 950,
            lastWatchedAt: now.addingTimeInterval(-60)
        )
        _ = WatchProgressLedger.upsert(olderPartial)
        _ = WatchProgressLedger.upsert(latestCompleted)

        XCTAssertTrue(WatchProgressLedger.isComplete(latestCompleted))
        XCTAssertFalse(
            WatchProgressLedger.continueWatchingCandidates().contains { $0.contentId == contentId },
            "A completed later episode must prevent an older partial episode from resurfacing"
        )
    }

    func testContinueWatchingCandidatesKeepNewerEarlierEpisodeRewatch() {
        let contentId = "tt-cw-earlier-rewatch-\(UUID().uuidString)"
        let profileId = "cw-earlier-rewatch-\(UUID().uuidString)"
        let previousProfileId = WatchProgressLedger.activeProfileId
        WatchProgressLedger.setActiveProfile(profileId)
        defer {
            WatchProgressLedger.eraseProfile(profileId)
            WatchProgressLedger.setActiveProfile(previousProfileId)
        }

        let now = Date()
        let completedEpisode10 = makeEpisodeProgress(
            contentId: contentId,
            season: 1,
            episode: 10,
            position: 950,
            lastWatchedAt: now.addingTimeInterval(-120)
        )
        let rewatchedEpisode8 = makeEpisodeProgress(
            contentId: contentId,
            season: 1,
            episode: 8,
            position: 300,
            lastWatchedAt: now.addingTimeInterval(-30)
        )
        _ = WatchProgressLedger.upsert(completedEpisode10)
        _ = WatchProgressLedger.upsert(rewatchedEpisode8)

        let candidate = WatchProgressLedger.continueWatchingCandidates()
            .first { $0.contentId == contentId }
        XCTAssertEqual(candidate?.progressKey, rewatchedEpisode8.progressKey)
    }

    func testOlderWatchedMarkDoesNotTurnNewerPartialRewatchIntoSeed() {
        let contentId = "tt-cw-rewatch-seed-\(UUID().uuidString)"
        let profileId = "cw-rewatch-seed-\(UUID().uuidString)"
        let previousWatchedProfileId = WatchedStore.activeProfileId
        let previousProgressProfileId = WatchProgressLedger.activeProfileId
        WatchedStore.setActiveProfile(profileId)
        WatchProgressLedger.setActiveProfile(profileId)
        defer {
            WatchedStore.eraseProfile(profileId)
            WatchProgressLedger.eraseProfile(profileId)
            WatchedStore.setActiveProfile(previousWatchedProfileId)
            WatchProgressLedger.setActiveProfile(previousProgressProfileId)
        }

        let meta = NuvioMeta(id: contentId, name: "Rewatch seed", type: "series")
        let watchedAt = Date().addingTimeInterval(-60)
        WatchedStore.replaceAll([
            WatchedStoreItem(
                meta: meta,
                watchedAt: watchedAt,
                season: 1,
                episode: 8
            )
        ])
        guard let persistedWatchedAt = WatchedStore.watchedAt(
            metaId: contentId,
            season: 1,
            episode: 8
        ) else {
            XCTFail("The watched episode should be readable from the isolated profile")
            return
        }
        let rewatch = makeEpisodeProgress(
            contentId: contentId,
            season: 1,
            episode: 8,
            position: 300,
            lastWatchedAt: persistedWatchedAt.addingTimeInterval(30)
        )
        _ = WatchProgressLedger.upsert(rewatch)

        let candidates = WatchProgressLedger.continueWatchingCandidates()
        XCTAssertEqual(candidates.first { $0.contentId == contentId }?.progressKey, rewatch.progressKey)
        XCTAssertFalse(WatchProgressLedger.upNextSeeds().contains { $0.progressKey == rewatch.progressKey })
        let plan = ContinueWatchingBuilder.planEntries(
            candidates: candidates,
            seeds: WatchProgressLedger.upNextSeeds()
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.record.progressKey, rewatch.progressKey)
        XCTAssertEqual(plan.first?.isSeed, false)

        let equalTimestampProgress = makeEpisodeProgress(
            contentId: contentId,
            season: 1,
            episode: 8,
            position: 300,
            lastWatchedAt: persistedWatchedAt
        )
        _ = WatchProgressLedger.upsert(equalTimestampProgress)
        XCTAssertTrue(
            WatchProgressLedger.upNextSeeds().contains { $0.progressKey == equalTimestampProgress.progressKey },
            "A watched mark at the same timestamp still seeds the completed episode"
        )
    }

    func testPlanEntriesPreferNewerWatchedOnlySeedOverOlderEpisodeResume() {
        let contentId = "tt-cw-watched-only-seed-\(UUID().uuidString)"
        let profileId = "cw-watched-only-seed-\(UUID().uuidString)"
        let previousProfileId = WatchedStore.activeProfileId
        defer {
            WatchedStore.eraseProfile(profileId)
            WatchedStore.setActiveProfile(previousProfileId)
        }

        let meta = NuvioMeta(id: contentId, name: "Watched only seed", type: "series")
        let watchedAt = Date()
        WatchedStore.replaceAll([
            WatchedStoreItem(
                meta: meta,
                watchedAt: watchedAt,
                season: 1,
                episode: 10
            )
        ], profileId: profileId)
        WatchedStore.setActiveProfile(profileId)

        let olderResume = makeEpisodeProgress(
            contentId: contentId,
            season: 1,
            episode: 8,
            position: 300,
            lastWatchedAt: watchedAt.addingTimeInterval(-60)
        )
        let watchedOnlySeed = ContinueWatchingBuilder.watchedHistorySeeds()
            .first { $0.contentId == contentId }
        XCTAssertEqual(watchedOnlySeed?.episode, 10)
        guard let watchedOnlySeed else {
            XCTFail("The WatchedStore-only episode should produce a history seed")
            return
        }

        let plan = ContinueWatchingBuilder.planEntries(
            candidates: [olderResume],
            seeds: [watchedOnlySeed]
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.record.episode, 10)
        XCTAssertEqual(plan.first?.isSeed, true)

        let equalTimestampPlan = ContinueWatchingBuilder.planEntries(
            candidates: [makeEpisodeProgress(
                contentId: contentId,
                season: 1,
                episode: 8,
                position: 300,
                lastWatchedAt: watchedAt
            )],
            seeds: [watchedOnlySeed]
        )
        XCTAssertEqual(equalTimestampPlan.first?.isSeed, true)
    }

    func testResolvedSeedKeepsCachedUpNextOnlyWhenItIsAfterCurrentEpisode() {
        let meta = NuvioMeta(id: "tt-cw-cached-up-next-\(UUID().uuidString)", name: "Cached Up Next", type: "series")
        let staleCachedFinale = ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: Date(),
            season: 1,
            episode: 8,
            isUpNext: true
        )
        let futureCachedEpisode = ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: Date(),
            season: 1,
            episode: 11,
            isUpNext: true
        )

        XCTAssertFalse(
            ContinueWatchingBuilder.shouldKeepCachedUpNext(staleCachedFinale, after: (season: 1, episode: 10)),
            "A cached suggestion at or before the resolved seed must be discarded"
        )
        XCTAssertTrue(
            ContinueWatchingBuilder.shouldKeepCachedUpNext(futureCachedEpisode, after: (season: 1, episode: 10)),
            "A cached episode beyond the resolved seed remains a valid fallback"
        )
        XCTAssertFalse(ContinueWatchingBuilder.shouldKeepCachedUpNext(futureCachedEpisode, after: nil))
    }

    func testHomeMergeExcludesRemovedPersistedItemAndLetsStoreWin() {
        let now = Date()
        let persistedMeta = NuvioMeta(id: "tt-cw-persisted-\(UUID().uuidString)", name: "Persisted", type: "series")
        let updatedMeta = NuvioMeta(id: "tt-cw-updated-\(UUID().uuidString)", name: "Updated", type: "series")
        let memoryOnlyMeta = NuvioMeta(id: "tt-cw-memory-only-\(UUID().uuidString)", name: "Memory only", type: "series")
        let originallyPersisted = ContinueWatchingItem(
            meta: persistedMeta,
            streamUrl: "",
            position: 300,
            duration: 1_000,
            lastWatchedAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            season: 1,
            episode: 8
        )
        let staleMemoryOnlyValue = ContinueWatchingItem(
            meta: updatedMeta,
            streamUrl: "",
            position: 300,
            duration: 1_000,
            lastWatchedAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
            season: 1,
            episode: 8
        )
        let currentStoreValue = ContinueWatchingItem(
            meta: updatedMeta,
            streamUrl: "",
            position: 400,
            duration: 1_000,
            lastWatchedAt: now,
            season: 1,
            episode: 9
        )
        let releaseFormatter = DateFormatter()
        releaseFormatter.calendar = Calendar(identifier: .gregorian)
        releaseFormatter.timeZone = .current
        releaseFormatter.dateFormat = "yyyy-MM-dd"
        let recentRelease = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let highRecencyMemoryOnly = ContinueWatchingItem(
            meta: memoryOnlyMeta,
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
            season: 1,
            episode: 2,
            released: releaseFormatter.string(from: recentRelease),
            isUpNext: true,
            upNextSeedSeason: 1
        )

        let memoryOnlyItems = ContinueWatchingBuilder.memoryOnlyItems(
            from: [originallyPersisted, staleMemoryOnlyValue, highRecencyMemoryOnly],
            persistedItemIDs: [persistedMeta.id]
        )
        XCTAssertFalse(memoryOnlyItems.contains { $0.meta.id == persistedMeta.id })
        XCTAssertGreaterThan(highRecencyMemoryOnly.recencySortDate, originallyPersisted.recencySortDate)

        let merged = ContinueWatchingBuilder.mergeMemoryOnlyItems(
            memoryOnlyItems,
            with: [currentStoreValue]
        )
        XCTAssertFalse(merged.contains { $0.meta.id == persistedMeta.id }, "A removed first-page card must not reappear from memory")
        XCTAssertEqual(merged.first { $0.meta.id == updatedMeta.id }?.episode, 9, "The current store value must override a stale memory-only card")
        XCTAssertTrue(merged.contains { $0.meta.id == memoryOnlyMeta.id }, "A later page remains visible even when recency sorting changes its position")
    }

    // MARK: - Issue #138 Autoplay and Unmark Regressions

    func testUnmarkingEpisodeRetiresCompletedLedgerRowsAndPreservesPartialResume() {
        let seriesMeta = NuvioMeta(
            id: "tt9999001",
            name: "Unmark Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt9999001",
            tmdbId: 401,
            type: "series",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [
                NuvioVideo(id: "tt9999001:1:1", title: "E1", season: 1, episode: 1),
                NuvioVideo(id: "tt9999001:1:2", title: "E2", season: 1, episode: 2),
                NuvioVideo(id: "tt9999001:1:3", title: "E3", season: 1, episode: 3)
            ]
        )

        let ep1Key = WatchProgressLedger.progressKey(contentId: seriesMeta.id, season: 1, episode: 1)
        let ep2Key = WatchProgressLedger.progressKey(contentId: seriesMeta.id, season: 1, episode: 2)

        defer {
            _ = WatchProgressLedger.remove(keys: [ep1Key, ep2Key])
            _ = WatchedStore.removeEpisode(meta: seriesMeta, season: 1, episode: 1)
            _ = WatchedStore.removeEpisode(meta: seriesMeta, season: 1, episode: 2)
        }

        // Ep 1 is completed (>= 90% progress)
        let ep1CompletedRecord = WatchProgressRecord(
            progressKey: ep1Key,
            contentId: seriesMeta.id,
            contentType: seriesMeta.type,
            videoId: "tt9999001:1:1",
            season: 1,
            episode: 1,
            position: 950,
            duration: 1000,
            lastWatchedAt: Date().addingTimeInterval(-100),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(ep1CompletedRecord)
        XCTAssertTrue(WatchProgressLedger.isComplete(ep1CompletedRecord))

        // Ep 2 is partial (< 90% progress)
        let ep2PartialRecord = WatchProgressRecord(
            progressKey: ep2Key,
            contentId: seriesMeta.id,
            contentType: seriesMeta.type,
            videoId: "tt9999001:1:2",
            season: 1,
            episode: 2,
            position: 300,
            duration: 1000,
            lastWatchedAt: Date().addingTimeInterval(-50),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(ep2PartialRecord)
        XCTAssertFalse(WatchProgressLedger.isComplete(ep2PartialRecord))

        // Mark Ep 1 watched in WatchedStore
        XCTAssertTrue(WatchedStore.markWatched(seriesMeta, season: 1, episode: 1))
        XCTAssertTrue(WatchedStore.containsEpisode(meta: seriesMeta, season: 1, episode: 1))

        // Ep 1 is a seed for Next Up
        let seedsBefore = WatchProgressLedger.upNextSeeds()
        XCTAssertTrue(seedsBefore.contains { $0.contentId == seriesMeta.id && $0.season == 1 && $0.episode == 1 })

        // Now unmark Ep 1
        XCTAssertTrue(WatchedStore.removeEpisode(meta: seriesMeta, season: 1, episode: 1))
        XCTAssertFalse(WatchedStore.containsEpisode(meta: seriesMeta, season: 1, episode: 1))

        // Ep 1's completed record should be retired from the ledger
        let ep1RecordAfter = WatchProgressLedger.record(forKey: ep1Key)
        XCTAssertNil(ep1RecordAfter, "Completed ledger row should be retired when unmarking episode")

        // Ep 2's partial resume record must be preserved
        let ep2RecordAfter = WatchProgressLedger.record(forKey: ep2Key)
        XCTAssertNotNil(ep2RecordAfter, "Partial resume record must be preserved when unmarking episode")
        XCTAssertEqual(ep2RecordAfter?.position, 300)

        // Ep 1 should no longer be an upNextSeed
        let seedsAfter = WatchProgressLedger.upNextSeeds()
        XCTAssertFalse(seedsAfter.contains { $0.contentId == seriesMeta.id && $0.season == 1 && $0.episode == 1 }, "Unmarked episode must not remain an upNextSeed")
    }

    @MainActor
    func testAetherPlaybackControllerAwaitingEngineLoadReportsZeroClockAndNoFirstFrame() {
        guard let controller = AetherPlaybackController() else {
            return
        }
        defer { controller.destroyPlayer() }

        let request = PlaybackLoadRequest(
            videoURL: URL(string: "http://example.com/video.mp4")!,
            streamName: "Test Episode",
            streamDescription: "S1:E2"
        )

        controller.load(request, generation: 1)

        // Immediately after load() is initiated, controller must report loading with zero clock and no first frame
        XCTAssertTrue(controller.isPlayerLoading)
        XCTAssertFalse(controller.isPlayerEnded)
        XCTAssertFalse(controller.isAtEndOfFile)
        XCTAssertFalse(controller.hasFirstFrameReadyForDisplay)
        XCTAssertFalse(controller.isTransportPlaying)
        XCTAssertEqual(controller.positionMs, 0)
        XCTAssertEqual(controller.durationMs, 0)
        XCTAssertFalse(controller.hasCoherentTimeSample)

        // refreshPlaybackState() while awaiting load must also keep loading and zero clock
        controller.refreshPlaybackState()
        XCTAssertTrue(controller.isPlayerLoading)
        XCTAssertFalse(controller.isPlayerEnded)
        XCTAssertFalse(controller.hasFirstFrameReadyForDisplay)
        XCTAssertEqual(controller.positionMs, 0)
    }

    func testDelayedSyncForProfileACannotModifyProfileBAfterProfileSwitch() {
        let restoreRemoteSettings = disableRemoteWatchedSyncForTest()
        let profileA = "profile-a-\(UUID().uuidString)"
        let profileB = "profile-b-\(UUID().uuidString)"
        let previousWatchedProfile = WatchedStore.activeProfileId
        let previousProgressProfile = WatchProgressLedger.activeProfileId
        let unscopedWatchedBefore = WatchedStore.items(profileId: nil)
        defer {
            WatchedStore.eraseProfile(profileA)
            WatchedStore.eraseProfile(profileB)
            WatchProgressLedger.eraseProfile(profileA)
            WatchProgressLedger.eraseProfile(profileB)
            WatchedStore.setActiveProfile(previousWatchedProfile)
            WatchedStore.replaceAll(unscopedWatchedBefore, profileId: nil)
            WatchProgressLedger.setActiveProfile(previousProgressProfile)
            restoreRemoteSettings()
        }

        // Set up Profile B as active
        WatchedStore.setActiveProfile(profileB)
        WatchProgressLedger.setActiveProfile(profileB)

        let metaB = NuvioMeta(id: "tt_item_b_\(UUID().uuidString)", name: "Movie B", type: "movie")
        _ = WatchedStore.markWatched(metaB)

        let recordB = WatchProgressRecord(
            progressKey: metaB.id,
            contentId: metaB.id,
            contentType: "movie",
            videoId: metaB.id,
            season: nil,
            episode: nil,
            position: 500,
            duration: 1000,
            lastWatchedAt: Date(),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(recordB)

        XCTAssertEqual(WatchedStore.items().map(\.meta.id), [metaB.id])
        XCTAssertEqual(WatchedStore.items(profileId: profileB).map(\.meta.id), [metaB.id])
        XCTAssertEqual(WatchProgressLedger.records().map(\.contentId), [metaB.id])

        // Simulate delayed sync for Profile A finishing while Profile B is active
        let syncStartedAt = Date().addingTimeInterval(-10)
        let metaA = NuvioMeta(id: "tt_item_a_\(UUID().uuidString)", name: "Movie A", type: "movie")
        let itemA = WatchedStoreItem(
            meta: metaA,
            watchedAt: syncStartedAt,
            sources: [TraktWatchProgressSource.nuvioSync.rawValue]
        )
        let recordA = WatchProgressRecord(
            progressKey: metaA.id,
            contentId: metaA.id,
            contentType: "movie",
            videoId: metaA.id,
            season: nil,
            episode: nil,
            position: 250,
            duration: 1000,
            lastWatchedAt: syncStartedAt,
            isPendingPush: false
        )

        // Perform reconcile with profileId: profileA
        let watchedResult = WatchedStore.reconcileNuvioSnapshot([itemA], syncStartedAt: syncStartedAt, profileId: profileA)
        XCTAssertTrue(watchedResult)

        let progressResult = WatchProgressLedger.reconcileRemote([recordA], syncStartedAt: syncStartedAt, profileId: profileA)
        XCTAssertTrue(progressResult.saved)

        // Verify Profile B remains completely untouched
        XCTAssertEqual(WatchedStore.items().map(\.meta.id), [metaB.id])
        XCTAssertEqual(WatchedStore.items(profileId: profileB).map(\.meta.id), [metaB.id])
        XCTAssertEqual(WatchProgressLedger.records().map(\.contentId), [metaB.id])

        // Verify Profile A received its synced items
        XCTAssertEqual(WatchedStore.items(profileId: profileA).map(\.meta.id), [metaA.id])
        XCTAssertEqual(WatchProgressLedger.records(profileId: profileA).map(\.contentId), [metaA.id])
    }

    func testImplicitWatchedOperationsUseActiveProfileAndKeepExplicitNilUnscoped() {
        let restoreRemoteSettings = disableRemoteWatchedSyncForTest()
        let profileA = "watched-implicit-a-\(UUID().uuidString)"
        let profileB = "watched-implicit-b-\(UUID().uuidString)"
        let previousProfile = WatchedStore.activeProfileId
        let unscopedItemsBefore = WatchedStore.items(profileId: nil)
        let unscopedTombstonesBefore = WatchedStore.tombstones(profileId: nil)
        defer {
            WatchedStore.eraseProfile(profileA)
            WatchedStore.eraseProfile(profileB)
            WatchedStore.setActiveProfile(previousProfile)
            WatchedStore.replaceAll(unscopedItemsBefore, profileId: nil)
            restoreRemoteSettings()
        }

        let existingB = NuvioMeta(id: "tt_existing_b_\(UUID().uuidString)", name: "Existing B", type: "movie")
        WatchedStore.replaceAll([
            WatchedStoreItem(meta: existingB, watchedAt: Date(), sources: [])
        ], profileId: profileB)
        WatchedStore.setActiveProfile(profileA)

        let markedA = NuvioMeta(id: "tt_marked_a_\(UUID().uuidString)", name: "Marked A", type: "movie")
        XCTAssertTrue(WatchedStore.markWatched(markedA))
        XCTAssertEqual(WatchedStore.items().map(\.meta.id), [markedA.id])
        XCTAssertEqual(WatchedStore.items(profileId: profileA).map(\.meta.id), [markedA.id])
        XCTAssertEqual(WatchedStore.items(profileId: profileB).map(\.meta.id), [existingB.id])
        XCTAssertEqual(WatchedStore.items(profileId: nil), unscopedItemsBefore)
        XCTAssertTrue(WatchedStore.currentSnapshot().contains(metaId: markedA.id, type: markedA.canonicalType))

        let removedA = NuvioMeta(id: "tt_removed_a_\(UUID().uuidString)", name: "Removed A", type: "movie")
        XCTAssertTrue(WatchedStore.markWatched(removedA))
        XCTAssertTrue(WatchedStore.remove(meta: removedA))
        XCTAssertTrue(WatchedStore.tombstones().contains { $0.metaId == removedA.id })
        XCTAssertTrue(WatchedStore.tombstones(profileId: profileA).contains { $0.metaId == removedA.id })
        XCTAssertEqual(WatchedStore.tombstones(profileId: nil), unscopedTombstonesBefore)
        XCTAssertEqual(WatchedStore.items(profileId: profileB).map(\.meta.id), [existingB.id])
    }

    func testBackgroundWatchedReconciliationAllowsMainQueueObserverReentry() async {
        let profile = "watched-observer-\(UUID().uuidString)"
        let previousProfile = WatchedStore.activeProfileId
        WatchedStore.eraseProfile(profile)
        WatchedStore.setActiveProfile(profile)
        let probe = WatchedStoreReconciliationProbe()
        let reconciliationCompleted = expectation(description: "watched reconciliation completes")
        let observerCompleted = expectation(description: "main queue observer reenters WatchedStore")
        let observer = NotificationCenter.default.addObserver(
            forName: WatchedStore.changedNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard probe.beginObserverDelivery() else { return }
            let reentryCompleted = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = WatchedStore.items()
                reentryCompleted.signal()
            }
            // Bound the observer wait: on a lock inversion this lets the
            // notification return, releasing the store lock for the reentry.
            let completed = reentryCompleted.wait(timeout: .now() + .milliseconds(250)) == .success
            probe.recordReentryCompleted(completed)
            observerCompleted.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            WatchedStore.eraseProfile(profile)
            WatchedStore.setActiveProfile(previousProfile)
        }

        let item = WatchedStoreItem(
            meta: NuvioMeta(id: "tt_observer_\(UUID().uuidString)", name: "Observer", type: "movie"),
            watchedAt: Date(),
            sources: []
        )
        DispatchQueue.global(qos: .userInitiated).async {
            probe.recordReconciliationSucceeded(
                WatchedStore.reconcileNuvioSnapshot([item], syncStartedAt: Date())
            )
            reconciliationCompleted.fulfill()
        }

        await fulfillment(of: [reconciliationCompleted, observerCompleted], timeout: 2.0)
        XCTAssertTrue(probe.reconciliationSucceeded)
        XCTAssertTrue(probe.reentryCompleted, "The observer should read the store after reconciliation releases its cache lock")
    }

    @MainActor
    func testWatchedProfileAReconciliationCannotRemoveProfileBContinueWatching() async throws {
        let restoreRemoteSettings = disableRemoteWatchedSyncForTest()
        let profileA = "watched-cw-a-\(UUID().uuidString)"
        let profileB = "watched-cw-b-\(UUID().uuidString)"
        let previousWatchedProfile = WatchedStore.activeProfileId
        let previousContinueWatchingProfile = ContinueWatchingStore.activeProfileId
        let previousProgressProfile = WatchProgressLedger.activeProfileId
        defer {
            ContinueWatchingStore.eraseProfile(profileA)
            ContinueWatchingStore.eraseProfile(profileB)
            WatchedStore.eraseProfile(profileA)
            WatchedStore.eraseProfile(profileB)
            ContinueWatchingStore.setActiveProfile(previousContinueWatchingProfile)
            WatchedStore.setActiveProfile(previousWatchedProfile)
            WatchProgressLedger.setActiveProfile(previousProgressProfile)
            restoreRemoteSettings()
        }

        // Profile switching updates Continue Watching before WatchedStore.
        ContinueWatchingStore.setActiveProfile(profileB)
        WatchedStore.setActiveProfile(profileA)
        let sharedTitle = NuvioMeta(
            id: "tt_shared_cw_\(UUID().uuidString)",
            name: "Shared title",
            type: "movie"
        )
        ContinueWatchingStore.save(
            meta: sharedTitle,
            streamUrl: "test://profile-b",
            position: 120,
            duration: 1_800
        )
        let profileBLedgerBefore = WatchProgressLedger.records(profileId: profileB)
            .filter { $0.contentId == sharedTitle.id }
        XCTAssertEqual(ContinueWatchingStore.items().map(\.meta.id), [sharedTitle.id])
        XCTAssertEqual(profileBLedgerBefore.count, 1)

        let remoteA = WatchedStoreItem(
            meta: sharedTitle,
            watchedAt: Date().addingTimeInterval(30),
            sources: [TraktWatchProgressSource.nuvioSync.rawValue]
        )
        XCTAssertTrue(WatchedStore.reconcileNuvioSnapshot(
            [remoteA],
            syncStartedAt: Date().addingTimeInterval(60),
            profileId: profileA
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(WatchedStore.items(profileId: profileA).map(\.meta.id), [sharedTitle.id])
        XCTAssertEqual(ContinueWatchingStore.activeProfileId, profileB)
        XCTAssertEqual(ContinueWatchingStore.items().map(\.meta.id), [sharedTitle.id])
        XCTAssertEqual(
            WatchProgressLedger.records(profileId: profileB).filter { $0.contentId == sharedTitle.id },
            profileBLedgerBefore
        )

        // The removal/retirement path has the same split active-profile window.
        // No completed Profile A ledger row is needed to exercise its CW cleanup.
        WatchedStore.retireCompletedLedgerRows(meta: sharedTitle, profileId: profileA)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ContinueWatchingStore.items().map(\.meta.id), [sharedTitle.id])
        XCTAssertEqual(
            WatchProgressLedger.records(profileId: profileB).filter { $0.contentId == sharedTitle.id },
            profileBLedgerBefore
        )
    }

    func testConcurrentPlaybackSavesSurviveReconciliation() async {
        let testProfile = "profile-concurrent-\(UUID().uuidString)"
        defer {
            WatchedStore.eraseProfile(testProfile)
            WatchProgressLedger.eraseProfile(testProfile)
            WatchedStore.setActiveProfile(previousDismissalProfileId)
            WatchProgressLedger.setActiveProfile(previousDismissalProfileId)
        }

        WatchedStore.setActiveProfile(testProfile)
        WatchProgressLedger.setActiveProfile(testProfile)

        // Seed initial progress
        let initialRecord = WatchProgressRecord(
            progressKey: "tt_base",
            contentId: "tt_base",
            contentType: "movie",
            videoId: "tt_base",
            season: nil,
            episode: nil,
            position: 100,
            duration: 1000,
            lastWatchedAt: Date().addingTimeInterval(-60),
            isPendingPush: false
        )
        _ = WatchProgressLedger.upsert(initialRecord, profileId: testProfile)

        let syncStartedAt = Date()

        // Run concurrent reconciliation and playback saves
        await withTaskGroup(of: Void.self) { group in
            // Reconcile task
            group.addTask {
                for i in 0..<10 {
                    let remoteItem = WatchProgressRecord(
                        progressKey: "tt_remote_\(i)",
                        contentId: "tt_remote_\(i)",
                        contentType: "movie",
                        videoId: "tt_remote_\(i)",
                        season: nil,
                        episode: nil,
                        position: 300,
                        duration: 1000,
                        lastWatchedAt: syncStartedAt.addingTimeInterval(Double(-i)),
                        isPendingPush: false
                    )
                    _ = WatchProgressLedger.reconcileRemote([remoteItem], syncStartedAt: syncStartedAt, profileId: testProfile)
                }
            }

            // Playback save task (newer progress)
            group.addTask {
                for i in 0..<10 {
                    let playbackRecord = WatchProgressRecord(
                        progressKey: "tt_playback_\(i)",
                        contentId: "tt_playback_\(i)",
                        contentType: "movie",
                        videoId: "tt_playback_\(i)",
                        season: nil,
                        episode: nil,
                        position: 800,
                        duration: 1000,
                        lastWatchedAt: Date(),
                        isPendingPush: true
                    )
                    _ = WatchProgressLedger.upsert(playbackRecord, profileId: testProfile)
                }
            }
        }

        let finalRecords = WatchProgressLedger.records(profileId: testProfile)
        // All playback records must survive
        for i in 0..<10 {
            let key = "tt_playback_\(i)"
            XCTAssertTrue(finalRecords.contains { $0.progressKey == key }, "Playback record \(key) must survive concurrent reconciliation")
        }
    }
}
