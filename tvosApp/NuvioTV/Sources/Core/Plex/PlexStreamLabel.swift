import Foundation

/// How a Plex file reads in the stream list, in the terms Plex's own apps use:
/// the version as a headline, then its tracks as the server names them.
///
///     Plex · 4K Dolby Vision
///     Video: 4K (HEVC Main 10)
///     Audio: English (EAC3 5.1), Português (AAC Stereo)
///     Subtitles: English, English SDH
///     18.2 GB · 54.1 Mbps · MKV · Living Room Server
enum PlexStreamLabel {
    /// Tracks listed before the rest are counted: "English, Français, +3".
    static let maxAudioTracks = 3
    static let maxSubtitleTracks = 4

    static var convertName: String {
        "Plex · " + L10n.string("plex_stream_convert_name", fallback: "Convert")
    }

    static func label(
        for file: PlexFile,
        tracks: PlexClient.PartTracks?,
        serverName: String
    ) -> (name: String, description: String) {
        let details = file.details
        let resolution = resolution(details?.videoResolution)
        let headline = [resolution, tracks?.dynamicRange].compactMap { $0 }.joined(separator: " ")
        let name = headline.isEmpty ? "Plex" : "Plex · \(headline)"

        var lines: [String] = []
        if let video = video(resolution: resolution, codec: details?.videoCodec, profile: tracks?.videoProfile) {
            lines.append(L10n.string("plex_stream_video", fallback: "Video") + ": " + video)
        }
        // The server's own track names when it answered in time; otherwise
        // the one audio format its library listing gave.
        let audio = tracks?.audio.isEmpty == false
            ? listed(tracks?.audio ?? [], limit: maxAudioTracks)
            : [audioCodec(details?.audioCodec), channels(details?.audioChannels)].compactMap { $0 }.joined(separator: " ")
        if !audio.isEmpty {
            lines.append(L10n.string("plex_stream_audio", fallback: "Audio") + ": " + audio)
        }
        if let subtitles = tracks?.subtitles, !subtitles.isEmpty {
            lines.append(
                L10n.string("plex_stream_subtitles", fallback: "Subtitles") + ": "
                    + listed(subtitles, limit: maxSubtitleTracks)
            )
        }

        var fileParts: [String] = []
        if let size = file.sizeBytes, size > 0 {
            fileParts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let bitrate = details?.bitrateKbps, bitrate > 0 {
            fileParts.append(String(format: "%.1f Mbps", Double(bitrate) / 1000))
        }
        if let container = file.container, !container.isEmpty { fileParts.append(container.uppercased()) }
        if let part = details?.part { fileParts.append(part) }
        // Titles synced before file formats were kept still say what sets the file apart.
        if details == nil, let label = file.label { fileParts.append(label) }
        fileParts.append(serverName)
        lines.append(fileParts.joined(separator: " · "))

        return (name, lines.joined(separator: "\n"))
    }

    static func convertDescription(_ text: String, serverName: String) -> String {
        "\(text)\n\(serverName)"
    }

    // MARK: - Parts

    /// `"1080"` → "1080p", `"4k"` → "4K", `"sd"` → "SD".
    static func resolution(_ value: String?) -> String? {
        guard let value = value?.lowercased(), !value.isEmpty else { return nil }
        if Int(value) != nil { return "\(value)p" }
        return value.uppercased()
    }

    /// "1080p (HEVC Main 10)", as Plex labels a version.
    static func video(resolution: String?, codec: String?, profile: String?) -> String? {
        let format = [videoCodec(codec), profile].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        switch (resolution, format.isEmpty) {
        case let (resolution?, false): return "\(resolution) (\(format))"
        case let (resolution?, true): return resolution
        case (nil, false): return format
        case (nil, true): return nil
        }
    }

    /// The first `limit` names, then how many more there are.
    static func listed(_ names: [String], limit: Int) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        return (names.prefix(limit) + ["+\(names.count - limit)"]).joined(separator: ", ")
    }

    static func videoCodec(_ value: String?) -> String? {
        guard let value = value?.lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "hevc", "h265": return "HEVC"
        case "h264", "avc": return "H.264"
        case "mpeg2video": return "MPEG-2"
        case "mpeg4": return "MPEG-4"
        case "vc1": return "VC-1"
        default: return value.uppercased()
        }
    }

    static func audioCodec(_ value: String?) -> String? {
        guard let value = value?.lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "dca", "dts": return "DTS"
        case "dca-ma": return "DTS-HD MA"
        case "truehd": return "TrueHD"
        default: return value.uppercased()
        }
    }

    /// 6 → "5.1", 8 → "7.1", 2 → "Stereo", 1 → "Mono", as Plex writes them.
    static func channels(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(count).0"
        }
    }
}
