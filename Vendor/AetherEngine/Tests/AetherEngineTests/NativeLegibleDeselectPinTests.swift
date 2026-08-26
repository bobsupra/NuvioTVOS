import Foundation
import Testing
@testable import AetherEngine

/// Sodalite#38 follow-up: the deselect pin on the native legible rendition used to run for the
/// first ~2 s of a session only. iOS 26's automatic captions (show when muted, show when skipping
/// back) select the rendition minutes later, and nothing held it back, so an empty system caption
/// box appeared over the frame while the host's on-frame overlay owned subtitles. The pin now
/// stays armed for the whole session, bounded only against a selection fight it cannot win.
struct NativeLegibleDeselectPinTests {

    @Test("re-asserts spaced further apart than the burst window never exhaust the pin")
    func mutingAgainMinutesLaterStillDeselects() {
        var pin = NativeLegibleDeselectPin(burstLimit: 5, burstWindow: 1.0)
        // Twenty mute toggles across an hour, each a single user action.
        for i in 0..<20 {
            #expect(pin.admit(now: Double(i) * 180.0) == true)
        }
    }

    @Test("the system re-selecting immediately after every deselect stops the pin")
    func selectionFightStandsDown() {
        var pin = NativeLegibleDeselectPin(burstLimit: 5, burstWindow: 1.0)
        for i in 0..<5 {
            #expect(pin.admit(now: Double(i) * 0.05) == true)
        }
        #expect(pin.admit(now: 0.30) == false)
        #expect(pin.admit(now: 0.35) == false)
    }

    @Test("a gap longer than the burst window is a new episode and restores the budget")
    func gapRestoresBudget() {
        var pin = NativeLegibleDeselectPin(burstLimit: 2, burstWindow: 1.0)
        #expect(pin.admit(now: 0.0) == true)
        #expect(pin.admit(now: 0.1) == true)
        #expect(pin.admit(now: 0.2) == false)
        #expect(pin.admit(now: 5.0) == true)
        #expect(pin.admit(now: 5.1) == true)
        #expect(pin.admit(now: 5.2) == false)
    }

    @Test("reset clears a spent budget")
    func resetClearsBudget() {
        var pin = NativeLegibleDeselectPin(burstLimit: 1, burstWindow: 1.0)
        #expect(pin.admit(now: 0.0) == true)
        #expect(pin.admit(now: 0.1) == false)
        pin.reset()
        #expect(pin.admit(now: 0.2) == true)
    }
}
