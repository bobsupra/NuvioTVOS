import Testing
import Foundation
import CoreMedia
@testable import AetherEngine

/// AE#491: a seek flushes the renderer and then AWAITS the reposition, and the decode thread keeps
/// running under that await. A frame decoded from a packet read before the seek used to arrive at a
/// renderer whose skip threshold was not armed until after the landing, so it was taken. It then
/// owned the newest handed-over timestamp and the frontier, and the first real post-seek frame
/// reported the whole seek distance as one inter-frame interval (`dpts`) over a negative cushion
/// (`vLead`) of the same size.
@Suite("Stale pre-seek references (#491)")
struct Issue491StaleSeekReferenceTests {

    /// The mechanism, stated as a test so the fix has something to be a fix OF: with no threshold
    /// standing between the flush and the landing, one pre-seek frame is enough.
    @Test("with no threshold armed, a pre-seek frame sets the spacing base and the frontier")
    @MainActor
    func unguardedStaleFrameOwnsBothReferences() {
        let renderer = SampleBufferRenderer()
        Self.hand(renderer, seconds: [949.66, 949.70, 949.74])
        renderer.flush(removingDisplayedImage: false)
        _ = renderer.takeCadence()

        // The frame the decoder was already holding when the flush ran.
        Self.hand(renderer, seconds: [949.78])
        // The landing, 161.6 s away. Six, so the reorder buffer pushes three frames out of its
        // four-deep hold and the spacing counters see two intervals.
        Self.hand(renderer, seconds: [1111.34, 1111.38, 1111.42, 1111.46, 1111.50, 1111.54])

        let cadence = renderer.takeCadence()
        #expect((cadence.maxDeltaSeconds ?? 0) > 100)
        #expect((renderer.newestEnqueuedPtsSeconds ?? 0) > 1111)
    }

    @Test("the threshold armed at flush time keeps the pre-seek frame out of both")
    @MainActor
    func armedThresholdRejectsTheStaleFrame() {
        let renderer = SampleBufferRenderer()
        Self.hand(renderer, seconds: [949.66, 949.70, 949.74])
        renderer.flush(removingDisplayedImage: false)
        _ = renderer.takeCadence()
        // What `seek(to:)` now does BEFORE awaiting the reposition.
        renderer.setSkipThreshold(CMTime(seconds: 1111.34, preferredTimescale: 90000))

        Self.hand(renderer, seconds: [949.78])
        #expect(renderer.newestEnqueuedPtsSeconds == nil)

        Self.hand(renderer, seconds: [1111.34, 1111.38, 1111.42, 1111.46, 1111.50, 1111.54])
        let cadence = renderer.takeCadence()
        // Only the post-seek run contributed a spacing, so the extremes are one frame apart.
        #expect((cadence.maxDeltaSeconds ?? 1) < 0.1)
        #expect((renderer.newestEnqueuedPtsSeconds ?? 0) > 1111)
    }

    /// A backward seek lands BEHIND the stale frame, so its timestamp clears the threshold on the
    /// way through. That direction is covered by the generation guard on the decoder callback, not
    /// by the threshold, which is why both stand.
    @Test("a backward seek's threshold does not stop a stale frame past the target")
    @MainActor
    func backwardSeekThresholdIsNotEnoughOnItsOwn() {
        let renderer = SampleBufferRenderer()
        Self.hand(renderer, seconds: [1453.90, 1453.94, 1453.98])
        renderer.flush(removingDisplayedImage: false)
        _ = renderer.takeCadence()
        renderer.setSkipThreshold(CMTime(seconds: 900.0, preferredTimescale: 90000))

        Self.hand(renderer, seconds: [1454.02])
        #expect(renderer.newestEnqueuedPtsSeconds == 1454.02)
    }

    /// Hands frames over one at a time; the reorder buffer holds four, so the tail of a run stays
    /// inside it and only the frames pushed out of it reach the spacing counters.
    private static func hand(_ renderer: SampleBufferRenderer, seconds: [Double]) {
        for s in seconds {
            renderer.enqueue(pixelBuffer: makePixelBuffer(),
                             pts: CMTime(seconds: s, preferredTimescale: 90000))
        }
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
}
