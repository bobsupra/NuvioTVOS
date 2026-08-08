import Foundation
import os
import AetherLibavformat
import AetherLibavutil

/// Custom AVIO context feeding FFmpeg via URLSession. Three modes:
/// - **Persistent** (known size + prefetch=true, playback path): single long-lived
///   `Range: bytes=<pos>-` GET into a sliding window; reconnects on drop/429/503.
///   Fix for AetherEngine#25 (CDN stutter collapsing playback). See `readPersistent`.
/// - **Seekable chunked** (known size + prefetch=false, still/frame-extraction):
///   discrete Range chunks for random access. See `readSeekable`.
/// - **Streaming** (size=-1): single sequential GET, no reconnect. See `readStreaming`.
///
/// AVIO callbacks run on the demux queue; prefetch/delivery on background queues.
/// Shared state protected by locks.

/// Dedupes `ReaderNetworkPhase` emissions so a flapping origin does not spam the callback (#85).
/// Mutated only on the demux thread (the read loop), so it needs no locking.
struct NetworkPhaseGate {
    private var last: ReaderNetworkPhase = .flowing
    mutating func shouldEmit(_ next: ReaderNetworkPhase) -> Bool {
        guard next != last else { return false }
        last = next
        return true
    }
}

final class AVIOReader: AVIOProvider, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    /// Session config factory. Short-lived probes/chunks get a 60s resource timeout;
    /// long-lived persistent/streaming connections omit it (fires mid-stream, NSURLError
    /// -1001; stall detection is handled by `connStallTimeout`). `urlCache = nil` avoids
    /// the "N URLCaches racing async invalidation" leak (reverted in fef8ef4).
    private static func makeSessionConfig(longLived: Bool = false) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        if !longLived {
            config.timeoutIntervalForResource = 60
        }
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // No URLCache instance, kills the in-memory cache that the
        // long-lived-session fix from fef8ef4 was working around.
        config.urlCache = nil
        return config
    }
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

    /// Typed source-fetch network phase, pushed on every stall/reconnect/recovery transition (#85).
    /// Mirrors `HLSVideoEngine.onSeekStateChanged`. `@Sendable`: invoked from the demux thread, the
    /// consumer hops to the main actor. Set only on the MAIN playback reader, never the subtitle side reader.
    var onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)?

    /// Demux-thread-only dedupe for `onNetworkPhaseChanged`.
    private var networkPhaseGate = NetworkPhaseGate()

    /// Emit a phase transition through the gate (demux thread only).
    private func emitNetworkPhase(_ phase: ReaderNetworkPhase) {
        if networkPhaseGate.shouldEmit(phase) {
            onNetworkPhaseChanged?(phase)
        }
    }

    /// Cached CDN URL after redirect resolution; skips proxy hop on subsequent chunks.
    /// Auth-expiry statuses (401/403/404/410) against it invalidate and fall back to
    /// the source URL. See AetherEngine#12.
    private let resolvedURLLock = NSLock()
    private var _resolvedURL: URL?

    private func requestURL() -> URL {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL ?? url
    }

    private func cachedResolvedURL() -> URL? {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL
    }

    private func recordResolvedURL(_ resolved: URL?) {
        guard let resolved else { return }
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if resolved != url && resolved != _resolvedURL {
            _resolvedURL = resolved
            #if DEBUG
            EngineLog.emit("[AVIOReader] Cached resolved URL host=\(resolved.host ?? "?")", category: .demux)
            #endif
        }
    }

    private func invalidateResolvedURL() {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if _resolvedURL != nil {
            _resolvedURL = nil
            #if DEBUG
            EngineLog.emit("[AVIOReader] Dropped resolved URL cache (expiry status)", category: .demux)
            #endif
        }
    }

    private static func isResolvedExpiryStatus(_ status: Int) -> Bool {
        return status == 401 || status == 403 || status == 404 || status == 410
    }

    // Cumulative bytes fetched since open; memory probe compares against RSS growth.
    private let counterLock = NSLock()
    private var _cumulativeBytesFetched: Int64 = 0
    var cumulativeBytesFetched: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _cumulativeBytesFetched
    }
    private func addBytesFetched(_ n: Int) {
        counterLock.lock()
        _cumulativeBytesFetched &+= Int64(n)
        counterLock.unlock()
    }

    private var isStreaming: Bool { fileSize <= 0 }

    /// #126: a VOD source that resolved no size runs the forward-only streaming reader
    /// (1 MB back-window, no reconnect); it must not be routed onto seek-dependent paths.
    /// Live keeps true: the persistent reader owns reconnection and live routing never
    /// seeks backward. Meaningful only after `open()` has resolved the mode.
    var isSeekable: Bool { isLive || !isStreaming }

    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Seekable Mode (Range requests)

    /// Default 4 MB. Delegate-based incremental delivery (ChunkFetchDelegate on a
    /// shared long-lived chunkSession) avoids the per-request URLSession task-pool
    /// leak that made 8 MB chunks bleed ~6 MB/s (e327e5e). 4 MB gives ~0.7 s
    /// cold-start on 45 Mbps 4K HEVC. Smaller values add HTTP roundtrip overhead
    /// at 5+ ops/sec without meaningful latency benefit. Still-extraction passes a
    /// smaller value for random-access single-keyframe fetches.
    private let chunkSize: Int
    /// When false, no speculative next-chunk prefetch (random-access: next read
    /// almost always seeks elsewhere, so prefetch would be wasted bandwidth).
    private let prefetchEnabled: Bool
    /// When set, the open-time data connection requests a finite `bytes=0-N` range instead of the
    /// open-ended `bytes=0-` stream (#93 residual). Scopes to the open connection only; read-loop
    /// reconnects and seek reconnects stay open-ended. nil = open-ended everywhere (playback).
    private let boundedInitialFetch: Int64?
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB
    private static let streamTrimThreshold = 1024 * 1024  // 1 MB, keep for small backward seeks
    // Backpressure: suspend the streaming task above highWater, resume below lowWater.
    private static let streamHighWater = 64 * 1024 * 1024
    private static let streamLowWater = 32 * 1024 * 1024

    private let bufferLock = NSLock()
    private var currentBuffer = Data()
    private var currentOffset: Int64 = 0
    private var prefetchBuffer: Data?
    private var prefetchOffset: Int64 = 0
    private var isPrefetching = false
    private let prefetchReady = DispatchSemaphore(value: 0)
    private let prefetchQueue = DispatchQueue(label: "com.aetherengine.avio.prefetch", qos: .userInitiated)
    private static let maxRetries = 3

    // MARK: - Streaming Mode (sequential GET)

    private var streamBuffer = Data()
    private var streamBytesRead: Int64 = 0
    private var streamEnded = false
    private let streamLock = NSLock()
    private let streamDataReady = DispatchSemaphore(value: 0)

    // MARK: - Persistent Mode (single forward-streaming connection, playback path)

    // Backpressure: suspend the persistent task above highWater, resume below lowWater
    // (#174). Suspend/resume is the only contractual flow control; blocking the delegate
    // callback leaves the socket read running on TLS/H2 transports, and the undelivered
    // body then accumulates in unbounded URLSession-internal allocations until jetsam.
    //
    // #220 correction: "peak window ~= highWater + a few MB of in-flight" is NOT what the
    // suspend delivers. Measured against an origin serving 2.5x media rate, 911 MB arrived
    // AFTER the task was suspended, window still climbing linearly, `suspended` true
    // throughout. `suspend()` is advisory: CFNetwork keeps draining the socket and delivering.
    // The real bound is whatever backpressure TCP applies once its own buffers fill, which
    // against a fast origin is far above anything this window was sized for. So the high
    // water is the target, and `winHardCap` is the bound: past it the connection is ended
    // deliberately and re-requested at the frontier once the window drains. See
    // `endPersistentConnectionForBackpressure`.
    private static let winHighWater = 16 * 1024 * 1024
    private static let winLowWater = 8 * 1024 * 1024
    // #220 hard bound on the resident window. Above this the transport is demonstrably
    // ignoring the suspend, and no amount of waiting brings it back down.
    //
    // 3x the high water, not 8x. The first attempt used 128 MB, reasoning that healthy
    // sessions sit far below it. They do (16-21 MB measured on both macOS and tvOS, across
    // both readers), but the cap is not the peak: the window is a `Data`, so crossing the cap
    // means a realloc that holds the old and new buffers at once, and a field capture with
    // this bound already working named `bigExact=160301056,135544832`, two blocks at 153 and
    // 129 MB, with `size_in_use` still touching 1003 MB. The cap sets the peak at roughly
    // twice its own value, so it has to be chosen against the peak that is affordable, not
    // against the window that looks reasonable. It also caught that event with 4 MB to spare,
    // which is not a margin.
    //
    // Lower costs reconnects only in the regime that is already broken: a healthy link never
    // reaches it, and at the rates where the defect appears the excess is 1-2 MB/s, so the
    // cycle is tens of seconds. No byte is discarded or re-fetched either way.
    static let winHardCap = 48 * 1024 * 1024
    // #220: how much the persistent reader asks for at a time. The resident window is then
    // bounded by low water plus this, 40 MB, whatever the transport chooses to do with a
    // suspend. Sized so the request rate stays modest (about one per 5 s on a 4K remux) while
    // leaving clearance under winHardCap, so a firing cap still means something is wrong
    // rather than being the normal ceiling.
    static let persistentRangeBytes: Int64 = 32 * 1024 * 1024
    // Keep this many bytes behind the cursor for small matroska backward re-reads.
    private static let winLookback = 2 * 1024 * 1024
    // Trim in batches to avoid O(n^2) memmove storm on every 256 KB read.
    private static let winTrimBatch = 4 * 1024 * 1024
    // Forward seeks within this distance keep the live connection; beyond it, reconnect.
    private static let seekKeepForwardLimit = 8 * 1024 * 1024
    // CDN stall threshold: no bytes for this long triggers reconnect.
    private static let connStallTimeout: TimeInterval = 20
    // A reconnect that delivers at least this much counts as progress; resets streak.
    private static let minReconnectProgress: Int64 = 512 * 1024
    // Cap on CONSECUTIVE unproductive reconnects; resets on real progress.
    private static let reconnectMaxUnproductive = 12

    // MARK: - Cold-start round trips (#281)

    /// How much of the file's head to retain for the return trip after a parse excursion. Measured
    /// landings across six container layouts and a field trace: 48, 1161, 5752 and 265159, all well
    /// inside this. Sized to hold that return without becoming a second buffer worth worrying about
    /// next to the live window: this is charged against the same footprint that winHardCap bounds.
    static let headSpanMaxBytes = 4 * 1024 * 1024

    /// Speculative suffix fetch issued with `open()`, sized to cover the small trailing objects a
    /// demuxer asks for before it can report a frame rate: `mfra` on fragmented MP4 (~1-2 KB), and
    /// the trailing `moov` of a non-faststart file whose sample tables are small enough to fit.
    ///
    /// Deliberately NOT sized to cover every trailing `moov`. Those grow with the sample count, so
    /// a feature-length file's runs into megabytes, and fetching that speculatively on every open
    /// would spend real bandwidth on a guess, competing with the first data connection on exactly
    /// the slow links this is meant to help. 64 KB is negligible on any link that plays video at
    /// all, and when it misses, the retained head still removes the return trip.
    static let tailPrefetchBytes = 64 * 1024

    // MARK: - Detour Block Cache (random-access parse reads; AetherEngine#69)

    // A non-faststart / coarsely-interleaved remote MP4 makes the demuxer ping-pong between
    // distant file regions (header, trailing moov, sample data) during find_stream_info /
    // index parse. Each non-sequential read used to tear down + reopen the persistent
    // connection (seekReconnect), so the parse storm hammered the origin into a 429.
    // Instead, serve those random-access reads through the pooled keep-alive chunkSession
    // (the one fetchChunk already uses), caching 4 MB aligned blocks. The streaming
    // connection stays ANCHORED; the ping-pong becomes cache hits; the storm collapses to
    // the two legitimate reconnects (open + the one seek to the moov). The sequential
    // playback fast path never enters this code, so it carries zero overhead.
    private static let detourBlockSize = 4 * 1024 * 1024
    private static let detourMaxBlocks = 8                       // ~32 MB LRU ceiling
    // Once detour reads turn sequential past this much, re-anchor the streaming connection
    // there so sustained playback returns to the cheap window path (e.g. after a backward scrub).
    private static let detourReanchorBytes: Int64 = 8 * 1024 * 1024
    // Interactive per-fetch budget for a detour block (#93/#96). A backward-scrub read serves via the
    // detour cache; a miss fetches a 4 MB block over the pooled session. On a per-connection-starved
    // origin that fetch used to ride the full chunkRequestTimeout (idle 15s / total 35s) before falling
    // through to the rescue reconnect, which opens a fresh connection the origin serves in ~30-190ms
    // (rrgomes' #93/#96 traces: the whole 15-35s sat here, invisibly, in the detour fetch). A 4 MB block
    // over a healthy remote 4K source lands in ~1s, so a tight budget aborts a starved fetch fast and
    // lets the reconnect serve, without tripping healthy parse-time detour fetches (#69 stays intact:
    // its fetches complete well under this, and a genuinely slow parse fetch reconnecting is bounded by
    // the #71 rate-limit streak, far gentler than the pre-cache per-read storm).
    private static let detourFetchBudgetSeconds: TimeInterval = 4

    /// Effective per-fetch budget for a detour block: the tight interactive cap, never exceeding the
    /// caller's chunk budget (still-extraction passes a smaller one; it never reaches this path, but
    /// the clamp keeps the invariant). Internal so the bound is unit-tested without a live origin.
    static func effectiveDetourBudget(chunkRequestTimeout: TimeInterval) -> TimeInterval {
        min(detourFetchBudgetSeconds, chunkRequestTimeout)
    }

    // Cap on CONSECUTIVE rate-limited (429/503) network attempts before giving up cleanly.
    // Distinct axis from unproductiveReconnects: NOT reset by seekReconnect, so parse-driven
    // seeks cannot mask a throttled origin into an infinite reconnect loop (AetherEngine#71).
    private static let rateLimitMaxStreak = 6

    /// NSCondition guards all persistent-mode fields and serves as the
    /// edge-triggered condition variable for read waits and backpressure.
    private let winCond = NSCondition()
    /// Sliding window of bytes from the live connection, starting at `winStart`.
    /// `position - winStart` is the read offset within `window`.
    private var window = Data()
    private var winStart: Int64 = 0
    // Connection state.
    private var connEnded = false
    private var connStatus = 0
    // Retry-After seconds from 429/503, honoured before reconnect.
    private var connRetryAfter: TimeInterval = 0
    // Bumped on every (re)connect; stale delegate callbacks are ignored.
    private var connGeneration = 0
    private var activeTask: URLSessionDataTask?
    // #174: true while the persistent task is suspended for window backpressure.
    // winCond-guarded; every suspend/resume transition goes through this flag so the
    // task's suspend count stays balanced.
    private var persistentTaskSuspended = false

    /// #174: winCond-guarded snapshot of the suspend state, internal so the task-level
    /// backpressure is unit-tested against a loopback origin without private state access.
    /// #220: planned range ends must leave the failure budget alone.
    var unproductiveReconnectsForTesting: Int {
        winCond.lock()
        defer { winCond.unlock() }
        return unproductiveReconnects
    }

    /// Whether a transfer is still installed. A test that needs a range to have COMPLETED, rather
    /// than merely to have delivered, waits on this instead of on a sleep: the completion callback
    /// is what clears `activeTask`, and that clearing is the state the behaviour turns on.
    var hasLiveConnectionForTesting: Bool {
        winCond.lock()
        defer { winCond.unlock() }
        return activeTask != nil
    }

    var persistentTaskIsSuspendedForTesting: Bool {
        winCond.lock()
        defer { winCond.unlock() }
        return persistentTaskSuspended
    }

    /// #220: bytes the delegate accepted while the task was ALREADY flagged suspended.
    /// The #174 comment prices this as "the transport's in-flight amount", i.e. a bounded
    /// overshoot. If it instead tracks the whole window, `suspend()` is not stopping delivery
    /// and the 16 MB high water bounds nothing. winCond-guarded.
    private var suspendedDeliveryBytes: Int64 = 0

    /// #220: set when WE ended the connection at `winHardCap`, so the read loop re-requests at
    /// the frontier without charging the reconnect to the unproductive-reconnect streak. Left
    /// unset, a deliberate cap would spend the streak that exists to detect a dead source and
    /// `recordReconnectAndShouldGiveUp` would kill the reader on a perfectly healthy link.
    /// winCond-guarded, cleared by `startPersistentConnection`.
    private var connEndedByBackpressure = false

    /// #220: last byte the live connection was asked for, nil when the request was open-ended
    /// (live sources, and any source whose total size is not resolved yet). winCond-guarded.
    private var connRangeEnd: Int64?

    /// #220: set when the connection ended because its range was delivered in full. That is a
    /// planned end, not a failure, and must not be charged to the reconnect budgets. Mirrors
    /// `connEndedByBackpressure`; cleared by `startPersistentConnection`.
    private var connEndedAtRangeEnd = false

    /// First byte the live connection was asked for. Distinct from `winStart` since #295: a
    /// continuation keeps the resident window, so the window no longer begins where the request
    /// did, and the checks that need the REQUESTED offset (a 200 that ignored Range, the size
    /// derived from a from-zero response) must not read the window's start instead. winCond-guarded.
    private var connRequestedOffset: Int64 = 0

    /// #220: winCond-guarded snapshot of the sliding window for the periodic memprobe.
    /// `ahead` is the undrained forward extent, the quantity `appendPersistentData` gates
    /// the suspend on, so a window sitting far above winHighWater with `suspended=false` is
    /// backpressure that never engaged rather than a transport overshoot. `postSuspend`
    /// separates those two: it is what arrived after the suspend was issued.
    var windowDiagnostics: (windowBytes: Int, aheadBytes: Int, suspended: Bool, postSuspendBytes: Int64) {
        winCond.lock()
        defer { winCond.unlock() }
        return (window.count,
                window.count - max(0, Int(position - winStart)),
                persistentTaskSuspended,
                suspendedDeliveryBytes)
    }
    // #93 restart latency diagnostics (winCond-guarded): bytes dropped by the stale-generation
    // guard, plus per-generation time-to-first-data tracking.
    private var staleGenDroppedBytes: Int64 = 0
    private var connStartedAt = DispatchTime.now()
    private var connFirstDataSeen = false
    // Consecutive unproductive reconnects (demux-thread-only).
    private var unproductiveReconnects = 0
    private var bytesAtLastReconnect: Int64 = 0
    // Consecutive 429/503 attempts; survives seekReconnect, resets on real read progress (#71).
    private var rateLimitStreak = 0

    /// Detour LRU block cache (its own leaf lock, never held across `fetchChunk`/network or
    /// `winCond`). Stores only full-size blocks; short bodies are served once but never cached
    /// (see serveFromDetour), so eviction never shadows a re-fetchable tail. Pure copy/eviction
    /// math lives on the cache and is unit-tested without any network.
    private let detourCache = DetourBlockCache(blockSize: AVIOReader.detourBlockSize,
                                               maxBlocks: AVIOReader.detourMaxBlocks)
    // Re-anchor run tracking (demux-thread-only): the file offset the next sequential detour read
    // would continue from, and how many contiguous bytes the current detour run has served.
    private var detourRunNextExpected: Int64 = -1
    private var detourRunBytes: Int64 = 0

    // MARK: - Cold-start spans (#281)

    /// The head of the FILE, retained for the open phase as the data connection delivers it, so the
    /// return trip after a parse excursion is a copy rather than a connection.
    ///
    /// #281 parked the window at seek time instead, cut from `winStart`, on the reasoning that the
    /// demuxer returns to the window's start. It returns to the FILE's start: measured landings of
    /// 48, 1161, 5752 across six container layouts and 265159 in a field trace. The two coincide
    /// only while the parse seeks away before reading anything, and the parked copy served nothing
    /// on any layout measured, so it is gone. Collected as the bytes arrive rather than copied at
    /// seek time, because `trimWindowLocked` has dropped the head long before a seek asks for it.
    /// winCond-guarded.
    private var headSpan: Data = Data()

    /// Speculative tail bytes fetched alongside `open()`. winCond-guarded: the fetch completes on a
    /// URLSession queue while the demux thread reads.
    private var tailSpan: ResidentSpan?

    /// In-flight speculative tail fetch, cancelled by `close()`.
    private var tailPrefetchTask: URLSessionDataTask?

    /// Whether that fetch is still outstanding, and when it went out. A read landing in its range
    /// waits for it rather than connecting past bytes that are already on the wire, so this is the
    /// difference between the fetch being an optimisation and being a wasted request. Cleared by
    /// the fetch's own completion, by `markClosed` and by `close`, each of which broadcasts.
    /// winCond-guarded.
    private var tailPrefetchInFlight = false
    private var tailPrefetchStartedAt = DispatchTime.now()

    /// One log line per span per open, not per serve. winCond-guarded (set from the read loop).
    private var headSpanServeLogged = false
    private var headSpanPlaybackServeLogged = false
    private var tailSpanServeLogged = false

    /// Measured time to first data of the most recent connection: what one round trip against this
    /// origin actually costs, which is the only honest bound on how long waiting for in-flight bytes
    /// can be worth. winCond-guarded (written by the delegate thread).
    private var lastFirstDataMs: Double = 0

    /// True from `open()` until the demuxer reports its header/stream-info pass done. The parse
    /// seeks this fix targets all happen inside that window; a far seek afterwards is a real scrub,
    /// where the old window is worthless and parking it would only cost memory.
    /// winCond-guarded.
    private var openPhaseActive = false

    /// Playback path (known size + prefetch) or live feeds. Live always uses the
    /// persistent reader; the streaming reader has no reconnect machinery.
    private var usePersistentReader: Bool {
        if isLive { return prefetchEnabled }
        return !isStreaming && prefetchEnabled
    }

    /// True for endless live feeds. Suppresses `position >= fileSize` EOF synthesis;
    /// reports EIO (-5) instead of EOF when the reconnect cap is hit.
    let isLive: Bool

    /// Detour cache is VOD-only: live feeds have no meaningful random access and a
    /// non-authoritative size, so they stay on the unchanged reconnect path.
    private var detourEligible: Bool { !isLive && fileSize > 0 }

    /// Timestamp of the last unplanned reconnect (drop/stall, not a seek).
    /// Producer correlates with a backward source-PTS reset to detect Jellyfin
    /// transcode respawn (re-serves from byte 0 on re-GET, invisible at byte level).
    /// Demux-thread-only (AVIO callback executes synchronously inside av_read_frame).
    private(set) var lastUnplannedReconnectAt: Date?

    /// Seekable-path per-chunk Range-request budget (seconds) and retry passes.
    /// Defaults preserve the historical playback/probe behaviour; still extraction
    /// passes smaller values so a stalled scrub thumbnail aborts fast (issue #27).
    private let chunkRequestTimeout: TimeInterval
    private let chunkMaxRetries: Int

    /// TEST-ONLY slow-CDN throttle (kbit/s, 0 = unlimited), captured once from the static hook at init.
    private let throttleKbps: Int
    private var throttleVClockNs: UInt64 = 0
    private let throttleLock = NSLock()

    /// #240: which reader this is, for the connection log. Several readers run against the same
    /// origin at once and the line used to name none of them.
    private let label: String

    init(url: URL, extraHeaders: [String: String] = [:], label: String = "source", chunkSize: Int = 4 * 1024 * 1024, prefetchEnabled: Bool = true, isLive: Bool = false, chunkRequestTimeout: TimeInterval = 35, chunkMaxRetries: Int = 3, boundedInitialFetch: Int64? = nil) {
        self.url = url
        self.label = label
        self.extraHeaders = extraHeaders
        self.chunkSize = chunkSize
        self.prefetchEnabled = prefetchEnabled
        self.isLive = isLive
        self.chunkRequestTimeout = chunkRequestTimeout
        self.chunkMaxRetries = max(1, chunkMaxRetries)
        self.boundedInitialFetch = boundedInitialFetch.map { max(1, $0) }
        self.throttleKbps = AetherEngine.sourceThrottleKbpsForTesting
    }

    /// Slow-CDN simulation: hold delivered bytes to `throttleKbps` by sleeping the demux thread before the
    /// bytes reach the demuxer. No-op unless the test hook is set. Lock-guarded: prefetch and demux paths
    /// can both deliver. Sleeping here is consistent with the existing reconnect backoff on this thread.
    private func applyThrottle(deliveredBytes: Int) {
        guard throttleKbps > 0, deliveredBytes > 0 else { return }
        throttleLock.lock()
        let sleepNs = SourceThrottle.advance(
            vclockNs: &throttleVClockNs,
            nowNs: DispatchTime.now().uptimeNanoseconds,
            deliveredBytes: deliveredBytes,
            kbps: throttleKbps
        )
        throttleLock.unlock()
        if sleepNs > 0 { Thread.sleep(forTimeInterval: Double(sleepNs) / 1_000_000_000) }
    }

    private func applyExtraHeaders(_ request: inout URLRequest) {
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    func open() throws {
        guard let buf = av_malloc(Int(Self.avioBufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.avioBufferSize,
            0,
            opaque,
            readCallback,
            nil,
            seekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }

        context = ctx

        if prefetchEnabled {
            // #281: the parse seeks that follow this open are what the retained head exists for.
            winCond.lock()
            openPhaseActive = true
            winCond.unlock()
            // #281: issued BEFORE the data connection so it overlaps the round trip that follows,
            // rather than queueing behind it. It asks for a suffix range, which needs no size and
            // therefore needs nothing this open has learned yet.
            startTailPrefetch()
            // Playback path. The persistent connection's `Range: bytes=0-` request is itself
            // the size probe: its 206 Content-Range is folded into fileSize by
            // persistentReceivedResponse (issue #70), so the common case skips the dedicated
            // probeFileSize() round-trip (and its HEAD fallback, the request some origins 429).
            startPersistentConnection(at: 0, boundedTo: boundedInitialFetch)
            let gotData = awaitFirstPersistentData()
            // AE#140: an HLS playlist URL misrouted onto the raw-byte live path. A live origin serves the
            // finite #EXTM3U body at HTTP 200 and closes the connection; the endless-feed reader then
            // re-fetches that body forever. Those reconnects look PRODUCTIVE (a full body at 200, and every
            // find_stream_info probe seek resets the unproductive streak via seekReconnect), so the #71
            // give-up counters never trip, avformat_open_input never returns, and load() hangs with no
            // terminal state. Fail closed here, before the reconnect loop is ever entered: a raw media
            // container never begins with '#' (TS syncs on 0x47; MP4/MKV open with binary box/EBML markers),
            // so an #EXTM3U prefix is an unambiguous misroute. The host is pointed at the HLS entry points.
            if isLive, gotData, Self.bodyBeginsWithHLSPlaylistTag(firstWindowPrefix()) {
                EngineLog.emit("[AVIOReader] HLS playlist body on the raw live path (AE#140); failing closed. Use LoadOptions.nativeRemoteHLS or HLSLiveIngestReader for m3u8 sources.", category: .demux)
                markClosed()
                close()
                throw AVIOReaderError.hlsPlaylistOnRawLivePath
            }
            // AE#154: same classification on the non-live path. FFmpeg (--disable-network) can
            // neither probe an m3u8 behind a custom pb (no extension / MIME hint reaches the hls
            // probe) nor fetch a variant, so avformat_open_input dies with AVERROR_INVALIDDATA.
            // Fail typed instead; load() reroutes the URL onto the native remote-HLS bypass.
            if !isLive, gotData, Self.bodyBeginsWithHLSPlaylistTag(firstWindowPrefix()) {
                EngineLog.emit("[AVIOReader] HLS playlist body on the VOD loopback path (AE#154); rerouting to the native remote-HLS bypass.", category: .demux)
                markClosed()
                close()
                throw AVIOReaderError.hlsPlaylistOnVODPath
            }
            var tookFallback = false
            if !isLive {
                // Atomically decide, under winCond, whether the optimistic connection resolved
                // a size; if not, abandon it (generation bump ignores a size landing in the
                // race window). fileSize is read under the lock because the delegate thread now
                // writes it (issue #70 review #4/#5).
                let (haveSize, abandonedTask, wasSuspended) = resolveOptimisticOpen()
                if wasSuspended { abandonedTask?.resume() }
                abandonedTask?.cancel()
                if !haveSize {
                    // The data connection resolved no size (no-length origin, a transient 429,
                    // slow headers, or an origin whose length only comes via HEAD). Fall back to
                    // the exact pre-#70 probe path (Range bytes=0- then HEAD, on its own
                    // connection and budget): it keeps seekability whenever a size is reachable
                    // and only streams on a genuinely length-less source, restoring main's
                    // resilience to all of those cases (issue #70 review #1/#3/#4).
                    tookFallback = true
                    EngineLog.emit("[AVIOReader] Data connection resolved no size, falling back to probe", category: .demux, level: .verbose)
                    fileSize = resolveInitialFileSize()
                    if isStreaming {
                        startStreamingDownload()
                        _ = streamDataReady.wait(timeout: .now() + .seconds(15))
                    } else {
                        startPersistentConnection(at: 0)
                        if !awaitFirstPersistentData() {
                            EngineLog.emit("[AVIOReader] Persistent open (post-probe): no data within 15s, proceeding to read-loop reconnect", category: .demux)
                        }
                    }
                }
            }
            if !tookFallback && !gotData {
                // No first byte within 15s; read loop's stall/reconnect machinery takes over.
                EngineLog.emit("[AVIOReader] Persistent open: no first byte within 15s, proceeding to read-loop reconnect", category: .demux)
            }
        } else {
            // Non-prefetch (still extraction / one-shot seekable): the size is needed up
            // front for SEEK_END and container index seeks, so keep the dedicated probe.
            fileSize = resolveInitialFileSize()
            if isStreaming {
                startStreamingDownload()
                _ = streamDataReady.wait(timeout: .now() + .seconds(15))
            } else {
                if let data = fetchChunk(from: 0, size: chunkSize) {
                    currentBuffer = data
                    currentOffset = 0
                }
            }
        }

        // #126: a VOD source that finishes open() without a resolved size runs the forward-only
        // streaming reader; FFmpeg must not believe pb is seekable. With a seekable-flagged pb the
        // mov demuxer far-forward-skips to a tail moov (buffering the entire skipped span in RAM),
        // parses an index it can never rewind to, and every sample read then dies with "partial
        // file" / zero produced packets. Non-seekable pb makes moov-at-end fail cleanly at open
        // and keeps faststart files on honest sequential reads.
        if !isLive, isStreaming, let ctx = context {
            ctx.pointee.seekable = 0
        }
    }

    /// Block up to 15s for the persistent connection's first window bytes. The response
    /// (and thus any Content-Range size) has already been processed by the time data
    /// arrives. Demux thread, open-time only. Returns true if data arrived.
    private func awaitFirstPersistentData() -> Bool {
        winCond.lock()
        let deadline = Date(timeIntervalSinceNow: 15)
        while window.isEmpty && !connEnded && !isClosed {
            if !winCond.wait(until: deadline) { break }
        }
        let gotData = !window.isEmpty
        winCond.unlock()
        return gotData
    }

    /// Snapshot up to `max` leading bytes of the first window (open-time, before any read has consumed
    /// it, so `winStart == 0`). winCond-guarded like every other window access. Used only by the AE#140
    /// misroute check; returns [] if no data has arrived.
    private func firstWindowPrefix(max: Int = 16) -> [UInt8] {
        winCond.lock()
        defer { winCond.unlock() }
        let n = Swift.min(max, window.count)
        return n > 0 ? Array(window.prefix(n)) : []
    }

    /// True when a body's leading bytes are the HLS playlist tag `#EXTM3U`, tolerating a UTF-8 BOM and
    /// leading ASCII whitespace. A raw media container never opens with '#', so this is an unambiguous
    /// signal that an m3u8 playlist was handed to the raw-byte reader (AE#140). Static + internal so the
    /// classifier is unit-tested without a live origin.
    static func bodyBeginsWithHLSPlaylistTag(_ bytes: [UInt8]) -> Bool {
        var i = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D {
            i += 1
        }
        let tag = Array("#EXTM3U".utf8)
        guard bytes.count - i >= tag.count else { return false }
        return Array(bytes[i..<(i + tag.count)]) == tag
    }

    /// Under a single winCond critical section: snapshot whether the optimistic open-time
    /// connection resolved a size (fileSize > 0, written by the delegate thread in
    /// persistentReceivedResponse), and if not, atomically abandon that connection so the
    /// open can fall back to the probe path. Bumping the generation inside the same lock as
    /// the read means a size that lands in the race window is ignored rather than racing a
    /// half-done teardown (issue #70 review #4/#5). Returns the session to cancel outside
    /// the lock. Demux thread, open-time only; leaves the AVIO context intact (unlike close()).
    private func resolveOptimisticOpen() -> (haveSize: Bool, abandonedTask: URLSessionDataTask?, wasSuspended: Bool) {
        winCond.lock()
        defer { winCond.unlock() }
        if fileSize > 0 { return (true, nil, false) }
        connGeneration &+= 1
        let task = activeTask
        let suspended = persistentTaskSuspended
        persistentTaskSuspended = false
        activeTask = nil
        window = Data()
        connEnded = true
        winCond.broadcast()
        return (false, task, suspended)
    }

    // Close flags written on the teardown thread (markClosed / fullyClose) and read on the demux
    // thread plus the URLSession delegate threads (persistent-connection callbacks). Backed by a
    // leaf unfair lock so every access is synchronized; the bare Bools were a TSan-confirmed data
    // race (markClosed write vs appendPersistentData read). The lock is only ever held for the
    // get/set itself (never across another lock), so it cannot invert with winCond/streamLock.
    private let isClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isClosed: Bool {
        get { isClosedLock.withLock { $0 } }
        set { isClosedLock.withLock { $0 = newValue } }
    }
    private let isFullyClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isFullyClosed: Bool {
        get { isFullyClosedLock.withLock { $0 } }
        set { isFullyClosedLock.withLock { $0 = newValue } }
    }

    /// #112 round 8: the resolved total byte size (Content-Length / Content-Range), nil until known.
    /// Read under winCond like every other fileSize access. Used by `Demuxer.seekByteEstimate` for the
    /// single-probe byte-position fallback when a timestamp seek on an index-less container times out.
    var resolvedByteSize: Int64? {
        winCond.lock()
        defer { winCond.unlock() }
        return fileSize > 0 ? fileSize : nil
    }

    /// Wall-clock deadline for reads. Armed by `beginReadDeadline` to abort
    /// a `avformat_seek_file` that degrades into a linear scan when MKV Cues
    /// index is missing or past EOF (tens of minutes on remote sources).
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    /// Set when a read returned early due to deadline. `seekBounded` uses this
    /// since matroska may still return success with a partial index after abort.
    private(set) var readDeadlineFired = false

    /// Contract: `readDeadline`/`readDeadlineFired` are demux-thread-only. The
    /// still-extraction (FrameExtractor) reader satisfies this because it runs on one
    /// serial decode queue and `avioPrefetch:false` means no background prefetch thread
    /// touches them. A future profile that re-enables prefetch on a deadline-armed
    /// reader would need these guarded.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        readDeadlineFired = false
        readDeadline = Date(timeIntervalSinceNow: seconds)
        // Wake a read already parked in the forward-wait so it re-evaluates
        // against the new deadline instead of sleeping the full stall window.
        winCond.lock()
        winCond.broadcast()
        winCond.unlock()
    }

    func endReadDeadline() {
        readDeadline = .distantFuture
    }

    /// Deadline expired; latches `readDeadlineFired` at the check sites.
    private var readDeadlinePassedOrAborted: Bool { isPastReadDeadline }

    // Streaming task/session held so teardown can cancel and unblock streamDownloadSync.
    private var streamingSession: URLSession?
    private var streamingTask: URLSessionDataTask?
    // Suspend/resume calls are balanced under streamLock.
    private var streamingTaskSuspended = false

    /// Unblock a suspended av_read_frame and release the live network connection.
    /// Must be called BEFORE acquiring the demuxer's access lock.
    func markClosed() {
        isClosed = true
        // Wake any semaphore waits so the read callbacks can exit
        prefetchReady.signal()
        streamDataReady.signal()
        streamLock.lock()
        let sTask = streamingTask
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        sTask?.cancel()
        winCond.lock()
        connGeneration &+= 1
        // #93/#96 residual: cancel the persistent Range GET here, not only in close(). markClosed is
        // the abort used by the #79 reopen path (dem.markClosed() to unblock a wedged read); leaving
        // its long-lived open-ended connection alive lets it keep draining the origin for the whole
        // reopen + first-read window, and that connection fair-shares the origin's bandwidth with the
        // fresh reader's cold read, which is exactly the per-connection starvation behind the residual
        // 15-30s cold reads. The AVIO context is untouched (close() still frees it); only the socket
        // is released. Grab under winCond, invalidate outside it (mirrors close()).
        let task = activeTask
        let persistentWasSuspended = persistentTaskSuspended
        persistentTaskSuspended = false
        activeTask = nil
        connEnded = true
        // #281: a speculative fetch outlives nothing. Same reasoning as the persistent GET above:
        // an abandoned reader's in-flight request fair-shares the origin with the fresh reader's
        // cold read, which is the starvation this whole area keeps paying for.
        let tailTask = tailPrefetchTask
        tailPrefetchTask = nil
        tailPrefetchInFlight = false
        openPhaseActive = false
        winCond.broadcast()
        winCond.unlock()
        if persistentWasSuspended { task?.resume() }
        task?.cancel()
        tailTask?.cancel()
    }

    /// Free all resources. Separate from `markClosed` (step 1: unblock reads)
    /// because `isClosed` alone can't gate this: prior misuse of that guard
    /// silently leaked 64 MB current + 64 MB prefetch buffers on teardown.
    /// `isFullyClosed` is the idempotency latch for this step.
    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if let ctx = context {
            // avio_context_free does NOT free ctx->buffer (verified, aviobuf.c).
            // Free ctx.pointee.buffer, not original av_malloc ptr: FFmpeg can
            // realloc internally via ffio_set_buf_size.
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil

        bufferLock.lock()
        currentBuffer = Data()
        prefetchBuffer = nil
        bufferLock.unlock()

        detourCache.clear()

        streamLock.lock()
        streamEnded = true
        streamBuffer = Data()
        let sTask = streamingTask
        let sSession = streamingSession
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamingTask = nil
        streamingSession = nil
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        streamDataReady.signal()
        // Covers a close() without prior markClosed().
        sTask?.cancel()
        sSession?.invalidateAndCancel()

        winCond.lock()
        connGeneration &+= 1
        connEnded = true
        let task = activeTask
        let persistentWasSuspended = persistentTaskSuspended
        persistentTaskSuspended = false
        activeTask = nil
        window = Data()
        // #281: both spans hold real bytes (up to headSpanMaxBytes + tailPrefetchBytes), so they
        // are released with the window rather than living until the reader is deallocated.
        headSpan = Data()
        tailSpan = nil
        openPhaseActive = false
        let tailTask = tailPrefetchTask
        tailPrefetchTask = nil
        tailPrefetchInFlight = false
        winCond.broadcast()
        winCond.unlock()
        tailTask?.cancel()
        if persistentWasSuspended { task?.resume() }
        // #220: the shared session is never invalidated, so the task has to be cancelled
        // explicitly. Invalidating used to be what released this connection.
        task?.cancel()
    }

    // MARK: - Read (called by FFmpeg on demux thread)

    // Internal (not fileprivate) so the #174 backpressure tests can drive the consumer
    // side directly; production entry stays the C read callback below.
    func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard !isClosed else { return -1 }
        if readDeadlinePassedOrAborted { readDeadlineFired = true; return -1 }
        // Check usePersistentReader before isStreaming: live feeds without
        // Content-Length must use the reconnect-capable persistent path.
        let n: Int32
        if usePersistentReader { n = readPersistent(into: buf, size: size) }
        else if isStreaming { n = readStreaming(into: buf, size: size) }
        else { n = readSeekable(into: buf, size: size) }
        if n > 0 { applyThrottle(deliveredBytes: Int(n)) }
        return n
    }

    // MARK: - Seekable Read (Range-based)

    private func readSeekable(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            // Abort a superseded / torn-down / past-deadline still read between chunk
            // fetches so it cannot park the decode queue (issue #27). Mirrors the
            // checks readPersistent already does at its loop head.
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            bufferLock.lock()
            let bufEnd = currentOffset + Int64(currentBuffer.count)
            let inRange = position >= currentOffset && position < bufEnd
            bufferLock.unlock()

            if inRange {
                bufferLock.lock()
                let offsetInBuffer = Int(position - currentOffset)
                let available = currentBuffer.count - offsetInBuffer
                let toCopy = min(available, requestSize - totalRead)

                currentBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: offsetInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                position += Int64(toCopy)
                totalRead += toCopy

                let consumed = Double(position - currentOffset) / Double(currentBuffer.count)
                let nextPrefetchOffset = currentOffset + Int64(currentBuffer.count)
                let needsPrefetch = prefetchEnabled && consumed > 0.5 && !isPrefetching && prefetchBuffer == nil
                bufferLock.unlock()

                if needsPrefetch {
                    triggerPrefetch(from: nextPrefetchOffset)
                }
            } else {
                bufferLock.lock()
                if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                    position < prefetchOffset + Int64(prefetch.count) {
                    currentBuffer = prefetch
                    currentOffset = prefetchOffset
                    prefetchBuffer = nil
                    bufferLock.unlock()
                    continue
                }
                let hasPrefetchInFlight = isPrefetching
                bufferLock.unlock()

                if hasPrefetchInFlight {
                    _ = prefetchReady.wait(timeout: .now() + .seconds(15))
                    bufferLock.lock()
                    if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                        position < prefetchOffset + Int64(prefetch.count) {
                        currentBuffer = prefetch
                        currentOffset = prefetchOffset
                        prefetchBuffer = nil
                        bufferLock.unlock()
                        continue
                    }
                    bufferLock.unlock()
                }

                let fetchSize: Int
                if fileSize > 0 {
                    fetchSize = min(chunkSize, Int(fileSize - position))
                } else {
                    fetchSize = chunkSize
                }

                if fetchSize <= 0 { break }

                guard let data = fetchChunk(from: position, size: fetchSize), !data.isEmpty else {
                    // An aborted fetch (supersede/close/deadline) must report a read
                    // error, not EOF (which would truncate the stream cleanly). issue #27.
                    if isClosed || readDeadlinePassedOrAborted {
                        if readDeadlinePassedOrAborted { readDeadlineFired = true }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    // nil = transport failure; empty = 2xx with no body (would loop forever otherwise).
                    break
                }

                bufferLock.lock()
                currentBuffer = data
                currentOffset = position
                prefetchBuffer = nil
                bufferLock.unlock()
            }
        }

        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
    }

    // MARK: - Streaming Read (sequential GET)

    private func readStreaming(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            streamLock.lock()
            let posInBuffer = Int(position - streamBytesRead)
            let available = streamBuffer.count - posInBuffer
            let ended = streamEnded
            streamLock.unlock()

            if available > 0 && posInBuffer >= 0 {
                let toCopy = min(available, requestSize - totalRead)

                streamLock.lock()
                streamBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: posInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                streamLock.unlock()

                position += Int64(toCopy)
                totalRead += toCopy

                // subdata (not removeFirst): removeFirst leaks backing storage (see trimWindowLocked).
                streamLock.lock()
                let consumed = Int(position - streamBytesRead)
                if consumed > Self.streamTrimThreshold {
                    let trimAmount = consumed - Self.streamTrimThreshold
                    streamBuffer = streamBuffer.subdata(in: trimAmount..<streamBuffer.count)
                    streamBytesRead += Int64(trimAmount)
                }
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended, streamBuffer.count < Self.streamLowWater {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
            } else if ended {
                break
            } else {
                // Resume before waiting: a suspended task would never deliver.
                streamLock.lock()
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
                let timeout = streamDataReady.wait(timeout: .now() + .seconds(15))
                if timeout == .timedOut { break }
            }
        }

        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
    }

    // MARK: - Persistent Read (single forward-streaming connection)

    /// Sliding-window read over a single long-lived Range: bytes=<offset>- connection.
    /// State machine: inside window -> copy; before window -> backward reconnect;
    /// position >= fileSize -> EOF (only EOF path); far forward -> reconnect;
    /// just ahead + live conn -> wait; conn ended -> reconnect + backoff.
    /// Fetch failures reconnect at the frontier, never collapse to AVERROR_EOF (AetherEngine#25).
    private func readPersistent(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        // #93 restart latency: accumulate where THIS read spends its time; one summary line fires
        // on completion when the whole call exceeded the threshold (see SlowReadDiagnostics).
        let readStart = DispatchTime.now()
        var diag = SlowReadDiagnostics()
        // #281 retest: fixed once per read, so a loop that wakes repeatedly cannot keep extending
        // its own patience for the speculative fetch.
        var tailWaitDeadline: Date?
        func msSince(_ t: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        }
        // #93/#96 residual: count the reconnect AND time the synchronous connect path it drives
        // (the old session's invalidateAndCancel + new task setup, all on this demux thread), so a
        // slow read that sinks its time into reconnecting names it as `connect=` instead of `unaccounted=`.
        func timedReconnect(seek: Bool, at offset: Int64) {
            diag.recordReconnect()
            let connectStart = DispatchTime.now()
            if seek { seekReconnect(at: offset) } else { startPersistentConnection(at: offset) }
            diag.recordConnect(ms: msSince(connectStart))
        }
        winCond.lock()
        let diagEntryPosition = position
        let diagGenAtStart = connGeneration
        let diagDropsAtStart = staleGenDroppedBytes
        winCond.unlock()
        defer {
            let elapsedMs = msSince(readStart)
            if elapsedMs >= diag.thresholdMs {
                winCond.lock()
                let genAtEnd = connGeneration
                let dropped = staleGenDroppedBytes - diagDropsAtStart
                winCond.unlock()
                diag.recordStaleGenerationDrop(bytes: dropped)
                if let line = diag.line(elapsedMs: elapsedMs, offset: diagEntryPosition,
                                        generationSpan: (diagGenAtStart, genAtEnd)) {
                    EngineLog.emit(line, category: .demux)
                }
            }
        }

        while totalRead < requestSize {
            diag.recordIteration()
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            // #93/#96 residual: time the loop-head lock acquisition. A delegate thread holding winCond
            // across its window copy blocks the read HERE with nothing to show for it, so this turns
            // that invisible wait into `lockWait=`.
            let lockWaitStart = DispatchTime.now()
            winCond.lock()
            diag.recordLockWait(ms: msSince(lockWaitStart))

            // #281: bytes already in hand beat every network path below, so this is checked before
            // any of them, and before the reconnect decision that a dead connection would force.
            // Only when the live window cannot serve the position: a window hit is the cheap path
            // and stays first.
            let spanPos = position
            let windowCanServe = spanPos >= winStart && spanPos < winStart + Int64(window.count)

            // #281 retest: the head has now done the job it was kept past the parse for. This read
            // is not at the head, so playback has either moved beyond it or started nowhere near it,
            // and holding megabytes for a return that is not coming is just footprint.
            if !openPhaseActive, !headSpan.isEmpty, spanPos < 0 || spanPos >= Int64(headSpan.count) {
                headSpan = Data()
            }
            if !windowCanServe, !headSpan.isEmpty || tailSpan != nil,
               let served = serveFromResidentSpansLocked(into: buf.advanced(by: totalRead),
                                                        maxLen: requestSize - totalRead,
                                                        at: spanPos) {
                let n = served.bytes
                // Once per span per open: the round trip that did not happen, named. Every serve
                // after the first says nothing new and would only make the log expensive.
                var spanLine: String? = nil
                switch served {
                // Two lines, not one, because they are two different findings: the parse's return to
                // the head was already true in 6.5.2, playback's first read being served is what the
                // head living past `markOpenPhaseFinished` added. One line could not tell a reporter
                // which of the two they were looking at.
                case .head where !openPhaseActive && !headSpanPlaybackServeLogged:
                    headSpanPlaybackServeLogged = true
                    spanLine = "[AVIOReader] \(label) retained file head served playback's first read"
                        + " at \(spanPos); no reconnect for it"
                case .head where !headSpanServeLogged:
                    headSpanServeLogged = true
                    spanLine = "[AVIOReader] \(label) retained file head served the return to \(spanPos)"
                        + "; no reconnect for it"
                case .tail where !tailSpanServeLogged:
                    tailSpanServeLogged = true
                    spanLine = "[AVIOReader] \(label) tail prefetch served the read at \(spanPos)"
                        + "; no reconnect for it"
                default:
                    break
                }
                position = spanPos + Int64(n)
                winCond.broadcast()
                winCond.unlock()
                if let spanLine { EngineLog.emit(spanLine, category: .demux) }
                totalRead += n
                diag.recordDetourServe(ms: 0, fetched: false)
                unproductiveReconnects = 0
                rateLimitStreak = 0
                emitNetworkPhase(.flowing)
                continue
            }

            // #281 retest: this read wants bytes the speculative fetch is on the wire for RIGHT NOW.
            // Reconnecting here is what made that fetch pure cost in the field: the demuxer arrives
            // microseconds after the data connection's first byte, so the fetch, which pays the same
            // round trip plus a body, has never landed yet. Waiting is bounded by what a round trip
            // against this origin was measured to cost, so it can never be the more expensive choice.
            if !windowCanServe, tailPrefetchInFlight, isInTailPrefetchRangeLocked(spanPos) {
                let deadline = tailWaitDeadline ?? Date(
                    timeIntervalSinceNow: max(0, tailPrefetchWaitBudget()
                        - Double(DispatchTime.now().uptimeNanoseconds
                                 - tailPrefetchStartedAt.uptimeNanoseconds) / 1_000_000_000))
                tailWaitDeadline = deadline
                if Date() < deadline {
                    let waitStart = DispatchTime.now()
                    _ = winCond.wait(until: min(deadline, readDeadline))
                    winCond.unlock()
                    diag.recordTailWait(ms: msSince(waitStart))
                    continue
                }
            }

            // Genuine EOF: the only path that returns AVERROR_EOF, and it is decided BEFORE any
            // reconnect, because a position at or past the last byte has nothing to connect for.
            // It used to sit below the reconnect, so a read at exactly `fileSize` opened
            // `bytes=<fileSize>-` first: an empty 206 whose reconnect reset `winStart` past the
            // end and dropped a window the parse was still reading. Skipped for live, where the
            // length is not authoritative.
            if !isLive, fileSize > 0, position >= fileSize {
                winCond.unlock()
                return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
            }

            // #220: `connEndedByBackpressure` is excluded on purpose. This reconnects at the
            // READ position, which resets winStart and drops the window, so a hard-cap end
            // would re-fetch up to winHardCap of already-resident bytes on every cycle. That
            // case falls through to the drained-window path below, which re-requests at the
            // frontier and keeps every delivered byte.
            //
            // `windowCanServe` is excluded for exactly the same reason, and the omission was
            // measurable: a range delivered IN FULL also clears `activeTask`, so a consumer
            // slower than the transfer (the parse pass, which reads one 256 KB AVIO buffer at a
            // time) reached this branch with the rest of the range still resident and re-fetched
            // it. Measured against a Range-logging origin, a 764450 B trailing `moov` cost three
            // connections and 1506918 delivered bytes, 1.97x what was read. Serving what is in
            // hand first also lets the #220 frontier refill below run, which it could not while
            // this branch preempted it on every completed range.
            if activeTask == nil, !connEndedByBackpressure, !windowCanServe {
                let target = position
                winCond.unlock()
                timedReconnect(seek: true, at: target)
                continue
            }

            let curPosition = position

            if curPosition < winStart {
                winCond.unlock()
                // Backward random-access read (MP4 parse ping-pong, or a large backward scrub).
                // Serve via the pooled detour cache so the anchored streaming connection is NOT
                // torn down (the reconnect storm + origin 429, AetherEngine#69).
                if detourEligible {
                    // Re-anchor the streaming connection once detour reads have turned sequential
                    // past the threshold (playback resumed here), so steady playback returns to
                    // the cheap window path instead of fetching 4 MB blocks forever.
                    if curPosition == detourRunNextExpected && detourRunBytes >= Self.detourReanchorBytes {
                        detourResetRun()
                        timedReconnect(seek: true, at: curPosition)
                        continue
                    }
                    let detourStart = DispatchTime.now()
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: true) {
                    case .served(let n):
                        // A resident-block hit is a pure memcpy (sub-ms); anything slower crossed the network.
                        let detourMs = msSince(detourStart)
                        diag.recordDetourServe(ms: detourMs, fetched: detourMs > 2)
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        unproductiveReconnects = 0
                        rateLimitStreak = 0
                        emitNetworkPhase(.flowing)   // detour cache served: not stalled (#85)
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited(let retryAfter):
                        // #93/#96: account the (throttled) fetch attempt's time so it leaves `unaccounted`.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        // Origin is throttling the detour fetch too (#71). Back off in place and
                        // RETRY the detour fetch; do NOT open a fresh connection (that re-enters
                        // the 429 churn the cache exists to remove). Give up cleanly at the cap.
                        if recordRateLimitAndShouldGiveUp() {
                            EngineLog.emit("[AVIOReader] Detour rate-limit gave up at offset \(curPosition) (\(rateLimitStreak) consecutive 429/503)", category: .demux)
                            return totalRead > 0 ? Int32(totalRead) : -1
                        }
                        let backoffStart = DispatchTime.now()
                        backoffBeforeReconnect(streak: rateLimitStreak, retryAfter: retryAfter)
                        diag.recordBackoff(ms: msSince(backoffStart))
                        continue
                    case .miss:
                        // #93/#96: this is where the residual cold read actually lived. A starved fetch
                        // rode its budget then missed; account that time (else it hides in `unaccounted`)
                        // before falling through to the rescue reconnect that serves in ~30-190ms.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
                        if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }
                        // Hard transport failure: degrade to the OLD single-reconnect behavior.
                        timedReconnect(seek: true, at: curPosition)
                        continue
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            let posInWindow = Int(curPosition - winStart)
            let available = window.count - posInWindow
            if available > 0 {
                let copyNow = min(available, requestSize - totalRead)
                window.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: posInWindow)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: copyNow)
                }
                position = curPosition + Int64(copyNow)
                totalRead += copyNow
                trimWindowLocked()
                unproductiveReconnects = 0      // real progress
                rateLimitStreak = 0             // real progress clears the 429 give-up streak (#71)
                emitNetworkPhase(.flowing)      // recovered: source delivering again (#85)
                // #174: resume the suspended transfer once the drain crosses lowWater.
                var toResume: URLSessionDataTask?
                var refillFrom: Int64? = nil
                let undrained = window.count - max(0, Int(position - winStart))
                if persistentTaskSuspended, undrained <= Self.winLowWater {
                    persistentTaskSuspended = false
                    toResume = activeTask
                }
                // #220: the range ended on purpose and the consumer has now drawn down far
                // enough that the next one should already be in flight. Requesting at the
                // frontier rather than at the read position keeps every delivered byte, and
                // doing it here rather than on an empty window is what stops a range boundary
                // from becoming a stall.
                // A frontier AT the end of the file is not a frontier. The range that ended was the
                // last one, and requesting `bytes=<fileSize>-` asks for nothing: origins answer it
                // with an empty 206, the reconnect resets `winStart` past the last byte, and the
                // window that was about to be read is dropped for it. On a trailing `moov` that
                // turned one connection into three, since the parse then had to re-fetch what it
                // had just been handed. Live keeps the old behaviour: its length is not
                // authoritative and its end moves.
                let frontier = winStart + Int64(window.count)
                if connEndedAtRangeEnd, activeTask == nil, undrained <= Self.winLowWater,
                   isLive || fileSize <= 0 || frontier < fileSize {
                    refillFrom = frontier
                }
                winCond.broadcast()
                winCond.unlock()
                toResume?.resume()
                if let refillFrom { timedReconnect(seek: false, at: refillFrom) }
                continue
            }

            let frontier = winStart + Int64(window.count)
            let ended = connEnded
            let endedByBackpressure = connEndedByBackpressure
            let endedByRangeEnd = connEndedAtRangeEnd
            let status = connStatus
            let retryAfter = connRetryAfter

            if curPosition > frontier + Int64(Self.seekKeepForwardLimit) {
                winCond.unlock()
                // Far-forward seek. Serve from the detour cache ONLY if the block is already
                // resident (e.g. the moov region the parser revisits); a genuine forward scrub
                // misses and re-anchors the streaming window there, never chunk-serving forever.
                if detourEligible {
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: false) {
                    case .served(let n):
                        diag.recordDetourServe(ms: 0, fetched: false)   // resident-only path
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        unproductiveReconnects = 0
                        rateLimitStreak = 0
                        emitNetworkPhase(.flowing)   // detour cache served: not stalled (#85)
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited, .miss:
                        break   // allowFetch:false never rate-limits; a miss falls through to reconnect
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            if !ended {
                // #174: a suspended task never delivers; resume before waiting (mirrors
                // readStreaming). Reached when a within-window forward seek lands at the
                // frontier while the transfer is parked above lowWater.
                if persistentTaskSuspended {
                    persistentTaskSuspended = false
                    let toResume = activeTask
                    winCond.unlock()
                    toResume?.resume()
                    continue
                }
                // Wait for the live connection to fill forward. A false return
                // means connStallTimeout elapsed with no data (socket stall).
                let waitStart = DispatchTime.now()
                let signaled = winCond.wait(until: min(Date(timeIntervalSinceNow: Self.connStallTimeout), readDeadline))
                winCond.unlock()
                diag.recordStallWait(ms: msSince(waitStart), signaled: signaled)
                // Check deadline before stall handling to avoid misrouting a
                // deadline wake as a socket stall (which would reconnect).
                if isPastReadDeadline { continue }
                if !signaled {
                    if recordReconnectAndShouldGiveUp() {
                        EngineLog.emit("[AVIOReader] \(label) stall gave up at offset \(frontier) (\(unproductiveReconnects) unproductive)\(isLive ? " [live source lost]" : "")", category: .demux)
                        emitNetworkPhase(.flowing)   // reader is exiting; let state carry the terminal outcome (#85)
                        if isLive {
                            return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                        }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    EngineLog.emit("[AVIOReader] \(label) stall at offset \(frontier), reconnecting", category: .demux)
                    lastUnplannedReconnectAt = Date()
                    emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
                    let backoffStart = DispatchTime.now()
                    backoffBeforeReconnect(streak: unproductiveReconnects, retryAfter: 0)
                    diag.recordBackoff(ms: msSince(backoffStart))
                    timedReconnect(seek: false, at: frontier)
                }
                continue
            }

            // Connection ended before EOF; reconnect at frontier. Honour Retry-After for 429/503.
            winCond.unlock()
            // #220: we ended it ourselves at the hard cap and the consumer has now drained the
            // window. Re-request immediately: no backoff (the origin never misbehaved), no
            // streak charge (this is not an unproductive reconnect), no `.reconnecting` phase
            // and no `lastUnplannedReconnectAt` (nothing here looks like a transcode respawn to
            // the host). Without this the cap would spend the give-up budget on a healthy link.
            if endedByBackpressure {
                EngineLog.emit(
                    "[AVIOReader] \(label) window drained after hard cap; re-requesting at \(frontier)",
                    category: .demux)
                timedReconnect(seek: false, at: frontier)
                continue
            }
            // #220: the range was delivered in full and the window has now drained, which is
            // the ordinary way a bounded read moves forward. No backoff and no streak charge:
            // nothing failed, and spending the give-up budget on range boundaries would kill
            // the reader on a healthy link.
            if endedByRangeEnd {
                timedReconnect(seek: false, at: frontier)
                continue
            }
            // A 429/503 is rate limiting, not a dead source: drive give-up + backoff off the
            // rate-limit streak, which (unlike unproductiveReconnects) survives the seekReconnect
            // that parse seeks fire, so a throttled origin fails cleanly instead of looping (#71).
            let isRateLimited = (status == 429 || status == 503)
            let giveUp = isRateLimited ? recordRateLimitAndShouldGiveUp()
                                       : recordReconnectAndShouldGiveUp(status: status)
            if giveUp {
                let streakDesc = isRateLimited ? "\(rateLimitStreak) consecutive 429/503" : "\(unproductiveReconnects) unproductive"
                EngineLog.emit("[AVIOReader] \(label) reconnect exhausted at offset \(frontier) status=\(status) (\(streakDesc))\(isLive ? " [live source lost]" : "")", category: .demux)
                emitNetworkPhase(.flowing)   // reader is exiting; let state carry the terminal outcome (#85)
                if isLive {
                    return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                }
                return totalRead > 0 ? Int32(totalRead) : -1
            }
            let backoffStreak = isRateLimited ? rateLimitStreak : unproductiveReconnects
            EngineLog.emit("[AVIOReader] \(label) conn ended at offset \(frontier) status=\(status), reconnecting (streak=\(backoffStreak) retryAfter=\(retryAfter)s)", category: .demux)
            lastUnplannedReconnectAt = Date()
            emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
            let backoffStart = DispatchTime.now()
            backoffBeforeReconnect(streak: backoffStreak, retryAfter: retryAfter)
            diag.recordBackoff(ms: msSince(backoffStart))
            timedReconnect(seek: false, at: frontier)
        }

        return Int32(totalRead)
    }

    /// Drop consumed bytes in ~winTrimBatch steps to avoid O(n^2) memmove.
    /// MUST use `subdata` (not `removeFirst`): removeFirst only advances the slice's
    /// lower bound but backing storage grows with count.setter in appendPersistentData,
    /// leaking ~14 MB/s on 80 Mbps remux (AetherEngine#31). subdata re-bases to compact
    /// storage. Caller holds `winCond`.
    private func trimWindowLocked() {
        let behind = Int(position - winStart)
        let dropThreshold = Self.winLookback + Self.winTrimBatch
        if behind > dropThreshold {
            let drop = behind - Self.winLookback
            window = window.subdata(in: drop..<window.count)
            winStart += Int64(drop)
        }
    }

    /// Intentional reconnect for a seek; clears the unproductive streak.
    private func seekReconnect(at offset: Int64) {
        unproductiveReconnects = 0
        bytesAtLastReconnect = cumulativeBytesFetched
        startPersistentConnection(at: offset)
    }

    /// Increments the unproductive-reconnect streak (resets if progress exceeded
    /// `minReconnectProgress`). Returns true when the cap is hit. Demux-thread-only.
    private func recordReconnectAndShouldGiveUp(status: Int = 0) -> Bool {
        let now = cumulativeBytesFetched
        if now - bytesAtLastReconnect >= Self.minReconnectProgress {
            unproductiveReconnects = 0
        } else {
            unproductiveReconnects += 1
        }
        bytesAtLastReconnect = now
        // Hard 4xx/5xx (not 429/503 which carry Retry-After) on a source that has
        // never delivered a byte = server-side failure (e.g. Jellyfin 500 after
        // transcode-failure latency ~15-20s/attempt). One retry, then out.
        let isHardError = status >= 400 && status != 429 && status != 503
        if now == 0 && isHardError {
            return unproductiveReconnects > 1
        }
        // Dead-on-arrival sources (never produced data) get a reduced budget;
        // sources that ever produced data keep the full budget for mid-stream resilience.
        let cap = now == 0
            ? Self.reconnectMaxUnproductiveNeverProductive
            : Self.reconnectMaxUnproductive
        return unproductiveReconnects > cap
    }

    // 4 attempts ride out a transient transcode spin-up (~10-15s with backoff)
    // without grinding a dead tuner for minutes.
    private static let reconnectMaxUnproductiveNeverProductive = 4

    /// Exponential backoff (0.5s..8s) growing with streak; immediate on streak=0.
    /// Sleeps in 0.1s slices so a close is honoured promptly.
    private func backoffBeforeReconnect(streak: Int, retryAfter: TimeInterval) {
        let expo = streak <= 0 ? 0.0 : min(Double(1 << min(streak, 4)) * 0.5, 8.0)
        let total = min(max(expo, retryAfter), 15.0)
        if total <= 0 { return }
        var slept = 0.0
        while slept < total {
            if isClosed { return }
            Thread.sleep(forTimeInterval: 0.1)
            slept += 0.1
        }
    }

    /// Increments the consecutive 429/503 streak; returns true once the bounded cap is hit.
    /// Demux-thread-only. Deliberately NOT reset by `seekReconnect` (parse seeks must not mask a
    /// throttled origin into an endless reconnect loop, #71); only real read progress clears it.
    /// Internal (not private) so the bounded give-up is unit-tested without a live origin.
    func recordRateLimitAndShouldGiveUp() -> Bool {
        rateLimitStreak += 1
        return rateLimitStreak > Self.rateLimitMaxStreak
    }

    // MARK: - Detour Block Cache (AetherEngine#69)

    private enum DetourServe { case served(Int); case rateLimited(TimeInterval); case miss }
    private enum DetourFetch { case ok(Data); case rateLimited(TimeInterval); case failed }

    /// Serve `[offset, offset+maxLen)` (clamped to one 4 MB block) from the detour cache,
    /// fetching the block over the pooled keep-alive chunkSession on a miss when `allowFetch`.
    /// Demux-thread call; may block on the network via `detourFetchBlock` (no lock held across it).
    /// Returns `.miss` (never `.served(0)`) so callers fall back to a single reconnect.
    private func serveFromDetour(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int,
                                 at offset: Int64, allowFetch: Bool) -> DetourServe {
        guard fileSize > 0, offset < fileSize, maxLen > 0 else { return .miss }

        // Resident-block hit: pure copy, no network.
        if let n = detourCache.serveCached(into: dst, maxLen: maxLen, at: offset) {
            return .served(n)
        }
        guard allowFetch else { return .miss }

        let blockStart = (offset / Int64(Self.detourBlockSize)) * Int64(Self.detourBlockSize)
        let blockLen = Int(min(Int64(Self.detourBlockSize), fileSize - blockStart))
        let block: Data
        switch detourFetchBlock(from: blockStart, size: blockLen) {
        case .ok(let fetched):
            // Cache only FULL-length blocks. A truncated 206 cached verbatim would shadow the
            // re-fetch path for its uncovered tail, so the parser ping-ponging into that tail
            // would cost one reconnect per read, reintroducing a mild storm (#69 review). Serve
            // the short body once; the next read of this block re-fetches.
            if fetched.count == blockLen, !isFullyClosed {
                detourCache.insert(blockStart / Int64(Self.detourBlockSize), fetched)
                #if DEBUG
                EngineLog.emit("[AVIOReader] detour fill block=\(blockStart / Int64(Self.detourBlockSize)) offset=\(blockStart) size=\(fetched.count) (resident=\(detourCache.residentCount))", category: .demux)
                #endif
            }
            block = fetched
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter)
        case .failed:
            return .miss
        }

        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < block.count else { return .miss }
        let n = min(maxLen, block.count - inBlock)
        block.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return .served(n)
    }

    /// Single Range fetch for a detour block over the pooled chunkSession. Surfaces 429/503 with
    /// its Retry-After so the caller can back off in place rather than churn the connection (#71).
    private func detourFetchBlock(from offset: Int64, size: Int) -> DetourFetch {
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: requestURL())
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        // #93/#96: a starved backward-scrub detour fetch must abort fast (the rescue reconnect serves
        // instantly), so this path uses the tight interactive budget, not the full chunk timeout.
        let budget = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        request.timeoutInterval = budget
        applyExtraHeaders(&request)
        do {
            let (data, response) = try syncRequest(request, budget: budget)
            if let http = response as? HTTPURLResponse {
                let status = http.statusCode
                if status == 429 || status == 503 {
                    return .rateLimited(Self.parseRetryAfter(http))
                }
                if status != 200 && status != 206 {
                    if Self.isResolvedExpiryStatus(status) { invalidateResolvedURL() }
                    return .failed
                }
                // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                if status == 200 && offset > 0 && !isLive {
                    EngineLog.emit("[AVIOReader] detour: server ignored Range (200 for offset \(offset)); rejecting", category: .demux, level: .verbose)
                    return .failed
                }
            }
            addBytesFetched(data.count)
            return .ok(data)
        } catch {
            return .failed
        }
    }

    /// Tracks contiguity of detour reads for the re-anchor heuristic. Shared by BOTH the backward
    /// and far-forward branches; the re-anchor check itself lives only in the backward branch on
    /// purpose, so a forward-accumulated run later met by a contiguous backward read is an intended
    /// re-anchor, not an accident. A non-contiguous read restarts the run. Demux-thread-only.
    private func detourTrackSequential(at offset: Int64, length: Int) {
        if offset == detourRunNextExpected {
            detourRunBytes += Int64(length)
        } else {
            detourRunBytes = Int64(length)
        }
        detourRunNextExpected = offset + Int64(length)
    }

    private func detourResetRun() {
        detourRunNextExpected = -1
        detourRunBytes = 0
    }

    // MARK: - Cold-start spans (#281)

    /// Fire-and-forget suffix fetch for the last `tailPrefetchBytes` of the source, running
    /// alongside the open connection.
    ///
    /// `bytes=-n` is the one range form that needs no size, which is the whole point: at this
    /// moment the reader has not seen a single response header, so an explicit `bytes=a-b` is not
    /// yet expressible. VOD only: a live feed's tail is meaningless and its length non-authoritative.
    ///
    /// A read that lands in this range WAITS for the fetch (`awaitTailPrefetchLocked`) instead of
    /// connecting past it. The first cut of this let nothing wait, on the reasoning that a late
    /// fetch costs no more than the reconnect it failed to save. That reasoning was wrong about the
    /// timing, and the #281 retest measured it: the demuxer reaches the tail within microseconds of
    /// the data connection's first byte, and the speculative fetch pays the SAME round trip plus a
    /// body, so it is ALWAYS still in flight at that moment on any origin whose first byte costs
    /// anything. It never once served the read it exists for; it only added a request. Only a
    /// loopback origin, which answers before the race can be lost, made it look like it worked.
    private func startTailPrefetch() {
        guard !isLive, !isClosed else { return }
        let url = requestURL()
        // An origin that already answered this form with something else will answer it that way
        // again. Said out loud rather than skipped silently: "no issued line" and "issued, declined"
        // are different findings, and a reporter reading this log can only report what it prints.
        if let reason = SuffixRangeSupport.shared.denialReason(for: url) {
            EngineLog.emit(
                "[AVIOReader] \(label) tail prefetch skipped: this origin declined suffix ranges "
                + "earlier this session (\(reason))", category: .demux)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=-\(Self.tailPrefetchBytes)", forHTTPHeaderField: "Range")
        request.timeoutInterval = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        applyExtraHeaders(&request)

        // A delegate rather than a completion handler, and the distinction is load-bearing: a
        // completion handler only fires once the body is in hand, so an origin that does not
        // implement suffix ranges and answers 200 with the WHOLE file would be downloaded in full
        // before this code could look at the status. On a 4 GB source that is the entire file
        // fetched speculatively. The delegate decides at the response header and hangs up there
        // (the same shape ProbeDelegate uses, and the same failure #255 paid for once already).
        let delegate = TailPrefetchDelegate(
            expectedLength: Self.tailPrefetchBytes,
            extraHeaders: extraHeaders
        )
        // #281 retest: one line per open, and the line the field needs. The advertised way to check
        // this fix was "does a bytes=-65536 request show up", which the engine never printed, so a
        // reporter reading the log could only report its absence. Names the outcome, not the intent.
        delegate.onOutcome = { [weak self] outcome in
            guard let self else { return }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds
                                   - self.tailPrefetchStartedAt.uptimeNanoseconds) / 1_000_000
            self.winCond.lock()
            self.tailPrefetchInFlight = false
            var installed = false
            if case .span(let start, let data) = outcome, !self.isFullyClosed, self.tailSpan == nil {
                self.tailSpan = ResidentSpan(start: start, data: data)
                installed = true
            }
            self.winCond.broadcast()
            self.winCond.unlock()
            if case .span(let start, let data) = outcome {
                SuffixRangeSupport.shared.noteServed(url)
                self.addBytesFetched(data.count)
                EngineLog.emit(
                    "[AVIOReader] \(self.label) tail prefetch \(installed ? "installed" : "dropped") "
                    + "\(data.count)B at \(start) after \(Int(elapsedMs))ms",
                    category: .demux)
            } else if case .rejected(let reason, let byOrigin) = outcome {
                var learned = false
                if byOrigin {
                    SuffixRangeSupport.shared.noteDeclined(url, reason: reason)
                    learned = true
                } else {
                    learned = SuffixRangeSupport.shared.noteTransportFailure(url, reason: reason)
                }
                EngineLog.emit(
                    "[AVIOReader] \(self.label) tail prefetch rejected after \(Int(elapsedMs))ms: \(reason)"
                    + (learned ? "; not asking this origin again this session" : ""),
                    category: .demux)
            }
        }
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate
        winCond.lock()
        tailPrefetchTask = task
        tailPrefetchInFlight = true
        tailPrefetchStartedAt = DispatchTime.now()
        winCond.unlock()
        task.resume()
        // Issue AND outcome, because "no outcome line" and "never issued" are different findings and
        // one line cannot carry both. A fetch that hangs to teardown prints this one and no other.
        EngineLog.emit("[AVIOReader] \(label) tail prefetch issued bytes=-\(Self.tailPrefetchBytes)",
                       category: .demux)
    }

    /// Whether `offset` lies in the range the speculative fetch asked for. Caller holds `winCond`.
    private func isInTailPrefetchRangeLocked(_ offset: Int64) -> Bool {
        guard fileSize > 0 else { return false }
        return offset >= fileSize - Int64(Self.tailPrefetchBytes) && offset < fileSize
    }

    /// How long a read may wait for the speculative fetch before giving up and reconnecting.
    ///
    /// Both requests left at the same instant against the same origin, so the fetch's first byte
    /// costs what the data connection's did: once it has been outstanding for materially longer
    /// than that, it is not about to land and a fresh connection is the better bet. Waiting up to
    /// that point can never cost more than the reconnect it replaces, which is what makes this
    /// bound the honest one rather than a tuned constant. The floor covers an origin that answered
    /// the first connection out of a warm cache; the cap keeps a hung fetch from owning the open.
    /// Caller holds `winCond`.
    private func tailPrefetchWaitBudget() -> TimeInterval {
        min(5.0, max(0.25, (lastFirstDataMs / 1000) * 2))
    }

    /// Start offset of the bytes a 206 actually carries, from `Content-Range: bytes a-b/total`.
    /// Returns nil unless the header agrees with what arrived, so a proxy that answered a suffix
    /// request with some other region cannot install bytes at the wrong offset.
    static func suffixRangeStart(_ http: HTTPURLResponse, expectedLength: Int) -> Int64? {
        guard let value = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let scanner = value.replacingOccurrences(of: "bytes ", with: "")
        let parts = scanner.split(separator: "/", maxSplits: 1)
        guard let range = parts.first else { return nil }
        let bounds = range.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start,
              end - start + 1 == Int64(expectedLength) else { return nil }
        return start
    }

    /// The demuxer is done parsing; a far seek from here on is playback. Stops COLLECTING into the
    /// head, but deliberately does not release it here.
    ///
    /// #281 retest: releasing it here was one read too early. The read that follows this call is
    /// playback's FIRST, and after a trailing-index parse the anchored connection sits at the END of
    /// the file, so that read is a backward one that lands at the head on every layout measured (48
    /// here, 5752 in the field trace). Dropping the head on the last parse read handed straight back
    /// the round trip the head exists to remove, and no `probe`-based measurement could see it,
    /// because `probe` exits at exactly this line. The head is released instead by the first
    /// post-open read it cannot answer, which is either playback moving past it or a resume position
    /// nowhere near it. The tail span stays for the same reason it always did: it is 64 KB, and a
    /// container that re-reads its trailing index during playback should keep hitting it.
    func markOpenPhaseFinished() {
        winCond.lock()
        openPhaseActive = false
        winCond.unlock()
    }

    /// Which cold-start span answered, so the log can name the round trip that did not happen
    /// rather than leaving its absence to be inferred.
    enum SpanServe {
        case head(Int)
        case tail(Int)

        var bytes: Int {
            switch self {
            case .head(let n), .tail(let n): return n
            }
        }
    }

    /// Serve `offset` from either cold-start span. Caller holds `winCond` (the read loop already
    /// does, and `winCond` is an NSCondition, so re-acquiring here would deadlock). The copy runs
    /// under the lock on purpose: it is a memcpy out of a `Data` the delegate threads only ever
    /// install, never mutate.
    private func serveFromResidentSpansLocked(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int,
                                              at offset: Int64) -> SpanServe? {
        if !headSpan.isEmpty,
           let n = ResidentSpan(start: 0, data: headSpan).serve(into: dst, maxLen: maxLen, at: offset) {
            return .head(n)
        }
        if let n = tailSpan?.serve(into: dst, maxLen: maxLen, at: offset) { return .tail(n) }
        return nil
    }

    // MARK: - Persistent Connection (lifecycle + delegate callbacks)

    /// Open a fresh Range: bytes=<offset>- connection. Bumps generation so
    /// late callbacks from the old connection are ignored.
    private func startPersistentConnection(at offset: Int64, boundedTo: Int64? = nil) {
        winCond.lock()
        connGeneration &+= 1
        let generation = connGeneration
        // #220: VOD asks for a fixed amount at a time, so the origin cannot deliver more than
        // was requested and the window is bounded by construction rather than by reaction. Two
        // cases keep the open-ended form: live, where the material is produced in real time so
        // the origin cannot outrun media rate and the end is moving, and a source whose total
        // size is not resolved yet, where there is nothing to clamp the last range against. An
        // explicit caller bound (boundedInitialFetch) still wins. `fileSize` is read here
        // because winCond is already held, as every fileSize access requires.
        let resolvedBound: Int64? = boundedTo ?? {
            guard !isLive else { return nil }
            // fileSize is still 0 on the very first connection, since the response's
            // Content-Range is what resolves it. Asking for a fixed amount anyway is both safe
            // and necessary: safe because a server clamps a range that overruns the file (416
            // needs the START past the end, which cannot happen here), and necessary because
            // waiting for a resolved size would leave the first connection, the one that reads
            // from byte zero, open-ended.
            if fileSize > offset { return min(Self.persistentRangeBytes, fileSize - offset) }
            return fileSize <= 0 ? Self.persistentRangeBytes : nil
        }()
        // #295: a request that begins inside the resident window, or exactly at its end, is a
        // CONTINUATION rather than a reposition. Resetting `winStart` to it dropped every byte
        // below it, which for the #220 frontier refill is up to `winLowWater` of already delivered,
        // still undrained data: the very next read then sat below `winStart`, took the backward
        // branch, and pulled those same bytes back over the network 4 MB at a time on the demux
        // read thread. Keeping them costs nothing (the new range covers only what follows) and the
        // window stays bounded by `trimWindowLocked` and `winHardCap` exactly as before.
        // The truncating case is the narrow race where the old connection appended past the
        // frontier the read loop computed before it unlocked; those bytes are re-delivered by the
        // new range, which is correct if slightly wasteful, and never leaves a hole.
        if offset >= winStart, offset <= winStart + Int64(window.count) {
            let keep = Int(offset - winStart)
            if keep < window.count { window = window.subdata(in: 0..<keep) }
        } else {
            winStart = offset
            window = Data()
        }
        connRequestedOffset = offset
        connEnded = false
        connEndedByBackpressure = false
        connEndedAtRangeEnd = false
        connRangeEnd = resolvedBound.map { offset + $0 - 1 }
        suspendedDeliveryBytes = 0
        connStatus = 0
        connRetryAfter = 0
        connStartedAt = DispatchTime.now()   // #93: time-to-first-data per generation
        connFirstDataSeen = false
        let oldTask = activeTask
        let oldSuspended = persistentTaskSuspended
        persistentTaskSuspended = false
        activeTask = nil
        winCond.broadcast()
        winCond.unlock()

        // #174: balance a pending suspend before cancel (mirrors the streaming teardown).
        if oldSuspended { oldTask?.resume() }
        oldTask?.cancel()

        if isClosed { return }

        var request = URLRequest(url: requestURL())
        // #93 residual: a bounded open connection asks for a finite range so an origin that dribbles
        // the open-ended `bytes=0-` stream serves it as a fast finite GET. The 206 Content-Range still
        // carries the total size, so fileSize resolution (issue #70) is unaffected.
        if let resolvedBound {
            request.setValue("bytes=\(offset)-\(offset + resolvedBound - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        request.timeoutInterval = 0  // long-lived; stalls handled by the reader
        applyExtraHeaders(&request)

        let delegate = PersistentReadDelegate(
            reader: self,
            generation: generation,
            extraHeaders: extraHeaders
        )
        let task = Self.persistentSession.dataTask(with: request)
        task.delegate = delegate

        winCond.lock()
        // A close() that raced in bumped the generation; don't install a stale connection.
        guard generation == connGeneration, !isClosed else {
            winCond.unlock()
            task.cancel()
            return
        }
        activeTask = task
        winCond.unlock()

        task.resume()
        // #240: not DEBUG-only any more, and it names its reader. This is the line a field report
        // needs to answer "who is on the link": with bounded ranges every 32 MiB refill starts a
        // generation, so an unlabelled sequence of them reads like several concurrent connections
        // when it is one reader walking forward. One line per range is a line every few seconds.
        EngineLog.emit(
            "[AVIOReader] \(label) conn start gen=\(generation) offset=\(offset)"
            + (resolvedBound.map { " len=\($0 / 1024 / 1024)MB" } ?? " open-ended"),
            category: .demux)
    }

    /// Force-copies `data` into the sliding window and applies backpressure by
    /// suspending the task once the window exceeds winHighWater (#174); readPersistent
    /// resumes it when the consumer drains below winLowWater. Never blocks: parking this
    /// delegate callback has no flow-control contract (TLS/H2 transports keep reading at
    /// line rate into unbounded internal buffers, the #174 EXC_RESOURCE). Force-copy
    /// releases source dispatch_data per delivery (same leak control as the chunk path).
    fileprivate func appendPersistentData(_ data: Data, generation: Int) {
        winCond.lock()
        guard generation == connGeneration, !isFullyClosed else {
            // #93: a slow read's summary line reports how much data the stale-generation
            // guard discarded while the read waited.
            staleGenDroppedBytes += Int64(data.count)
            winCond.unlock()
            return
        }
        var firstDataMs: Double? = nil
        if !connFirstDataSeen {
            connFirstDataSeen = true
            firstDataMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
            // #281 retest: the price of one round trip against this origin, which is what bounds
            // how long a read may wait for bytes that are already on the wire.
            lastFirstDataMs = firstDataMs ?? 0
        }
        let count = data.count
        // #220: delivery that lands with the suspend flag already set. Counted before the
        // append so it is attributable to the transport, not to our own bookkeeping.
        if persistentTaskSuspended { suspendedDeliveryBytes += Int64(count) }
        let base = window.count
        window.count = base + count
        window.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                if let d = dst.baseAddress, let s = src.baseAddress {
                    (d + base).copyMemory(from: s, byteCount: count)
                }
            }
        }
        // #281 retest: retain the head of the file for the open phase, as it arrives. It cannot be
        // copied later out of the window, because `trimWindowLocked` drops it as the parse reads
        // forward, which is why the seek-time park misses on every layout whose parse reads more
        // than `winLookback` before its first excursion. Contiguity is checked rather than assumed:
        // only the connection anchored at zero, and only while it is still the tail of what is held.
        if openPhaseActive, winStart == 0, base == headSpan.count,
           headSpan.count < Self.headSpanMaxBytes {
            headSpan.append(data.prefix(Self.headSpanMaxBytes - headSpan.count))
        }
        addBytesFetched(count)
        // #220: the requested range has been delivered in full. That ends the connection on
        // purpose; the read loop re-requests at the frontier once the consumer has drawn down.
        if let end = connRangeEnd, winStart + Int64(window.count) > end {
            connEndedAtRangeEnd = true
            connEnded = true
        }
        winCond.broadcast()
        // Deliveries already dispatched before the suspend takes effect still land here
        // (flag already set, no double-suspend), so the window can overshoot highWater by
        // the transport's in-flight amount; the suspend count stays balanced via the flag.
        var toSuspend: URLSessionDataTask?
        var toCancel: URLSessionDataTask?
        let ahead = window.count - max(0, Int(position - winStart))
        if ahead > Self.winHighWater, !persistentTaskSuspended, !isClosed {
            persistentTaskSuspended = true
            toSuspend = activeTask
        }
        // #220: the suspend did not take. Ending the connection is the only bound left; the
        // window keeps every byte already delivered (they are valid and the consumer reads
        // them) and the read loop re-requests at the frontier once it has drained. Nothing is
        // discarded and nothing is re-fetched.
        if ahead > Self.winHardCap, !connEndedByBackpressure, !isClosed {
            connEndedByBackpressure = true
            connEnded = true
            toCancel = activeTask
            activeTask = nil
            persistentTaskSuspended = false
            winCond.broadcast()
        }
        winCond.unlock()
        toSuspend?.suspend()
        if let toCancel {
            EngineLog.emit(
                "[AVIOReader] \(label) window hard cap: \(ahead / 1024 / 1024)MB resident with the task "
                + "suspended (\(suspendedDeliveryBytes / 1024 / 1024)MB arrived after the "
                + "suspend); ending the connection, will re-request at the frontier",
                category: .demux)
            toCancel.resume()   // balance the suspend so the cancel is not charged to a parked task
            toCancel.cancel()
        }
        if let firstDataMs {
            // #93/#96 residual: a slow first-data gap is release-visible so a device trace can pair it
            // with the response-header timing above. Small header gap + large first-data gap = the body
            // stalled after headers; large header gap = server-side connection queuing. Fast reads stay
            // on the DEBUG-only path to keep the release log quiet.
            if firstDataMs > 2000 {
                EngineLog.emit("[AVIOReader] \(label) gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
            } else {
                #if DEBUG
                EngineLog.emit("[AVIOReader] \(label) gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
                #endif
            }
        }
    }

    fileprivate func persistentReceivedResponse(
        _ http: HTTPURLResponse,
        resolvedURL: URL?,
        generation: Int
    ) -> Bool {
        let status = http.statusCode
        var isOK = status == 200 || status == 206
        var retryAfter: TimeInterval = 0
        if status == 429 || status == 503 {
            retryAfter = Self.parseRetryAfter(http)
        }
        var headerMs: Double? = nil
        winCond.lock()
        if generation == connGeneration {
            connStatus = status
            connRetryAfter = retryAfter
            // #93/#96 residual: time-to-first-response-header for this generation. A large value here
            // with a small subsequent first-data gap points at server-side connection queuing (the
            // origin accepted the socket but withheld the response while it served another connection
            // of the same file at full rate), the prime suspect for the ~15s cold reads.
            headerMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
        }
        // VOD: 200 at offset > 0 means server ignored Range and sent the full body
        // from byte 0 (silent corruption). Reject it. Live is exempt: transcode
        // reconnect legitimately answers 200 with "from now".
        let requestedOffset = (generation == connGeneration) ? connRequestedOffset : 0
        // Issue #70: the first from-0 data connection doubles as the size probe, so the
        // playback open skips probeFileSize() entirely. Derive the total from this
        // response (206 Content-Range, or Content-Length on a from-0 2xx). Write-once
        // (fileSize <= 0), current-gen only, and never for live (whose length is
        // non-authoritative). The response precedes any body and no read() reads fileSize
        // until open() returns, so this write is ordered behind winCond just like the data.
        if generation == connGeneration, !isLive, fileSize <= 0,
           let total = Self.sizeFromResponse(http, requestedOffset: requestedOffset) {
            fileSize = total
            // #112: share this resolved length so a later side demuxer on the same origin can skip a probe that
            // might be starved under this connection's load and would otherwise collapse it to forward-only.
            SourceContentLengthCache.store(total, for: url)
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(total) bytes (data connection)", category: .demux)
            #endif
        }
        winCond.unlock()
        if let headerMs, headerMs > 2000 {
            EngineLog.emit(
                "[AVIOReader] gen=\(generation) response headers after \(Int(headerMs))ms status=\(status)",
                category: .demux
            )
        }
        if status == 200 && requestedOffset > 0 && !isLive {
            EngineLog.emit(
                "[AVIOReader] server ignored Range (200 for offset \(requestedOffset)); rejecting body",
                category: .demux
            )
            isOK = false
        }

        if isOK {
            if let resolvedURL { recordResolvedURL(resolvedURL) }
            return true
        }
        if Self.isResolvedExpiryStatus(status) {
            invalidateResolvedURL()
        }
        return false
    }

    fileprivate func persistentConnectionEnded(error: Error?, generation: Int) {
        winCond.lock()
        let isCurrentGen = (generation == connGeneration)
        if isCurrentGen {
            connEnded = true
            // #220: the refill below keys off there being no live connection, so the finished
            // task must not stay installed.
            activeTask = nil
        }
        let windowAhead = isCurrentGen ? (window.count - max(0, Int(position - winStart))) : 0
        winCond.broadcast()
        winCond.unlock()
        if let error {
            EngineLog.emit("[AVIOReader] \(label) conn gen=\(generation) ended with error: \(error.localizedDescription)", category: .demux)
        }
        if isCurrentGen && isLive {
            EngineLog.emit("[AVIOReader] Live source: connection ended gen=\(generation) buffered=\(windowAhead / 1024)KB; reconnect will fire when buffer drains", category: .demux)
        }
    }

    /// Parses delta-seconds Retry-After; HTTP-date form falls back to expo backoff. Cap 15s.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else {
            return 0
        }
        return min(max(seconds, 0), 15)
    }

    // MARK: - Streaming Download (background)

    private func startStreamingDownload() {
        prefetchQueue.async { [weak self] in
            self?.streamDownloadSync()
        }
    }

    private func streamDownloadSync() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 0  // No timeout for live streams
        applyExtraHeaders(&request)

        let semaphore = DispatchSemaphore(value: 0)

        let delegate = StreamingDelegate { [weak self] data in
            guard let self, !self.isClosed else { return }
            self.streamLock.lock()
            self.streamBuffer.append(data)
            // Backpressure: park the transfer once the retained buffer
            // exceeds the high water mark; readStreaming resumes it when
            // the consumer drains below the low water mark (and before
            // any wait, so a far-forward seek can't deadlock against a
            // suspended producer).
            var toSuspend: URLSessionDataTask?
            if !self.streamingTaskSuspended, self.streamBuffer.count > Self.streamHighWater {
                self.streamingTaskSuspended = true
                toSuspend = self.streamingTask
            }
            self.streamLock.unlock()
            toSuspend?.suspend()
            self.addBytesFetched(data.count)
            self.streamDataReady.signal()
        } onComplete: { [weak self] in
            self?.streamLock.lock()
            self?.streamEnded = true
            self?.streamLock.unlock()
            self?.streamDataReady.signal()
            semaphore.signal()
        }

        let streamSession = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamSession.dataTask(with: request)

        // Register before resume so markClosed()/close() can cancel; re-check after.
        streamLock.lock()
        streamingSession = streamSession
        streamingTask = task
        streamLock.unlock()

        task.resume()
        if isClosed { task.cancel() }

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming started: \(url.lastPathComponent)", category: .demux)
        #endif

        semaphore.wait()

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming ended", category: .demux)
        #endif
        streamLock.lock()
        streamingSession = nil
        streamingTask = nil
        streamLock.unlock()
        streamSession.invalidateAndCancel()
    }

    // MARK: - Prefetch (background, seekable mode only)

    private func triggerPrefetch(from offset: Int64) {
        guard prefetchEnabled else { return }
        if fileSize > 0 && offset >= fileSize { return }

        bufferLock.lock()
        guard !isPrefetching else { bufferLock.unlock(); return }
        isPrefetching = true
        bufferLock.unlock()

        prefetchQueue.async { [weak self] in
            guard let self = self else { return }

            // Bail if close() ran to avoid writing stale data back into prefetchBuffer.
            if self.isFullyClosed {
                self.bufferLock.lock()
                self.isPrefetching = false
                self.bufferLock.unlock()
                self.prefetchReady.signal()
                return
            }

            let size: Int
            if self.fileSize > 0 {
                size = min(self.chunkSize, Int(self.fileSize - offset))
            } else {
                size = self.chunkSize
            }

            let data = size > 0 ? self.fetchChunk(from: offset, size: size) : nil

            self.bufferLock.lock()
            // Re-check: close() may have fired while fetchChunk was on the network.
            if !self.isFullyClosed {
                self.prefetchBuffer = data
                self.prefetchOffset = offset
            }
            self.isPrefetching = false
            self.bufferLock.unlock()

            self.prefetchReady.signal()
        }
    }

    // MARK: - Seek

    /// Internal rather than fileprivate (#281) so the seek-driven paths, the parse seek and the
    /// return trip behind it, are exercised against a real origin without going through FFmpeg,
    /// the same reason `recordRateLimitAndShouldGiveUp` is not private. Callers outside the file
    /// are tests; production reaches this through `seekCallback`.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == AVSEEK_SIZE { return fileSize }
        // For persistent mode, position is shared with the delegate thread;
        // read SEEK_CUR base under the window lock.
        let newPosition: Int64
        switch whence {
        case SEEK_SET:
            newPosition = offset
        case SEEK_CUR:
            if usePersistentReader {
                winCond.lock(); let cur = position; winCond.unlock()
                newPosition = cur + offset
            } else {
                newPosition = position + offset
            }
        case SEEK_END:
            guard fileSize >= 0 else { return -1 }
            newPosition = fileSize + offset
        default:
            return -1
        }

        if usePersistentReader {
            // Just move the cursor; the read loop decides whether to reconnect.
            // Coalesces the matroska seek-storm on open into minimal reconnects.
            winCond.lock()
            position = newPosition
            winCond.broadcast()
            winCond.unlock()
        } else if !isStreaming {
            position = newPosition
            bufferLock.lock()
            let inCurrent = position >= currentOffset &&
                position < currentOffset + Int64(currentBuffer.count)
            if !inCurrent {
                currentBuffer = Data()
                currentOffset = position
                prefetchBuffer = nil
            }
            bufferLock.unlock()
        } else {
            // Streaming: forward-only; backward seeks below the retained
            // window return failure so the demuxer doesn't silently wait 15s.
            streamLock.lock()
            let oldestRetained = streamBytesRead
            streamLock.unlock()
            if newPosition < oldestRetained { return -1 }
            position = newPosition
        }

        return newPosition
    }

    // MARK: - Network (seekable mode)

    /// Long-lived session for file-size probes. Per-request sessions force fresh TLS
    /// handshakes, which Cloudflare-fronted origins can flag as suspicious. Distinct
    /// from syncRequest's per-request pattern (load-bearing for chunk-fetch leak control).
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    /// Total size from a data-connection response: `Content-Range` total on a 206, or
    /// `Content-Length` on a from-0 2xx (origins that answer 200 ignoring Range). Nil when
    /// the origin gave no usable length (chunked, or an unknown `*` total). Issue #70.
    static func sizeFromResponse(_ http: HTTPURLResponse, requestedOffset: Int64) -> Int64? {
        // On a 206 the total lives ONLY in Content-Range; Content-Length is the partial span,
        // so a 206 with an unknown (`*`) or unparseable range must report no size, never fall
        // through to the partial length (issue #70 review #6).
        if http.statusCode == 206 {
            guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = HTTPDiscIOReader.parseContentRangeTotal(cr), total > 0 else {
                return nil
            }
            return total
        }
        if (200...299).contains(http.statusCode), requestedOffset == 0,
           http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        return nil
    }

    /// #112: resolve the source length for the open, preferring a live probe and falling back to a length another
    /// demuxer already resolved for the same origin. A fresh probe here can be 429'd or answered without a length
    /// while the video producer is hammering the origin, which would drop this reader to forward-only streaming so
    /// every `avformat_seek_file` returns -1 and PGS reconstruction reads nothing. The producer's persistent open
    /// caches the real length (SourceContentLengthCache.store at the data-connection response), so a starved probe
    /// reuses it and stays byte-seekable. A successful probe also seeds the cache for whoever opens next.
    private func resolveInitialFileSize() -> Int64 {
        let probed = probeFileSize()
        if probed > 0 {
            SourceContentLengthCache.store(probed, for: url)
            return probed
        }
        if let cached = SourceContentLengthCache.lookup(url), cached > 0 {
            EngineLog.emit("[AVIOReader] size probe empty; reusing cached \(cached) bytes to keep seekability (#112)", category: .demux)
            return cached
        }
        return probed
    }

    /// Concurrent queue for the staggered open-time size probes; each probe blocks its
    /// worker on a semaphore-driven URLSession round-trip.
    private static let sizeProbeQueue = DispatchQueue(label: "aether.avio.size-probe", attributes: .concurrent)

    /// How long the primary open-ended range probe runs alone before the two fallback
    /// probes fire. Fast origins resolve well inside this window and never see a
    /// fallback request (identical wire behavior to the old sequential ladder).
    static let sizeProbeStaggerSeconds: TimeInterval = 0.75

    /// Shared, condition-guarded state for the staggered-concurrent size probes. Every field is
    /// touched only while `cond` is held, so the box is safe to capture in the @Sendable probe closures.
    private final class ProbeSizeState: @unchecked Sendable {
        let cond = NSCondition()
        var resolvedSize: Int64 = -1
        var outstanding = 0
    }

    private func probeFileSize() -> Int64 {
        // Staggered-concurrent ladder (#107 follow-up). The probes themselves are unchanged:
        // Range bytes=0- primary (AetherEngine#8: HEAD breaks on Cloudflare-fronted origins
        // returning 405), HEAD for live-transcode endpoints that reject Range, and the #126
        // bounded bytes=0-1 for origins that answer bytes=0- with 200/chunked but honor real
        // ranges. Sequentially each failing probe cost a full origin round-trip; a live tuner
        // pays its ~4 s tune-in on EVERY connection, so the ladder tripled the open latency
        // of every genuinely length-less source. The fallbacks now start after a short
        // stagger and run in parallel; the first positive size wins.
        // All mutable probe state lives inside ProbeSizeState, guarded entirely by its own
        // NSCondition, so the box is a safe capture for the @Sendable asyncAfter closures below
        // (Swift 6 SendableClosureCaptures otherwise flags the raw local vars and the run thunk).
        let state = ProbeSizeState()

        func launch(after delay: TimeInterval, name: String, _ run: @escaping @Sendable () -> Int64) {
            state.cond.lock(); state.outstanding += 1; state.cond.unlock()
            Self.sizeProbeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                state.cond.lock()
                let alreadyResolved = state.resolvedSize > 0
                state.cond.unlock()
                let closed = self?.isClosed ?? true
                let size = (alreadyResolved || closed) ? -1 : run()
                state.cond.lock()
                if size > 0, state.resolvedSize <= 0 {
                    state.resolvedSize = size
                    EngineLog.emit("[AVIOReader] File size: \(size) bytes (\(name))", category: .demux)
                }
                state.outstanding -= 1
                state.cond.broadcast()
                state.cond.unlock()
            }
        }

        launch(after: 0, name: "Range probe") { [weak self] in
            self?.rangeProbeFileSize(range: "bytes=0-") ?? -1
        }
        launch(after: Self.sizeProbeStaggerSeconds, name: "HEAD fallback") { [weak self] in
            self?.headProbeFileSize() ?? -1
        }
        launch(after: Self.sizeProbeStaggerSeconds, name: "bounded-range fallback") { [weak self] in
            self?.rangeProbeFileSize(range: "bytes=0-1") ?? -1
        }

        // Budget mirrors a single sequential probe (its own 20-25 s ceiling) plus the stagger;
        // isClosed teardown breaks the individual probes, which then signal outstanding down.
        let deadline = Date(timeIntervalSinceNow: Self.sizeProbeStaggerSeconds + min(25, chunkRequestTimeout) + 2)
        state.cond.lock()
        while state.resolvedSize <= 0 && state.outstanding > 0 {
            if !state.cond.wait(until: deadline) { break }
        }
        let size = state.resolvedSize
        state.cond.unlock()
        if size <= 0 {
            EngineLog.emit("[AVIOReader] no probe resolved a size, streaming mode (forward-only)", category: .demux)
        }
        return size > 0 ? size : -1
    }

    /// Range GET cancelled at didReceive response (no body transfers). Returns the total from
    /// Content-Range on 206, or expectedContentLength on 2xx (origins that ignore Range).
    /// The primary probe is the open-ended bytes=0- form; bytes=0- over bytes=0-0: some origins
    /// special-case the single-byte form and omit length, then 429 the HEAD fallback (issue #70);
    /// bytes=0- answers with a proper Content-Range in one shot. The bounded bytes=0-1 form is
    /// the #126 last-resort probe for origins that answer bytes=0- without a length but honor
    /// real ranges.
    private func rangeProbeFileSize(range: String) -> Int64? {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        applyExtraHeaders(&request)

        let delegate = ProbeDelegate(extraHeaders: extraHeaders)
        let task = Self.probeSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Bound + make abortable: still extraction caps this at its small budget so a
        // reopen mid-scrub on a stalled source can't park ~25s, and a teardown during
        // open returns at once (issue #27). Playback keeps its 25s ceiling.
        let probeBudget = min(25, chunkRequestTimeout)
        if Self.awaitSignal(semaphore, budget: probeBudget, pollInterval: 0.1,
                            shouldAbort: { [weak self] in
                                self?.isClosed == true
                            }) != .signaled {
            task.cancel()
            EngineLog.emit("[AVIOReader] Range probe (\(range)) timed out", category: .demux, level: .verbose)
            return nil
        }

        if delegate.totalSize == nil {
            EngineLog.emit("[AVIOReader] Range probe (\(range)) didn't yield a size", category: .demux, level: .verbose)
        }
        return delegate.totalSize
    }

    /// HEAD probe fallback for live-transcode endpoints that reject Range.
    private func headProbeFileSize() -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        applyExtraHeaders(&request)

        do {
            // Honour the still budget here too so the open-time HEAD fallback can't
            // ride the default 35s on a stalled origin during a cold/reopen scrub (#27).
            let (_, response) = try syncRequest(request, budget: chunkRequestTimeout)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                EngineLog.emit("[AVIOReader] HEAD failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))", category: .demux, level: .verbose)
                return -1
            }
            let length = http.expectedContentLength
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(length) bytes (HEAD fallback)", category: .demux)
            #endif
            return length
        } catch {
            EngineLog.emit("[AVIOReader] HEAD probe failed: \(error.localizedDescription)", category: .demux, level: .verbose)
            return -1
        }
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        if let data = fetchChunkAttempt(from: offset, size: size, forceSource: false) {
            return data
        }
        // Retry against source URL only if a cached resolved URL was used
        // (so the proxy can re-issue a fresh signed redirect).
        if cachedResolvedURL() != nil {
            return fetchChunkAttempt(from: offset, size: size, forceSource: true)
        }
        return nil
    }

    private func fetchChunkAttempt(from offset: Int64, size: Int, forceSource: Bool) -> Data? {
        let usingCachedURL = !forceSource && cachedResolvedURL() != nil
        let target = forceSource ? url : requestURL()
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: target)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = min(15, chunkRequestTimeout)
        applyExtraHeaders(&request)

        var lastError: Error?
        for attempt in 0..<chunkMaxRetries {
            do {
                let (data, response) = try syncRequest(request, budget: chunkRequestTimeout)
                if let http = response as? HTTPURLResponse {
                    let status = http.statusCode
                    if status != 200 && status != 206 {
                        if usingCachedURL && Self.isResolvedExpiryStatus(status) {
                            invalidateResolvedURL()
                        }
                        EngineLog.emit("[AVIOReader] chunk fetch got HTTP \(status) at offset \(offset)\(usingCachedURL ? " (cached URL, will retry source)" : "")", category: .demux, level: .verbose)
                        return nil
                    }
                    // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                    if status == 200 && offset > 0 && !isLive {
                        EngineLog.emit(
                            "[AVIOReader] server ignored Range (200 for offset \(offset)); rejecting chunk",
                            category: .demux
                        )
                        return nil
                    }
                }
                addBytesFetched(data.count)
                return data
            } catch {
                // Superseded / closed / past the read deadline: this read is disposable,
                // bail at once instead of retrying into the abort (issue #27).
                if isClosed || isPastReadDeadline { return nil }
                lastError = error
                if attempt < chunkMaxRetries - 1 {
                    Thread.sleep(forTimeInterval: Double(1 << attempt) * 0.5)
                }
            }
        }

        EngineLog.emit("[AVIOReader] Fetch failed after \(chunkMaxRetries) retries at offset \(offset): \(lastError?.localizedDescription ?? "?")", category: .demux, level: .verbose)
        return nil
    }

    /// Long-lived session for seekable-path chunk fetches paired with per-task
    /// ChunkFetchDelegate. Delegate-based incremental delivery (not completion-handler)
    /// releases source dispatch_data per delivery on the delegate queue, so the body never
    /// reaches the demux thread's autorelease pool, which is what drove the original leak.
    /// No invalidation overhead.
    private static let chunkSession: URLSession = {
        let config = makeSessionConfig()
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    /// #220: long-lived session for the persistent streaming path, paired with a per-task
    /// `PersistentReadDelegate`. Bounded ranges end a connection every `persistentRangeBytes`,
    /// and a session per connection would make each of those a fresh TLS handshake against the
    /// origin. The delegate carries the connection generation, so per-task assignment is all
    /// that was ever needed here. The old per-request-session rule does not apply, and #243
    /// showed why it never could: measured against a range origin, a session per request leaks
    /// exactly as much as a shared one (+973 MB vs +968 MB per 480 MB fetched). What retains a
    /// completion-handler body is the never-draining autorelease pool of the demux thread that
    /// bridges it out, not the session. This path is delegate-based, so the body is released on
    /// the delegate queue and never reaches that pool.
    ///
    /// Never invalidated. Releasing a connection is `task.cancel()` now, not session teardown.
    private static let persistentSession: URLSession = {
        URLSession(configuration: makeSessionConfig(longLived: true), delegate: nil, delegateQueue: nil)
    }()

    /// Outcome of an abortable semaphore wait (issue #27).
    enum WaitOutcome: Equatable { case signaled, timedOut, aborted }

    /// Wait on `semaphore` up to `budget` seconds, polling `shouldAbort` every
    /// `pollInterval`. Returns `.signaled` the moment the semaphore fires,
    /// `.aborted` within one poll of `shouldAbort()` going true, or `.timedOut`
    /// when the budget elapses. Lets a seekable chunk read bail promptly on
    /// supersede / close / read-deadline instead of parking the decode queue in a
    /// flat 35s wait (the root cause of the frozen scrub preview, issue #27).
    static func awaitSignal(
        _ semaphore: DispatchSemaphore,
        budget: TimeInterval,
        pollInterval: TimeInterval,
        shouldAbort: () -> Bool
    ) -> WaitOutcome {
        let deadline = Date(timeIntervalSinceNow: budget)
        while true {
            if shouldAbort() { return .aborted }
            let now = Date()
            if now >= deadline { return .timedOut }
            let slice = min(pollInterval, deadline.timeIntervalSince(now))
            if semaphore.wait(timeout: .now() + max(0.001, slice)) == .success {
                return .signaled
            }
        }
    }

    // MARK: - Response Body Bounds (#255)

    /// Reservation ceiling for a response whose request set no bounded `Range`. `Data` grows on
    /// demand, so the cap costs at most one reallocation on a legitimately larger body, while a
    /// bogus or whole-source declared length stays harmless.
    static let maxBodyReserve = 8 * 1024 * 1024

    /// Bytes the request can legitimately deliver: the span of a bounded `Range: bytes=a-b`, 0 for a
    /// HEAD (bodyless by definition), nil when the request is open-ended and the body is whatever the
    /// origin chooses to stream.
    ///
    /// #255: the declared `Content-Length` is not that number and never was. A HEAD answers with the
    /// whole source's length and no body at all, and an origin that ignores `Range` answers a bounded
    /// chunk request with `200` plus the whole source's length, so sizing an allocation from it asked
    /// malloc for the entire 12.4 GB movie at open time. `Data`'s storage force-unwraps the NULL that
    /// a failing malloc returns, so it traps: a host app can neither catch it nor degrade.
    static func expectedBodyBytes(for request: URLRequest) -> Int? {
        if request.httpMethod?.uppercased() == "HEAD" { return 0 }
        guard let value = request.value(forHTTPHeaderField: "Range") else { return nil }
        return boundedRangeSpan(value)
    }

    /// Span of a single bounded byte range (`bytes=a-b`). Nil for the open-ended (`bytes=a-`), suffix
    /// (`bytes=-n`), multi-range and malformed forms: none of those bound the body, so they fall back
    /// to the flat ceiling rather than a wrong limit.
    static func boundedRangeSpan(_ headerValue: String) -> Int? {
        let spec = headerValue.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes=") else { return nil }
        let set = spec.dropFirst("bytes=".count)
        guard !set.contains(",") else { return nil }
        let parts = set.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lower = Int64(parts[0]), let upper = Int64(parts[1]),
              lower >= 0, upper >= lower else { return nil }
        let span = upper - lower + 1
        return span <= Int64(Int.max) ? Int(span) : nil
    }

    /// Bytes to reserve up front for a response body: the origin's declared length clamped to what
    /// the request itself can deliver, or to `maxBodyReserve` when the request is open-ended.
    static func bodyReservation(declaredLength: Int64, limit: Int?) -> Int {
        guard declaredLength > 0 else { return 0 }
        let ceiling = Int64(limit ?? maxBodyReserve)
        guard ceiling > 0 else { return 0 }
        return Int(min(declaredLength, ceiling))
    }

    /// #255 test hook: the largest up-front body reservation any chunk fetch has asked for since the
    /// last reset. Written on the delegate queue, read once the fetch it belongs to has completed.
    nonisolated(unsafe) static var peakBodyReserveForTesting = 0

    private func syncRequest(_ request: URLRequest, budget: TimeInterval = 35) throws -> (Data, URLResponse) {
        let delegate = ChunkFetchDelegate(extraHeaders: extraHeaders,
                                          bodyLimit: Self.expectedBodyBytes(for: request))
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Poll for close / read-deadline so a superseded or torn-down still-extraction
        // read aborts within ~100ms instead of riding the full budget (issue #27).
        let outcome = Self.awaitSignal(
            semaphore, budget: budget, pollInterval: 0.1,
            shouldAbort: { [weak self] in self?.isClosed == true || self?.readDeadlinePassedOrAborted == true }
        )
        guard outcome == .signaled else {
            task.cancel()
            throw AVIOReaderError.requestTimeout
        }

        // A truncating cancel is this reader hanging up on purpose, so the cancellation error it
        // produces is not a failed fetch: the prefix the request asked for is in hand (#255).
        if let err = delegate.error, !delegate.truncated { throw err }
        guard let response = delegate.response else { throw AVIOReaderError.noResponse }
        if delegate.truncated {
            EngineLog.emit(
                "[AVIOReader] response body ran past the requested range; kept \(delegate.body.count) bytes and hung up (origin ignored Range?)",
                category: .demux, level: .verbose
            )
        }
        return (delegate.body, response)
    }
}

