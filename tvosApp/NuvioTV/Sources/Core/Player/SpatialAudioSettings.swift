import Foundation
import AetherEngine

/// Opt-in TrueHD Atmos/DTS:X conversion, read at load time so profile switches and disabling it take effect
/// on the next playback. Codec, sample-rate and route eligibility remain engine decisions.
enum SpatialAudioSettings {
    static var isSupported: Bool {
        if #available(tvOS 26.0, *) { return true }
        return false
    }

    static func rendering(
        defaults: UserDefaults = ProfileSettings.current,
        supportsAPAC: Bool = isSupported
    ) -> ObjectAudioRendering {
        guard supportsAPAC, defaults.bool(forKey: SettingsKey.trueHDSpatialAudio) else {
            return .off
        }
        return .render(.l916)
    }
}
