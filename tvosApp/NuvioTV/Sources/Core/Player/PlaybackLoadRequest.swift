import Foundation
import Darwin

struct PlaybackCacheFileIdentity: Equatable, Sendable {
    let infoHash: String
    let fileIndex: Int

    init?(infoHash: String?, fileIndex: Int?) {
        guard let rawHash = infoHash, let fileIndex, fileIndex >= 0 else { return nil }
        let hash = rawHash.lowercased()
        guard (hash.count == 40 || hash.count == 64),
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.infoHash = hash
        self.fileIndex = fileIndex
    }

    var cacheKey: String { "torrent:\(infoHash):\(fileIndex)" }
}

/// Everything required to open a stream on any playback backend.
struct PlaybackLoadRequest: Equatable {
    var videoURL: URL
    /// Separate audio URL (YouTube trailers). Forces MPV when non-nil.
    var audioURL: URL?
    var resumePositionSeconds: Double?
    var httpHeaders: [String: String]
    var externalSubtitles: [NuvioSubtitle]
    var preferredAudioLanguages: [String]
    var preferredSubtitleLanguages: [String]
    /// Settings → Frame Rate Matching / Match Content. `false` when Off.
    var matchContentEnabled: Bool
    var cacheProfile: PlaybackCacheProfile
    var assMode: PlaybackASSMode
    var isAnime: Bool
    var autoplay: Bool
    /// Runtime controls that must survive an Aether → MPV handoff.
    var playbackRate: Float
    var aspectMode: PlayerAspectMode
    var subtitleDelaySeconds: Double
    var audioDelaySeconds: Double
    var audioGainDB: Double
    /// Stream card labels used only for diagnostics / hard-exception policy.
    var streamName: String?
    var streamDescription: String?
    var filename: String?
    /// Canonical content identity (SHA-256 over imdbId/season/ep/durationBucket)
    /// allowing preview caches to survive debrid URL changes and token expiration.
    var canonicalMediaKey: String?
    var cacheFileIdentity: PlaybackCacheFileIdentity?
    /// Direct storyboard/trickplay manifest URL (WebVTT) when supplied by the stream add-on.
    var trickplayURL: URL?
    /// Remote artwork URL (episode thumbnail or movie poster/backdrop) for system Now Playing publication.
    var artworkURL: URL?

    init(
        videoURL: URL,
        audioURL: URL? = nil,
        resumePositionSeconds: Double? = nil,
        httpHeaders: [String: String] = [:],
        externalSubtitles: [NuvioSubtitle] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        matchContentEnabled: Bool = true,
        cacheProfile: PlaybackCacheProfile = .auto,
        assMode: PlaybackASSMode = .off,
        isAnime: Bool = false,
        autoplay: Bool = true,
        playbackRate: Float = 1,
        aspectMode: PlayerAspectMode = .fit,
        subtitleDelaySeconds: Double = 0,
        audioDelaySeconds: Double = 0,
        audioGainDB: Double = 0,
        streamName: String? = nil,
        streamDescription: String? = nil,
        filename: String? = nil,
        canonicalMediaKey: String? = nil,
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        trickplayURL: URL? = nil,
        artworkURL: URL? = nil
    ) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.resumePositionSeconds = resumePositionSeconds
        self.httpHeaders = httpHeaders
        self.externalSubtitles = externalSubtitles
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.matchContentEnabled = matchContentEnabled
        self.cacheProfile = cacheProfile
        self.assMode = assMode
        self.isAnime = isAnime
        self.autoplay = autoplay
        self.playbackRate = playbackRate
        self.aspectMode = aspectMode
        self.subtitleDelaySeconds = subtitleDelaySeconds
        self.audioDelaySeconds = audioDelaySeconds
        self.audioGainDB = audioGainDB
        self.streamName = streamName
        self.streamDescription = streamDescription
        self.filename = filename
        self.canonicalMediaKey = canonicalMediaKey
        self.cacheFileIdentity = cacheFileIdentity
        self.trickplayURL = trickplayURL
        self.artworkURL = artworkURL
    }
}

enum PlaybackCacheProfile: String, Equatable {
    case auto
    case conservative
    case medium
    case large
    case max
    case ultra

