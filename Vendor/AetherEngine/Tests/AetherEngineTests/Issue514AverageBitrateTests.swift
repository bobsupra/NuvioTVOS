import Foundation
import Testing
import AVFoundation
@testable import AetherEngine

/// AE#514: `LiveTelemetry.averageBitrateMbps` divided the session's lifetime bytes by pure wall-clock
/// time. Bytes stop arriving while the transport is paused (the forward buffer is already full), the
/// divisor does not, so the reported average decayed toward zero for as long as the pause lasted and
/// never came back: the paused seconds stayed in the divisor for the rest of the session. The fix
/// charges a tick's second only when the session is in a phase that consumes media.
@MainActor
struct Issue514AverageBitrateTests {

    // MARK: - Which seconds belong in the divisor

    /// A pause and the three terminal phases are the session standing still. Everything else is the
    /// session working, and the bytes it did or did not get in those seconds are part of its average.
    @Test("only the phases that consume media charge a second to the divisor")
    func pausedAndTerminalPhasesDoNotCharge() {
        #expect(LiveTelemetrySampler.chargesActiveTime(.paused) == false)
        #expect(LiveTelemetrySampler.chargesActiveTime(.idle) == false)
        #expect(LiveTelemetrySampler.chargesActiveTime(.ended) == false)
        #expect(LiveTelemetrySampler.chargesActiveTime(.error("boom")) == false)

        #expect(LiveTelemetrySampler.chargesActiveTime(.playing))
        #expect(LiveTelemetrySampler.chargesActiveTime(.loading))
        #expect(LiveTelemetrySampler.chargesActiveTime(.rebuffering))
        #expect(LiveTelemetrySampler.chargesActiveTime(.stalled(reconnecting: true)))
        #expect(LiveTelemetrySampler.chargesActiveTime(.stalled(reconnecting: false)))
    }

    /// Deliberately NOT excluded, against the report's own suggestion: a seek is where the session
    /// fetches hardest (the buffer is discarded and a new range pulled). Dropping those seconds while
    /// keeping their bytes would push the average above the media's real rate on every scrub.
    @Test("a seek charges its seconds, because it is also where the bytes arrive")
    func seekingCharges() {
        #expect(LiveTelemetrySampler.chargesActiveTime(.seeking))
    }

    // MARK: - The quotient

    @Test("the average is the lifetime bytes over the active seconds")
    func averageIsBytesOverActiveSeconds() {
        // 2 Mbps for ten active seconds: 2 500 000 bytes.
        let rate = LiveTelemetrySampler.averageBitrateMbps(lifetimeBytes: 2_500_000, activeSeconds: 10)
        #expect(abs((rate ?? 0) - 2.0) < 0.001)
    }

    /// Same rule as `observedTransferMbps` one field over: "not measurable yet" is a gap, never a
    /// confident zero. Before the fix the very first tick published 0.00 Mbps, because it seeds
    /// `sessionStartBytes` from the same counter it then subtracts.
    @Test("a session with no active time and no bytes publishes nil, not zero")
    func unmeasurableSessionPublishesNil() {
        #expect(LiveTelemetrySampler.averageBitrateMbps(lifetimeBytes: 0, activeSeconds: 0) == nil)
        #expect(LiveTelemetrySampler.averageBitrateMbps(lifetimeBytes: 350_000, activeSeconds: 0) == nil)
        #expect(LiveTelemetrySampler.averageBitrateMbps(lifetimeBytes: 0, activeSeconds: 30) == nil)
    }

    // MARK: - The reported session shape

    /// The reporter's steps, folded tick by tick: 30 s of a 2.8 Mbps file, a three-minute pause during
    /// which the demuxer counter stands still, then playback again.
    @Test("a three-minute pause leaves the average flat instead of collapsing it")
    func pauseDoesNotDragTheAverageDown() {
        let bytesPerSecond: Int64 = 350_000        // 2.8 Mbps
        var lifetimeBytes: Int64 = 0
        var activeSeconds: Double = 0
        var wallClockSeconds: Double = 0

        func tick(_ phase: PlaybackPhase, bytes: Int64) {
            lifetimeBytes += bytes
            wallClockSeconds += 1
            if LiveTelemetrySampler.chargesActiveTime(phase) { activeSeconds += 1 }
        }

        for _ in 0..<30 { tick(.playing, bytes: bytesPerSecond) }
        let beforePause = LiveTelemetrySampler.averageBitrateMbps(
            lifetimeBytes: lifetimeBytes, activeSeconds: activeSeconds)
        #expect(abs((beforePause ?? 0) - 2.8) < 0.001)

        // Paused: the forward buffer is full, so the demuxer counter does not move.
        for _ in 0..<180 { tick(.paused, bytes: 0) }
        let duringPause = LiveTelemetrySampler.averageBitrateMbps(
            lifetimeBytes: lifetimeBytes, activeSeconds: activeSeconds)
        #expect(duringPause == beforePause, "the pause must not move the average at all")

        // What used to ship, for the record: the same bytes over wall-clock time.
        let wallClockAverage = Double(lifetimeBytes) * 8.0 / wallClockSeconds / 1_000_000.0
        #expect(wallClockAverage < 0.5, "the old divisor collapsed a 2.8 Mbps session to \(wallClockAverage)")

        // And on resume it is still the media's rate, not a value climbing back out of a hole.
        for _ in 0..<30 { tick(.playing, bytes: bytesPerSecond) }
        let afterResume = LiveTelemetrySampler.averageBitrateMbps(
            lifetimeBytes: lifetimeBytes, activeSeconds: activeSeconds)
        #expect(abs((afterResume ?? 0) - 2.8) < 0.001)
    }

    /// End of media is the other unbounded divisor: the sampler runs until the host tears the session
    /// down, so a snapshot left on screen after the last frame used to decay exactly like a pause.
    @Test("the average stops moving once the source has ended")
    func endedSessionFreezesTheAverage() {
        var activeSeconds: Double = 0
        for _ in 0..<30 where LiveTelemetrySampler.chargesActiveTime(.playing) { activeSeconds += 1 }
        let atEnd = activeSeconds
        for _ in 0..<120 where LiveTelemetrySampler.chargesActiveTime(.ended) { activeSeconds += 1 }
        #expect(activeSeconds == atEnd)
    }

    // MARK: - Wiring

    /// The two functions above are only right if the tick actually asks them. A paused session accrues
    /// no active time however long its sampler runs; the same sampler starts accruing on play.
    @Test("the running sampler charges no active time while the transport is paused")
    func samplerAccruesNoActiveTimeWhilePaused() async throws {
        let engine = try AetherEngine()
        engine.playbackBackend = .native
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-514.mp4"))
        engine.currentAVPlayer = AVPlayer(playerItem: item)
        engine.state = .paused
        #expect(engine.playbackPhase == .paused)

        let sampler = LiveTelemetrySampler(engine: engine, nativeRead: { _, _ in
            NativeAVFReadings(forwardBufferSeconds: 12.0)
        })
        sampler.start()
        defer { sampler.stop() }

        // Long enough for several 1 Hz ticks to have run and charged nothing.
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(sampler.activeSeconds == 0)

        engine.state = .playing
        let started = ContinuousClock().now
        while sampler.activeSeconds == 0 {
            if ContinuousClock().now - started > .seconds(30) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sampler.activeSeconds > 0)
    }
}
