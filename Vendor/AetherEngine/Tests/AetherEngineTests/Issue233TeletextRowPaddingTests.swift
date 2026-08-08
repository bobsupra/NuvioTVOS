import Testing
import Foundation
@testable import AetherEngine

/// #233 round 4, reported by tresby: teletext rows kept their column padding at interior line
/// breaks, so a two-row caption arrived as `row one␣␣\n␣␣␣␣␣␣␣␣row two`. A renderer that centres
/// each line puts row two visibly off centre and draws the background box wider than the text.
///
/// The padding is the grid. On a page libzvbi does not flag as a subtitle page, `gen_sub_ass`
/// (`libavcodec/libzvbi-teletextdec.c:378`) writes every row at full column width
/// (`decode_string(page, row, &buf, 0, page->columns, ...)`, one `\h` per grid space) and appends
/// `" \N"` after it. `edgeTrimmed` reaches the outer edges of the whole run sequence only, and
/// `collapseInteriorBlankLines` looks at the characters BETWEEN two newlines, never the ones
/// touching a single retained one, so both walked past it.
///
/// The pass is gated on the same signal as the vertical fallback: no `\an` means the raw grid
/// dump. A flagged page is curated by `gen_sub_ass` itself (`:357-376`), where the surviving pad is
/// the relative indentation that carries the alignment it chose, and the blank lines are its
/// `empty_lines / 2` vertical fine-positioning. Trimming those would delete information.
struct Issue233TeletextRowPaddingTests {

    /// One emitted row of an unflagged page: full column width in `\h`, then the `" \N"` separator.
    private func gridRow(_ text: String, leading: Int, columns: Int = 40) -> String {
        let trailing = max(0, columns - leading - text.count)
        return String(repeating: #"\h"#, count: leading)
            + text
            + String(repeating: #"\h"#, count: trailing)
            + #" \N"#
    }

    private func unflaggedPage(_ rows: String...) -> String {
        "0,0,Teletext,,0,0,0,," + rows.joined()
    }

    private func text(_ line: String) -> String? {
        SubtitleRectText.teletextBody(fromASSEventLine: line)?.body.flattenedText
    }

    // MARK: - The report

    @Test("a two-row grid dump loses the padding on both sides of the line break")
    func interiorPaddingTrimmed() {
        let page = unflaggedPage(
            gridRow("Waxy, buttery potatoes with chicken", leading: 3),
            gridRow("and peas.", leading: 8)
        )
        #expect(text(page) == "Waxy, buttery potatoes with chicken\nand peas.")
    }

    @Test("the separator space gen_sub_ass writes before every newline goes too")
    func separatorSpaceTrimmed() {
        // Even a row that fills its columns exactly still carries the " " from `" \N"`.
        let page = unflaggedPage(
            gridRow("one", leading: 0, columns: 3),
            gridRow("two", leading: 0, columns: 3)
        )
        #expect(text(page) == "one\ntwo")
    }

    @Test("padding split off into its own run by a colour change is still padding")
    func paddingInItsOwnRun() {
        // decode_string emits the colour change at the column it happens on, so a row's pad
        // routinely lands in a whitespace-only run: a per-run trim steps over it, and a trim that
        // only looked at the run touching the newline would keep the rest.
        let line = #"0,0,Teletext,,0,0,0,,{\c&H0000FF&}one\h\h{\c&H00FF00&}\h\h \N{\c&H0000FF&}\h\htwo"#
        #expect(text(line) == "one\ntwo")
    }

    @Test("the trailing pad of the last row and the leading pad of the first are still gone")
    func outerEdgesUnaffected() {
        let page = unflaggedPage(gridRow("only row", leading: 12))
        #expect(text(page) == "only row")
    }

    // MARK: - What the trim must not eat

    @Test("indentation inside a row survives")
    func interiorIndentationSurvives() {
        // Only the run of whitespace touching a row edge is grid pad. What sits between two
        // characters is spacing the broadcaster laid out.
        let page = unflaggedPage(gridRow("A     B", leading: 4))
        #expect(text(page) == "A     B")
    }

    @Test("a single line break still survives, an interior blank row still folds")
    func foldStillApplies() {
        let adjacent = unflaggedPage(gridRow("line one", leading: 2), gridRow("line two", leading: 2))
        #expect(text(adjacent) == "line one\nline two")

        let gapped = unflaggedPage(
            gridRow("line one", leading: 2),
            gridRow("", leading: 0),
            gridRow("line two", leading: 2)
        )
        #expect(text(gapped) == "line one\nline two")
    }

    @Test("colours survive the trim on the runs that keep text")
    func coloursSurvive() {
        let line = #"0,0,Teletext,,0,0,0,,{\c&H0000FF&}\h\hred\h\h \N{\c&H00FF00&}\h\hgreen\h\h"#
        guard case .richText(let runs)? =
                SubtitleRectText.teletextBody(fromASSEventLine: line)?.body else {
            Issue.record("expected richText")
            return
        }
        #expect(runs.map(\.text).joined() == "red\ngreen")
        #expect(runs.compactMap(\.color).count == 2)
    }

    // MARK: - The gate

    @Test("a curated page keeps the relative indentation that carries its alignment")
    func curatedPageUntouched() {
        // Left-aligned subtitle page: gen_sub_ass emits from min_leading, so what is left of the
        // pad is the offset of that row against the block, not grid noise.
        let line = #"0,0,Subtitle,,0,0,0,,{\an1}line one \N\h\h\h\h\hline two \N"#
        #expect(text(line) == "line one \n     line two")
    }

    @Test("a curated page keeps its empty_lines fillers")
    func curatedFillersUntouched() {
        // `if (len && empty_lines > 1) for (empty_lines /= 2; ...) av_bprintf(&buf, " \\N");`
        // is deliberate vertical spacing inside the block, not a row the page happened to skip.
        let line = #"0,0,Subtitle,,0,0,0,,{\an5}line one \N \N \Nline two \N"#
        #expect(text(line) == "line one \n \n \nline two")
    }

    @Test("an explicit an2 counts as curated, though it looks like the derived answer")
    func explicitBottomIsCurated() {
        // The same trap the vertical fallback has: {\an2} is a real answer that reads like none.
        let line = #"0,0,Subtitle,,0,0,0,,{\an2}line one \N\h\hline two \N"#
        #expect(text(line) == "line one \n  line two")
    }

    @Test("the trim is teletext only")
    func teletextOnly() {
        // Interior indentation in an ASS or SRT cue can be deliberate, and nothing there is a grid.
        let line = #"0,0,Default,,0,0,0,,line one  \N   line two"#
        #expect(SubtitleRectText.styledBody(fromASSEventLine: line)?.body.flattenedText
                == "line one  \n   line two")
    }

    // MARK: - Degenerate input

    @Test("a page of nothing but padding still produces no cue")
    func allPadding() {
        let page = unflaggedPage(gridRow("", leading: 0), gridRow("", leading: 0))
        #expect(SubtitleRectText.teletextBody(fromASSEventLine: page) == nil)
    }

    @Test("the placement derivation still sees the untrimmed row ordinal")
    func placementUnaffected() {
        // firstTextRow is measured before any of this runs, so the trim cannot move the caption.
        let page = unflaggedPage(
            gridRow("", leading: 0),
            gridRow("", leading: 0),
            gridRow("caption", leading: 6)
        )
        let parsed = SubtitleRectText.teletextBody(fromASSEventLine: page)
        #expect(parsed?.placement?.alignment == 8)
        #expect(parsed?.body.flattenedText == "caption")
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
