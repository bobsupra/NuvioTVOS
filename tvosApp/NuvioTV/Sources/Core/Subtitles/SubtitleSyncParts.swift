import Foundation

/// A stretch of an add-on subtitle that moves by its own amount: a different intro before the
/// opening (the TV version's sponsor card after the opening is gone from the Blu-ray), a scene
/// only the TV version has. `from` is where it starts on the subtitle's own timeline.
struct SubtitleSyncPart: Codable, Equatable, Sendable {
    var from: Double
    var mapping: SubtitleSyncMapping
    var lines: Int
}

/// How each line of an add-on subtitle moves: by the part it starts in, lines before the first
/// part by the first part. Song and sign lines between two parts go with the part before them,
/// so an opening moves with the intro it follows.
struct SubtitleSyncPlan: Codable, Equatable, Sendable {
    /// At least one, sorted by `from`.
    var parts: [SubtitleSyncPart]

    static func single(_ mapping: SubtitleSyncMapping, lines: Int = 0) -> SubtitleSyncPlan {
        SubtitleSyncPlan(parts: [SubtitleSyncPart(from: 0, mapping: mapping, lines: lines)])
    }

    /// The mapping of the part with the most lines.
    var main: SubtitleSyncMapping {
        parts.max { $0.lines < $1.lines }?.mapping ?? .identity
    }

    var isSplit: Bool { parts.count > 1 }

    func mapping(at time: Double) -> SubtitleSyncMapping {
        var current = parts.first?.mapping ?? .identity
        for part in parts where part.from <= time + 0.0005 {
            current = part.mapping
        }
        return current
    }

    func callAsFunction(_ time: Double) -> Double { mapping(at: time)(time) }

    /// The largest move a line in `span` gets.
    func largestShift(over span: ClosedRange<Double>) -> Double {
        var largest = 0.0
        for (index, part) in parts.enumerated() {
            let lower = index == 0 ? span.lowerBound : max(part.from, span.lowerBound)
            let upper = index + 1 < parts.count ? min(parts[index + 1].from, span.upperBound) : span.upperBound
            guard lower <= upper else { continue }
            largest = max(largest, part.mapping.largestShift(over: lower...upper))
        }
        return largest
    }

    /// Tells copies made with different plans apart.
    var signature: String {
        parts.map { String(format: "%.2f:%.3f:%.6f", $0.from, $0.mapping.offset, $0.mapping.scale) }
            .joined(separator: "|")
    }
}

/// What AutoSubSync did and noticed beyond the main shift, for the diagnostics. The warnings are
/// lines whose shift the reference couldn't check well.
enum SubtitleSyncRemark: Equatable, Sendable {
    /// Song and sign lines left out of matching, and the songs on the subtitle's timeline.
    case songs(lines: Int, songs: [ClosedRange<Double>])
    /// The shift changes slowly through the subtitle (timed for another frame rate).
    case drift(startShift: Double, endShift: Double)
    /// A part got its own shift.
    case part(range: ClosedRange<Double>, lines: Int, shift: Double, mainShift: Double, evidence: PartEvidence)
    /// A long stretch moved by a fraction of a second onto the reference's line starts.
    case fineTuned(range: ClosedRange<Double>, delta: Double, startsBefore: Int, startsAfter: Int, lines: Int)
    /// How much of the lines' time the reference covers, and what chance alone gives.
    case score(match: Double, chance: Double)
    /// The share of line starts on a reference start, and what chance alone gives.
    case startScore(share: Double, chance: Double)
    case ambiguous(range: ClosedRange<Double>, lines: Int, low: Double, high: Double, kept: Double)
    case sparseReference(range: ClosedRange<Double>, lines: Int, references: Int, kept: Double)
    case noReference(range: ClosedRange<Double>, lines: Int, kept: Double)
    case beforeStart(lines: Int)

    enum PartEvidence: Equatable, Sendable {
        /// Line starts on the reference's line starts (within 0.3 s).
        case starts(hits: Int, of: Int)
        /// The best overlap with the reference's block around it.
        case block(before: Double, after: Double)
        /// Split off by the whole-subtitle search; the share of its time on the reference.
        case split(share: Double)
    }

    var isPart: Bool {
        if case .part = self { return true }
        return false
    }

    var isWarning: Bool {
        switch self {
        case .ambiguous, .sparseReference, .noReference, .beforeStart: return true
        case .songs, .drift, .part, .fineTuned, .score, .startScore: return false
        }
    }

