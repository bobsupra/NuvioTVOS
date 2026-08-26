import XCTest
@testable import NuvioTV

final class PlayerControlsSettingsTests: XCTestCase {
    func testPlayerControlsSettingsKeysDefined() {
        XCTAssertEqual(SettingsKey.playerShowPiP, "nuvio.tv.settings.playback.showPiP")
        XCTAssertEqual(SettingsKey.playerShowEpisodes, "nuvio.tv.settings.playback.showEpisodes")
        XCTAssertEqual(SettingsKey.playerShowSources, "nuvio.tv.settings.playback.showSources")

        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowPiP))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowEpisodes))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowSources))
    }

    func testPlayerControlsSettingsSyncMappings() {
        let localMappings = Dictionary(uniqueKeysWithValues: PlayerSettingsSyncMapper.localToRemoteKeyMappings)
        XCTAssertEqual(localMappings[SettingsKey.playerShowPiP], "player_show_pip")
        XCTAssertEqual(localMappings[SettingsKey.playerShowEpisodes], "player_show_episodes")
        XCTAssertEqual(localMappings[SettingsKey.playerShowSources], "player_show_sources")

        let remoteMappings = Dictionary(uniqueKeysWithValues: PlayerSettingsSyncMapper.remoteToLocalKeyMappings)
        XCTAssertEqual(remoteMappings["player_show_pip"], SettingsKey.playerShowPiP)
        XCTAssertEqual(remoteMappings["player_show_episodes"], SettingsKey.playerShowEpisodes)
        XCTAssertEqual(remoteMappings["player_show_sources"], SettingsKey.playerShowSources)
    }

    func testPlayerControlsButtonDefaults() {
        let defaults = UserDefaults(suiteName: "PlayerControlsSettingsTestsDefaults")!
        defaults.removePersistentDomain(forName: "PlayerControlsSettingsTestsDefaults")

        // When unconfigured, defaults for toggles should be treated as enabled (true)
        let pipEnabled = defaults.object(forKey: SettingsKey.playerShowPiP) as? Bool ?? true
        let episodesEnabled = defaults.object(forKey: SettingsKey.playerShowEpisodes) as? Bool ?? true
        let sourcesEnabled = defaults.object(forKey: SettingsKey.playerShowSources) as? Bool ?? true

        XCTAssertTrue(pipEnabled)
        XCTAssertTrue(episodesEnabled)
        XCTAssertTrue(sourcesEnabled)

        // When explicitly set to false, it should disable
        defaults.set(false, forKey: SettingsKey.playerShowPiP)
        defaults.set(false, forKey: SettingsKey.playerShowEpisodes)
        defaults.set(false, forKey: SettingsKey.playerShowSources)

        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowPiP))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowEpisodes))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowSources))
    }
}