// MARK: - Detour Block Cache

/// Fixed-block LRU cache backing the persistent reader's detour path (AetherEngine#69). Random-access
/// parse reads on a non-faststart remote MP4 are served from here over the pooled keep-alive session
/// instead of tearing down the anchored streaming connection. Thread-safe via a single leaf lock
/// (demux-thread reads + teardown-thread `clear`); never held across the network. Stores only
/// full-size blocks (the fetch/insert decision is the caller's), so eviction can't shadow a
/// re-fetchable short-body tail. The copy + eviction math is pure and unit-tested without a network.
final class DetourBlockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    private var lru: [Int64] = []
    private let maxBlocks: Int
    let blockSize: Int

    init(blockSize: Int, maxBlocks: Int) {
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
    }

    /// Returns the resident block for `idx` and bumps its recency, or nil on a miss.
    func block(_ idx: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = blocks[idx] else { return nil }
        if let i = lru.firstIndex(of: idx) {
            lru.remove(at: i)
            lru.append(idx)
        }
        return data
    }

    /// Inserts a (full-size) block, evicting the least-recently-used tail beyond `maxBlocks`.
    func insert(_ idx: Int64, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if blocks[idx] == nil { lru.append(idx) }
        blocks[idx] = data
        while lru.count > maxBlocks {
            blocks.removeValue(forKey: lru.removeFirst())
        }
    }

    func clear() {
        lock.lock()
        blocks.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    var residentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return blocks.count
    }

    /// Copy up to `maxLen` bytes covering `offset` from the resident block into `dst`, returning the
    /// byte count. Returns nil if the covering block is not resident, or if `offset` lands in the
    /// uncovered tail of a short block (so the caller re-fetches rather than serving stale bytes).
    /// One call serves at most to the block boundary; a read spanning blocks is driven by the caller
    /// re-entering at the advanced offset. Pure given the cache contents; bumps recency on a hit.
    func serveCached(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int, at offset: Int64) -> Int? {
        guard maxLen > 0, offset >= 0 else { return nil }
        let idx = offset / Int64(blockSize)
        let blockStart = idx * Int64(blockSize)
        guard let blk = block(idx) else { return nil }
        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < blk.count else { return nil }
        let n = min(maxLen, blk.count - inBlock)
        blk.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return n
    }
}

