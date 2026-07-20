import Foundation

/// Host-registered external subtitle file (AetherEngine#88). Registered via
/// `LoadOptions.externalSubtitles` (load time, eligible for the native WebVTT rendition / PiP) or
/// `AetherEngine.addExternalSubtitleTrack` (any time, host overlay only). Appears in
/// `engine.$subtitleTracks` as a `TrackInfo` with a synthetic id
/// (`AetherEngine.externalSubtitleTrackIDBase` + registration ordinal) and `isExternal == true`,
/// selectable through the same `selectSubtitleTrack(index:)` as embedded streams.
public struct ExternalSubtitleTrack: Sendable, Equatable {
    public var url: URL
    public var name: String?
    /// BCP-47 / ISO 639 code, same convention as `TrackInfo.language`.
    public var language: String?
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var isDefault: Bool
    /// nil forwards `LoadOptions.httpHeaders` (same auth as the media).
    public var httpHeaders: [String: String]?
    /// File-extension override ("srt", "ass", "vtt", "ssa") for URLs whose path hides the format.
    public var formatHint: String?

    public init(url: URL, name: String? = nil, language: String? = nil,
                isForced: Bool = false, isHearingImpaired: Bool = false, isDefault: Bool = false,
                httpHeaders: [String: String]? = nil, formatHint: String? = nil) {
        self.url = url
        self.name = name
        self.language = language
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isDefault = isDefault
        self.httpHeaders = httpHeaders
        self.formatHint = formatHint
    }

    /// libavcodec decoder name for `TrackInfo.codec`, so host codec checks (ASS styling, text/bitmap
    /// classification) treat external tracks like embedded ones. Unknown formats fall back to
    /// "subrip"; `SubtitleDecoder.decodeFile` sniffs the real format at decode time anyway.
    public static func codecName(url: URL, formatHint: String?) -> String {
        let ext = (formatHint ?? url.pathExtension).lowercased()
        switch ext {
        case "srt", "subrip": return "subrip"
        case "ass", "ssa": return "ass"
        case "vtt", "webvtt": return "webvtt"
        default: return "subrip"
        }
    }

    func makeTrackInfo(id: Int, fallbackNumber: Int) -> TrackInfo {
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else if let language, let localized = Locale.current.localizedString(forIdentifier: language) {
            resolvedName = localized
        } else {
            resolvedName = "External \(fallbackNumber)"
        }
        return TrackInfo(id: id, name: resolvedName,
                         codec: Self.codecName(url: url, formatHint: formatHint),
                         language: language, channels: 0, isDefault: isDefault,
                         isForced: isForced, isHearingImpaired: isHearingImpaired,
                         isExternal: true)
    }
}
