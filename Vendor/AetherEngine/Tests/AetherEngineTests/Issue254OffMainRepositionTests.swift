import Foundation
import Testing
@testable import AetherEngine

/// #254: `SoftwarePlaybackHost.seek` ran the demuxer reposition inline, and the host is `@MainActor`.
/// `Demuxer.readPacket` holds the access lock across the whole of `av_read_frame`, so a seek issued
/// while the demux loop sat in a slow remote read parked the MAIN thread until that read returned:
/// two field App Hangs, "Fully Blocked", 4.4 s and 5.2 s, on a WAN source over the software path. The
/// missing read deadline is a second, latent hazard; it could not have caused those two, because
/// `seekBounded` arms its deadline on the far side of the lock the seek never got past.
struct Issue254OffMainRepositionTests {

    /// One-shot flag a sent closure can write. A mutable local captured by such a closure is the
    /// `#SendingRisksDataRace` shape the CI toolchain rejects.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @MainActor
    @Test("the reposition runs off the main thread")
    func repositionRunsOffMain() async {
        let demuxer = Demuxer()
        let queue = DispatchQueue(label: "test.issue254.offmain")
        let sawOffMain = Flag()
        // The supersede predicate is evaluated ON `queue`, immediately before the FFmpeg call, so it
        // observes the thread the reposition itself runs on.
        _ = await demuxer.seekBounded(to: 10, timeout: 1, on: queue, isSuperseded: {
            sawOffMain.set(!Thread.isMainThread)
            return false
        })
        #expect(sawOffMain.isSet)
    }

    @MainActor
    @Test("a reposition waiting on the demuxer leaves the main actor free")
    func blockedRepositionKeepsMainActorLive() async {
        let demuxer = Demuxer()
        let queue = DispatchQueue(label: "test.issue254.blocked")
        let release = DispatchSemaphore(value: 0)
        let finished = Flag()
        // Stands in for the demux loop holding `accessLock` across a slow remote read: the reposition
        // cannot begin until this returns. Generous backstop, never a discriminator; the signal below
        // is what actually ends it.
        queue.async { _ = release.wait(timeout: .now() + 90) }

        let reposition = Task { @MainActor in
            _ = await demuxer.seekBounded(to: 10, timeout: 1, on: queue)
            finished.set(true)
        }

        // 100 ms of main-actor work while the reposition is stuck behind the queue. The inline call
        // this replaces could not reach here at all: it held the thread these hops need.
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(finished.isSet == false)

        release.signal()
        await reposition.value
        #expect(finished.isSet)
    }

    @MainActor
    @Test("a superseded reposition never reaches the demuxer")
    func supersededSkipsTheDemuxer() async {
        let demuxer = Demuxer()
        let queue = DispatchQueue(label: "test.issue254.superseded")
        // A scrub burst (the report's trigger: 20+ relative seeks in 10 s) collapses onto its last
        // target instead of paying one lock wait per seek.
        let outcome = await demuxer.seekBounded(to: 10, timeout: 1, on: queue, isSuperseded: { true })
        #expect(outcome == .superseded)
    }

    @Test("a reposition that spends its budget reports stalled, not a landing")
    func stalledRepositionDoesNotClaimALanding() {
        #expect(AetherEngine.seekTicketOutcome(hostReposition: .stalled, renderedTime: 42) == .stalled)
        #expect(AetherEngine.seekTicketOutcome(hostReposition: .landed, renderedTime: 42)
                == .landed(renderedTime: 42))
        // Supersession is settled by the engine's own generation guard before the ticket is closed;
        // if it ever does reach here it is a landing, not a give-up.
        #expect(AetherEngine.seekTicketOutcome(hostReposition: .superseded, renderedTime: 42)
                == .landed(renderedTime: 42))
    }
}