    var text: String {
        switch self {
        case .songs(let lines, let songs):
            return L10n.format("subtitle_autosync_note_songs", fallback: "%d song and sign lines left out (songs %@)",
                               lines, songs.isEmpty ? "–" : songs.map(Self.range).joined(separator: ", "))
        case .drift(let start, let end):
            return L10n.format("subtitle_autosync_note_drift", fallback: "smooth drift %@ → %@", Self.shift(start), Self.shift(end))
        case .part(let range, let lines, let shift, let main, let evidence):
            let why: String
            switch evidence {
            case .starts(let hits, let of):
                why = L10n.format("subtitle_autosync_note_part_starts", fallback: "starts %d of %d on the reference", hits, of)
            case .block(let before, let after):
                why = L10n.format("subtitle_autosync_note_part_block", fallback: "match %@ → %@", Self.percent(before), Self.percent(after))
            case .split(let share):
                why = L10n.format("subtitle_autosync_note_part_split", fallback: "match %@", Self.percent(share))
            }
            return L10n.format("subtitle_autosync_note_part", fallback: "%@ (%d lines): %@ instead of %@, %@",
                               Self.range(range), lines, Self.shift(shift), Self.shift(main), why)
        case .fineTuned(let range, let delta, let before, let after, let lines):
            return L10n.format("subtitle_autosync_note_fine", fallback: "%@ fine-tuned by %@ (starts within 0.1 s: %d → %d of %d)",
                               Self.range(range), Self.shift(delta, digits: 2), before, after, lines)
        case .score(let match, let chance):
            return L10n.format("subtitle_autosync_note_score", fallback: "match %@ (by chance ~%@)", Self.percent(match), Self.percent(chance))
        case .startScore(let share, let chance):
            return "starts on the reference \(Self.percent(share)) (by chance ~\(Self.percent(chance)))"
        case .ambiguous(let range, let lines, let low, let high, let kept):
            return L10n.format("subtitle_autosync_warn_ambiguous", fallback: "%@ (%d lines): the match is flat %@ … %@, kept %@",
                               Self.range(range), lines, Self.shift(low), Self.shift(high), Self.shift(kept))
        case .sparseReference(let range, let lines, let references, let kept):
            return L10n.format("subtitle_autosync_warn_sparse", fallback: "%@ (%d lines): the video's subtitles have only %d lines here, kept %@",
                               Self.range(range), lines, references, Self.shift(kept))
        case .noReference(let range, let lines, let kept):
            return L10n.format("subtitle_autosync_warn_no_reference", fallback: "%@ (%d lines): nothing in the video's subtitles here (trailer or cut scene?), kept %@",
                               Self.range(range), lines, Self.shift(kept))
        case .beforeStart(let lines):
            return L10n.format("subtitle_autosync_warn_before_start", fallback: "%d lines start before the video", lines)
        }
    }

