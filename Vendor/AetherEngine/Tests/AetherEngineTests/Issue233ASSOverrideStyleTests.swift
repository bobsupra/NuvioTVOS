import Testing
import Foundation
@testable import AetherEngine

/// #233: text subtitle styling was discarded at the parser, not at the source.
///
/// libavcodec converts every text subtitle format into an ASS event line before the engine sees
/// it, so the markup is already present on `AVSubtitleRect.ass`: SRT through
/// `ff_htmlmarkup_to_ass` (`<b>` to `{\b1}`, `<font color=>` to `{\c&HBBGGRR&}`, `<font face=>` to
/// `{\fn}`, `<font size=>` to `{\fs}`), WebVTT through its own tag table (`<i>/<b>/<u>`), and
/// dvb_teletext because the decoder already runs with `txt_format=ass`. What threw it away was
/// ours: `cleanASSBody` stripped every `{...}` block, and `coloredRuns` handled `\c`/`\1c` and
/// documented that "All other override tags are ignored".
///
/// So there is one parser here, not one per format, and SRT, WebVTT, teletext and ASS all reach
/// the host styled through it.
struct Issue233ASSOverrideStyleTests {

    private func runs(_ line: String) -> [SubtitleTextRun] {
        SubtitleRectText.styledRuns(fromASSEventLine: line)?.runs ?? []
    }

    private func placement(_ line: String) -> SubtitleTextPlacement? {
        SubtitleRectText.styledRuns(fromASSEventLine: line)?.placement
    }

    // MARK: - Inline attributes

