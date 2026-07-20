import Testing
import Foundation
@testable import AetherEngine

/// #125: the playhead-paced drainer must not time-prune the SubtitlePacketStore.
///
/// A backward seek into segment-cache-resident content is served without a producer restart
/// (the segment cache answers the region; the pump is the store's ONLY writer and stays parked
/// forward), so the pump never re-harvests that region. The old trailing playhead-relative prune
/// (`store.prune(before: playhead - 300)`, run every drain tick) evicted those packets while the
/// playhead was still far ahead, and once the packets were gone the drain window landed
/// permanently empty: cues stopped rendering and re-arming any track logged "backfilled 0 cues".
///
/// Retention is now byte-bounded (`perStreamByteCap`, evict-oldest per stream) instead of
/// time-bounded, mirroring the segment cache retaining history for backward seeks. Text tracks
/// keep the whole session; bitmap tracks keep a wide trailing window.
@MainActor
struct Issue125PacketStoreRetentionTests {

    private func makeLoadedEngine(store: SubtitlePacketStore) throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = store
        return engine
    }

    /// The core regression: a drain tick at a far-forward playhead must leave an early region's
    /// packets in the store. Pre-fix the tick pruned `before: 795 - 300 = 495`, dropping the
    /// 200-220 s region a later backward seek would need.
    @Test("drain tick retains packets a far-forward playhead moved well past")
    func drainTickDoesNotTimePruneBehindPlayhead() throws {
        let store = SubtitlePacketStore()
        for p in stride(from: 200.0, through: 220.0, by: 2.0) {
            store.append(streamIndex: 5, ptsSeconds: p, durationSeconds: 2, payload: Data([0x01]))
        }
        let engine = try makeLoadedEngine(store: store)
        engine.subtitleDrainTargets[.primary] = 5
        engine.clock.sourceTime = 795.0   // forward chase, old prune cutoff would be 495 s

        engine.subtitleDrainTick()

        let survived = store.entries(streamIndex: 5, from: 200, through: 220).map(\.ptsSeconds)
        #expect(survived == [200, 202, 204, 206, 208, 210, 212, 214, 216, 218, 220])
    }

    /// The reported sequence end to end: forward chase, tick, then scrub back into the early
    /// region. The region's packets must still be present for the drainer to decode.
    @Test("backward seek after a forward-chase tick still finds the region's packets")
    func backwardSeekAfterChaseFindsPackets() throws {
        let store = SubtitlePacketStore()
        for p in stride(from: 200.0, through: 220.0, by: 2.0) {
            store.append(streamIndex: 5, ptsSeconds: p, durationSeconds: 2, payload: Data([0x01]))
        }
        let engine = try makeLoadedEngine(store: store)
        engine.subtitleDrainTargets[.primary] = 5
        engine.clock.sourceTime = 795.0
        engine.subtitleDrainTick()        // pre-fix: prunes the 200-220 s region here

        engine.clock.sourceTime = 213.0   // scrub back into cache-resident content
        let window = store.entries(streamIndex: 5, from: 205, through: 217).map(\.ptsSeconds)
        #expect(window == [206, 208, 210, 212, 214, 216])
    }

    /// Removing the time-prune must not mean unbounded growth: the per-stream byte cap still
    /// bounds a bitmap-sized stream, evicting the oldest packets first.
    @Test("byte cap still bounds a large stream after the time-prune is gone")
    func byteCapStillBoundsGrowth() throws {
        let store = SubtitlePacketStore()
        let big = SubtitlePacketStore.perStreamByteCap / 3
        for p in [10.0, 20.0, 30.0, 40.0] {
            store.append(streamIndex: 7, ptsSeconds: p, durationSeconds: 2,
                         payload: Data(repeating: 0, count: big))
        }
        let remaining = store.entries(streamIndex: 7, from: 0, through: 1_000).map(\.ptsSeconds)
        #expect(remaining.first != 10)      // oldest evicted
        #expect(remaining.contains(40))     // newest kept
    }
}
