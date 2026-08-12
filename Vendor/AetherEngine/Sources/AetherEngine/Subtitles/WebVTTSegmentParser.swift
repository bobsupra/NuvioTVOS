import Foundation

/// One parsed WebVTT segment of an HLS SUBTITLES rendition (AE#359).
///
/// Cue times are in the segment's own LOCAL clock, a counter providers run for days (MDR sits at 164
/// hours). `anchorLocalSeconds` and `anchorMPEGTS90k` are the `X-TIMESTAMP-MAP` pair the spec offers
/// for placing them, kept here because it identifies the file as a live segment, but see `cues` for
/// why the placement itself does not use it.
struct WebVTTSegment: Equatable {
    struct Cue: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    let anchorLocalSeconds: Double
    let anchorMPEGTS90k: Int64
    let cues: [Cue]
}

/// Turns the `.vtt` segments of a live SUBTITLES rendition into engine cues.
///
/// Pure by design: the fetch loop owns the network and the lifetime, this owns the two things that
/// are easy to get silently wrong, the clock mapping and the cross-segment repeats. HLS repeats a
/// cue in every segment it overlaps, clipped to the segment boundary, so a collector that appends
/// publishes the same sentence three times in a row.
enum WebVTTSegmentParser {
    /// Cues from adjacent segments count as the same line when their ranges touch. Segment boundaries
    /// are cut on frame times, so the clipped halves rarely meet exactly.
    private static let joinTolerance = 0.25

    static func parse(_ text: String) -> WebVTTSegment? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .hasPrefix("WEBVTT") == true else { return nil }
        guard let mapLine = lines.first(where: { $0.hasPrefix("X-TIMESTAMP-MAP") }),
              let anchor = parseTimestampMap(mapLine) else { return nil }

        var cues: [WebVTTSegment.Cue] = []
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            let line = lines[index]
            guard let arrow = line.range(of: "-->") else { continue }
            let startText = String(line[line.startIndex..<arrow.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // Everything after the second timestamp is cue settings (line:, position:, align: ...),
            // not dialogue.
            let endText = String(line[arrow.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ").first ?? ""
            guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { continue }

            var body: [String] = []
            var cursor = index + 1
            while cursor < lines.count, !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[cursor])
                cursor += 1
            }
            index = cursor
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                cues.append(WebVTTSegment.Cue(start: start, end: end, text: joined))
            }
        }
        return WebVTTSegment(anchorLocalSeconds: anchor.local, anchorMPEGTS90k: anchor.mpegts, cues: cues)
    }

    /// Map a segment's cues onto the player clock.
    ///
    /// NOT through `X-TIMESTAMP-MAP`, deliberately. Measured against MDR (AE#359) the subtitle
    /// rendition's MPEGTS anchor sits two hours off the video rendition's PTS, so a cue placed
    /// through it lands nowhere near the picture, and the anchor is written once and never moves
    /// while the LOCAL clock keeps running. What the renditions of a program do share is the
    /// playlist geometry: identical EXT-X-MEDIA-SEQUENCE and identical EXT-X-PROGRAM-DATE-TIME.
    /// So a cue is placed by its segment's wall time plus its offset inside that segment, and the
    /// wall-to-player mapping comes from the segment the video ingest itself joined at.
    ///
    /// The offset assumes the LOCAL clock is aligned to the segment grid, which is what the boundary
    /// times in real segments show (cues clipped at whole multiples of the duration). A provider that
    /// violates it loses accuracy inside one segment, not the whole placement, and the clamp keeps a
    /// cue from escaping its own segment.
    static func cues(from segment: WebVTTSegment, segmentWallStart: Date, segmentDuration: Double,
                     anchorWall: Date, anchorEngineTime: Double, nextID: inout Int) -> [SubtitleCue] {
        let segmentStartOnPlayerClock = anchorEngineTime + segmentWallStart.timeIntervalSince(anchorWall)
        return segment.cues.map { cue in
            let grid = segmentDuration > 0 ? segmentDuration : 1
            let localSegmentStart = (cue.start / grid).rounded(.down) * grid
            let offset = min(max(cue.start - localSegmentStart, 0), grid)
            let start = segmentStartOnPlayerClock + offset
            let id = nextID
            nextID += 1
            return SubtitleCue(id: id, startTime: start, endTime: start + (cue.end - cue.start),
                               body: .text(cue.text))
        }
    }

    /// Fold a new segment's cues into what is already published: a line whose text is identical and
    /// whose range touches an existing cue extends that cue instead of becoming a second one. Re-feeding
    /// the same segment therefore changes nothing, which is what makes a playlist poll cheap.
    static func merged(into existing: [SubtitleCue], adding: [SubtitleCue],
                       nextID: inout Int) -> [SubtitleCue] {
        var result = existing
        for cue in adding {
            guard case .text(let text) = cue.body else { continue }
            let match = result.firstIndex { candidate in
                guard case .text(let candidateText) = candidate.body, candidateText == text else { return false }
                return cue.startTime <= candidate.endTime + joinTolerance
                    && cue.endTime >= candidate.startTime - joinTolerance
            }
            if let match {
                let old = result[match]
                result[match] = SubtitleCue(id: old.id,
                                            startTime: min(old.startTime, cue.startTime),
                                            endTime: max(old.endTime, cue.endTime),
                                            body: old.body,
                                            placement: old.placement)
            } else {
                result.append(cue)
            }
        }
        return result
    }

    // MARK: - Parsing helpers

    private static func parseTimestampMap(_ line: String) -> (local: Double, mpegts: Int64)? {
        var local: Double?
        var mpegts: Int64?
        // Fields may come in either order: both `LOCAL:...,MPEGTS:...` and the reverse are in the wild.
        for field in line.dropFirst("X-TIMESTAMP-MAP".count).drop(while: { $0 == "=" })
            .components(separatedBy: ",") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("LOCAL:") {
                local = parseTimestamp(String(trimmed.dropFirst("LOCAL:".count)))
            } else if trimmed.hasPrefix("MPEGTS:") {
                mpegts = Int64(trimmed.dropFirst("MPEGTS:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let local, let mpegts else { return nil }
        return (local, mpegts)
    }

    /// `HH:MM:SS.mmm` or `MM:SS.mmm`; hours are unbounded (providers run the LOCAL clock for days).
    private static func parseTimestamp(_ text: String) -> Double? {
        let parts = text.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let values = parts.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard values.count == parts.count else { return nil }
        return parts.count == 3
            ? values[0] * 3600 + values[1] * 60 + values[2]
            : values[0] * 60 + values[1]
    }


}