/// Preserves Range + extra headers across cross-host redirects. URLSession strips
/// custom headers on host change; without this, CDN behind AIOStreams proxy gets a
/// plain GET and either streams the full body or 400s. Credential headers follow
/// RedirectHeaderPolicy (#126): same-host destinations only, never cross-origin.
private func redirectPreservingHeaders(
    task: URLSessionTask,
    newRequest request: URLRequest,
    extraHeaders: [String: String]
) -> URLRequest {
    RedirectHeaderPolicy.redirectRequest(
        request,
        originalURL: task.originalRequest?.url,
        originalRange: task.originalRequest?.value(forHTTPHeaderField: "Range"),
        extraHeaders: extraHeaders)
}

// MARK: - Persistent Read Delegate

/// Forwards deliveries into the reader's sliding window with generation tagging
/// so stale-connection late callbacks are no-ops. @unchecked Sendable: only
/// mutable coupling is weak reader, guarded by winCond.
private final class PersistentReadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var reader: AVIOReader?
    let generation: Int
    let extraHeaders: [String: String]

    init(reader: AVIOReader, generation: Int, extraHeaders: [String: String]) {
        self.reader = reader
        self.generation = generation
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let reader else {
            completionHandler(.cancel)
            return
        }
        let resolved = (http.statusCode == 200 || http.statusCode == 206)
            ? dataTask.currentRequest?.url
            : nil
        let allow = reader.persistentReceivedResponse(
            http, resolvedURL: resolved, generation: generation
        )
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        reader?.appendPersistentData(data, generation: generation)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        reader?.persistentConnectionEnded(error: error, generation: generation)
    }
}

