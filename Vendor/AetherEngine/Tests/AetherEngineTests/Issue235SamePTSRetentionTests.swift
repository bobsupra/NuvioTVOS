import Testing
import Foundation
@testable import AetherEngine

/// #235: the SubtitlePacketStore treated a PTS as a unique key, so a second packet landing on an
/// already-occupied timestamp replaced the entry sitting there.
///
/// The premise was that a repeated PTS could only mean the pump and the forward prefetcher
/// re-harvesting the same packet (#151), which is a real overlap and does need collapsing. It is
/// not the only way two packets share a timestamp. ASS/SSA authors overlapping lines on identical
/// Start/End as a matter of course, and a karaoke or layered-style track emits many distinct
/// Dialogue events on one timestamp: the #56 measurement of a real track found 1534 packets on
/// exactly pts=5.207000. Every one of those but the last was discarded on write, so a heavily
/// styled track reached the renderer with most of its events missing.
///
/// A re-harvest is byte-identical to what it duplicates, which is the signature the store now
/// collapses on. Distinct payloads on one PTS are distinct cues and are all retained.
///
/// Reported by fivepandasna, who traced it to `appendLocked` from event counts in a host wrapper.
struct Issue235SamePTSRetentionTests {

    /// An ASS Dialogue line, distinct per index, in the shape the harvest actually stores.
    private func dialogue(_ index: Int, layer: Int = 0) -> Data {
        Data("\(index),\(layer),Default,,0,0,0,,{\\k42}line \(index)".utf8)
    }

    // MARK: - The regression

