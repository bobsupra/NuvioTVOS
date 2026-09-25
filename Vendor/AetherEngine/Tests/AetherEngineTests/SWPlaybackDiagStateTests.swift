import Testing
import Foundation
@testable import AetherEngine

/// AE#479: the `[SWDiag]` audio marker after a seek.
///
/// `lastAudioPts` is the newest audio the pump enqueued, written by the pump alone. A seek flushes the
/// audio queue on the main actor while the pump is still on the pre-seek generation: after a playing
/// seek the pump writes its stale local once more before it notices the generation, and a seek that
/// lands paused parks the pump in its pause wait, where it writes nothing until `play()`. Either way
/// the line printed the old PTS against the re-anchored clock (`aLead=475.49` on a backward scrub in
/// the field, `-23.89` on a forward one on the harness), for one tick or for the whole paused stretch.
@Suite("SWPlaybackDiagState")
struct SWPlaybackDiagStateTests {

    @Test("A write from before the flush cannot republish the flushed queue's PTS")
    func staleWriteIsRefusedForTheMarker() {
        let diag = SWPlaybackDiagState()
        diag.update(lastAudioPts: 16.11, parked: 95, generation: 0)
        // The seek path: bump to generation 1, flush, tell the box.
        diag.audioFlushed(generation: 1)
        #expect(diag.snapshot.lastAudioPts.isNaN)
        // The pump's one late write from the iteration that was in flight when the seek arrived.
        diag.update(lastAudioPts: 16.11, parked: 95, generation: 0)
        #expect(diag.snapshot.lastAudioPts.isNaN)
    }

    @Test("parked and rebuffering are the pump's own state and land regardless of generation")
    func pumpStateStaysUnconditional() {
        let diag = SWPlaybackDiagState()
        diag.audioFlushed(generation: 3)
        diag.setRebuffering(true)
        diag.update(lastAudioPts: 16.11, parked: 42, generation: 1)
        let s = diag.snapshot
        #expect(s.lastAudioPts.isNaN)
        #expect(s.parked == 42)
        #expect(s.rebuffering)
    }

    @Test("The first write on the post-seek generation publishes the fresh marker")
    func freshWriteLands() {
        let diag = SWPlaybackDiagState()
        diag.update(lastAudioPts: 16.11, parked: 95, generation: 0)
        diag.audioFlushed(generation: 1)
        diag.update(lastAudioPts: 44.01, parked: 12, generation: 1)
        #expect(diag.snapshot.lastAudioPts == 44.01)
    }

    @Test("A superseded seek's flush cannot undo the newer one")
    func olderFlushDoesNotRegress() {
        let diag = SWPlaybackDiagState()
        diag.audioFlushed(generation: 2)
        diag.update(lastAudioPts: 44.01, parked: 12, generation: 2)
        // A seek from generation 1 finishing its main-actor prologue late.
        diag.audioFlushed(generation: 1)
        #expect(diag.snapshot.lastAudioPts == 44.01)
    }

    @Test("A pump that started on a later generation than the box writes normally")
    func pumpAheadOfBoxWrites() {
        // A host seeks before its pump is up: the pump captures the current generation on entry and
        // must not be refused by a box that has never seen a flush.
        let diag = SWPlaybackDiagState()
        diag.update(lastAudioPts: 4.0, parked: 1, generation: 7)
        #expect(diag.snapshot.lastAudioPts == 4.0)
    }

    @Test("a seek resets progress and a stale frame cannot release the new generation's hold")
    func progressIsGenerationGated() {
        let diag = SWPlaybackDiagState()
        diag.noteVideoFrame(generation: 0)
        let beforeSeek = diag.snapshot.videoFrameGeneration
        diag.setRebuffering(true, generation: 0)

        diag.audioFlushed(generation: 1)
        let afterSeek = diag.snapshot
        #expect(!afterSeek.rebuffering)
        #expect(afterSeek.rebufferVideoFrameGeneration == beforeSeek)

        diag.noteVideoFrame(generation: 0)
        #expect(diag.snapshot.videoFrameGeneration == beforeSeek)
        diag.noteVideoFrame(generation: 1)
        #expect(diag.snapshot.videoFrameGeneration == beforeSeek + 1)
    }
}

