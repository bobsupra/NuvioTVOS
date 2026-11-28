import Foundation
import AetherEngine

/// TrueHD Atmos/DTS:X conversion (enabled by default on tvOS 26+), read at load time so profile
/// switches and disabling it take effect on the next playback. Codec, sample-rate and route eligibility
/// remain engine decisions.
enum SpatialAudioSettings {
    static let defaultLayout: SpatialSpeakerLayout = .l916

    static var isSupported: Bool {
        if #available(tvOS 26.0, *) { return true }
        return false
    }

    static func isEnabled(defaults: UserDefaults = ProfileSettings.current) -> Bool {
        defaults.object(forKey: SettingsKey.trueHDSpatialAudio) as? Bool ?? true
    }

    static func layout(defaults: UserDefaults = ProfileSettings.current) -> SpatialSpeakerLayout {
        defaults.string(forKey: SettingsKey.trueHDSpatialAudioLayout)
            .flatMap(SpatialSpeakerLayout.init(rawValue:)) ?? defaultLayout
    }

    static func rendering(
        defaults: UserDefaults = ProfileSettings.current,
        supportsAPAC: Bool = isSupported
    ) -> ObjectAudioRendering {
        guard supportsAPAC, isEnabled(defaults: defaults) else {
            return .off
        }
        return .render(layout(defaults: defaults))
    }
}
