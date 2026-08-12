import Testing
import Combine
@testable import AetherEngine

/// #315: `hasFirstFrameReadyForDisplay`, the load-scoped statement that the running path has a
/// picture. The layer property it folds needs a real AVPlayer / AVSampleBufferDisplayLayer, so the
/// end-to-end edge is measured with `aetherctl play` (native: layer ready t+0.05 s, published
/// t+0.16 s; software: ready after 6 enqueued frames) rather than here. What is testable here is
/// the fold, and the fold is where the two ways to get this wrong live: inheriting the previous
/// item's picture, and re-lowering the flag on a seam.
@Suite("First-frame-ready latch (#315)")
struct Issue315FirstFramePresentedTests {

    /// Stands in for a playback host's `@Published private(set) var isVideoReadyForDisplay`.
    @MainActor
    final class HostDouble {
        @Published var isVideoReadyForDisplay: Bool
        init(_ initial: Bool) { isVideoReadyForDisplay = initial }
    }

    @MainActor
    @Test("A reused host's carried-in picture does not latch this load")
    func carriedInValueIsNotThisLoadsFrame() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        // A native host kept across a reload still reports the OUTGOING item as ready at the moment
        // the engine wires its sinks: host.load() (and its unloadCurrentItem) runs after the wiring.
        let host = HostDouble(true)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)

        #expect(engine.hasFirstFrameReadyForDisplay == false)

        // AVFoundation clears the layer once the swap goes through, then raises it for the new item.
        host.isVideoReadyForDisplay = false
        #expect(engine.hasFirstFrameReadyForDisplay == false)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)
    }

    @MainActor
    @Test("A fresh host's first frame latches it")
    func freshHostLatchesOnFirstRise() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(false)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)

        #expect(engine.hasFirstFrameReadyForDisplay == false)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)
    }

    @MainActor
    @Test("A seam that drops the layer's picture does not lower it")
    func latchHoldsThroughAPictureLessSeam() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(false)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)
        host.isVideoReadyForDisplay = true

        // The measured shape of an item swap on a reused host: ~40 ms of false, then true again.
        // The media fallback, the AirPlay master swap and the #93 recovery reload all call
        // host.load(inPlaceSwap:) themselves, reach no stopInternal, and a host must not re-cover a
        // picture for any of them.
        host.isVideoReadyForDisplay = false
        #expect(engine.hasFirstFrameReadyForDisplay == true)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)
    }

    @MainActor
    @Test("The AE#158 in-place handover is a load(), so it un-latches like any other")
    func inPlaceHandoverUnlatchesLikeAnyLoad() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(false)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)

        // What load() runs for a PiP next-episode handover: the outgoing item stays attached so the
        // system PiP window survives the teardown, which is what makes this seam look like the three
        // above. It is not one of them. The content is new, so its own first frame has to be reached
        // again, and holding the latch here would lift a host's cover onto the previous episode's
        // frozen frame.
        engine.stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCurrentItem: true)
        #expect(engine.hasFirstFrameReadyForDisplay == false)
    }

    /// Device measurement (iPhone -> Apple TV, 2026-08-09): four loads with external playback active, none of
    /// them ever reaching `layer.isReadyForDisplay`, against three local loads reaching it in 0.16 to 0.22 s.
    /// The layer fold alone therefore cannot carry an AirPlay session, and readiness has to.
    @Test("Readiness is the latch edge while an external screen holds the picture")
    func externalPlaybackLatchesAtReadiness() {
        func decide(video: Bool, ready: Bool, external: Bool, latched: Bool = false) -> Bool {
            AetherEngine.shouldLatchFirstFrameForExternalPlayback(
                alreadyLatched: latched,
                hasVideoDisplaySignal: video,
                isSessionReady: ready,
                externalPlaybackHoldsThePicture: external)
        }

        #expect(decide(video: true, ready: true, external: true))
        // Audio-only: no picture anywhere, and a gate waiting on this flag must keep waiting forever
        // rather than be told a frame exists on a receiver that was handed audio.
        #expect(decide(video: false, ready: true, external: true) == false)
        // Pre-ready: the receiver has not been handed a playable item yet.
        #expect(decide(video: true, ready: false, external: true) == false)
        // Local: the layer fold owns this case and reaches it a beat later than readiness.
        #expect(decide(video: true, ready: true, external: false) == false)
        // Latched: the seam rules stay the layer's, this only ever adds a rise.
        #expect(decide(video: true, ready: true, external: true, latched: true) == false)
    }

    @MainActor
    @Test("An audio-only session is not latched by an external route")
    func audioOnlySessionIgnoresExternalPlayback() async throws {
        let engine = try AetherEngine()
        engine.isSessionReady = true
        // No host wired a video display signal, which is what an audio load looks like.
        #expect(engine.sessionPublishesVideoDisplaySignal == false)

        engine.latchFirstFrameForExternalPlaybackIfNeeded()
        #expect(engine.hasFirstFrameReadyForDisplay == false)
    }

    @MainActor
    @Test("stop() un-latches it")
    func stopClearsTheLatch() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(false)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)

        engine.stop()
        // The session is gone, so no statement about a picture survives it. load() reaches the same
        // reset through the stopInternal() in its prologue.
        #expect(engine.hasFirstFrameReadyForDisplay == false)
    }
}
