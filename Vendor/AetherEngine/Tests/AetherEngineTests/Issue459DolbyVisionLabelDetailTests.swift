import Testing
@testable import AetherEngine

/// AE#459 follow-up: two things a Dolby Vision label could not say. A Blu-ray Profile 7 (and a Profile 8.1
/// remuxed from one) can carry an HDR10+ layer next to the RPU, which a display without Dolby Vision
/// presents; and a Profile 7 played on a display presenting Dolby Vision is served as Profile 8.1.
@Suite("Issue 459: Dolby Vision label detail")
@MainActor
struct Issue459DolbyVisionLabelDetailTests {

    // The reporter's Samsung: no Dolby Vision in the table, so the clamp resolves HDR10, the headroom
    // proves nothing, the load-time label reads SDR, and the T.35 payload lands before the acceptance
    // proof. `sourceVideoFormat` stays `.dolbyVision`, so the evidence has to survive somewhere else.
    @Test("A Dolby Vision source's HDR10+ layer survives a late panel proof")
    func dolbyVisionSourceKeepsHDR10PlusThroughTheLateProof() throws {
        let engine = try AetherEngine()
        engine.sourceVideoFormat = .dolbyVision
        engine.videoFormat = .sdr

        engine.handleHDR10PlusDetected()
        #expect(engine.videoFormat == .sdr)
        #expect(engine.sourceVideoFormat == .dolbyVision)

        engine.republishPanelPresentsHDR(effectiveFormat: .hdr10, because: "test")
        #expect(engine.videoFormat == .hdr10Plus)
    }

    @Test("A Dolby Vision source already labelled HDR10 is upgraded when the payload lands")
    func dolbyVisionSourceClampedToHDR10UpgradesOnDetection() throws {
        let engine = try AetherEngine()
        engine.sourceVideoFormat = .dolbyVision
        engine.videoFormat = .hdr10

        engine.handleHDR10PlusDetected()
        #expect(engine.videoFormat == .hdr10Plus)
        #expect(engine.sourceVideoFormat == .dolbyVision)
    }

    // On a display presenting Dolby Vision the RPU wins; the HDR10+ layer is not what is shown.
    @Test("A Dolby Vision session keeps its label when the source also carries HDR10+")
    func dolbyVisionSessionIgnoresTheHDR10PlusLayer() throws {
        let engine = try AetherEngine()
        engine.sourceVideoFormat = .dolbyVision
        engine.videoFormat = .sdr

        engine.handleHDR10PlusDetected()
        engine.republishPanelPresentsHDR(effectiveFormat: .dolbyVision, because: "test")
        #expect(engine.videoFormat == .dolbyVision)
    }

    @Test("A fresh engine reports no Dolby Vision conversion")
    func noConversionByDefault() throws {
        let engine = try AetherEngine()
        #expect(engine.dolbyVisionConversion == nil)
        #expect(!engine.sourceCarriesHDR10PlusMetadata)
    }
}
