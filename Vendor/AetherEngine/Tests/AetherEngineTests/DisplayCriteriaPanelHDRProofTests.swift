import Testing
@testable import AetherEngine

// Device trace (Apple TV 4K, HDR10+ panel, output SDR + Match Dynamic Range, 2026-08-02): playing a
// DV P8.1 title routed correctly on the first start, and every replay that began before the TV had
// dropped back to SDR served media-direct and labelled the session SDR while the TV itself reported
// HDR. The gate is `UIScreen.currentEDRHeadroom > 1.001`, sampled once after waitForSwitch, and on
// tvOS that value is NOT a readout of the panel's HDMI mode:
//
//   22:33:59.355 [PanelProbe] headroom=1.20 switching=no      <- confirmed HDR10 session, 13 s in
//   22:33:59.615 [PanelProbe] headroom=1.00 switching=no      <- same session, still HDR on the TV
//
// It is raised around a dynamic-range TRANSITION and decays while the panel keeps presenting HDR. A
// replay onto an already-HDR panel makes no transition, so the headroom never rises and the single
// read concluded "panel is SDR". On tvOS that one boolean is the whole master-vs-media routing gate
// (`resolveUseMasterPlaylist`: builtInPanelEngagesOnDemand is false there), so the session lost its
// HDR signaling entirely.
//
// The reading is therefore only trusted as a POSITIVE. Its absence is answered by what the panel has
// already proven. This suite covers that pure DECISION.
@Suite("DisplayCriteria panel-HDR proof")
struct DisplayCriteriaPanelHDRProofTests {

    @Test("Headroom above 1.0 is authoritative on its own")
    func headroomWins() {
        #expect(DisplayCriteriaController.panelPresentsHDR(
            headroomAboveOne: true, attribution: .engineHDR, panelProvenToEngageHDR: false))
    }

    // The regression this suite exists for.
    @Test("Requested HDR on a panel proven to engage reads HDR despite the decayed headroom")
    func provenPanelSurvivesHeadroomDecay() {
        #expect(DisplayCriteriaController.panelPresentsHDR(
            headroomAboveOne: false, attribution: .engineHDR, panelProvenToEngageHDR: true))
    }

    @Test("Cold start: HDR requested but nothing proven yet keeps the conservative answer")
    func unprovenPanelStaysSDR() {
        #expect(!DisplayCriteriaController.panelPresentsHDR(
            headroomAboveOne: false, attribution: .engineHDR, panelProvenToEngageHDR: false))
    }

    // Match Frame Rate on, Match Dynamic Range off: the combined tvOS toggle reports enabled, the
    // engine writes HDR criteria, and the panel stays SDR forever. It never engages, so it never
    // proves, and a PQ master is never offered to it (-11848).
    @Test("A rate-only panel never proves and stays SDR across sessions")
    func rateOnlyPanelNeverProves() {
        #expect(!DisplayCriteriaController.panelPresentsHDR(
            headroomAboveOne: false, attribution: .engineHDR, panelProvenToEngageHDR: false))
    }

    // effectiveFormat is clamped to displayCapabilities before apply(), so an SDR write is the
    // engine's own statement that this session is not HDR. The proof must not override it.
    @Test("An SDR rate-only write reads SDR even on a proven panel")
    func rateOnlyWriteIgnoresProof() {
        #expect(!DisplayCriteriaController.panelPresentsHDR(
            headroomAboveOne: false, attribution: .engineRateOnly, panelProvenToEngageHDR: true))
    }

    // Sole-writer hosts (suppressDisplayCriteria) get their answer from the caller's pre-load
    // snapshot instead; the engine wrote nothing, so it has no request to reason from.
    @Test("A host-driven session claims nothing from the proof")
    func hostDrivenIgnoresProof() {
        #expect(!DisplayCriteriaController.panelPresentsHDR(
            headroomAboveOne: false, attribution: .hostDriven, panelProvenToEngageHDR: true))
    }

    @Test("Host-driven still honors a live headroom reading")
    func hostDrivenHonorsHeadroom() {
        #expect(DisplayCriteriaController.panelPresentsHDR(
            headroomAboveOne: true, attribution: .hostDriven, panelProvenToEngageHDR: false))
    }
}
