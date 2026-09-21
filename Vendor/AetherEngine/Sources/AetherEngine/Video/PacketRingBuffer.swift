import Foundation

/// Keyframe-indexed disk-spooled DVR ring buffer. Eviction is keyframe-aligned (retained span always starts at a decodable keyframe). Bytes stored as flat files under a scratch dir; in-RAM index holds only metadata; `Data(contentsOf:,.alwaysMapped)` keeps RSS flat. NSLock guards the index (demux-thread appends, seek-thread reads).
// Thread-safe: all mutable state is guarded by `lock` (NSLock), so it is safe to share across the
// demux/seek/feeder threads and capture in @Sendable closures.
final class PacketRingBuffer: @unchecked Sendable {

    // MARK: - Public types

    /// A single packet as returned by `packets(fromPts:)`.
    struct Packet {
        let pts: Double
        let isKeyframe: Bool
        let isVideo: Bool
        let bytes: Data
    }

    // MARK: - Private types

    private struct Entry {
        let pts: Double
        let isKeyframe: Bool
        let isVideo: Bool
        let fileURL: URL
        let byteCount: Int
    }

    // MARK: - State

    private let lock = NSLock()
    private let windowSeconds: Double
    private let scratch: URL

    private var entries: [Entry] = []
    /// Sequence number of `entries[0]`; eviction advances this instead of renumbering. Feeder cursor below `firstSeq` = fell out of window.
    private var firstSeq: Int = 0
    private var counter: Int = 0
    private var edge: Double = -.infinity
    private var closed: Bool = false

    // MARK: - Init / close

    init(windowSeconds: Double, scratch: URL) throws {
        self.windowSeconds = windowSeconds
        self.scratch = scratch
    }

    /// Idempotent teardown. State is cleared synchronously so the ring is immediately
    /// unusable; the scratch-directory removal is dispatched to a background queue so
    /// filesystem I/O never blocks the caller.
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        entries.removeAll(keepingCapacity: false)
        edge = -.infinity
        counter = 0
        firstSeq = 0
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [scratch] in
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    // MARK: - Writer

    func append(pts: Double, isKeyframe: Bool, isVideo: Bool, bytes: Data) throws {
        let fileURL = scratch.appendingPathComponent("pkt-\(nextCounter()).bin")
        try bytes.write(to: fileURL, options: [.atomic])
        let entry = Entry(pts: pts, isKeyframe: isKeyframe, isVideo: isVideo, fileURL: fileURL, byteCount: bytes.count)

        lock.lock()
        entries.append(entry)
        if pts > edge { edge = pts }
        let evictedURLs = evictLocked()
        lock.unlock()

        for url in evictedURLs {  // delete outside the lock; removeItem is filesystem I/O
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Reader

    func keyframePts(atOrBefore target: Double) throws -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries
            .filter { $0.isKeyframe && $0.pts <= target }
            .last
            .map(\.pts)
    }

    /// Returns packets with `pts >= startPts`. Entries evicted between index snapshot and off-lock disk read are skipped (eviction is front-only, so skipping preserves keyframe alignment).
    func packets(fromPts startPts: Double) throws -> [Packet] {
        lock.lock()
        let slice = entries.filter { $0.pts >= startPts }
        lock.unlock()

        var packets = slice.compactMap { entry -> Packet? in
            guard let data = try? Data(contentsOf: entry.fileURL, options: [.alwaysMapped, .uncached]) else {
                return nil
            }
            return Packet(pts: entry.pts, isKeyframe: entry.isKeyframe, isVideo: entry.isVideo, bytes: data)
        }
        // Off-lock reads can race deferred eviction deletions: trim to the first video keyframe to guarantee a clean decode start.
        if packets.contains(where: { $0.isVideo }),
           let kf = packets.firstIndex(where: { $0.isVideo && $0.isKeyframe }) {
            if kf > 0 { packets.removeFirst(kf) }
        } else if packets.contains(where: { $0.isVideo }) {
            return []
        }
        return packets
    }

    // MARK: - Sequential consumption (live feeder)

    var seqBounds: (first: Int, end: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (firstSeq, firstSeq + entries.count)
    }

    /// Returns packet for `seq`, or nil if evicted or not yet appended. Index lock NOT held across the disk read.
    func packet(atSeq seq: Int) -> Packet? {
        lock.lock()
        let idx = seq - firstSeq
        guard idx >= 0, idx < entries.count else {
            lock.unlock()
            return nil
        }
        let entry = entries[idx]
        lock.unlock()
        guard let data = try? Data(contentsOf: entry.fileURL,
                                   options: [.alwaysMapped, .uncached]) else { return nil }
        return Packet(pts: entry.pts, isKeyframe: entry.isKeyframe,
                      isVideo: entry.isVideo, bytes: data)
    }

    func seq(forKeyframeAtOrBefore target: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries.indices
            .last(where: { entries[$0].isKeyframe && entries[$0].pts <= target })
            .map { firstSeq + $0 }
    }

    /// Sequence of the EARLIEST retained keyframe, or nil if the ring holds no keyframe yet. DVR reseed
    /// floor when a target precedes every keyframe: seeding seqBounds.first (firstSeq) can land mid-GOP,
    /// since leading entries appended before the first eviction are not guaranteed keyframe-aligned.
    func firstKeyframeSeq() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries.indices
            .first(where: { entries[$0].isKeyframe })
            .map { firstSeq + $0 }
    }

