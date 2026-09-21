import Foundation
import Testing
@testable import AetherEngine

/// AE#541: an in-place rebuild (the audio pick) routed from the raw `panelIsInHDRMode` option, so a
/// panel the load had proven through the criteria readout was served the media playlist on the reload
/// and the title lost its AUDIO rendition's language at the moment a viewer picked audio.
struct Issue541ReloadCarriesHDRRouteTests {

    @Test("The reporter's case: no assertion, a proven readout at load, and the reload keeps the master")
    func provenReadoutSurvivesTheReload() {
        #expect(AetherEngine.reloadRoutesAsHDRPanel(
            hostAsserts: false,
            criteriaReadoutAtLoad: true,
            attemptWhenUnproven: false,
            isLive: false,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false))
    }

    @Test("An unproven but eligible VOD panel the load offered the master is offered it again")
    func unprovenAttemptSurvivesTheReload() {
        #expect(AetherEngine.reloadRoutesAsHDRPanel(
            hostAsserts: false,
            criteriaReadoutAtLoad: false,
            attemptWhenUnproven: true,
            isLive: false,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false))
    }

    @Test("A refusal latched after the load is honoured, so the reload does not pay the fallback twice")
    func refusalAfterTheLoadIsHonoured() {
        #expect(AetherEngine.reloadRoutesAsHDRPanel(
            hostAsserts: false,
            criteriaReadoutAtLoad: false,
            attemptWhenUnproven: true,
            isLive: false,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: true) == false)
    }

    @Test("Live never attempts on an unproven panel, on the reload as on the load")
    func liveDoesNotAttempt() {
        #expect(AetherEngine.reloadRoutesAsHDRPanel(
            hostAsserts: false,
            criteriaReadoutAtLoad: false,
            attemptWhenUnproven: true,
            isLive: true,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false) == false)
    }

    @Test("A suppressed-criteria session with no assertion stays media-direct, as before")
    func suppressedWithoutAssertionIsUnchanged() {
        #expect(AetherEngine.reloadRoutesAsHDRPanel(
            hostAsserts: false,
            criteriaReadoutAtLoad: nil,
            attemptWhenUnproven: false,
            isLive: false,
            displayEligibleForHDR: true,
            panelRefusedHDRMaster: false) == false)
    }

    @Test("An assertion applied through a #460 correction still moves the reload's route")
    func correctedAssertionMovesTheRoute() {
        #expect(AetherEngine.reloadRoutesAsHDRPanel(
            hostAsserts: true,
            criteriaReadoutAtLoad: false,
            attemptWhenUnproven: false,
            isLive: false,
            displayEligibleForHDR: false,
            panelRefusedHDRMaster: false))
    }

    @Test("For every input the reload reaches the answer the load reached, so the two cannot drift")
    func reloadMatchesTheLoad() {
        for hostAsserts in [false, true] {
            for readout in [nil, false, true] as [Bool?] {
                for attempt in [false, true] {
                    for isLive in [false, true] {
                        for eligible in [false, true] {
                            for refused in [false, true] {
                                let load = AetherEngine.sessionRoutesAsHDRPanel(
                                    panelPresentsHDR: AetherEngine.sessionPanelPresentsHDR(
                                        hostAsserts: hostAsserts, criteriaReadout: readout),
                                    attemptWhenUnproven: attempt && !isLive,
                                    displayEligibleForHDR: eligible,
                                    panelRefusedHDRMaster: refused)
                                let reload = AetherEngine.reloadRoutesAsHDRPanel(
                                    hostAsserts: hostAsserts,
                                    criteriaReadoutAtLoad: readout,
                                    attemptWhenUnproven: attempt,
                                    isLive: isLive,
                                    displayEligibleForHDR: eligible,
                                    panelRefusedHDRMaster: refused)
                                #expect(load == reload)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("The reload call site hands loadNative the composed route, not the raw option")
    func reloadCallSiteDoesNotPassTheRawOption() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine+Loading.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return }
        #expect(!text.contains("panelIsInHDRMode: loadedOptions.panelIsInHDRMode"))
        #expect(text.contains("panelIsInHDRMode: reloadRoutingPanelHDR"))
    }
}
