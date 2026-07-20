import Testing
@testable import AetherEngine

/// Covers the `PlaybackState.ended` terminal-state contract (#63): end-of-media is a state distinct from
/// `.idle`, and like `.idle` it swallows transport calls so a host scrub / play press racing the end card
/// cannot revive a finished session. The "didReachEnd -> .ended" wiring itself needs real playback to EOF
/// and is device-verified.
@Suite("PlaybackState.ended (#63)")
struct PlaybackStateEndedTests {

    @Test("All cases are distinct, and .ended is not .idle")
    func casesDistinct() {
        let all: [PlaybackState] = [.idle, .loading, .playing, .paused, .seeking, .ended, .error("x")]
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() {
                if i == j { #expect(a == b) } else { #expect(a != b) }
            }
        }
        // The whole point of the change: "finished" must never compare equal to "pre-load / stopped".
        #expect(PlaybackState.ended != PlaybackState.idle)
    }

    @MainActor
    @Test("seek(to:) is a no-op in .ended (terminal, like .idle)")
    func seekIgnoredWhenEnded() async throws {
        let engine = try AetherEngine()
        engine.state = .ended
        await engine.seek(to: 42)
        // A guard miss would flip .ended -> .seeking/.playing; the state must stay terminal.
        #expect(engine.state == .ended)
    }

    @MainActor
    @Test("togglePlayPause() is a no-op in .ended")
    func togglePlayPauseIgnoredWhenEnded() throws {
        let engine = try AetherEngine()
        engine.state = .ended
        engine.togglePlayPause()
        #expect(engine.state == .ended)
    }
}