    @Test("two distinct payloads on one pts are both retained")
    func distinctPayloadsAtOnePtsAreBothRetained() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(1))
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(2))

        let got = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(got.count == 2)
        #expect(got.map(\.payload) == [dialogue(1), dialogue(2)])
    }

    /// The field shape: one timestamp carrying a whole burst of styled events.
    @Test("an ass same-pts burst retains every event")
    func assSamePtsBurstRetainsEveryEvent() {
        let store = SubtitlePacketStore()
        let burst = 512
        for i in 0..<burst {
            store.append(streamIndex: 4, ptsSeconds: 5.207, durationSeconds: 3,
                         payload: dialogue(i, layer: i % 8))
        }

        let got = store.entries(streamIndex: 4, from: 0, through: 10)
        #expect(got.count == burst)
        #expect(Set(got.map(\.payload)).count == burst)
    }

    @Test("a burst is drained in one window rather than one entry per pts")
    func burstIsVisibleToASingleDrainWindow() {
        let store = SubtitlePacketStore()
        for i in 0..<64 {
            store.append(streamIndex: 4, ptsSeconds: 5.207, durationSeconds: 3, payload: dialogue(i))
        }
        store.append(streamIndex: 4, ptsSeconds: 9.0, durationSeconds: 2, payload: dialogue(999))

        // The drainer scans an inclusive window and advances its cursor to the last decoded PTS,
        // so every entry on a shared timestamp has to come back from one query or the remainder
        // is skipped by the next tick's `.decode(from: lastDecodedPts.nextUp)`.
        let window = store.entries(streamIndex: 4, from: 0, through: 6)
        #expect(window.count == 64)
    }

    // MARK: - The overlap that still has to collapse

    @Test("a byte-identical re-harvest on one pts still collapses")
    func identicalPayloadAtOnePtsCollapses() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(1))
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(1))

        #expect(store.entries(streamIndex: 3, from: 0, through: 100).count == 1)
    }

    /// The pump and the prefetcher overlap on arbitrary members of a burst, not just the newest.
    @Test("a re-harvest collapses its own entry inside a same-pts run")
    func reHarvestCollapsesTheMatchingEntryInARun() {
        let store = SubtitlePacketStore()
        for i in 0..<8 {
            store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(i))
        }
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(3))

        let got = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(got.count == 8)
        #expect(got.map(\.payload) == (0..<8).map { dialogue($0) })
    }

    // MARK: - Byte accounting

    @Test("a collapsed re-harvest is counted once")
    func collapseKeepsByteAccountingExact() {
        let store = SubtitlePacketStore()
        let payload = dialogue(1)
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: payload)
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: payload)

        #expect(store.totalRetainedBytes == payload.count)
    }

    @Test("distinct payloads on one pts are both counted")
    func retainedBytesCoverEveryEntryOnAPts() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(1))
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(2))

        #expect(store.totalRetainedBytes == dialogue(1).count + dialogue(2).count)
    }

    // MARK: - Ordering invariants the drainer depends on

    @Test("entries stay sorted when a same-pts run sits between other timestamps")
    func samePtsRunStaysInsideTheSortedSequence() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 20, durationSeconds: 2, payload: dialogue(90))
        store.append(streamIndex: 3, ptsSeconds: 5, durationSeconds: 2, payload: dialogue(80))
        for i in 0..<4 {
            store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: dialogue(i))
        }

        let got = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(got.map(\.ptsSeconds) == [5, 10, 10, 10, 10, 20])
        #expect(got.map(\.payload) == [dialogue(80), dialogue(0), dialogue(1),
                                       dialogue(2), dialogue(3), dialogue(90)])
    }

    /// Harvest is near-monotonic, but the prefetcher backfills far behind the frontier, so the
    /// insert has to place by search rather than by assuming it appends at the end.
    @Test("a backfill far behind the frontier lands in sorted position")
    func backfillFarBehindTheFrontierLandsSorted() {
        let store = SubtitlePacketStore()
        for p in stride(from: 100.0, through: 400.0, by: 10.0) {
            store.append(streamIndex: 3, ptsSeconds: p, durationSeconds: 2, payload: dialogue(Int(p)))
        }
        store.append(streamIndex: 3, ptsSeconds: 155, durationSeconds: 2, payload: dialogue(1))
        store.append(streamIndex: 3, ptsSeconds: 5, durationSeconds: 2, payload: dialogue(2))

        let pts = store.entries(streamIndex: 3, from: 0, through: 1_000).map(\.ptsSeconds)
        #expect(pts == pts.sorted())
        #expect(pts.first == 5)
        #expect(pts.contains(155))
    }

    @Test("frontier reports the shared pts once a burst is stored")
    func frontierIsUnaffectedByABurst() {
        let store = SubtitlePacketStore()
        for i in 0..<16 {
            store.append(streamIndex: 3, ptsSeconds: 42, durationSeconds: 2, payload: dialogue(i))
        }
        #expect(store.frontier(streamIndex: 3) == 42)
    }

    // MARK: - The searched insert position

    @Test("lower bound finds the first index at or past a pts")
    func lowerBoundBoundaries() {
        func entries(_ pts: [Double]) -> [StoredSubtitlePacket] {
            pts.map { StoredSubtitlePacket(ptsSeconds: $0, durationSeconds: 1, flags: 0,
                                           payload: Data()) }
        }
        #expect(SubtitlePacketStore.lowerBound(entries([]), 10) == 0)
        #expect(SubtitlePacketStore.lowerBound(entries([20, 30]), 10) == 0)
        #expect(SubtitlePacketStore.lowerBound(entries([1, 2]), 10) == 2)
        #expect(SubtitlePacketStore.lowerBound(entries([1, 10, 20]), 10) == 1)
        #expect(SubtitlePacketStore.lowerBound(entries([1, 5, 20]), 10) == 2)
        // A run of equals resolves to its FIRST member, so the duplicate probe sees all of it.
        #expect(SubtitlePacketStore.lowerBound(entries([1, 10, 10, 10, 20]), 10) == 1)
        #expect(SubtitlePacketStore.lowerBound(entries([10, 10, 10]), 10) == 0)
    }

    /// The searched position has to agree with a linear scan for every input, including the
    /// out-of-order arrivals the prefetcher produces.
    @Test("lower bound agrees with a linear scan over a mixed sequence")
    func lowerBoundMatchesLinearScan() {
        let store = SubtitlePacketStore()
        var stored: [Double] = []
        for p in [50.0, 10.0, 10.0, 90.0, 30.0, 10.0, 70.0, 30.0] {
            store.append(streamIndex: 3, ptsSeconds: p, durationSeconds: 1,
                         payload: dialogue(stored.count))
            stored.append(p)
        }
        let entries = store.entries(streamIndex: 3, from: -1, through: 1_000)
        for probe in [0.0, 10.0, 20.0, 30.0, 50.0, 70.0, 90.0, 100.0] {
            let expected = entries.firstIndex { $0.ptsSeconds >= probe } ?? entries.count
            #expect(SubtitlePacketStore.lowerBound(entries, probe) == expected)
        }
    }

    // MARK: - Retention still bounds a burst

    @Test("the per-stream cap still evicts oldest first when a burst exceeds it")
    func burstStillRespectsThePerStreamCap() {
        let store = SubtitlePacketStore(perStreamByteCap: 4_096, aggregateByteCap: 1 << 20)
        let chunk = Data(repeating: 0xAB, count: 512)
        for i in 0..<32 {
            store.append(streamIndex: 3, ptsSeconds: Double(i), durationSeconds: 1,
                         payload: chunk + Data([UInt8(i)]))
        }
        #expect(store.totalRetainedBytes <= 4_096)
        // Oldest-first eviction: what survives is the tail of the sequence.
        let pts = store.entries(streamIndex: 3, from: 0, through: 1_000).map(\.ptsSeconds)
        #expect(pts.last == 31)
        #expect(pts == pts.sorted())
    }
}