// MARK: - Chunk Fetch Delegate

/// Single-use per fetch; force-copies each delivery into `body` so source
/// dispatch_data is released per delivery. @unchecked Sendable: ownership
/// via semaphore ensures no concurrent access to mutable fields.
private final class ChunkFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    /// Most this fetch will ever buffer, nil when the request is open-ended (#255). Derived from
    /// the request, never from the response: a declared length is the origin's claim about the
    /// whole source, not about this body.
    let bodyLimit: Int?
    var body = Data()
    var response: URLResponse?
    var error: Error?
    /// Set when the origin sent past `bodyLimit` and the task was cancelled mid-body, so the
    /// caller reads the kept prefix as a success instead of a cancellation failure.
    var truncated = false
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String], bodyLimit: Int?) {
        self.extraHeaders = extraHeaders
        self.bodyLimit = bodyLimit
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        if let http = response as? HTTPURLResponse {
            let reserve = AVIOReader.bodyReservation(
                declaredLength: http.expectedContentLength, limit: bodyLimit)
            AVIOReader.peakBodyReserveForTesting = max(
                AVIOReader.peakBodyReserveForTesting, reserve)
            if reserve > 0 { body.reserveCapacity(reserve) }
            let status = http.statusCode
            if status == 200 || status == 206,
               let resolved = dataTask.currentRequest?.url {
                onResolved?(resolved)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var count = data.count
        var overshoot = false
        if let bodyLimit {
            // Past what the request asked for means the origin ignored the Range and is streaming
            // the whole source at us. Keep the prefix the caller wanted and hang up, rather than
            // buffer a 12 GB movie in order to reject it afterwards (#255).
            let room = bodyLimit - body.count
            if count > room {
                count = max(0, room)
                overshoot = true
            }
        }
        if count > 0 {
            // Force-copy: body.append(data) may retain source dispatch_data via CoW,
            // defeating the per-delivery release. Manual memcpy guarantees drop on return.
            let baseCount = body.count
            body.count = baseCount + count
            body.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                        (dstBase + baseCount).copyMemory(from: srcBase, byteCount: count)
                    }
                }
            }
        }
        if overshoot {
            truncated = true
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        self.error = error
        onCompletion?()
    }
}

