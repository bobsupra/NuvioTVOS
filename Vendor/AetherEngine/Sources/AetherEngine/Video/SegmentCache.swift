import Foundation

/// Sliding-window disk-backed cache for HLS-fMP4 segments. Bytes go to
/// <NSTemporaryDirectory>/aether-segments/<uuid>/seg-N.m4s; only URLs stay in RAM.
/// Reads use .alwaysMapped (kernel pages in/out under memory pressure). Window:
/// [currentTargetIndex - backwardWindow, currentTargetIndex + forwardWindow].
/// The producer pauses via awaitFetchHighWater once forwardWindow ahead of target.
// Thread-safe: all mutable state is guarded by `condition` (NSCondition), so it is safe to share
// across the producer/provider threads and capture in @Sendable closures.
final class SegmentCache: @unchecked Sendable {

    private let condition = NSCondition()

    private let forwardWindow: Int
    /// 20 covers Continuous-Audio handover refetches (~7-10 segments backward); smaller values
    /// cascaded into restart chains that reset the FLAC bridge PTS and caused audible glitches.
    private let backwardWindow: Int
    /// Byte budget for retaining segments OUTSIDE the hard window (#93 / Sodalite#32). While the
    /// cache's total footprint fits the budget, already-produced segments beyond the window stay
    /// resident (evicted farthest-from-target first once it fills), so a backward seek into watched
    /// content is a cache hit and never fires the producer restart that wedges slow sources (#93)
    /// and detaches AVKit's PiP legible renderer (Sodalite#32). 0 = window-only legacy pruning
    /// (live sessions, where the sliding playlist already dropped everything behind the window).
    private let retentionBudgetBytes: Int

    private var entries: [Int: URL] = [:]
    /// Per-index byte ledger for _totalBytes. Stat-on-eviction was wrong when same index was
    /// overwritten (stat returned new size, old bytes stayed counted forever).
    private var entryBytes: [Int: Int] = [:]

    /// Pinned in RAM (~3.5 KB); AVPlayer fetches exactly once per session; never evicted.
    private var initSegment: Data?

    /// Mid-session SSAI program-switch inits: (versionID, fromSegment, data). Version 0 = session init.
    private var initVersions: [(versionID: Int, fromSegment: Int, data: Data)] = []

    private var closed = false
    /// Declared by provider at top of each mediaSegment(at:); non-monotonic (backward scrub is valid).
    private var currentTargetIndex: Int = -1

    /// Lowest index of the consumer's current uninterrupted fetch sequence, and the highest index it has
    /// reached in it. A seek flushes the consumer's buffer, so only within one sequence does everything
    /// between the playhead and the target sit in that buffer, which is what
    /// `contiguousForwardFrontier(fromPlayhead:)` rests on.
    private var fetchFloor: Int = -1
    private var fetchFront: Int = -1

    let sessionDir: URL

    private var _totalBytes: Int = 0

    /// Monotonic across prunes; NOT decremented by pruneOutsideWindow. Lets VideoSegmentProvider
    /// detect gaps below the producer's write head after eviction erases them from indexRange().
    private var _highestStoredIndex: Int = -1

    /// (10, 20)=30 entries, ~300 MB at 4K HDR HEVC ~10 MB/seg.
    init(forwardWindow: Int = 10, backwardWindow: Int = 20, retentionBudgetBytes: Int = 0) {
        self.forwardWindow = forwardWindow
        self.backwardWindow = backwardWindow
        self.retentionBudgetBytes = retentionBudgetBytes

        // aether-segments/ prefix lets sweepStaleSessionDirs() find sibling dirs from crashed sessions.
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aether-segments", isDirectory: true)
        let sessionID = UUID().uuidString
        self.sessionDir = baseDir.appendingPathComponent(sessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            EngineLog.emit("[SegmentCache] session dir create failed at \(sessionDir.path): \(error)",
                           category: .session)
        }

        Self.sweepStaleSessionDirs(baseDir: baseDir, currentSession: sessionID)
    }

