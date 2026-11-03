import Foundation

/// How an add-on subtitle's times move onto the video: `time * scale + offset`, in seconds.
/// A scale other than 1 corrects a subtitle made for another frame rate (25 against 23.976).
struct SubtitleSyncMapping: Codable, Equatable, Sendable {
    var scale: Double
    var offset: Double

    static let identity = SubtitleSyncMapping(scale: 1, offset: 0)

    func callAsFunction(_ time: Double) -> Double { time * scale + offset }

    /// The largest move this mapping makes to a time in `span`.
    func largestShift(over span: ClosedRange<Double>) -> Double {
        max(abs(self(span.lowerBound) - span.lowerBound), abs(self(span.upperBound) - span.upperBound))
    }

    /// How far apart two mappings put a time in `span` at most.
    func distance(to other: SubtitleSyncMapping, over span: ClosedRange<Double>) -> Double {
        max(abs(self(span.lowerBound) - other(span.lowerBound)), abs(self(span.upperBound) - other(span.upperBound)))
    }
}

/// How well a mapping puts the subtitle's lines onto the reference.
struct SubtitleSyncFit: Equatable, Sendable {
    var mapping: SubtitleSyncMapping
    /// Share of lines that start within half a second of a reference line, or mostly overlap one.
    var coverage: Double
    /// Lines that start within half a second of a reference line.
    var startMatches: Int
    /// The longest run of lines next to nothing in the reference.
    var longestMiss: Int
    /// Median distance between matched starts after the mapping, in seconds.
    var medianError: Double
    var lineCount: Int
    /// Lines the reference can check: those landing inside its blocks (not in a long silence).
    var checkable: Int = 0
    /// Share of the lines' time the reference covers, and what chance alone gives.
    var match: Double = 0
    var chance: Double = 0
    /// What chance alone gives for a line start within `startTolerance` of a reference start.
    var startChance: Double = 0
}

enum SubtitleSyncVerdict: Equatable, Sendable {
    case confident
    /// Too few lines (in the subtitle or the reference) to judge.
    case tooFewLines
    /// No mapping puts enough lines on the reference.
    case noMatch
    /// Two different mappings fit about as well: no telling which is right.
    case ambiguous
}

struct SubtitleSyncAlignment: Equatable, Sendable {
    var fit: SubtitleSyncFit?
    var verdict: SubtitleSyncVerdict
    /// How each line moves (parts with shifts of their own), with what was noticed on the way.
    var plan: SubtitleSyncPlan? = nil
    var remarks: [SubtitleSyncRemark] = []
}

