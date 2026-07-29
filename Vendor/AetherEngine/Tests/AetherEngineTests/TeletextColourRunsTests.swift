import Testing
@testable import AetherEngine

/// #107 teletext colour, kept green through the #233 generalization: the colour parser became a
/// full ASS override parser (`coloredRuns` -> `styledRuns`) and the interior blank-line fold moved
/// out of the run parser into `teletextBody`, where it belongs, since only libzvbi's row joining
/// produces those blank lines.
struct TeletextColourRunsTests {
    private func runs(_ line: String) -> [SubtitleTextRun]? {
        SubtitleRectText.styledRuns(fromASSEventLine: line)?.runs
    }

    // ASS colour is &Hbbggrr& (BGR). &H00FFFF& = R=255 G=255 B=0 (yellow).
    @Test("parses BGR hex into RGB runs")
    func bgrToRgb() {
        let line = "0,0,Default,,0,0,0,,{\\c&H00FFFF&}Yellow"
        #expect(runs(line) == [SubtitleTextRun(text: "Yellow", color: SubtitleColor(r: 255, g: 255, b: 0))])
    }

    @Test("splits into multiple runs at colour changes, collapses equal-colour neighbours")
    func multiRun() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}Red {\\c&HFFFFFF&}White"
        #expect(runs(line) == [
            SubtitleTextRun(text: "Red ", color: SubtitleColor(r: 255, g: 0, b: 0)),
            SubtitleTextRun(text: "White", color: SubtitleColor(r: 255, g: 255, b: 255)),
        ])
    }

    @Test("bare \\c resets to default (nil colour)")
    func resetColour() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}Red{\\c}plain"
        #expect(runs(line) == [
            SubtitleTextRun(text: "Red", color: SubtitleColor(r: 255, g: 0, b: 0)),
            SubtitleTextRun(text: "plain", color: nil),
        ])
    }

    @Test("applies \\N newline and \\h hard space escapes")
    func escapes() {
        let line = "0,0,Default,,0,0,0,,line1\\Nline2\\hend"
        #expect(runs(line) == [SubtitleTextRun(text: "line1\nline2 end", color: nil)])
    }

    @Test("uncoloured line yields a single nil-colour run")
    func noColour() {
        #expect(runs("0,0,Default,,0,0,0,,just text") == [SubtitleTextRun(text: "just text", color: nil)])
    }

    @Test("teletextBody returns richText when coloured, text when not, nil when empty")
    func bodySelection() {
        if case .richText? = SubtitleRectText.teletextBody(fromASSEventLine: "0,0,D,,0,0,0,,{\\c&H0000FF&}Red")?.body {} else { Issue.record("expected richText") }
        if case .text(let s)? = SubtitleRectText.teletextBody(fromASSEventLine: "0,0,D,,0,0,0,,plain")?.body { #expect(s == "plain") } else { Issue.record("expected text") }
        #expect(SubtitleRectText.teletextBody(fromASSEventLine: "0,0,D,,0,0,0,,{\\c&H0&}") == nil)
    }

    @Test("non-event line with too few fields is cleaned as-is")
    func nonEventLine() {
        #expect(runs("plain, with, commas") == [SubtitleTextRun(text: "plain, with, commas", color: nil)])
    }

    @Test("adjacent same-colour runs collapse into one")
    func collapseSameColour() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}A{\\c&H0000FF&}B"
        #expect(runs(line) == [SubtitleTextRun(text: "AB", color: SubtitleColor(r: 255, g: 0, b: 0))])
    }

    @Test("non-colour override tags like \\clip are ignored, not treated as a reset")
    func clipTagIgnored() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}Red{\\clip(1,2,3,4)}still"
        #expect(runs(line) == [SubtitleTextRun(text: "Redstill", color: SubtitleColor(r: 255, g: 0, b: 0))])
    }

    @Test("leading/trailing newlines are edge-trimmed across coloured runs (no blank line)")
    func edgeTrimsColouredRuns() {
        // libzvbi teletext ass can prefix a row-positioning newline; a coloured cue must not
        // render a blank line the plain path already trims. Interior line breaks are kept.
        let line = "0,0,Default,,0,0,0,,\\N{\\c&H0000FF&}Red\\NWhite\\N"
        #expect(runs(line) == [SubtitleTextRun(text: "Red\nWhite", color: SubtitleColor(r: 255, g: 0, b: 0))])
    }

    @Test("interior blank line from a skipped teletext row collapses to a single break (#107)")
    func collapsesInteriorBlankLine() {
        // libzvbi joins teletext rows with \N; a two-line caption on non-adjacent rows (an empty
        // row between them, used only for vertical placement) arrives as line1\N\Nline2 and would
        // render a blank line the broadcaster never intended. It must read as two adjacent lines.
        let line = "0,0,Default,,0,0,0,,Can you tell someone\\N\\Nthey're not a good singer?"
        if case .text(let s)? = SubtitleRectText.teletextBody(fromASSEventLine: line)?.body {
            #expect(s == "Can you tell someone\nthey're not a good singer?")
        } else {
            Issue.record("expected text body")
        }
    }

    @Test("multiple skipped rows collapse to a single break, colours preserved (#107)")
    func collapsesMultipleBlankRowsColoured() {
        let line = "0,0,Default,,0,0,0,,{\\c&H00FFFF&}Line A\\N\\N\\NLine B"
        if case .richText(let r)? = SubtitleRectText.teletextBody(fromASSEventLine: line)?.body {
            #expect(r == [SubtitleTextRun(text: "Line A\nLine B", color: SubtitleColor(r: 255, g: 255, b: 0))])
        } else {
            Issue.record("expected richText body")
        }
    }

    @Test("adjacent teletext rows keep their single line break (no over-collapse)")
    func keepsAdjacentRowBreak() {
        let line = "0,0,Default,,0,0,0,,First line\\NSecond line"
        #expect(runs(line) == [SubtitleTextRun(text: "First line\nSecond line", color: nil)])
    }
}
