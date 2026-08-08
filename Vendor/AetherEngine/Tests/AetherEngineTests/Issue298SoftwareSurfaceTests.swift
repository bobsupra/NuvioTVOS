import Testing
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
@testable import AetherEngine

/// #298 (akacores): an AVI whose video track is packed-bitstream XviD played its audio to
/// completion while the picture never appeared, with `[Renderer] enqueue #30 ... ready=false` read
/// as "the renderer stopped accepting frames". That log line is what a HEALTHY software session
/// prints: `isReadyForMoreMediaData` is the demux loop's back-pressure gate, so a full queue right
/// after an enqueue is the gate working, and the counter reaching #100 at t+4.7 s on a 23.976 fps
/// source is real-time pacing. A queue that had truly stopped draining would have parked the one
/// demux loop that also feeds audio within a queue depth, and the audio would have stopped with it.
///
/// What the session cannot say today is where the frames went. Two silent host-side conditions
/// produce exactly this report, and neither leaves a trace:
///
/// - the display layer is in no view hierarchy at all (`AetherEngine.bind(view:)` / `AetherPlayerSurface`
///   never called; the software path does not render through AVPlayerViewController, which has no
///   AVPlayerItem here and shows its own spinner forever),
/// - the layer is attached to a view that never got a layout, so it is sized 0x0.
///
/// Plus one hardening: a frame whose PTS is not numeric cannot be scheduled by the render
/// synchronizer. The deinterlace path already drops its untimestamped output for that reason; the
/// direct path passed `CMTime.invalid` straight through to the display queue, and a NaN also
/// silently breaks the reorder buffer's PTS ordering (every comparison against NaN is false).
@Suite("Software-path surface visibility + unschedulable frame gate (#298)")
struct Issue298SoftwareSurfaceTests {

    // MARK: - Unschedulable frames

    @Test("a numeric PTS is schedulable")
    func numericPTSSchedulable() {
        #expect(SampleBufferRenderer.isSchedulable(CMTimeMake(value: 42, timescale: 1000)))
        #expect(SampleBufferRenderer.isSchedulable(.zero))
    }

    /// AV_NOPTS_VALUE reaches the decoder callback as `CMTime.invalid`; CoreMedia happily builds a
    /// sample buffer from it (measured: `CMSampleBufferCreateReadyWithImageBuffer` returns noErr and
    /// the sample's PTS reads back as NaN seconds), so nothing downstream rejects it either.
    @Test("an invalid, indefinite or infinite PTS is not schedulable")
    func nonNumericPTSRejected() {
        #expect(!SampleBufferRenderer.isSchedulable(.invalid))
        #expect(!SampleBufferRenderer.isSchedulable(.indefinite))
        #expect(!SampleBufferRenderer.isSchedulable(.positiveInfinity))
        #expect(!SampleBufferRenderer.isSchedulable(.negativeInfinity))
    }

    @Test("untimed frames never reach the display queue and are counted")
    func untimedFramesDropped() throws {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Self.makePixelBuffer()

        for _ in 0..<6 {
            renderer.enqueue(pixelBuffer: pixelBuffer, pts: .invalid)
        }
        renderer.drainReorderBuffer()

        #expect(renderer.untimedFramesDropped == 6)
        #expect(renderer.enqueueCount == 0)
    }

    @Test("timed frames still reach the display queue")
    func timedFramesPass() throws {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Self.makePixelBuffer()

        for i in 0..<5 {
            renderer.enqueue(pixelBuffer: pixelBuffer,
                             pts: CMTimeMake(value: Int64(i) * 42, timescale: 1000))
        }
        renderer.drainReorderBuffer()

        #expect(renderer.untimedFramesDropped == 0)
        #expect(renderer.enqueueCount == 5)
    }

    /// The gate also protects the reorder buffer: `CMTimeGetSeconds(.invalid)` is NaN and every
    /// comparison against NaN is false, so an untimed frame used to be appended past frames it
    /// should have preceded, reordering its neighbours as well.
    @Test("ordering of timed frames survives untimed ones in the same run")
    func orderingSurvivesUntimedFrames() throws {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Self.makePixelBuffer()

        for (i, pts) in [30, -1, 10, -1, 20].enumerated() {
            _ = i
            renderer.enqueue(pixelBuffer: pixelBuffer,
                             pts: pts < 0 ? .invalid : CMTimeMake(value: Int64(pts), timescale: 1000))
        }
        renderer.drainReorderBuffer()

        #expect(renderer.untimedFramesDropped == 2)
        #expect(renderer.enqueueCount == 3)
    }

    // MARK: - Surface visibility

    @Test("a layer in a view hierarchy with a real size is on screen")
    func boundSurfaceIsOnScreen() {
        #expect(SoftwarePlaybackHost.assessSurface(
            hasSuperlayer: true, size: CGSize(width: 1920, height: 1080)) == .onScreen)
    }

    /// The reported configuration: a host that presents AVPlayerViewController and never binds a
    /// render surface. Audio plays, the log is clean, no frame can ever be visible.
    @Test("a layer with no superlayer is named as unbound")
    func unboundSurfaceIsNamed() {
        #expect(SoftwarePlaybackHost.assessSurface(
            hasSuperlayer: false, size: CGSize(width: 1920, height: 1080)) == .notInViewHierarchy)
        // An unbound layer is usually zero-sized too; "never bound" is the more useful of the two.
        #expect(SoftwarePlaybackHost.assessSurface(
            hasSuperlayer: false, size: .zero) == .notInViewHierarchy)
    }

    @Test("a bound but unlaid-out surface is named by its size")
    func zeroSizedSurfaceIsNamed() {
        #expect(SoftwarePlaybackHost.assessSurface(
            hasSuperlayer: true, size: .zero) == .zeroSized(width: 0, height: 0))
        #expect(SoftwarePlaybackHost.assessSurface(
            hasSuperlayer: true, size: CGSize(width: 320, height: 0)) == .zeroSized(width: 320, height: 0))
    }

    // MARK: - Helpers

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 128, 96,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pb
        )
        #expect(status == kCVReturnSuccess)
        return try #require(pb)
    }
}
