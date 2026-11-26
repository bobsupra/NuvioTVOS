import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
    /// Backend forced disposition. External tracks also use a title fallback
    /// because subtitle providers do not expose container disposition metadata.
    var isForced: Bool = false
    var isNativelyRenderedSubtitle: Bool = false
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

enum EnhanceDialogueMode: String, CaseIterable, Identifiable {
    case off
    case enhance
    case boost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return L10n.string("action_off", fallback: "Off")
        case .enhance:
            return L10n.string("player_dialogue_enhance", fallback: "Enhance")
        case .boost:
            return L10n.string("player_dialogue_boost", fallback: "Boost")
        }
    }
}

enum PlaybackSpeed: Float, CaseIterable, Identifiable {
    case quarter = 0.25
    case half = 0.5
    case normal = 1.0
    case oneAndQuarter = 1.25
    case oneAndHalf = 1.5
    case double = 2.0
    
    var id: Float { rawValue }
    
    var label: String {
        return "\(String(format: "%g", rawValue))x"
    }

    /// Speeds available for quick cycling in the player controls (no slowmos).
    static let quickSpeeds: [PlaybackSpeed] = [.normal, .oneAndQuarter, .oneAndHalf, .double]

    /// Next speed when cycling from the quick speed button.
    var nextQuickSpeed: PlaybackSpeed {
        let speeds = Self.quickSpeeds
        guard let currentIndex = speeds.firstIndex(of: self) else {
            return .normal
        }
        return speeds[(currentIndex + 1) % speeds.count]
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

/// How the video fills the screen across AetherEngine and MPV.
enum PlayerAspectMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case zoom
    case stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return L10n.string("player_aspect_fit", fallback: "Fit")
        case .fill: return L10n.string("player_aspect_crop", fallback: "Fill")
        case .zoom: return L10n.string("player_aspect_mode_slight_zoom", fallback: "Zoom")
        case .stretch: return L10n.string("player_aspect_stretch", fallback: "Stretch")
        }
    }

    var detail: String {
        switch self {
        case .fit: return "Letterbox — show entire frame"
        case .fill: return "Crop edges to fill the screen"
        case .zoom: return "Zoom to reduce black bars"
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
        case .zoom:
            let fillFactor = max(containerAspect / videoAspect, videoAspect / containerAspect)
            let factor = 1.0 + (fillFactor - 1.0) * 0.5
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
/// installed tvOS app with the stream URL (and optional subtitle URLs).
enum ExternalPlayer: String, CaseIterable, Identifiable {
    // The built-in player first, then the apps from A to Z. This is the order
    // of the Play with menu and of Settings > External Player. Settings store
    // the raw value, so the order can change without touching saved choices.
    case builtIn = "Nuvio (Built-in)"
    case infuse = "Infuse"
    case nativePlayer = "Native Player"
    case nplayer = "nPlayer"
    case outplayer = "Outplayer"
    case senplayer = "SenPlayer"
    case vidhub = "VidHub"
    case vlc = "VLC"

    var id: String { rawValue }

    /// Every option's display label, in the order shown in Settings.
    static var settingsOptions: [String] { allCases.map(\.rawValue) }

    /// The player's app icon in Images.xcassets. The built-in player shows
    /// Nuvio's Home Screen icon.
    var iconAssetName: String {
        switch self {
        case .builtIn: return "player_nuvio"
        case .infuse: return "player_infuse"
        case .nativePlayer: return "player_nativeplayer"
        case .nplayer: return "player_nplayer"
        case .outplayer: return "player_outplayer"
        case .senplayer: return "player_senplayer"
        case .vidhub: return "player_vidhub"
        case .vlc: return "player_vlc"
        }
    }

    /// A URL scheme the player's app registers, used to check whether the app
    /// is installed. `canOpenURL` answers only for schemes listed under
    /// LSApplicationQueriesSchemes in Info.plist. Nil for the built-in player.
    var probeScheme: String? {
        switch self {
        case .builtIn: return nil
        case .infuse: return "infuse"
        case .nativePlayer: return "nativeplayer"
        case .nplayer: return "nplayer-http"
        case .outplayer: return "outplayer"
        case .senplayer: return "senplayer"
        case .vidhub: return "vidhub"
        case .vlc: return "vlc"
        }
    }

    #if canImport(UIKit)
    /// Whether the player's app is on this Apple TV. The built-in player
    /// always is.
    @MainActor var isInstalled: Bool {
        guard let scheme = probeScheme, let url = URL(string: "\(scheme)://") else { return true }
        return UIApplication.shared.canOpenURL(url)
    }

    /// The icon for the Play with menu, faded when the player's app is not on
    /// this Apple TV. The fade is drawn into the image, because tvOS menus
    /// draw an item's image without its view modifiers.
    @MainActor var menuIcon: UIImage? {
        guard let icon = UIImage(named: iconAssetName) else { return nil }
        guard !isInstalled else { return icon.withRenderingMode(.alwaysOriginal) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = icon.scale
        return UIGraphicsImageRenderer(size: icon.size, format: format).image { _ in
            icon.draw(at: .zero, blendMode: .normal, alpha: 0.35)
        }.withRenderingMode(.alwaysOriginal)
    }
    #endif

    /// System SF Symbol icon name for the player option.
    var systemImage: String {
        switch self {
        case .builtIn: return "play.tv.fill"
        case .infuse: return "play.circle.fill"
        case .vlc: return "cone.fill"
        case .outplayer: return "arrow.up.right.video.fill"
        case .nplayer: return "play.rectangle.fill"
        case .vidhub: return "play.square.fill"
        case .senplayer: return "play.rectangle.on.rectangle.fill"
        case .nativePlayer: return "play.display"
        }
    }

    /// Resolve a stored setting value, defaulting to the built-in player.
    static func from(_ rawValue: String?) -> ExternalPlayer {
        guard let rawValue, let player = ExternalPlayer(rawValue: rawValue) else { return .builtIn }
        return player
    }

    /// The URL-scheme deep link that hands `streamURL` to this player, or `nil`
    /// for the built-in player (which plays in-app). Infuse supports multi-`sub=`,
    /// `filename=` (for accurate metadata/title scraping), and `position=`.
    /// VLC takes the first subtitle. Native Player takes a display `name=` (title).
    /// Source is percent-encoded so query separators in the stream URL survive.
    func launchURL(
        for streamURL: URL,
        filename: String? = nil,
        subtitleURLs: [URL] = [],
        position: Double? = nil,
        title: String? = nil,
        successURL: URL? = nil,
        errorURL: URL? = nil
    ) -> URL? {
        guard self != .builtIn,
              let encoded = streamURL.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .externalPlayerURLValue) else {
            return nil
        }
        let encodedSubs = subtitleURLs.compactMap {
            $0.absoluteString.addingPercentEncoding(withAllowedCharacters: .externalPlayerURLValue)
        }
        let encodedFilename = filename?.addingPercentEncoding(withAllowedCharacters: .externalPlayerURLValue)

        switch self {
        case .builtIn:
            return nil
        case .infuse:
            var query = "infuse://x-callback-url/play?url=\(encoded)"
            if let encodedFilename, !encodedFilename.isEmpty {
                query += "&filename=\(encodedFilename)"
            }
            if let position, position > 0 {
                query += "&position=\(Int(position))"
            }
            for sub in encodedSubs.prefix(8) {
                query += "&sub=\(sub)"
            }
            for (name, callback) in [("x-success", successURL), ("x-error", errorURL)] {
                if let callback,
                   let encodedCallback = callback.absoluteString.addingPercentEncoding(
                       withAllowedCharacters: .externalPlayerURLValue
                   ) {
                    query += "&\(name)=\(encodedCallback)"
                }
            }
            return URL(string: query)
        case .vlc:
            var query = "vlc-x-callback://x-callback-url/stream?url=\(encoded)"
            if let first = encodedSubs.first {
                query += "&sub=\(first)"
            }
            return URL(string: query)
        case .outplayer:
            if let encodedFilename, !encodedFilename.isEmpty {
                return URL(string: "outplayer://x-callback-url/play?url=\(encoded)&filename=\(encodedFilename)")
            }
            return URL(string: "outplayer://\(encoded)")
        case .nplayer:
            // nPlayer uses nplayer-http / nplayer-https for remote progressive URLs.
            if streamURL.scheme?.lowercased() == "https" {
                let path = streamURL.absoluteString.replacingOccurrences(of: "https://", with: "")
                return URL(string: "nplayer-https://\(path)")
            }
            if streamURL.scheme?.lowercased() == "http" {
                let path = streamURL.absoluteString.replacingOccurrences(of: "http://", with: "")
                return URL(string: "nplayer-http://\(path)")
            }
            return URL(string: "nplayer-\(encoded)")
        case .vidhub:
            var query = "vidhub://play?url=\(encoded)"
            if let encodedFilename, !encodedFilename.isEmpty {
                query += "&filename=\(encodedFilename)"
            }
            if let position, position > 0 {
                query += "&position=\(Int(position))"
            }
            if let first = encodedSubs.first {
                query += "&sub=\(first)"
            }
            return URL(string: query)
        case .senplayer:
            var query = "senplayer://x-callback-url/play?url=\(encoded)"
            if let encodedFilename, !encodedFilename.isEmpty {
                query += "&filename=\(encodedFilename)"
            }
            if let position, position > 0 {
                query += "&position=\(Int(position))"
            }
            for sub in encodedSubs.prefix(8) {
                query += "&sub=\(sub)"
            }
            for (name, callback) in [("x-success", successURL), ("x-error", errorURL)] {
                if let callback,
                   let encodedCallback = callback.absoluteString.addingPercentEncoding(
                       withAllowedCharacters: .externalPlayerURLValue
                   ) {
                    query += "&\(name)=\(encodedCallback)"
                }
            }
            return URL(string: query)
        case .nativePlayer:
            guard let scheme = streamURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  Self.pathExtension(of: streamURL) != "mpd"
            else { return nil }
            // Native Player (App Store, tvOS).
            // Scheme: nativeplayer://play?url=<video>&name=<title>&sub=<subtitle>.
            // For an externally launched URL, Native Player resumes only if the
            // caller sends the start time, so we pass `position=<seconds>`, the same
            // param Infuse takes. The x-callback-url form carries x-success/x-error
            // so progress can come back here if Native Player reports it.
            let wantsCallback = successURL != nil || errorURL != nil
            var query = wantsCallback
                ? "nativeplayer://x-callback-url/play?url=\(encoded)"
                : "nativeplayer://play?url=\(encoded)"
            if let position, position > 0 {
                query += "&position=\(Int(position))"
            }
            if let title,
               let encodedTitle = title.addingPercentEncoding(
                   withAllowedCharacters: .externalPlayerURLValue
               ) {
                query += "&name=\(encodedTitle)"
            }
            let nativeSubs = subtitleURLs
                .filter(Self.nativePlayerSupportsSubtitle)
                .compactMap { $0.absoluteString.addingPercentEncoding(withAllowedCharacters: .externalPlayerURLValue) }
            for sub in nativeSubs.prefix(8) {
                query += "&sub=\(sub)"
            }
            if wantsCallback {
                query += "&x-source=Nuvio"
                for (name, callback) in [("x-success", successURL), ("x-error", errorURL)] {
                    if let callback,
                       let encodedCallback = callback.absoluteString.addingPercentEncoding(
                           withAllowedCharacters: .externalPlayerURLValue
                       ) {
                        query += "&\(name)=\(encodedCallback)"
                    }
                }
            }
            return URL(string: query)
        }
    }

    private static func nativePlayerSupportsSubtitle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !["vtt", "ass", "ssa"].contains(pathExtension(of: url))
    }

    private static func pathExtension(of url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        return (path as NSString).pathExtension.lowercased()
    }

    /// The title an external player shows. An episode gets its season,
    /// number and title after the show's name, as in "Severance · S2 · E3 ·
    /// Who Is Alive?", so the player doesn't show the same name for every
    /// episode. A movie keeps its name.
    static func displayTitle(name: String, season: Int?, episode: Int?, episodeTitle: String?) -> String {
        guard let season, let episode, season >= 0, episode > 0 else { return name }
        let code = "S\(season) · E\(episode)"
        // The episode line can already start with its code, as in "S2 · E3 · ...".
        let title = (episodeTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^(?:S\d{1,3}\s*[·•xX:-]?\s*E\d{1,4}\s*[·•:-]?\s*)+"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = title.isEmpty
            || title.caseInsensitiveCompare(name) == .orderedSame
            || title.range(of: #"^(?:Season|Episode)\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        return isPlaceholder ? "\(name) · \(code)" : "\(name) · \(code) · \(title)"
    }

    /// Builds a sanitized, scraper-friendly media filename for external players
    /// (e.g. Infuse, Outplayer, VidHub, SenPlayer) to enable accurate metadata matching (TMDb / TheTVDB)
    /// and prevent displaying raw stream hashes/tokens.
    static func mediaFilename(
        meta: NuvioMeta?,
        season: Int? = nil,
        episode: Int? = nil,
        episodeTitle: String? = nil,
        streamFilename: String? = nil
    ) -> String? {
        if let meta {
            let cleanTitle = sanitizeFilename(meta.name)
            guard !cleanTitle.isEmpty else {
                return fallbackFilename(streamFilename: streamFilename)
            }

            if meta.isSeries || (season != nil && episode != nil) {
                let s = season.map { String(format: "%02d", max(1, $0)) } ?? "01"
                let e = episode.map { String(format: "%02d", max(1, $0)) } ?? "01"
                var epTitle = episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let t = epTitle {
                    let cleaned = sanitizeFilename(t)
                    if cleaned.isEmpty
                        || cleaned.caseInsensitiveCompare(cleanTitle) == .orderedSame
                        || cleaned.range(of: #"^S\d{1,2}\s*[·•xX-]\s*E\d{1,2}$"#, options: .regularExpression) != nil
                        || cleaned.range(of: #"^Season\s+\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
                        || cleaned.range(of: #"^Episode\s+\d+"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        epTitle = nil
                    } else {
                        // Strip leading "S01E01 - " or "S1 · E1 · " if already embedded in subtitle
                        let stripped = cleaned.replacingOccurrences(
                            of: #"^(?:S\d{1,2}\s*[·•xX-]\s*E\d{1,2}\s*[·•-]\s*)+"#,
                            with: "",
                            options: .regularExpression
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        epTitle = stripped.isEmpty ? nil : stripped
                    }
                }
                if let epTitle, !epTitle.isEmpty {
                    return "\(cleanTitle) - S\(s)E\(e) - \(epTitle).mp4"
                } else {
                    return "\(cleanTitle) - S\(s)E\(e).mp4"
                }
            } else {
                var year = meta.year
                if year == nil, let releaseInfo = meta.releaseInfo,
                   let match = releaseInfo.range(of: #"\b(19\d\d|20\d\d)\b"#, options: .regularExpression) {
                    year = Int(releaseInfo[match])
                }
                if year == nil, let released = meta.released,
                   let match = released.range(of: #"\b(19\d\d|20\d\d)\b"#, options: .regularExpression) {
                    year = Int(released[match])
                }
                if let year {
                    return "\(cleanTitle) (\(year)).mp4"
                } else {
                    return "\(cleanTitle).mp4"
                }
            }
        }
        return fallbackFilename(streamFilename: streamFilename)
    }

    private static func fallbackFilename(streamFilename: String?) -> String? {
        guard let streamFilename = streamFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
              !streamFilename.isEmpty else {
            return nil
        }
        let cleaned = sanitizeFilename(streamFilename)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains(".") {
            return cleaned
        }
        return "\(cleaned).mp4"
    }

    private static func sanitizeFilename(_ name: String) -> String {
        var s = name
        s = s.replacingOccurrences(of: ":", with: " -")
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: "\\", with: "-")
        let forbidden = CharacterSet(charactersIn: "*?\"<>|")
        s = s.unicodeScalars.filter { !forbidden.contains($0) }.map(String.init).joined()
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        while s.contains("- -") { s = s.replacingOccurrences(of: "- -", with: "-") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The return link an external player (Infuse, SenPlayer, Native Player)
/// opens when its player closes after a handoff.
struct ExternalPlaybackCallback: Equatable {
    let id: String
    let isError: Bool
    let progress: Double?
    let position: Double?
    let duration: Double?

    static func parse(_ url: URL) -> ExternalPlaybackCallback? {
        guard url.scheme?.lowercased() == "nuvio-tv",
              url.host?.lowercased() == "external-playback" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let isError = parts.first?.lowercased() == "error"
        let id = isError ? parts.dropFirst().first : parts.first
        guard let id, !id.isEmpty else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func number(_ name: String) -> Double? {
            guard let raw = query.first(where: { $0.name == name })?.value,
                  let value = Double(raw), value.isFinite else { return nil }
            return value
        }
        let progress: Double?
        if let value = number("progress") {
            guard (0...1).contains(value) else { return nil }
            progress = value
        } else {
            progress = nil
        }
        return ExternalPlaybackCallback(
            id: id,
            isError: isError,
            progress: progress,
            position: number("position"),
            duration: number("duration")
        )
    }
}

/// What a return link says about the playback. Times are in seconds.
struct ExternalPlaybackReport: Equatable {
    /// How much of the video was watched, from 0 to 1.
    let progress: Double
    /// Where the player was when it closed.
    let position: Double?
    /// The video's length.
    let duration: Double?
    /// Whether `duration` came from the player, sent or worked out from its
    /// position and progress, rather than from the title's listed runtime.
    let durationIsFromPlayer: Bool
    /// Whether the player closed where it was asked to start, so nothing
    /// played.
    var isAtStart = false
}

extension ExternalPlaybackCallback {
    /// Below this, a progress rounded to four places is too coarse to work out
    /// a duration from.
    private static let smallestProgressForDuration = 0.01
    /// Listed runtimes are whole minutes, and a player can report a little
    /// past the end, so a position up to this far past the listed runtime
    /// counts as the end.
    private static let overrunAllowance: Double = 120
    /// A position this close to where the player was asked to start means it
    /// closed before anything played.
    private static let startTolerance: Double = 2

    /// Reads the link. `listedDuration` is the title's listed runtime, or the
    /// length Plex has for a Plex stream, and `startPosition` where the player
    /// was asked to start, in seconds.
    ///
    /// The players send different values. Infuse sends only `position`.
    /// Native Player sends `position` and `progress` but no `duration`, and
    /// its progress is position / duration to four places, so the duration is
    /// position / progress. A listed runtime can be minutes off the real
    /// length, so it is only the fallback.
    func report(listedDuration: Double?, startPosition: Double?) -> ExternalPlaybackReport? {
        let played = position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let sent = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let listed = listedDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let isAtStart = played.map { abs($0 - (startPosition ?? 0)) <= Self.startTolerance } ?? false
        func make(_ progress: Double, _ position: Double?, _ duration: Double?, fromPlayer: Bool) -> ExternalPlaybackReport {
            ExternalPlaybackReport(
                progress: progress,
                position: position,
                duration: duration,
                durationIsFromPlayer: fromPlayer,
                isAtStart: isAtStart
            )
        }

        if let progress {
            var fromPlayer = sent
            if fromPlayer == nil, let played, played > 0, progress >= Self.smallestProgressForDuration {
                fromPlayer = played / progress
            }
            let length = fromPlayer ?? listed
            return make(progress, played ?? length.map { $0 * progress }, length, fromPlayer: fromPlayer != nil)
        }

        guard let played else { return nil }
        if let sent {
            // A player can report the end a second past the duration.
            guard played <= sent + 1 else { return nil }
            return make(min(played / sent, 1), min(played, sent), sent, fromPlayer: true)
        }
        guard let listed else { return nil }
        if played <= listed {
            return make(played / listed, played, listed, fromPlayer: false)
        }
        // Just past the listed runtime counts as played to the end, unless the
        // player closed where it started. Further past, the listed runtime is
        // off by more than rounding and how much is left is unknown, so
        // nothing is recorded.
        guard played <= listed + Self.overrunAllowance, !isAtStart else { return nil }
        return make(1, played, played, fromPlayer: false)
    }
}

/// Minimal durable state for one in-flight Infuse handoff. A single slot is
/// intentional: a second handoff supersedes the first and callback IDs prevent
/// stale callbacks from consuming the new session.
struct ExternalPlaybackSession: Codable, Equatable {
    let id: String
    let meta: NuvioMeta
    let sourceURL: String
    let season: Int?
    let episode: Int?
    let duration: Double?
    let profileID: String?
    var collectionContext: CollectionPlaybackContext? = nil
    /// Where the player was asked to start, in seconds.
    var startPosition: Double? = nil
}

enum ExternalPlaybackSessionStore {
    private static let key = "nuvio.tv.externalPlaybackSession.v1"

    static func save(_ session: ExternalPlaybackSession, defaults: UserDefaults = .standard) {
        // A series meta can carry its entire episode guide. This handoff is a
        // single-slot preference, so persist the compact form and never send a
        // full guide to cfprefsd.
        let compactSession = ExternalPlaybackSession(
            id: session.id,
            meta: session.meta.persistenceSnapshot,
            sourceURL: session.sourceURL,
            season: session.season,
            episode: session.episode,
            duration: session.duration,
            profileID: session.profileID,
            collectionContext: session.collectionContext,
            startPosition: session.startPosition
        )
        guard let data = try? JSONEncoder().encode(compactSession) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(defaults: UserDefaults = .standard) -> ExternalPlaybackSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ExternalPlaybackSession.self, from: data)
    }

    /// Atomically consumes only a matching callback and profile. Replayed or
    /// unrelated callbacks therefore become no-ops after the first delivery.
    static func consume(
        id: String,
        profileID: String?,
        defaults: UserDefaults = .standard
    ) -> ExternalPlaybackSession? {
        guard let session = load(defaults: defaults),
              session.id == id,
              session.profileID == profileID else { return nil }
        defaults.removeObject(forKey: key)
        return session
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

extension SubtitleLanguagePreferences {
    /// Orders subtitles for external-player handoff so the best COMPLETE (non-forced)
    /// subtitle in the user's preferred language comes first. VLC honors only the first
    /// `sub=`, so index 0 must be the full dialogue track; forced / foreign-parts-only tracks sink to the
    /// end (they don't carry the whole dialogue). Nothing is dropped; forced detection is
    /// a best-effort text heuristic since `NuvioSubtitle` has no disposition flag.
    static func bestCompleteFirst(
        _ subs: [NuvioSubtitle],
        preferredLanguages: [String]
    ) -> [NuvioSubtitle] {
        guard subs.count > 1 else { return subs }
        func isForced(_ sub: NuvioSubtitle) -> Bool {
            let path = URLComponents(string: sub.url)?.path ?? ""
            let filename = (path as NSString).lastPathComponent
            let markerTokens = [sub.label ?? "", sub.language, filename].map { value in
                value.lowercased()
                    .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                    .split(separator: " ").map(String.init)
            }
            func hasExplicitNonForcedMarker(_ tokens: [String]) -> Bool {
                if tokens.contains("unforced") || tokens.contains("nonforced") { return true }
                return zip(tokens, tokens.dropFirst()).contains {
                    ($0 == "not" && $1 == "forced") || ($0 == "non" && $1 == "forced")
                }
            }
            if markerTokens.contains(where: hasExplicitNonForcedMarker) { return false }
            return markerTokens.contains { tokens in
                tokens.contains("forced") || zip(tokens, tokens.dropFirst()).contains {
                    $0 == "foreign" && ($1 == "part" || $1 == "parts")
                }
            }
        }
        let complete = subs.filter { !isForced($0) }
        let forced = subs.filter { isForced($0) }
        var seen: Set<String> = []
        var ordered: [NuvioSubtitle] = []
        for language in preferredLanguages {
            for sub in complete where matches(sub.language, target: language)
                || matches(sub.label, target: language) {
                if seen.insert(sub.url).inserted { ordered.append(sub) }
            }
        }
        for sub in complete where seen.insert(sub.url).inserted { ordered.append(sub) }
        for sub in forced where seen.insert(sub.url).inserted { ordered.append(sub) }
        return ordered
    }
}

/// A next-episode stream the player resolved and is ready to hand to mpv for a
/// seamless in-place advance. Built by the app layer's resolver (reusing the
/// same add-on fetch + smart-stream selection the details screen uses).
struct PreparedNextStream {
    let url: URL
    /// Stable torrent file identity for the resolved URL, when the resolver
    /// can prove the selected file index is unchanged.
    var cacheFileIdentity: PlaybackCacheFileIdentity? = nil
    /// Per-stream HTTP headers from the add-on's proxy hints.
    var httpHeaders: [String: String] = [:]
    /// The "S1 · E2 · Title" line the player shows and parses episode numbers from.
    let subtitleLine: String
    let subtitles: [NuvioSubtitle]
    /// Optional stream card name / description for engine policy (Dolby Vision hints).
    var streamName: String? = nil
    var streamDescription: String? = nil
    var filename: String? = nil
    var addonName: String? = nil
    var videoSize: Int64? = nil
    var videoHash: String? = nil
    var provider: String? = nil
    var bingeGroup: String? = nil
    var artworkURL: URL? = nil
    /// Storyboard URL belonging to this replacement source, if provided.
    var trickplayURL: URL? = nil
    /// Original source-row identity, independent of its resolved playback URL.
    var sourceID: String? = nil
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

/// Settings → Up Next: when the Next Episode card shows on an episode with no
/// ending marker. Values are stored as the strings the rows list.
enum NextEpisodeThreshold {
    static let modePercentage = "Percentage"
    static let modeMinutes = "Minutes before end"
    static let modes = [modePercentage, modeMinutes]
    /// Two minutes before the end is the lead the player always used.
    static let defaultMode = modeMinutes
    static let percentChoices = ["97", "97.5", "98", "98.5", "99", "99.5", "100"]
    static let defaultPercent = "99"
    static let minuteChoices = ["0", "0.5", "1", "1.5", "2", "2.5", "3", "3.5"]
    static let defaultMinutes = "2"

    /// Seconds before the end at which the card shows.
    static func leadSeconds(duration: Double, in settings: UserDefaults) -> Double {
        let mode = settings.string(forKey: SettingsKey.nextEpisodeThresholdMode) ?? defaultMode
        if mode == modePercentage {
            let stored = settings.string(forKey: SettingsKey.nextEpisodeThresholdPercent).flatMap(Double.init) ?? 99
            let percent = min(max(stored, 97), 100)
            return max(duration, 0) * (1 - percent / 100)
        }
        let stored = settings.string(forKey: SettingsKey.nextEpisodeThresholdMinutes).flatMap(Double.init) ?? 2
        return min(max(stored, 0), 3.5) * 60
    }
}

/// Settings → Continue Watching → Resume prompt on launch. Remembers, per
/// profile and only on this Apple TV, the title the player was showing, until
/// the player is left in the normal way. A value still there at launch means
/// the app was closed from the player.
enum ResumePromptStore {
    private static let metaIDKey = "nuvio.tv.resumePrompt.metaID"

    static func markPlayerEntered(metaID: String, in store: UserDefaults = ProfileSettings.current) {
        guard store.string(forKey: metaIDKey) != metaID else { return }
        store.set(metaID, forKey: metaIDKey)
    }

    static func markPlayerExitedNormally(in store: UserDefaults = ProfileSettings.current) {
        guard store.object(forKey: metaIDKey) != nil else { return }
        store.removeObject(forKey: metaIDKey)
    }

    /// The title the app was closed on, read once.
    static func consume(in store: UserDefaults = ProfileSettings.current) -> String? {
        guard let metaID = store.string(forKey: metaIDKey) else { return nil }
        store.removeObject(forKey: metaIDKey)
        return metaID.isEmpty ? nil : metaID
    }
}

/// Settings → Continue Watching → On Select.
enum ContinueWatchingClickAction {
    static let stream = "Open Stream"
    static let details = "Open Details"
    static let detailsForUpcoming = "Details for Upcoming Only"
    static let options = [stream, details, detailsForUpcoming]
    /// Home has always opened details for an episode that has not aired and
    /// played everything else.
    static let defaultOption = detailsForUpcoming

    /// Whether Select on this card opens its details page instead of playing.
    static func opensDetails(for item: ContinueWatchingItem, in settings: UserDefaults) -> Bool {
        switch settings.string(forKey: SettingsKey.continueWatchingClickAction) ?? defaultOption {
        case details: return true
        case stream: return false
        default: return ContinueWatchingSortPolicy.isUpcomingItem(item)
        }
    }
}

/// Settings → Stream Selection → Stream Selection Timeout: how long Auto
/// Select Stream waits for add-ons before it picks from what has arrived.
/// Stored as the strings the row lists.
enum StreamSelectionTimeout {
    /// The rule the app always had: play a link that already meets the
    /// quality target, otherwise wait for every add-on.
    static let automatic = "Automatic"
    static let instant = "0"
    static let unlimited = "Unlimited"
    static let options = [automatic, instant, "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "15", "20", "25", "30", unlimited]
    static let defaultOption = automatic

    enum Rule: Equatable, Sendable {
        case automatic
        /// Pick from what has arrived once this many seconds have passed.
        case seconds(Int)
        /// Wait for every add-on to answer.
        case unlimited

        /// Whether a link may be picked while add-ons are still answering.
        /// Nil leaves it to the app's own checks.
        func allowsEarlyPick(elapsed: TimeInterval) -> Bool? {
            switch self {
            case .automatic: return nil
            case .seconds(let seconds): return elapsed >= Double(seconds)
            case .unlimited: return false
            }
        }
    }

    static func rule(in settings: UserDefaults) -> Rule {
        let stored = settings.string(forKey: SettingsKey.streamSelectionTimeout) ?? defaultOption
        if stored == unlimited { return .unlimited }
        guard stored != automatic, let seconds = Int(stored) else { return .automatic }
        return .seconds(min(max(seconds, 0), 30))
    }

    static func label(for option: String) -> String {
        switch option {
        case automatic: return L10n.string("tvos_settings_stream_timeout_automatic", fallback: "Automatic")
        case instant: return L10n.string("settings_playback_timeout_instant", fallback: "Instant")
        case unlimited: return L10n.string("settings_playback_timeout_unlimited", fallback: "Unlimited")
        default: return option + "s"
        }
    }
}

/// Settings → Stream Selection → Auto-play Source Scope, Allowed Addons and
/// Allowed Plugins: which sources Auto Select Stream may pick from. The
/// stream picker always lists every source.
enum StreamAutoPlaySources {
    static let allSources = "All sources"
    static let addonsOnly = "Installed addons only"
    static let pluginsOnly = "Enabled plugins only"
    static let scopes = [allSources, addonsOnly, pluginsOnly]
    static let defaultScope = allSources

    /// An allow-list is stored as the sources' names, one per line. Empty
    /// allows every source.
    static func names(from stored: String?) -> Set<String> {
        Set((stored ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func stored(_ names: [String]) -> String {
        names.joined(separator: "\n")
    }

    struct Filter: Sendable {
        let scope: String
        let allowedAddons: Set<String>
        let allowedPlugins: Set<String>

        init(settings: UserDefaults) {
            let stored = settings.string(forKey: SettingsKey.streamAutoPlaySourceScope) ?? defaultScope
            scope = scopes.contains(stored) ? stored : defaultScope
            allowedAddons = names(from: settings.string(forKey: SettingsKey.streamAutoPlayAllowedAddons))
            allowedPlugins = names(from: settings.string(forKey: SettingsKey.streamAutoPlayAllowedPlugins))
        }

        /// False with the defaults, when every stream passes.
        var isActive: Bool {
            scope != defaultScope || !allowedAddons.isEmpty || !allowedPlugins.isEmpty
        }

        /// The streams auto-select may pick from. Each stream is judged by
        /// the group it came in: a plugin's, a media server's (Plex,
        /// Jellyfin, a network share), or an add-on's. Media server streams
        /// always pass, as on the other apps. A stream in no group passes.
        func candidates(from streams: [NuvioStream], groups: [AddonStreamGroup]) -> [NuvioStream] {
            guard isActive else { return streams }
            var known = Set<String>()
            var allowed = Set<String>()
            for group in groups {
                known.formUnion(group.streams.map(\.id))
                allowed.formUnion(allowedStreams(in: group).map(\.id))
            }
            return streams.filter { stream in
                let id = stream.id
                return allowed.contains(id) || !known.contains(id)
            }
        }

        /// The groups auto-select may pick from. The stream list builder
        /// reads streams from the groups when it is given any, so they have
        /// to be filtered along with the streams.
        func candidateGroups(from groups: [AddonStreamGroup]) -> [AddonStreamGroup] {
            guard isActive else { return groups }
            return groups.filter(allows).map { group in
                var copy = group
                copy.streams = allowedStreams(in: group)
                return copy
            }
        }

        /// The streams of a group auto-select may pick. A repository's group
        /// (Group plugin providers by repository) holds several plugins'
        /// streams, so each stream is judged by the plugin it names.
        private func allowedStreams(in group: AddonStreamGroup) -> [NuvioStream] {
            guard allows(group) else { return [] }
            guard group.addonId.hasPrefix(PluginStreamDiscovery.repositoryGroupPrefix),
                  !allowedPlugins.isEmpty else { return group.streams }
            return group.streams.filter { allowedPlugins.contains($0.addonName ?? "") }
        }

        private func allows(_ group: AddonStreamGroup) -> Bool {
            if group.addonId.hasPrefix(PluginStreamDiscovery.repositoryGroupPrefix) {
                return scope != addonsOnly
            }
            if group.addonId.hasPrefix("plugin:") {
                guard scope != addonsOnly else { return false }
                return allowedPlugins.isEmpty || allowedPlugins.contains(group.displayName)
            }
            if group.addonId.hasPrefix("local.") { return true }
            guard scope != pluginsOnly else { return false }
            return allowedAddons.isEmpty || allowedAddons.contains(group.displayName)
        }
    }
}

/// Settings → Player Interface → Hold To Speed and Hold Speed: holding
/// Select on the remote plays faster until it is released.
enum HoldToSpeed {
    static let choices = ["1.25", "1.5", "1.75", "2", "2.5", "3"]
    static let defaultChoice = "2"
    /// How long Select is held before playback speeds up.
    static let holdDelayNanoseconds: UInt64 = 500_000_000

    /// Off unless switched on: Select has always only paused on the Apple TV.
    static func isEnabled(in settings: UserDefaults) -> Bool {
        settings.object(forKey: SettingsKey.holdToSpeedEnabled) as? Bool ?? false
    }

    static func speed(in settings: UserDefaults) -> Float {
        let stored = settings.string(forKey: SettingsKey.holdToSpeedValue) ?? defaultChoice
        return Float(choices.contains(stored) ? stored : defaultChoice) ?? 2
    }
}

/// Settings → Stream Selection → Auto-play regex match and Regex Pattern:
/// Auto Select Stream plays the first source whose text matches the pattern.
/// A pattern that is empty, does not compile or has no letter or digit
/// switches the mode off, and auto-select works as without it.
enum StreamAutoPlayRegex {
    /// The other apps' presets, by their label.
    static let presets: [(key: String, label: String, pattern: String)] = [
        ("settings_playback_regex_preset_any_1080p", "Any 1080p+", "(2160p|4k|1080p)"),
        ("settings_playback_regex_preset_quality_4k_remux", "4K / Remux", "(2160p|4k|remux)"),
        ("settings_playback_regex_preset_quality_1080p_standard", "1080p Standard", "(1080p|full\\s*hd)"),
        ("settings_playback_regex_preset_quality_720p_smaller", "720p / Smaller", "(720p|webrip|web-dl)"),
        ("settings_playback_regex_preset_web_sources", "WEB Sources", "(web[-\\s]?dl|webrip)"),
        ("settings_playback_regex_preset_bluray_quality", "BluRay Quality", "(bluray|b[dr]rip|remux)"),
        ("settings_playback_regex_preset_hevc_x265", "HEVC / x265", "(hevc|x265|h\\.265)"),
        ("settings_playback_regex_preset_avc_x264", "AVC / x264", "(x264|h\\.264|avc)"),
        ("settings_playback_regex_preset_hdr_dolby_vision", "HDR / Dolby Vision", "(hdr|hdr10\\+?|dv|dolby\\s*vision)"),
        ("settings_playback_regex_preset_dolby_atmos_dts", "Dolby Atmos / DTS", "(atmos|truehd|dts[-\\s]?hd|dtsx?)"),
        ("settings_playback_regex_preset_english", "English", "(\\beng\\b|english)"),
        ("settings_playback_regex_preset_no_cam_ts", "No CAM/TS", "^(?!.*\\b(cam|hdcam|ts|telesync)\\b).*$"),
        ("settings_playback_regex_preset_no_remux_hdr", "No REMUX/HDR", "(?is)^(?!.*\\b(hdr|hdr10|dv|dolby|vision|hevc|remux|2160p)\\b).+$")
    ]

    /// Longer patterns are not used: nothing typed on a remote gets there.
    static let maxPatternLength = 300
    /// A stream's text is cut to this many characters before it is matched.
    private static let maxTextLength = 2_000
    /// How long one stream may take to match, and all streams of one pick
    /// together. A pattern that runs over matches nothing more, so a slow
    /// pattern cannot hold up stream selection.
    private static let matchBudget: TimeInterval = 0.05
    private static let totalBudget: TimeInterval = 0.5

    static func compiled(_ pattern: String) -> NSRegularExpression? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPatternLength,
              trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
    }

    /// Whether the mode would use this pattern.
    static func isUsable(_ pattern: String) -> Bool {
        compiled(pattern) != nil
    }

    static func isEnabled(in settings: UserDefaults) -> Bool {
        settings.object(forKey: SettingsKey.streamAutoPlayRegexEnabled) as? Bool ?? false
    }

    /// Time spent matching by one `Matcher`, shared by its copies.
    private final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var spent: TimeInterval = 0

        var isSpent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return spent >= StreamAutoPlayRegex.totalBudget
        }

        func add(_ time: TimeInterval) {
            lock.lock()
            spent += time
            lock.unlock()
        }
    }

    struct Matcher: @unchecked Sendable {
        private let regex: NSRegularExpression
        /// Words inside the pattern's negative lookaheads, as whole words:
        /// a stream that has one never matches, as on the other apps.
        private let exclusion: NSRegularExpression?
        private let budget = Budget()

        /// Nil when the mode is off or the pattern cannot be used.
        init?(settings: UserDefaults) {
            guard StreamAutoPlayRegex.isEnabled(in: settings) else { return nil }
            // The rows are part of Auto Select Stream and grey out with it,
            // so the pattern does nothing while that is off.
            guard settings.object(forKey: SettingsKey.smartStreamSelection) as? Bool ?? false else { return nil }
            self.init(pattern: settings.string(forKey: SettingsKey.streamAutoPlayRegex) ?? "")
        }

        init?(pattern: String) {
            guard let regex = StreamAutoPlayRegex.compiled(pattern) else { return nil }
            self.regex = regex
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            var words: [String] = []
            if let lookahead = try? NSRegularExpression(pattern: "\\(\\?![^)]*?\\(([^)]+)\\)") {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                for match in lookahead.matches(in: trimmed, range: range) where match.numberOfRanges > 1 {
                    guard let wordsRange = Range(match.range(at: 1), in: trimmed) else { continue }
                    words += trimmed[wordsRange].split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            }
            if words.isEmpty {
                exclusion = nil
            } else {
                let escaped = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                exclusion = try? NSRegularExpression(pattern: "\\b(\(escaped))\\b", options: [.caseInsensitive])
            }
        }

        /// The add-on's name, the stream's name and description, and its
        /// address, as the other apps match them.
        func matches(_ stream: NuvioStream) -> Bool {
            let text = String(
                [stream.addonName ?? "", stream.name ?? "", stream.description ?? "", stream.directURL ?? ""]
                    .joined(separator: " ")
                    // One line: add-on descriptions hold line breaks, which
                    // "." and "$" in a pattern would otherwise stop at.
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .prefix(StreamAutoPlayRegex.maxTextLength)
            )
            guard found(regex, in: text) else { return false }
            if let exclusion, found(exclusion, in: text) { return false }
            return true
        }

        func candidates(from streams: [NuvioStream]) -> [NuvioStream] {
            streams.filter(matches)
        }

        /// The stream list builder reads streams from the groups when it is
        /// given any, so they are filtered along with the streams.
        func candidateGroups(from groups: [AddonStreamGroup]) -> [AddonStreamGroup] {
            groups.map { group in
                var copy = group
                copy.streams = group.streams.filter(matches)
                return copy
            }
        }

        private func found(_ expression: NSRegularExpression, in text: String) -> Bool {
            guard !budget.isSpent else { return false }
            let started = Date()
            let deadline = started.addingTimeInterval(StreamAutoPlayRegex.matchBudget)
            var matched = false
            expression.enumerateMatches(
                in: text,
                options: [.reportProgress],
                range: NSRange(text.startIndex..., in: text)
            ) { result, _, stop in
                if result != nil {
                    matched = true
                    stop.pointee = true
                } else if Date() > deadline {
                    stop.pointee = true
                }
            }
            budget.add(Date().timeIntervalSince(started))
            return matched
        }
    }
}

/// Which of the two binge group options a stream pick follows.
enum StreamBingeUse {
    /// A title started from Details, Continue Watching or a recommendation:
    /// Settings → Up Next → Reuse Binge Group.
    case freshStart
    /// The next episode inside the player: Prefer Binge Group (Next Episode).
    case nextEpisode
    /// A new link for what is playing: either option, as before they were split.
    case reload
}

/// Settings → Up Next → Fallback when binge group fails.
enum NextEpisodeResolution {
    /// True while the player resolves the episode it advances to by itself
    /// or from the Next Episode card. An episode picked from the player's
    /// episode list is not one.
    @TaskLocal static var isAutoAdvance = false

    /// On unless switched off: the next episode has always fallen back to
    /// the best other source.
    static func fallsBack(in settings: UserDefaults) -> Bool {
        settings.object(forKey: SettingsKey.nextEpisodeBingeFallback) as? Bool ?? true
    }
}

/// Settings → Audio → Downmix: surround audio is mixed down to fewer channels.
enum AudioDownmix {
    static let stereo = "2.0"
    static let surround = "5.1"
    /// The layouts both player engines can be asked for. AetherEngine takes
    /// a channel count, so the other apps' in-between layouts are left out.
    static let layouts = [stereo, surround]
    static let defaultLayout = stereo

    static func isEnabled(in settings: UserDefaults) -> Bool {
        settings.object(forKey: SettingsKey.downmixEnabled) as? Bool ?? false
    }

    static func layout(in settings: UserDefaults) -> String {
        let stored = settings.string(forKey: SettingsKey.downmixChannels) ?? defaultLayout
        return layouts.contains(stored) ? stored : defaultLayout
    }

    /// AetherEngine's ceiling on output channels, or nil with Downmix off.
    static func maxChannels(in settings: UserDefaults) -> Int? {
        guard isEnabled(in: settings) else { return nil }
        return layout(in: settings) == surround ? 6 : 2
    }

    /// mpv's `audio-channels`, or nil with Downmix off. The narrower layouts
    /// are listed too, so a source with fewer channels is not mixed up.
    static func mpvChannels(in settings: UserDefaults) -> String? {
        guard isEnabled(in: settings) else { return nil }
        return layout(in: settings) == surround ? "5.1,stereo,mono" : "stereo,mono"
    }

    /// mpv's `audio-normalize-downmix`: on when Maintain Original Audio on
    /// Downmix is switched off. Nil with Downmix off.
    static func mpvNormalizesDownmix(in settings: UserDefaults) -> Bool? {
        guard isEnabled(in: settings) else { return nil }
        return (settings.object(forKey: SettingsKey.downmixMaintainOriginal) as? Bool ?? true) == false
    }
}
