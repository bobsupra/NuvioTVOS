import Foundation
import Testing
@testable import AetherEngine

/// #112 packet-tap follow-up: on Blu-ray MPEG-TS a PGS display set spans several PES packets
/// (PCS|WDS|PDS|ODS|END), some without a PTS of their own and some sharing one. The store must
/// reassemble those chunks into ONE self-contained entry at the PCS presentation PTS; storing
/// them per-packet drops the palette/object segments and every set dies with
/// "Invalid palette id" at its END (remote-ISO regression, 0.9.22).
struct Issue112PGSDisplaySetAssemblyTests {
    private static let stream: Int32 = 22

    /// `[type:1][length:2 BE][body]`, bodies filled with a marker byte per type for payload checks.
    private func seg(_ type: UInt8, bodyLen: Int) -> Data {
        var d = Data([type, UInt8((bodyLen >> 8) & 0xFF), UInt8(bodyLen & 0xFF)])
        d.append(Data(repeating: type, count: bodyLen))
        return d
    }

    private var pcs: Data { seg(0x16, bodyLen: 11) }
    private var wds: Data { seg(0x17, bodyLen: 10) }
    private var pds: Data { seg(0x14, bodyLen: 7) }
    private var ods: Data { seg(0x15, bodyLen: 20) }
    private var end: Data { seg(0x80, bodyLen: 0) }

    private func harvest(_ store: SubtitlePacketStore, _ payload: Data, pts: Double?,
                         flags: Int32 = 0) {
        store.harvestChunk(streamIndex: Self.stream, ptsSeconds: pts, durationSeconds: 0,
                           flags: flags, payload: payload, assembleSplitDisplaySets: true)
    }

    private func stored(_ store: SubtitlePacketStore) -> [StoredSubtitlePacket] {
        store.entries(streamIndex: Self.stream, from: -1_000, through: 1_000_000)
    }

    @Test("split set (NOPTS intermediates) assembles into one entry at the PCS pts")
    func splitSetAssembles() {
        let store = SubtitlePacketStore()
        harvest(store, pcs, pts: 100.0)
        harvest(store, wds, pts: nil)
        harvest(store, pds, pts: nil)
        harvest(store, ods, pts: nil)
        harvest(store, end, pts: nil)
        let got = stored(store)
        #expect(got.count == 1)
        #expect(got.first?.ptsSeconds == 100.0)
        #expect(got.first?.payload == pcs + wds + pds + ods + end)
    }

    @Test("segments sharing one pts do not collapse into the last one")
    func samePtsSegmentsSurvive() {
        let store = SubtitlePacketStore()
        for chunk in [pcs, wds, pds, ods, end] {
            harvest(store, chunk, pts: 100.0)
        }
        let got = stored(store)
        #expect(got.count == 1)
        #expect(got.first?.payload == pcs + wds + pds + ods + end)
    }

    @Test("a single-packet complete set stores unchanged")
    func completeSetPassesThrough() {
        let store = SubtitlePacketStore()
        let full = pcs + wds + pds + ods + end
        harvest(store, full, pts: 50.0)
        let got = stored(store)
        #expect(got.count == 1)
        #expect(got.first?.ptsSeconds == 50.0)
        #expect(got.first?.payload == full)
    }

    @Test("restart re-harvest of the same set dedups to one entry")
    func restartReharvestDedups() {
        let store = SubtitlePacketStore()
        for _ in 0..<2 {
            harvest(store, pcs, pts: 100.0)
            harvest(store, ods, pts: nil)
            harvest(store, end, pts: 100.0)
        }
        let got = stored(store)
        #expect(got.count == 1)
        #expect(got.first?.payload == pcs + ods + end)
    }

    @Test("mid-set backfill start (no PCS seen) is dropped, not stored broken")
    func midSetBackfillDropped() {
        let store = SubtitlePacketStore()
        harvest(store, ods, pts: nil)
        harvest(store, end, pts: 100.0)
        #expect(stored(store).isEmpty)
    }

