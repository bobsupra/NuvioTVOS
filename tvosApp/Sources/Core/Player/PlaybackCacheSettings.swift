import Foundation

// MARK: - Network buffer sizing

/// libmpv network-cache sizes, driven by Settings → Playback → Network Cache.
/// `forwardBuffer` is how far ahead mpv prefetches ("preload"); `backBuffer`
/// keeps already-played data resident for instant backward seeks. Values are
/// libmpv bytesize strings (e.g. `"128MiB"`).
///
/// Caps are intentionally modest on tvOS. Apple TV often has only 2–4 GB RAM
/// total; demuxer cache + decode surfaces + Metal/Vulkan can jetsam the app
/// (bug type 298 / `per-process-limit`) once a process approaches ~2 GB.
/// Older defaults (Auto ≈ 512 MiB–1 GiB forward alone) filled aggressively on
/// debrid/4K hosts and caused frequent foreground kills during long watches.
struct PlaybackCacheSettings {
    let forwardBuffer: String
    let backBuffer: String

    static var current: PlaybackCacheSettings {
        switch ProfileSettings.current.string(forKey: SettingsKey.networkCache) ?? "Auto" {
        case "Small", "Conservative":
            // Minimal readahead — prefer stability over seek/buffer comfort.
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        case "Medium":
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        case "Large":
            // Still well under previous 1 GiB default; enough for bursty hosts.
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        case "Max":
            // High-RAM Apple TV only. Still capped to limit jetsam risk.
            return PlaybackCacheSettings(forwardBuffer: "512MiB", backBuffer: "96MiB")
        default:
            return auto
        }
    }

    /// Ceiling scaled to total device RAM (`physicalMemory` is bytes).
    /// Prefer staying far below jetsam: demuxer is only one slice of peak RSS.
    /// > 3.5 GB (newer 4K) → 192/48, ~3 GB (common 4K) → 128/32, ≤ 2.5 GB (HD) → 64/16.
    private static var auto: PlaybackCacheSettings {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gib > 3.5 {
            return PlaybackCacheSettings(forwardBuffer: "192MiB", backBuffer: "48MiB")
        } else if gib > 2.5 {
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        } else {
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        }
    }
}

