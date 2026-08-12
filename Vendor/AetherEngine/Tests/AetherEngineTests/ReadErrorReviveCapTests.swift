import Testing
import Foundation
@testable import AetherEngine

/// #169: a mid-session VOD read error gets a bounded producer revive. Once the gate was
/// exhausted, `handleVODReadErrorExit` used to log "giving up" and return WITHOUT any
/// terminal surface — no producer, no error, AVPlayer parked in waitingToPlay forever.
/// The cap-reached arm must fire `onVODSourceFailed` exactly like the produced-nothing arm.
@Suite("VOD readError revive-cap exhaustion")
struct ReadErrorReviveCapTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _code: Int32?
        var code: Int32? {
            lock.lock(); defer { lock.unlock() }
            return _code
        }
        func set(_ code: Int32) {
            lock.lock(); _code = code; lock.unlock()
        }
    }

    @Test("an exhausted revive gate surfaces onVODSourceFailed instead of dying silently")
    func exhaustedGateSurfacesFailure() {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/witness.mkv"),
                                    dvModeAvailable: false)
        engine.readErrorReviveGate = MuxerFailureReviveGate(maxAttempts: 0)
        let failed = Flag()
        engine.onVODSourceFailed = { failed.set($0) }

        engine.handleVODReadErrorExit(-5)

        #expect(failed.code == -5,
                "the cap-reached arm must surface the terminal failure to the host")
    }

    @Test("the revive gate admits within its cap and refuses past it")
    func gateAdmitsWithinCap() {
        var gate = MuxerFailureReviveGate(maxAttempts: 2)
        let first = gate.admit()
        let second = gate.admit()
        let third = gate.admit()
        #expect(first)
        #expect(second)
        #expect(!third, "the third failure must exhaust a two-attempt gate")
        #expect(gate.attempts == 3)
    }
}
