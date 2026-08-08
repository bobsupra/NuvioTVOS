import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

/// #261: an ASS header's declared play resolution is the only frame of reference `\pos` has, and
/// the header reaches us as codec extradata exactly as the muxer stored it. Muxed ASS is
/// conventionally CRLF, so the line is `"PlayResX: 718\r"`. `CharacterSet.whitespaces` is space
/// and tab, not CR, so the trailing CR survived both trims and `Double("718\r")` returned nil.
/// Both lookups failed, the parser reported "declares none", and every `\pos` on the track
/// normalized against libavcodec's 384x288 default instead.
///
/// On the reporter's 718x480 script `{\an1\pos(298,432)}` arrived at the host as
/// (0.7760, 1.5000) rather than (0.4151, 0.9000): off-picture, which is indistinguishable from a
/// cue that never arrived. Every fixture in the suite was a Swift multi-line literal, so LF only,
/// and the whole class of failure was invisible to the tests. These fixtures carry their line
/// endings explicitly for that reason.
struct Issue261ASSHeaderLineEndingsTests {

    /// The reporter's CodecPrivate, line endings included.
    private let crlfHeader = "[Script Info]\r\nScriptType: v4.00+\r\nPlayResX: 718\r\nPlayResY: 480\r\nTimer: 100.0000\r\n"
    private let lfHeader = "[Script Info]\nScriptType: v4.00+\nPlayResX: 718\nPlayResY: 480\nTimer: 100.0000\n"
    private let crHeader = "[Script Info]\rScriptType: v4.00+\rPlayResX: 718\rPlayResY: 480\rTimer: 100.0000\r"

    @Test("a CRLF header declares its play resolution just as an LF one does")
    func crlfHeaderIsRead() {
        #expect(SubtitleRectText.playRes(fromASSHeader: crlfHeader) == CGSize(width: 718, height: 480))
    }

    @Test("line endings do not change what a header declares")
    func lineEndingsAgree() {
        let crlf = SubtitleRectText.playRes(fromASSHeader: crlfHeader)
        #expect(crlf == SubtitleRectText.playRes(fromASSHeader: lfHeader))
        #expect(crlf == SubtitleRectText.playRes(fromASSHeader: crHeader))
    }

    @Test("trailing spaces before the line ending are still trimmed")
    func trailingSpacesTolerated() {
        let header = "[Script Info]\r\nPlayResX: 1920 \r\nPlayResY:\t1080\t\r\n"
        #expect(SubtitleRectText.playRes(fromASSHeader: header) == CGSize(width: 1920, height: 1080))
    }

    @Test("a header that declares no play resolution still reports none")
    func undeclaredStaysNil() {
        #expect(SubtitleRectText.playRes(fromASSHeader: "[Script Info]\r\nScriptType: v4.00+\r\n") == nil)
    }

    /// The reporter's cue, end to end: 432 of a declared 480 is 90% down the frame, and that is
    /// on the picture. Against the 384x288 default it was 1.5, which is not.
    @Test("the reporter's cue lands on the picture once the header is read")
    func reporterCueLandsOnPicture() {
        let playRes = SubtitleRectText.playRes(fromASSHeader: crlfHeader) ?? SubtitleRectText.defaultASSPlayRes
        let placement = SubtitleRectText.styledRuns(
            fromASSEventLine: #"0,0,Default,,0,0,0,,{\an1\pos(298,432)}bottom left"#,
            playRes: playRes)?.placement
        #expect(placement?.alignment == 1)
        #expect(abs((placement?.position?.x ?? 0) - 298.0 / 718.0) < 0.0001)
        #expect(abs((placement?.position?.y ?? 0) - 0.9) < 0.0001)
    }
}