    // MARK: - Still runs (#544)

    /// One retained packet as the still planner sees it: no bytes, no file, just the three fields
    /// the decision needs.
    struct IndexEntry: Equatable {
        let pts: Double
        let isKeyframe: Bool
        let isVideo: Bool
    }

    /// The sequence span a still at `target` needs: from the newest video keyframe at or before it
    /// forward to the first video packet that reaches it, plus `reorderTail` further video packets.
    /// Nil when no keyframe at or before the target is retained, when the index holds no video, or
    /// when the span exceeds either bound.
    ///
    /// Two shapes decide the rules here. Packets are stored in DECODE order, so with B-frames the
    /// frame at the target can sit behind the first packet that reaches it, which is what the tail
    /// pays for. And a live scrub routinely aims a fraction past the newest packet, so a target
    /// beyond the end clamps to it rather than answering nil, which would blink the card out at
    /// exactly the edge the viewer sits on most.
    /// `indexReachesEnd` says whether `index` runs to the ring's newest entry. It is what separates
    /// the two ways the walk can run out of packets: the ring genuinely ending (clamp to it) from a
    /// caller's bounded window ending (refuse). Without it a truncated window silently returns a
    /// picture from before the requested time and calls it the answer.
    static func stillRunSpan(target: Double,
                             index: [IndexEntry],
                             firstSeq: Int,
                             maxPackets: Int,
                             maxSpanSeconds: Double,
                             reorderTail: Int,
                             indexReachesEnd: Bool) -> ClosedRange<Int>? {
        guard index.contains(where: \.isVideo) else { return nil }
        guard let start = index.indices.last(where: { index[$0].isKeyframe && index[$0].pts <= target })
        else { return nil }
        guard target - index[start].pts <= maxSpanSeconds else { return nil }

        let reached = index.indices[start...].first(where: { index[$0].isVideo && index[$0].pts >= target })
        guard reached != nil || indexReachesEnd else { return nil }
        guard var end = reached ?? index.indices.last(where: { index[$0].isVideo }) else { return nil }

        if reached != nil, reorderTail > 0 {
            var remaining = reorderTail
            var i = end + 1
            while i < index.count, remaining > 0 {
                if index[i].isVideo {
                    remaining -= 1
                    end = i
                }
                i += 1
            }
        }

        guard end >= start, end - start + 1 <= maxPackets else { return nil }
        return (firstSeq + start)...(firstSeq + end)
    }

    /// The video packets a still at `target` needs, keyframe-first. Nil when the target is not
    /// decodable from what the ring retains. Only the window the span can possibly cover is copied
    /// out under the lock: a 30 minute window holds ~150k entries and a still is asked for every
    /// 80 ms while a viewer holds the scrub.
    func stillRun(target: Double,
                  maxPackets: Int,
                  maxSpanSeconds: Double,
                  reorderTail: Int) -> [Packet]? {
        lock.lock()
        guard let startIdx = entries.indices
            .last(where: { entries[$0].isKeyframe && entries[$0].pts <= target }) else {
            lock.unlock()
            return nil
        }
        let upper = min(entries.count, startIdx + maxPackets + reorderTail + 1)
        let reachesEnd = upper == entries.count
        let window = entries[startIdx..<upper].map {
            IndexEntry(pts: $0.pts, isKeyframe: $0.isKeyframe, isVideo: $0.isVideo)
        }
        let base = firstSeq + startIdx
        lock.unlock()

        guard let span = Self.stillRunSpan(target: target, index: window, firstSeq: base,
                                           maxPackets: maxPackets, maxSpanSeconds: maxSpanSeconds,
                                           reorderTail: reorderTail,
                                           indexReachesEnd: reachesEnd) else { return nil }

        let run = span.compactMap { packet(atSeq: $0) }.filter(\.isVideo)
        // Eviction between the snapshot and the off-lock reads would cost the run its keyframe, and
        // a run that does not open on one decodes as garbage.
        guard let first = run.first, first.isKeyframe else { return nil }
        return run
    }

    // MARK: - Diagnostics

    var oldestPts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first.map(\.pts)
    }

    // MARK: - Internal

    private func nextCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let c = counter
        counter += 1
        return c
    }

    /// Drop leading entries outside `edge - windowSeconds`, keyframe-aligned. Forward scan: backward scan walked ~150k entries per append at 80 pkt/s; forward scan touches a few hundred at most. Caller deletes returned URLs after releasing the lock.
    private func evictLocked() -> [URL] {
        let cutoff = edge - windowSeconds
        var pivot: Int? = nil
        var i = 0
        while i < entries.count, entries[i].pts <= cutoff {
            if entries[i].isKeyframe { pivot = i }
            i += 1
        }
        guard let p = pivot, p > 0 else { return [] }
        let urls = entries[..<p].map(\.fileURL)
        entries.removeSubrange(..<p)
        firstSeq += p
        return urls
    }
}
