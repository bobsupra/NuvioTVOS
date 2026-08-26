import Testing
@testable import AetherEngine

/// #361: the engine-side half of the startup ladder. The reducer is proven in `StartupProgressTests`;
/// what is decided here is which events open, continue and end a sequence, since that is where the
/// axis differs from the internal `loadGeneration` it would be tempting to reuse.
@MainActor
struct StartupProgressEngineTests {

    @Test("no load, no sequence")
    func idleEnginePublishesNothing() throws {
        let engine = try AetherEngine()
        #expect(engine.startupProgress == nil)
    }

    @Test("a load opens a sequence at the origin of the ladder")
    func loadOpensSequence() throws {
        let engine = try AetherEngine()
        let gen = engine.beginStartupProgress()
        #expect(engine.startupProgress?.checkpoint == .dispatched)
        #expect(engine.startupProgress?.generation == gen)
        #expect(engine.startupProgress?.completed == 0)
    }

    @Test("each load gets its own generation")
    func generationsAreDistinct() throws {
        let engine = try AetherEngine()
        let first = engine.beginStartupProgress()
        engine.recordStartupCheckpoint(.ready)
        let second = engine.beginStartupProgress()
        #expect(second != first)
        #expect(engine.startupProgress?.checkpoint == .dispatched)
    }

    // The case the whole separate generation exists for: the AE#154 / AE#268 reroutes tear the
    // session down and call load() again while the user is still waiting on the load they asked for.
    @Test("an engine reroute continues the sequence instead of restarting it")
    func rerouteKeepsGenerationAndProgress() throws {
        let engine = try AetherEngine()
        let gen = engine.beginStartupProgress()
        engine.recordStartupCheckpoint(.streamsProbed)

        engine.continueStartupAcrossReroute()
        let rerouteGen = engine.beginStartupProgress()

        #expect(rerouteGen == gen)
        #expect(engine.startupProgress?.checkpoint == .streamsProbed)
    }

    @Test("the continuation flag is consumed by the load it was set for")
    func continuationIsSingleUse() throws {
        let engine = try AetherEngine()
        let gen = engine.beginStartupProgress()
        engine.continueStartupAcrossReroute()
        _ = engine.beginStartupProgress()
        let afterwards = engine.beginStartupProgress()
        #expect(afterwards != gen)
        #expect(engine.startupProgress?.checkpoint == .dispatched)
    }

    @Test("a checkpoint from a superseded load cannot move the current one")
    func stragglerFromSupersededLoadIsDropped() throws {
        let engine = try AetherEngine()
        let stale = engine.beginStartupProgress()
        _ = engine.beginStartupProgress()
        engine.recordStartupCheckpoint(.ready, generation: stale)
        #expect(engine.startupProgress?.checkpoint == .dispatched)
    }

    @Test("stop() ends the sequence without completing it")
    func stopClearsWithoutFinishing() throws {
        let engine = try AetherEngine()
        _ = engine.beginStartupProgress()
        engine.recordStartupCheckpoint(.ready)
        #expect(engine.startupProgress?.isComplete == false)
        engine.stop()
        #expect(engine.startupProgress == nil)
    }

    @Test("a sink firing after stop() cannot resurrect a sequence")
    func lateSinkAfterStopStaysSilent() throws {
        let engine = try AetherEngine()
        _ = engine.beginStartupProgress()
        engine.stop()
        engine.recordStartupCheckpoint(.presenting)
        #expect(engine.startupProgress == nil)
    }

    @Test("the ladder walks forward and only forward")
    func ladderIsMonotonic() throws {
        let engine = try AetherEngine()
        _ = engine.beginStartupProgress()
        for checkpoint in StartupCheckpoint.allCases {
            engine.recordStartupCheckpoint(checkpoint)
        }
        #expect(engine.startupProgress?.isComplete == true)
        engine.recordStartupCheckpoint(.sourceOpened)
        #expect(engine.startupProgress?.checkpoint == .presenting)
    }
}
