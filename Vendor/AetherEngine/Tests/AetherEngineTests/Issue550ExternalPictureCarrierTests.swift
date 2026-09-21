import Testing
@testable import AetherEngine

@Suite("AE#550 (only the native backend can hand a picture to an external screen)")
struct Issue550ExternalPictureCarrierTests {

    @Test("the native path is the only carrier: external playback is an AVPlayer feature")
    func onlyNativeCarriesThePicture() {
        #expect(AetherEngine.externalPlaybackCanCarryThePicture(backend: .native))
    }

    @Test("the software path renders into a local layer, so a route says nothing about a picture")
    func softwareCarriesNothing() {
        #expect(!AetherEngine.externalPlaybackCanCarryThePicture(backend: .software))
    }

    @Test("an audio backend and an unstarted session carry no picture either")
    func audioAndIdleCarryNothing() {
        #expect(!AetherEngine.externalPlaybackCanCarryThePicture(backend: .audio))
        #expect(!AetherEngine.externalPlaybackCanCarryThePicture(backend: .none))
    }

    @Test("the reporter's session: a software route with a receiver on it does not latch #315")
    func softwareSessionDoesNotLatchTheExternalFirstFrame() {
        // The field log latched here and announced an external screen. The picture was on the phone
        // the whole time, and the local layer it came from reports its own first frame.
        #expect(!AetherEngine.shouldLatchFirstFrameForExternalPlayback(
            alreadyLatched: false,
            hasVideoDisplaySignal: true,
            isSessionReady: true,
            externalPlaybackHoldsThePicture:
                AetherEngine.externalPlaybackCanCarryThePicture(backend: .software)))
        // Same session on the native path, where the receiver really does hold it.
        #expect(AetherEngine.shouldLatchFirstFrameForExternalPlayback(
            alreadyLatched: false,
            hasVideoDisplaySignal: true,
            isSessionReady: true,
            externalPlaybackHoldsThePicture:
                AetherEngine.externalPlaybackCanCarryThePicture(backend: .native)))
    }
}
