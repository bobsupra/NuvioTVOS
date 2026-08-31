import Testing
@testable import AetherEngine

/// Pure derivation of the unified playback phase (#85). Covers the full precedence truth table:
/// error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused.
@Suite("PlaybackPhase.derive (#85)")
struct PlaybackPhaseDeriveTests {

    @Test("error beats every other signal")
    func errorWins() {
        #expect(PlaybackPhase.derive(state: .error("boom"), isBuffering: true, isSeeking: true, stall: .reconnecting, transportHasRolled: true) == .error("boom"))
    }

    @Test("ended beats idle/loading/playing signals")
    func endedWins() {
        #expect(PlaybackPhase.derive(state: .ended, isBuffering: true, isSeeking: true, stall: .reconnecting, transportHasRolled: true) == .ended)
    }

    @Test("idle maps straight through")
    func idlePassThrough() {
        #expect(PlaybackPhase.derive(state: .idle, isBuffering: false, isSeeking: false, stall: .flowing, transportHasRolled: true) == .idle)
    }

    @Test("loading outranks a reconnect happening underneath startup")
    func loadingOutranksStall() {
        #expect(PlaybackPhase.derive(state: .loading, isBuffering: false, isSeeking: false, stall: .reconnecting, transportHasRolled: true) == .loading)
    }

    @Test("a seek over a delivering source outranks a rebuffer")
    func seekingOutranksRebuffer() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: true, stall: .flowing, transportHasRolled: true) == .seeking)
    }

    @Test("state == .seeking but isSeeking already cleared reads as playing")
    func optimisticSeekStateWithoutInFlightIsPlaying() {
        #expect(PlaybackPhase.derive(state: .seeking, isBuffering: false, isSeeking: false, stall: .flowing, transportHasRolled: true) == .playing)
    }

    @Test("reconnect outranks a plain rebuffer")
    func stallOutranksRebuffer() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false, stall: .reconnecting, transportHasRolled: true) == .stalled(reconnecting: true))
    }

    @Test("rebuffer when only the buffer underran, connection healthy")
    func rebufferWhenOnlyBuffering() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false, stall: .flowing, transportHasRolled: true) == .rebuffering)
    }

    @Test("clean playing")
    func playing() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false, stall: .flowing, transportHasRolled: true) == .playing)
    }

    @Test("paused is preserved when nothing else is in flight")
    func paused() {
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false, stall: .flowing, transportHasRolled: true) == .paused)
    }

    @Test("paused while reconnecting still reports the stall")
    func pausedWhileStalled() {
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false, stall: .reconnecting, transportHasRolled: true) == .stalled(reconnecting: true))
    }
}

/// #410: a seek cannot land over a source that stopped delivering, so `isSeeking` stays up for the whole
/// outage and used to hide the one axis that describes it. The seek is still observable (`isSeeking`,
/// `seekEvents`); the reader phase is not observable anywhere else, so it takes precedence.
@Suite("PlaybackPhase source-stall precedence (#410)")
struct PlaybackPhaseStallPrecedenceTests {

    @Test("a reconnecting reader stays visible while a seek is in flight")
    func stallOutranksSeek() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: true, stall: .reconnecting, transportHasRolled: true)
                == .stalled(reconnecting: true))
    }

    @Test("the engine's own recovery scrub does not hide the outage it recovers from")
    func stallOutranksSeekAndRebufferTogether() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: true, stall: .reconnecting, transportHasRolled: true)
                == .stalled(reconnecting: true))
    }

    @Test("over a delivering source a seek still reads as .seeking")
    func healthySourceKeepsSeeking() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: true, stall: .flowing, transportHasRolled: true) == .seeking)
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: true, stall: .flowing, transportHasRolled: true) == .seeking)
    }

    @Test("an exhausted ladder reports the stall with retries stopped")
    func exhaustedReportsRetriesStopped() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false, stall: .exhausted, transportHasRolled: true)
                == .stalled(reconnecting: false))
    }

    @Test("exhausted outranks seek, rebuffer and paused the same way reconnecting does")
    func exhaustedPrecedence() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: true, stall: .exhausted, transportHasRolled: true)
                == .stalled(reconnecting: false))
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false, stall: .exhausted, transportHasRolled: true)
                == .stalled(reconnecting: false))
    }

    @Test("a terminal state still outranks an exhausted reader")
    func terminalOutranksExhausted() {
        #expect(PlaybackPhase.derive(state: .error("boom"), isBuffering: false, isSeeking: false, stall: .exhausted, transportHasRolled: true) == .error("boom"))
        #expect(PlaybackPhase.derive(state: .ended, isBuffering: false, isSeeking: false, stall: .exhausted, transportHasRolled: true) == .ended)
        #expect(PlaybackPhase.derive(state: .loading, isBuffering: false, isSeeking: false, stall: .exhausted, transportHasRolled: true) == .loading)
    }
}

