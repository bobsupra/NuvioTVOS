import Foundation

// MARK: - Engine kinds

/// Internal playback backend selected by Settings → Player Engine and Auto policy.
enum PlayerEngineKind: String, Equatable {
    case mpv
    case avPlayer
}

/// Result of the Android-style DV decision tree for tvOS.
///
/// Android maps to MediaCodec profiles; on Apple TV the only path that can
/// light true Dolby Vision mode is AVPlayer/AVFoundation. Everything else
/// keeps MPV and falls back to the HDR10/PQ base layer.
enum DolbyVisionPlaybackDecision: Equatable {
    /// Hand the stream to AVPlayer so tvOS can engage native Dolby Vision
    /// (when the asset is tagged and Match Content → Dynamic Range is on).
    case nativeAVPlayer
    /// Start with MPV while the original HEVC packets are copied into a local,
    /// DV-tagged fragmented MP4 HLS playlist. AVPlayer takes over only after
    /// that playlist is confirmed playable.
    case nativeRemux
    /// MPV path that will request HDR10/PQ (or HLG) display criteria — the
    /// equivalent of Android `STRIP_TO_HDR10` for containers AVPlayer rejects.
    case mpvHdrFallback
    /// Ordinary MPV playback (non-DV streams, or user forced MPVKit).
    case mpvDefault
}

// MARK: - Policy

/// Decides how to play a stream with respect to Dolby Vision, mirroring the
/// intent of Android `DolbyVisionBaseLayerPolicy` under tvOS constraints.
enum DolbyVisionPlaybackPolicy {

    struct Input: Equatable {
        /// Absolute URL string or path of the playable link.
        var urlString: String
        /// Stream card name (Torrentio-style quality line).
        var streamName: String?
        /// Stream description / secondary line.
        var streamDescription: String?
        /// Optional filename hint from the add-on.
        var filename: String?
        /// Settings → Player Engine raw value: `"Auto"`, `"AVPlayer"`, `"MPVKit"`.
        var engineSetting: String
    }

    struct Result: Equatable {
        let decision: DolbyVisionPlaybackDecision
        let engine: PlayerEngineKind
        /// True when stream metadata/URL strongly suggests Dolby Vision.
        let isDolbyVisionLikely: Bool
        /// True when the container is something AVPlayer can usually open.
        let isAVPlayerFriendlyContainer: Bool
        /// Human-readable reason for logs / toasts.
        let reason: String
    }

    // MARK: Public resolve

    static func resolve(_ input: Input) -> Result {
        let setting = input.engineSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDV = isDolbyVisionLikely(
            urlString: input.urlString,
            streamName: input.streamName,
            streamDescription: input.streamDescription,
            filename: input.filename
        )
        let profile = isDV ? dolbyVisionProfileHint(
            urlString: input.urlString,
            streamName: input.streamName,
            streamDescription: input.streamDescription,
            filename: input.filename
        ) : nil
        let friendly = isAVPlayerFriendlyContainer(urlString: input.urlString)

        switch setting.lowercased() {
        case "avplayer":
            return Result(
                decision: isDV ? .nativeAVPlayer : .nativeAVPlayer,
                engine: .avPlayer,
                isDolbyVisionLikely: isDV,
                isAVPlayerFriendlyContainer: friendly,
                reason: isDV
                    ? "Player Engine forced AVPlayer (native Dolby Vision when asset supports it)"
                    : "Player Engine forced AVPlayer"
            )

        case "mpvkit", "mpv":
            return Result(
                decision: isDV ? .mpvHdrFallback : .mpvDefault,
                engine: .mpv,
                isDolbyVisionLikely: isDV,
                isAVPlayerFriendlyContainer: friendly,
                reason: isDV
                    ? "Player Engine forced MPVKit (Dolby Vision → HDR10/PQ fallback)"
                    : "Player Engine forced MPVKit"
            )

        default:
            // Auto
            if isDV, profile == 7 {
                return Result(
                    decision: .mpvHdrFallback,
                    engine: .mpv,
                    isDolbyVisionLikely: true,
                    isAVPlayerFriendlyContainer: friendly,
                    reason: "Auto: Dolby Vision profile 7 is not native AVPlayer-compatible → MPV HDR10/PQ fallback"
                )
            }
            if isDV {
                return Result(
                    decision: .nativeRemux,
                    engine: .mpv,
                    isDolbyVisionLikely: true,
                    isAVPlayerFriendlyContainer: friendly,
                    reason: "Auto: start MPV while preparing a native Dolby Vision remux"
                )
            }
            return Result(
                decision: .mpvDefault,
                engine: .mpv,
                isDolbyVisionLikely: false,
                isAVPlayerFriendlyContainer: friendly,
                reason: "Auto: default MPV for broad Stremio/debrid codec coverage"
            )
        }
    }

