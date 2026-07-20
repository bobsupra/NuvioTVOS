import Testing
@testable import AetherEngine

@Suite("Audio-only routing decision")
struct AudioOnlyRoutingTests {

    @Test("Explicit audioOnly forces the audio path even with a video stream")
    func explicitFlagForcesAudio() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, probeOpened: true, hasVideoStream: true) == true)
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, probeOpened: true, hasVideoStream: false) == true)
    }

    @Test("Explicit audioOnly forces the audio path even when the probe failed")
    func explicitFlagForcesAudioOnProbeFailure() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, probeOpened: false, hasVideoStream: false) == true)
    }

    @Test("A successful probe that genuinely found no video routes to the audio path")
    func probedNoVideoRoutesAudio() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, probeOpened: true, hasVideoStream: false) == true)
    }

    @Test("Video stream without the flag stays on the video path")
    func videoStaysVideo() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, probeOpened: true, hasVideoStream: true) == false)
    }

    @Test("A failed probe is not treated as audio-only; falls through to the video path (#78)")
    func failedProbeDoesNotForceAudio() {
        // probeOpened == false means we never looked. Conflating that with "no video" silently degrades a
        // real video file to audio-only (a transient 429 on a 4K HEVC VOD). The caller must fall through to
        // the native path so HLSVideoEngine reopens and discovers the stream.
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, probeOpened: false, hasVideoStream: false) == false)
    }
}
