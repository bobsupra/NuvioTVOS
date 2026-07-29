import CoreGraphics
import Foundation
import AetherLibavcodec

/// WebVTT cue settings (`line`, `position`, `align`, `size`, `vertical`) mapped onto
/// `SubtitleTextPlacement` (#233).
///
/// libavcodec's WebVTT decoder does not convert these into the ASS event line it synthesises
/// (`libavcodec/webvttdec.c` says so as a `@todo` in its file header), so the markup path carries
/// no trace of them. The demuxer keeps them: `libavformat/webvttdec.c` attaches the verbatim
/// settings string to each packet as `AV_PKT_DATA_WEBVTT_SETTINGS`, and `matroskadec.c` propagates
/// the same side data for WebVTT in Matroska. Both subtitle decoders read that side data and hand
/// the string here.
///
/// Two deliberate limits, both because `SubtitleTextPlacement` models an anchor and a point rather
/// than a box:
/// - `size` (box width) has nowhere to go and is ignored.
/// - a point needs both axes, so a `position` without a `line` keeps only the alignment column.
///   The column is where a host's horizontal margin logic already lives, so little is lost.
enum WebVTTCueSettings {

    /// Placement a cue-settings string asks for, or nil when it asks for nothing the engine can
    /// express. Values follow the WebVTT grammar, plus the older `left` / `right` / `middle`
    /// spellings that real tools still emit.
    static func placement(fromSettings settings: String) -> SubtitleTextPlacement? {
        var column: Int?          // 0 left, 1 centre, 2 right
        var row: Int?             // 0 bottom, 1 middle, 2 top
        var lineFraction: Double?
        var positionFraction: Double?
        var sawPlacementSetting = false

        for field in settings.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])

            switch parts[0].lowercased() {
            case "vertical":
                // A writing mode, not a placement. Rendering sideways text at a horizontal anchor
                // is worse than handing the cue back to the host untouched.
                if value == "rl" || value == "lr" { return nil }

            case "align":
                guard let c = Self.column(forAlign: value) else { continue }
                column = c
                sawPlacementSetting = true

            case "line":
                let fields = value.split(separator: ",", omittingEmptySubsequences: false)
                guard let first = fields.first else { continue }
                if first.hasSuffix("%") {
                    guard let f = Self.fraction(String(first)) else { continue }
                    lineFraction = f
                    // The spec's default line alignment is `start`, which anchors the box TOP at
                    // the offset: at line:90% a two-line cue then hangs off the frame and the
                    // renderer has to walk it back. Anchoring to the nearer edge is the stable
                    // reading of the same intent. An explicit alignment still wins, below.
                    row = f >= 0.5 ? 0 : 2
                } else if let n = Int(first) {
                    // Line boxes need the rendered line height, which the engine does not have.
                    // The half of the frame the number names is unambiguous, so that is all it
                    // yields; no anchor point, so the host keeps its own margin.
                    row = n < 0 ? 0 : 2
                } else {
                    continue
                }
                if fields.count > 1, let explicit = Self.row(forLineAlign: String(fields[1])) {
                    row = explicit
                }
                sawPlacementSetting = true

            case "position":
                let head = value.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                guard let f = Self.fraction(String(head)) else { continue }
                positionFraction = f
                sawPlacementSetting = true

            default:
                continue   // size, region and anything else carry no placement the engine models.
            }
        }

        guard sawPlacementSetting else { return nil }

        let c = column ?? 1
        let r = row ?? 0
        var position: CGPoint?
        if let y = lineFraction {
            // Only a vertical percentage makes a point meaningful; x then follows the column so
            // the anchor and the alignment agree.
            let x = positionFraction ?? [0.0, 0.5, 1.0][c]
            position = CGPoint(x: x, y: y)
        }
        return SubtitleTextPlacement(alignment: r * 3 + c + 1, position: position)
    }

    /// The settings string the demuxer attached to this packet, if any. Verbatim, exactly as it
    /// followed the timestamp line in the source.
    static func settings(onPacket packet: UnsafePointer<AVPacket>) -> String? {
        var size = 0
        guard let raw = av_packet_get_side_data(packet, AV_PKT_DATA_WEBVTT_SETTINGS, &size),
              size > 0 else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: raw, count: size), encoding: .utf8)
    }

    /// Placement for a packet in one step: nil unless the packet carries settings that resolve.
    static func placement(onPacket packet: UnsafePointer<AVPacket>) -> SubtitleTextPlacement? {
        settings(onPacket: packet).flatMap { placement(fromSettings: $0) }
    }

    /// Re-attach a settings string to a rebuilt packet (#112 store path), so a cue decoded from
    /// the packet store resolves its placement the same way a freshly demuxed one does.
    @discardableResult
    static func attach(settings: String, to packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        var bytes = Array(settings.utf8)
        guard !bytes.isEmpty,
              let buf = av_packet_new_side_data(packet, AV_PKT_DATA_WEBVTT_SETTINGS, bytes.count)
        else { return false }
        memcpy(buf, &bytes, bytes.count)
        return true
    }

    private static func column(forAlign value: String) -> Int? {
        switch value.lowercased() {
        case "start", "left": return 0
        case "center", "centre", "middle": return 1
        case "end", "right": return 2
        default: return nil
        }
    }

    private static func row(forLineAlign value: String) -> Int? {
        switch value.lowercased() {
        case "start": return 2
        case "center", "centre", "middle": return 1
        case "end": return 0
        default: return nil
        }
    }

    /// `NN%` as a [0, 1] fraction, clamped. Out of range is a malformed file rather than a
    /// different intent, so it clamps instead of dropping the setting.
    private static func fraction(_ value: String) -> Double? {
        guard value.hasSuffix("%"), let percent = Double(value.dropLast()) else { return nil }
        return min(1.0, max(0.0, percent / 100.0))
    }
}
