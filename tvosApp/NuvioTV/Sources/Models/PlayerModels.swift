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
    /// Container/backend codec name (e.g. "subrip", "hdmv_pgs_subtitle", "ass").
    var codec: String = ""
}

enum SubtitleFormatPreference: String, CaseIterable, Identifiable, Equatable {
    case auto = "Auto"
    case text = "Text"
    case srt = "SRT"
    case ass = "ASS"
    case vtt = "VTT"
    case pgs = "PGS"

    var id: String { rawValue }

    static func fromStored(_ raw: String?) -> SubtitleFormatPreference {
        let normalized = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "text": return .text
        case "srt", "subrip": return .srt
        case "ass", "ssa": return .ass
        case "vtt", "webvtt": return .vtt
        case "pgs", "sup", "pgssub": return .pgs
        default: return .auto
        }
    }

    var displayTitle: String {
        switch self {
        case .auto:
            return L10n.string("tvos_settings_option_auto", fallback: "Auto")
        case .text:
            return L10n.string("tvos_playback_subtitle_format_text", fallback: "Text (SRT / ASS / VTT)")
        case .srt:
            return "SRT"
        case .ass:
            return "ASS / SSA"
        case .vtt:
            return "WebVTT"
        case .pgs:
            return "PGS"
        }
    }

    private enum DetectedFormat {
        case srt
        case ass
        case vtt
        case otherText
        case pgs
        case otherBitmap
        case unknown
    }

    func matches(_ track: SubtitleTrack) -> Bool {
        guard self != .auto else { return false }
        let detected = Self.detectFormat(
            codec: track.codec,
            urlString: track.externalFilename,
            label: track.name
        )
        return matches(detected)
    }

    func matches(_ subtitle: NuvioSubtitle) -> Bool {
        guard self != .auto else { return false }
        let detected = Self.detectFormat(
            codec: "",
            urlString: subtitle.url,
            label: subtitle.label
        )
        return matches(detected)
    }

    private func matches(_ detected: DetectedFormat) -> Bool {
        switch self {
        case .auto:
            return false
        case .text:
            switch detected {
            case .srt, .ass, .vtt, .otherText:
                return true
            case .pgs, .otherBitmap, .unknown:
                return false
            }
        case .srt:
            return detected == .srt
        case .ass:
            return detected == .ass
        case .vtt:
            return detected == .vtt
        case .pgs:
            return detected == .pgs
        }
    }

    private static func detectFormat(codec: String, urlString: String, label: String?) -> DetectedFormat {
        let lowerCodec = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !lowerCodec.isEmpty {
            if let classified = classifyToken(lowerCodec) {
                return classified
            }
        }

        let cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanURL.isEmpty {
            let ext = (URL(string: cleanURL)?.pathExtension ?? (cleanURL as NSString).pathExtension).lowercased()
            if !ext.isEmpty, let classified = classifyToken(ext) {
                return classified
            }
        }

        if let label {
            let tokens = label.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            for token in tokens {
                if let classified = classifyToken(token) {
                    return classified
                }
            }
        }
        return .unknown
    }

    private static func classifyToken(_ raw: String) -> DetectedFormat? {
        if raw == "subrip" || raw == "srt" {
            return .srt
        }
        if raw == "ass" || raw == "ssa" {
            return .ass
        }
        if raw == "webvtt" || raw == "vtt" {
            return .vtt
        }
        if raw == "sup" || raw.contains("pgs") || raw.contains("hdmv") {
            return .pgs
        }
        if raw.contains("dvd_sub") || raw.contains("dvdsub") || raw.contains("dvb_sub")
            || raw.contains("dvbsub") || raw.contains("vobsub") || raw.contains("xsub") {
            return .otherBitmap
        }
        if raw == "mov_text" || raw == "tx3g" || raw == "ttml" || raw == "sami" || raw == "smi"
            || raw == "text" || raw == "eia_608" || raw == "eia_708" || raw == "cea708"
            || raw == "cea_708" || raw.contains("teletext") {
            return .otherText
        }
        return nil
    }
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
    /// Nuvio's Home Screen icon: the chosen Nuvio icon with Nuvio Branding on,
    /// the app's own icon with it off.
    var iconAssetName: String {
        switch self {
        case .builtIn:
            guard NuvioBranding.isOn else { return "player_nuvio" }
            return Self.builtInIconAssetName(for: NuvioBranding.appIcon)
        case .infuse: return "player_infuse"
        case .nativePlayer: return "player_nativeplayer"
        case .nplayer: return "player_nplayer"
        case .outplayer: return "player_outplayer"
        case .senplayer: return "player_senplayer"
        case .vidhub: return "player_vidhub"
        case .vlc: return "player_vlc"
        }
    }

    /// The built-in player's icon tile for a Nuvio app icon, such as
    /// `player_nuvio_arcticblue` for Arctic Blue.
    static func builtInIconAssetName(for icon: NuvioAppIcon) -> String {
        "player_nuvio_" + icon.rawValue.replacingOccurrences(of: "_", with: "")
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
    /// A `nuvio-usenet://` URL when the Usenet stream was only got ready ahead: the player
    /// starts it (`UsenetEngineManager.startStream`) when it plays it.
    var url: URL
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
