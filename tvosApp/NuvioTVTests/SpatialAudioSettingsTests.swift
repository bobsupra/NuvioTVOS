import XCTest
import AetherEngine
@testable import NuvioTV

final class SpatialAudioSettingsTests: XCTestCase {
    func testDualLayerDolbyVisionPreferenceIsRegisteredForProfileSync() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.preferDualLayerDolbyVision))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.lowResUpscaling))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.losslessAudioBridge))
    }

    func testExistingProfilesRemainOffUntilEnabledAndCanDisableAgain() {
        let name = "SpatialAudioSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(SpatialAudioSettings.rendering(defaults: defaults, supportsAPAC: true), .off)
        defaults.set(true, forKey: SettingsKey.trueHDSpatialAudio)
        XCTAssertEqual(SpatialAudioSettings.rendering(defaults: defaults, supportsAPAC: true), .render(.l916))
        // A preference synced from a newer Apple TV must not activate spatial rendering on an older OS.
        XCTAssertEqual(SpatialAudioSettings.rendering(defaults: defaults, supportsAPAC: false), .off)
        defaults.set(false, forKey: SettingsKey.trueHDSpatialAudio)
        XCTAssertEqual(SpatialAudioSettings.rendering(defaults: defaults, supportsAPAC: true), .off)
    }

    func testPlaybackReadsActiveProfileInsteadOfCachingPreviousPreference() {
        let firstID = "spatial-first-\(UUID().uuidString)"
        let secondID = "spatial-second-\(UUID().uuidString)"
        defer {
            ProfileSettings.clearActiveProfile()
            for id in [firstID, secondID] {
                let name = "nuvio.tv.profile.settings.\(id)"
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }

        ProfileSettings.setActiveProfile(firstID, isPrimary: false)
        ProfileSettings.current.set(true, forKey: SettingsKey.trueHDSpatialAudio)
        XCTAssertEqual(SpatialAudioSettings.rendering(supportsAPAC: true), .render(.l916))

        ProfileSettings.setActiveProfile(secondID, isPrimary: false)
        ProfileSettings.current.set(false, forKey: SettingsKey.trueHDSpatialAudio)
        XCTAssertEqual(SpatialAudioSettings.rendering(supportsAPAC: true), .off)

        ProfileSettings.setActiveProfile(firstID, isPrimary: false)
        XCTAssertEqual(SpatialAudioSettings.rendering(supportsAPAC: true), .render(.l916))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.trueHDSpatialAudio))
    }
}
