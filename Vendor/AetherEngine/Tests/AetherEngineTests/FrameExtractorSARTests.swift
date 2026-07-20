import Testing
import AetherLibavutil
@testable import AetherEngine

/// Regression: FrameExtractor used coded width/height only, ignoring SAR, so anamorphic DVD
/// thumbnails rendered at 3:2 instead of 4:3. displayDimensions must fold SAR into output height.
struct FrameExtractorSARTests {

    private func ratio(_ wh: (Int, Int)) -> Double { Double(wh.0) / Double(wh.1) }

    @Test("NTSC 4:3 DVD thumbnail comes out 4:3, not 3:2")
    func ntsc43() {
        // 720x480 stored, SAR 8:9 -> displays 4:3.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 480, sar: AVRational(num: 8, den: 9), targetWidth: 320)
        #expect(dims.0 == 320)
        #expect(abs(ratio(dims) - 4.0 / 3.0) < 0.01,
                "expected 4:3, got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("Widescreen anamorphic DVD thumbnail comes out 16:9")
    func anamorphic169() {
        // 720x480 stored, SAR 32:27 -> displays 16:9.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 480, sar: AVRational(num: 32, den: 27), targetWidth: 320)
        #expect(abs(ratio(dims) - 16.0 / 9.0) < 0.01,
                "expected 16:9, got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("PAL 4:3 DVD thumbnail comes out 4:3")
    func pal43() {
        // 720x576 stored, SAR 16:15 (generic PAL 4:3) -> displays 4:3.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 576, sar: AVRational(num: 16, den: 15), targetWidth: 320)
        #expect(abs(ratio(dims) - 4.0 / 3.0) < 0.01,
                "expected 4:3, got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("BT.601 PAL SAR 12:11 applies (slightly wider than exact 4:3)")
    func pal601() {
        // SAR 12:11 yields ~1.364, not exact 4:3; must be applied (square would give 1.25).
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 720, srcH: 576, sar: AVRational(num: 12, den: 11), targetWidth: 320)
        #expect(abs(ratio(dims) - (720.0 * 12.0) / (576.0 * 11.0)) < 0.01,
                "SAR 12:11 not applied: got \(dims.0)x\(dims.1) = \(ratio(dims))")
    }

    @Test("Square-pixel source keeps its coded aspect")
    func squarePixels() {
        // 1920x1080 square pixels -> 16:9 unchanged.
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 1920, srcH: 1080, sar: AVRational(num: 1, den: 1), targetWidth: 320)
        #expect(dims.0 == 320 && dims.1 == 180)
    }

    @Test("Degenerate 0:0 SAR is treated as square")
    func degenerateSAR() {
        let dims = FrameDecodeContext.displayDimensions(
            srcW: 640, srcH: 480, sar: AVRational(num: 0, den: 0), targetWidth: 320)
        #expect(dims.0 == 320 && dims.1 == 240)
    }
}
