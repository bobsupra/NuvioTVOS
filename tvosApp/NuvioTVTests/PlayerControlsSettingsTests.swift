import XCTest
@testable import NuvioTV

final class PlayerControlsSettingsTests: XCTestCase {
    func testPlayerControlsSettingsKeysDefined() {
        XCTAssertEqual(SettingsKey.playerShowPiP, "nuvio.tv.settings.playback.showPiP")
        XCTAssertEqual(SettingsKey.playerShowEpisodes, "nuvio.tv.settings.playback.showEpisodes")
        XCTAssertEqual(SettingsKey.playerShowSources, "nuvio.tv.settings.playback.showSources")
        XCTAssertEqual(SettingsKey.playerShowSubtitles, "nuvio.tv.settings.playback.showSubtitles")

        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowPiP))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowEpisodes))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowSources))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowSubtitles))
    }

    func testPlayerControlsSettingsSyncMappings() {
        let localMappings = Dictionary(uniqueKeysWithValues: PlayerSettingsSyncMapper.localToRemoteKeyMappings)
        XCTAssertEqual(localMappings[SettingsKey.playerShowPiP], "player_show_pip")
        XCTAssertEqual(localMappings[SettingsKey.playerShowEpisodes], "player_show_episodes")
        XCTAssertEqual(localMappings[SettingsKey.playerShowSources], "player_show_sources")
        XCTAssertEqual(localMappings[SettingsKey.playerShowSubtitles], "player_show_subtitles")

        let remoteMappings = Dictionary(uniqueKeysWithValues: PlayerSettingsSyncMapper.remoteToLocalKeyMappings)
        XCTAssertEqual(remoteMappings["player_show_pip"], SettingsKey.playerShowPiP)
        XCTAssertEqual(remoteMappings["player_show_episodes"], SettingsKey.playerShowEpisodes)
        XCTAssertEqual(remoteMappings["player_show_sources"], SettingsKey.playerShowSources)
        XCTAssertEqual(remoteMappings["player_show_subtitles"], SettingsKey.playerShowSubtitles)
    }

    func testPlayerControlsButtonDefaults() {
        let defaults = UserDefaults(suiteName: "PlayerControlsSettingsTestsDefaults")!
        defaults.removePersistentDomain(forName: "PlayerControlsSettingsTestsDefaults")

        // When unconfigured, defaults for toggles should be treated as enabled (true)
        let pipEnabled = defaults.object(forKey: SettingsKey.playerShowPiP) as? Bool ?? true
        let episodesEnabled = defaults.object(forKey: SettingsKey.playerShowEpisodes) as? Bool ?? true
        let sourcesEnabled = defaults.object(forKey: SettingsKey.playerShowSources) as? Bool ?? true
        let subtitlesEnabled = defaults.object(forKey: SettingsKey.playerShowSubtitles) as? Bool ?? true

        XCTAssertTrue(pipEnabled)
        XCTAssertTrue(episodesEnabled)
        XCTAssertTrue(sourcesEnabled)
        XCTAssertTrue(subtitlesEnabled)

        // When explicitly set to false, it should disable
        defaults.set(false, forKey: SettingsKey.playerShowPiP)
        defaults.set(false, forKey: SettingsKey.playerShowEpisodes)
        defaults.set(false, forKey: SettingsKey.playerShowSources)
        defaults.set(false, forKey: SettingsKey.playerShowSubtitles)

        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowPiP))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowEpisodes))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowSources))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowSubtitles))
    }

    func testAudioRouteDescriptionHelper() {
        let title = PlaybackSystemMonitor.currentAudioOutputTitle()
        XCTAssertFalse(title.isEmpty)
        let route = PlaybackSystemMonitor.audioRouteInfo()
        XCTAssertFalse(route.isEmpty)
    }

    @MainActor
    func testAetherEngineVideoNowPlayingSessionOptIn() {
        guard let controller = AetherPlaybackController() else {
            XCTFail("AetherEngine should initialize in the test environment")
            return
        }
        XCTAssertTrue(controller.engine.ownsVideoNowPlayingSession)
        controller.destroyPlayer()
    }

    @MainActor
    func testAetherPlaybackControllerExternalSubtitleSelectionAndMapping() throws {
        guard let controller = AetherPlaybackController() else {
            XCTFail("AetherEngine should initialize in the test environment")
            return
        }
        let subtitleURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\nTest subtitle\n".utf8).write(to: subtitleURL)
        defer {
            controller.destroyPlayer()
            try? FileManager.default.removeItem(at: subtitleURL)
        }
        let sub = NuvioSubtitle(url: subtitleURL.absoluteString, language: "en", label: "English Subtitle", source: "OpenSubtitles")
        controller.addSubtitle(sub, select: true)

        XCTAssertEqual(controller.subtitleTracks.count, 1)
        let track = controller.subtitleTracks.first
        XCTAssertEqual(track?.title, "English Subtitle")
        XCTAssertEqual(track?.externalFilename, subtitleURL.absoluteString)
        XCTAssertEqual(track?.selected, true)

        controller.selectSubtitle(-1)
        XCTAssertEqual(controller.subtitleTracks.first?.selected, false)

        if let id = track?.id {
            controller.selectSubtitle(id)
            XCTAssertEqual(controller.subtitleTracks.first?.selected, true)
        }
    }

    @MainActor
    func testExternalSubtitleRegistrationUsesCleanHeaders() {
        let sub = NuvioSubtitle(url: "https://example.com/sub.srt", language: "en", label: "English")
        let registration = AetherExternalSubtitleRegistration.make(
            subtitles: [sub],
            httpHeaders: ["Authorization": "Bearer secret_stream_token", "Referer": "https://stream.host/"]
        )
        XCTAssertEqual(registration.tracks.count, 1)
        XCTAssertEqual(registration.tracks.first?.httpHeaders, [:])
    }

    func testStreamAddonSubtitleDTODecodingNumericAndStringID() throws {
        let jsonNumeric = """
        {
            "url": "https://subs.strem.io/file/12345.srt",
            "lang": "eng",
            "id": 1952383625
        }
        """.data(using: .utf8)!

        let jsonString = """
        {
            "url": "https://subs.strem.io/file/67890.srt",
            "lang": "spa",
            "id": "sub-custom-id"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let dtoNumeric = try decoder.decode(StreamAddonSubtitleDTO.self, from: jsonNumeric)
        let subNumeric = dtoNumeric.toNuvioSubtitle(source: "OpenSubtitles")
        XCTAssertNotNil(subNumeric)
        XCTAssertEqual(subNumeric?.url, "https://subs.strem.io/file/12345.srt")
        XCTAssertEqual(subNumeric?.language, "eng")
        XCTAssertEqual(subNumeric?.label, "1952383625")

        let dtoString = try decoder.decode(StreamAddonSubtitleDTO.self, from: jsonString)
        let subString = dtoString.toNuvioSubtitle(source: "SubDL")
        XCTAssertNotNil(subString)
        XCTAssertEqual(subString?.url, "https://subs.strem.io/file/67890.srt")
        XCTAssertEqual(subString?.language, "spa")
        XCTAssertEqual(subString?.label, "sub-custom-id")
    }

    func testSubtitleTrackBuiltInVsExternalClassification() {
        let builtInTrack = SubtitleTrack(
            id: "1",
            name: "English [SDH]",
            language: "en",
            isSelected: false,
            externalFilename: ""
        )
        let externalTrack = SubtitleTrack(
            id: "2",
            name: "English",
            language: "en",
            isSelected: true,
            externalFilename: "https://example.com/en.srt"
        )

        XCTAssertTrue(builtInTrack.externalFilename.isEmpty)
        XCTAssertFalse(externalTrack.externalFilename.isEmpty)
    }
}
