import Foundation

/// Stateless plain-text sanitizer for subtitle cues: strips ASS/SSA markup and normalizes inline
/// escapes into plain text. Used by `WebVTTBuilder` for the native WebVTT rendition.
enum MovTextSampleBuilder {

    /// Strip ASS/SSA override blocks (`{\...}`) and normalize inline escapes to plain text.
    static func sanitize(_ assText: String) -> String {
        var s = assText
        while let open = s.firstIndex(of: "{"), let close = s[open...].firstIndex(of: "}") {
            s.removeSubrange(open...close)
        }
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
