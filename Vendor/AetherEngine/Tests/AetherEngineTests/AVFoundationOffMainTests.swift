import Foundation
import Testing
import AVFoundation
@testable import AetherEngine

/// #134: shared hop that runs batched synchronous AVFoundation property reads on a
/// caller-owned serial queue instead of the main actor.
@MainActor
struct AVFoundationOffMainTests {

    @Test("body runs off the main thread and the value round-trips")
    func bodyRunsOffMain() async {
        let queue = DispatchQueue(label: "test.avfread")
        let player = AVPlayer()
        let wasOffMain = await AVFoundationOffMain.read(player, on: queue) { player -> Bool in
            _ = player.rate
            return !Thread.isMainThread
        }
        #expect(wasOffMain)
    }

    @Test("a blocked body must not block the main actor", .timeLimit(.minutes(3)))
    func blockedBodyKeepsMainActorResponsive() async {
        let queue = DispatchQueue(label: "test.avfread.stall")
        let release = DispatchSemaphore(value: 0)
        let player = AVPlayer()
        let finished = AtomicBool(false)
        // Barrier, not a measurement: the body may only end at the signal below, which the main
        // actor can only send if this read left it free. A wall-clock cap here would release the
        // body on its own under CI starvation and answer the question the test is asking (see
        // Issue254OffMainRepositionTests); a genuinely blocked main actor never signals at any size,
        // so the honest report of that regression is the trait's time limit. The defer covers an
        // early exit.
        defer { release.signal() }
        let read = Task { @MainActor in
            _ = await AVFoundationOffMain.read(player, on: queue) { _ -> Bool in
                release.wait()
                return true
            }
            finished.set(true)
        }
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(finished.get() == false)

        release.signal()
        await read.value
        #expect(finished.get())
    }
}

/// #134 follow-up: seekable-end mapping used by the host's KVO mirror of
/// `seekableTimeRanges`, replacing per-call synchronous reads at clock-tick cadence.
struct NativeAVPlayerHostSeekableEndTests {

    @Test("empty ranges map to 0")
    func emptyRanges() {
        #expect(NativeAVPlayerHost.seekableEnd(from: []) == 0)
    }

    @Test("end of the last range wins")
    func lastRangeEnd() {
        let ranges = [
            NSValue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))),
            NSValue(timeRange: CMTimeRange(start: CMTime(value: 20, timescale: 1),
                                           duration: CMTime(value: 15, timescale: 1))),
        ]
        #expect(NativeAVPlayerHost.seekableEnd(from: ranges) == 35)
    }

    @Test("non-finite end maps to 0")
    func nonFiniteEnd() {
        let ranges = [NSValue(timeRange: CMTimeRange(start: .zero, duration: .indefinite))]
        #expect(NativeAVPlayerHost.seekableEnd(from: ranges) == 0)
    }
}
