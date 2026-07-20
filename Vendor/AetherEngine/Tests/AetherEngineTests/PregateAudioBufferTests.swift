import Testing
@testable import AetherEngine

// #74: at head-of-stream the producer's audio gate dropped every audio packet that arrived before the
// first video packet. On wide-interleave sources (audio muxed ~1 s ahead of video in file order) that
// discarded the whole first second of real audio, so AVPlayer pulled the survivors forward into a
// constant ~1 s desync. The fix buffers pre-gate audio (bounded) and replays it in DTS order once the
// video gate opens.
//
// #74 follow-up (VOD seek/resume): the same wide interleave breaks restart producers too. On a seek the
// demuxer lands before the video keyframe and scans forward; the matching audio (muxed ~1 s earlier in
// file order) is read while the gate is still closed and was dropped, so the post-gate restart-target
// filter snapped the next (~1 s-later) audio onto the keyframe → audio ~1 s AHEAD of picture. Fix: also
// buffer pre-gate audio on a VOD restart, so the restart-target filter selects the matching packet from
// the [target, …] window (gapMs ≈ 0). Live restart keeps the drop (its program-boundary re-anchor
// handles audio separately). These cover the buffering DECISION: head-of-stream OR VOD, while the gate
// waits, only audio, only under the byte cap; live restart never buffers.
@Suite("HLSSegmentProducer pre-gate audio buffering decision")
struct PregateAudioBufferTests {

    private let cap = 8 * 1024 * 1024

    @Test("A non-audio packet is never buffered")
    func nonAudioNotBuffered() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: false, audioWaitForVideo: true, isHeadOfStream: true, isLive: false,
            bufferedBytes: 0, packetSize: 1024, capBytes: cap) == false)
    }

    @Test("Audio is not buffered once the video gate has opened")
    func notBufferedAfterGateOpen() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: false, isHeadOfStream: true, isLive: false,
            bufferedBytes: 0, packetSize: 1024, capBytes: cap) == false)
    }

    @Test("VOD restart/seek producers now buffer pre-gate audio (the #74 follow-up)")
    func bufferedOnVODRestart() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: false, isLive: false,
            bufferedBytes: 0, packetSize: 1024, capBytes: cap) == true)
    }

    @Test("Live restart producers keep the old drop, never buffer")
    func notBufferedOnLiveRestart() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: false, isLive: true,
            bufferedBytes: 0, packetSize: 1024, capBytes: cap) == false)
    }

    @Test("Head-of-stream pre-gate audio under the cap is buffered (live and VOD)")
    func bufferedAtHeadOfStream() {
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: true, isLive: false,
            bufferedBytes: 64 * 1024, packetSize: 1024, capBytes: cap) == true)
        // Live head-of-stream still buffers (unchanged from 4.5.1).
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: true, isLive: true,
            bufferedBytes: 64 * 1024, packetSize: 1024, capBytes: cap) == true)
    }

    @Test("Buffering is allowed exactly up to the cap boundary")
    func capBoundaryInclusive() {
        // bufferedBytes + packetSize == cap: still fits.
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: true, isLive: false,
            bufferedBytes: cap - 1024, packetSize: 1024, capBytes: cap) == true)
    }

    @Test("Over the cap falls back to the old drop (not buffered)")
    func overCapNotBuffered() {
        // Applies to VOD restart too: over the cap, the original drop resumes.
        #expect(HLSSegmentProducer.shouldBufferPregateAudio(
            isAudioPkt: true, audioWaitForVideo: true, isHeadOfStream: false, isLive: false,
            bufferedBytes: cap - 1024, packetSize: 1025, capBytes: cap) == false)
    }
}