// MARK: - Streaming Delegate

private final class StreamingDelegate: NSObject, URLSessionDataDelegate {
    let onData: @Sendable (Data) -> Void
    let onComplete: @Sendable () -> Void

    init(onData: @escaping @Sendable (Data) -> Void, onComplete: @escaping @Sendable () -> Void) {
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        #if DEBUG
        if let error {
            EngineLog.emit("[AVIOReader] Stream error: \(error.localizedDescription)", category: .demux)
        }
        #endif
        onComplete()
    }
}

// MARK: - Probe Delegate

/// File-size Range probe delegate. Preserves Range across cross-host redirects,
/// captures total from Content-Range, cancels before the body streams.
/// @unchecked Sendable: single-use per probe, semaphore ownership prevents concurrency.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var totalSize: Int64?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        defer { completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else { return }
        let status = http.statusCode
        if (200...299).contains(status), let resolved = dataTask.currentRequest?.url {
            onResolved?(resolved)
        }
        // The probe requests `bytes=0-`, so requestedOffset is 0. Shared with the
        // data-connection path so a 206 with an unknown (`*`) total never reports its
        // partial Content-Length as the size (issue #70 review #6).
        totalSize = AVIOReader.sizeFromResponse(http, requestedOffset: 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?()
    }
}

