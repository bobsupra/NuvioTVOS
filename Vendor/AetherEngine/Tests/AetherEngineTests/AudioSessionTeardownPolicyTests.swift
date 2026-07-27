import Testing
import Foundation
@testable import AetherEngine

/// Unit tests for the #215 teardown policy: when a stop may release the shared `AVAudioSession`.
///
/// The session is process-global state the engine mostly does not own (the native path never activates
/// it, AVKit does, #24), so the release is gated three ways: the host opted in, the caller declared a
/// genuine final teardown, and no native host survives the stop. Getting the gate wrong is not a cosmetic
/// bug: deactivating mid-reload kills audio for a session the host expects to keep playing.
@Suite("AVAudioSession teardown policy (#215)")
struct AudioSessionTeardownPolicyTests {

    private func shouldDeactivate(finalTeardown: Bool, keepNativeHost: Bool, hostOptedIn: Bool) -> Bool {
        AetherEngine.shouldDeactivateAudioSessionOnTeardown(
            finalTeardown: finalTeardown, keepNativeHost: keepNativeHost, hostOptedIn: hostOptedIn)
    }

    @Test("a final teardown with the host opted in releases the session")
    func finalTeardownOptedInDeactivates() {
        #expect(shouldDeactivate(finalTeardown: true, keepNativeHost: false, hostOptedIn: true))
    }

    @Test("without the host opt-in nothing is ever deactivated")
    func optOutNeverDeactivates() {
        for finalTeardown in [true, false] {
            for keepNativeHost in [true, false] {
                #expect(!shouldDeactivate(finalTeardown: finalTeardown,
                                          keepNativeHost: keepNativeHost,
                                          hostOptedIn: false),
                        "default-off must be byte-identical to pre-#215 behaviour")
            }
        }
    }

    /// `stopInternal()` defaults `finalTeardown` to false, so every internal stop (the live-reload
    /// watchdog, an audio-track switch, a backend handoff) is excluded even for an opted-in host.
    @Test("an internal stop that is not a final teardown keeps the session")
    func internalStopKeepsSession() {
        #expect(!shouldDeactivate(finalTeardown: false, keepNativeHost: false, hostOptedIn: true))
        #expect(!shouldDeactivate(finalTeardown: false, keepNativeHost: true, hostOptedIn: true))
    }

    /// A preserved native host means the AVPlayer lives on into the next load: audio is expected to keep
    /// flowing across the seam, so the session must not go away underneath it.
    @Test("a preserved native host keeps the session even on a declared final teardown")
    func preservedNativeHostKeepsSession() {
        #expect(!shouldDeactivate(finalTeardown: true, keepNativeHost: true, hostOptedIn: true))
    }

    @MainActor
    @Test("the opt-in is off by default")
    func optInDefaultsOff() throws {
        let engine = try AetherEngine()
        #expect(engine.deactivatesAudioSessionOnStop == false)
    }
}
