import Testing
@testable import AetherEngine

@Suite("PausedFirstFrame (Sodalite#104 round 4: a pause before the first frame still presents it)")
struct Sodalite104PausedFirstFrameTests {

    @Test("a pause before the first frame keeps the loops running, one after it parks them")
    func holdsOnlyBeforeTheFirstFrame() {
        #expect(PausedFirstFrame.holdsForFirstFrame(loopsStarted: true, framesEnqueued: 0))
        #expect(!PausedFirstFrame.holdsForFirstFrame(loopsStarted: true, framesEnqueued: 1))
        #expect(!PausedFirstFrame.holdsForFirstFrame(loopsStarted: false, framesEnqueued: 0))
    }

    @Test("the loops run while playing or while waiting for the first frame, and park otherwise")
    func loopsMayRun() {
        #expect(PausedFirstFrame.loopsMayRun(isPlaying: true, pausedBeforeFirstFrame: false))
        #expect(PausedFirstFrame.loopsMayRun(isPlaying: false, pausedBeforeFirstFrame: true))
        #expect(!PausedFirstFrame.loopsMayRun(isPlaying: false, pausedBeforeFirstFrame: false))
    }

    @Test("a clock arming under that pause starts stopped, otherwise at the last speed")
    func armingRate() {
        #expect(PausedFirstFrame.armingRate(lastRate: 1.5, pausedBeforeFirstFrame: true) == 0)
        #expect(PausedFirstFrame.armingRate(lastRate: 1.5, pausedBeforeFirstFrame: false) == 1.5)
    }

    @Test("an arm that raced a pause() is stopped, one that raced a play() is started, one that did not is left")
    func rateCorrectionAtArm() {
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: false, pausedBeforeFirstFrame: false, synchronizerRate: 1, lastRate: 1) == 0)
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: true, pausedBeforeFirstFrame: false, synchronizerRate: 0, lastRate: 1.25) == 1.25)
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: true, pausedBeforeFirstFrame: false, synchronizerRate: 1.25, lastRate: 1.25) == nil)
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: false, pausedBeforeFirstFrame: true, synchronizerRate: 0, lastRate: 1) == nil)
    }

    @Test("the reporter's tune: armed on audio ahead of the keyframe, the stopped clock moves onto the frame")
    func anchorsAClockStandingBeforeTheFrame() {
        #expect(PausedFirstFrame.presentationAnchor(
            framePTS: 26116.9, clockArmed: true, clockSeconds: 26115.74) == 26116.9)
    }

    @Test("a clock already at or past the frame presents it where it stands")
    func leavesAClockAtOrPastTheFrame() {
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: true, clockSeconds: 10) == nil)
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: true, clockSeconds: 12) == nil)
    }

    @Test("an unarmed or unreadable clock is left to the loop that arms it")
    func leavesAnUnarmedClock() {
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: false, clockSeconds: 0) == nil)
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: true, clockSeconds: .nan) == nil)
        #expect(PausedFirstFrame.presentationAnchor(framePTS: .nan, clockArmed: true, clockSeconds: 0) == nil)
    }
}
