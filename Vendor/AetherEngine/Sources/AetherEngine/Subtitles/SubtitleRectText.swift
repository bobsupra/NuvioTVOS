import Foundation
import AetherLibavcodec

/// Plain-text extraction from FFmpeg subtitle rects, shared by `SubtitleDecoder` (sidecar) and `EmbeddedSubtitleDecoder` (in-container) so ASS parsing fixes live in one place.
enum SubtitleRectText {

    /// Plain text for a rect: prefers `text` field, falls back to parsing the raw ASS `Dialogue:` line (strip 8 header fields, clean tags + escapes).
    static func plainText(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            return plainText(fromASSEventLine: String(cString: assPtr))
        }
        return nil
    }

    /// Plain text from a raw ASS event line (`ReadOrder,Layer,Style,...,Text`), for surfaces that need
    /// plain text out of markup-preserving cues (the WebVTT rendition over tap-harvested stores,
    /// Sodalite#32). Guarded on the first field being the integer ReadOrder so a plain, comma-heavy
    /// line is never misparsed as an event; non-event lines just get tag/escape cleaning.
    static func plainText(fromASSEventLine line: String) -> String? {
        var l = line
        if l.hasPrefix("Dialogue: ") {
            l.removeFirst("Dialogue: ".count)
        }
        // ASS dialogue: 9 comma-separated fields; body is the 9th and may contain commas.
        let parts = l.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        if parts.count == 9, Int(parts[0]) != nil {
            return cleanASSBody(String(parts[8]))
        }
        return cleanASSBody(l)
    }

    /// Raw ASS event line exactly as libavcodec hands it over (`ReadOrder,Layer,Style,...,Text`, tags + escapes intact), for the `preserveASSMarkup` path; nil when the rect carries no ASS payload (bitmap or plain-text-only rects).
    static func rawASSLine(for rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        guard let assPtr = rect.pointee.ass else { return nil }
        let line = String(cString: assPtr)
        return line.isEmpty ? nil : line
    }

    /// Strip ASS escapes (`\\N` newline, `\\h` hard space) and
    /// `{...}` override tags; nil when nothing displayable remains.
    static func cleanASSBody(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = s.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parse an ASS event line's Text body into coloured runs (#107 teletext colour). Tracks the
    /// current foreground from `\c&Hbbggrr&` / `\1c&Hbbggrr&` (ASS colour is BGR); a bare `\c`/`\1c`
    /// or unparseable value resets to nil (page default). Applies `\N`/`\n` -> newline, `\h` -> space.
    /// All other override tags are ignored. Adjacent equal-colour runs are collapsed. nil when nothing
    /// displayable remains.
    static func coloredRuns(fromASSEventLine line: String) -> [SubtitleTextRun]? {
        var body = line
        if body.hasPrefix("Dialogue: ") { body.removeFirst("Dialogue: ".count) }
        let parts = body.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let text: String = (parts.count == 9 && Int(parts[0]) != nil) ? String(parts[8]) : body

        var runs: [SubtitleTextRun] = []
        var current = ""
        var color: SubtitleColor? = nil

        func flush() {
            guard !current.isEmpty else { return }
            if let last = runs.last, last.color == color {
                runs[runs.count - 1] = SubtitleTextRun(text: last.text + current, color: color)
            } else {
                runs.append(SubtitleTextRun(text: current, color: color))
            }
            current = ""
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "N" || n == "n" { current += "\n"; i += 2; continue }
                if n == "h" { current += " "; i += 2; continue }
            }
            if c == "{" {
                // Override block: colour changes start a new run.
                var j = i + 1
                var tag = ""
                while j < chars.count, chars[j] != "}" { tag.append(chars[j]); j += 1 }
                if let newColor = parseColorTag(tag) {
                    flush()
                    color = newColor   // nil means reset
                }
                i = (j < chars.count) ? j + 1 : j
                continue
            }
            current.append(c)
            i += 1
        }
        flush()

        var cleaned = runs.filter { !$0.text.isEmpty }
        // Edge-trim leading/trailing whitespace and newlines across the run sequence so a coloured
        // cue matches the plain path (teletextBody flattens + trims the .text case). libzvbi
        // teletext ass can prefix a row-positioning newline that would otherwise render as a blank
        // line ONLY on coloured cues (#107). Interior blank lines are folded separately below;
        // single line breaks and colours are preserved.
        while let first = cleaned.first {
            let d = String(first.text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
            if d.isEmpty { cleaned.removeFirst(); continue }
            cleaned[0] = SubtitleTextRun(text: d, color: first.color)
            break
        }
        while let last = cleaned.last {
            var s = last.text
            while let c = s.last, c == " " || c == "\t" || c == "\n" { s.removeLast() }
            if s.isEmpty { cleaned.removeLast(); continue }
            cleaned[cleaned.count - 1] = SubtitleTextRun(text: s, color: last.color)
            break
        }
        cleaned = collapseInteriorBlankLines(cleaned)
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// Collapse interior blank lines across a run sequence (#107). libzvbi joins teletext rows with
    /// `\N`, so a caption whose lines sit on non-adjacent rows (an empty row between them, used only
    /// for vertical placement) arrives as `line1\n\nline2` and would render a blank line the
    /// broadcaster never intended. Consecutive newlines (optionally separated by horizontal
    /// whitespace) fold to one; single line breaks and colours are preserved. The empty row lands
    /// inside a single run in practice, but a colour change at a row boundary could split it, so the
    /// boundary between adjacent runs is folded too.
    private static func collapseInteriorBlankLines(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun] {
        var folded = runs.map { run in
            SubtitleTextRun(
                text: run.text.replacingOccurrences(
                    of: #"\n(?:[ \t]*\n)+"#, with: "\n", options: .regularExpression),
                color: run.color
            )
        }
        var i = 0
        while i < folded.count - 1 {
            if folded[i].text.hasSuffix("\n") {
                var next = folded[i + 1].text
                while next.hasPrefix("\n") { next.removeFirst() }
                folded[i + 1] = SubtitleTextRun(text: next, color: folded[i + 1].color)
            }
            i += 1
        }
        return folded.filter { !$0.text.isEmpty }
    }

    /// Body for a teletext rect's ASS line: `.richText` when any run is coloured, `.text` (flattened)
    /// when none is, nil when empty. Keeps the all-white page on the existing plain-text path (#107).
    static func teletextBody(fromASSEventLine line: String) -> SubtitleCue.Body? {
        guard let runs = coloredRuns(fromASSEventLine: line) else { return nil }
        if runs.contains(where: { $0.color != nil }) {
            return .richText(runs)
        }
        let plain = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : .text(plain)
    }

    /// Parse a `\c`/`\1c` colour override tag body. Returns `.some(nil)` for a reset (bare tag or bad
    /// value), `.some(color)` for a parsed BGR value, and `nil` when the tag is not a colour tag.
    ///
    /// Deviates from the task brief's `-> (value: SubtitleColor?)?` signature: Swift rejects a
    /// single-element labeled tuple as a type ("cannot create a single-element tuple with an element
    /// label"), so this uses the semantically identical `SubtitleColor??` (double optional) instead.
    /// Behaviour (three-way nil / reset / color) is unchanged.
    private static func parseColorTag(_ tag: String) -> SubtitleColor?? {
        // Accept a block that contains \c or \1c (teletext libzvbi emits one tag per block).
        guard let range = tag.range(of: #"\\1?c(?![a-zA-Z])"#, options: .regularExpression) else { return nil }
        let after = tag[range.upperBound...]
        guard let hexRange = after.range(of: #"&H[0-9A-Fa-f]{1,6}&"#, options: .regularExpression) else {
            return .some(nil)   // bare \c => reset
        }
        let hex = after[hexRange].dropFirst(2).dropLast()   // strip &H .. &
        guard let bgr = UInt32(hex, radix: 16) else { return .some(nil) }
        let b = UInt8((bgr >> 16) & 0xFF)
        let g = UInt8((bgr >> 8) & 0xFF)
        let r = UInt8(bgr & 0xFF)
        return .some(SubtitleColor(r: r, g: g, b: b))
    }
}
