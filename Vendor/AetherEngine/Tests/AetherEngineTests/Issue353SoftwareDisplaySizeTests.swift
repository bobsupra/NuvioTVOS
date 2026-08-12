import Combine
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

/// AE#353: the picture size the software path settled on, so a host overlay lays out against the
/// picture rather than the coded frame.
///
/// The value has to be read off the format description the renderer enqueues, not recomputed from
/// the SAR policy. `SoftwareVideoDecoder` resolves the ratio per frame (frame -> codec ctx ->
/// stream, #177) and drops one whose display aspect is impossible (#290), so a second computation
/// of the same answer is a second thing that can disagree with the screen.
@Suite("Settled software display size (#353)")
@MainActor
struct Issue353SoftwareDisplaySizeTests {

    private final class SizeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CGSize] = []

        var values: [CGSize] {
            lock.lock(); defer { lock.unlock() }; return storage
        }

        func append(_ value: CGSize) {
            lock.lock(); storage.append(value); lock.unlock()
        }
    }

    private func makeBuffer(width: Int = 720, height: Int = 576, par: (Int, Int)?) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary,
            &pb
        )
        let buffer = pb!
        if let par {
            let aspect: NSDictionary = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: par.0,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: par.1,
            ]
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        }
        return buffer
    }

    private func pts(_ frame: Int64) -> CMTime {
        CMTime(value: frame * 3600, timescale: 90000)
    }

    // MARK: - The settled value

    @Test("no size is claimed before the first frame is built")
    func nothingSettledBeforeTheFirstFrame() {
        #expect(SampleBufferRenderer().displaySize == nil)
    }

    @Test("square pixels settle at the coded dimensions")
    func squarePixelsSettleAtCodedDimensions() throws {
        let renderer = SampleBufferRenderer()

        _ = try #require(renderer.createSampleBuffer(from: makeBuffer(par: nil), pts: pts(0)))

        #expect(renderer.displaySize == CGSize(width: 720, height: 576))
    }

    /// The case the whole issue is about: 720x576 at 64:45 is PAL 16:9. A host laying out against
    /// the coded frame draws into a 5:4 rect inside a 16:9 picture.
    @Test("an anamorphic PAR settles at the width the picture actually has")
    func anamorphicPARSettlesAtTheDisplayWidth() throws {
        let renderer = SampleBufferRenderer()

        _ = try #require(renderer.createSampleBuffer(from: makeBuffer(par: (64, 45)), pts: pts(0)))

        #expect(renderer.displaySize == CGSize(width: 1024, height: 576))
    }

    // MARK: - When it is reported

    @Test("the settled size is reported once, not once per frame")
    func reportedOnChangeNotPerFrame() throws {
        let renderer = SampleBufferRenderer()
        let collector = SizeCollector()
        renderer.setDisplaySizeObserver { collector.append($0) }

        for frame in 0..<5 {
            _ = try #require(renderer.createSampleBuffer(
                from: makeBuffer(par: (64, 45)), pts: pts(Int64(frame))))
        }

        #expect(collector.values == [CGSize(width: 1024, height: 576)])
    }

    /// A mid-stream PAR change at identical geometry is exactly what the format cache invalidates
    /// on (#177), and it is the one moment the picture changes shape under a host.
    @Test("a PAR change at identical geometry reports the new size")
    func parChangeReportsTheNewSize() throws {
        let renderer = SampleBufferRenderer()
        let collector = SizeCollector()
        renderer.setDisplaySizeObserver { collector.append($0) }

        _ = try #require(renderer.createSampleBuffer(from: makeBuffer(par: nil), pts: pts(0)))
        _ = try #require(renderer.createSampleBuffer(from: makeBuffer(par: (64, 45)), pts: pts(1)))

        #expect(collector.values == [
            CGSize(width: 720, height: 576),
            CGSize(width: 1024, height: 576),
        ])
        #expect(renderer.displaySize == CGSize(width: 1024, height: 576))
    }

    /// A seek flushes the format-description cache, so the next frame rebuilds a description that
    /// describes the same picture. Reporting that as a change would have every seek re-lay-out an
    /// overlay that never moved.
    @Test("a format rebuild after a flush reports nothing new")
    func flushRebuildIsNotAChange() throws {
        let renderer = SampleBufferRenderer()
        let collector = SizeCollector()
        renderer.setDisplaySizeObserver { collector.append($0) }

        _ = try #require(renderer.createSampleBuffer(from: makeBuffer(par: (64, 45)), pts: pts(0)))
        renderer.flush(removingDisplayedImage: false)
        _ = try #require(renderer.createSampleBuffer(from: makeBuffer(par: (64, 45)), pts: pts(1)))

        #expect(collector.values == [CGSize(width: 1024, height: 576)])
        #expect(renderer.displaySize == CGSize(width: 1024, height: 576))
    }

    /// An observer installed after the picture settled still has to learn the size it missed:
    /// nothing else will change until the format does, which on most sources is never.
    @Test("an observer installed after the fact is told the settled size")
    func lateObserverIsToldTheSettledSize() throws {
        let renderer = SampleBufferRenderer()
        _ = try #require(renderer.createSampleBuffer(from: makeBuffer(par: (64, 45)), pts: pts(0)))

        let collector = SizeCollector()
        renderer.setDisplaySizeObserver { collector.append($0) }

        #expect(collector.values == [CGSize(width: 1024, height: 576)])
    }

    // MARK: - The engine's public mirror

    /// Stands in for the software host's `@Published private(set) var videoDisplaySize`.
    @MainActor
    private final class HostDouble {
        @Published var videoDisplaySize: CGSize?
        init(_ initial: CGSize?) { videoDisplaySize = initial }
    }

    @MainActor
    @Test("the settled size reaches the engine's published mirror")
    func settledSizeReachesTheEngine() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(nil)
        engine.mirrorSoftwareDisplaySize(from: host.$videoDisplaySize, storeIn: &cancellables)

        #expect(engine.softwareDisplaySize == nil)

        host.videoDisplaySize = CGSize(width: 1024, height: 576)
        #expect(engine.softwareDisplaySize == CGSize(width: 1024, height: 576))
    }

    /// Mirrored rather than latched, unlike the first-frame flag of #315. The software path builds a
    /// new host per load, so a new session's mirror replays nil and the previous picture cannot be
    /// inherited; a latch here would hand the next source the last one's rectangle.
    @MainActor
    @Test("a fresh session's mirror does not inherit the previous session's picture")
    func freshSessionStartsWithNoSize() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let outgoing = HostDouble(nil)
        engine.mirrorSoftwareDisplaySize(from: outgoing.$videoDisplaySize, storeIn: &cancellables)
        outgoing.videoDisplaySize = CGSize(width: 1024, height: 576)

        let incoming = HostDouble(nil)
        engine.mirrorSoftwareDisplaySize(from: incoming.$videoDisplaySize, storeIn: &cancellables)

        #expect(engine.softwareDisplaySize == nil)
    }

    @MainActor
    @Test("a session teardown clears the size with the session")
    func teardownClearsTheSize() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(nil)
        engine.mirrorSoftwareDisplaySize(from: host.$videoDisplaySize, storeIn: &cancellables)
        host.videoDisplaySize = CGSize(width: 1024, height: 576)

        engine.stopInternal()

        #expect(engine.softwareDisplaySize == nil,
                "an overlay must not lay out the next source against this one's picture")
    }
}
