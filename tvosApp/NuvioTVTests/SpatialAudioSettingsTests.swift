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

        let autoMovie = AetherPlaybackController.resolvedUpscaleConfiguration(
            choice: "smart", lowResEnabled: true, isAnime: false
        )
        XCTAssertTrue(autoMovie.upscalesLowResolutionVideo)
        XCTAssertEqual(autoMovie.scaler, .automatic)
        XCTAssertTrue(autoMovie.upscalesFullHDVideo)

        let autoAnime = AetherPlaybackController.resolvedUpscaleConfiguration(
            choice: "smart", lowResEnabled: true, isAnime: true
        )
        XCTAssertTrue(autoAnime.upscalesLowResolutionVideo)
        XCTAssertEqual(autoAnime.scaler, .lineArt)
        XCTAssertTrue(autoAnime.upscalesFullHDVideo)

        let metalOnly = AetherPlaybackController.resolvedUpscaleConfiguration(
            choice: "automatic", lowResEnabled: true, isAnime: false
        )
        XCTAssertTrue(metalOnly.upscalesLowResolutionVideo)
        XCTAssertEqual(metalOnly.scaler, .automatic)
        XCTAssertFalse(metalOnly.upscalesFullHDVideo)

        let animeOnly = AetherPlaybackController.resolvedUpscaleConfiguration(
            choice: "lineArt", lowResEnabled: true, isAnime: true
        )
        XCTAssertTrue(animeOnly.upscalesLowResolutionVideo)
        XCTAssertEqual(animeOnly.scaler, .lineArt)
        XCTAssertFalse(animeOnly.upscalesFullHDVideo)

        let offChoice = AetherPlaybackController.resolvedUpscaleConfiguration(
            choice: "off", lowResEnabled: true, isAnime: false
        )
        XCTAssertFalse(offChoice.upscalesLowResolutionVideo)
        XCTAssertFalse(offChoice.upscalesFullHDVideo)

        let lowResDisabled = AetherPlaybackController.resolvedUpscaleConfiguration(
            choice: "smart", lowResEnabled: false, isAnime: false
        )
        XCTAssertFalse(lowResDisabled.upscalesLowResolutionVideo)
        XCTAssertFalse(lowResDisabled.upscalesFullHDVideo)
    }
}
