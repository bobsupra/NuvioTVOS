import Testing
import AVFoundation
@testable import AetherEngine

/// #489: `AetherEngine.videoGravity` reached the software display layer only through its setter.
/// A host built during a load came up on the layer's own default, so a value the host app set
/// before playback started was dropped, and the same value set again mid-session worked. The
/// native path has always re-applied the stored gravity on every host build
/// (`AetherEngine+Loading.swift`); the software path now does too, at construction, so the layer
/// is never briefly on a gravity nobody asked for.
///
/// A host app drawing its own subtitle overlay has to know which gravity is on screen to place
/// cues against the right rectangle, and it can only learn that from the engine.
@Suite("Software host is built on the engine's videoGravity (#489)")
struct Issue489SoftwareHostGravityTests {

    @MainActor
    @Test("a renderer built with no gravity keeps the aspect-fit default")
    func rendererDefaultsToAspect() {
        let renderer = SampleBufferRenderer()
        #expect(renderer.displayLayer.videoGravity == .resizeAspect)
    }

    @MainActor
    @Test("a renderer carries the gravity it was built with")
    func rendererCarriesGravity() {
        #expect(SampleBufferRenderer(videoGravity: .resizeAspectFill)
            .displayLayer.videoGravity == .resizeAspectFill)
        #expect(SampleBufferRenderer(videoGravity: .resize)
            .displayLayer.videoGravity == .resize)
    }

    @MainActor
    @Test("a software host hands its gravity to the display layer it renders into")
    func hostCarriesGravity() {
        #expect(SoftwarePlaybackHost(videoGravity: .resizeAspectFill)
            .displayLayer.videoGravity == .resizeAspectFill)
    }

    @MainActor
    @Test("a software host built with no gravity keeps the aspect-fit default")
    func hostDefaultsToAspect() {
        #expect(SoftwarePlaybackHost().displayLayer.videoGravity == .resizeAspect)
    }
}
