import Foundation

/// Playback backends after the AetherEngine migration.
enum PlayerBackendKind: String, Equatable {
    case aether
    case mpv
}

/// Settings → Player Engine after migration.
enum PlayerEngineSetting: String, Equatable {
    case auto
    case aether
    case mpv

    var settingsRawValue: String {
        switch self {
        case .auto: return "Auto"
        case .aether: return "AetherEngine"
        case .mpv: return "MPVKit"
        }
    }

    /// Migrates stored preference strings from earlier engine configurations.
    static func migrated(from raw: String?) -> PlayerEngineSetting {
        let value = (raw ?? "Auto").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "aether", "aetherengine":
            return .aether
        case "mpvkit", "mpv":
            return .mpv
        case "avplayer":
            // Retired engine preference → Auto.
            return .auto
        case "auto", "":
            return .auto
        default:
            return .auto
        }
    }
}

/// Selects the initial backend and whether automatic Aether→MPV fallback is allowed.
enum PlaybackBackendPolicy {

    struct Input: Equatable {
        var urlString: String
        var separateAudioURL: String?
        var streamName: String?
        var streamDescription: String?
        var filename: String?
        var engineSetting: PlayerEngineSetting
        /// Non-zero audio delay or amplification forces MPV for the session.
        var requiresMPVAudioControls: Bool
        var assMode: PlaybackASSMode
    }

    struct Result: Equatable {
        let backend: PlayerBackendKind
        /// Ordinary automatic Aether→MPV fallback on terminal error.
        let allowAutomaticFallback: Bool
        let reason: String
        let statusMessage: String?
    }

    static func resolve(_ input: Input) -> Result {
        // Hard capability exceptions always take MPV.
        if let audio = input.separateAudioURL, !audio.isEmpty {
            return Result(
                backend: .mpv,
                allowAutomaticFallback: false,
                reason: "Separate audio URL requires MPVKit",
                statusMessage: nil
            )
        }
        if input.requiresMPVAudioControls {
            return Result(
                backend: .mpv,
                allowAutomaticFallback: false,
                reason: "Audio delay/amplification requires MPVKit",
                statusMessage: "Compatibility player (audio delay)"
            )
        }
        // Authored ASS Scale is not yet rendered by Nuvio's host overlay.
        if input.assMode == .scale {
            return Result(
                backend: .mpv,
                allowAutomaticFallback: false,
                reason: "ASS Scale uses MPV until host ASS renderer ships",
                statusMessage: nil
            )
        }

        switch input.engineSetting {
        case .mpv:
            return Result(
                backend: .mpv,
                allowAutomaticFallback: false,
                reason: "Player Engine forced MPVKit",
                statusMessage: nil
            )
        case .aether:
            return Result(
                backend: .aether,
                allowAutomaticFallback: false,
                reason: "Player Engine forced AetherEngine (no ordinary auto-fallback)",
                statusMessage: nil
            )
        case .auto:
            return Result(
                backend: .aether,
                allowAutomaticFallback: true,
                reason: "Auto: AetherEngine primary with MPVKit one-way fallback",
                statusMessage: nil
            )
        }
    }

    static func resolveFromCurrentSettings(
        url: URL,
        audioURL: URL? = nil,
        streamName: String? = nil,
        streamDescription: String? = nil,
        filename: String? = nil,
        requiresMPVAudioControls: Bool = false
    ) -> Result {
        let setting = PlayerEngineSetting.migrated(
            from: ProfileSettings.current.string(forKey: SettingsKey.playerEngine)
        )
        let ass = PlaybackASSMode.fromSettings(
            ProfileSettings.current.string(forKey: SettingsKey.assOverrideMode)
        )
        return resolve(
            Input(
                urlString: url.absoluteString,
                separateAudioURL: audioURL?.absoluteString,
                streamName: streamName,
                streamDescription: streamDescription,
                filename: filename,
                engineSetting: setting,
                requiresMPVAudioControls: requiresMPVAudioControls,
                assMode: ass
            )
        )
    }
}

// Compatibility aliases for the old enum names used across the dual-engine era.
typealias PlayerEngineKind = PlayerBackendKind

extension PlayerBackendKind {
    /// Compatibility alias retained for older call sites.
    static var mpvDefault: PlayerBackendKind { .mpv }
}
