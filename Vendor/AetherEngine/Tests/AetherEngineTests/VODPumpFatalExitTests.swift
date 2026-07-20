import Testing
@testable import AetherEngine

/// Issue #126: an unknown-length HTTP MP4 degraded to forward-only streaming mode, the first
/// readPacket failed, and the VOD pump died silently with zero packets while AVPlayer waited
/// forever on a playlist that would never gain a segment. These pin the fatal-exit decision
/// that now surfaces such a death to the host.
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

    @Test("VOD eof with zero packets is not a fatal read exit")
    func eofIsNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .eof, isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }

    @Test("teardown exits are not fatal")
    func stopRequestedIsNotFatal() {
        #expect(!HLSVideoEngine.isFatalVODPumpExit(
            reason: .stopRequested, isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }
}
