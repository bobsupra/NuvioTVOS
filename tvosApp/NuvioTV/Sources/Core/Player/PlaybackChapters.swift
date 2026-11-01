import Foundation

/// One chapter of the playing file (Matroska / MP4 container chapters), on
/// the same 0-based axis as the playback position and `seek(to:)`.
struct PlaybackChapter: Equatable, Identifiable, Hashable {
    let id: Int
    let name: String
    let startSeconds: Double
    let endSeconds: Double

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

/// Chapter lookups for the player: names to show, where the playhead is, the
/// marks on the timeline, and Skip Intro / Skip Ending from chapter names.
enum PlaybackChapters {
    /// Chapters from an engine's (start, duration) list: sorted, each ending
    /// where the next one starts when the container gives no length, the last
    /// at the end of the video. A single chapter is no chapter list: the file
    /// gets no Chapters button and no marks.
    static func chapters(
        from items: [(id: Int, name: String, start: Double, duration: Double)],
        totalDuration: Double
    ) -> [PlaybackChapter] {
        let sorted = items
            .filter { $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
        guard sorted.count >= 2 else { return [] }
        return sorted.enumerated().map { index, item in
            let next = index + 1 < sorted.count ? sorted[index + 1].start : nil
            var end = item.duration.isFinite && item.duration > 0 ? item.start + item.duration : (next ?? totalDuration)
            if let next { end = min(end, next) }
            if totalDuration > 0 { end = min(end, totalDuration) }
            return PlaybackChapter(id: item.id, name: item.name, startSeconds: item.start, endSeconds: max(item.start, end))
        }
    }

    /// Whether two chapter lists are the same chapters. The end of the last chapter follows the
    /// video's length, which can still move by a fraction of a second: that is no new list, and
    /// treating it as one dropped the Chapters panel's stills and stopped their loading.
    static func isSameList(_ lhs: [PlaybackChapter], _ rhs: [PlaybackChapter]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.id == b.id && a.name == b.name
                && abs(a.startSeconds - b.startSeconds) < 0.5
                && abs(a.endSeconds - b.endSeconds) < 1.5
        }
    }

    /// The chapter's own name, or "Chapter N" when it has none or only a
    /// generic one ("Chapter 03", "00:12:30.000").
    static func displayName(_ chapter: PlaybackChapter, index: Int) -> String {
        let name = chapter.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || isGeneric(name) {
            return L10n.format("player_chapter_number", fallback: "Chapter %d", index + 1)
        }
        return name
    }

