import Foundation
import Darwin

// MARK: - Network buffer sizing

/// libmpv network-cache sizes, driven by Settings → Playback → Network Cache.
/// `forwardBuffer` is how far ahead mpv prefetches ("preload"); `backBuffer`
/// keeps already-played data resident for instant backward seeks. Values are
/// libmpv bytesize strings (e.g. `"128MiB"`).
///
/// Dynamic scaling in Auto balances ample readahead runway for high-bitrate 4K
/// (512 MiB forward on high-headroom 4 GB devices like Apple TV 4K Gen 3)
/// against tvOS jetsam memory pressure limits, throttling down on lower-RAM/constrained
/// devices or under memory pressure.
struct PlaybackCacheSettings: Equatable {
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
            return PlaybackCacheSettings(forwardBuffer: "192MiB", backBuffer: "48MiB")
        case "Max":
            // High-RAM Apple TV (256 MiB forward / 64 MiB back).
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        case "Ultra", "Extreme":
            // Safe ceiling for Apple TV 4K Gen 3. Leaves ample headroom for 4K VideoToolbox decode.
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        default:
            return auto
        }
    }

    /// Dynamically scales buffer size based on live available memory headroom and physical RAM.
    /// Safely sized on tvOS to ensure VideoToolbox 4K decoding (videocodecd ~1.5 GB) never triggers jetsam kills.
    /// - High Headroom (Apple TV 4K Gen 3 with 4GB RAM and >=350 MB available) -> 256/64
    /// - Mid Headroom (Apple TV 4K Gen 1/2 with 3GB RAM and >=250 MB available) -> 256/64
    /// - Constrained Memory (>=150 MB available) -> 128/32
    /// - Low Memory (<150 MB or Apple TV HD) -> 64/16
    static var auto: PlaybackCacheSettings {
        resolveAuto(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableMemoryBytes: os_proc_available_memory()
        )
    }

    static func resolveAuto(physicalMemoryBytes: UInt64, availableMemoryBytes: size_t) -> PlaybackCacheSettings {
        let gibPhysical = Double(physicalMemoryBytes) / 1_073_741_824.0
        let mbAvailable = Double(availableMemoryBytes) / (1024.0 * 1024.0)

        if gibPhysical > 3.5 && mbAvailable >= 350 {
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        } else if gibPhysical > 2.5 && mbAvailable >= 250 {
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        } else if mbAvailable >= 150 {
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        } else {
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        }
    }
}