    @Test("a set missing its END is dropped when the next PCS arrives")
    func missingEndDroppedOnNextPCS() {
        let store = SubtitlePacketStore()
        harvest(store, pcs, pts: 10.0)
        harvest(store, ods, pts: nil)
        harvest(store, pcs, pts: 20.0)
        harvest(store, end, pts: nil)
        let got = stored(store)
        #expect(got.map(\.ptsSeconds) == [20.0])
        #expect(got.first?.payload == pcs + end)
    }

    @Test("a PCS chunk without a pts cannot anchor a set; the set is skipped")
    func noPtsAnchorSkipsSet() {
        let store = SubtitlePacketStore()
        harvest(store, pcs, pts: nil)
        harvest(store, ods, pts: nil)
        harvest(store, end, pts: nil)
        #expect(stored(store).isEmpty)
    }

    @Test("SUP-style PG headers are stripped per chunk before concatenation")
    func pgHeaderStripped() {
        let store = SubtitlePacketStore()
        func wrapped(_ payload: Data) -> Data {
            Data([0x50, 0x47, 0, 0, 0, 0, 0, 0, 0, 0]) + payload
        }
        harvest(store, wrapped(pcs), pts: 100.0)
        harvest(store, wrapped(ods + end), pts: nil)
        let got = stored(store)
        #expect(got.count == 1)
        #expect(got.first?.payload == pcs + ods + end)
    }

    @Test("END followed by the next set's PCS in one chunk splits into two entries")
    func endPlusNextPcsSplits() {
        let store = SubtitlePacketStore()
        harvest(store, pcs + ods, pts: 10.0)
        harvest(store, end + pcs, pts: 12.0)
        harvest(store, end, pts: nil)
        let got = stored(store)
        #expect(got.map(\.ptsSeconds) == [10.0, 12.0])
        #expect(got[0].payload == pcs + ods + end)
        #expect(got[1].payload == pcs + end)
    }

    @Test("a runaway pending set is dropped at the byte cap")
    func pendingCapDrops() {
        let store = SubtitlePacketStore()
        harvest(store, pcs, pts: 100.0)
        let bigBody = SubtitlePacketStore.maxPendingDisplaySetBytes
        harvest(store, seg(0x15, bodyLen: bigBody), pts: nil)
        harvest(store, end, pts: nil)
        #expect(stored(store).isEmpty)
    }

    @Test("a backward pts jump while a set is pending drops the stale pending")
    func backwardJumpDropsPending() {
        let store = SubtitlePacketStore()
        harvest(store, pcs, pts: 100.0)
        harvest(store, ods, pts: nil)
        harvest(store, pcs, pts: 50.0)
        harvest(store, end, pts: nil)
        let got = stored(store)
        #expect(got.map(\.ptsSeconds) == [50.0])
    }

    @Test("flags of all chunks in a set are OR-folded into the stored entry")
    func flagsFold() {
        let store = SubtitlePacketStore()
        harvest(store, pcs, pts: 100.0, flags: 0x1)
        harvest(store, ods, pts: nil, flags: 0x4)
        harvest(store, end, pts: nil)
        #expect(stored(store).first?.flags == 0x5)
    }

    @Test("un-armed streams keep the per-packet path: NOPTS drops, same-pts replaces")
    func unarmedKeepsLegacyBehavior() {
        let store = SubtitlePacketStore()
        store.harvestChunk(streamIndex: 3, ptsSeconds: nil, durationSeconds: 0,
                           flags: 0, payload: pcs, assembleSplitDisplaySets: false)
        store.harvestChunk(streamIndex: 3, ptsSeconds: 10, durationSeconds: 0,
                           flags: 0, payload: Data([1]), assembleSplitDisplaySets: false)
        store.harvestChunk(streamIndex: 3, ptsSeconds: 10, durationSeconds: 0,
                           flags: 0, payload: Data([2, 2]), assembleSplitDisplaySets: false)
        let got = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(got.count == 1)
        #expect(got.first?.payload == Data([2, 2]))
    }

    @Test("clear resets pending assembly state")
    func clearResetsPending() {
        let store = SubtitlePacketStore()
        harvest(store, pcs, pts: 100.0)
        store.clear()
        harvest(store, ods, pts: nil)
        harvest(store, end, pts: nil)
        #expect(stored(store).isEmpty)
    }
}