    static func clock(_ time: Double) -> String {
        let seconds = Int(abs(time).rounded(.down))
        return (time < 0 ? "−" : "") + String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func range(_ range: ClosedRange<Double>) -> String { clock(range.lowerBound) + "–" + clock(range.upperBound) }

    static func shift(_ value: Double, digits: Int = 1) -> String {
        String(format: "%@%.\(digits)f s", value < 0 ? "−" : "+", abs(value))
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
}

/// Finds the parts of an add-on subtitle that need a shift of their own, after the main mapping
/// is known. The rules come from the NimeToDex Blu-ray re-timing (anime-titulky, czmask.js),
/// tested on real episodes there:
/// - songs (dense runs of song and karaoke lines) are left out of matching, translations too;
/// - a short part (the intro before the opening) is bound to the reference's block around it
///   and to its neighbours (±20 s), and judged by overlap, or by line starts when those agree;
/// - long stretches are fine-tuned onto the reference's line starts when that clearly helps.
/// What alass does on the server (splitting a long part where the shift changes) is a dynamic
/// programme over candidate shifts here, with a penalty for every split.
enum SubtitleSyncParts {
    static let lineCap: Double = 8
    static let songGap: Double = 6
    static let songMinLines = 8
    static let songMinLength: Double = 40
    static let shortPart = 40
    static let shortPartMin = 4
    static let blockGap: Double = 30
    static let blockTolerance: Double = 1
    static let neighbourMax: Double = 20
    static let anchorRange: Double = 30
    static let startTolerance = 0.3
    static let startStrong = 0.6
    static let ambiguityRatio = 0.9
    static let ambiguitySpread: Double = 1
    static let fineMax = 0.4
    static let fineStep = 0.02
    static let fineTolerance = 0.1
    static let fineMin = 0.1
    static let fineLines = 30
    static let fineShare = 0.3
    static let fineGain = 1.25
    static let window = 8
    static let windowStride = 4
    static let searchRange: Double = 20
    static let minWindowGain = 0.35
    static let maxCandidates = 12
    static let splitPenalty = 2.5
    static let minPartLines = 6
    static let minPartShare = 0.5
    static let step = 0.1

    struct Interval: Equatable {
        var start: Double
        var end: Double
    }

    // MARK: The subtitle

    /// The lines to match on and the songs of an add-on subtitle.
    struct Target {
        let lines: [SubtitleTimingCue]
        let songs: [ClosedRange<Double>]
        let excluded: Int

        init(_ cues: [SubtitleTimingCue]) {
            let songLines = cues.filter(\.isSongLike).sorted { $0.start < $1.start }
            var clusters: [(start: Double, end: Double, count: Int)] = []
            for line in songLines {
                if let last = clusters.last, line.start - last.end <= SubtitleSyncParts.songGap {
                    clusters[clusters.count - 1] = (last.start, max(last.end, line.end), last.count + 1)
                } else {
                    clusters.append((line.start, line.end, 1))
                }
            }
            let songs = clusters
                .filter { $0.count >= SubtitleSyncParts.songMinLines && $0.end - $0.start >= SubtitleSyncParts.songMinLength }
                .map { $0.start...$0.end }
            func inSong(_ time: Double) -> Bool {
                songs.contains { time >= $0.lowerBound - 1 && time <= $0.upperBound + 1 }
            }
            let dialogue = cues.filter(\.isDialogue)
            let kept = dialogue.filter { !inSong($0.start) }.sorted { $0.start < $1.start }
            if kept.count >= 10 {
                lines = kept
                self.songs = songs
                excluded = cues.count - kept.count
            } else {
                let all = dialogue.sorted { $0.start < $1.start }
                lines = all
                self.songs = []
                excluded = cues.count - all.count
            }
        }
    }

    // MARK: The reference

    /// The video's own subtitle timeline: merged intervals, line starts, blocks between silences
    /// of 30 s or more (where the songs are: the dialogue track has nothing there).
    struct Reference {
        let merged: [Interval]
        let starts: [Double]
        /// Starts of lines 0.25–8 s long (no signs or karaoke).
        let checkStarts: [Double]
        let blocks: [Block]

        struct Block {
            var start: Double
            var end: Double
            var intervals: [Interval]
            var duration: Double
        }

        init(_ cues: [SubtitleTimingCue]) {
            let sorted = cues.sorted { $0.start < $1.start }
            var merged: [Interval] = []
            for cue in sorted where cue.end > cue.start {
                if let last = merged.last, cue.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, cue.end)
                } else {
                    merged.append(Interval(start: cue.start, end: cue.end))
                }
            }
            self.merged = merged
            starts = sorted.map(\.start)
            checkStarts = sorted.filter { $0.end - $0.start >= 0.25 && $0.end - $0.start <= SubtitleSyncParts.lineCap }.map(\.start)
            var blocks: [Block] = []
            for interval in merged {
                if let last = blocks.last, interval.start - last.end < SubtitleSyncParts.blockGap {
                    blocks[blocks.count - 1].end = max(last.end, interval.end)
                    blocks[blocks.count - 1].intervals.append(interval)
                    blocks[blocks.count - 1].duration += interval.end - interval.start
                } else {
                    blocks.append(Block(start: interval.start, end: interval.end, intervals: [interval],
                                        duration: interval.end - interval.start))
                }
            }
            self.blocks = blocks
        }

        /// A time inside one of the blocks, where the reference can say whether a line fits.
        func isCheckable(_ time: Double) -> Bool {
            blocks.contains { time >= $0.start - 2 && time <= $0.end + 2 }
        }
    }

    /// Time of `pairs` (sorted by start) covered by `intervals` (merged, sorted). Lines before
    /// the start of the video count nothing.
    static func overlap(_ pairs: [Interval], _ intervals: [Interval]) -> Double {
        var total = 0.0
        for pair in pairs where pair.end > 0 {
            var index = firstEnding(after: pair.start, in: intervals)
            while index < intervals.count, intervals[index].start < pair.end {
                total += min(pair.end, intervals[index].end) - max(pair.start, intervals[index].start)
                index += 1
            }
        }
        return total
    }