/// Engine-level wiring of #85: the published phase tracks the four inputs and only re-emits on change.
@Suite("AetherEngine.playbackPhase wiring (#85)")
@MainActor
struct PlaybackPhaseEngineTests {

    @Test("phase starts idle and follows state/buffer/stall/seek transitions")
    func followsInputs() throws {
        let engine = try AetherEngine()
        #expect(engine.playbackPhase == .idle)

        engine.state = .loading
        #expect(engine.playbackPhase == .loading)

        engine.state = .playing
        // AE#440: intent alone is not motion. This is the live-join hold, in miniature.
        #expect(engine.playbackPhase == .loading)
        engine.hasTransportRolled = true
        #expect(engine.playbackPhase == .playing)

        engine.isBuffering = true
        #expect(engine.playbackPhase == .rebuffering)

        engine.setReaderNetworkPhase(.reconnecting)
        #expect(engine.playbackPhase == .stalled(reconnecting: true))   // stall outranks rebuffer

        engine.isSeeking = true
        #expect(engine.playbackPhase == .stalled(reconnecting: true))   // #410: the stall survives the seek

        engine.setReaderNetworkPhase(.flowing)
        #expect(engine.playbackPhase == .seeking)                       // delivering again: the seek reads through

        engine.isSeeking = false
        engine.isBuffering = false
        #expect(engine.playbackPhase == .playing)
    }

    @Test("setReaderNetworkPhase clears back to a non-stalled phase")
    func stallClears() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.hasTransportRolled = true
        engine.setReaderNetworkPhase(.reconnecting)
        #expect(engine.playbackPhase == .stalled(reconnecting: true))
        engine.setReaderNetworkPhase(.flowing)
        #expect(engine.playbackPhase == .playing)
    }

    /// #410 second half: the reader that exhausts its ladder is replaced by the reopen's own reader, so the
    /// exhausted state has to survive the handover and be cleared by the NEW reader's first real progress.
    @Test("an exhausted ladder holds the phase until a reader delivers again")
    func exhaustedHeldAcrossReaderHandover() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.hasTransportRolled = true

        var dyingReaderGate = NetworkPhaseGate()
        if dyingReaderGate.shouldEmit(.reconnecting) { engine.setReaderNetworkPhase(.reconnecting) }
        #expect(engine.playbackPhase == .stalled(reconnecting: true))
        if dyingReaderGate.shouldEmit(.exhausted) { engine.setReaderNetworkPhase(.exhausted) }
        #expect(engine.playbackPhase == .stalled(reconnecting: false))

        // The reopen installs a fresh reader with a fresh gate; its first real progress is what clears the
        // stall. A gate that starts out believing it already said `.flowing` would latch the phase here.
        var reopenedReaderGate = NetworkPhaseGate()
        if reopenedReaderGate.shouldEmit(.flowing) { engine.setReaderNetworkPhase(.flowing) }
        #expect(engine.playbackPhase == .playing)
    }
}

/// The reader-side dedupe gate: emit only when the phase actually changes, so a flapping origin
/// does not spam the callback (#85). It deduplicates for one SINK, so attaching a listener clears it
/// (#433, `forgetForNewListener`).
@Suite("NetworkPhaseGate (#85)")
struct NetworkPhaseGateTests {

    /// #410: the first statement always goes out. The gate is per reader INSTANCE while the phase it feeds
    /// is per engine, so a reopened reader that assumed `.flowing` would never report its recovery and
    /// would strand the engine on the dying reader's last word.
    @Test("emits the first phase it is handed, including flowing")
    func emitsInitialPhase() {
        var gate = NetworkPhaseGate()
        #expect(gate.shouldEmit(.flowing) == true)
        #expect(gate.shouldEmit(.flowing) == false)
    }

    @Test("emits on transition and suppresses repeats")
    func emitsOnlyOnChange() {
        var gate = NetworkPhaseGate()
        #expect(gate.shouldEmit(.reconnecting) == true)
        #expect(gate.shouldEmit(.reconnecting) == false)
        #expect(gate.shouldEmit(.flowing) == true)
        #expect(gate.shouldEmit(.flowing) == false)
        #expect(gate.shouldEmit(.reconnecting) == true)
    }

    @Test("exhaustion is its own transition, in both directions")
    func exhaustionTransitions() {
        var gate = NetworkPhaseGate()
        #expect(gate.shouldEmit(.reconnecting) == true)
        #expect(gate.shouldEmit(.exhausted) == true)
        #expect(gate.shouldEmit(.exhausted) == false)
        #expect(gate.shouldEmit(.flowing) == true)
    }
}
