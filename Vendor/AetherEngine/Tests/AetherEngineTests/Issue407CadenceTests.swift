import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import AetherEngine

/// #407 (classicjazz): VC-1 judder on tvOS where every counter on the 1 Hz `[SWDiag]` line reads
/// healthy while the picture is visibly uneven. His capture settled the panel (Match Frame Rate
/// landed on 23.976), the decoder (`enq` at the content rate, `parkedPkts` steady) and the display
/// layer (no drops, no accumulated delay), which leaves the one thing the line could not describe:
/// the cadence itself.
///
/// `enq` is a count per wall second taken in the DECODER callback. An even 24 fps timeline, one
/// carrying a doubled interval or a duplicate timestamp, and one where a frame never reached the
/// layer all read `+24`. These are the three counters that separate them, plus the frame duration
/// the layer was never given.
@Suite("Software-path cadence surface (#407)")
@MainActor
struct Issue407CadenceTests {

    static func makePixelBuffer(width: Int = 64, height: Int = 36) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        try #require(status == kCVReturnSuccess)
        return try #require(pb)
    }

    static func pts(ms: Int64) -> CMTime { CMTimeMake(value: ms, timescale: 1000) }

    // MARK: - Frame duration

    /// The reorder buffer is already holding the successor when a frame goes out, so the exact
    /// length costs nothing and needs no extra latency.
    @Test("the successor's timestamp is the frame's duration")
    func durationFromSuccessor() {
        let d = SampleBufferRenderer.frameDuration(from: Self.pts(ms: 1000), to: Self.pts(ms: 1042))
        #expect(abs(CMTimeGetSeconds(d) - 0.042) < 1e-9)
    }

    /// The last frame of a stream is the one that stays on screen at end of media, and a length is
    /// exactly what it must not carry.
    @Test("no successor means no duration")
    func noSuccessorNoDuration() {
        #expect(!SampleBufferRenderer.frameDuration(from: Self.pts(ms: 1000), to: nil).isValid)
    }

    /// A non-positive gap is a duplicate or a reordering fault and a gap past a second is a stream
    /// discontinuity; neither is a length to present a picture for.
    @Test("an impossible gap is not a duration", arguments: [
        (1000 as Int64, 1000 as Int64),   // duplicate timestamp
        (1000, 900),                      // out of order
        (1000, 3000),                     // discontinuity
    ])
    func implausibleGapRejected(from: Int64, to: Int64) {
        #expect(!SampleBufferRenderer.frameDuration(from: Self.pts(ms: from), to: Self.pts(ms: to)).isValid)
    }

    @Test("an unschedulable endpoint is not a duration")
    func nonNumericRejected() {
        #expect(!SampleBufferRenderer.frameDuration(from: .invalid, to: Self.pts(ms: 42)).isValid)
        #expect(!SampleBufferRenderer.frameDuration(from: Self.pts(ms: 42), to: .indefinite).isValid)
    }

    @Test("the duration reaches the sample buffer")
    func durationOnSampleBuffer() throws {
        let renderer = SampleBufferRenderer()
        let sample = try #require(renderer.createSampleBuffer(
            from: try Self.makePixelBuffer(), pts: Self.pts(ms: 1000),
            duration: Self.pts(ms: 42)))
        #expect(abs(CMTimeGetSeconds(CMSampleBufferGetDuration(sample)) - 0.042) < 1e-9)
    }

    // MARK: - Cadence counters

    /// The failure this exists for: a per-second frame count that cannot tell an even timeline from
    /// one with a hole in it. Both runs hand over the same number of frames.
    @Test("a hole in the timeline shows in the spacing, not in the count")
    func spacingSeesWhatTheCountCannot() throws {
        let pixelBuffer = try Self.makePixelBuffer()

        func handOver(_ timestampsMs: [Int64]) -> SampleBufferRenderer.Cadence {
            let renderer = SampleBufferRenderer()
            for ms in timestampsMs {
                renderer.enqueue(pixelBuffer: pixelBuffer, pts: Self.pts(ms: ms))
            }
            renderer.drainReorderBuffer()
            return renderer.takeCadence()
        }

        let even = handOver([0, 42, 83, 125, 167, 209, 250])
        let holed = handOver([0, 42, 83, 125, 250, 292, 334])

        #expect(even.handedOver == holed.handedOver)
        #expect((even.maxDeltaSeconds ?? 0) < 0.05)
        #expect((holed.maxDeltaSeconds ?? 0) > 0.1)
    }

    @Test("the spacing extremes describe the interval, not the session")
    func spacingResetsPerSnapshot() throws {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Self.makePixelBuffer()

        for ms in [0, 42, 500] as [Int64] {
            renderer.enqueue(pixelBuffer: pixelBuffer, pts: Self.pts(ms: ms))
        }
        renderer.drainReorderBuffer()
        #expect((renderer.takeCadence().maxDeltaSeconds ?? 0) > 0.4)

        for ms in [542, 584, 626] as [Int64] {
            renderer.enqueue(pixelBuffer: pixelBuffer, pts: Self.pts(ms: ms))
        }
        renderer.drainReorderBuffer()
        let second = renderer.takeCadence()
        #expect((second.maxDeltaSeconds ?? 0) < 0.05)
    }

    @Test("no frames handed over means no spacing to report")
    func emptyIntervalReportsNoSpacing() {
        let cadence = SampleBufferRenderer().takeCadence()
        #expect(cadence.minDeltaSeconds == nil)
        #expect(cadence.maxDeltaSeconds == nil)
    }

    /// A seek does not connect the frame before it to the frame after it. Left standing, the series
    /// would report the distance travelled as one enormous frame interval.
    @Test("the spacing series does not survive a flush")
    func flushBreaksTheSeries() throws {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Self.makePixelBuffer()

        for ms in [0, 42, 83, 125, 167] as [Int64] {
            renderer.enqueue(pixelBuffer: pixelBuffer, pts: Self.pts(ms: ms))
        }
        renderer.drainReorderBuffer()
        _ = renderer.takeCadence()

        renderer.flush(removingDisplayedImage: false)
        for ms in [600_000, 600_042, 600_083] as [Int64] {
            renderer.enqueue(pixelBuffer: pixelBuffer, pts: Self.pts(ms: ms))
        }
        renderer.drainReorderBuffer()

        #expect((renderer.takeCadence().maxDeltaSeconds ?? 0) < 0.05)
    }

    /// The gap `enq` cannot show: frames the decoder produced that the layer never received.
    @Test("frames lost before the layer are counted apart from the ones handed over")
    func lostFramesCounted() throws {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Self.makePixelBuffer()

        for ms in [0, -1, 42, -1, 83] as [Int64] {
            renderer.enqueue(pixelBuffer: pixelBuffer,
                             pts: ms < 0 ? .invalid : Self.pts(ms: ms))
        }
        renderer.drainReorderBuffer()

        let cadence = renderer.takeCadence()
        #expect(cadence.handedOver == 3)
        #expect(cadence.lostBeforeLayer == 2)
    }

    @Test("the counts are cumulative across snapshots")
    func countsAreCumulative() throws {
        let renderer = SampleBufferRenderer()
        let pixelBuffer = try Self.makePixelBuffer()

        renderer.enqueue(pixelBuffer: pixelBuffer, pts: Self.pts(ms: 0))
        renderer.drainReorderBuffer()
        #expect(renderer.takeCadence().handedOver == 1)

        renderer.enqueue(pixelBuffer: pixelBuffer, pts: Self.pts(ms: 42))
        renderer.drainReorderBuffer()
        #expect(renderer.takeCadence().handedOver == 2)
    }
}