    /// Convenience from a concrete playable URL plus optional stream labels.
    static func resolve(
        url: URL,
        streamName: String? = nil,
        streamDescription: String? = nil,
        filename: String? = nil,
        engineSetting: String = ProfileSettings.current.string(forKey: SettingsKey.playerEngine) ?? "Auto"
    ) -> Result {
        resolve(
            Input(
                urlString: url.absoluteString,
                streamName: streamName,
                streamDescription: streamDescription,
                filename: filename,
                engineSetting: engineSetting
            )
        )
    }

    // MARK: Detection

    static func isDolbyVisionLikely(
        urlString: String,
        streamName: String? = nil,
        streamDescription: String? = nil,
        filename: String? = nil
    ) -> Bool {
        let blob = [urlString, streamName, streamDescription, filename]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        // Prefer whole-token style matches so "HDR" alone is not enough.
        let patterns = [
            #"\bdolby[ ._-]?vision\b"#,
            #"\bdovi\b"#,
            #"\bdvhe\b"#,
            #"\bdvh1\b"#,
            #"\bdvav\b"#,
            #"\bdva1\b"#,
            #"\bdv[ ._-]?p?(?:5|7|8)(?:\.\d+)?\b"#,
            #"(?:^|[^a-z0-9])dv(?:[^a-z0-9]|$)"#,
            #"\bdv\.profile\b"#,
            #"profile[ ._-]?5\.?\d*\b.*\bdv\b"#,
            #"\bhdr10\+?\b.*\bdv\b"#,
            #"\bdv\b.*\bhdr10\b"#
        ]

        for pattern in patterns {
            if blob.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Best-effort release-name hint. Actual device decodability is still
    /// checked after AVFoundation opens the asset.
    static func dolbyVisionProfileHint(
        urlString: String,
        streamName: String? = nil,
        streamDescription: String? = nil,
        filename: String? = nil
    ) -> Int? {
        let blob = [urlString, streamName, streamDescription, filename]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let patterns = [
            #"(?:dolby[ ._-]?vision|dovi|dvhe|dvh1|\bdv\b)[ ._-]*(?:profile[ ._-]*)?p?0?([578])(?:[._-]\d+)?\b"#,
            #"\bprofile[ ._-]?0?([578])(?:[._-]\d+)?\b"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: blob,
                    range: NSRange(blob.startIndex..., in: blob)
                  ),
                  let range = Range(match.range(at: 1), in: blob) else { continue }
            return Int(blob[range])
        }
        return nil
    }

    /// Containers AVFoundation typically opens for progressive / HLS playback.
    static func isAVPlayerFriendlyContainer(urlString: String) -> Bool {
        let lower = urlString.lowercased()
        // Strip query for extension checks.
        let path = lower.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? lower

        if path.contains(".m3u8") { return true }

        let friendlyExtensions = [".mp4", ".m4v", ".mov", ".m4a"]
        if friendlyExtensions.contains(where: { path.hasSuffix($0) }) {
            return true
        }

        // Some debrid hosts put the extension mid-path before a token query.
        if friendlyExtensions.contains(where: { path.contains($0 + "/") || path.contains($0 + "?") }) {
            return true
        }

        return false
    }

    /// Status line for the player toast / logs after a decision.
    static func statusMessage(for result: Result) -> String? {
        switch result.decision {
        case .nativeAVPlayer where result.isDolbyVisionLikely:
            return "Native Dolby Vision (AVPlayer)"
        case .nativeAVPlayer:
            return nil
        case .nativeRemux:
            // Do not claim native DV until AVPlayer produces its first frame.
            return nil
        case .mpvHdrFallback:
            return "Dolby Vision → HDR10/PQ (MPV)"
        case .mpvDefault:
            return nil
        }
    }
}
