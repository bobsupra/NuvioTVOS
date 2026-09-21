import Foundation
import Testing
@testable import AetherEngine

/// #496 (RadicalMuffinMan): a field capture showed the forward prefetcher exiting seven seconds
/// into a session with `reason=cancelled cancelled=true` and never coming back, with playback
/// running on for another eight minutes. The exit line says a `cancel()` happened and nothing
/// else, and it lands whenever the parked loop next looks, so the cause had to be reconstructed
/// from what else happened to log nearby: a whole-file subtitle reader that opened 67 microseconds
/// later. Two rounds went into that reconstruction. These pin the routing that makes it a read.
struct Issue496PrefetchCancelReasonTests {

    @MainActor
    private func engineWithLivePrefetcher() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mov")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleDrainTargets[.primary] = 2
        engine.subtitleForwardPrefetchTask = Task {}
        return engine
    }

    @MainActor
    @Test("a sidecar taking over the primary names itself, not the mechanism it shares with teardown")
    func sidecarSelectionNamesItself() throws {
        let engine = try engineWithLivePrefetcher()
        engine.clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)
        #expect(engine.lastSubtitleDrainStopReason == .sidecarSelected)
        #expect(engine.subtitleForwardPrefetchTask == nil)
    }

    @MainActor
    @Test("session teardown is distinguishable from a track switch, which is the whole ambiguity")
    func sessionStopIsADifferentReason() throws {
        let engine = try engineWithLivePrefetcher()
        engine.stopSubtitleDrainer(reason: .sessionStopped)
        #expect(engine.lastSubtitleDrainStopReason == .sessionStopped)
    }

    @MainActor
    @Test("a rebuild is not a loss and says so")
    func rebuildIsItsOwnReason() throws {
        let engine = try engineWithLivePrefetcher()
        engine.cancelSubtitleForwardPrefetcher(reason: .prefetchRebuild)
        #expect(engine.lastSubtitleDrainStopReason == .prefetchRebuild)
    }

    @MainActor
    @Test("clearing the secondary while the primary still drains cancels nothing and claims nothing")
    func secondaryClearLeavesTheRunningPrefetcherAlone() throws {
        let engine = try engineWithLivePrefetcher()
        engine.subtitleDrainTargets[.secondary] = 3
        engine.clearSubtitleDrainTarget(channel: .secondary, reason: .secondarySidecarSelected)
        #expect(engine.lastSubtitleDrainStopReason == nil)
        #expect(engine.subtitleForwardPrefetchTask != nil)
        engine.subtitleForwardPrefetchTask?.cancel()
    }

    @MainActor
    @Test("a cancel with no prefetcher running claims no reason, so the field never reads a stale one")
    func noRunningTaskRecordsNothing() throws {
        let engine = try AetherEngine()
        engine.subtitleDrainTargets[.primary] = 2
        engine.clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)
        #expect(engine.lastSubtitleDrainStopReason == nil)
    }

    @MainActor
    @Test("every teardown route carries a reason of its own: the log cannot collapse two causes into one")
    func reasonsAreDistinct() {
        let all: [SubtitleDrainStopReason] = [
            .sidecarSelected, .secondarySidecarSelected, .externalStoreBackfill,
            .closedCaptionsSelected, .injectedRenditionSelected, .liveRenditionSelected,
            .subtitlesCleared, .sessionStopped, .prefetchRebuild,
        ]
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }
}
