import Foundation
import Testing
@testable import AetherEngine

/// AE#443: a session counter has to describe the session.
///
/// The reporter of #443 read a fall in the CLI's `rx=` as evidence that the engine had swapped its
/// origin socket under a deep live rewind, and built a server-side theory on top of it. The socket
/// swap never happened (one `pump conn start` for the whole campaign, on their logs and on the
/// harness), and neither did the producer restart the fall was then attributed to. What fell was an
/// `AVPlayerItemAccessLogEvent` boundary: those counters are totals PER ENTRY, and AVFoundation opens
/// a new entry whenever the playback session changes under it.
///
/// Measured before the fix on the live loopback harness, one origin connection and no restart in the
/// whole run: `rx` went 3.4 MB -> 2.2 MB -> 0.6 MB and `drop` 44 -> 0, mid-session, while playing.
struct Issue443SessionCounterTests {

    @Test("a per-entry counter reads as the session's total, not as the newest entry's")
    func sumsAcrossEntries() {
        // The shape of the defect: entry 2 opened mid-session and is still filling.
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(3_600_000), 2_300_000]) == 5_900_000)
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [44, 0]) == 44)
    }

    @Test("a single entry still reads as itself")
    func singleEntry() {
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(1_100_000)]) == 1_100_000)
    }

    @Test("entries that cannot report the field are skipped, not clamped into the total")
    func skipsUnavailableEntries() {
        // AVFoundation reports an unavailable counter as a negative, and clamping it to 0 would let a
        // known-unknown entry read as a measured zero.
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(10), -1, 5]) == 15)
    }

    @Test("nothing measurable stays nil, which is not the same as a measured zero")
    func nilWhenNothingMeasurable() {
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int64(-1), -1]) == nil)
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [Int]()) == nil)
    }

    @Test("a measured zero is reported as zero")
    func measuredZero() {
        #expect(LiveTelemetrySampler.sessionTotal(perEntry: [0, 0]) == 0)
    }

    // MARK: - Round 2: the same scope error one layer further out

    /// The reporter's 6.53.0 re-run: summing the entries fixed the fall inside one item, and the
    /// number still restarted when the #93 stage-2 recovery replaced the ITEM under a session that
    /// never stopped (1229.1 MB, the field absent for the swap, then 34.3 MB). An item's access log
    /// holds only its own entries, so the host has to carry what the retired ones transferred.
    @Test("a swapped item's total carries into the session's")
    func foldsRetiredItems() {
        #expect(LiveTelemetrySampler.foldRetired(Int64(34_300_000), retired: 1_229_100_000)
                == 1_263_400_000)
    }

    @Test("the swap gap reports the total so far rather than nothing")
    func gapReportsRetiredTotal() {
        // Between the two items there is no current item to read, and publishing nil there is what
        // made the field vanish from the tick line mid-session.
        #expect(LiveTelemetrySampler.foldRetired(nil, retired: Int64(1_229_100_000)) == 1_229_100_000)
    }

    @Test("nothing measurable and nothing retired stays nil")
    func nilStaysNilBeforeAnySwap() {
        // A path that cannot report the field at all must not start reading as a measured zero just
        // because the fold exists.
        #expect(LiveTelemetrySampler.foldRetired(nil, retired: Int64(0)) == nil)
    }

    @Test("a measured zero on a fresh item still adds to what came before")
    func freshItemZeroKeepsTheTotal() {
        #expect(LiveTelemetrySampler.foldRetired(Int64(0), retired: 1_229_100_000) == 1_229_100_000)
    }
}
