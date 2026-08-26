import Testing
@testable import AetherEngine

// AE#361: the host-facing startup ladder. Every rule the axis promises is decided here, in the pure
// reducer, so none of it depends on driving a real load against real media.
@Suite("Startup progress checkpoints (#361)")
struct StartupProgressTests {

    private func begin(_ generation: UInt64 = 1) -> StartupProgress {
        StartupProgress(generation: generation, checkpoint: .dispatched)
    }

    @Test("A fresh sequence starts at zero of the full ladder")
    func startsAtZero() {
        let p = begin()
        #expect(p.completed == 0)
        #expect(p.total == StartupCheckpoint.allCases.count - 1)
        #expect(p.fraction == 0)
        #expect(!p.isComplete)
    }

    @Test("Completed counts the checkpoints behind the sequence, not the enum case")
    func completedCountsCheckpoints() {
        let p = StartupProgress.advanced(from: begin(), to: .streamsProbed, generation: 1)
        #expect(p?.completed == 3)
        #expect(p?.checkpoint == .streamsProbed)
    }

    @Test("Reaching the last checkpoint completes the sequence")
    func lastCheckpointCompletes() {
        let p = StartupProgress.advanced(from: begin(), to: .presenting, generation: 1)
        #expect(p?.isComplete == true)
        #expect(p?.fraction == 1.0)
        #expect(p?.completed == p?.total)
    }

    @Test("A repeated checkpoint publishes nothing")
    func steadyRepublishIsDeduped() {
        let landed = StartupProgress.advanced(from: begin(), to: .ready, generation: 1)
        #expect(landed != nil)
        #expect(StartupProgress.advanced(from: landed, to: .ready, generation: 1) == nil)
    }

    @Test("A checkpoint behind the sequence never lowers it")
    func neverGoesBackwards() {
        let landed = StartupProgress.advanced(from: begin(), to: .sessionConstructed, generation: 1)
        #expect(StartupProgress.advanced(from: landed, to: .sourceOpened, generation: 1) == nil)
        #expect(StartupProgress.advanced(from: landed, to: .routed, generation: 1) == nil)
    }

    // The bypasses (remote-HLS, audio-only) run no probe and no panel handshake; the ladder has to
    // credit the work they legitimately skip instead of stalling on checkpoints that never come.
    @Test("A skipped stretch completes with the checkpoint that overtakes it")
    func skippedCheckpointsCompleteImmediately() {
        let p = StartupProgress.advanced(from: begin(), to: .routed, generation: 1)
        #expect(p?.completed == StartupCheckpoint.routed.rawValue)
        #expect(p?.checkpoint == .routed)
    }

    @Test("A checkpoint from a superseded generation is ignored")
    func supersededGenerationIgnored() {
        let current = StartupProgress(generation: 7, checkpoint: .streamsProbed)
        #expect(StartupProgress.advanced(from: current, to: .routed, generation: 6) == nil)
        #expect(StartupProgress.advanced(from: current, to: .routed, generation: 8) == nil)
        #expect(StartupProgress.advanced(from: current, to: .routed, generation: 7) != nil)
    }

    // A late sink from a torn-down session must not resurrect a sequence the host has already
    // stopped observing.
    @Test("A checkpoint without a running sequence starts nothing")
    func noSequenceMeansNoPublish() {
        #expect(StartupProgress.advanced(from: nil, to: .ready, generation: 1) == nil)
    }

    @Test("The stage names the work in flight, not the checkpoint behind it")
    func stageDescribesWorkInFlight() {
        #expect(begin().stage == .connecting)
        #expect(StartupProgress(generation: 1, checkpoint: .sourceOpened).stage == .openingContainer)
        #expect(StartupProgress(generation: 1, checkpoint: .containerOpened).stage == .analyzingStreams)
        #expect(StartupProgress(generation: 1, checkpoint: .streamsProbed).stage == .preparingDisplay)
        #expect(StartupProgress(generation: 1, checkpoint: .displayPrepared).stage == .selectingRoute)
        #expect(StartupProgress(generation: 1, checkpoint: .routed).stage == .buildingSession)
        #expect(StartupProgress(generation: 1, checkpoint: .sessionConstructed).stage == .preparingPlayback)
        #expect(StartupProgress(generation: 1, checkpoint: .ready).stage == .awaitingFirstFrame)
        #expect(StartupProgress(generation: 1, checkpoint: .presenting).stage == .presenting)
    }

    @Test("The ladder is ordered as the engine walks it")
    func ladderOrder() {
        #expect(StartupCheckpoint.allCases == [
            .dispatched, .sourceOpened, .containerOpened, .streamsProbed,
            .displayPrepared, .routed, .sessionConstructed, .ready, .presenting,
        ])
        #expect(StartupCheckpoint.dispatched < StartupCheckpoint.presenting)
    }

    @Test("Every open stage maps onto its checkpoint")
    func openStageMapping() {
        #expect(StartupCheckpoint(openStage: .sourceOpened) == .sourceOpened)
        #expect(StartupCheckpoint(openStage: .containerOpened) == .containerOpened)
        #expect(StartupCheckpoint(openStage: .streamsProbed) == .streamsProbed)
    }

    @Test("Fraction never leaves 0...1")
    func fractionIsNormalized() {
        for checkpoint in StartupCheckpoint.allCases {
            let p = StartupProgress(generation: 1, checkpoint: checkpoint)
            #expect(p.fraction >= 0 && p.fraction <= 1)
        }
    }
}
