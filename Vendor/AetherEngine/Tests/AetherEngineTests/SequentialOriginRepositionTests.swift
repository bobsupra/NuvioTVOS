import Testing
import Foundation
@testable import AetherEngine

/// #346 follow-up: a sequential origin answers from byte 0 and nowhere else, so every site that
/// would set the producer down at some other offset has to refuse. The merged PR covered one of
/// them (the readError revive); `performRestart`'s demuxer seek was the dangerous one it missed,
/// because a seek on a non-seekable pb does not throw - it returns false, and the restart ignores
/// that, leaving the new producer to label whatever bytes the stream is on as segment `idx`. That
/// is the same fabricated-position content the whole declaration exists to keep out, except silent
/// instead of audible.
@Suite("Sequential-origin reposition refusal")
struct SequentialOriginRepositionTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _codes: [Int32] = []
        var codes: [Int32] {
            lock.lock(); defer { lock.unlock() }
            return _codes
        }
        func set(_ code: Int32) {
            lock.lock(); _codes.append(code); lock.unlock()
        }
    }

    private func makeEngine(sequential: Bool) -> HLSVideoEngine {
        HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/archive.ts"),
                       dvModeAvailable: false,
                       sequentialOrigin: sequential,
                       declaredDurationSeconds: sequential ? 8100 : nil)
    }

    @Test("a sequential VOD session refuses the restart and surfaces the source failure")
    func restartRefused() {
        let engine = makeEngine(sequential: true)
        let failed = Flag()
        engine.onVODSourceFailed = { code, _, _ in failed.set(code) }

        engine.requestRestart(at: 12)

        #expect(failed.codes == [-5],
                "the refusal must reach the host as a terminal source failure, not park silently")
    }

    @Test("an authoritative restart is refused too")
    func authoritativeRestartRefused() {
        // The seek-deadline recovery re-anchors with authoritative: true, which wins the coalescer
        // over any pending target. Authority over the coalescer is not authority over the origin.
        let engine = makeEngine(sequential: true)
        let failed = Flag()
        engine.onVODSourceFailed = { code, _, _ in failed.set(code) }

        engine.requestRestart(at: 40, authoritative: true)

        #expect(failed.codes == [-5])
    }

    @Test("an ordinary VOD session keeps the restart path")
    func ordinaryRestartUnaffected() {
        // Same call on a non-sequential session must NOT take the refusal arm: it runs the normal
        // restart, which no-ops here (empty segment plan) without surfacing a failure.
        let engine = makeEngine(sequential: false)
        let failed = Flag()
        engine.onVODSourceFailed = { code, _, _ in failed.set(code) }

        engine.requestRestart(at: 12)

        #expect(failed.codes.isEmpty,
                "a non-sequential session must not inherit the sequential refusal")
    }

    @Test("the pin predicate is what every reposition site asks")
    func predicateShape() {
        #expect(makeEngine(sequential: true).sequentialOriginPinsProducerToZero)
        #expect(!makeEngine(sequential: false).sequentialOriginPinsProducerToZero)
    }
}
