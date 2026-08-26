import Foundation

/// AE#406: the live no-cut stall decision, held off the read thread it judges.
///
/// The decision used to be evaluated inline at the top of `HLSSegmentProducer`'s read loop, which
/// meant it could only run between `av_read_frame` calls. `av_read_frame` does not return before a
/// whole packet is assembled and carries no `interrupt_callback`, so an origin too slow to complete
/// one packet inside the watchdog window did not make the watchdog late, it made it unable to run:
/// measured on a trickling origin, a 35 s window fired at 48 s, 30 ms after a 46.9 s read finally
/// returned. Same shape as the reader-side defect #309, where the precondition that had to go was
/// "a consumer must be blocked on it".
///
/// So the window lives here instead. The pump thread reports what it reads (`note…`), a timer asks
/// for a verdict (`evaluate`), and both meet under one lock. The classifier itself is unchanged and
/// still `HLSSegmentProducer.noCutStallAction`.
///
/// Two properties the caller depends on:
///
/// - **The exit is a latch.** `evaluate` returns `.exitForRetune` exactly once, and nothing clears
///   it afterwards. A finalize that lands in the microseconds between the verdict and the abort
///   does not un-decide it: the pump is already on its way out, and a retune one segment late is
///   the same outcome the inline watchdog produced.
/// - **A parked pump is not judged.** The live headroom park sleeps the read thread on purpose,
///   for a consumer that stopped polling. Counting that time would report a dead consumer as a
///   dead source, so the park brackets it with `setReading(false:)` / `setReading(true:)` and the
///   window re-anchors on release.
final class NoCutStallWatchdog: @unchecked Sendable {

    /// One verdict's view of the window, for the line the caller logs. Carries every number the
    /// inline watchdog used to print, so the log vocabulary does not change with the position.
    struct Window: Equatable {
        var stalledFor: TimeInterval
        var packetsRead: Int
        var progress: Int
        var readRate: Double
        var videoPtsAdvanceSeconds: Double
        var videoPackets: Int
        var videoKeyframes: Int
        var audioPackets: Int
        var foreignPackets: Int
        var lastForeignStreamIndex: Int32
        var consecutiveHolds: Int

        /// Reads at full rate with nothing cut: a wedged cutter rather than a starved source.
        var isWedge: Bool { readRate >= HLSSegmentProducer.liveWedgeProgressRateThreshold }
    }

    enum Decision: Equatable {
        case holdForSlowDelivery(Window)
        case exitForRetune(Window)
    }

    private let lock = NSLock()
    private let videoTimeBaseSeconds: Double

    /// Wall-clock of the last finalized live segment. Nil until the first one: before that there is
    /// no window and nothing to judge.
    private var lastFinalizeAt: Date?
    /// #177 hold: the window measures from here once a slow-delivery hold has re-armed it.
    private var holdRearmedAt: Date?
    private var consecutiveHolds = 0
    private var reading = true
    private var exitLatched = false

    private var packetsRead = 0
    private var packetsReadAtWindowStart = 0
    private var videoPackets = 0
    private var videoKeyframes = 0
    private var audioPackets = 0
    private var foreignPackets = 0
    private var lastForeignStreamIndex: Int32 = -1
    private var firstVideoPts: Int64 = Int64.min
    private var lastVideoPts: Int64 = Int64.min

    init(videoTimeBaseSeconds: Double) {
        self.videoTimeBaseSeconds = videoTimeBaseSeconds
    }

    // MARK: - Pump thread

    /// A live segment was finalized: the window starts over from this instant.
    func noteFinalize(at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        lastFinalizeAt = now
        holdRearmedAt = nil
        consecutiveHolds = 0
        resetWindowCounters()
    }

    func notePacketRead() {
        lock.lock()
        packetsRead += 1
        lock.unlock()
    }

    func noteVideoPacket(pts: Int64, isKeyframe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        videoPackets += 1
        if isKeyframe { videoKeyframes += 1 }
        guard pts != Int64.min else { return }
        if firstVideoPts == Int64.min { firstVideoPts = pts }
        lastVideoPts = pts
    }

    func noteAudioPacket() {
        lock.lock()
        audioPackets += 1
        lock.unlock()
    }

    func noteForeignPacket(streamIndex: Int32) {
        lock.lock()
        foreignPackets += 1
        lastForeignStreamIndex = streamIndex
        lock.unlock()
    }

    /// Brackets a deliberate park of the read thread. Releasing re-anchors the window: the pump was
    /// not reading because it was told not to, which is not a statement about the source.
    func setReading(_ isReading: Bool, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard isReading != reading else { return }
        reading = isReading
        if isReading {
            holdRearmedAt = now
            resetWindowCounters()
        }
    }

    // MARK: - Timer thread

    var hasLatchedExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitLatched
    }

    /// One evaluation. Returns nil while there is nothing to say: not armed, parked, already
    /// latched, or simply healthy.
    func evaluate(now: Date) -> Decision? {
        lock.lock()
        defer { lock.unlock() }
        guard !exitLatched, reading, let finalizeAt = lastFinalizeAt else { return nil }
        let stalledFor = now.timeIntervalSince(holdRearmedAt ?? finalizeAt)
        let progress = packetsRead - packetsReadAtWindowStart
        let readRate = stalledFor > 0 ? Double(progress) / stalledFor : 0
        let ptsAdvance = (firstVideoPts != Int64.min && lastVideoPts != Int64.min
                          && videoTimeBaseSeconds > 0)
            ? Double(lastVideoPts - firstVideoPts) * videoTimeBaseSeconds
            : -1
        switch HLSSegmentProducer.noCutStallAction(
            stalledFor: stalledFor,
            readRate: readRate,
            videoPtsAdvanceSeconds: ptsAdvance,
            consecutiveHolds: consecutiveHolds
        ) {
        case .keepReading:
            return nil
        case .holdForSlowDelivery:
            consecutiveHolds += 1
            let window = makeWindow(stalledFor: stalledFor, progress: progress,
                                    readRate: readRate, ptsAdvance: ptsAdvance)
            holdRearmedAt = now
            resetWindowCounters()
            return .holdForSlowDelivery(window)
        case .exitForRetune:
            exitLatched = true
            return .exitForRetune(makeWindow(stalledFor: stalledFor, progress: progress,
                                             readRate: readRate, ptsAdvance: ptsAdvance))
        }
    }

    // MARK: - Private

    private func makeWindow(stalledFor: TimeInterval, progress: Int,
                            readRate: Double, ptsAdvance: Double) -> Window {
        Window(
            stalledFor: stalledFor,
            packetsRead: packetsRead,
            progress: progress,
            readRate: readRate,
            videoPtsAdvanceSeconds: ptsAdvance,
            videoPackets: videoPackets,
            videoKeyframes: videoKeyframes,
            audioPackets: audioPackets,
            foreignPackets: foreignPackets,
            lastForeignStreamIndex: lastForeignStreamIndex,
            consecutiveHolds: consecutiveHolds
        )
    }

    private func resetWindowCounters() {
        packetsReadAtWindowStart = packetsRead
        videoPackets = 0
        videoKeyframes = 0
        audioPackets = 0
        foreignPackets = 0
        lastForeignStreamIndex = -1
        firstVideoPts = Int64.min
        lastVideoPts = Int64.min
    }
}
