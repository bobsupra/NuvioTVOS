import Foundation

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
    var autoplay: Bool
    /// Runtime controls that must survive an Aether → MPV handoff.
    var playbackRate: Float
    var subtitleDelaySeconds: Double
    var audioDelaySeconds: Double
    var audioGainDB: Double
    /// Stream card labels used only for diagnostics / hard-exception policy.
    var streamName: String?
    var streamDescription: String?
    var filename: String?

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
        assMode: PlaybackASSMode = .strip,
        autoplay: Bool = true,
        playbackRate: Float = 1,
        subtitleDelaySeconds: Double = 0,
        audioDelaySeconds: Double = 0,
        audioGainDB: Double = 0,
        streamName: String? = nil,
        streamDescription: String? = nil,
        filename: String? = nil
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
        self.autoplay = autoplay
        self.playbackRate = playbackRate
        self.subtitleDelaySeconds = subtitleDelaySeconds
        self.audioDelaySeconds = audioDelaySeconds
        self.audioGainDB = audioGainDB
        self.streamName = streamName
        self.streamDescription = streamDescription
        self.filename = filename
    }
}

enum PlaybackCacheProfile: String, Equatable {
    case auto
    case conservative
    case medium
    case large
    case max

    /// Maps Settings → Network Cache raw value.
    static func fromSettings(_ raw: String?) -> PlaybackCacheProfile {
        switch raw {
        case "Small", "Conservative": return .conservative
        case "Medium": return .medium
        case "Large": return .large
        case "Max": return .max
        default: return .auto
        }
    }

    /// Aether `LoadOptions.forwardBufferSegments` (~4 s each).
    var aetherForwardBufferSegments: Int {
        switch self {
        case .conservative: return 4
        case .medium, .auto: return 10
        case .large: return 30
        case .max: return 60
        }
    }
}

enum PlaybackASSMode: String, Equatable {
    case strip
    case force
    case scale

    static func fromSettings(_ raw: String?) -> PlaybackASSMode {
        switch (raw ?? "Strip").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "force": return .force
        case "scale": return .scale
        default: return .strip
        }
    }
}