    /// First interval that ends after `time`.
    static func firstEnding(after time: Double, in intervals: [Interval]) -> Int {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Where `line` lands under `main` moved by `delta`, at most 8 s long.
    static func span(_ line: SubtitleTimingCue, _ main: SubtitleSyncMapping, _ delta: Double) -> Interval {
        let start = main(line.start) + delta
        return Interval(start: start, end: start + min(max(main(line.end) - main(line.start), 0), lineCap))
    }

    static func spans(_ lines: [SubtitleTimingCue], _ main: SubtitleSyncMapping, _ delta: Double) -> [Interval] {
        lines.map { span($0, main, delta) }.sorted { $0.start < $1.start }
    }

    static func duration(_ lines: [SubtitleTimingCue], _ main: SubtitleSyncMapping) -> Double {
        let total = lines.reduce(0.0) { $0 + min(max(main($1.end) - main($1.start), 0), lineCap) }
        return total > 0 ? total : 1
    }

    /// Share of a line's time on the reference; −1 for a line that would start before the video.
    static func share(_ line: SubtitleTimingCue, _ main: SubtitleSyncMapping, _ delta: Double, _ reference: Reference) -> Double {
        let interval = span(line, main, delta)
        if interval.start < -0.5 { return -1 }
        let length = interval.end - interval.start
        guard length > 0 else { return 0 }
        return overlap([interval], reference.merged) / length
    }

    static func grid(_ low: Double, _ high: Double) -> [Double] {
        guard low <= high else { return [] }
        let first = Int((low / step - 1e-9).rounded(.up))
        let last = Int((high / step + 1e-9).rounded(.down))
        guard first <= last else { return [] }
        return (first...last).map { Double($0) * step }
    }

    /// The middle of the run of best values nearest `near` (a ±0.5 s tolerance makes plateaus,
    /// and their edge would be half a second off).
    static func plateauCenter(_ curve: [(Double, Double)], best: Double, near: Double) -> Double {
        var plateaus: [[Double]] = []
        for (offset, value) in curve where abs(value - best) <= 1e-9 {
            if let last = plateaus.last?.last, offset - last <= step + 1e-6 {
                plateaus[plateaus.count - 1].append(offset)
            } else {
                plateaus.append([offset])
            }
        }
        guard let chosen = plateaus.min(by: { abs($0[$0.count / 2] - near) < abs($1[$1.count / 2] - near) }) else { return near }
        return chosen[chosen.count / 2]
    }

    // MARK: The plan

    struct Outcome {
        var plan: SubtitleSyncPlan
        var remarks: [SubtitleSyncRemark]
    }

    private struct Segment {
        var delta: Double
        var lines: [SubtitleTimingCue]
        var evidence: SubtitleSyncRemark.PartEvidence?
        var first: Double { lines.first?.start ?? 0 }
        var last: Double { lines.last?.start ?? 0 }
    }

    /// The parts of `target` under `main`, judged against `reference`.
    static func plan(target: Target, reference: Reference, main: SubtitleSyncMapping) -> Outcome {
        var remarks: [SubtitleSyncRemark] = []
        if target.excluded > 0, !target.songs.isEmpty {
            remarks.append(.songs(lines: target.excluded, songs: target.songs))
        }
        guard !target.lines.isEmpty else { return Outcome(plan: .single(main), remarks: remarks) }

        // Parts between the songs; a long one splits where its shift changes.
        let songStarts = target.songs.map(\.lowerBound)
        var groups: [[SubtitleTimingCue]] = Array(repeating: [], count: songStarts.count + 1)
        for line in target.lines {
            groups[songStarts.filter { $0 <= line.start }.count].append(line)
        }
        var segments: [Segment] = []
        for group in groups where !group.isEmpty {
            if group.count > shortPart {
                segments += splitLong(group, main: main, reference: reference)
            } else {
                segments.append(Segment(delta: 0, lines: group, evidence: nil))
            }
        }

        // Short parts: bound to the reference's block and to the long parts around them.
        let longs = segments.filter { $0.lines.count > shortPart }
        for index in segments.indices where (shortPartMin...shortPart).contains(segments[index].lines.count) {
            let segment = segments[index]
            let neighbour = nearestLong(to: segment, in: longs)?.delta
            let before = longs.filter { $0.last < segment.first }
            let after = longs.filter { $0.first > segment.first }
            let regionStart = (before.map { seg -> Double in
                let line = seg.lines[seg.lines.count - 1]
                return span(line, main, seg.delta).end
            }.max() ?? -1e9) + blockTolerance
            let regionEnd = (after.map { main($0.lines[0].start) + $0.delta }.min() ?? 1e9) - blockTolerance
            let range = segment.first...max(segment.first, segment.lines.map(\.end).max() ?? segment.first)
            let count = segment.lines.count
            guard let fit = fitShort(segment.lines, main: main, was: segment.delta, neighbour: neighbour,
                                     reference: reference, region: regionStart...max(regionStart, regionEnd)) else { continue }
            switch fit {
            case .keep:
                continue
            case .noReference:
                let kept = neighbour ?? segment.delta
                segments[index].delta = kept
                segments[index].evidence = nil
                remarks.append(.noReference(range: range, lines: count, kept: shift(main, kept, at: segment.first)))
            case .fitted(let result):
                if result.change {
                    segments[index].delta = result.offset
                    if let starts = result.starts {
                        segments[index].evidence = .starts(hits: starts.hits, of: starts.of)
                    } else {
                        segments[index].evidence = .block(before: result.current, after: result.iou)
                    }
                }
                let kept = shift(main, segments[index].delta, at: segment.first)
                if result.starts == nil, result.spread.upperBound - result.spread.lowerBound > ambiguitySpread {
                    remarks.append(.ambiguous(range: range, lines: count,
                                              low: shift(main, result.spread.lowerBound, at: segment.first),
                                              high: shift(main, result.spread.upperBound, at: segment.first), kept: kept))
                }
                if Double(result.references) < Double(count) / 2 {
                    remarks.append(.sparseReference(range: range, lines: count, references: result.references, kept: kept))
                }
            }
        }

        // Long stretches: onto the reference's line starts when that clearly helps.
        if reference.checkStarts.count >= fineLines {
            for index in segments.indices where segments[index].lines.count > shortPart {
                guard let fine = fineStarts(segments[index].lines, main: main, delta: segments[index].delta,
                                            starts: reference.checkStarts), fine.apply else { continue }
                let before = coverage(segments, main: main, reference: reference)
                segments[index].delta += fine.offset
                if coverage(segments, main: main, reference: reference) < before - 0.02 {
                    segments[index].delta -= fine.offset
                    continue
                }
                remarks.append(.fineTuned(range: segments[index].first...segments[index].last, delta: fine.offset,
                                          startsBefore: fine.before, startsAfter: fine.after, lines: fine.lines))
            }
        }

        // The plan: one part per run of equal shifts.
        segments.sort { $0.first < $1.first }
        var parts: [SubtitleSyncPart] = []
        var partRemarks: [SubtitleSyncRemark] = []
        for segment in segments {
            let mapping = SubtitleSyncMapping(scale: main.scale, offset: main.offset + segment.delta)
            if let last = parts.last, abs(last.mapping.offset - mapping.offset) < 1e-6 {
                parts[parts.count - 1].lines += segment.lines.count
                continue
            }
            parts.append(SubtitleSyncPart(from: segment.first, mapping: mapping, lines: segment.lines.count))
            if abs(segment.delta) > 1e-6 {
                partRemarks.append(.part(range: segment.first...segment.last, lines: segment.lines.count,
                                         shift: shift(main, segment.delta, at: segment.first),
                                         mainShift: shift(main, 0, at: segment.first),
                                         evidence: segment.evidence ?? .split(share: 0)))
            }
        }
        if parts.count == 1 { parts[0].from = 0 }
        return Outcome(plan: SubtitleSyncPlan(parts: parts), remarks: partRemarks + remarks)
    }

    /// How far a line at `time` moves under `main` moved by `delta`.
    static func shift(_ main: SubtitleSyncMapping, _ delta: Double, at time: Double) -> Double {
        main(time) + delta - time
    }

    private static func nearestLong(to segment: Segment, in longs: [Segment]) -> Segment? {
        longs.min { distance($0, segment.first) < distance($1, segment.first) }
    }

    private static func distance(_ segment: Segment, _ time: Double) -> Double {
        if time < segment.first { return segment.first - time }
        if time > segment.last { return time - segment.last }
        return 0
    }

    private static func coverage(_ segments: [Segment], main: SubtitleSyncMapping, reference: Reference) -> Double {
        let pairs = segments.flatMap { segment in segment.lines.map { span($0, main, segment.delta) } }.sorted { $0.start < $1.start }
        let total = segments.reduce(0.0) { $0 + duration($1.lines, main) }
        return overlap(pairs, reference.merged) / max(total, 1)
    }

    // MARK: Long parts

    /// Splits a long part where its shift changes: every window of lines proposes the shift that
    /// puts it on the reference best, and a dynamic programme picks one per line with a penalty
    /// for every change. A part survives only with enough lines clearly better placed than under
    /// the main mapping, in its own place in the video.
    private static func splitLong(_ lines: [SubtitleTimingCue], main: SubtitleSyncMapping, reference: Reference) -> [Segment] {
        let count = lines.count
        guard count >= 2 * minPartLines else { return [Segment(delta: 0, lines: lines, evidence: nil)] }

        var proposals: [Int: (delta: Double, gain: Double)] = [:]
        let offsets = grid(-searchRange, searchRange)
        var start = 0
        while start < max(1, count - window + 1) {
            let part = Array(lines[start..<min(count, start + window)])
            let length = duration(part, main)
            let curve = offsets.map { ($0, overlap(spans(part, main, $0), reference.merged) / length) }
            let best = curve.map { $0.1 }.max() ?? 0
            let current = overlap(spans(part, main, 0), reference.merged) / length
            if best - current >= minWindowGain {
                let delta = plateauCenter(curve, best: best, near: 0)
                let key = Int((delta / 0.3).rounded())
                if proposals[key].map({ $0.gain < best - current }) ?? true {
                    proposals[key] = (delta, best - current)
                }
            }
            start += windowStride
        }
        let deltas = [0.0] + proposals.values.sorted { $0.gain > $1.gain }
            .prefix(maxCandidates).map { $0.delta }.filter { abs($0) > 0.25 }
        guard deltas.count > 1 else { return [Segment(delta: 0, lines: lines, evidence: nil)] }
        let states = deltas.count
        let score = lines.map { line in deltas.map { share(line, main, $0, reference) } }

        // Best total share with a penalty per change; on a tie the line stays where it was.
        var total = [score[0]]
        var from: [[Int]] = [Array(0..<states)]
        for index in 1..<count {
            let previous = total[index - 1]
            var bestPrevious = 0
            for state in 1..<states where previous[state] > previous[bestPrevious] { bestPrevious = state }
            var row = [Double](repeating: 0, count: states)
            var origin = [Int](repeating: 0, count: states)
            for state in 0..<states {
                let switched = previous[bestPrevious] - splitPenalty
                if bestPrevious != state, switched > previous[state] + 1e-9 {
                    row[state] = score[index][state] + switched
                    origin[state] = bestPrevious
                } else {
                    row[state] = score[index][state] + previous[state]
                    origin[state] = state
                }
            }
            total.append(row)
            from.append(origin)
        }
        var chosen = [Int](repeating: 0, count: count)
        var last = 0
        for state in 1..<states where total[count - 1][state] > total[count - 1][last] + 1e-9 { last = state }
        chosen[count - 1] = last
        for index in stride(from: count - 1, to: 0, by: -1) {
            chosen[index - 1] = from[index][chosen[index]]
        }

        func runs() -> [(state: Int, first: Int, last: Int)] {
            var result: [(state: Int, first: Int, last: Int)] = []
            for (index, state) in chosen.enumerated() {
                if let tail = result.last, tail.state == state {
                    result[result.count - 1].last = index
                } else {
                    result.append((state, index, index))
                }
            }
            return result
        }
        func informative(_ run: (state: Int, first: Int, last: Int)) -> [Int] {
            (run.first...run.last).filter { score[$0][run.state] >= 0.1 || score[$0][0] >= 0.1 || score[$0][0] < 0 }
        }
        func gain(_ run: (state: Int, first: Int, last: Int)) -> Double {
            guard run.state != 0 else { return .infinity }
            return informative(run).reduce(0) { $0 + score[$1][run.state] - score[$1][0] }
        }
        func reset(_ run: (state: Int, first: Int, last: Int)) {
            for index in run.first...run.last { chosen[index] = 0 }
        }

        // Enough lines clearly better placed than under the main mapping.
        var changed = true
        while changed {
            changed = false
            for run in runs() where run.state != 0 {
                let used = informative(run)
                let own = used.reduce(0) { $0 + score[$1][run.state] }
                let base = used.reduce(0) { $0 + score[$1][0] }
                if used.count < minPartLines || own / Double(max(used.count, 1)) < minPartShare
                    || own - base < max(2.5, 0.25 * Double(used.count)) {
                    reset(run)
                    changed = true
                }
            }
        }

        // Each part in its own place: its lines on the reference may not land among those of the
        // part next to it (a few stray lines of a cut scene don't count). The weaker one gives way.
        func matched(_ run: (state: Int, first: Int, last: Int)) -> [Int] {
            (run.first...run.last).filter { score[$0][run.state] >= 0.3 }
        }
        func conflict(_ a: (state: Int, first: Int, last: Int), _ b: (state: Int, first: Int, last: Int)) -> Bool {
            let inA = matched(a), inB = matched(b)
            guard !inA.isEmpty, !inB.isEmpty else { return false }
            let endA = inA.map { span(lines[$0], main, deltas[a.state]).end }.max() ?? 0
            let startB = inB.map { span(lines[$0], main, deltas[b.state]).start }.min() ?? 0
            if endA - 2 <= startB { return false }
            let crossing = inB.filter { span(lines[$0], main, deltas[b.state]).start < endA - 2 }.count
                + inA.filter { span(lines[$0], main, deltas[a.state]).end > startB + 2 }.count
            return Double(crossing) > max(2, 0.2 * Double(min(inA.count, inB.count)))
        }
        changed = true
        while changed {
            changed = false
            let current = runs()
            for index in 0..<max(0, current.count - 1) {
                let a = current[index], b = current[index + 1]
                guard a.state != 0 || b.state != 0, conflict(a, b) else { continue }
                reset(gain(a) < gain(b) ? a : b)
                changed = true
                break
            }
        }

        // Lines placed by neither side at a change go with the part before it.
        let settled = runs()
        if settled.count > 1 {
            for index in 1..<settled.count {
                let before = settled[index - 1].state, run = settled[index]
                var line = run.first
                while line <= run.last, score[line][run.state] < 0.1, score[line][before] < 0.1 {
                    chosen[line] = before
                    line += 1
                }
            }
        }

        return runs().map { run in
            let part = Array(lines[run.first...run.last])
            let evidence: SubtitleSyncRemark.PartEvidence? = run.state == 0 ? nil : {
                let used = informative(run)
                let own = used.reduce(0) { $0 + max(0, score[$1][run.state]) }
                return .split(share: own / Double(max(used.count, 1)))
            }()
            return Segment(delta: deltas[run.state], lines: part, evidence: evidence)
        }
    }

    // MARK: Short parts

    struct ShortFitResult {
        var offset: Double
        var iou: Double
        var current: Double
        var change: Bool
        var spread: ClosedRange<Double>
        var references: Int
        var starts: (hits: Int, of: Int)?
    }

    enum ShortFit {
        /// The reference can't place it: keep what it has.
        case keep
        /// The reference has nothing there (a trailer, a cut scene): the neighbours' shift.
        case noReference
        case fitted(ShortFitResult)
    }

    /// A short part (the intro before the opening) has to lie inside one block of the reference
    /// (±1 s), or, where the reference is sparse, between the long parts around it; no more than
    /// 20 s from its neighbours. Within that the best two-sided overlap wins; when most of its
    /// line starts sit on the reference's (±0.3 s), those decide.
    static func fitShort(
        _ part: [SubtitleTimingCue],
        main: SubtitleSyncMapping,
        was: Double,
        neighbour: Double?,
        reference: Reference,
        region: ClosedRange<Double>
    ) -> ShortFit? {
        guard !reference.blocks.isEmpty, !part.isEmpty else { return nil }
        let first = part.map { main($0.start) }.min() ?? 0
        let lastEnd = part.map { span($0, main, 0).end }.max() ?? first
        let anchor = neighbour.map { abs(was - $0) <= neighbourMax ? was : $0 } ?? was
        let a = first + anchor, b = lastEnd + anchor
        var block = reference.blocks[0]
        var blockScore = -Double.infinity
        for candidate in reference.blocks {
            let shared = min(b, candidate.end) - max(a, candidate.start)
            let value = shared > 0 ? shared : -min(abs(candidate.start - b), abs(a - candidate.end))
            if value > blockScore { blockScore = value; block = candidate }
        }
        var low: Double, high: Double
        let target: Reference.Block
        if lastEnd - first <= block.end - block.start + 2 * blockTolerance {
            low = block.start - blockTolerance - first
            high = block.end + blockTolerance - lastEnd
            target = block
        } else {
            low = region.lowerBound - first
            high = region.upperBound - lastEnd
            let intervals = reference.blocks.flatMap(\.intervals).filter { $0.end > region.lowerBound && $0.start < region.upperBound }
            target = Reference.Block(start: region.lowerBound, end: region.upperBound, intervals: intervals,
                                     duration: intervals.reduce(0) { $0 + $1.end - $1.start })
        }
        low = max(low, anchor - anchorRange, -first - 0.5)
        high = min(high, anchor + anchorRange)
        if let neighbour {
            low = max(low, neighbour - neighbourMax)
            high = min(high, neighbour + neighbourMax)
        }
        guard low <= high else { return .noReference }

        let length = duration(part, main)
        func iou(_ delta: Double) -> Double {
            let shared = overlap(spans(part, main, delta), target.intervals)
            let union = length + target.duration - shared
            return union > 0 ? shared / union : 0
        }
        let offsets = grid(low, high)
        guard !offsets.isEmpty else { return .keep }
        let curve = offsets.map { ($0, iou($0)) }
        let best = curve.map { $0.1 }.max() ?? 0
        var offset = plateauCenter(curve, best: best, near: anchor)

        var starts: (hits: Int, of: Int)?
        if !reference.checkStarts.isEmpty {
            let lineStarts = part.map { main($0.start) }.sorted()
            func hits(_ delta: Double) -> Int {
                lineStarts.reduce(0) { count, start in
                    let value = start + delta
                    let index = SubtitleSyncAligner.lowerBound(reference.checkStarts, value - startTolerance)
                    return count + (index < reference.checkStarts.count && abs(reference.checkStarts[index] - value) <= startTolerance ? 1 : 0)
                }
            }
            let hitCurve = offsets.map { ($0, Double(hits($0))) }
            let most = hitCurve.map { $0.1 }.max() ?? 0
            if most >= max(3, (Double(part.count) * startStrong).rounded(.up)) {
                offset = plateauCenter(hitCurve, best: most, near: anchor)
                starts = (Int(most), part.count)
            }
        }
        let good = curve.filter { $0.1 >= best * ambiguityRatio }.map { $0.0 }
        let spread = starts != nil ? offset...offset : (good.min() ?? offset)...(good.max() ?? offset)
        let references = reference.checkStarts.filter { $0 >= first + offset - 0.5 && $0 <= lastEnd + offset }.count
        if references == 0 { return .noReference }
        let current = iou(was)
        let inside = part.allSatisfy {
            let interval = span($0, main, was)
            return interval.start >= target.start - blockTolerance && interval.end <= target.end + blockTolerance
        }
        let change = (!inside || starts != nil || best >= current + 0.1) && abs(offset - was) > 0.3
        return .fitted(ShortFitResult(
            offset: offset, iou: curve.first { abs($0.0 - offset) < 1e-9 }?.1 ?? best, current: current,
            change: change, spread: spread, references: references, starts: starts))
    }

    // MARK: Fine-tuning

    struct FineResult {
        var lines: Int
        var before: Int
        var after: Int
        var offset: Double
        var apply: Bool
    }

    /// A long stretch moved by up to ±0.4 s so that clearly more line starts sit on the
    /// reference's (within 0.1 s): by the median of their distances, all lines at once.
    static func fineStarts(_ lines: [SubtitleTimingCue], main: SubtitleSyncMapping, delta: Double, starts: [Double]) -> FineResult? {
        let usable = lines.filter { $0.end - $0.start >= 0.25 && $0.end - $0.start <= lineCap }
        guard usable.count >= fineLines else { return nil }
        let mapped = usable.map { main($0.start) + delta }.sorted()
        func nearest(_ value: Double) -> Double? { SubtitleSyncAligner.nearest(starts, to: value) }
        func hits(_ offset: Double) -> Int {
            mapped.reduce(0) { count, start in
                guard let near = nearest(start + offset) else { return count }
                return count + (abs(near - start - offset) <= fineTolerance ? 1 : 0)
            }
        }
        let before = hits(0)
        var best = (offset: 0.0, hits: before)
        var offset = -fineMax
        while offset <= fineMax + 1e-9 {
            let value = hits(offset)
            if value > best.hits || (value == best.hits && abs(offset) < abs(best.offset)) { best = (offset, value) }
            offset += fineStep
        }
        let deviations = mapped.compactMap { start -> Double? in
            guard let near = nearest(start) else { return nil }
            let deviation = near - start
            return abs(deviation - best.offset) <= fineTolerance ? deviation : nil
        }.sorted()
        let shift = deviations.isEmpty ? best.offset : deviations[deviations.count / 2]
        let apply = abs(shift) >= fineMin && Double(best.hits) >= Double(usable.count) * fineShare
            && Double(best.hits) >= Double(before) * fineGain && best.hits - before >= 5
        return FineResult(lines: usable.count, before: before, after: best.hits, offset: shift, apply: apply)
    }
}
