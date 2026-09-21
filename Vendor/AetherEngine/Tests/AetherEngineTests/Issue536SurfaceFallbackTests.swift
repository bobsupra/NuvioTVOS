import Testing
import Foundation
@testable import AetherEngine

/// AE#536: the engine held one weak reference to its bound view. A host that remounts its surface by
/// identity while keeping the engine gets the incoming view made and bound first, then SwiftUI still
/// updates the OUTGOING view on its way out (rebinding it, #188's update path) and only then dismantles
/// it. With a single reference the engine was bound to the outgoing view, then to nothing, and the
/// next session's fresh layer attached nowhere: audio over a black picture. These tests replay that
/// order at the engine level and lock the fallback that keeps the incoming view presenting.
@Suite("Surface fallback when a remounted surface leaves (AE#536)")
struct Issue536SurfaceFallbackTests {

    private static let frame = CGRect(x: 0, y: 0, width: 640, height: 360)

    @MainActor
    private func loadedEngine(_ name: String) async throws -> (AetherEngine, NativeAVPlayerHost) {
        let engine = try AetherEngine()
        try await engine.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/\(name).m3u8")!,
            options: LoadOptions(isLive: true, nativeRemoteHLS: true))
        return (engine, try #require(engine.nativeHost))
    }

    @MainActor
    @Test("The outgoing view's rebind and unbind hand the layer back to the incoming view")
    func unbindOfOutgoingViewFallsBackToIncoming() async throws {
        let (engine, host) = try await loadedEngine("remount")
        let outgoing = AetherPlayerView(frame: Self.frame)
        engine.bind(view: outgoing)

        let incoming = AetherPlayerView(frame: Self.frame)
        engine.bind(view: incoming)      // makeUIView of the remounted surface
        engine.bind(view: outgoing)      // updateUIView of the surface being removed
        #expect(host.playerLayer.superlayer === outgoing.layer)

        engine.unbind(view: outgoing)    // dismantleUIView

        #expect(host.playerLayer.superlayer === incoming.layer,
                "the layer must move to the surface that is still mounted")
    }

    @MainActor
    @Test("An outgoing view released without unbind leaves the next session presenting on the incoming view")
    func releasedOutgoingViewFallsBackForNextSession() async throws {
        let engine = try AetherEngine()
        let incoming = AetherPlayerView(frame: Self.frame)
        weak var releasedOutgoing: AetherPlayerView?
        autoreleasepool {
            let outgoing = AetherPlayerView(frame: Self.frame)
            releasedOutgoing = outgoing
            engine.bind(view: outgoing)
            engine.bind(view: incoming)
            engine.bind(view: outgoing)
        }
        #expect(releasedOutgoing == nil, "precondition: nothing else retains the outgoing view")

        // The session after the swap builds its host only now, as a next-episode load does.
        try await engine.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/next.m3u8")!,
            options: LoadOptions(isLive: true, nativeRemoteHLS: true))
        let host = try #require(engine.nativeHost)

        #expect(host.playerLayer.superlayer === incoming.layer,
                "a fresh layer must attach to the surviving surface, not to nothing")
    }

    @MainActor
    @Test("Unbinding a view that is not presenting leaves the presenting view alone and removes the fallback")
    func unbindOfFallbackKeepsPresentingView() async throws {
        let (engine, host) = try await loadedEngine("fallback")
        let first = AetherPlayerView(frame: Self.frame)
        let second = AetherPlayerView(frame: Self.frame)
        engine.bind(view: first)
        engine.bind(view: second)

        engine.unbind(view: first)
        #expect(host.playerLayer.superlayer === second.layer)

        engine.unbind(view: second)
        #expect(host.playerLayer.superlayer == nil,
                "an unbound view must never come back as a fallback")
    }

    @MainActor
    @Test("A view taken over by another engine is no longer the first engine's surface or fallback")
    func takenOverViewLeavesPreviousEngine() async throws {
        let (engineA, hostA) = try await loadedEngine("a")
        let (engineB, hostB) = try await loadedEngine("b")
        let earlier = AetherPlayerView(frame: Self.frame)
        let shared = AetherPlayerView(frame: Self.frame)
        engineA.bind(view: earlier)
        engineA.bind(view: shared)

        engineB.bind(view: shared)

        #expect(hostB.playerLayer.superlayer === shared.layer)
        #expect(hostA.playerLayer.superlayer === earlier.layer,
                "the first engine falls back to its own remaining surface")

        engineA.unbind(view: earlier)
        #expect(hostA.playerLayer.superlayer == nil)
        #expect(hostB.playerLayer.superlayer === shared.layer,
                "the first engine must not reclaim the view the second engine holds")
    }
}
