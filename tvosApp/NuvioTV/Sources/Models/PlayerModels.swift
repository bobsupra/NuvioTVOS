import Foundation

enum PlayerStatus: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case error(String)
    case ended
}

struct SubtitleTrack: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    var isSelected: Bool
    /// URL/path mpv loaded this track from, empty for tracks embedded in the
    /// stream. Lets the subtitle panel tell external tracks apart and map them
    /// back to the `NuvioSubtitle` they were added from.
    var externalFilename: String = ""
}

struct AudioTrack: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    var isSelected: Bool
    /// Localized language name for the card's secondary line ("Russian").
    var languageName: String = ""
    /// Technical summary line ("AC-3 | 6 ch | 48 kHz").
    var detail: String = ""
}

enum PlaybackSpeed: Float, CaseIterable, Identifiable {
    case quarter = 0.25
    case half = 0.5
    case normal = 1.0
    case oneAndHalf = 1.5
    case double = 2.0
    
    var id: Float { rawValue }
    
    var label: String {
        return "\(String(format: "%g", rawValue))x"
    }
}

enum PlayerSeekSettings {
    static let defaultStep = 15
    static let validSteps = [5, 10, 15, 30, 60]
    private static let key = "player.seekStepSeconds"

    static var current: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            return validSteps.contains(stored) ? stored : defaultStep
        }
        set {
            UserDefaults.standard.set(validSteps.contains(newValue) ? newValue : defaultStep, forKey: key)
        }
    }
}

/// How the video fills the screen. Applied as a SwiftUI transform on the video
/// host (mpv always letterboxes into the Metal layer; we scale that surface).
enum PlayerAspectMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var detail: String {
        switch self {
        case .fit: return "Letterbox — show entire frame"
        case .fill: return "Crop edges to fill the screen"
        case .stretch: return "Stretch to fill (may distort)"
        }
    }

    private static let key = "player.aspectMode"

    static var current: PlayerAspectMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? ""
            return PlayerAspectMode(rawValue: raw) ?? .fit
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    /// Scale factors for the video host relative to a FITTED presentation.
    /// Matches Infuse/NuvioTVAppleTV: zoom crops bars, stretch distorts.
    func scale(video: CGSize, container: CGSize) -> CGSize {
        guard video.width > 1, video.height > 1,
              container.width > 1, container.height > 1 else {
            return CGSize(width: 1, height: 1)
        }
        let videoAspect = video.width / video.height
        let containerAspect = container.width / container.height
        switch self {
        case .fit:
            return CGSize(width: 1, height: 1)
        case .fill:
            let factor = max(containerAspect / videoAspect, videoAspect / containerAspect)
            return CGSize(width: factor, height: factor)
        case .stretch:
            if videoAspect > containerAspect {
                return CGSize(width: 1, height: videoAspect / containerAspect)
            } else {
                return CGSize(width: containerAspect / videoAspect, height: 1)
            }
        }
    }
}

enum QualityOption: Identifiable, Equatable {
    case auto
    case manual(resolution: String, bitrate: Int)
    
    var id: String {
        switch self {
        case .auto: return "auto"
        case .manual(let res, let bitrate): return "\(res)-\(bitrate)"
        }
    }
    
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .manual(let res, _): return res
        }
    }
}

/// A player the user can hand a stream off to instead of the built-in mpv
/// engine. `.builtIn` plays in-app; the rest build a deep link that opens an
/// installed tvOS app (Infuse, VLC, Outplayer) with the stream URL.
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case builtIn = "Nuvio (Built-in)"
    case infuse = "Infuse"
    case vlc = "VLC"
    case outplayer = "Outplayer"

    var id: String { rawValue }

    /// Every option's display label, in the order shown in Settings.
    static var settingsOptions: [String] { allCases.map(\.rawValue) }

    /// Resolve a stored setting value, defaulting to the built-in player.
    static func from(_ rawValue: String?) -> ExternalPlayer {
        guard let rawValue, let player = ExternalPlayer(rawValue: rawValue) else { return .builtIn }
        return player
    }

    /// The URL-scheme deep link that hands `streamURL` to this player, or `nil`
    /// for the built-in player (which plays in-app). Infuse and VLC take the
    /// source as an x-callback-url query value; Outplayer takes it inline. The
    /// source is percent-encoded so query separators in the stream URL survive.
    func launchURL(for streamURL: URL) -> URL? {
        guard self != .builtIn,
              let encoded = streamURL.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .externalPlayerURLValue) else {
            return nil
        }
        switch self {
        case .builtIn:
            return nil
        case .infuse:
            return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
        case .vlc:
            return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
        case .outplayer:
            return URL(string: "outplayer://\(encoded)")
        }
    }
}

private extension CharacterSet {
    /// Percent-encoding set for embedding a full URL as a scheme value: only the
    /// RFC 3986 unreserved characters pass through, so `:` `/` `?` `&` `=` `#`
    /// `+` in the stream URL are all escaped and the target app sees it intact.
    static let externalPlayerURLValue = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

/// A next-episode stream the player resolved and is ready to hand to mpv for a
/// seamless in-place advance. Built by the app layer's resolver (reusing the
/// same add-on fetch + smart-stream selection the details screen uses).
struct PreparedNextStream {
    let url: URL
    /// The "S1 · E2 · Title" line the player shows and parses episode numbers from.
    let subtitleLine: String
    let subtitles: [NuvioSubtitle]
    /// Optional stream card name / description for engine policy (Dolby Vision hints).
    var streamName: String? = nil
    var streamDescription: String? = nil
    var filename: String? = nil
}

struct PlayerTime: Equatable {
    var current: Double = 0
    var duration: Double = 0
    
    var progress: Double {
        guard duration > 0 else { return 0 }
        return current / duration
    }
    
    var remaining: Double {
        return max(0, duration - current)
    }
    
    static func formatted(time: Double) -> String {
        let seconds = Int(time) % 60
        let minutes = (Int(time) / 60) % 60
        let hours = Int(time) / 3600
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
