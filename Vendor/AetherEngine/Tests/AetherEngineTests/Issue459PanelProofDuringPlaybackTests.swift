import Testing
@testable import AetherEngine

// AE#459 (DrHurt, Apple TV 4K 2022, tvOS 27 beta): an Apple TV whose output format is fixed to HDR
// labels every HDR10+/DV session "HDR -> SDR" in Stats for Nerds, and has done for months.
//
// `currentPanelIsHDR()` answers from `UIScreen.currentEDRHeadroom`, and on tvOS that value is a
// TRANSITION artifact: it is raised around a dynamic-range switch and decays back to 1.00 while the
// panel keeps presenting HDR (see DisplayCriteriaPanelHDRProofTests for the device trace). A panel
// parked in HDR never transitions, so both terms of `panelPresentsHDR` are dead for it: the live
// reading is 1.00 at every load-time sample, and `panelProvenToEngageHDR` is only ever armed by such
// a sample, so the proof can never be earned either. The session is labelled SDR and, because the
// same boolean is the master-vs-media routing gate, served media-direct.
//
// The signal exists, it is just read three seconds too early. Vincent's device measurement of
// 2026-08-09 (Apple TV 4K 3rd gen, tvOS 26.5, HDR10 panel, one title played twice):
//
//     output 4K HDR, t+2.5s:  headroom 1.20
//     output 4K HDR, t+20s:   headroom 1.00
//     output 4K SDR, t+2.5s:  headroom 1.00
//
// The rise comes with the HDR content reaching the screen, not with an HDMI mode switch, and it
// separates the two configurations that `eligibleForHDRPlayback` conflates (a panel parked in HDR
// from a rate-only panel parked in SDR). So the answer has to be sampled again once frames are
// running, which is what this suite covers.
@Suite("AE#459 panel-HDR proof during playback")
struct Issue459PanelProofDuringPlaybackTests {

    // MARK: - Which sessions get a late probe

    @Test("An HDR session the panel read SDR is the one to re-ask")
    func probesTheClampedHDRSession() {
        #expect(DisplayCriteriaController.shouldProbePanelDuringPlayback(
            effectiveFormat: .hdr10, panelPresentedHDRAtLoad: false, sessionIsPlaying: true))
    }

    @Test("A session the load-time read already answered HDR is not re-asked")
    func skipsAnsweredSession() {
        #expect(!DisplayCriteriaController.shouldProbePanelDuringPlayback(
            effectiveFormat: .hdr10, panelPresentedHDRAtLoad: true, sessionIsPlaying: true))
    }

    // SDR content composites no HDR, so the headroom cannot rise for it and there is nothing to
    // upgrade the label to. Sampling would burn a task on every SDR playback for a certain 1.00.
    @Test("An SDR session is never probed")
    func skipsSDRSession() {
        #expect(!DisplayCriteriaController.shouldProbePanelDuringPlayback(
            effectiveFormat: .sdr, panelPresentedHDRAtLoad: false, sessionIsPlaying: true))
    }

    @Test("Dolby Vision and HLG sessions are probed like HDR10")
    func probesEveryHDRFlavor() {
        #expect(DisplayCriteriaController.shouldProbePanelDuringPlayback(
            effectiveFormat: .dolbyVision, panelPresentedHDRAtLoad: false, sessionIsPlaying: true))
        #expect(DisplayCriteriaController.shouldProbePanelDuringPlayback(
            effectiveFormat: .hlg, panelPresentedHDRAtLoad: false, sessionIsPlaying: true))
    }

    // #124: a paused mount renders no frames, so nothing composites HDR and the window would close on a
    // reading that says nothing about the panel. Worse, it would say it in the voice of a measurement.
    @Test("A paused mount is not probed")
    func skipsPausedMount() {
        #expect(!DisplayCriteriaController.shouldProbePanelDuringPlayback(
            effectiveFormat: .hdr10, panelPresentedHDRAtLoad: false, sessionIsPlaying: false))
    }

    // MARK: - How long the probe runs

    @Test("The probe stops on the first HDR reading")
    func stopsOnFirstReading() {
        #expect(!DisplayCriteriaController.playbackProbeContinues(elapsedMs: 500, observedHDR: true))
    }

    @Test("The probe keeps sampling while the panel still reads SDR")
    func continuesWhileSDR() {
        #expect(DisplayCriteriaController.playbackProbeContinues(elapsedMs: 500, observedHDR: false))
    }

    // The reading decays, so an unbounded probe would sample a value that can no longer answer
    // anything. It is also the diagnostic: a window that closes with no reading is the measurement
    // that says this panel does not raise the headroom at all.
    @Test("The probe is bounded and stops at the end of its window")
    func stopsAtWindowEnd() {
        #expect(!DisplayCriteriaController.playbackProbeContinues(
            elapsedMs: DisplayCriteriaController.playbackProbeWindowMs, observedHDR: false))
    }

    // The device trace puts the rise at t+2.5s and the decay at t+20s, so the window has to open
    // wide enough to contain the rise and close before the value stops meaning anything.
    @Test("The probe window contains the measured rise and closes before the measured decay")
    func windowSpansTheMeasuredRise() {
        #expect(DisplayCriteriaController.playbackProbeWindowMs > 2_500)
        #expect(DisplayCriteriaController.playbackProbeWindowMs < 20_000)
    }

    // MARK: - What the late proof publishes

    @Test("A panel that answers HDR publishes the effective format, not SDR")
    func lateProofPublishesTheEffectiveFormat() {
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .hdr10, panelPresentsHDR: true, sourceCarriesHDR10Plus: false) == .hdr10)
    }

    @Test("A panel that stays SDR keeps the clamped label")
    func unprovenPanelKeepsSDR() {
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .hdr10, panelPresentsHDR: false, sourceCarriesHDR10Plus: false) == .sdr)
    }

    // SDR content on any panel is SDR content; the panel's mode does not upgrade it.
    @Test("An SDR source stays SDR on a panel presenting HDR")
    func sdrSourceStaysSDR() {
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .sdr, panelPresentsHDR: true, sourceCarriesHDR10Plus: false) == .sdr)
    }

    // T.35 detection fires early in the session, while the label is still clamped to SDR, and
    // `handleHDR10PlusDetected` only upgrades a `videoFormat` that already reads `.hdr10`. So by the
    // time the late proof lands, the HDR10+ evidence lives in `sourceVideoFormat` alone, and
    // republishing the bare effective format would relabel a proven HDR10+ session "HDR10+ -> HDR10".
    @Test("An HDR10+ source that was clamped past its T.35 upgrade is republished as HDR10+")
    func lateProofCarriesTheHDR10PlusUpgrade() {
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .hdr10, panelPresentsHDR: true, sourceCarriesHDR10Plus: true)
            == .hdr10Plus)
    }

    // The dynamic metadata rides on an HDR10 base layer; it says nothing about a DV or HLG session.
    @Test("The HDR10+ carry-over applies only to an HDR10 base")
    func hdr10PlusCarryOverIsScopedToHDR10() {
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .dolbyVision, panelPresentsHDR: true, sourceCarriesHDR10Plus: true)
            == .dolbyVision)
    }
}
