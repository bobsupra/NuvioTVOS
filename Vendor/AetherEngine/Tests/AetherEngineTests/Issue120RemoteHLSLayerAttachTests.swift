import Testing
import Foundation
@testable import AetherEngine

/// #120: `loadRemoteHLS` assigned the host but never called `presentCurrentLayer()`, so a surface
/// bound BEFORE load (the usual SwiftUI order: view appears, then the load task fires) never got
/// `host.playerLayer` attached. AVPlayer plays audio without a layer, so every remote-HLS live
/// channel showed black video with working sound. The normal native/software `load()` paths call
/// `presentCurrentLayer()` after the host exists; this locks the same contract for the bypass.
@Suite("loadRemoteHLS layer attach (#120)")
struct Issue120RemoteHLSLayerAttachTests {

    @MainActor
    @Test("Surface bound before load gets the host player layer attached")
    func attachesLayerToPreBoundSurface() async throws {
        let engine = try AetherEngine()
        let view = AetherPlayerView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        engine.bind(view: view)
        // Sanity: nothing loaded yet, so bind alone must not have attached anything.
        #expect(engine.nativeHost == nil)

        // Dead-end URL: AVPlayer fails asynchronously, but the layer attach is synchronous
        // within loadRemoteHLS and must not depend on the item ever becoming ready.
        try await engine.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/live.m3u8")!,
            options: LoadOptions(isLive: true, nativeRemoteHLS: true))

        let host = try #require(engine.nativeHost)
        #expect(host.playerLayer.superlayer === view.layer,
                "remote-HLS bypass must present its layer on an already-bound surface")
    }

    @MainActor
    @Test("Surface bound after load still gets the layer (existing behavior, must not regress)")
    func attachesLayerToPostBoundSurface() async throws {
        let engine = try AetherEngine()
        try await engine.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/live.m3u8")!,
            options: LoadOptions(isLive: true, nativeRemoteHLS: true))

        let view = AetherPlayerView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        engine.bind(view: view)

        let host = try #require(engine.nativeHost)
        #expect(host.playerLayer.superlayer === view.layer)
    }
}
