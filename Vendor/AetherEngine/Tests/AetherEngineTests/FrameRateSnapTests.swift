import Testing
@testable import AetherEngine

@Suite("FrameRateSnap")
struct FrameRateSnapTests {

    @Test("Standard rates pass through unchanged")
    func standardRatesIdentity() {
        #expect(FrameRateSnap.snap(25) == 25)
        #expect(FrameRateSnap.snap(29.97) == 29.97)
        #expect(FrameRateSnap.snap(30) == 30)
        #expect(FrameRateSnap.snap(50) == 50)
        #expect(FrameRateSnap.snap(59.94) == 59.94)
        #expect(FrameRateSnap.snap(60) == 60)
        #expect(FrameRateSnap.snap(48) == 48)
    }

    @Test("Film cadence window: 23.5...24.05 → 23.976, except an exact 24.000")
    func filmCadencePrefers23976() {
        #expect(FrameRateSnap.snap(24000.0 / 1001.0) == 23.976)
        #expect(FrameRateSnap.snap(23.976) == 23.976)
        #expect(FrameRateSnap.snap(23.97) == 23.976)
        #expect(FrameRateSnap.snap(23.98) == 23.976)
        #expect(FrameRateSnap.snap(23.5) == 23.976)
        #expect(FrameRateSnap.snap(23.99) == 23.976)
        #expect(FrameRateSnap.snap(24.01) == 23.976)
        #expect(FrameRateSnap.snap(24.05) == 23.976)
    }

    @Test("AE#884: a 24.000 fps probe is programmed as 24 Hz")
    func exact24GoesTo24() {
        #expect(FrameRateSnap.snap(24) == 24)
        #expect(FrameRateSnap.snap(24.004) == 24)
        #expect(FrameRateSnap.snap(23.996) == 24)
        // Above the film window the nearest match still picks 24, as before.
        #expect(FrameRateSnap.snap(24.3) == 24)
    }

    @Test("Nearby probes snap to standard within ±0.5")
    func nearestMatchWithinTolerance() {
        #expect(FrameRateSnap.snap(24.99) == 25)
        #expect(FrameRateSnap.snap(25.4) == 25)
        #expect(FrameRateSnap.snap(29.5) == 29.97)
        #expect(FrameRateSnap.snap(60.3) == 60)
    }

    @Test("Out-of-tolerance probes return nil")
    func outOfToleranceReturnsNil() {
        #expect(FrameRateSnap.snap(35) == nil)   // >0.5 from any standard rate
        #expect(FrameRateSnap.snap(45) == nil)   // between 30 and 48, >0.5 from each
        #expect(FrameRateSnap.snap(120) == nil)  // above all standard rates
    }

    @Test("Invalid inputs return nil")
    func invalidInputsReturnNil() {
        #expect(FrameRateSnap.snap(0) == nil)
        #expect(FrameRateSnap.snap(-1) == nil)
        #expect(FrameRateSnap.snap(-23.976) == nil)
        #expect(FrameRateSnap.snap(.nan) == nil)
        #expect(FrameRateSnap.snap(.infinity) == nil)
    }

    @Test("Standard set is the documented contract")
    func standardSetMatchesDocumentation() {
        // Locks the documented contract: changes here are intentional
        // API breaks for hosts that depend on a specific set.
        #expect(FrameRateSnap.standard == [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60])
    }
}
