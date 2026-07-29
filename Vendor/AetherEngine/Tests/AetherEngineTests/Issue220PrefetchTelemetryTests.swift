import Foundation
import Testing
@testable import AetherEngine

/// #220 (rrgomes): server-side per-connection byte totals showed the #151 subtitle prefetcher
/// consuming 2.6x media rate at playhead + 333 s against a 60 s lead allowance, while the pump
/// on the same session stayed exactly paced. The lead is visible on the wire minutes before the
/// process dies, so it belongs in our own periodic line. These cover the two formatters only;
/// the live state is written from the prefetch task and read from the main actor.
struct Issue220PrefetchTelemetryTests {

    // MARK: - Prefetch fragment

    @Test("a session that never ran reads as off, not as a zero lead")
    func neverRanReadsOff() {
        let fragment = SubtitlePrefetchTelemetry.format(
            SubtitlePrefetchTelemetry.Snapshot(), playhead: 120)
        #expect(fragment == "prefetch=off ")
    }

    /// The whole point of the field: 333 s of lead against a 60 s allowance has to be legible
    /// as a number, not inferred from a state word.
    @Test("a running session reports the lead over the playhead")
    func runningReportsLead() {
        var snapshot = SubtitlePrefetchTelemetry.Snapshot()
        snapshot.running = true
        snapshot.lastPacketSeconds = 1899
        snapshot.harvested = 412
        let fragment = SubtitlePrefetchTelemetry.format(snapshot, playhead: 1566)
        #expect(fragment.contains("prefetch=read "))
        #expect(fragment.contains("prefetchLead=333.0s "))
        #expect(fragment.contains("prefetchHarvested=412 "))
        #expect(fragment.contains("prefetchTbFallback=0 "))
    }

    @Test("a parked session is distinguishable from a reading one")
    func parkedIsDistinct() {
        var snapshot = SubtitlePrefetchTelemetry.Snapshot()
        snapshot.running = true
        snapshot.parked = true
        snapshot.lastPacketSeconds = 1626
        let fragment = SubtitlePrefetchTelemetry.format(snapshot, playhead: 1566)
        #expect(fragment.contains("prefetch=park "))
        #expect(fragment.contains("prefetchLead=60.0s "))
    }

    /// Defect 4: the loop exits on any read error and nothing restarts it until a seek. A
    /// session that harvested and then stopped must not read the same as one never started.
    @Test("a session that failed mid-playback is distinguishable from one never started")
    func failedSessionReported() {
        var snapshot = SubtitlePrefetchTelemetry.Snapshot()
        snapshot.running = false
        snapshot.harvested = 22
        snapshot.lastPacketSeconds = 800
        snapshot.exit = .readFailed
        let fragment = SubtitlePrefetchTelemetry.format(snapshot, playhead: 700)
        #expect(fragment.contains("prefetch=failed "))
        #expect(fragment.contains("prefetchHarvested=22 "))
    }

    /// The reader works `leadSeconds` ahead, so it reaches EOF a full lead before the playhead
    /// does and EVERY completed playback ends with the loop gone. Reporting that the same way as
    /// a mid-stream failure made the signal fire over the closing minute of every film, which is
    /// exactly when it is least useful.
    @Test("reaching end of file is not reported as a failure")
    func endOfFileNotAFailure() {
        var snapshot = SubtitlePrefetchTelemetry.Snapshot()
        snapshot.running = false
        snapshot.harvested = 416
        snapshot.lastPacketSeconds = 1400
        snapshot.exit = .endOfFile
        let fragment = SubtitlePrefetchTelemetry.format(snapshot, playhead: 1362.5)
        #expect(fragment.contains("prefetch=eof "))
        #expect(!fragment.contains("failed"))
    }

    @Test("no packet seen yet reports no lead rather than a garbage one")
    func noPacketYetHasNoLead() {
        var snapshot = SubtitlePrefetchTelemetry.Snapshot()
        snapshot.running = true
        let fragment = SubtitlePrefetchTelemetry.format(snapshot, playhead: 120)
        #expect(fragment.contains("prefetchLead=n/as "))
    }

    /// Defect 2: a 0/1 time-base fallback skips the park guard for that packet. The counter
    /// says whether that path was ever taken in a session, which decides whether it is the
    /// mechanism behind an unsettled lead or an unrelated latent bug.
    @Test("time-base fallbacks are counted")
    func timeBaseFallbacksCounted() {
        var snapshot = SubtitlePrefetchTelemetry.Snapshot()
        snapshot.running = true
        snapshot.timeBaseFallbacks = 3
        let fragment = SubtitlePrefetchTelemetry.format(snapshot, playhead: 0)
        #expect(fragment.contains("prefetchTbFallback=3 "))
    }

    // MARK: - Reader window fragment

    @Test("no reader emits nothing")
    func noReaderEmitsNothing() {
        #expect(AetherEngine.readerWindowFragment(pump: nil, prefetch: nil).isEmpty)
    }

    /// The discriminator the kill needs: `ahead` far above winHighWater with `Susp=0` is
    /// backpressure that never engaged, not a transport overshoot past a suspend that did.
    @Test("both readers report window, ahead and suspend state")
    func bothReadersReported() {
        let fragment = AetherEngine.readerWindowFragment(
            pump: (windowBytes: 12 * 1024 * 1024, aheadBytes: 8 * 1024 * 1024,
                   suspended: false, postSuspendBytes: 0),
            prefetch: (windowBytes: 1024 * 1024 * 1024, aheadBytes: 1020 * 1024 * 1024,
                       suspended: false, postSuspendBytes: 0))
        #expect(fragment.contains("pumpWinMB=12 "))
        #expect(fragment.contains("pumpAheadMB=8 "))
        #expect(fragment.contains("pumpSusp=0 "))
        #expect(fragment.contains("prefWinMB=1024 "))
        #expect(fragment.contains("prefAheadMB=1020 "))
        #expect(fragment.contains("prefSusp=0 "))
    }

    @Test("a suspended reader is flagged")
    func suspendedReaderFlagged() {
        let fragment = AetherEngine.readerWindowFragment(
            pump: nil,
            prefetch: (windowBytes: 17 * 1024 * 1024, aheadBytes: 17 * 1024 * 1024,
                       suspended: true, postSuspendBytes: 1024 * 1024))
        #expect(!fragment.contains("pump"))
        #expect(fragment.contains("prefSusp=1 "))
    }

    /// #220: the quantity that decided the issue. A suspend that works leaves `PostMB` at the
    /// transport's in-flight amount; one that does not leaves it tracking the whole window, and
    /// the two are only distinguishable because this is reported separately from `AheadMB`.
    @Test("post-suspend delivery is reported per reader")
    func postSuspendDeliveryReported() {
        let fragment = AetherEngine.readerWindowFragment(
            pump: (windowBytes: 16 * 1024 * 1024, aheadBytes: 16 * 1024 * 1024,
                   suspended: true, postSuspendBytes: 2 * 1024 * 1024),
            prefetch: (windowBytes: 612 * 1024 * 1024, aheadBytes: 609 * 1024 * 1024,
                       suspended: true, postSuspendBytes: 911 * 1024 * 1024))
        #expect(fragment.contains("pumpPostMB=2 "))
        #expect(fragment.contains("prefPostMB=911 "))
    }
}
