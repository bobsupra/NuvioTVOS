import Foundation

/// AE#458: what AVFoundation resolved from the audio the engine served, as one line.
///
/// The serving line has always carried the first half of the exchange (`audioLang=`, the master's
/// `EXT-X-MEDIA:TYPE=AUDIO` tag). The second half, what AVFoundation built from it, is the value AVKit
/// prints in its audio menu and the value #458 was opened about ("Not Specified"), and nothing on this
/// side read it: every `loadMediaSelectionGroup` in the engine asks for `.legible`. A report could
/// therefore only ever be answered as far as our own manifest, which is the half that was never in doubt.
///
/// Pure so it can be asserted on without an item; the reading itself is in `logAudibleReadback`.
enum AudibleSelectionReadback {

    struct Option: Equatable, Sendable {
        let displayName: String
        let languageTag: String?
    }

    /// One line, bounded: it lands in a 300-line ring buffer a reporter copies out of.
    ///
    /// `served` is the language the master declared, nil when it declared none. `servingMaster`
    /// separates the two ways that happens: a media-direct session has no master to declare anything in,
    /// and the absent group there is the documented consequence rather than a finding.
    static func line(
        served: String?,
        servingMaster: Bool,
        groupPresent: Bool,
        options: [Option],
        selected: Option?
    ) -> String {
        var parts = ["[AetherEngine] AE#458 audible readback: served=\(served ?? "none")"]
        parts.append(servingMaster ? "master" : "media playlist")

        guard groupPresent, !options.isEmpty else {
            // A declared rendition that came back as nothing is the reported defect; nothing declared is
            // not, so only the first earns the AVKit consequence.
            parts.append(served != nil
                ? "no audible group (AVKit labels the track Not Specified)"
                : "no audible group, as declared")
            return parts.joined(separator: ", ")
        }

        parts.append("options=\(options.count)")
        parts.append("resolved=\(selected.map(describe) ?? "none")")
        if let served, let selected, !matches(served: served, resolved: selected.languageTag) {
            parts.append("MISMATCH (served \(served), resolved \(selected.languageTag ?? "none"))")
        }
        let listed = options.prefix(4)
        var list = listed.map(describe).joined(separator: " ")
        if options.count > listed.count { list += " +\(options.count - listed.count) more" }
        parts.append("all=[\(list)]")
        return parts.joined(separator: ", ")
    }

    private static func describe(_ option: Option) -> String {
        let name = option.displayName.isEmpty ? "unnamed" : option.displayName
        return "\"\(name)\" (\(option.languageTag ?? "no tag"))"
    }

    /// AVFoundation normalizes what it is handed (matroska "ger" reads back as "de", usually with a region
    /// subtag), so the comparison runs on the primary subtag through the engine's own synonym table. A raw
    /// compare would flag every second German title, and a line that cries wolf is worse than no line.
    private static func matches(served: String, resolved: String?) -> Bool {
        guard let primary = resolved?.split(separator: "-").first else { return false }
        return AetherEngine.languageMatches(String(primary), served)
    }
}
