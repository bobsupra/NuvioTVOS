import Foundation
import Testing
@testable import AetherEngine

/// Covers the machine-readable failure companion (#376). The gap it closes: `PlaybackState.error`
/// carries one string, and on the native paths that string is `AVPlayerItem.error.localizedDescription`
/// forwarded verbatim, so a host classifying its failures was substring-matching text the OS had
/// already translated. The kind and the underlying domain / code are what survive a locale.
@Suite("PlaybackErrorInfo (#376)")
struct PlaybackErrorInfoTests {

    @Test("An underlying NSError contributes its domain and code")
    func capturesUnderlying() {
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12939)
        let info = PlaybackErrorInfo(kind: .nativeItemFailed,
                                     message: underlying.localizedDescription,
                                     underlying: underlying)
        #expect(info.kind == .nativeItemFailed)
        #expect(info.underlyingDomain == "CoreMediaErrorDomain")
        #expect(info.underlyingCode == -12939)
    }

    @Test("An engine-authored failure has no underlying domain, which is how a host tells the halves apart")
    func engineAuthoredHasNoUnderlying() {
        let info = PlaybackErrorInfo(kind: .liveSourceUnavailable, message: "Live source unavailable")
        #expect(info.underlyingDomain == nil)
        #expect(info.underlyingCode == nil)
        // The same constructor path the hosts use when there is nothing underneath.
        let fromNilError = PlaybackErrorInfo(kind: .liveSourceUnavailable,
                                             message: "Live source unavailable",
                                             underlying: nil)
        #expect(fromNilError == info)
    }

    /// The raw values are API: a host ships them into an analytics bucket, so a rename is a silent
    /// break in someone else's histogram rather than a compile error here.
    @Test("Kind raw values are the published tokens and are distinct")
    func rawValuesAreStableAndDistinct() {
        let kinds: [PlaybackErrorKind] = [
            .sourceOpenFailed, .sourceRefused, .customSourceProbeFailed, .liveSourceUnavailable,
            .hlsPlaylistOnRawLivePath, .dolbyVisionRequiresHardware, .demuxedAudioLiveUnsupported,
            .nativeItemFailed, .noPlayableTrackWithinBudget, .masterPlaylistRejected,
            .vodSourceFailed, .softwarePipelineFailed, .audioSessionFailed,
            .reloadFailed, .liveReloadNeverReady, .audioTrackSwitchFailed,
        ]
        #expect(Set(kinds.map(\.rawValue)).count == kinds.count)
        #expect(PlaybackErrorKind.nativeItemFailed.rawValue == "nativeItemFailed")
        #expect(PlaybackErrorKind(rawValue: "nativeItemFailed") == .nativeItemFailed)
    }

    @MainActor
    @Test("publishError assigns the info BEFORE the state, so a $state sink reads this failure's own")
    func infoIsVisibleFromAStateSink() throws {
        let engine = try AetherEngine()
        var seen: [PlaybackErrorInfo?] = []
        let token = engine.$state
            .dropFirst()                        // the replay of .idle belongs to no failure
            .sink { _ in seen.append(engine.errorInfo) }
        defer { token.cancel() }

        engine.publishError(.liveSourceUnavailable, "Live source unavailable")

        #expect(seen.count == 1)
        #expect(seen.first??.kind == .liveSourceUnavailable)
        #expect(engine.state == .error("Live source unavailable"))
    }

    @MainActor
    @Test("The info dies with the failure it describes")
    func clearedWhenTheStateLeavesError() throws {
        let engine = try AetherEngine()
        engine.publishError(.reloadFailed, "Reload failed: nope")
        #expect(engine.errorInfo?.kind == .reloadFailed)

        engine.state = .loading
        #expect(engine.errorInfo == nil)
    }

    /// The funnel is the reason a published `.error` can never arrive without its classification. A new
    /// failure site that assigns `state` directly would compile, run, and publish an unclassifiable
    /// error, which is exactly the shape this issue exists to remove.
    @Test("Nothing outside the funnel publishes .error")
    func onlyTheFunnelPublishesError() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)

        let assignment = try NSRegularExpression(pattern: #"state\s*=\s*\.error\("#)
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "PlaybackErrorInfo.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = assignment.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if hits > 0 { offenders.append("\(file.lastPathComponent) (\(hits))") }
        }
        #expect(offenders.isEmpty, "publish these through publishError instead: \(offenders.joined(separator: ", "))")
    }
}
