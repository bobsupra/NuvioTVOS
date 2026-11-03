import Compression
import Foundation

/// One subtitle line on the timeline, in seconds. `isDialogue` is false for the lines Auto Sync
/// does not match on (ASS signs, songs, karaoke, typesetting); they still move with the rest.
/// `isSongLike` marks the lines whose dense runs are the songs (opening, ending): a song style
/// or karaoke tags. Everything inside a song is left out of matching, its translation too.
struct SubtitleTimingCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var isDialogue: Bool = true
    var isSongLike: Bool = false
}

enum SubtitleTextFormat: String, Sendable {
    case srt
    case vtt
    case ass

    var fileExtension: String { rawValue }
}

/// Reads the timing of an add-on subtitle file: its text (any of the encodings Czech and Slovak
/// subtitles come in), its format, and when each line shows.
enum SubtitleTiming {
    // MARK: Text

    /// The file's text: gzip is unpacked, a byte order mark decides UTF-8 / UTF-16, otherwise UTF-8
    /// when it decodes cleanly, then Windows-1250 (older Czech and Slovak subtitles), then Latin-1.
    static func decodeText(_ raw: Data) -> String? {
        var data = raw
        if data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            guard let unpacked = gunzip(data) else { return nil }
            data = unpacked
        }
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let windows1250 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsLatin2.rawValue)))
        if let text = String(data: data, encoding: windows1250) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    /// A gzip member's payload (RFC 1952): the header is skipped and the raw deflate stream inflated.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var position = 10
        if flags & 0x04 != 0 {
            guard position + 2 <= bytes.count else { return nil }
            position += 2 + Int(bytes[position]) + Int(bytes[position + 1]) << 8
        }
        if flags & 0x08 != 0 {
            while position < bytes.count, bytes[position] != 0 { position += 1 }
            position += 1
        }
        if flags & 0x10 != 0 {
            while position < bytes.count, bytes[position] != 0 { position += 1 }
            position += 1
        }
        if flags & 0x02 != 0 { position += 2 }
        guard position < bytes.count - 8 else { return nil }
        let deflated = Array(bytes[position..<(bytes.count - 8)])
        // The size field is the payload size modulo 2^32: a fine hint for a subtitle.
        let sizeHint = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8
            | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        var capacity = max(sizeHint, deflated.count * 4, 64 * 1024)
        for _ in 0..<4 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = deflated.withUnsafeBufferPointer { source in
                compression_decode_buffer(&output, capacity, source.baseAddress!, deflated.count, nil, COMPRESSION_ZLIB)
            }
            if written > 0, written < capacity { return Data(output.prefix(written)) }
            capacity *= 4
        }
        return nil
    }

    // MARK: Format

    static func format(of text: String) -> SubtitleTextFormat? {
        let head = text.prefix(8192)
        if head.contains("[Script Info]") || head.contains("[Events]") || text.contains("\nDialogue:") {
            return .ass
        }
        if head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") { return .vtt }
        if text.contains("-->") { return .srt }
        return nil
    }

    // MARK: Lines

    /// The lines of `text` in `format`, sorted by start. ASS comments are left out; lines with the
    /// same start and end (an ASS line drawn twice for a border) count once.
    static func cues(in text: String, format: SubtitleTextFormat) -> [SubtitleTimingCue] {
        let parsed: [SubtitleTimingCue]
        switch format {
        case .srt, .vtt: parsed = arrowCues(in: text)
        case .ass: parsed = assCues(in: text)
        }
        var seen = Set<String>()
        return parsed
            .filter { $0.end > $0.start && $0.start >= 0 }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            .filter { cue in
                let key = "\(Int((cue.start * 100).rounded())):\(Int((cue.end * 100).rounded())):\(cue.isDialogue)"
                return seen.insert(key).inserted
            }
    }

    /// `00:01:02,345 --> 00:01:04,000` (SRT) and `01:02.345 --> 01:04.000` (WebVTT).
    static let arrowLine = try! NSRegularExpression(
        pattern: #"((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})"#)

    private static func arrowCues(in text: String) -> [SubtitleTimingCue] {
        var cues: [SubtitleTimingCue] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let string = String(line)
            guard string.contains("-->") else { continue }
            let range = NSRange(string.startIndex..., in: string)
            guard let match = arrowLine.firstMatch(in: string, range: range),
                  let startRange = Range(match.range(at: 1), in: string),
                  let endRange = Range(match.range(at: 2), in: string),
                  let start = arrowTime(String(string[startRange])),
                  let end = arrowTime(String(string[endRange])) else { continue }
            cues.append(SubtitleTimingCue(start: start, end: end))
        }
        return cues
    }

    /// `h:mm:ss,mmm`, `mm:ss.mmm`; a fraction shorter than three digits is tenths or hundredths.
    static func arrowTime(_ value: String) -> Double? {
        let parts = value.split(whereSeparator: { $0 == "," || $0 == "." })
        guard parts.count == 2, let fraction = Double(parts[1]) else { return nil }
        let clock = parts[0].split(separator: ":").compactMap { Double($0) }
        guard clock.count == 2 || clock.count == 3 else { return nil }
        let seconds = clock.reduce(0) { $0 * 60 + $1 }
        return seconds + fraction / pow(10, Double(parts[1].count))
    }

    /// ASS field positions from the `[Events]` Format line (the standard order when missing).
    struct ASSEventLayout: Equatable {
        var fieldCount = 10
        var start = 1
        var end = 2
        var style = 3
        var text = 9

        init() {}

        init?(formatLine: String) {
            guard let colon = formatLine.firstIndex(of: ":") else { return nil }
            let names = formatLine[formatLine.index(after: colon)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let start = names.firstIndex(of: "start"),
                  let end = names.firstIndex(of: "end"),
                  let text = names.firstIndex(of: "text") else { return nil }
            fieldCount = names.count
            self.start = start
            self.end = end
            self.text = text
            style = names.firstIndex(of: "style") ?? -1
        }
    }

    /// Styles of signs, songs, karaoke and typesetting, by the names fansubs give them.
    static let nonDialogueStyle = try! NSRegularExpression(
        pattern: #"sign|song|kara|lyric|romaji|kanji|title|typeset|insert|logo|note|credit|next ?ep|eyecatch|^ts\b|\bop\b|\bed\b|^(op|ed)(\d|[\W_]|jp|cz|sk|en|ro|kar|tl|$)|opening|ending"#,
        options: [.caseInsensitive])
    /// The song lines (NimeToDex anime-titulky, czmask.js): opening / ending styles in all the
    /// spellings fansubs use ("OPJP", "ED-romaji"), signs, karaoke; and any line with \k tags.
    static let songStyle = try! NSRegularExpression(
        pattern: #"sign|song|kara|\bop\b|\bed\b|^(op|ed)(\d|[\W_]|jp|cz|sk|en|ro|kar|tl|$)|title|note|typeset|lyric|credit|insert|next ?ep|eyecatch"#,
        options: [.caseInsensitive])
    static let karaokeTag = try! NSRegularExpression(pattern: #"\\k"#, options: [.caseInsensitive])

    static func isSongLike(style: String, text: String) -> Bool {
        songStyle.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)) != nil
            || karaokeTag.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    /// Positioned, moving, karaoke or drawn lines: typesetting, not dialogue.
    static let nonDialogueTags = try! NSRegularExpression(
        pattern: #"\\(pos|move)\s*\(|\\[kK][fo]?\d|\\p[1-9]"#)

    private static func assCues(in text: String) -> [SubtitleTimingCue] {
        var layout = ASSEventLayout()
        var inEvents = false
        var cues: [SubtitleTimingCue] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                layout = ASSEventLayout(formatLine: line) ?? ASSEventLayout()
                continue
            }
            guard line.hasPrefix("Dialogue:") else { continue }
            let fields = assFields(of: line, layout: layout)
            guard fields.count == layout.fieldCount,
                  let start = assTime(fields[layout.start]),
                  let end = assTime(fields[layout.end]) else { continue }
            let style = layout.style >= 0 ? fields[layout.style] : ""
            let body = fields[layout.text]
            let songLike = isSongLike(style: style, text: body)
            cues.append(SubtitleTimingCue(
                start: start, end: end,
                isDialogue: !songLike && isDialogue(style: style, text: body),
                isSongLike: songLike))
        }
        return cues
    }

    /// The fields after `Dialogue:`; the text (last) keeps its commas.
    static func assFields(of line: String, layout: ASSEventLayout) -> [String] {
        guard let colon = line.firstIndex(of: ":") else { return [] }
        return line[line.index(after: colon)...]
            .split(separator: ",", maxSplits: layout.fieldCount - 1, omittingEmptySubsequences: false)
            .map { String($0) }
    }

    /// `h:mm:ss.cc`.
    static func assTime(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let clockAndFraction = trimmed.split(separator: ".")
        guard clockAndFraction.count == 2, let fraction = Double(clockAndFraction[1]) else { return nil }
        let clock = clockAndFraction[0].split(separator: ":").compactMap { Double($0) }
        guard clock.count == 3 else { return nil }
        return clock[0] * 3600 + clock[1] * 60 + clock[2] + fraction / pow(10, Double(clockAndFraction[1].count))
    }

    static func isDialogue(style: String, text: String) -> Bool {
        let styleRange = NSRange(style.startIndex..., in: style)
        if nonDialogueStyle.firstMatch(in: style, range: styleRange) != nil { return false }
        let textRange = NSRange(text.startIndex..., in: text)
        if nonDialogueTags.firstMatch(in: text, range: textRange) != nil { return false }
        // Nothing left once the override tags are gone: a drawing or an empty line.
        let visible = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\[Nnh]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return !visible.isEmpty
    }
}
