import XCTest
@testable import NuvioTV

final class ContinueWatchingAndPlayerSyncTests: XCTestCase {

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
        let existingPayload = """
        {
            "isVisible": false,
            "style": "Poster",
            "use_episode_thumbnails_in_cw": false,
            "blur_continue_watching_next_up": true,
            "dismissedNextUpKeys": ["tt1234567|1|1", "tt7654321|2|3"],
            "showResumePromptOnLaunch": false,
            "sort_mode": "DEFAULT"
        }
        """

        let payload = ContinueWatchingSyncMapper.exportPayload(
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

    func testContinueWatchingImportPayload() {
        let remoteJson = """
        {
            "upNextFromFurthestEpisode": false,
            "show_unaired_next_up": false,
            "sort_mode": "STREAMING_STYLE",
            "dismissedNextUpKeys": ["tt1234567|1|1"]
        }
        """

        let (upNext, showUnaired, sortMode, dismissedKeys) = ContinueWatchingSyncMapper.importPayload(remoteJson)
        XCTAssertEqual(upNext, false)
        XCTAssertEqual(showUnaired, false)
        XCTAssertEqual(sortMode, "Streaming Style")
        XCTAssertEqual(dismissedKeys, ["tt1234567|1|1"])
    }

    // MARK: - Player Settings Sync Tests

    func testPlayerSettingsKeyMappingsCoverage() {
        let localKeys = PlayerSettingsSyncMapper.localToRemoteKeyMappings.map(\.local)
        XCTAssertTrue(localKeys.contains(SettingsKey.audioLanguage))
        XCTAssertTrue(localKeys.contains(SettingsKey.subtitleLanguage))
        XCTAssertTrue(localKeys.contains(SettingsKey.subtitleLanguageSecondary))
        XCTAssertTrue(localKeys.contains(SettingsKey.forcedSubtitles))
        XCTAssertTrue(localKeys.contains(SettingsKey.autoPlayNext))
        XCTAssertTrue(localKeys.contains(SettingsKey.autoPlayNextCountdown))
        XCTAssertTrue(localKeys.contains(SettingsKey.cachedOnlyStreams))
        XCTAssertTrue(localKeys.contains(SettingsKey.streamSortOption))
        XCTAssertTrue(localKeys.contains(SettingsKey.smartStreamSelection))
        XCTAssertTrue(localKeys.contains(SettingsKey.smartStreamQuality))
        XCTAssertTrue(localKeys.contains(SettingsKey.externalPlayerForwardSubtitles))
        XCTAssertTrue(localKeys.contains(SettingsKey.frameRateMatching))
        XCTAssertTrue(localKeys.contains(SettingsKey.playerShowPiP))
        XCTAssertTrue(localKeys.contains(SettingsKey.playerShowEpisodes))
        XCTAssertTrue(localKeys.contains(SettingsKey.playerShowSources))

        let remoteKeys = PlayerSettingsSyncMapper.remoteToLocalKeyMappings.map(\.remote)
        XCTAssertTrue(remoteKeys.contains("preferred_audio_language"))
        XCTAssertTrue(remoteKeys.contains("preferred_subtitle_language"))
        XCTAssertTrue(remoteKeys.contains("secondary_preferred_subtitle_language"))
        XCTAssertTrue(remoteKeys.contains("subtitle_use_forced_subtitles"))
        XCTAssertTrue(remoteKeys.contains("stream_auto_play_next_episode_enabled"))
        XCTAssertTrue(remoteKeys.contains("stream_auto_play_timeout_seconds"))
        XCTAssertTrue(remoteKeys.contains("stream_cached_only"))
        XCTAssertTrue(remoteKeys.contains("cached_only_streams"))
        XCTAssertTrue(remoteKeys.contains("stream_sort_mode"))
        XCTAssertTrue(remoteKeys.contains("smart_stream_selection"))
        XCTAssertTrue(remoteKeys.contains("smart_stream_quality"))
        XCTAssertTrue(remoteKeys.contains("external_player_forward_subtitles"))
        XCTAssertTrue(remoteKeys.contains("frame_rate_matching"))
        XCTAssertTrue(remoteKeys.contains("player_show_pip"))
        XCTAssertTrue(remoteKeys.contains("player_show_episodes"))
        XCTAssertTrue(remoteKeys.contains("player_show_sources"))
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
}


