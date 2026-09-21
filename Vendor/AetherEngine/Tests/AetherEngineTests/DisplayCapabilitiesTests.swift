import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

struct DisplayCapabilitiesTests {

    @Test("AE#493: an eligible on-demand EDR display can present HDR10 and HLG")
    func eligibleDisplayPresentsPQAndHLG() {
        let caps = DisplayCapabilities.onDemandEDRDisplay(hdrEligible: true)
        #expect(caps.supportsHDR)
        #expect(caps.supportsHDR10)
        #expect(caps.supportsHLG)
    }

    @Test("AE#493: eligibility says nothing about Dolby Vision, so it stays unclaimed")
    func eligibilityDoesNotClaimDolbyVision() {
        #expect(DisplayCapabilities.onDemandEDRDisplay(hdrEligible: true).supportsDolbyVision == false)
    }

    @Test("AE#493: an ineligible display claims nothing, which is what the SDR-only Mac needs")
    func ineligibleDisplayClaimsNothing() {
        let caps = DisplayCapabilities.onDemandEDRDisplay(hdrEligible: false)
        #expect(caps.supportsHDR == false)
        #expect(caps.supportsHDR10 == false)
        #expect(caps.supportsHLG == false)
        #expect(caps.supportsDolbyVision == false)
    }

    // MARK: - AE#459: the per-mode table under-reports HLG over HDMI

    /// The measured tvOS reading: a Samsung whose EDID advertises Hybrid Log-Gamma, connected straight to
    /// an Apple TV, with `availableHDRModes` reporting HDR10 and not HLG.
    private static let measuredAppleTVTable = DisplayCapabilities.observedPerModeTable(
        hdrEligible: true, hdr10: true, hlg: false, dolbyVision: false)

    @Test("AE#459: eligibility is the floor for HLG, so a table that omits it no longer subtracts")
    func eligibilityIsTheFloorForHLG() {
        #expect(Self.measuredAppleTVTable.supportsHLG)
        #expect(Self.measuredAppleTVTable.supportsHDR10)
        #expect(Self.measuredAppleTVTable.supportsHDR)
    }

    @Test("AE#459: the table may still ADD a mode eligibility does not imply")
    func tableStillAdds() {
        let caps = DisplayCapabilities.observedPerModeTable(
            hdrEligible: false, hdr10: false, hlg: true, dolbyVision: true)
        #expect(caps.supportsHLG)
        #expect(caps.supportsDolbyVision)
    }

    @Test("AE#459: Dolby Vision stays on the table alone, eligibility never claims it")
    func eligibilityDoesNotClaimDolbyVisionFromTable() {
        #expect(Self.measuredAppleTVTable.supportsDolbyVision == false)
        let dvDisplay = DisplayCapabilities.observedPerModeTable(
            hdrEligible: true, hdr10: true, hlg: true, dolbyVision: true)
        #expect(dvDisplay.supportsDolbyVision)
    }

    @Test("AE#459: an ineligible display with an empty table still claims nothing")
    func ineligibleWithEmptyTableClaimsNothing() {
        let caps = DisplayCapabilities.observedPerModeTable(
            hdrEligible: false, hdr10: false, hlg: false, dolbyVision: false)
        #expect(caps.supportsHDR == false)
        #expect(caps.supportsHDR10 == false)
        #expect(caps.supportsHLG == false)
        #expect(caps.supportsDolbyVision == false)
    }

    /// The whole point of the capability term: this is the one source it reaches.
    @Test("AE#459: a Dolby Vision Profile 8.4 no longer resolves to SDR on the measured Apple TV table")
    func profile84NoLongerClampsToSDR() {
        let resolved = AetherEngine.effectiveVideoFormat(
            detected: .dolbyVision,
            baseTransfer: AVCOL_TRC_ARIB_STD_B67,
            capabilities: Self.measuredAppleTVTable)
        #expect(resolved == .hlg)
    }

    /// The guard that keeps the blast radius narrow, pinned so nobody widens it by accident.
    @Test("AE#459: a plain HLG source was never clamped by the capability table")
    func plainHLGIsNotClamped() {
        let caps = DisplayCapabilities.observedPerModeTable(
            hdrEligible: false, hdr10: false, hlg: false, dolbyVision: false)
        #expect(AetherEngine.effectiveVideoFormat(
            detected: .hlg, baseTransfer: AVCOL_TRC_ARIB_STD_B67, capabilities: caps) == .hlg)
    }
}