    private static func isGeneric(_ name: String) -> Bool {
        name.range(of: #"^(chapter|kapitola|chapitre|kapitel|cap[ií]tulo|capitolo)\s*\d+$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
            || name.range(of: #"^\d{1,2}:\d{2}(:\d{2})?([.,]\d+)?$"#, options: .regularExpression) != nil
    }

    /// The chapter that holds `seconds`, if any.
    static func index(at seconds: Double, in chapters: [PlaybackChapter]) -> Int? {
        guard seconds.isFinite else { return nil }
        return chapters.lastIndex { seconds >= $0.startSeconds - 0.25 }
            .flatMap { seconds < chapters[$0].endSeconds || $0 == chapters.count - 1 ? $0 : nil }
    }

    /// Where chapters start on the timeline, as fractions of the duration
    /// (the first chapter at the very start is not marked).
    static func markers(_ chapters: [PlaybackChapter], duration: Double) -> [Double] {
        guard duration > 0, chapters.count > 1 else { return [] }
        return chapters
            .map { $0.startSeconds / duration }
            .filter { $0 > 0.002 && $0 < 0.998 }
    }

    // MARK: - Timeline pieces

    /// A stretch of the timeline between two cuts, as fractions of the duration.
    struct TimelinePiece: Equatable {
        let start: Double
        let end: Double
    }

    /// Cuts closer than this to each other or to either end make no piece of their own.
    static let minPieceFraction: Double = 0.002

    /// The pieces the timeline is drawn in, with a gap between them: cut where chapters
    /// start (`markers`) or, in a file without chapters, at the opening's and the ending's
    /// edges. Empty when there is nothing to cut at: the track is then one bar.
    static func timelinePieces(markers: [Double], segments: [(start: Double, end: Double)]) -> [TimelinePiece] {
        let cuts = markers.isEmpty ? segments.flatMap { [$0.start, $0.end] } : markers
        var edges: [Double] = [0]
        for cut in cuts.filter(\.isFinite).sorted()
        where cut >= minPieceFraction && cut <= 1 - minPieceFraction && cut - edges[edges.count - 1] >= minPieceFraction {
            edges.append(cut)
        }
        guard edges.count > 1 else { return [] }
        edges.append(1)
        return zip(edges, edges.dropFirst()).map { TimelinePiece(start: $0, end: $1) }
    }

    /// The piece that holds `fraction`: the playhead, or where a seek is headed.
    static func pieceIndex(at fraction: Double, in pieces: [TimelinePiece]) -> Int? {
        guard !pieces.isEmpty, fraction.isFinite else { return nil }
        return pieces.lastIndex { fraction >= $0.start } ?? 0
    }

    // MARK: - Skip from chapter names

    enum Kind: Equatable {
        case opening
        case ending
    }

    /// An opening or an ending on the timeline, as fractions of the duration.
    struct TimelineSegment: Equatable {
        let start: Double
        let end: Double
        let kind: Kind
    }

    /// Longest chapter still taken for an opening or an ending: anything longer
    /// is more likely a part of the episode that happens to carry the name.
    static let maxOpeningSeconds: Double = 180
    static let maxEndingSeconds: Double = 240
    static let minSegmentSeconds: Double = 15

    /// What a chapter name says: "Opening", "OP", "OP2", "Intro", "Opening
    /// Credits" → opening; "Ending", "ED", "Credits", "End Credits", "Outro" →
    /// ending. Anything else (Part A, Prologue, Preview, Chapter 3) → nil.
    static func kind(ofName name: String) -> Kind? {
        let normalized = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        if normalized.range(of: #"^(op ?\d*|opening( (credits|song|theme|titles))?|intro(duction)?)( \d+)?$"#,
                            options: .regularExpression) != nil {
            return .opening
        }
        if normalized.range(of: #"^(ed ?\d*|ending( (credits|song|theme))?|end credits|closing credits|credits|outro)( \d+)?$"#,
                            options: .regularExpression) != nil {
            return .ending
        }
        return nil
    }

    /// Skip Intro / Skip Ending intervals from chapter names: the first short
    /// opening and the first short ending chapter.
    static func skipIntervals(from chapters: [PlaybackChapter]) -> [SkipInterval] {
        var opening: SkipInterval?
        var ending: SkipInterval?
        for chapter in chapters {
            guard let kind = kind(ofName: chapter.name), chapter.durationSeconds >= minSegmentSeconds else { continue }
            switch kind {
            case .opening where opening == nil && chapter.durationSeconds <= maxOpeningSeconds:
                opening = SkipInterval(startTime: chapter.startSeconds, endTime: chapter.endSeconds,
                                       type: "intro", provider: "chapters")
            case .ending where ending == nil && chapter.durationSeconds <= maxEndingSeconds:
                ending = SkipInterval(startTime: chapter.startSeconds, endTime: chapter.endSeconds,
                                      type: "outro", provider: "chapters")
            default:
                break
            }
        }
        return [opening, ending].compactMap { $0 }
    }

    /// Where the opening and the ending sit on the timeline, as fractions of
    /// the duration, from the skip segments in use (IntroDB and chapters).
    static func timelineSegments(_ intervals: [SkipInterval], duration: Double) -> [TimelineSegment] {
        guard duration > 0 else { return [] }
        return intervals.compactMap { interval in
            let kind: Kind
            if interval.isIntro {
                kind = .opening
            } else if interval.isEnding {
                kind = .ending
            } else {
                return nil
            }
            let start = min(max(interval.startTime / duration, 0), 1)
            let end = min(max(interval.endTime / duration, 0), 1)
            guard end - start > 0.001 else { return nil }
            return TimelineSegment(start: start, end: end, kind: kind)
        }
    }

    // MARK: - Snapping while seeking

    /// Where a swipe seek stops for a moment: chapter starts and the opening's and the ending's
    /// edges, in seconds, inside the video (not its very start or its last second).
    static func snapEdges(chapters: [PlaybackChapter], segments: [SkipInterval], duration: Double) -> [Double] {
        guard duration > 2 else { return [] }
        let starts = chapters.map(\.startSeconds)
        let edges = segments.filter { $0.isIntro || $0.isEnding }.flatMap { [$0.startTime, $0.endTime] }
        return Array(Set((starts + edges).filter { $0.isFinite && $0 >= 1 && $0 <= duration - 1 })).sorted()
    }

    /// How close a swipe must come to an edge to stop on it: 1 % of the video, 3 to 10 s.
    static func snapRadius(duration: Double) -> Double {
        min(max(duration * 0.01, 3), 10)
    }

    /// How far past an edge a swipe must carry on before the target leaves it: three times the
    /// radius (9 to 30 s of swipe), so a slow swipe stays on the edge for a good while.
    static func snapPush(duration: Double) -> Double {
        3 * snapRadius(duration: duration)
    }

    /// Whether the opening and the ending are colored on the timeline (Settings → Player).
    static func showsSegmentsOnTimeline(in settings: UserDefaults) -> Bool {
        settings.object(forKey: SettingsKey.timelineSegmentsEnabled) as? Bool ?? true
    }

    /// Whether a swipe seek stops on edges (Settings → Player).
    static func snapsWhileSeeking(in settings: UserDefaults) -> Bool {
        settings.object(forKey: SettingsKey.timelineSnapEnabled) as? Bool ?? true
    }

    /// A swipe seek that stops on edges. It takes the swipe's steps (seconds, after the swipe's
    /// acceleration) and gives the seek target: once within `radius` of an edge the target stays
    /// on it until the swipe has carried on `push` past it, then moves on from the edge.
    struct SnappingSeek {
        let edges: [Double]
        let radius: Double
        let push: Double
        /// Where the swipe has got to while it is not on an edge.
        private(set) var position: Double
        /// The edge the target is on.
        private(set) var edge: Double?
        /// The swipe since it reached `edge`, counted from the edge.
        private var pushed: Double = 0
        /// The edge just left (or started on): it doesn't hold the swipe until it is out of reach.
        private var released: Double?

        init(from start: Double, edges: [Double], radius: Double, push: Double) {
            self.edges = edges
            self.radius = radius
            self.push = push
            self.position = start
            reset(to: start)
        }

        /// Starts over at `start` (fine-tuning or a jump moved the target there).
        mutating func reset(to start: Double) {
            position = start
            edge = nil
            pushed = 0
            released = Self.closest(to: start, in: edges, within: radius)
        }

        /// Moves the swipe by `delta` within 0...`limit`; returns the target.
        mutating func move(by delta: Double, upTo limit: Double) -> Double {
            if let held = edge {
                pushed += delta
                guard abs(pushed) > push else { return held }
                position = min(max(held + (pushed > 0 ? pushed - push : pushed + push), 0), limit)
                released = held
                edge = nil
                pushed = 0
                return position
            }
            position = min(max(position + delta, 0), limit)
            if let left = released, abs(position - left) > radius { released = nil }
            guard let next = Self.closest(to: position, in: edges.filter { $0 != released }, within: radius) else {
                return position
            }
            edge = next
            pushed = position - next
            return next
        }

        static func closest(to seconds: Double, in edges: [Double], within radius: Double) -> Double? {
            edges.filter { abs($0 - seconds) <= radius }.min { abs($0 - seconds) < abs($1 - seconds) }
        }
    }

    // MARK: - Colors

    /// The colors the opening and the ending can take (Settings → Player): the subtitle
    /// palette without white, which reads as the played part, black, and red, the mark of
    /// where playback is (pink in its place).
    static let colorChoices = ["#F2C94C", "#56CCF2", "#F78FB3", "#6FCF97", "#9B51E0", "#F2994A", "#27AE60", "#2F80ED"]
    static let defaultOpeningColor = "#F2C94C"
    static let defaultEndingColor = "#56CCF2"

    static func colorKey(for kind: Kind) -> String {
        kind == .opening ? SettingsKey.timelineOpeningColor : SettingsKey.timelineEndingColor
    }

    /// The color chosen for `kind`, as "#RRGGBB"; its default while none is set, or when the
    /// setting holds a color that is no longer offered.
    static func colorHex(for kind: Kind, in settings: UserDefaults) -> String {
        let fallback = kind == .opening ? defaultOpeningColor : defaultEndingColor
        guard let value = settings.string(forKey: colorKey(for: kind))?.trimmingCharacters(in: .whitespaces),
              let choice = colorChoices.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
        else { return fallback }
        return choice
    }

    /// Whether black text reads better than white on `hex` (the Opening / Ending badges).
    static func prefersDarkText(on hex: String) -> Bool {
        var value: UInt64 = 0
        guard Scanner(string: String(hex.drop { $0 == "#" }.prefix(6))).scanHexInt64(&value) else { return true }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return 0.299 * red + 0.587 * green + 0.114 * blue >= 0.6
    }

    /// A chapter's badge in the list: from its name, or from the segment it
    /// lines up with (IntroDB's opening over an unnamed chapter).
    static func kind(of chapter: PlaybackChapter, segments: [SkipInterval]) -> Kind? {
        if let named = kind(ofName: chapter.name) { return named }
        let match = segments.first {
            abs($0.startTime - chapter.startSeconds) <= 3 && abs($0.endTime - chapter.endSeconds) <= 3
        }
        guard let match else { return nil }
        return match.isIntro ? .opening : (match.isEnding ? .ending : nil)
    }

    /// The opening and the ending in use, on the file's own cut: IntroDB's times come from
    /// another release (or the season's template), so they can sit seconds off this file.
    /// - An opening or ending chapter by name (`chapters`, from `skipIntervals(from:)`) takes
    ///   the place of IntroDB's segment of that kind.
    /// - IntroDB's other segments take the start and end of the chapter they line up with
    ///   (`chapterList`, see `aligned(_:to:)`).
    static func merged(
        introDB: [SkipInterval],
        chapters: [SkipInterval],
        chapterList: [PlaybackChapter] = []
    ) -> [SkipInterval] {
        let namedIntro = chapters.contains(where: \.isIntro)
        let namedEnding = chapters.contains(where: \.isEnding)
        let fromIntroDB = introDB
            .filter { !($0.isIntro && namedIntro) && !($0.isEnding && namedEnding) }
            .map { aligned($0, to: chapterList) }
        return (fromIntroDB + chapters).sorted { $0.startTime < $1.startTime }
    }

    /// Share of both IntroDB's segment and the chapter that must overlap for the segment to
    /// take the chapter's start and end.
    static let alignmentOverlap: Double = 0.7

    /// IntroDB's opening or ending on the chapter it lines up with: one of an opening's or an
    /// ending's length that covers most of the segment, and the segment most of it. Anything
    /// else (no such chapter, a long part that holds the opening) keeps IntroDB's times.
    static func aligned(_ interval: SkipInterval, to chapters: [PlaybackChapter]) -> SkipInterval {
        guard interval.isIntro || interval.isEnding else { return interval }
        let length = interval.endTime - interval.startTime
        guard length > 0 else { return interval }
        let longest = interval.isIntro ? maxOpeningSeconds : maxEndingSeconds
        var best: (chapter: PlaybackChapter, overlap: Double)?
        for chapter in chapters where chapter.durationSeconds >= minSegmentSeconds && chapter.durationSeconds <= longest {
            let overlap = min(chapter.endSeconds, interval.endTime) - max(chapter.startSeconds, interval.startTime)
            guard overlap >= alignmentOverlap * length,
                  overlap >= alignmentOverlap * chapter.durationSeconds,
                  overlap > (best?.overlap ?? 0) else { continue }
            best = (chapter, overlap)
        }
        guard let chapter = best?.chapter else { return interval }
        return SkipInterval(startTime: chapter.startSeconds, endTime: chapter.endSeconds,
                            type: interval.type, provider: interval.provider)
    }
}
