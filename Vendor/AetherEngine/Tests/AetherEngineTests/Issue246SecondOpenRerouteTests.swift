import Testing
import Foundation
@testable import AetherEngine

/// AE#246: the load-time probe can fail for a transient reason that is not the HLS classification,
/// so `probeFailure` is inconclusive and the AE#154 reroute does not fire. The load then falls
/// through to the loopback path with a nil preopened demuxer, and `HLSVideoEngine.start()` reopens
/// the same URL. That second open is the first one to read the playlist body, so it is the one that
/// produces `AVIOReaderError.hlsPlaylistOnVODPath`.
///
/// Interpolating that typed error into `HLSVideoEngineError.openFailed(reason:)` erased the domain,
/// and a reroutable source died as a terminal `openFailed`. These cover the pure pieces: the open
/// failure mapping, and the reroute decision on the error the mapping now preserves.
struct Issue246SecondOpenRerouteTests {

    // MARK: - Open-failure mapping

    @Test("The VOD playlist classification survives the fallback open as a typed error")
    func vodPlaylistErrorPassesThrough() {
        let mapped = HLSVideoEngine.openFailure(from: AVIOReaderError.hlsPlaylistOnVODPath)
        #expect(mapped as? AVIOReaderError == .hlsPlaylistOnVODPath)
    }

    @Test("The raw-live classification also survives, keeping AE#140 typed at every open")
    func rawLiveErrorPassesThrough() {
        let mapped = HLSVideoEngine.openFailure(from: AVIOReaderError.hlsPlaylistOnRawLivePath)
        #expect(mapped as? AVIOReaderError == .hlsPlaylistOnRawLivePath)
    }

    @Test("Every other open failure keeps its openFailed(reason:) shape")
    func unrelatedErrorsStayWrapped() {
        let mapped = HLSVideoEngine.openFailure(from: DemuxerError.openFailed(code: -5))
        guard let engineError = mapped as? HLSVideoEngine.HLSVideoEngineError,
              case .openFailed(let reason) = engineError else {
            Issue.record("expected openFailed, got \(mapped)")
            return
        }
        #expect(reason.contains("openFailed"))
    }

    // MARK: - Reroute decision on the second-open error

    @Test("A second-open VOD classification is a reroute candidate")
    func secondOpenErrorReroutes() {
        let failure = HLSVideoEngine.openFailure(from: AVIOReaderError.hlsPlaylistOnVODPath)
        #expect(RemoteHLSMediaSelection.shouldReroute(failure: failure, isCustomSource: false))
    }

    @Test("A wrapped classification is not a reroute candidate, which is why it must not be wrapped")
    func wrappedErrorDoesNotReroute() {
        let wrapped = HLSVideoEngine.HLSVideoEngineError.openFailed(
            reason: "\(AVIOReaderError.hlsPlaylistOnVODPath)")
        #expect(!RemoteHLSMediaSelection.shouldReroute(failure: wrapped, isCustomSource: false))
    }

    @Test("A custom source still has no URL to reroute, whichever open produced the error")
    func customSourceNeverReroutes() {
        let failure = HLSVideoEngine.openFailure(from: AVIOReaderError.hlsPlaylistOnVODPath)
        #expect(!RemoteHLSMediaSelection.shouldReroute(failure: failure, isCustomSource: true))
    }

    @Test("The raw-live misroute keeps its AE#140 fail-closed contract after the fallback open")
    func rawLiveNeverReroutes() {
        let failure = HLSVideoEngine.openFailure(from: AVIOReaderError.hlsPlaylistOnRawLivePath)
        #expect(!RemoteHLSMediaSelection.shouldReroute(failure: failure, isCustomSource: false))
    }
}
