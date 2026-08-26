import Testing
@testable import AetherEngine

/// Issue #126: an unknown-length HTTP MP4 degraded to forward-only streaming mode, the first
/// readPacket failed, and the VOD pump died silently with zero packets while AVPlayer waited
/// forever on a playlist that would never gain a segment. These pin the fatal-exit decision
/// that now surfaces such a death to the host.
///
/// The decision is about what the pump PRODUCED, not about how it died: a source that runs to EOF
/// without ever writing a packet leaves the same dead playlist behind as one whose read threw.
struct VODPumpFatalExitTests {

    @Test("VOD readError with nothing produced is fatal")
    func zeroProgressReadErrorIsFatal() {
        #expect(HLSVideoEngine.isFatalVODPumpExit(
            reason: .readError(code: -1), isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }

    @Test("VOD readError after packets were written is not fatal (mid-session transient)")
    func midSessionReadErrorIsNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .readError(code: -5), isLive: false,
            packetsWritten: 4821, cachedSegments: 0))
    }

    @Test("VOD readError with cached segments is not fatal (restart arms cover recovery)")
    func cachedSegmentsAreNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .readError(code: -1), isLive: false,
            packetsWritten: 0, cachedSegments: 12))
    }

    @Test("live readError is never fatal here (live reopen owns recovery)")
    func liveReadErrorIsNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .readError(code: -1), isLive: true,
            packetsWritten: 0, cachedSegments: 0))
    }

    /// This case used to assert the opposite, on the grounds that EOF is not a read error. True,
    /// and beside the point: measured on a source whose packets libavformat cannot split, the pump
    /// read 322 packets, wrote none, exited `.eof`, and the host sat at
    /// `state=playing phase=rebuffering` for the whole session with no error anywhere.
    @Test("VOD eof with nothing produced is fatal")
    func eofWithNothingProducedIsFatal() {
        #expect(HLSVideoEngine.isFatalVODPumpExit(
            reason: .eof, isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }

    @Test("an ordinary EOF after real playback is not fatal")
    func eofAfterProductionIsNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .eof, isLive: false,
            packetsWritten: 12_400, cachedSegments: 0))
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .eof, isLive: false,
            packetsWritten: 0, cachedSegments: 340))
    }

    @Test("live eof is never fatal here (live reopen owns recovery)")
    func liveEofIsNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .eof, isLive: true,
            packetsWritten: 0, cachedSegments: 0))
    }

    /// Every reason that owns a recovery arm returns before this decision is reached; if one ever
    /// stops doing so, surfacing here would pre-empt its own bounded revive.
    @Test("reasons with their own recovery arm are not fatal here")
    func recoverableReasonsAreNotFatal() {
        for reason in [HLSSegmentProducer.PumpExitReason.muxerFailed,
                       .needsAudioSampleEntryPrime,
                       .backpressureWedge] {
            #expect(!HLSVideoEngine.isFatalVODPumpExit(
                reason: reason, isLive: false,
                packetsWritten: 0, cachedSegments: 0))
        }
    }

    @Test("teardown exits are not fatal")
    func stopRequestedIsNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .stopRequested, isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }
}
