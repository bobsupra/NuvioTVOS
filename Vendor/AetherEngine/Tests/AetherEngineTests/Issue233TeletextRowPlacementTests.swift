import Testing
import Foundation
@testable import AetherEngine

/// #233 follow-up, reported by tresby: teletext captions lost their vertical placement.
///
/// Only on pages libzvbi does not classify as subtitle pages. `gen_sub_ass`
/// (`libavcodec/libzvbi-teletextdec.c`) derives the vertical anchor from the grid row itself and
/// emits it as `{\anN}`:
///
///     vertical_align = (2 - (av_clip(i + 1, 0, 23) / 8));
///     av_bprintf(&buf, "{\\an%d}", alignment + vertical_align * 3);
///
/// but that whole block sits behind `is_subtitle_page`, which comes from the row-0 header flags
/// (NEWSFLASH clear AND SUBTITLE set AND SUPPRESS_HEADER set). When a broadcaster does not set all
/// three, or the header has not been seen yet, the else path runs instead: no `\an`, no per-row
/// trim, and every row including the empty ones goes out as `" \N"`. The row ordinal is then the
/// only carrier of the position, and `edgeTrimmed` was throwing it away.
///
/// So the fallback reproduces ffmpeg's own formula on the emitted rows rather than inventing a
/// scale, and it must never fire when `\an` is present: `{\an2}` is explicitly bottom and produces
/// exactly the same empty derived output that "no information" would.
struct Issue233TeletextRowPlacementTests {

    /// Event line whose body starts on emitted row `row` (0-based), the shape a non-subtitle page
    /// produces: one `" \N"` per grid row, blanks included.
    private func page(firstTextRow row: Int, prefix: String = "") -> String {
        let blanks = String(repeating: " \\N", count: row)
        return "0,0,Teletext,,0,0,0,,\(prefix)\(blanks)CAPTION TEXT"
    }

    private func alignment(_ line: String) -> Int? {
        SubtitleRectText.teletextBody(fromASSEventLine: line)?.placement?.alignment
    }

    // MARK: - Derivation

    @Test("the first text row picks the same third ffmpeg would have picked")
    func rowThirds() {
        // Emitted row r sits on grid row r + 1 (txt_chop_top defaults to 1), and ffmpeg tests
        // i + 1, so the boundaries are r <= 5 top, r <= 13 middle, r >= 14 bottom.
        #expect(alignment(page(firstTextRow: 0)) == 8)
        #expect(alignment(page(firstTextRow: 5)) == 8)
        #expect(alignment(page(firstTextRow: 6)) == 5)
        #expect(alignment(page(firstTextRow: 13)) == 5)
        #expect(alignment(page(firstTextRow: 14)) == 2)
        #expect(alignment(page(firstTextRow: 21)) == 2)
    }

    @Test("rows padded with hard spaces are still blank rows")
    func hardSpacePadding() {
        // libzvbi writes every space as \h, so a "blank" row is not an empty string.
        let padded = "0,0,Teletext,,0,0,0,,"
            + String(repeating: "\\h\\h\\h \\N", count: 15) + "CAPTION"
        #expect(alignment(padded) == 2)
    }

    @Test("the derived placement carries no anchor point")
    func noPosition() {
        // A third of the frame is all the row ordinal says. Inventing a \pos-style anchor from it
        // would pin the block and take the host's margin away.
        let p = SubtitleRectText.teletextBody(fromASSEventLine: page(firstTextRow: 16))?.placement
        #expect(p?.position == nil)
    }

    // MARK: - What must not change

    @Test("an explicit an wins, including when it means bottom")
    func explicitAlignmentWins() {
        // The trap: {\an2} is bottom, and bottom is also what "derived nothing" looks like.
        #expect(alignment(page(firstTextRow: 2, prefix: #"{\an2}"#)) == 2)
        #expect(alignment(page(firstTextRow: 18, prefix: #"{\an8}"#)) == 8)
        #expect(alignment(page(firstTextRow: 0, prefix: #"{\an1}"#)) == 1)
    }

    @Test("the derivation is teletext only")
    func teletextOnly() {
        // A leading newline in an ASS or SRT cue is an intentional blank line, not a grid row.
        let line = page(firstTextRow: 16)
        #expect(SubtitleRectText.styledBody(fromASSEventLine: line)?.placement == nil)
    }

    @Test("the body is unchanged by the derivation")
    func bodyUnchanged() {
        let parsed = SubtitleRectText.teletextBody(fromASSEventLine: page(firstTextRow: 16))
        #expect(parsed?.body.flattenedText == "CAPTION TEXT")
    }

    // MARK: - Blank-line folding across runs (#107 hardening)

    @Test("a blank row split into its own run by a colour change still folds")
    func blankRowSplitByColourChange() {
        // The padding of an otherwise empty row carries the spacing attribute that changes colour,
        // so the blank row can land in a run of its own. Folding per run, and across one run
        // boundary, both miss that: the chain is line -> whitespace-only run -> line.
        let line = #"0,0,Teletext,,0,0,0,,a\N{\c&H0000FF&}\h\h\N{\c&H00FF00&}b"#
        let body = SubtitleRectText.teletextBody(fromASSEventLine: line)?.body
        #expect(body?.flattenedText == "a\nb")
    }

    @Test("interior blank rows still fold, single line breaks still survive")
    func foldRegression() {
        let folded = #"0,0,Teletext,,0,0,0,,line one\N \Nline two"#
        #expect(SubtitleRectText.teletextBody(fromASSEventLine: folded)?.body.flattenedText
                == "line one\nline two")
        let kept = #"0,0,Teletext,,0,0,0,,line one\Nline two"#
        #expect(SubtitleRectText.teletextBody(fromASSEventLine: kept)?.body.flattenedText
                == "line one\nline two")
    }

    // MARK: - Whitespace predicates

    @Test("the styled path trims the same characters the plain path does")
    func unicodeWhitespaceEdgeTrim() {
        // The plain path trims with .whitespacesAndNewlines (Unicode Zs); the styled path tested
        // for literal space / tab / newline, so a NO-BREAK SPACE survived on a styled cue and not
        // on an unstyled one. Teletext cannot produce one (IS_TXT_SPACE maps U+00A0 to a space,
        // which decode_string writes as \h), but SRT, WebVTT and ASS payloads can.
        let nbsp = "\u{00A0}"
        let line = "0,0,Default,,0,0,0,,{\\c&HFFFFFF&}\(nbsp)\(nbsp)styled\(nbsp)"
        let runs = SubtitleRectText.styledRuns(fromASSEventLine: line)?.runs ?? []
        #expect(runs.map(\.text).joined() == "styled")

        let plain = SubtitleRectText.plainText(fromASSEventLine:
            "0,0,Default,,0,0,0,,\(nbsp)\(nbsp)plain\(nbsp)")
        #expect(plain == "plain")
    }
}

private extension SubtitleCue.Body {
    var flattenedText: String {
        switch self {
        case .text(let t): return t
        case .richText(let runs): return runs.map(\.text).joined()
        case .image: return ""
        }
    }
}
