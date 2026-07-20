import Foundation

/// Reassembles a full ASS script (header + Dialogue lines) from the raw event lines the engine emits under `LoadOptions.preserveASSMarkup` (#30), for whole-file renderers (e.g. swift-ass-renderer `loadTrack(content:)`).
///
/// libavcodec normalizes events to `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text` WITHOUT timestamps; timing travels on the cue (`startTime`/`endTime`, absolute source-PTS seconds). Accumulates streamed events from the paced side demuxer, dedupes re-emits by CONTENT (line text + cue times).
///
/// Dedupe deliberately NOT keyed on ReadOrder: real files ship ReadOrder hardcoded to 0 on every line (field repro: anime MKV collapsed to one event under ReadOrder-keyed dedupe). Content key still absorbs byte-identical post-seek re-emits.
///
/// Not thread-safe; confine to one actor (typically host MainActor cue sink).
public final class ASSScriptBuilder {

    private let header: String
    private var events: [(start: Double, seq: Int, line: String)] = []
    /// Content keys (`start|end|raw line`) of everything in `events`.
    private var seen: Set<String> = []

    public var eventCount: Int { events.count }

    /// `header` is the track's `TrackInfo.assHeader`. NUL bytes stripped: MKV CodecPrivate is often NUL-terminated and libass parses C-string-style, so an embedded NUL drops every line after the header (field repro: "2 styles, 0 events").
    public init(header: String) {
        self.header = header.replacingOccurrences(of: "\0", with: "")
    }

    /// Add one cue body. `rawEventText` may contain SEVERAL raw event lines joined by newlines (one per packet rect); `start`/`end` in seconds. Returns true when at least one NEW (unseen) event was added.
    @discardableResult
    public func add(rawEventText: String, start: Double, end: Double) -> Bool {
        var addedAny = false
        for line in rawEventText.split(separator: "\n", omittingEmptySubsequences: true) {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text. Numeric-ReadOrder check validates line SHAPE (rejects comma-heavy plain text); value itself untrustworthy and unused.
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, Int(fields[0]) != nil else { continue }
            let key = "\(start)|\(end)|\(line)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let layer = fields[1]
            let tail = fields[2...].joined(separator: ",")
            events.append((
                start: start,
                seq: events.count,
                line: "Dialogue: \(layer),\(Self.timestamp(start)),\(Self.timestamp(end)),\(tail)"
            ))
            addedAny = true
        }
        return addedAny
    }

    /// Full script: header then events ordered by start/seq. MKV CodecPrivate often ends after the last `Style:` WITHOUT an `[Events]` section, so appended `Dialogue:` lines land inside `[V4+ Styles]` and libass parses 0 events (field repro: "2 styles, 0 events"); synthesize the section + Format line when missing.
    public func script() -> String {
        var lines = [header]
        lines.reserveCapacity(events.count + 2)
        if !header.contains("[Events]") {
            lines.append("""

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            """)
        }
        let ordered = events.sorted {
            ($0.start, $0.seq) < ($1.start, $1.seq)
        }
        for event in ordered {
            lines.append(event.line)
        }
        return lines.joined(separator: "\n")
    }

    /// Drop accumulated events. Header is PER-TRACK (`TrackInfo.assHeader` carries that track's `[V4+ Styles]`): on a track SWITCH build a NEW instance, not reset, else new events render against old styles. reset() is for same-track re-feeds only.
    public func reset() {
        events.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
    }

    /// ASS timestamp `H:MM:SS.cc` (centiseconds). Negative input
    /// clamps to zero.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        var centis = Int((total * 100).rounded())
        let h = centis / 360_000
        centis %= 360_000
        let m = centis / 6_000
        centis %= 6_000
        let s = centis / 100
        centis %= 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, centis)
    }
}
