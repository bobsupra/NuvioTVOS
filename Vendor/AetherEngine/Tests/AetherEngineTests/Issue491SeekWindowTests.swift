import Testing
import Foundation
import CoreMedia
@testable import AetherEngine

/// AE#491 round 2: the generation is bumped when a seek is REQUESTED, and the read position moves
/// when the reposition RUNS, tens of milliseconds later. Round 1 gated everything on that
/// generation, which closes the door on a packet read before the bump and leaves it open for one
/// read INSIDE the window: those bytes are from the position the seek left behind and carry the new
/// generation, so every gate passes them.
///
/// Measured on the 6.68.2 build with a 3000 s fixture and a chain of large alternating seeks two
/// seconds apart: 5 to 9 packets per twelve-seek run entered the pipeline from a source that had not
/// been repositioned yet, with timestamps at the OLD position, and two of three runs paused the
/// clock for a rebuffer that was not happening. Same runs on this fix: zero, and none.
@Suite("The seek window (#491 round 2)")
struct Issue491SeekWindowTests {

    // MARK: - The window

    @Test("the window is open from the request until the landing settles it")
    func windowSpansRequestToLanding() {
        #expect(SeekWindow.isOpen(requested: 7, settled: 7) == false)
        #expect(SeekWindow.isOpen(requested: 8, settled: 7))
    }

    @Test("the loop reads only when it is playing and no seek is outstanding")
    func loopReadsOnlyOutsideTheWindow() {
        #expect(SeekWindow.loopMayRead(isPlaying: true, windowOpen: false))
        #expect(SeekWindow.loopMayRead(isPlaying: true, windowOpen: true) == false)
        #expect(SeekWindow.loopMayRead(isPlaying: false, windowOpen: false) == false)
        #expect(SeekWindow.loopMayRead(isPlaying: false, windowOpen: true) == false)
    }

    // MARK: - The packet rule, in the three shapes a read can have

    /// Round 1's shape: the read started before the bump, so it carries the old generation.
    @Test("a read that started before the bump is refused")
    func readBeforeTheBumpIsRefused() {
        #expect(SeekWindow.admitsPacket(readGeneration: 7, liveGeneration: 8, windowOpen: true) == false)
    }

    /// Round 2's shape, and the one the generation alone admits: the read started after the bump,
    /// so it carries the LIVE generation, but the reposition has not run, so the bytes are from the
    /// old position. The two cannot overlap, since a read and a reposition take the same access
    /// lock, which is what makes an open window sufficient to say it.
    @Test("a read that started inside the window is refused, generation notwithstanding")
    func readInsideTheWindowIsRefused() {
        #expect(SeekWindow.admitsPacket(readGeneration: 8, liveGeneration: 8, windowOpen: true) == false)
    }

    @Test("a read after the landing is admitted")
    func readAfterTheLandingIsAdmitted() {
        #expect(SeekWindow.admitsPacket(readGeneration: 8, liveGeneration: 8, windowOpen: false))
    }

    /// A scrub burst supersedes its predecessors. Only the seek that still owns the window closes
    /// it, or a landing that arrives late would re-open the window a newer seek is still inside.
    @Test("a superseded seek does not close a newer seek's window")
    func supersededSeekDoesNotClose() {
        #expect(SeekWindow.closes(settling: 9, live: 9))
        #expect(SeekWindow.closes(settling: 8, live: 9) == false)
    }

    // MARK: - Why one packet is enough

    /// The frontier is the newest timestamp HELD, so it only ever moves up between flushes. A single
    /// frame from before a backward seek therefore does not decay: every frame from the new position
    /// is lower and leaves it standing, and the cushion reads the seek distance until the next
    /// flush. That is the reporter's `vLead=2301.93` on a 2297 s backward jump.
    @Test("one stale frame past the target owns the frontier for the rest of the session")
    @MainActor
    func staleFrameOwnsTheFrontierPermanently() {
        let renderer = SampleBufferRenderer()
        Self.hand(renderer, seconds: [2468.55, 2470.51, 2470.55])
        renderer.flush(removingDisplayedImage: false)
        renderer.setSkipThreshold(CMTime(seconds: 168.62, preferredTimescale: 90000))

        // The one packet the window let through, decoded after the flush. It is PAST the backward
        // target, so the threshold passes it and clears itself on the way.
        Self.hand(renderer, seconds: [2470.55])
        #expect(renderer.newestEnqueuedPtsSeconds == 2470.55)

        // A whole second of the landing cannot take it back.
        Self.hand(renderer, seconds: (0..<24).map { 168.62 + Double($0) / 24.0 })
        #expect(renderer.newestEnqueuedPtsSeconds == 2470.55)
        let cushion = SoftwareBufferFrontier.cushionSeconds(
            newestEnqueuedPts: renderer.newestEnqueuedPtsSeconds, sourceClock: 168.62)
        #expect((cushion ?? 0) > 2300)
    }

    /// Without that packet, the same landing reports the cushion it actually has.
    @Test("with the window closed the frontier is the landing's own")
    @MainActor
    func landingOwnsTheFrontier() {
        let renderer = SampleBufferRenderer()
        Self.hand(renderer, seconds: [2468.55, 2470.51, 2470.55])
        renderer.flush(removingDisplayedImage: false)
        renderer.setSkipThreshold(CMTime(seconds: 168.62, preferredTimescale: 90000))

        Self.hand(renderer, seconds: (0..<24).map { 168.62 + Double($0) / 24.0 })
        let cushion = SoftwareBufferFrontier.cushionSeconds(
            newestEnqueuedPts: renderer.newestEnqueuedPtsSeconds, sourceClock: 168.62)
        #expect((cushion ?? 0) < 1.0)
    }

    private static func hand(_ renderer: SampleBufferRenderer, seconds: [Double]) {
        for s in seconds {
            renderer.enqueue(pixelBuffer: makePixelBuffer(),
                             pts: CMTime(seconds: s, preferredTimescale: 90000))
        }
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
}
