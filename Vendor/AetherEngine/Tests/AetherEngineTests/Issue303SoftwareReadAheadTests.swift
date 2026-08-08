import Testing
import Foundation
import CoreMedia
@testable import AetherEngine

/// #303: the software path's read-ahead is whatever `AVSampleBufferVideoRenderer` accepts, and
/// until now nothing reported the depth it actually had. `frameAhead` is the native producer-shift
/// fold and reads 0 here by construction; `bufferedSessionTime` is fed only on live sessions, so a
/// VOD software session published a `bufferedPosition` that just mirrored the playhead.
@Suite("Software read-ahead telemetry (#303)")
struct Issue303SoftwareReadAheadTests {

    // MARK: - Frontier

    @Test("the enqueued frontier follows the newest presentation timestamp, not the newest call")
    func frontierTracksMaximum() {
        let renderer = SampleBufferRenderer()
        #expect(renderer.newestEnqueuedPtsSeconds == nil)

        // B-frame order: the decoder hands out 0.0, 0.12, 0.04, 0.08. The frontier is the newest
        // timestamp held, which the reorder buffer will present last, not the last one handed over.
        for seconds in [0.0, 0.12, 0.04, 0.08] {
            renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                             pts: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        let frontier = try? #require(renderer.newestEnqueuedPtsSeconds)
        #expect(frontier == 0.12)
    }

    @Test("a frame refused at the unschedulable-PTS gate does not advance the frontier")
    func untimedFrameDoesNotAdvanceFrontier() {
        let renderer = SampleBufferRenderer()
        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 1.0, preferredTimescale: 600))
        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(), pts: .invalid)

        #expect(renderer.newestEnqueuedPtsSeconds == 1.0)
        #expect(renderer.untimedFramesDropped == 1)
    }

    // MARK: - Cushion

    @Test("the cushion is the frontier's lead over the source clock")
    func cushionIsLeadOverSourceClock() {
        #expect(SoftwareBufferFrontier.cushionSeconds(newestEnqueuedPts: 12.5, sourceClock: 11.0) == 1.5)
    }

    @Test("nothing enqueued yet is no cushion, not a cushion of zero")
    func cushionIsNilBeforeFirstFrame() {
        #expect(SoftwareBufferFrontier.cushionSeconds(newestEnqueuedPts: nil, sourceClock: 11.0) == nil)
    }

    /// The synchronizer can read past the newest frame held (it keeps running while the queue
    /// starves, which is exactly the moment this number is interesting). A negative lead is not a
    /// negative cushion, it is an empty one.
    @Test("a clock past the frontier reports an empty cushion, never a negative one")
    func cushionClampsAtZero() {
        #expect(SoftwareBufferFrontier.cushionSeconds(newestEnqueuedPts: 10.0, sourceClock: 10.4) == 0)
    }

    // MARK: - bufferedPosition composition

    @Test("a VOD software session reports the cushion instead of mirroring the playhead")
    func bufferedPositionCarriesTheCushionOnVOD() {
        // Live frontier is 0 on VOD: `noteEdge` only runs on live sessions.
        let pos = SoftwareBufferFrontier.bufferedPosition(currentTime: 30.0, liveFrontier: 0, cushion: 1.25)
        #expect(pos == 31.25)
    }

    @Test("the live frontier still wins where it is the larger of the two")
    func liveFrontierIsPreserved() {
        let pos = SoftwareBufferFrontier.bufferedPosition(currentTime: 30.0, liveFrontier: 44.0, cushion: 1.25)
        #expect(pos == 44.0)
    }

    /// #54: `bufferedPosition` never trails the playhead, whatever the inputs say.
    @Test("bufferedPosition never trails the playhead")
    func bufferedPositionNeverTrailsPlayhead() {
        #expect(SoftwareBufferFrontier.bufferedPosition(currentTime: 30.0, liveFrontier: 0, cushion: nil) == 30.0)
        #expect(SoftwareBufferFrontier.bufferedPosition(currentTime: 30.0, liveFrontier: 12.0, cushion: nil) == 30.0)
    }

    // MARK: - memprobe fragment

    @Test("a native session adds nothing to the line")
    func fragmentIsEmptyWithoutASoftwareSession() {
        #expect(AetherEngine.softwareReadAheadFragment(cushionSeconds: nil, metrics: nil).isEmpty)
    }

    @Test("the cushion is reported before the display metrics can answer")
    func fragmentCarriesCushionAlone() {
        let s = AetherEngine.softwareReadAheadFragment(cushionSeconds: 1.417, metrics: nil)
        #expect(s == "swAhead=1.42s ")
    }

    @Test("a clean run does not print a corruption count")
    func fragmentOmitsCorruptWhenZero() {
        let m = SampleBufferRenderer.RenderMetrics(total: 1520, dropped: 3, corrupted: 0, accumulatedDelay: 0.08)
        let s = AetherEngine.softwareReadAheadFragment(cushionSeconds: 1.42, metrics: m)
        #expect(s == "swAhead=1.42s swDropped=3/1520 swDelay=0.08s ")
    }

    @Test("corrupted frames are named when there are any")
    func fragmentNamesCorruption() {
        let m = SampleBufferRenderer.RenderMetrics(total: 900, dropped: 0, corrupted: 2, accumulatedDelay: 0)
        let s = AetherEngine.softwareReadAheadFragment(cushionSeconds: nil, metrics: m)
        #expect(s == "swDropped=0/900 swCorrupt=2 swDelay=0.00s ")
    }

    // MARK: -

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
}
