import Testing
import Foundation
@testable import AetherEngine

/// Sodalite#104 round 3: a software live seek lands the rebuffer lead behind the frontier.
///
/// The software path plays out of a ring the reader fills at the rate the source delivers, so a
/// landing AT the frontier has nothing ahead of it: the pump finds the ring dry, the clock parks, and
/// it resumes once `rebufferResumeLeadSeconds` of audio stands ahead of it. On a real-time source
/// that lead arrives exactly as slowly as it is deep, so the session resumes that far behind the
/// frontier after a frozen picture of the same length. Measured from a device on a tuner:
/// `lead=0.13s` to `lead=2.05s` in 1.92 s, on every Return to Live, while a rewind into content the
/// ring already held reached its first frame in 223 to 258 ms.
@Suite("A software live landing keeps the rebuffer lead ahead of it (Sodalite#104)")
struct Sodalite104SoftwareLiveLandingTests {

    private let lead = AudioLookaheadPolicy.rebufferResumeLeadSeconds

    private func window(edge: Double, depth: Double = 120) -> LiveWindow {
        var w = LiveWindow(windowSeconds: depth)
        w.noteEdge(edge)
        w.notePlayhead(edge)
        return w
    }

    @Test("Return to Live lands the lead behind the frontier")
    func edgeLandingIsHeldBack() {
        let w = window(edge: 600)
        #expect(AetherEngine.softwareLiveLanding(requested: w.edgeTime, window: w) == 600 - lead)
    }

    @Test("a target nearer the frontier than the lead is held back to it")
    func nearEdgeTargetIsHeldBack() {
        let w = window(edge: 600)
        #expect(AetherEngine.softwareLiveLanding(requested: 599.5, window: w) == 600 - lead)
    }

    @Test("a target the ring already holds a lead for is untouched")
    func rewindIsUntouched() {
        let w = window(edge: 600)
        #expect(AetherEngine.softwareLiveLanding(requested: 540, window: w) == 540)
        #expect(AetherEngine.softwareLiveLanding(requested: 600 - lead, window: w) == 600 - lead)
    }

    @Test("a window shallower than the lead lands on its floor, never past the edge")
    func shallowWindowLandsOnItsFloor() {
        let w = window(edge: 1.2)
        let landing = AetherEngine.softwareLiveLanding(requested: 1.2, window: w)
        #expect(landing == 0)
        #expect(landing <= w.edgeTime)
    }

    @Test("a target below the window is still clamped into it")
    func belowWindowIsClamped() {
        let w = window(edge: 600, depth: 120)
        #expect(AetherEngine.softwareLiveLanding(requested: 100, window: w) == 480)
    }

    /// The landing is a place the verdict has to call live at the first publish, before the session
    /// has taught the tolerance anything: otherwise Return to Live would land with the chip still in
    /// the row. That holds only while the lead fits inside the tolerance's own constant.
    @Test("the held-back landing is at the edge before any cadence is measured")
    func landingIsAtEdgeWithoutSamples() {
        var w = window(edge: 600)
        w.notePlayhead(AetherEngine.softwareLiveLanding(requested: w.edgeTime, window: w))
        #expect(w.trackingCadenceSeconds == nil)
        #expect(w.isWithinEdgeTolerance)
        #expect(lead <= LiveWindow.edgeTolerance)
    }
}
