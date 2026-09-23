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
        case "ksplayer", "ks", "avplayer":
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
        /// Non-zero audio amplification forces MPV for the session (audio delay is supported on Aether).
        var requiresMPVAudioControls: Bool
        var assMode: PlaybackASSMode
        var isAnime: Bool = false
    }

    struct Result: Equatable {
        let backend: PlayerBackendKind
        /// Ordinary automatic Aether→MPV fallback on terminal error.
        let allowAutomaticFallback: Bool
        let reason: String
        let statusMessage: String?
    }

    static func isRemoteHTTP(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            return false
        }
        if url.host == "127.0.0.1" || url.host == "localhost" {
            return false
        }
        return scheme == "https" || scheme == "http"
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
            if isRemoteHTTP(input.urlString) && !PlaybackEngineCapabilities.mpv.supportsDirectHTTPS {
                return Result(
                    backend: .aether,
                    allowAutomaticFallback: false,
                    reason: "Audio amplification requires MPVKit, but remote HTTPS streams use AetherEngine",
                    statusMessage: nil
                )
            }
            return Result(
                backend: .mpv,
                allowAutomaticFallback: false,
                reason: "Audio amplification requires MPVKit",
                statusMessage: "Compatibility player (audio amplification)"
            )
        }

        let isAnime = input.isAnime
            || NuvioMeta.isAnimeStream(filename: input.filename, streamName: input.streamName, streamDescription: input.streamDescription)
            || input.urlString.lowercased().contains("anime")

        // Authored ASS Scale uses MPV for anime content where complex ASS typesetting is present.
        if input.assMode == .scale && isAnime {
            return Result(
                backend: .mpv,
                allowAutomaticFallback: false,
                reason: "ASS Scale uses MPV for anime content",
                statusMessage: nil
            )
        }

        switch input.engineSetting {
        case .mpv:
            if isRemoteHTTP(input.urlString) && !PlaybackEngineCapabilities.mpv.supportsDirectHTTPS {
                return Result(
                    backend: .aether,
                    allowAutomaticFallback: false,
                    reason: "MPVKit forced but remote HTTPS requires AetherEngine",
                    statusMessage: "AetherEngine (MPVKit lacks HTTPS)"
                )
            }
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
            if isAnime {
                return Result(
                    backend: .mpv,
                    allowAutomaticFallback: true,
                    reason: "Auto: Anime content detected, routing to MPVKit for ASS/typesetting support",
                    statusMessage: nil
                )
            }
            let allowFallback = PlaybackEngineCapabilities.mpv.supportsDirectHTTPS || !isRemoteHTTP(input.urlString)
            return Result(
                backend: .aether,
                allowAutomaticFallback: allowFallback,
                reason: allowFallback
                    ? "Auto: AetherEngine primary for movies/shows with MPVKit fallback"
                    : "Auto: AetherEngine primary (remote HTTPS disables MPVKit fallback)",
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
        requiresMPVAudioControls: Bool = false,
        isAnime: Bool = false
    ) -> Result {
        let setting = PlayerEngineSetting.migrated(
            from: ProfileSettings.current.string(forKey: SettingsKey.playerEngine)
        )
        let ass = PlaybackASSMode.fromSettings(
            ProfileSettings.current.string(forKey: SettingsKey.assOverrideMode)
        )
        let detectedAnime = isAnime
            || NuvioMeta.isAnimeStream(filename: filename, streamName: streamName, streamDescription: streamDescription)
        return resolve(
            Input(
                urlString: url.absoluteString,
                separateAudioURL: audioURL?.absoluteString,
                streamName: streamName,
                streamDescription: streamDescription,
                filename: filename,
                engineSetting: setting,
                requiresMPVAudioControls: requiresMPVAudioControls,
                assMode: ass,
                isAnime: detectedAnime
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
