import Foundation
import Testing
@testable import AetherEngine

/// AE#535: `displayCapabilities` answers at call time, and a native load read it TWICE, once to compose
/// the format clamp and once inside `loadNative` for the session it builds. The comment over the second
/// read claimed it was the first one's table. Measured 203 ms apart on an Apple TV they disagreed, and an
/// HDR10+ title whose load had read `dv=true` was served media-direct with its master withheld. The same
/// property is revoked wholesale (`hdr=false hdr10=false hlg=false dv=false`) while the app is
/// backgrounded, which is where a route-death rebuild lands.
struct Issue535OneDisplayTablePerLoadTests {

    private static let dvPanel = DisplayCapabilities(
        supportsHDR: true, supportsDolbyVision: true, supportsHDR10: true, supportsHLG: true)
    private static let revoked = DisplayCapabilities(
        supportsHDR: false, supportsDolbyVision: false, supportsHDR10: false, supportsHLG: false)

    @Test("The reporter's case: a rebuild inside the revoked window keeps the load's table")
    func revokedReadDoesNotReachTheRebuild() {
        let caps = AetherEngine.reloadDisplayCapabilities(
            observedAtLoad: Self.dvPanel,
            hostAssertsDolbyVision: false,
            readNow: { Self.revoked })
        #expect(caps == Self.dvPanel)
    }

    @Test("A rebuild with no load behind it reads the display, because it has nothing to carry")
    func noLoadTableFallsBackToTheRead() {
        let caps = AetherEngine.reloadDisplayCapabilities(
            observedAtLoad: nil,
            hostAssertsDolbyVision: false,
            readNow: { Self.dvPanel })
        #expect(caps == Self.dvPanel)
    }

    @Test("The host's Dolby Vision assertion is applied to the carried table, as it is at the load")
    func assertionAppliesToTheCarriedTable() {
        let observed = DisplayCapabilities(
            supportsHDR: false, supportsDolbyVision: false, supportsHDR10: false, supportsHLG: false)
        let caps = AetherEngine.reloadDisplayCapabilities(
            observedAtLoad: observed,
            hostAssertsDolbyVision: true,
            readNow: { Self.revoked })
        #expect(caps.supportsDolbyVision)
        #expect(caps.supportsHDR)
    }

    @Test("Carrying the table reaches the same value the load composed, so the two cannot drift")
    func rebuildMatchesTheLoad() {
        for hdrEligible in [false, true] {
            for hdr10 in [false, true] {
                for hlg in [false, true] {
                    for dv in [false, true] {
                        for asserts in [false, true] {
                            let observed = DisplayCapabilities.observedPerModeTable(
                                hdrEligible: hdrEligible, hdr10: hdr10, hlg: hlg, dolbyVision: dv)
                            let atLoad = observed.assertingDolbyVision(asserts)
                            let atRebuild = AetherEngine.reloadDisplayCapabilities(
                                observedAtLoad: observed,
                                hostAssertsDolbyVision: asserts,
                                readNow: { Self.revoked })
                            #expect(atLoad == atRebuild)
                        }
                    }
                }
            }
        }
    }

    @Test("A host assertion claims Dolby Vision without making the panel eligible for the route")
    func assertionDoesNotStandInForEligibility() {
        // `sessionDisplayEligibleForHDR` derives from the OBSERVED table for this reason: the route's
        // unproven-panel attempt (AE#459) asks what the display answers, not what the host claims.
        let observed = DisplayCapabilities(
            supportsHDR: false, supportsDolbyVision: false, supportsHDR10: false, supportsHLG: false)
        #expect(observed.assertingDolbyVision(true).supportsHDR)
        #expect(observed.supportsHDR == false)
    }

    @Test("The loading path reads the property once, and the session is handed that one table")
    func loadingPathHoldsNoSecondRead() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine")
        let loading = try String(
            contentsOf: sources.appendingPathComponent("AetherEngine+Loading.swift"), encoding: .utf8)
        let engine = try String(
            contentsOf: sources.appendingPathComponent("AetherEngine.swift"), encoding: .utf8)
        // The session is built from the parameter, never from a read taken beside it.
        #expect(loading.contains("sessionDisplayCaps: DisplayCapabilities,"))
        #expect(loading.contains("dvModeAvailable: sessionDisplayCaps.supportsDolbyVision"))
        #expect(!loading.contains("let sessionDisplayCaps = Self.displayCapabilities"))
        // Exactly one read composes a route: the one in `load`. The reads the rebuild path takes are
        // the carried-table fallback and the diagnostic comparison, both named.
        let routingReads = engine.components(separatedBy: "Self.displayCapabilities").count - 1
        #expect(routingReads == 1)
        #expect(engine.contains("let observedDisplayCaps = Self.displayCapabilities"))
        #expect(engine.contains("sessionDisplayCaps: sessionDisplayCaps"))
    }
}