/// Which origins have already shown they cannot answer a suffix range, so the next open does not
/// ask them again.
///
/// #281 retest: the reporter's origin answers `bytes=-65536` with a 200 and the WHOLE file, on every
/// single open. The delegate hangs up at the response header so the body is never taken, but the
/// request is not therefore free: it is a second connection opened at the same instant as the data
/// connection whose first byte IS the cold start, sharing that uplink, against a server that has
/// already demonstrated it cannot serve it. A request that structurally cannot be answered belongs
/// once per origin, not once per open.
///
/// Only the origin's own answer latches. A transport failure is the network's rather than the
/// server's, and a link bad enough to time out this request will time out others, so it takes two
/// before the origin is judged by it. Process lifetime: a server does not gain suffix-range support
/// mid-session, and forgetting across launches costs exactly one request.
final class SuffixRangeSupport: @unchecked Sendable {
    static let shared = SuffixRangeSupport()

    private static let transportFailuresBeforeDenying = 2

    private let lock = NSLock()
    private var denied: [String: String] = [:]      // origin -> how it declined, for the log line
    private var transportFailures: [String: Int] = [:]

    /// Scheme + host + port. Suffix-range support is a property of the server, not of one file.
    static func originKey(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        return "\(url.scheme ?? "http")://\(host):\(url.port.map(String.init) ?? "-")"
    }

