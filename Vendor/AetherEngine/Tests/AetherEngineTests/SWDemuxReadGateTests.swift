import Testing
@testable import AetherEngine

/// `SoftwarePlaybackHost.shouldHoldDemuxRead`: when the combined SW demux loop stops pulling
/// packets so the renderer can drain the parked video FIFO. The lead is the pacing rule and the
/// packet cap is only a memory backstop - pacing on the cap alone makes the effective audio lead
/// a function of frame rate (256 packets is ~10 s at 25 fps and ~5 s at 50 fps).
@Suite("SW demux read gate")
struct SWDemuxReadGateTests {

    private let cap = 256

    @Test("audio at its target lead holds the read")
    func holdsAtTargetLead() {
        let clock = 100.0
        let atTarget = clock + AudioLookaheadPolicy.targetLeadSeconds
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: atTarget, clockSeconds: clock) == true)
    }

    @Test("audio below its target lead keeps reading, however deep the FIFO is under the cap")
    func readsBelowTargetLead() {
        let clock = 100.0
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 200, parkedCap: cap, clockArmed: true,
            lastAudioPts: clock + 1.0, clockSeconds: clock) == false)
    }

    @Test("the packet cap holds the read on its own")
    func capIsTheBackstop() {
        let clock = 100.0
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: cap, parkedCap: cap, clockArmed: true,
            lastAudioPts: clock + 0.1, clockSeconds: clock) == true)
    }

    /// #337: before the clock is armed the lead is meaningless and the loop is the only reader.
    /// Holding here parks forever - the clock waits for an audio buffer that only a further read
    /// can produce. Only the cap may hold, and the parked-video arming exit runs at that point.
    @Test("an unarmed clock never holds on the lead, only on the cap")
    func unarmedClockKeepsReading() {
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 10, parkedCap: cap, clockArmed: false,
            lastAudioPts: 1_000, clockSeconds: 0) == false)
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: cap, parkedCap: cap, clockArmed: false,
            lastAudioPts: 1_000, clockSeconds: 0) == true)
    }

    @Test("no audio enqueued yet and an unreadable clock both keep reading")
    func nonFiniteInputsKeepReading() {
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: .nan, clockSeconds: 100) == false)
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: 104, clockSeconds: .nan) == false)
    }
}
