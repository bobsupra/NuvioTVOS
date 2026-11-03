import Foundation

/// Applies a mapping to a subtitle file's text by rewriting only its timestamps. Styles,
/// positions, effects and karaoke of ASS stay as they are (their tags count from the line's
/// start), so libass draws the retimed copy exactly like the original.
enum SubtitleRetimer {
    static func retime(_ text: String, format: SubtitleTextFormat, mapping: SubtitleSyncMapping) -> String? {
        retime(text, format: format, plan: .single(mapping))
    }

    /// Every line moves by the part of `plan` it starts in.
    static func retime(_ text: String, format: SubtitleTextFormat, plan: SubtitleSyncPlan) -> String? {
        switch format {
        case .srt: return retimeArrowLines(text, plan: plan, separator: ",")
        case .vtt: return retimeArrowLines(text, plan: plan, separator: ".")
        case .ass: return retimeASS(text, plan: plan)
        }
    }

    /// Start and end after the mapping: never before zero, never shorter than 10 ms.
    static func mapped(start: Double, end: Double, mapping: SubtitleSyncMapping) -> (Double, Double) {
        let newStart = max(0, mapping(start))
        return (newStart, max(newStart + 0.01, mapping(end)))
    }

    private static func retimeArrowLines(_ text: String, plan: SubtitleSyncPlan, separator: String) -> String? {
        let mutable = NSMutableString(string: text)
        let matches = SubtitleTiming.arrowLine.matches(in: text, range: NSRange(location: 0, length: mutable.length))
        guard !matches.isEmpty else { return nil }
        for match in matches.reversed() {
            let source = mutable as String
            guard let startRange = Range(match.range(at: 1), in: source),
                  let endRange = Range(match.range(at: 2), in: source),
                  let start = SubtitleTiming.arrowTime(String(source[startRange])),
                  let end = SubtitleTiming.arrowTime(String(source[endRange])) else { continue }
            let (newStart, newEnd) = mapped(start: start, end: end, mapping: plan.mapping(at: start))
            mutable.replaceCharacters(in: match.range(at: 2), with: arrowTime(newEnd, separator: separator))
            mutable.replaceCharacters(in: match.range(at: 1), with: arrowTime(newStart, separator: separator))
        }
        return mutable as String
    }

    static func arrowTime(_ seconds: Double, separator: String) -> String {
        let total = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d",
                      total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, separator, total % 1000)
    }

    static func assTime(_ seconds: Double) -> String {
        let total = Int((seconds * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", total / 360_000, total / 6000 % 60, total / 100 % 60, total % 100)
    }

    private static func retimeASS(_ text: String, plan: SubtitleSyncPlan) -> String? {
        var layout = SubtitleTiming.ASSEventLayout()
        var inEvents = false
        var changed = false
        let lines = text.components(separatedBy: "\n").map { rawLine -> String in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[events]"
                return rawLine
            }
            guard inEvents else { return rawLine }
            if line.lowercased().hasPrefix("format:") {
                layout = SubtitleTiming.ASSEventLayout(formatLine: line.trimmingCharacters(in: .newlines))
                    ?? SubtitleTiming.ASSEventLayout()
                return rawLine
            }
            guard line.hasPrefix("Dialogue:") || line.hasPrefix("Comment:"),
                  let colon = rawLine.firstIndex(of: ":") else { return rawLine }
            var fields = SubtitleTiming.assFields(of: rawLine, layout: layout)
            guard fields.count == layout.fieldCount,
                  let start = SubtitleTiming.assTime(fields[layout.start]),
                  let end = SubtitleTiming.assTime(fields[layout.end]) else { return rawLine }
            let (newStart, newEnd) = mapped(start: start, end: end, mapping: plan.mapping(at: start))
            fields[layout.start] = assTime(newStart)
            fields[layout.end] = assTime(newEnd)
            changed = true
            return String(rawLine[...colon]) + fields.joined(separator: ",")
        }
        return changed ? lines.joined(separator: "\n") : nil
    }
}