@Suite("SW software clock starvation")
struct SWSoftwareClockStarvationPolicyTests {

    @Test("short gaps keep realtime-paced media running, sustained silence parks the clock")
    func sustainedSilenceHolds() {
        #expect(Self.action(now: 5.74, lastProgress: 5.0) == .none)
        #expect(Self.action(now: 5.75, lastProgress: 5.0) == .pauseForRebuffer)
        #expect(Self.action(now: 10.0, lastProgress: 1.0, audioLead: 0.2) == .none)
        #expect(Self.action(now: 10.0, lastProgress: 1.0, audioLead: 4.0) == .none)
    }

    @Test("a recovered audio lead or fresh decoded frame releases the hold")
    func usablePostHoldMediaResumes() {
        #expect(Self.action(rebuffering: true, audioLead: 2.0) == .resume)
        #expect(Self.action(rebuffering: true, videoFrameGeneration: 8,
                            rebufferVideoFrameGeneration: 7) == .resume)
    }

    @Test("video-only sessions are excluded from this queue-drain hold")
    func nonDecoupledPathsAreExcluded() {
        #expect(Self.action(hasAudio: false, now: 10.0, lastProgress: 1.0) == .none)
        #expect(Self.action(hasAudio: false, rebuffering: true,
                            videoFrameGeneration: 8, rebufferVideoFrameGeneration: 7,
                            audioLead: .nan) == .none)
    }

    @Test("pause, seek, unarmed clock, and EOF cannot trigger a resume or new hold")
    func lifecycleGates() {
        #expect(Self.action(isPlaying: false, rebuffering: true, audioLead: 4.0) == .none)
        #expect(Self.action(seekInFlight: true, now: 9.0, lastProgress: 1.0) == .none)
        #expect(Self.action(clockArmed: false, now: 9.0, lastProgress: 1.0) == .none)
        #expect(Self.action(sourceExhausted: true, now: 9.0, lastProgress: 1.0) == .none)
    }

    @Test("play clears explicit pause intent without restarting an active rebuffer hold")
    func playPreservesStarvationHold() {
        let held = SWPlaybackHostResumePolicy.decision(
            hostPaused: true, clockArmed: true, synchronizerRate: 0,
            rebuffering: true, parkedAtEndOfMedia: false)
        #expect(held.clockAction == .none)
        #expect(held.clearHostPause)

        let recovered = SWPlaybackHostResumePolicy.decision(
            hostPaused: true, clockArmed: true, synchronizerRate: 0,
            rebuffering: false, parkedAtEndOfMedia: false)
        #expect(recovered.clockAction == .resumeHostPause)
        #expect(!recovered.clearHostPause)
    }

    private static func action(
        clockArmed: Bool = true,
        isPlaying: Bool = true,
        seekInFlight: Bool = false,
        sourceExhausted: Bool = false,
        hasAudio: Bool = true,
        rebuffering: Bool = false,
        now: Double = 10.0,
        lastProgress: Double = 9.0,
        videoFrameGeneration: UInt64 = 7,
        rebufferVideoFrameGeneration: UInt64 = 7,
        audioLead: Double = 0.0
    ) -> AudioLookaheadPolicy.ClockAction {
        SWSoftwareClockStarvationPolicy.action(
            clockArmed: clockArmed,
            isPlaying: isPlaying,
            seekInFlight: seekInFlight,
            sourceExhausted: sourceExhausted,
            hasAudio: hasAudio,
            rebuffering: rebuffering,
            now: now,
            lastMediaProgressAt: lastProgress,
            videoFrameGeneration: videoFrameGeneration,
            rebufferVideoFrameGeneration: rebufferVideoFrameGeneration,
            audioLead: audioLead
        )
    }
}