    /// How this origin declined, or nil if it has not (yet) declined.
    func denialReason(for url: URL) -> String? {
        guard let key = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return denied[key]
    }

    func noteDeclined(_ url: URL, reason: String) {
        guard let key = Self.originKey(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        denied[key] = reason
    }

    /// Returns true when this failure was the one that tipped the origin into being denied.
    @discardableResult
    func noteTransportFailure(_ url: URL, reason: String) -> Bool {
        guard let key = Self.originKey(for: url) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard denied[key] == nil else { return false }
        let count = (transportFailures[key] ?? 0) + 1
        transportFailures[key] = count
        guard count >= Self.transportFailuresBeforeDenying else { return false }
        denied[key] = reason
        return true
    }

    /// A served fetch clears the transport tally: whatever those failures were, they were not this
    /// origin refusing the form.
    func noteServed(_ url: URL) {
        guard let key = Self.originKey(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        transportFailures[key] = nil
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        denied.removeAll()
        transportFailures.removeAll()
    }
}

/// #281: collects the speculative tail fetch, and refuses everything that is not the tail.
///
/// The guarantee that matters is that this never downloads a body it did not ask for. Suffix
/// ranges are not universally implemented: an origin may answer `bytes=-65536` with a 200 and the
/// whole file. That body is rejected at the header, before a byte of it is accepted, and the
/// collected length is capped besides, so a lying `Content-Range` cannot grow this either.
private final class TailPrefetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        case span(Int64, Data)
        /// Named so the log says WHICH way an origin declined, since "no suffix ranges", "a 200 with
        /// the whole file" and "a short body" are three different origins to talk to a reporter about.
        ///
        /// `byOrigin` separates the origin's own answer from the network's: the first is a property
        /// of the server and will repeat on every open, the second may not. Only the first is worth
        /// remembering after one occurrence (`SuffixRangeSupport`).
        case rejected(String, byOrigin: Bool)
    }

