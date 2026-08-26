import AVFoundation
import Testing
@testable import AetherEngine

@Suite("Audio AVPlayer host rebuffer fold")
struct AudioAVPlayerHostRebufferingTests {

    @Test("A wait before the item has ever played is startup, not a rebuffer")
    func startupWaitIsNotRebuffering() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: false, status: .waitingToPlayAtSpecifiedRate, stalledSinceLastPlaying: false
        ) == false)
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: false, status: .waitingToPlayAtSpecifiedRate, stalledSinceLastPlaying: true
        ) == false)
    }

    @Test("A wait after the item has played is a rebuffer")
    func waitAfterPlayingIsRebuffering() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .waitingToPlayAtSpecifiedRate, stalledSinceLastPlaying: false
        ) == true)
    }

    @Test("Playing clears it; a stall latched since the last play holds it until then")
    func stallLatchCoversNotificationOrder() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .playing, stalledSinceLastPlaying: false
        ) == false)
        // The stall notification can precede the status flip; the latch alone reports the rebuffer.
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .playing, stalledSinceLastPlaying: true
        ) == true)
    }

    @Test("A paused player is never rebuffering, whatever it latched")
    func pausedIsNeverRebuffering() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .paused, stalledSinceLastPlaying: true
        ) == false)
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .paused, stalledSinceLastPlaying: false
        ) == false)
    }
}