/// Finds the mapping that lines an add-on subtitle up with a reference timeline (the subtitles
/// embedded in the video), from line timing only, so the two may be in different languages.
///
/// Every line start votes for the offsets that would put it on a reference start; the strongest
/// offsets of each frame rate ratio are then scored on all lines and refined to the median error.
/// A mapping is used only when most lines land on the reference and no other mapping comes close.
enum SubtitleSyncAligner {
    /// 1 first: it wins a tie. Then the PAL speed-up both ways, 24 against 23.976, 25 against 24.
    static let scales: [Double] = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25]
    static let maxOffset: Double = 180
    static let binWidth: Double = 0.1
    static let smoothingBins = 3
    static let peaksPerScale = 3
    static let peakSeparation: Double = 1.5
    static let startTolerance: Double = 0.5
    static let minLines = 20
    static let minCoverage: Double = 0.8
    /// With a sparse reference (PGS, fewer lines than the subtitle) less coverage does, when the
    /// match is clearly above chance.
    static let minSparseCoverage: Double = 0.6
    static let sparseLift: Double = 1.5
    static let minStartShare: Double = 0.4
    static let maxMissRun = 12
    /// Match against what chance gives on a reference this dense (anime-titulky: < 1.2 = the
    /// reference doesn't belong to the subtitle).
    static let minLift: Double = 1.2
    /// A reference covering this much of the time by chance is dense (dialogue and signs in one
    /// track): its overlap tells little, so the line starts decide…
    static let denseReferenceChance: Double = 0.5
    /// …when this many times more of them land on a reference start than chance gives
    /// (KAA DVD: 68 % of the starts against ~35 % by chance, overlap 79 % against 70 %).
    static let minStartLift: Double = 1.5
    /// The main mapping has to put this share of the line starts on the reference before
    /// parts are looked for.
    static let partsMinStartShare: Double = 0.5
    /// A refined frame rate ratio at most this far from the voted one (czmask smoothDrift: 0.2 %).
    static let maxDrift: Double = 0.002
    /// A different mapping with this share of the best one's matched starts makes the result
    /// ambiguous. Starts, not overlap: a mapping a second off still overlaps most lines.
    static let rivalShare: Double = 0.8
    /// Mappings closer than this everywhere count as the same answer.
    static let distinctMappings: Double = 1.0

    static func align(target: [SubtitleTimingCue], reference: [SubtitleTimingCue]) -> SubtitleSyncAlignment {
        let prepared = SubtitleSyncParts.Target(target)
        let lines = prepared.lines
        let referenceCues = reference.sorted { $0.start < $1.start }
        guard lines.count >= minLines, referenceCues.count >= minLines else {
            return SubtitleSyncAlignment(fit: nil, verdict: .tooFewLines)
        }
        let starts = referenceCues.map(\.start)
        let intervals = mergedIntervals(referenceCues)
        let span = lines[0].start...max(lines[lines.count - 1].end, lines[0].start + 1)

        var fits: [SubtitleSyncFit] = []
        for scale in scales {
            for offset in votedOffsets(lines: lines, referenceStarts: starts, scale: scale) {
                var fit = evaluate(lines: lines, referenceStarts: starts, intervals: intervals,
                                   mapping: SubtitleSyncMapping(scale: scale, offset: offset))
                for _ in 0..<2 where fit.startMatches > 0 && abs(fit.medianError) > 0.001 {
                    let refined = SubtitleSyncMapping(scale: scale, offset: fit.mapping.offset + fit.medianError)
                    let next = evaluate(lines: lines, referenceStarts: starts, intervals: intervals, mapping: refined)
                    guard next.coverage >= fit.coverage - 0.001 else { break }
                    fit = next
                }
                fits.append(fit)
            }
        }
        guard var best = fits.max(by: { better($1, than: $0) }) else {
            return SubtitleSyncAlignment(fit: nil, verdict: .noMatch)
        }
        // A frame rate change only when it clearly fits better than none.
        if best.mapping.scale != 1,
           let plain = fits.filter({ $0.mapping.scale == 1 }).max(by: { better($1, than: $0) }),
           Double(plain.startMatches) >= Double(best.startMatches) - 0.02 * Double(lines.count) {
            best = plain
        }

        // Parts with shifts of their own, once the main mapping explains most of the subtitle.
        let timeline = SubtitleSyncParts.Reference(referenceCues)
        var remarks: [SubtitleSyncRemark] = []
        var main = best.mapping
        if let smooth = refinedDrift(lines: lines, mapping: main, starts: starts, timeline: timeline) {
            main = smooth
            remarks.append(.drift(startShift: main(span.lowerBound) - span.lowerBound,
                                  endShift: main(span.upperBound) - span.upperBound))
        }
        let plan: SubtitleSyncPlan
        if Double(best.startMatches) >= partsMinStartShare * Double(lines.count) {
            let outcome = SubtitleSyncParts.plan(target: prepared, reference: timeline, main: main)
            plan = outcome.plan
            remarks = outcome.remarks + remarks
        } else {
            plan = .single(main, lines: lines.count)
            if prepared.excluded > 0, !prepared.songs.isEmpty {
                remarks.insert(.songs(lines: prepared.excluded, songs: prepared.songs), at: 0)
            }
        }

        var fit = evaluate(lines: lines, referenceStarts: starts, intervals: intervals, plan: plan, timeline: timeline)
        fit.mapping = plan.main
        remarks.append(.score(match: fit.match, chance: fit.chance))
        let startShare = Double(fit.startMatches) / Double(max(fit.checkable, 1))
        let startLift = fit.startChance > 0 ? startShare / fit.startChance : 0
        if fit.chance >= denseReferenceChance {
            remarks.append(.startScore(share: startShare, chance: fit.startChance))
        }
        let beforeStart = lines.filter { plan($0.start) < -1 }.count
        if beforeStart > 0 { remarks.append(.beforeStart(lines: beforeStart)) }

        let lift = fit.chance > 0 ? fit.match / fit.chance : 0
        let checkable = Double(fit.checkable)
        let enoughLines = checkable >= max(Double(minLines), 0.5 * Double(lines.count))
        let covered = fit.coverage >= minCoverage
            || (fit.coverage >= minSparseCoverage && lift >= sparseLift && Double(fit.startMatches) >= minStartShare * checkable)
        let enoughStarts = Double(fit.startMatches) >= max(Double(minLines), minStartShare * checkable)
        let lifted = lift >= minLift || (fit.chance >= denseReferenceChance && startLift >= minStartLift)
        guard enoughLines, covered, enoughStarts, fit.longestMiss <= maxMissRun, lifted else {
            return SubtitleSyncAlignment(fit: fit, verdict: .noMatch, plan: plan, remarks: remarks)
        }
        // A rival is a different mapping that fits about as well. One that matches a part of the
        // plan over that part's own stretch (half of a cut episode) is that part, not a rival.
        let partRanges: [(mapping: SubtitleSyncMapping, range: ClosedRange<Double>)] = plan.parts.enumerated().map { index, part in
            let lower = index == 0 ? span.lowerBound : max(part.from, span.lowerBound)
            let upper = index + 1 < plan.parts.count ? min(plan.parts[index + 1].from, span.upperBound) : span.upperBound
            return (part.mapping, lower...max(lower, upper))
        }
        let rival = fits.contains { other in
            other.mapping.distance(to: best.mapping, over: span) > distinctMappings
                && !partRanges.contains { other.mapping.distance(to: $0.mapping, over: $0.range) <= distinctMappings }
                && Double(other.startMatches) >= Double(best.startMatches) * rivalShare
        }
        return SubtitleSyncAlignment(fit: fit, verdict: rival ? .ambiguous : .confident, plan: plan, remarks: remarks)
    }

    /// The slow drift of a subtitle timed for a slightly different speed (czmask smoothDrift):
    /// a line through the matched starts, used when it is within 0.2 % of the voted ratio and
    /// puts more of the lines' time on the reference.
    static func refinedDrift(
        lines: [SubtitleTimingCue],
        mapping: SubtitleSyncMapping,
        starts: [Double],
        timeline: SubtitleSyncParts.Reference
    ) -> SubtitleSyncMapping? {
        var points: [(x: Double, y: Double)] = lines.compactMap { line in
            let mapped = mapping(line.start)
            guard let near = nearest(starts, to: mapped), abs(near - mapped) <= startTolerance else { return nil }
            return (line.start, near)
        }
        guard points.count >= 30 else { return nil }
        var slope = mapping.scale
        var intercept = mapping.offset
        for _ in 0..<3 {
            let count = Double(points.count)
            let meanX = points.reduce(0) { $0 + $1.x } / count
            let meanY = points.reduce(0) { $0 + $1.y } / count
            let sxx = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
            guard sxx > 0 else { return nil }
            slope = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) } / sxx
            intercept = meanY - slope * meanX
            let kept = points.filter { abs($0.y - (slope * $0.x + intercept)) <= 0.3 }
            if kept.count == points.count || kept.count < 30 { break }
            points = kept
        }
        let drift = abs(slope - mapping.scale)
        guard drift <= maxDrift, drift >= 0.00005 else { return nil }
        let candidate = SubtitleSyncMapping(scale: slope, offset: intercept)
        func covered(_ mapping: SubtitleSyncMapping) -> Double {
            SubtitleSyncParts.overlap(SubtitleSyncParts.spans(lines, mapping, 0), timeline.merged)
        }
        return covered(candidate) > covered(mapping) * 1.002 ? candidate : nil
    }

    /// The final fit under a plan, counted over the lines the reference can check.
    static func evaluate(
        lines: [SubtitleTimingCue],
        referenceStarts starts: [Double],
        intervals: [ClosedRange<Double>],
        plan: SubtitleSyncPlan,
        timeline: SubtitleSyncParts.Reference
    ) -> SubtitleSyncFit {
        var covered = 0
        var startMatches = 0
        var checkable = 0
        var run = 0
        var longest = 0
        var errors: [Double] = []
        var pairs: [SubtitleSyncParts.Interval] = []
        var total = 0.0
        for line in lines {
            let mapping = plan.mapping(at: line.start)
            let start = mapping(line.start)
            let end = max(mapping(line.end), start + 0.01)
            let length = min(max(mapping(line.end) - start, 0), SubtitleSyncParts.lineCap)
            pairs.append(SubtitleSyncParts.Interval(start: start, end: start + length))
            total += length
            guard timeline.isCheckable(start) else { continue }
            checkable += 1
            let error = nearest(starts, to: start).map { $0 - start }
            let startHit = error.map { abs($0) <= startTolerance } ?? false
            if startHit, let error {
                startMatches += 1
                errors.append(error)
            }
            if startHit || overlap(intervals, start...end) >= 0.5 * (end - start) {
                covered += 1
                run = 0
            } else {
                run += 1
                longest = max(longest, run)
            }
        }
        errors.sort()
        pairs.sort { $0.start < $1.start }
        let match = SubtitleSyncParts.overlap(pairs, timeline.merged) / max(total, 1)
        // Chance: how densely the reference covers the time the lines span.
        var chance = 0.0
        var startChance = 0.0
        if let first = pairs.first?.start, let last = pairs.last?.start, last > first {
            let inside = timeline.merged.reduce(0.0) { $0 + max(0, min(last, $1.end) - max(first, $1.start)) }
            chance = inside / (last - first)
            startChance = startWindowShare(starts, from: first, to: last)
        }
        return SubtitleSyncFit(
            mapping: plan.main,
            coverage: Double(covered) / Double(max(checkable, 1)),
            startMatches: startMatches,
            longestMiss: longest,
            medianError: errors.isEmpty ? 0 : errors[errors.count / 2],
            lineCount: lines.count,
            checkable: checkable,
            match: match,
            chance: chance,
            startChance: startChance)
    }

    /// The share of `from…to` within `startTolerance` of a reference start: the chance that a
    /// line start put anywhere in it hits one.
    static func startWindowShare(_ starts: [Double], from: Double, to: Double) -> Double {
        guard to > from else { return 0 }
        var covered = 0.0
        var reach = -Double.infinity
        for start in starts.sorted() {
            let low = max(start - startTolerance, from), high = min(start + startTolerance, to)
            guard high > low else { continue }
            covered += max(0, high - max(low, reach))
            reach = max(reach, high)
        }
        return min(covered / (to - from), 1)
    }

    /// Matched starts weigh most (they pin the timing down); overlap counts lines a translation
    /// split or merged differently.
    static func score(_ fit: SubtitleSyncFit) -> Double {
        0.7 * Double(fit.startMatches) / Double(max(fit.lineCount, 1)) + 0.3 * fit.coverage
    }

    static func better(_ lhs: SubtitleSyncFit, than rhs: SubtitleSyncFit) -> Bool {
        let left = score(lhs)
        let right = score(rhs)
        if abs(left - right) > 0.0001 { return left > right }
        return abs(lhs.medianError) < abs(rhs.medianError)
    }

    /// The offsets most line starts vote for at `scale`, strongest first.
    static func votedOffsets(lines: [SubtitleTimingCue], referenceStarts starts: [Double], scale: Double) -> [Double] {
        let binCount = Int((2 * maxOffset / binWidth).rounded()) + 1
        var votes = [Int](repeating: 0, count: binCount)
        for line in lines {
            let scaled = line.start * scale
            var index = lowerBound(starts, scaled - maxOffset)
            while index < starts.count, starts[index] <= scaled + maxOffset {
                let bin = Int(((starts[index] - scaled + maxOffset) / binWidth).rounded())
                if bin >= 0, bin < binCount { votes[bin] += 1 }
                index += 1
            }
        }
        var smoothed = [Int](repeating: 0, count: binCount)
        var running = 0
        for index in 0..<(binCount + smoothingBins) {
            if index < binCount { running += votes[index] }
            if index - 2 * smoothingBins - 1 >= 0 { running -= votes[index - 2 * smoothingBins - 1] }
            let center = index - smoothingBins
            if center >= 0, center < binCount { smoothed[center] = running }
        }
        var offsets: [Double] = []
        let suppression = Int((peakSeparation / binWidth).rounded())
        for _ in 0..<peaksPerScale {
            guard let peak = smoothed.enumerated().max(by: { $0.element < $1.element }), peak.element > 0 else { break }
            let bin = peak.offset
            offsets.append(Double(bin) * binWidth - maxOffset)
            for index in max(0, bin - suppression)...min(binCount - 1, bin + suppression) { smoothed[index] = 0 }
        }
        return offsets
    }

    static func evaluate(
        lines: [SubtitleTimingCue],
        referenceStarts starts: [Double],
        intervals: [ClosedRange<Double>],
        mapping: SubtitleSyncMapping
    ) -> SubtitleSyncFit {
        var covered = 0
        var startMatches = 0
        var run = 0
        var longest = 0
        var errors: [Double] = []
        for line in lines {
            let start = mapping(line.start)
            let end = max(mapping(line.end), start + 0.01)
            let error = nearest(starts, to: start).map { $0 - start }
            let startHit = error.map { abs($0) <= startTolerance } ?? false
            if startHit, let error {
                startMatches += 1
                errors.append(error)
            }
            let hit = startHit || overlap(intervals, start...end) >= 0.5 * (end - start)
            if hit {
                covered += 1
                run = 0
            } else {
                run += 1
                longest = max(longest, run)
            }
        }
        errors.sort()
        let median = errors.isEmpty ? 0 : errors[errors.count / 2]
        return SubtitleSyncFit(
            mapping: mapping,
            coverage: Double(covered) / Double(lines.count),
            startMatches: startMatches,
            longestMiss: longest,
            medianError: median,
            lineCount: lines.count)
    }

    static func mergedIntervals(_ cues: [SubtitleTimingCue]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) where cue.end > cue.start {
            if let last = merged.last, cue.start <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, cue.end)
            } else {
                merged.append(cue.start...cue.end)
            }
        }
        return merged
    }

    static func overlap(_ intervals: [ClosedRange<Double>], _ range: ClosedRange<Double>) -> Double {
        var index = max(0, lowerBoundUpper(intervals, range.lowerBound))
        var total = 0.0
        while index < intervals.count, intervals[index].lowerBound < range.upperBound {
            let low = max(intervals[index].lowerBound, range.lowerBound)
            let high = min(intervals[index].upperBound, range.upperBound)
            if high > low { total += high - low }
            index += 1
        }
        return total
    }

    static func nearest(_ sorted: [Double], to value: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = lowerBound(sorted, value)
        if index == 0 { return sorted[0] }
        if index == sorted.count { return sorted[sorted.count - 1] }
        return value - sorted[index - 1] <= sorted[index] - value ? sorted[index - 1] : sorted[index]
    }

    /// First index whose value is not below `value`.
    static func lowerBound(_ sorted: [Double], _ value: Double) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// First interval that ends at or after `value`.
    private static func lowerBoundUpper(_ intervals: [ClosedRange<Double>], _ value: Double) -> Int {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].upperBound < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// The video's own subtitle timeline to line an add-on subtitle up with: which embedded tracks