    /// Maps Settings → Network Cache raw value.
    static func fromSettings(_ raw: String?) -> PlaybackCacheProfile {
        switch raw {
        case "Small", "Conservative": return .conservative
        case "Medium": return .medium
        case "Large": return .large
        case "Max": return .max
        case "Ultra", "Extreme": return .ultra
        default: return .auto
        }
    }

    /// Aether `LoadOptions.forwardBufferSegments` (~4 s each) when streaming directly without local cache.
    var directForwardBufferSegments: Int {
        switch self {
        case .conservative: return 4
        case .medium: return 10
        case .large: return 18
        case .max: return 25
        case .ultra: return 25
        case .auto:
            return Self.resolveAutoSegments(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                availableMemoryBytes: os_proc_available_memory()
            )
        }
    }

    /// Legacy / default segment window for unproxied streams.
    var aetherForwardBufferSegments: Int {
        directForwardBufferSegments
    }

    /// When backed by the Hybrid Disk Cache, Aether builds an immediate, comfortable in-memory playback cushion
    /// (~40s / 10 segments for standard/high RAM profiles, bounded by directForwardBufferSegments)
    /// to ensure rapid startup and instant seek response while the disk cache asynchronously pre-fetches minutes ahead onto flash.
    func aetherForwardBufferSegments(isBackedByHybridDiskCache: Bool) -> Int {
        if isBackedByHybridDiskCache {
            return min(10, directForwardBufferSegments)
        }
        return directForwardBufferSegments
    }

    /// Target buffer lead (in seconds) for the Hybrid Disk Cache upstream fetch scheduler.
    var hybridCacheTargetLeadSeconds: Double {
        switch self {
        case .conservative: return 45.0
        case .medium: return 90.0
        case .large: return 150.0
        case .max: return 240.0
        case .ultra: return 360.0
        case .auto:
            return Self.resolveAutoLeadSeconds(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                availableMemoryBytes: os_proc_available_memory()
            )
        }
    }

    /// Dynamically scales Aether forward buffer segments based on live available memory headroom and device physical memory.
    /// Safely bounded to ensure 4K VideoToolbox decoding headroom is preserved without triggering tvOS jetsam kills.
    static func resolveAutoSegments(physicalMemoryBytes: UInt64, availableMemoryBytes: size_t) -> Int {
        let gibPhysical = Double(physicalMemoryBytes) / 1_073_741_824.0
        let mbAvailable = Double(availableMemoryBytes) / (1024.0 * 1024.0)

        if gibPhysical > 3.5 && mbAvailable >= 1000 {
            return 25 // Max/Ultra: ~100s readahead
        } else if gibPhysical > 2.5 && mbAvailable >= 450 {
            return 18 // Large: ~72s readahead
        } else if mbAvailable >= 250 {
            return 10 // Medium: ~40s readahead
        } else {
            return 4  // Conservative: ~16s readahead
        }
    }

    /// Dynamically scales Hybrid Disk Cache forward buffer lead based on device physical memory and available RAM.
    static func resolveAutoLeadSeconds(physicalMemoryBytes: UInt64, availableMemoryBytes: size_t) -> Double {
        let gibPhysical = Double(physicalMemoryBytes) / 1_073_741_824.0
        let mbAvailable = Double(availableMemoryBytes) / (1024.0 * 1024.0)

        if gibPhysical > 3.5 && mbAvailable >= 1000 {
            return 240.0 // 4 minutes ahead
        } else if gibPhysical > 2.5 && mbAvailable >= 450 {
            return 180.0 // 3 minutes ahead
        } else if mbAvailable >= 250 {
            return 120.0 // 2 minutes ahead
        } else {
            return 60.0  // 1 minute ahead
        }
    }
}

enum PlaybackASSMode: String, Equatable {
    case off
    case strip
    case force
    case scale

    static func fromSettings(_ raw: String?) -> PlaybackASSMode {
        switch (raw ?? "Off").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "strip": return .strip
        case "force": return .force
        case "scale": return .scale
        case "off", "no", "disabled", "native", "authored", "none": return .off
        default: return .off
        }
    }
}
