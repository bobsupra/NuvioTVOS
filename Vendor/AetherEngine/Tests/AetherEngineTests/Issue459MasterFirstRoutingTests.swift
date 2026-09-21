import Foundation
import Testing
@testable import AetherEngine

/// AE#459: the route may assume more about the panel than the label may claim, because the two answer
/// different questions and only one of them has a component that actually knows.
struct Issue459MasterFirstRoutingTests {

    // MARK: - The decision itself

    @Test("A proven panel short-circuits, so a box on plain 4K HDR never attempts anything")
    func provenPanelShortCircuits() {
        #expect(AetherEngine.sessionRoutesAsHDRPanel(
            panelPresentsHDR: true,
            attemptWhenUnproven: false,
            displayEligibleForHDR: false,
            panelRefusedHDRMaster: true))
    }

    @Test("An unproven but HDR-eligible panel is offered the master: the 4K HDR10+ case")
    func unprovenEligiblePanelAttempts() {
        #expect(AetherEngine.sessionRoutesAsHDRPanel(
            panelPresentsHDR: false,
            attemptWhenUnproven: true,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false))
    }

    @Test("A display that cannot do HDR at all is never offered a master")
    func ineligibleDisplayNeverAttempts() {
        #expect(AetherEngine.sessionRoutesAsHDRPanel(
            panelPresentsHDR: false,
            attemptWhenUnproven: true,
            displayEligibleForHDR: false,
            panelRefusedHDRMaster: false) == false)
    }

    @Test("A refusal is latched, so a genuinely SDR panel pays the 223 ms once and not per title")
    func refusalIsLatched() {
        #expect(AetherEngine.sessionRoutesAsHDRPanel(
            panelPresentsHDR: false,
            attemptWhenUnproven: true,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: true) == false)
    }

    @Test("A host that knows its display is SDR can decline to spend the attempt")
    func hostCanOptOut() {
        #expect(AetherEngine.sessionRoutesAsHDRPanel(
            panelPresentsHDR: false,
            attemptWhenUnproven: false,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false) == false)
    }

    // MARK: - What the latch may and may not learn from

    /// `-1002` reaches the same fallback and means the master was filtered at parse time (#130). That is a
    /// statement about the playlist, so latching on it would teach the process a fact about the panel from
    /// an unrelated defect.
    @Test("Only the two display-rejection codes may teach the process about the panel")
    func onlyDisplayRejectionsAreAboutTheDisplay() {
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11868))
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11848))
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-1002) == false)
        // and -1002 still reaches the fallback, which is why the distinction has to be made there
        #expect(MasterFallbackDecision.isMasterRejectionCode(-1002))
    }

    // MARK: - The label is deliberately left alone

    /// Publishing HDR because a master was SERVED would claim exactly what this issue was opened about,
    /// one frame earlier. The label keeps answering from the readout.
    @Test("An attempted route does not move the published label")
    func attemptDoesNotMoveTheLabel() {
        #expect(AetherEngine.sessionPanelPresentsHDR(hostAsserts: false, criteriaReadout: false) == false)
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .hdr10, panelPresentsHDR: false, sourceCarriesHDR10Plus: true) == .sdr)
    }

    // MARK: - Live

    @Test("Live never attempts: its fallback is a rejoin at the edge, and that cost is unmeasured")
    func liveNeverAttempts() {
        let live = LoadOptions(isLive: true)
        #expect(AetherEngine.sessionRoutesAsHDRPanel(
            panelPresentsHDR: false,
            attemptWhenUnproven: live.attemptsHDRMasterOnUnprovenPanel && !live.isLive,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false) == false)
    }

    @Test("VOD attempts by default, so the fix reaches a host that sets nothing")
    func vodAttemptsByDefault() {
        let vod = LoadOptions()
        #expect(vod.attemptsHDRMasterOnUnprovenPanel)
        #expect(AetherEngine.sessionRoutesAsHDRPanel(
            panelPresentsHDR: false,
            attemptWhenUnproven: vod.attemptsHDRMasterOnUnprovenPanel && !vod.isLive,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false))
    }
}