/// to try, and their lines.
enum SubtitleSyncReference {
    static let minEvents = 8
    static let minSpan: Double = 30
    /// A text frame without a length in the index lasts until the next one, at most this long.
    static let estimatedTextDuration: Double = 4
    static let maxDuration: Double = 20
    /// PGS shows a picture and clears it: a pair this far apart is one line.
    static let pgsLineRange: ClosedRange<Double> = 0.3...15
    /// A text track with this many times the events of the leanest one is signs or karaoke.
    static let crowdedTrackFactor: Double = 3
    static let maxCandidates = 3

    static let unwantedName = try! NSRegularExpression(
        pattern: #"sign|song|forced|commentary|karaoke|lyric|\bop\b|\bed\b"#, options: [.caseInsensitive])
    static let hearingImpairedName = try! NSRegularExpression(
        pattern: #"sdh|\bcc\b|hearing|impaired"#, options: [.caseInsensitive])
    static let fullDialogueName = try! NSRegularExpression(pattern: #"full|dialog"#, options: [.caseInsensitive])
    /// A PGS track needs this many lines after pairing (anime-titulky: 20).
    static let minLines = 20

    /// The lines of an embedded track.
    static func cues(of track: MatroskaSubtitleTrack) -> [SubtitleTimingCue] {
        var events = track.events.sorted { $0.start < $1.start }
        events = events.enumerated().filter { index, event in
            index == 0 || event.start - events[index - 1].start > 0.001
        }.map { $0.element }
        guard !events.isEmpty else { return [] }
        if track.isPGS {
            return pgsLines(events.map { $0.start })
        }
        return events.enumerated().map { index, event in
            let next = index + 1 < events.count ? events[index + 1].start - event.start : estimatedTextDuration
            let length = event.duration.flatMap { $0 > 0 ? $0 : nil } ?? min(next, estimatedTextDuration)
            return SubtitleTimingCue(start: event.start, end: event.start + min(max(length, 0.2), maxDuration))
        }
    }

    /// PGS events show a picture or clear it, but not strictly in turns: a new line can replace
    /// the last one without a clear, and a lone event often sits at 0:00. Pairing them two by two
    /// flips at the first such event and takes the gaps between lines for lines (anime-titulky,
    /// Ladies versus Butlers E1: 507 events, only 186 pairs). Each event gets "show" or "clear"
    /// by a dynamic programme instead (torboxref.js pgsPairs): a shown line lasts 0.7–7 s, the
    /// gap after a clear is short (< 0.6 s) or long, two clears in a row almost never happen,
    /// a replacement now and then. Simulation: 92 % of starts right two by two, 97 % this way.
    static func pgsLines(_ times: [Double]) -> [SubtitleTimingCue] {
        let events = times.sorted()
        let count = events.count
        guard count >= 2 else { return [] }
        let gaps = (0..<(count - 1)).map { events[$0 + 1] - events[$0] }
        func shown(_ length: Double) -> Double {
            if length >= 0.7, length <= 7 { return 1 }
            if length >= 0.3, length <= 10 { return 0.5 }
            if length >= 0.3, length <= 15 { return 0 }
            return -4
        }
        func cleared(_ length: Double) -> Double { length < 0.6 || length > 7 ? 1 : 0.6 }
        // [from][to]: 0 = show, 1 = clear
        let transition: [[Double]] = [[-0.4, 0], [0, -2.5]]
        var score: [[Double]] = [[0, -0.5]]
        var from: [[Int]] = [[0, 0]]
        for index in 1..<count {
            var row = [-Double.infinity, -Double.infinity]
            var origin = [0, 0]
            for state in 0..<2 {
                for previous in 0..<2 {
                    let interval = previous == 0 ? shown(gaps[index - 1]) : cleared(gaps[index - 1])
                    let value = score[index - 1][previous] + interval + transition[previous][state]
                    if value > row[state] {
                        row[state] = value
                        origin[state] = previous
                    }
                }
            }
            score.append(row)
            from.append(origin)
        }
        var states = [Int](repeating: 0, count: count)
        states[count - 1] = 1
        for index in stride(from: count - 1, to: 0, by: -1) {
            states[index - 1] = from[index][states[index]]
        }
        return (0..<(count - 1)).compactMap { index in
            guard states[index] == 0, pgsLineRange.contains(gaps[index]) else { return nil }
            return SubtitleTimingCue(start: events[index], end: events[index + 1])
        }
    }

    struct Candidate: Sendable {
        let track: MatroskaSubtitleTrack
        let cues: [SubtitleTimingCue]
    }

    /// The embedded tracks to try, best first (anime-titulky pickDialogueTrack): English ASS
    /// (translations are made from English, so the lines are split alike), ASS in another
    /// language, English SRT (SRT copies were seen running 1.4 s late), then the rest; without
    /// SDH; closest to the subtitle's line count. PGS only without text, English and "Full" or
    /// "Dialogue" first.
    static func candidates(in index: MatroskaSubtitleIndex, targetLineCount: Int) -> [Candidate] {
        review(in: index, targetLineCount: targetLineCount).candidates
    }

    /// The tracks to try, and why each of the others was left out (for the diagnostics).
    struct Review: Sendable {
        var candidates: [Candidate]
        var skipped: [UInt64: String]
    }

    static func review(in index: MatroskaSubtitleIndex, targetLineCount: Int) -> Review {
        var skipped: [UInt64: String] = [:]
        func usableTrack(_ track: MatroskaSubtitleTrack) -> Candidate? {
            if track.isCommentary { skipped[track.number] = "commentary"; return nil }
            guard track.isText || track.isPGS else {
                skipped[track.number] = "picture subtitles (\(track.codecID))"
                return nil
            }
            if matches(unwantedName, track.name) { skipped[track.number] = "name (signs, songs…)"; return nil }
            let lines = cues(of: track)
            guard lines.count >= (track.isPGS ? minLines : minEvents) else {
                skipped[track.number] = "only \(lines.count) lines in the index"
                return nil
            }
            guard let first = lines.first, let last = lines.last, last.end - first.start >= minSpan else {
                skipped[track.number] = "spans under \(Int(minSpan)) s"
                return nil
            }
            return Candidate(track: track, cues: lines)
        }
        var usable = index.tracks.filter { !$0.isForced }.compactMap(usableTrack)
        let forced = index.tracks.filter(\.isForced)
        if usable.isEmpty {
            // Some releases mark their only full track forced: with nothing else to go by, it is
            // tried like any other (signs and songs still left out by name).
            usable = forced.compactMap(usableTrack)
        } else {
            for track in forced { skipped[track.number] = "forced" }
        }
        var pool = usable.filter { $0.track.isText }
        if pool.count >= 2 {
            // Karaoke and typesetting tracks: far more events than the middle one.
            let counts = pool.map { $0.cues.count }.sorted()
            let median = counts[counts.count / 2]
            let clean = pool.filter { Double($0.cues.count) <= crowdedTrackFactor * Double(median) }
            if !clean.isEmpty {
                for crowded in pool where !clean.contains(where: { $0.track.number == crowded.track.number }) {
                    skipped[crowded.track.number] = "far more lines than the others (signs or karaoke)"
                }
                pool = clean
            }
        }
        let text = !pool.isEmpty
        if !text {
            pool = usable.filter { $0.track.isPGS }
        } else {
            for picture in usable where picture.track.isPGS {
                skipped[picture.track.number] = "PGS, text tracks first"
            }
        }

        var seen = Set<String>()
        pool = pool.filter { candidate in
            let key = "\(candidate.cues.count):\(Int((candidate.cues[0].start * 20).rounded())):\(Int((candidate.cues[candidate.cues.count - 1].start * 20).rounded()))"
            let isNew = seen.insert(key).inserted
            if !isNew { skipped[candidate.track.number] = "same timing as another track" }
            return isNew
        }
        let target = Double(max(targetLineCount, 1))
        func isEnglish(_ track: MatroskaSubtitleTrack) -> Bool {
            (track.language ?? "").lowercased().hasPrefix("en")
        }
        func tier(_ track: MatroskaSubtitleTrack) -> Int {
            if track.isPGS {
                let named = matches(fullDialogueName, track.name)
                return (isEnglish(track) ? 0 : 2) + (named ? 0 : 1)
            }
            switch (isEnglish(track), track.isASS) {
            case (true, true): return 0
            case (false, true): return 1
            case (true, false): return 2
            case (false, false): return 3
            }
        }
        func hearingImpaired(_ track: MatroskaSubtitleTrack) -> Bool {
            track.isHearingImpaired || matches(hearingImpairedName, track.name)
        }
        func closeness(_ candidate: Candidate) -> Double {
            abs(log(Double(candidate.cues.count) / target))
        }
        let ordered = pool.sorted { a, b in
            if tier(a.track) != tier(b.track) { return tier(a.track) < tier(b.track) }
            if hearingImpaired(a.track) != hearingImpaired(b.track) { return !hearingImpaired(a.track) }
            return closeness(a) < closeness(b)
        }
        for left in ordered.dropFirst(maxCandidates) {
            skipped[left.track.number] = "not tried (\(maxCandidates) better ones first)"
        }
        return Review(candidates: Array(ordered.prefix(maxCandidates)), skipped: skipped)
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
