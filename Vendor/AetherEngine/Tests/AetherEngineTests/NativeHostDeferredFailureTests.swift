import Testing
@testable import AetherEngine

/// Covers the shared deferred-failure resolution that decides, after the 5s confirm window,
/// whether an AVPlayer trouble signal is a genuine terminal failure or a self-healing transient.
///
/// Both `item.status == .failed` and (new) `failedToPlayToEndTime` on the lean remote-HLS live
/// path feed this decision. The reported bug (Reddit, live IPTV m3u8): segments started 404ing
/// after the initial buffer, AVPlayer fired `failedToPlayToEndTime` and parked at rate 0 with the
/// clock frozen, but `item.status` stayed `readyToPlay`, so the host never surfaced `.error` and
/// the player silently froze. This decision is the gate that must say "surface" for that case.
///
/// The notification -> handler WIRING needs a real stalling stream and is device/path-verified, not
/// unit-tested here (the whole NativeAVPlayerHost is AVPlayer-bound). This locks the recovery contract
/// the wiring depends on, so the change cannot start false-positiving on streams that recover.
@Suite("NativeAVPlayerHost deferred-failure resolution")
struct NativeHostDeferredFailureTests {

    @Test("Surfaces when the player stopped and the clock stayed frozen (reported live-IPTV death)")
    func surfacesWhenStoppedAndFrozen() {
        #expect(NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: false, clockAtFailure: 30.0, clockNow: 30.0))
    }

    @Test("Clears when the player resumed playing (self-healing transient)")
    func clearsWhenPlaying() {
        #expect(!NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: true, clockAtFailure: 30.0, clockNow: 30.0))
    }

    @Test("Clears when the clock advanced past the threshold (playback recovered)")
    func clearsWhenClockAdvanced() {
        #expect(!NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: false, clockAtFailure: 30.0, clockNow: 31.0))
    }

    @Test("Surfaces when the clock crept under the threshold (not real progress)")
    func surfacesWhenSubThresholdCreep() {
        #expect(NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: false, clockAtFailure: 30.0, clockNow: 30.4))
    }
}