    private let expectedLength: Int
    private let extraHeaders: [String: String]
    private var buffer = Data()
    private var spanStart: Int64?
    private var rejection: String?

    /// Called exactly once, on completion, whatever happened. A caller waits on this fetch, so a
    /// silent failure would be a caller waiting out its whole budget for bytes that are never coming.
    var onOutcome: ((Outcome) -> Void)?

    init(expectedLength: Int, extraHeaders: [String: String]) {
        self.expectedLength = expectedLength
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Same policy as every other delegate here: credential headers do not follow a redirect
        // to another host (the #126 cross-origin token replay).
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            rejection = "no HTTP response"
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 206 else {
            rejection = "status=\(http.statusCode) (no suffix range support)"
            completionHandler(.cancel)
            return
        }
        guard let start = AVIOReader.suffixRangeStart(http, expectedLength: expectedLength) else {
            let cr = http.value(forHTTPHeaderField: "Content-Range") ?? "absent"
            rejection = "Content-Range: \(cr) does not describe the \(expectedLength)B asked for"
            completionHandler(.cancel)
            return
        }
        spanStart = start
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count < expectedLength else { return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = self.outcome(error: error)
        onOutcome?(outcome)
        onOutcome = nil
    }

    private func outcome(error: Error?) -> Outcome {
        if let rejection { return .rejected(rejection, byOrigin: true) }
        if let error { return .rejected("transport: \(error.localizedDescription)", byOrigin: false) }
        guard let start = spanStart else {
            return .rejected("no usable response header", byOrigin: true)
        }
        // A short body would put later offsets in the span at the wrong place, so a partial
        // delivery is dropped rather than trimmed: this is an optimisation, and a wrong
        // optimisation is worse than none.
        guard buffer.count == expectedLength else {
            return .rejected("short body: \(buffer.count)B of \(expectedLength)B", byOrigin: true)
        }
        return .span(start, buffer)
    }
}

// MARK: - C Callbacks


// AVERROR(EIO) = -5: live source lost (distinct from AVERROR_EOF).
private let AVERROR_EIO_VALUE: Int32 = -5

private func readCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.read(into: buf, size: size)
}

private func seekCallback(
    opaque: UnsafeMutableRawPointer?,
    offset: Int64,
    whence: Int32
) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.seek(offset: offset, whence: whence)
}

// MARK: - Errors

enum AVIOReaderError: Error, CustomStringConvertible, LocalizedError {
    case allocationFailed
    case noResponse
    case requestTimeout
    /// AE#140: an HLS playlist body arrived on the raw-byte live reader (misroute). Surfaced to load()
    /// so it can fail closed with a typed rejection instead of looping the endless-feed reconnect.
    case hlsPlaylistOnRawLivePath
    /// AE#154: an HLS playlist body arrived on the non-live loopback reader. FFmpeg (built with
    /// --disable-network) can never demux it; surfaced to load() so it reroutes the source onto the
    /// native remote-HLS bypass instead of dying with a bare AVERROR_INVALIDDATA.
    case hlsPlaylistOnVODPath

    var description: String {
        switch self {
        case .allocationFailed: return "Failed to allocate AVIO buffer"
        case .noResponse: return "No response from server"
        case .requestTimeout: return "Request timed out"
        case .hlsPlaylistOnRawLivePath: return "HLS playlist supplied to the raw live path"
        case .hlsPlaylistOnVODPath: return "HLS playlist supplied to the VOD loopback path"
        }
    }

    var errorDescription: String? { description }
}