    @Test("bold, italic, underline and strikeout are carried on the run")
    func binaryAttributes() {
        let got = runs(#"0,0,Default,,0,0,0,,{\b1}bold{\b0} {\i1}it{\i0} {\u1}un{\u0} {\s1}st{\s0}"#)
        #expect(got.first(where: { $0.text == "bold" })?.isBold == true)
        #expect(got.first(where: { $0.text == "it" })?.isItalic == true)
        #expect(got.first(where: { $0.text == "un" })?.isUnderlined == true)
        #expect(got.first(where: { $0.text == "st" })?.isStruckThrough == true)
    }

    @Test("an attribute turned off does not leak into later runs")
    func attributeTurnsOff() {
        let got = runs(#"0,0,Default,,0,0,0,,{\b1}loud{\b0} quiet"#)
        #expect(got.count == 2)
        #expect(got[0].isBold == true)
        #expect(got[1].isBold == false)
        #expect(got[1].text == " quiet")
    }

    @Test("several tags in one override block all apply")
    func multipleTagsInOneBlock() {
        let got = runs(#"0,0,Default,,0,0,0,,{\i1\b1}both"#)
        #expect(got.count == 1)
        #expect(got[0].isBold == true)
        #expect(got[0].isItalic == true)
    }

    @Test("a non-zero ass weight counts as bold")
    func assWeightIsBold() {
        #expect(runs(#"0,0,Default,,0,0,0,,{\b700}heavy"#).first?.isBold == true)
        #expect(runs(#"0,0,Default,,0,0,0,,{\b0}plain"#).first?.isBold == false)
    }

    @Test("font name and size are carried and reset by a bare tag")
    func fontNameAndSize() {
        let got = runs(#"0,0,Default,,0,0,0,,{\fnArial}{\fs40}big{\fn}{\fs}back"#)
        #expect(got.first(where: { $0.text == "big" })?.fontName == "Arial")
        #expect(got.first(where: { $0.text == "big" })?.fontSize == 40)
        #expect(got.first(where: { $0.text == "back" })?.fontName == nil)
        #expect(got.first(where: { $0.text == "back" })?.fontSize == nil)
    }

    @Test("a font name containing a space survives")
    func fontNameWithSpace() {
        #expect(runs(#"0,0,Default,,0,0,0,,{\fnArial Black}x"#).first?.fontName == "Arial Black")
    }

    /// `\be`, `\bord`, `\iclip`, `\shad`, `\fscx` and `\fsp` all start with a letter this parser
    /// cares about and none of them is the tag it looks like.
    @Test("lookalike tags do not set the attribute they resemble")
    func lookalikeTagsAreIgnored() {
        #expect(runs(#"0,0,Default,,0,0,0,,{\be1}x"#).first?.isBold == false)
        #expect(runs(#"0,0,Default,,0,0,0,,{\bord2}x"#).first?.isBold == false)
        #expect(runs(#"0,0,Default,,0,0,0,,{\iclip(1,2,3,4)}x"#).first?.isItalic == false)
        #expect(runs(#"0,0,Default,,0,0,0,,{\shad2}x"#).first?.isStruckThrough == false)
        #expect(runs(#"0,0,Default,,0,0,0,,{\fscx200}x"#).first?.fontSize == nil)
        #expect(runs(#"0,0,Default,,0,0,0,,{\fsp3}x"#).first?.fontSize == nil)
    }

    @Test("a style reset clears every accumulated attribute")
    func styleResetClearsAttributes() {
        let got = runs(#"0,0,Default,,0,0,0,,{\b1\i1\fnArial}styled{\r}plain"#)
        let plain = got.first(where: { $0.text == "plain" })
        #expect(plain?.isBold == false)
        #expect(plain?.isItalic == false)
        #expect(plain?.fontName == nil)
    }

    // MARK: - Colour, the behaviour that already existed

    @Test("colour still parses and still splits runs")
    func colourRegression() {
        let got = runs(#"0,0,Default,,0,0,0,,{\c&H0000FF&}red{\c&H00FF00&}green"#)
        #expect(got.count == 2)
        #expect(got[0].color == SubtitleColor(r: 255, g: 0, b: 0))
        #expect(got[1].color == SubtitleColor(r: 0, g: 255, b: 0))
    }

    @Test("colour and a binary attribute coexist on one run")
    func colourAndAttribute() {
        let got = runs(#"0,0,Default,,0,0,0,,{\c&H0000FF&\i1}both"#)
        #expect(got.count == 1)
        #expect(got[0].color == SubtitleColor(r: 255, g: 0, b: 0))
        #expect(got[0].isItalic == true)
    }

    // MARK: - Placement

    @Test("an alignment tag lands on the cue, not the run")
    func alignmentIsCueLevel() {
        #expect(placement(#"0,0,Default,,0,0,0,,{\an8}top"#)?.alignment == 8)
        #expect(placement(#"0,0,Default,,0,0,0,,plain"#) == nil)
    }

    /// A libavcodec-generated line positions against the default ASS play resolution, 384x288
    /// (`ASS_DEFAULT_PLAYRESX/Y`), so the centre of that space is the centre of the frame.
    @Test("a position tag normalizes against the play resolution")
    func positionNormalizes() {
        let p = placement(#"0,0,Default,,0,0,0,,{\pos(192,144)}mid"#)
        #expect(p?.position?.x == 0.5)
        #expect(p?.position?.y == 0.5)
    }

    @Test("a position is normalized against a declared play resolution when one is given")
    func positionUsesDeclaredPlayRes() {
        let parsed = SubtitleRectText.styledRuns(
            fromASSEventLine: #"0,0,Default,,0,0,0,,{\pos(960,540)}mid"#,
            playRes: CGSize(width: 1920, height: 1080))
        #expect(parsed?.placement?.position?.x == 0.5)
        #expect(parsed?.placement?.position?.y == 0.5)
    }

    @Test("play resolution is read from an ass header when it declares one")
    func playResFromHeader() {
        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        """
        #expect(SubtitleRectText.playRes(fromASSHeader: header) == CGSize(width: 1920, height: 1080))
        #expect(SubtitleRectText.playRes(fromASSHeader: "[Script Info]\nScriptType: v4.00+") == nil)
    }

    // MARK: - The formats this actually serves

    /// What `ff_htmlmarkup_to_ass` emits for `<i>ciao</i> <font color="#FF0000">rosso</font>`.
    @Test("an srt line converted by libavcodec reaches the host styled")
    func srtShapedLine() {
        let got = runs(#"0,0,Default,,0,0,0,,{\i1}ciao{\i0} {\c&H0000FF&}rosso"#)
        #expect(got.first(where: { $0.text == "ciao" })?.isItalic == true)
        #expect(got.first(where: { $0.text == "rosso" })?.color == SubtitleColor(r: 255, g: 0, b: 0))
    }

    /// WebVTT maps only its inline tags; cue settings never arrive (webvttdec `@todo`).
    @Test("a webvtt line converted by libavcodec reaches the host styled")
    func webvttShapedLine() {
        let got = runs(#"0,0,Default,,0,0,0,,{\b1}loud{\b0} then {\i1}soft"#)
        #expect(got.first(where: { $0.text == "loud" })?.isBold == true)
        #expect(got.first(where: { $0.text == "soft" })?.isItalic == true)
    }

    // MARK: - Body selection

    @Test("an unstyled line stays plain text so nothing regresses for text-only hosts")
    func unstyledStaysPlainText() {
        guard case .text(let s) = SubtitleRectText.styledBody(fromASSEventLine: "0,0,Default,,0,0,0,,just words")?.body else {
            Issue.record("expected .text")
            return
        }
        #expect(s == "just words")
    }

    @Test("a styled line becomes rich text")
    func styledBecomesRichText() {
        guard case .richText(let r) = SubtitleRectText.styledBody(fromASSEventLine: #"0,0,Default,,0,0,0,,{\i1}words"#)?.body else {
            Issue.record("expected .richText")
            return
        }
        #expect(r.count == 1)
        #expect(r[0].isItalic == true)
    }

    @Test("escapes and line breaks survive the styled path")
    func escapesSurvive() {
        let got = runs(#"0,0,Default,,0,0,0,,{\i1}one\Ntwo\hthree"#)
        #expect(got.map(\.text).joined() == "one\ntwo three")
    }

    // MARK: - Teletext behaviour that must not regress

    /// #107: libzvbi joins teletext rows with `\N`, so a caption on non-adjacent rows arrives as
    /// `line1\n\nline2`. That fold is teletext-specific and must not apply to ASS or SRT, where a
    /// blank line can be deliberate.
    @Test("teletext still folds interior blank lines")
    func teletextFoldsBlankLines() {
        guard case .text(let s) = SubtitleRectText.teletextBody(fromASSEventLine: #"0,0,Default,,0,0,0,,line1\N\Nline2"#)?.body else {
            Issue.record("expected .text")
            return
        }
        #expect(s == "line1\nline2")
    }

    @Test("the general path keeps a deliberate blank line")
    func generalPathKeepsBlankLine() {
        guard case .text(let s) = SubtitleRectText.styledBody(fromASSEventLine: #"0,0,Default,,0,0,0,,line1\N\Nline2"#)?.body else {
            Issue.record("expected .text")
            return
        }
        #expect(s == "line1\n\nline2")
    }

    @Test("teletext colour still produces rich text")
    func teletextColourRegression() {
        guard case .richText(let r) = SubtitleRectText.teletextBody(fromASSEventLine: #"0,0,Default,,0,0,0,,{\c&H00FFFF&}yellow"#)?.body else {
            Issue.record("expected .richText")
            return
        }
        #expect(r[0].color == SubtitleColor(r: 255, g: 255, b: 0))
    }
}
