import Testing
import CoreGraphics
import CoreText
import Foundation
@testable import AetherEngine

/// #233: the SW-PiP compositor flattened `.richText` to `runs.map(\.text).joined()` and drew every
/// cue in one white font at the bottom, so the styling the parser now preserves would have stopped
/// at the PiP window. It renders per-run attributes and honours the cue's placement instead.
struct Issue233CompositorStylingTests {

    private let frame = CGSize(width: 1920, height: 1080)
    private let block = CGSize(width: 400, height: 100)

    private func origin(_ alignment: Int?, _ position: CGPoint?) -> CGPoint {
        SubtitleFrameCompositor.blockOrigin(
            placement: SubtitleTextPlacement(alignment: alignment, position: position),
            blockSize: block, frameWidth: frame.width, frameHeight: frame.height,
            margin: 64)
    }

    // MARK: - Alignment without an explicit position

    @Test("alignment 1 pins the block to the bottom left inside the margin")
    func bottomLeft() {
        #expect(origin(1, nil) == CGPoint(x: 64, y: 64))
    }

    @Test("alignment 3 pins the block to the bottom right inside the margin")
    func bottomRight() {
        #expect(origin(3, nil) == CGPoint(x: 1920 - 400 - 64, y: 64))
    }

    @Test("alignment 8 pins the block to the top, centred")
    func topCentre() {
        #expect(origin(8, nil) == CGPoint(x: (1920 - 400) / 2, y: 1080 - 100 - 64))
    }

    @Test("alignment 5 centres the block on both axes")
    func middleCentre() {
        #expect(origin(5, nil) == CGPoint(x: (1920 - 400) / 2, y: (1080 - 100) / 2))
    }

    // MARK: - Explicit position

    /// `\pos` names the anchor point, and the alignment says which part of the block sits on it.
    /// Position is normalized with y measured from the top; the context draws bottom-up.
    @Test("a centred position anchors the block centre on the point")
    func positionWithCentreAlignment() {
        let got = origin(5, CGPoint(x: 0.5, y: 0.5))
        #expect(got == CGPoint(x: 960 - 200, y: 540 - 50))
    }

    @Test("a bottom-left alignment puts the block corner on the point")
    func positionWithCornerAlignment() {
        let got = origin(1, CGPoint(x: 0.25, y: 0.75))
        #expect(got == CGPoint(x: 480, y: 270))
    }

    @Test("a position with no alignment falls back to the ass default of bottom centre")
    func positionDefaultsToBottomCentre() {
        #expect(origin(nil, CGPoint(x: 0.5, y: 0.5)) == origin(2, CGPoint(x: 0.5, y: 0.5)))
    }

    // MARK: - Rendering

    @Test("a styled cue still produces an overlay image")
    func rendersStyledCue() {
        let runs = [
            SubtitleTextRun(text: "bold ", color: SubtitleColor(r: 255, g: 0, b: 0), isBold: true),
            SubtitleTextRun(text: "italic", color: nil, isItalic: true, fontName: "Helvetica", fontSize: 32),
        ]
        let cue = SubtitleCue(id: 1, startTime: 0, endTime: 5, body: .richText(runs))
        #expect(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 640, frameHeight: 360) != nil)
    }

    @Test("a placed cue still produces an overlay image")
    func rendersPlacedCue() {
        let cue = SubtitleCue(
            id: 1, startTime: 0, endTime: 5, body: .text("top"),
            placement: SubtitleTextPlacement(alignment: 8, position: nil))
        #expect(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 640, frameHeight: 360) != nil)
    }

    /// Bold and italic have to reach CoreText as real traits, not be silently dropped.
    @Test("bold and italic resolve to a font carrying those traits")
    func fontTraits() {
        let plain = SubtitleFrameCompositor.font(
            for: SubtitleTextRun(text: "x", color: nil), baseSize: 40)
        let bold = SubtitleFrameCompositor.font(
            for: SubtitleTextRun(text: "x", color: nil, isBold: true), baseSize: 40)
        let italic = SubtitleFrameCompositor.font(
            for: SubtitleTextRun(text: "x", color: nil, isItalic: true), baseSize: 40)
        #expect(CTFontGetSymbolicTraits(plain).contains(CTFontSymbolicTraits.traitBold) == false)
        #expect(CTFontGetSymbolicTraits(bold).contains(CTFontSymbolicTraits.traitBold))
        #expect(CTFontGetSymbolicTraits(italic).contains(CTFontSymbolicTraits.traitItalic))
    }

    /// ASS `\fs` is relative to libavcodec's default style size of 16, so it scales the base size
    /// rather than naming pixels.
    @Test("an ass font size scales the base size relative to the ass default")
    func fontSizeScales() {
        let doubled = SubtitleFrameCompositor.font(
            for: SubtitleTextRun(text: "x", color: nil, fontSize: 32), baseSize: 40)
        #expect(CTFontGetSize(doubled) == 80)
        let unset = SubtitleFrameCompositor.font(
            for: SubtitleTextRun(text: "x", color: nil), baseSize: 40)
        #expect(CTFontGetSize(unset) == 40)
    }
}
