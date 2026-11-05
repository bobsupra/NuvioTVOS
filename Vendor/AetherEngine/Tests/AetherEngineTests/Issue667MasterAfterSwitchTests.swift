import Foundation
import Testing
@testable import AetherEngine

/// AE#667: an unproven HDR master served while the display mode switch is still running is refused for the
/// mode the panel is leaving, and that refusal was latched as a fact about the panel.
///
/// Measured by the reporter on an Apple TV 4K (3rd gen, tvOS 27.0, HDR10 panel, Match Content on): the
/// pre-flight released at its 2 s cap, the master was served 140 ms later, AVPlayer failed it with `-11868`
/// after 80 ms, and the switch ended 660 ms after the refusal. Every HDR title on that box lost its master.
struct Issue667MasterAfterSwitchTests {

    @Test("An unproven master waits while a switch it saw start is still running")
    func unprovenMasterWaitsForRunningSwitch() {
        #expect(AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: true, panelPresentsHDR: false, switchRunning: true))
    }

    @Test("No running switch, no wait: the #348 overlap stays where nothing is pending")
    func noRunningSwitchNoWait() {
        #expect(!AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: true, panelPresentsHDR: false, switchRunning: false))
    }

    @Test("A proven panel already answered, so its master does not wait")
    func provenPanelDoesNotWait() {
        #expect(!AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: true, panelPresentsHDR: true, switchRunning: true))
    }

    @Test("A media route has no acceptance to wait for")
    func mediaRouteDoesNotWait() {
        #expect(!AetherEngine.unprovenMasterAwaitsSwitchEnd(
            routesAsHDR: false, panelPresentsHDR: false, switchRunning: true))
    }

    @Test("A confirmed preferred HDR10+ master waits for an observed switch")
    func preferredHDR10PlusMasterWaitsForSwitch() {
        #expect(AetherEngine.preferredHDR10PlusMasterAwaitsSwitch(
            isLive: false, dolbyVisionHandling: .hdr10BaseLayerOnly, servingMaster: true,
            advertisesHDR10Plus: true, switchRunning: true))
    }

    @Test("The preferred master wait is limited to confirmed VOD HDR10+ during a switch")
    func preferredHDR10PlusMasterWaitIsScoped() {
        #expect(!AetherEngine.preferredHDR10PlusMasterAwaitsSwitch(
            isLive: true, dolbyVisionHandling: .hdr10BaseLayerOnly, servingMaster: true,
            advertisesHDR10Plus: true, switchRunning: true))
        #expect(!AetherEngine.preferredHDR10PlusMasterAwaitsSwitch(
            isLive: false, dolbyVisionHandling: .automatic, servingMaster: true,
            advertisesHDR10Plus: true, switchRunning: true))
        #expect(!AetherEngine.preferredHDR10PlusMasterAwaitsSwitch(
            isLive: false, dolbyVisionHandling: .hdr10BaseLayerOnly, servingMaster: false,
            advertisesHDR10Plus: true, switchRunning: true))
        #expect(!AetherEngine.preferredHDR10PlusMasterAwaitsSwitch(
            isLive: false, dolbyVisionHandling: .hdr10BaseLayerOnly, servingMaster: true,
            advertisesHDR10Plus: false, switchRunning: true))
        #expect(!AetherEngine.preferredHDR10PlusMasterAwaitsSwitch(
            isLive: false, dolbyVisionHandling: .hdr10BaseLayerOnly, servingMaster: true,
            advertisesHDR10Plus: true, switchRunning: false))
    }

    @Test("A refusal raised mid-switch does not latch, even on an eligible display")
    func midSwitchRefusalDoesNotLatch() {
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(
            code: -11868, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: true))
        #expect(!MasterFallbackDecision.shouldLatchPanelRefusal(
            code: -11848, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: true))
    }

    @Test("A refusal after the switch settled still latches")
    func settledRefusalStillLatches() {
        #expect(MasterFallbackDecision.shouldLatchPanelRefusal(
            code: -11868, servedMasterIsHDR: true, displayEligibleForHDRNow: true, displaySwitchInProgress: false))
    }

    /// A policy test cannot see the call site, so this one reads it: the wait sits between the route and the
    /// serve, and re-reads the panel afterwards so the route is decided on the arrived mode.
    @Test("The load waits for the switch before routing, then routes again")
    func loadSiteWaitsThenReroutes() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let gate = try #require(text.range(of: "Self.unprovenMasterAwaitsSwitchEnd("))
        let after = text[gate.upperBound...]
        let wait = try #require(after.range(of: "waitForSwitch(consumesRecord: false, settleCap: .awaitObservedEnd"))
        let reroute = try #require(after.range(of: "routingPanelHDR = Self.sessionRoutesAsHDRPanel("))
        let serve = try #require(after.range(of: "panelIsInHDRMode: routingPanelHDR"))
        #expect(wait.lowerBound < reroute.lowerBound)
        #expect(reroute.lowerBound < serve.lowerBound)
    }
}