    private static func sweepStaleSessionDirs(baseDir: URL, currentSession: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDir,
                                                        includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries where entry.lastPathComponent != currentSession {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if created == nil || created! < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Writer side

    func setInit(_ data: Data) {
        condition.lock()
        initSegment = data
        condition.broadcast()
        condition.unlock()
    }

    /// Register fresh init at SSAI program switch valid from `fromSegment`. Idempotent on fromSegment.
    func addInitVersion(_ data: Data, fromSegment: Int) {
        condition.lock()
        defer { condition.unlock() }
        if let i = initVersions.firstIndex(where: { $0.fromSegment == fromSegment }) {
            initVersions[i].data = data
        } else {
            let nextID = (initVersions.map { $0.versionID }.max() ?? 0) + 1
            initVersions.append((versionID: nextID, fromSegment: fromSegment, data: data))
            initVersions.sort { $0.fromSegment < $1.fromSegment }
        }
        condition.broadcast()
    }

    func initVersionID(forSegment index: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        var id = 0
        for v in initVersions where v.fromSegment <= index { id = v.versionID }
        return id
    }

    func initData(versionID: Int) -> Data? {
        condition.lock(); defer { condition.unlock() }
        if versionID == 0 { return initSegment }
        return initVersions.first(where: { $0.versionID == versionID })?.data
    }

    func store(index: Int, data: Data) {
        let fileURL = sessionDir.appendingPathComponent("seg-\(index).m4s")
        let writeOK: Bool
        do {
            try data.write(to: fileURL, options: [.atomic])
            writeOK = true
        } catch {
            EngineLog.emit("[SegmentCache] write failed seg-\(index): \(error)",
                           category: .session)
            writeOK = false
        }

        condition.lock()
        // store racing close() must not resurrect bookkeeping; entry would point into deleted sessionDir.
        guard !closed else {
            condition.unlock()
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        if writeOK {
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            entries[index] = fileURL
            entryBytes[index] = data.count
            _totalBytes += data.count
            if index > _highestStoredIndex { _highestStoredIndex = index }
        }
        let doomed = pruneOutsideWindow()
        condition.broadcast()
        condition.unlock()
        for url in doomed { try? FileManager.default.removeItem(at: url) }
    }

    /// Adopt a staging file via rename(2). Page cache pages stay warm; skips a Swift Data round trip.
    func adopt(index: Int, stagingPath: URL, byteCount: Int) {
        let fileURL = sessionDir.appendingPathComponent("seg-\(index).m4s")
        let renameOK: Bool
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: stagingPath, to: fileURL)
            renameOK = true
        } catch {
            EngineLog.emit("[SegmentCache] adopt failed seg-\(index): \(error)",
                           category: .session)
            try? FileManager.default.removeItem(at: stagingPath)
            renameOK = false
        }

        condition.lock()
        guard !closed else {
            condition.unlock()
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        if renameOK {
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            entries[index] = fileURL
            entryBytes[index] = byteCount
            _totalBytes += byteCount
            if index > _highestStoredIndex { _highestStoredIndex = index }
        }
        let doomed = pruneOutsideWindow()
        condition.broadcast()
        condition.unlock()
        for url in doomed { try? FileManager.default.removeItem(at: url) }
    }

    func close() {
        condition.lock()
        closed = true
        let dir = sessionDir
        entries.removeAll(keepingCapacity: false)
        entryBytes.removeAll(keepingCapacity: false)
        initSegment = nil
        initVersions.removeAll(keepingCapacity: false)
        _totalBytes = 0
        _highestStoredIndex = -1
        condition.broadcast()
        condition.unlock()

        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Reader side

    func declareTarget(_ index: Int) {
        condition.lock()
        var doomed: [URL] = []
        trackFetchSequenceLocked(index)
        if index != currentTargetIndex {
            currentTargetIndex = index
            doomed = pruneOutsideWindow()
            condition.broadcast()
        }
        condition.unlock()
        for url in doomed { try? FileManager.default.removeItem(at: url) }
    }

    /// Must be called with condition held.
    ///
    /// A fetch that leaves a gap above the front, or that drops further back than a handover refetch
    /// reaches, is the consumer arriving from somewhere else: it flushed its buffer and starts a new
    /// sequence here. Anything else extends the current one, including the ~7-10 segment backward
    /// refetch of the Continuous-Audio handover and its return to the front, which must NOT count as a
    /// jump: under an opt-in prefetch the playhead sits below the retained low end, so falling back to
    /// the playhead anchor there would re-open the #207 collapse the anchor exists to prevent.
    private func trackFetchSequenceLocked(_ index: Int) {
        if index > fetchFront + 1 || index < fetchFront - backwardWindow {
            fetchFloor = index
            fetchFront = index
        } else {
            fetchFront = max(fetchFront, index)
        }
    }

    func peek(index: Int) -> Data? {
        condition.lock()
        let fileURL = entries[index]
        condition.unlock()
        guard let url = fileURL else { return nil }
        return readMapped(url)
    }

    func peekURL(index: Int) -> URL? {
        condition.lock()
        defer { condition.unlock() }
        return entries[index]
    }

    func fetch(index: Int, timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        if let url = entries[index] {
            condition.unlock()
            return readMapped(url)
        }
        if closed {
            condition.unlock()
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, entries[index] == nil {
            if !condition.wait(until: deadline) { break }
        }
        let fileURL = entries[index]
        condition.unlock()
        guard let url = fileURL else { return nil }
        return readMapped(url)
    }

    func fetchInit(timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let i = initSegment { return i }
        if closed { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, initSegment == nil {
            if !condition.wait(until: deadline) { break }
        }
        return initSegment
    }

    /// Pump-side backpressure: one-shot wait for target or any broadcast. Returns true if target met.
    func awaitFetchHighWater(reaching target: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if currentTargetIndex >= target { return true }
        if closed { return false }
        let deadline = Date().addingTimeInterval(timeout)
        _ = condition.wait(until: deadline)
        return currentTargetIndex >= target
    }

    /// Evict segments strictly below cutoff (= live firstVisible). Bounded by firstVisible <= currentTargetIndex
    /// so it only removes segments the playlist already dropped; pruneOutsideWindow handles the forward bound.
    func evictBelow(_ cutoff: Int) {
        condition.lock()
        var doomed: [URL] = []
        for (k, url) in entries where k < cutoff {
            _totalBytes -= entryBytes[k] ?? byteSize(of: url)
            entryBytes.removeValue(forKey: k)
            entries.removeValue(forKey: k)
            doomed.append(url)
        }
        condition.unlock()
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Authoritative disk footprint via fresh stat (not _totalBytes accumulator); diagnostics path.
    func diskBytes() -> Int64 {
        condition.lock()
        let urls = Array(entries.values)
        condition.unlock()
        var total: Int64 = 0
        for url in urls {
            total += Int64(byteSize(of: url))
        }
        return total
    }

    func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Diagnostics

    var targetIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentTargetIndex
    }

    func indexRange() -> (Int, Int)? {
        condition.lock()
        defer { condition.unlock() }
        guard !entries.isEmpty else { return nil }
        let keys = entries.keys
        return (keys.min()!, keys.max()!)
    }

    /// Monotonic across prunes; reset per restart via resetHighWaterForRestart().
    /// indexRange() only shows resident entries and loses the signal after pruning the high end;
    /// highestStoredIndex retains it so VideoSegmentProvider can detect prune-created gaps.
    var highestStoredIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return _highestStoredIndex
    }

    /// Largest K such that every index in [startIdx ... K] is resident, walking forward until the first
    /// gap. Returns startIdx - 1 when startIdx itself is absent (nothing cached from there). Used to
    /// express the disk read-ahead frontier as a segment index. Thread-safe.
    func contiguousForwardFrontier(from startIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return frontierLocked(from: startIdx)
    }

    /// Frontier of the contiguous *safe* range for a playhead at `playheadIdx`, anchored at
    /// `max(playheadIdx, currentTargetIndex)` (#207 follow-up).
    ///
    /// Walking from the playhead alone under-reports whenever the consumer's fetch target runs ahead of
    /// it: `pruneOutsideWindow` retains from `currentTargetIndex - backwardWindow` upward, so the
    /// playhead's own segment is an evictable extra, and an opt-in whole-source prefetch (which is the
    /// only case that reaches the retention budget) really does evict it. The walk then starts on a hole
    /// and reports nothing ahead while the whole band is resident.
    ///
    /// Anchoring on the fetch target is safe rather than merely optimistic: `declareTarget` is only ever
    /// called from the segment-serve path, so everything below `currentTargetIndex` has been handed to
    /// the consumer and sits in its own buffer. Skipping the leading hole *without* that bound would
    /// instead land on a stale band above a backward seek (nothing forces its eviction while the budget
    /// has room) and report it as buffered, which fails in the dangerous direction; anchoring at the new
    /// target stops the walk at the hole above the freshly produced segments. `max` keeps a backward
    /// refetch behind the playhead (Continuous-Audio handover) from dragging the anchor back.
    ///
    /// Anchor and walk share one lock hold: reading `targetIndex` separately would let a target change
    /// land between the two and walk from an anchor that does not match the entries observed.
    ///
    /// The target anchor only holds while the playhead is inside the consumer's current fetch sequence.
    /// AVPlayer fetches no further ahead than its own buffer reaches, which is what keeps everything
    /// between the playhead and the target genuinely held; a seek removes that bound, and since
    /// `declareTarget` lands at the destination before `currentTime()` reports it, the target would
    /// otherwise measure the band at the destination against the position the seek jumped away from and
    /// claim a lead the size of the seek distance (#207 field report on 5.23.4). Outside the sequence the
    /// walk falls back to the playhead, which reports the band that is genuinely reachable from there,
    /// or nothing when its own segment is gone.
    func contiguousForwardFrontier(fromPlayhead playheadIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        let anchor = playheadIdx >= fetchFloor ? max(playheadIdx, currentTargetIndex) : playheadIdx
        return frontierLocked(from: anchor)
    }

    /// Must be called with condition held.
    private func frontierLocked(from startIdx: Int) -> Int {
        var k = startIdx
        while entries[k] != nil { k += 1 }
        return k - 1
    }

    /// Reset before triggering a restart; previous producer's highWater would keep producerPassedAndPruned
    /// hot on every fetch, cascading a single restart into a per-segment storm.
    func resetHighWaterForRestart() {
        condition.lock()
        defer { condition.unlock() }
        _highestStoredIndex = -1
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.count
    }

    /// On-disk bytes (not RAM); useful for memprobe alongside RSS.
    var totalBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return _totalBytes
    }

    /// On-disk bytes at or above the consumer's current target: what the producer's race-ahead owns
    /// (#207). Everything behind the playhead is either the small backward window or budget-evictable
    /// extras, so this is the only footprint an opt-in whole-source window grows without bound.
    var forwardBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentForwardBytes()
    }

    /// #207 producer park step: true once the producer may write `head`. Withheld while its race-ahead
    /// has reached `budgetBytes` and the consumer still has a safe lead behind it; the extras eviction
    /// that follows the advancing playhead is what frees the room again.
    func awaitPrefetchDiskHeadroom(head: Int, budgetBytes: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if !shouldParkLocked(head: head, budgetBytes: budgetBytes) { return true }
        _ = condition.wait(until: Date().addingTimeInterval(timeout))
        return !shouldParkLocked(head: head, budgetBytes: budgetBytes)
    }

    /// Must be called with condition held.
    private func shouldParkLocked(head: Int, budgetBytes: Int) -> Bool {
        PrefetchDiskBudget.shouldPark(forwardBytes: currentForwardBytes(),
                                      budgetBytes: budgetBytes,
                                      head: head,
                                      consumerTarget: currentTargetIndex)
    }

    /// Must be called with condition held.
    private func currentForwardBytes() -> Int {
        var bytes = 0
        for (k, b) in entryBytes where k >= currentTargetIndex { bytes += b }
        return bytes
    }

    // MARK: - Internal

    /// Prune to [currentTarget - backwardWindow, max(currentTarget + forwardWindow, highestStoredIndex)].
    /// Must be called with condition held.
    /// hi anchors on highestStoredIndex so a transient backward refetch (AVPlayer audio handover)
    /// doesn't evict already-produced forward segments (repro: seg0..25 produced, refetch seg4 -> target=4
    /// pruned seg15+, stalled when playback reached seg15).
    /// With a retention budget (#93 / Sodalite#32), entries outside that hard window survive,
    /// nearest-to-target first, while the cache's total footprint fits the budget; the window itself
    /// is never evicted even when it alone exceeds the budget. Nearest-first eviction from the far
    /// ends keeps each side of the resident span contiguous, so the provider's residency gate
    /// (a resident backward target = no producer restart) holds across the whole retained span.
    private func pruneOutsideWindow() -> [URL] {
        let lo = currentTargetIndex - backwardWindow
        let hi = max(currentTargetIndex + forwardWindow, _highestStoredIndex)
        var doomed: [URL] = []
        if retentionBudgetBytes > 0 {
            var extras: [(index: Int, bytes: Int)] = []
            var keptBytes = 0
            for (k, _) in entries {
                let bytes = entryBytes[k] ?? 0
                if k < lo || k > hi {
                    extras.append((k, bytes))
                } else {
                    keptBytes += bytes
                }
            }
            guard !extras.isEmpty else { return [] }
            extras.sort { abs($0.index - currentTargetIndex) < abs($1.index - currentTargetIndex) }
            for (k, bytes) in extras {
                if keptBytes + bytes <= retentionBudgetBytes {
                    keptBytes += bytes
                } else if let url = entries[k] {
                    _totalBytes -= bytes
                    entryBytes.removeValue(forKey: k)
                    entries.removeValue(forKey: k)
                    doomed.append(url)
                }
            }
            return doomed
        }
        for (k, url) in entries {
            if k < lo || k > hi {
                _totalBytes -= entryBytes[k] ?? byteSize(of: url)
                entryBytes.removeValue(forKey: k)
                entries.removeValue(forKey: k)
                doomed.append(url)
            }
        }
        // Collected under the lock, deleted by the caller AFTER
        // unlocking: removeItem is filesystem I/O on the segment-serve
        // hot path (fetch waiters + the pump's backpressure wait park on
        // this condition; PacketRingBuffer's eviction uses the same
        // pattern). A racing reader that still resolves a doomed URL
        // degrades to an mmap miss -> nil, same as before.
        return doomed
    }

    /// Read a segment file as mmap-backed Data. The kernel pages in
    /// on access and frees on memory pressure; we never hold the
    /// full segment in our heap. Errors degrade to `nil` (cache miss);
    /// the caller handles that by retrying or restarting the producer.
    private func readMapped(_ url: URL) -> Data? {
        do {
            return try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
        } catch {
            EngineLog.emit("[SegmentCache] mmap read failed \(url.lastPathComponent): \(error)",
                           category: .session)
            return nil
        }
    }

    /// On-disk size of a segment file. Cached size accounting only
    /// queries the file system when needed; in steady state `store`
    /// + `prune` keep `_totalBytes` accurate via Data.count and this
    /// path is a fallback.
    private func byteSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
