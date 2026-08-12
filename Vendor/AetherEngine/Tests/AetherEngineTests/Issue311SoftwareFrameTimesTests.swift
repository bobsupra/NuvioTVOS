import Foundation
import Testing
import AVFoundation
import CoreMedia
@testable import AetherEngine

/// #311: the software path reports the frames it enqueues, and hands out the clock it presents them
/// against, so a host can pace a bitmap overlay (libass) frame-exactly without an AVPlayer.
///
/// The reporting point is the handover, not the admission: a frame that the renderer refuses, skips
/// after a seek, or fails to wrap in a sample buffer is one the compositor never receives, and a
/// presenter that stamped an overlay for it would place it at a boundary that does not exist.
@Suite("Software frame times (#311)")
@MainActor
struct Issue311SoftwareFrameTimesTests {

    // MARK: - What gets reported

    @Test("every enqueued frame is reported, in ascending presentation order")
    func reportsEnqueuedFramesInOrder() {
        let renderer = SampleBufferRenderer()
        let seen = Collector()
        renderer.setFrameEnqueuedObserver { seen.append($0) }

        // Decode order with a B-frame run. The reorder buffer holds 4, so handing over 6 frames
        // pushes the two oldest out, and those two are what the compositor has been given.
        for seconds in [0.00, 0.12, 0.04, 0.08, 0.20, 0.16] {
            renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                             pts: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        let reported = seen.values.map { $0.presentation.seconds }
        #expect(reported == [0.00, 0.04])

        // EOF drains the rest, still in ascending order rather than the order they arrived.
        renderer.drainReorderBuffer()
        #expect(seen.values.map { $0.presentation.seconds } == [0.00, 0.04, 0.08, 0.12, 0.16, 0.20])
    }

    @Test("a frame refused at the unschedulable-PTS gate is never reported")
    func untimedFrameIsNotReported() {
        let renderer = SampleBufferRenderer()
        let seen = Collector()
        renderer.setFrameEnqueuedObserver { seen.append($0) }

        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(), pts: .invalid)
        renderer.drainReorderBuffer()

        #expect(seen.values.isEmpty)
        #expect(renderer.untimedFramesDropped == 1)
    }

    @Test("frames skipped after a seek are never reported")
    func skippedFramesAreNotReported() {
        let renderer = SampleBufferRenderer()
        let seen = Collector()
        renderer.setFrameEnqueuedObserver { seen.append($0) }
        renderer.setSkipThreshold(CMTime(seconds: 10.0, preferredTimescale: 600))

        // The decoder runs from the preceding keyframe, so these arrive and are dropped.
        for seconds in [9.0, 9.5] {
            renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                             pts: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 10.0, preferredTimescale: 600))
        renderer.drainReorderBuffer()

        #expect(seen.values.map { $0.presentation.seconds } == [10.0])
    }

    // MARK: - Generation

    /// A seek flushes, and everything recorded before it describes frames the compositor no longer
    /// holds. Without a generation a consumer's table would keep entries that look current, and on a
    /// backward seek the two runs overlap in time, so the timestamps alone cannot separate them.
    ///
    /// The assertions are inequalities: since #314 the generation is drawn from a process-wide
    /// sequence, so a renderer in a parallel test legitimately consumes values in between. Ordering is
    /// the contract, consecutive values never were.
    @Test("a flush moves the generation, so pre-seek frames are distinguishable")
    func flushMovesTheGeneration() {
        let renderer = SampleBufferRenderer()
        let seen = Collector()
        renderer.setFrameEnqueuedObserver { seen.append($0) }

        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 30.0, preferredTimescale: 600))
        renderer.drainReorderBuffer()
        let before = renderer.flushGeneration

        renderer.flush(removingDisplayedImage: false)   // the seek
        #expect(renderer.flushGeneration > before)

        // Backward seek: the same timestamp comes round again under the new generation.
        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 30.0, preferredTimescale: 600))
        renderer.drainReorderBuffer()

        #expect(seen.values.count == 2)
        #expect(seen.values[0].presentation == seen.values[1].presentation)
        #expect(seen.values[1].generation > seen.values[0].generation)
    }

    // MARK: - Installation

    @Test("removing the observer stops the reports")
    func observerCanBeRemoved() {
        let renderer = SampleBufferRenderer()
        let seen = Collector()
        renderer.setFrameEnqueuedObserver { seen.append($0) }
        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 1.0, preferredTimescale: 600))
        renderer.drainReorderBuffer()
        #expect(seen.values.count == 1)

        renderer.setFrameEnqueuedObserver(nil)
        renderer.enqueue(pixelBuffer: Self.makePixelBuffer(),
                         pts: CMTime(seconds: 2.0, preferredTimescale: 600))
        renderer.drainReorderBuffer()
        #expect(seen.values.count == 1)
    }

    /// Both are nil on a path that has no software host, rather than a zero timebase or a callback
    /// that never fires for a reason the host cannot see.
    @Test("the timebase is nil without a software session")
    @MainActor
    func timebaseIsNilWithoutSession() throws {
        let engine = try AetherEngine()
        #expect(engine.softwarePresentationTimebase == nil)

        // Installing before a load is the documented usage: the engine holds it and re-arms the
        // next host with it.
        engine.setSoftwareVideoFrameTimeObserver { _ in }
        #expect(engine.softwareVideoFrameTimeObserver != nil)
        engine.setSoftwareVideoFrameTimeObserver(nil)
        #expect(engine.softwareVideoFrameTimeObserver == nil)
    }

    // MARK: - Helpers

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SoftwareVideoFrameTime] = []
        var values: [SoftwareVideoFrameTime] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ value: SoftwareVideoFrameTime) {
            lock.lock(); storage.append(value); lock.unlock()
        }
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
}
