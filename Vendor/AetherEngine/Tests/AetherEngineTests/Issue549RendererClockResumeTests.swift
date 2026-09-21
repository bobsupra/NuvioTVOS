import Testing
@testable import AetherEngine

@Suite("RendererClockResume (AE#549: play() can start a clock the host did not stop)")
struct Issue549RendererClockResumeTests {

    @Test("the reporter's session: armed, running at rate 0, nobody here paused it, so it restarts")
    func restartsTheStalledClock() {
        #expect(RendererClockResume.onPlay(
            hostPaused: false, clockArmed: true, synchronizerRate: 0,
            rebuffering: false, parkedAtEndOfMedia: false) == .restartStalledClock)
    }

    @Test("a host pause keeps its own resume, whatever else is true")
    func hostPauseWins() {
        #expect(RendererClockResume.onPlay(
            hostPaused: true, clockArmed: true, synchronizerRate: 0,
            rebuffering: false, parkedAtEndOfMedia: false) == .resumeHostPause)
        #expect(RendererClockResume.onPlay(
            hostPaused: true, clockArmed: false, synchronizerRate: 0,
            rebuffering: true, parkedAtEndOfMedia: true) == .resumeHostPause)
    }

    @Test("a running clock is left alone")
    func runningClockIsLeftAlone() {
        #expect(RendererClockResume.onPlay(
            hostPaused: false, clockArmed: true, synchronizerRate: 1,
            rebuffering: false, parkedAtEndOfMedia: false) == .none)
        #expect(RendererClockResume.onPlay(
            hostPaused: false, clockArmed: true, synchronizerRate: 1.5,
            rebuffering: false, parkedAtEndOfMedia: false) == .none)
    }

    @Test("an un-anchored clock is left to its arming sample (#107), never rate-changed")
    func unarmedClockIsLeftAlone() {
        #expect(RendererClockResume.onPlay(
            hostPaused: false, clockArmed: false, synchronizerRate: 0,
            rebuffering: false, parkedAtEndOfMedia: false) == .none)
    }

    @Test("a rebuffer owns its resume: play() during one does not outrun the lead it is waiting for")
    func rebufferKeepsItsClock() {
        #expect(RendererClockResume.onPlay(
            hostPaused: false, clockArmed: true, synchronizerRate: 0,
            rebuffering: true, parkedAtEndOfMedia: false) == .none)
    }

    @Test("an end-of-media park (AE#374) is the source running out, and play() answers that with a rewind")
    func endOfMediaParkIsNotAStall() {
        #expect(RendererClockResume.onPlay(
            hostPaused: false, clockArmed: true, synchronizerRate: 0,
            rebuffering: false, parkedAtEndOfMedia: true) == .none)
    }
}
