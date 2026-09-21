import Foundation
import Testing
@testable import AetherEngine

/// AE#459: an accepted HDR master answers the panel question better than the headroom does, so the label
/// stops following a property that has been measured getting this exact case wrong.
struct Issue459AcceptanceProvesPanelTests {

    @Test("A served HDR master that was not withdrawn proves the panel")
    func acceptedMasterProves() {
        #expect(DisplayCriteriaController.masterAcceptanceProvesPanel(
            servingHDRMaster: true, fellBackToMedia: false, sessionIsPlaying: true))
    }

    /// The measured case this exists for: the same session read `currentEDR=1.00` and had AVFoundation
    /// report `ITU_R_2100_HLG` on the item it accepted.
    @Test("A refused master proves nothing, which is the whole difference from merely serving one")
    func refusedMasterProvesNothing() {
        #expect(DisplayCriteriaController.masterAcceptanceProvesPanel(
            servingHDRMaster: true, fellBackToMedia: true, sessionIsPlaying: true) == false)
    }

    @Test("An SDR master proves nothing: every panel takes one")
    func sdrMasterProvesNothing() {
        #expect(DisplayCriteriaController.masterAcceptanceProvesPanel(
            servingHDRMaster: false, fellBackToMedia: false, sessionIsPlaying: true) == false)
    }

    @Test("A session that never started proves nothing")
    func notPlayingProvesNothing() {
        #expect(DisplayCriteriaController.masterAcceptanceProvesPanel(
            servingHDRMaster: true, fellBackToMedia: false, sessionIsPlaying: false) == false)
    }

    /// A rejection is decided at parse and eligibility time, measured at 54 to 61 ms on device with zero
    /// `errorLog` events. The settle window has to clear that by an order of magnitude and still fit inside
    /// the probe window it delays.
    @Test("The settle window clears a measured rejection by an order of magnitude")
    func settleWindowClearsARejection() {
        #expect(DisplayCriteriaController.masterAcceptanceSettleMs >= 500)
        #expect(DisplayCriteriaController.masterAcceptanceSettleMs < DisplayCriteriaController.playbackProbeWindowMs)
    }

    /// The label still refuses to claim HDR for an SDR source, whatever the panel is doing.
    @Test("Proving the panel does not invent HDR for an SDR source")
    func sdrSourceStaysSDR() {
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .sdr, panelPresentsHDR: true, sourceCarriesHDR10Plus: false) == .sdr)
    }

    /// The P8.4 that produced this round: HLG base on a display whose table reported HLG absent, served as
    /// a master and accepted. Before the capability fix it resolved to SDR; before this one the label did.
    @Test("A proven panel publishes the HLG a Profile 8.4 actually resolved to")
    func profile84PublishesHLG() {
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .hlg, panelPresentsHDR: true, sourceCarriesHDR10Plus: false) == .hlg)
        #expect(AetherEngine.presentedVideoFormat(
            effectiveFormat: .hlg, panelPresentsHDR: false, sourceCarriesHDR10Plus: false) == .sdr)
    }
}
