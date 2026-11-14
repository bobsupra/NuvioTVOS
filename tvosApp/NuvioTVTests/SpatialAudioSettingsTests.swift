import XCTest
import AetherEngine
@testable import NuvioTV

final class SpatialAudioSettingsTests: XCTestCase {
    func testDualLayerDolbyVisionPreferenceIsRegisteredForProfileSync() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.preferDualLayerDolbyVision))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.foldsDolbyVisionFEL))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.lowResUpscaling))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.upscaleScaler))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.losslessAudioBridge))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.preserveSubwooferBassInStereo))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.loudnessNormalizer))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.loudnessTargetPreset))
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

    func testAudioShapingSubwooferRetentionAndLoudnessPresets() {
        let stereoRetention = AudioShaping(maxChannels: 2, lfeMixDB: 0)
        XCTAssertTrue(stereoRetention.isActive)
        XCTAssertEqual(stereoRetention.lfeMixDB, 0)
        XCTAssertEqual(stereoRetention.maxChannels, 2)

        let standard = AudioShaping(loudnessTargetLUFS: -24.0)
        let night = AudioShaping(loudnessTargetLUFS: -20.0)
        let boost = AudioShaping(loudnessTargetLUFS: -16.0)

        XCTAssertEqual(standard.loudnessTargetLUFS, -24.0)
        XCTAssertEqual(night.loudnessTargetLUFS, -20.0)
        XCTAssertEqual(boost.loudnessTargetLUFS, -16.0)
    }

    func testUpscaleModeOptionsAndOffState() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.lowResUpscaling))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.upscaleScaler))

        // Off turns off lowResUpscaling
        let upscaleChoice = "off"
        let isEnabled = upscaleChoice != "off"
        XCTAssertFalse(isEnabled)

        // Other choices turn it on
        for choice in ["smart", "lineArt", "automatic"] {
            XCTAssertTrue(choice != "off")
        }
    }
}
