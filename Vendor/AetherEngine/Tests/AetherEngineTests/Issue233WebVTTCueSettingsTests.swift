import Testing
import Foundation
@testable import AetherEngine

/// #233 follow-up: WebVTT cue settings never reached the host, and the first pass concluded they
/// could not.
///
/// That conclusion looked at the wrong layer. libavcodec's WebVTT *decoder* really does drop
/// `line` / `position` / `align` (`libavcodec/webvttdec.c` says so as a `@todo` in its file
/// header), so nothing about the placement is in the ASS event line the decoder synthesises. The
/// *demuxer* keeps them: `libavformat/webvttdec.c` attaches the verbatim settings string to every
/// packet as `AV_PKT_DATA_WEBVTT_SETTINGS`, and `matroskadec.c` propagates the same side data for
/// WebVTT in Matroska. So the placement travels one layer above where the parser was looking.
struct Issue233WebVTTCueSettingsTests {

    private func placement(_ settings: String) -> SubtitleTextPlacement? {
        WebVTTCueSettings.placement(fromSettings: settings)
    }

    // MARK: - Horizontal

    @Test("align picks the ASS numpad column and leaves the row at the bottom default")
    func alignColumns() {
        #expect(placement("align:start")?.alignment == 1)
        #expect(placement("align:center")?.alignment == 2)
        #expect(placement("align:end")?.alignment == 3)
        // Old draft spellings still emitted by real tools.
        #expect(placement("align:left")?.alignment == 1)
        #expect(placement("align:right")?.alignment == 3)
        #expect(placement("align:middle")?.alignment == 2)
        // A column alone is an anchor, not a geometric point: the host keeps its own margin.
        #expect(placement("align:center")?.position == nil)
    }

    // MARK: - Vertical

    @Test("a line percentage becomes a position anchored to the nearer edge")
    func linePercentage() {
        let top = placement("line:10%")
        #expect(top?.alignment == 8)
        #expect(top?.position?.x == 0.5)
        #expect(top?.position?.y == 0.1)

        // 90% with the spec's default line alignment would anchor the box TOP at 90% and hang a
        // two-line cue off the frame. Anchoring to the nearer edge renders what the file means.
        let bottom = placement("line:90%")
        #expect(bottom?.alignment == 2)
        #expect(bottom?.position?.y == 0.9)
    }

    @Test("an explicit line alignment wins over the nearer-edge default")
    func lineAlignSuffix() {
        #expect(placement("line:10%,start")?.alignment == 8)
        #expect(placement("line:10%,center")?.alignment == 5)
        #expect(placement("line:10%,end")?.alignment == 2)
        #expect(placement("line:90%,start")?.alignment == 8)
    }

    @Test("a line NUMBER keeps its half of the frame and no position")
    func lineNumber() {
        // Line boxes need the rendered line height, which the engine does not have. The half of
        // the frame the number asks for is unambiguous, so that is all it yields.
        #expect(placement("line:0")?.alignment == 8)
        #expect(placement("line:0")?.position == nil)
        #expect(placement("line:-1")?.alignment == 2)
        #expect(placement("line:-1")?.position == nil)
        #expect(placement("line:3")?.alignment == 8)
    }

    // MARK: - Combined

    @Test("position and align resolve the horizontal anchor of a placed cue")
    func positionWithLine() {
        let p = placement("line:90% position:20% align:start")
        #expect(p?.alignment == 1)
        #expect(p?.position?.x == 0.2)
        #expect(p?.position?.y == 0.9)
    }

    @Test("a horizontal offset without a line keeps the column only")
    func positionWithoutLine() {
        // A point needs both axes; the engine models no half-position. The column still carries
        // most of the intent and leaves the host's vertical margin intact.
        let p = placement("position:20% align:start")
        #expect(p?.alignment == 1)
        #expect(p?.position == nil)
    }

    @Test("settings are separated by spaces or tabs")
    func separators() {
        #expect(placement("align:start\tline:0")?.alignment == 7)
        #expect(placement("  align:end   line:0  ")?.alignment == 9)
    }

    // MARK: - Nothing to say

    @Test("settings the engine cannot express produce no placement")
    func unsupported() {
        #expect(placement("") == nil)
        #expect(placement("size:50%") == nil)
        #expect(placement("region:fred") == nil)
        // Vertical writing mode is not a placement the compositor can honour, and placing sideways
        // text as if it were horizontal is worse than leaving it to the host.
        #expect(placement("vertical:rl") == nil)
        #expect(placement("vertical:lr align:start line:0") == nil)
    }

    @Test("malformed values are ignored rather than guessed")
    func malformed() {
        #expect(placement("line:abc") == nil)
        #expect(placement("position:%") == nil)
        #expect(placement("align:") == nil)
        #expect(placement("line:200%")?.position?.y == 1.0)   // clamped, not dropped
        #expect(placement("line:-30%")?.position?.y == 0.0)
    }

    // MARK: - End to end through the real demuxer

    @Test("cue settings survive a sidecar WebVTT decode")
    func sidecarDecodeCarriesPlacement() async throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000 line:10% align:start
        Top left caption

        00:00:04.000 --> 00:00:06.000
        Plain caption
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae-issue233-\(ProcessInfo.processInfo.globallyUniqueString).vtt")
        try vtt.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await SubtitleDecoder.decodeFile(url: url)
        #expect(result.cues.count == 2)

        let placed = try #require(result.cues.first)
        #expect(placed.placement?.alignment == 7)
        #expect(placed.placement?.position?.x == 0.0)
        #expect(placed.placement?.position?.y == 0.1)

        // A cue that asks for nothing still asks for nothing.
        #expect(result.cues.last?.placement == nil)
    }
}
