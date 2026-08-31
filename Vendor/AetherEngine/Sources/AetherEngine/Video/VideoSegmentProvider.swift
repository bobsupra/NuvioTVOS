import Foundation

// MARK: - Native subtitle rendition metadata

/// Per-rendition master-playlist metadata (#15): NAME must be unique within the subtitle group
/// (HLS requirement; duplicates make AVFoundation collapse same-language renditions into one
/// legible option), FORCED carries the container disposition into EXT-X-MEDIA. Built once at load
/// by `AetherEngine.nativeSubtitleRenditionInfos(for:)`.
struct NativeSubtitleRenditionInfo: Sendable, Equatable {
    let language: String?
    let name: String
    let isForced: Bool
}

// MARK: - Live window sizing

/// Single source of truth for sliding live window size. Playlist firstVisible and cache evictBelow
/// both read this so they can never drift (drift = playlist lists a segment the cache deleted, or vice versa).
/// effectiveWindowSeconds = dvrWindowSeconds ?? liveOnlyFloorSeconds;
/// windowSegmentCount = max(minSafeSegments, ceil(effective / targetSegmentDurationSeconds)).
struct LiveWindowSizing {
    /// Live-only floor: 60 s so disk and playlist stay finite even without DVR seek.
    static let liveOnlyFloorSeconds: Double = 60
    /// 8 segments: comfortably wider than AVPlayer's ~5-7 segment live-edge prefetch at 4 s segments.
    /// Smaller windows caused the 81 s spike stall (AVPlayer fell below MEDIA-SEQUENCE).
    static let minSafeSegments = 8

    /// AE#443: the most segments a live playlist will ever list, however deep the window and however
    /// cheap the segments. A PLAYLIST bound rather than a disk one (the retention budget below is the
    /// disk bound): the whole visible window is rebuilt and re-served on every poll, and a live client
    /// polls about once per target duration.
    static let maxWindowSegments = 900

    let targetSegmentDurationSeconds: Double
    let dvrWindowSeconds: Double?
    /// AE#443: the session's disk allowance (`HLSVideoEngine.sessionRetentionBudgetBytes`). 0 means
    /// "not stated", which leaves the sizing purely time-based, as it was.
    var retentionBudgetBytes: Int = 0

    /// Number of segments the playlist keeps visible (and the cache keeps
    /// resident). Clamped up to `minSafeSegments`.
    ///
    /// `targetSegmentDurationSeconds` is the CUT TARGET, a lower bound on the real GOP-quantized
    /// segment duration (fastZap: 0.5 s target vs ~2 s GOPs). Dividing the window seconds by it
    /// alone inflated the window 4x (120 segments ≈ 240 s), pinning MEDIA-SEQUENCE at 0 for minutes
    /// and deferring evictBelow (the "sliding" window never slid). Callers that know the observed
    /// cadence (mean EXTINF of recent finalized segments) pass it so the window really holds
    /// `effectiveWindowSeconds` of content.
    func windowSegmentCount(observedSegmentDurationSeconds: Double?,
                            observedSegmentBytes: Int? = nil) -> Int {
        let asked = requestedSegmentCount(observedSegmentDurationSeconds: observedSegmentDurationSeconds)
        let affordable = Self.affordableSegments(retentionBudgetBytes: retentionBudgetBytes,
                                                 observedSegmentBytes: observedSegmentBytes)
        return max(Self.minSafeSegments, min(asked, affordable, Self.maxWindowSegments))
    }

    /// AE#443: the window in segments as ASKED for, before either bound. Only the log reads it, and it
    /// has to: comparing the served count against a value that already carries the clamps would report
    /// every clamped window as unclamped.
    func requestedSegmentCount(observedSegmentDurationSeconds: Double?) -> Int {
        let effective = dvrWindowSeconds ?? Self.liveOnlyFloorSeconds
        let divisor = max(max(0.5, targetSegmentDurationSeconds), observedSegmentDurationSeconds ?? 0)
        return Int(ceil(effective / divisor))
    }

    /// AE#443: how many segments of the observed size the session's disk allowance holds.
    ///
    /// The window a host asks for is a promise in SECONDS and the disk is a fact in BYTES, and until
    /// this clamp existed nothing made them meet: a 1800 s window at a 1 s cadence sized a 1800-segment
    /// window that the producer's resident cap refused to hold, so the cache filled to the cap before
    /// the window had slid once, and the pump parked against it for the rest of the session. A parked
    /// live pump stops draining the origin, which on a single-connection source is not backpressure but
    /// a slow kill. Sizing the window by what can actually be held means the window slides instead, at
    /// the depth the disk really supports, and `seekableLiveRange` (AE#441 reads the cache) then
    /// advertises that depth rather than the one that was asked for.
    ///
    /// `.max` when either side is unknown: an unmeasured segment size must not shrink a window.
    static func affordableSegments(retentionBudgetBytes: Int, observedSegmentBytes: Int?) -> Int {
        guard retentionBudgetBytes > 0, let bytes = observedSegmentBytes, bytes > 0 else { return .max }
        return retentionBudgetBytes / bytes
    }

    var windowSegmentCount: Int { windowSegmentCount(observedSegmentDurationSeconds: nil) }
}

// MARK: - Live-edge holdback policy

/// Couples the served `#EXT-X-TARGETDURATION` / `HOLD-BACK` to the startup cushion so they can never
/// drift. AVPlayer's default live-edge holdback (absent an explicit `HOLD-BACK`) is `3 x TARGETDURATION`:
/// it wants to play that far behind the live edge. When the served window holds LESS than that behind the
/// edge, AVPlayer restarts inside its own stall-danger zone and spams
/// `-16832 restarting Ns from end of live playlist; target duration Ts - stall danger`, rebuffering until
/// the window naturally deepens (AE#189: long-GOP HEVC-in-TS, 5.76s segments -> TD=6 -> 18s holdback, but
/// the fixed 2-segment cushion only built ~9.6s). Both the served playlist
/// (`HLSLocalServer.buildMediaPlaylistText`) and the startup gate (`waitForFirstLiveSegment`) derive
/// TARGETDURATION here, so the depth the cushion builds to is exactly the depth AVPlayer enforces.
enum LiveEdgePolicy {
    /// Never serve an empty or single-segment live playlist (a 1-segment window is an instant -12888).
    static let minStartupSegments = 2

    /// AVPlayer's unchanged-playlist patience: it tolerates a playlist that has not changed for this
    /// multiple of the served TARGETDURATION before drawing `-12888`. The one number the cadence floor
    /// is answerable to.
    static let unchangedPlaylistPatienceMultiplier: Double = 1.5

    /// The TARGETDURATION a measured arrival cadence requires: enough that `1.5 x TD` of patience covers
    /// the gap. AE#447: the floor used to enter as `ceil(gap)`, which demands `1.5 x` the gap in patience
    /// and, through the `3 x TD` holdback, `4.5 x` it in startup depth. Nobody chose that margin; it came
    /// from treating an arrival interval as if it were a segment duration. The conservatism belongs where
    /// it is already paid for: the meter reports the MAX over a trailing window, not the mean, so the gap
    /// handed in here is a worst case already. Multiplying a worst case by 1.5 counts it twice, and at a
    /// 2.000 s cadence the ordinary jitter that makes it 2.05 then buys a whole extra second of TD and
    /// three of holdback (measured: 1.07-1.09 s of wall clock per zap).
    static func targetDurationForCadence(_ cadenceSeconds: Double) -> Int {
        wholeSecondsCovering(cadenceSeconds / unchangedPlaylistPatienceMultiplier)
    }

    /// A duration as the playlist actually serves it: `#EXTINF` is written with `%.3f`, so a millisecond
    /// is the finest distinction any client can ever read, and nothing below it may decide anything.
    ///
    /// AE#447 round 2: the live durations are differences of accumulated item-axis doubles
    /// (`nextStart - startSeconds` in `reportLiveSegmentFinalized`), and the two operands carry different
    /// representation error, so a strictly 2.000 s GOP produces the odd `2.0000000000000004`. Measured on
    /// the reporter's device: 74 of 80 segments exactly `2.0`, 6 one to four ulp above. `ceil` weighs that
    /// invisible excess as a whole second, the seal takes the MAX over the window so one segment is enough,
    /// and `3 x TD` turns it into a 9 s holdback: the same 1.1 s per zap the first four fixes removed,
    /// arriving through a term nobody could see (his log read `max EXTINF 2.000s` and sealed at 3).
    /// The rounding matches `String(format: "%.3f")`, ties away from zero, so this is never BELOW what the
    /// playlist prints and the promise always covers the segment the client was handed. `seconds(_:)`
    /// below is the same quantization as text, so a term printed in the seal line is the term that
    /// decided it.
    static func servedSeconds(_ seconds: Double) -> Double {
        (seconds * 1000).rounded(.toNearestOrAwayFromZero) / 1000
    }

    /// Whole seconds of promise covering a measured duration, taken at the served resolution.
    static func wholeSecondsCovering(_ seconds: Double) -> Int {
        Int(servedSeconds(seconds).rounded(.up))
    }

    /// AE#454: the served `EXT-X-START:TIME-OFFSET` for a rejoin, or nil when this playlist cannot
    /// carry the placement.
    ///
    /// The item's own timeline is the SUM OF THE PRINTED EXTINFs, not the producer's accumulated
    /// output axis, so every term here is taken at the resolution the playlist serves. A target the
    /// window has already evicted returns nil, and so does one within `3 x TARGETDURATION` of the end:
    /// RFC 8216 4.3.5.2 says a positive offset should not sit inside the holdback, and a viewer that
    /// close to the edge is one the ordinary edge join answers correctly anyway.
    static func rejoinStartTimeOffset(
        segmentIndex: Int,
        secondsIntoSegment: Double,
        firstVisible: Int,
        visibleCount: Int,
        targetDuration: Int,
        segmentDuration: (Int) -> Double
    ) -> Double? {
        guard segmentIndex >= firstVisible, segmentIndex < visibleCount, firstVisible < visibleCount else {
            return nil
        }
        var offset: Double = 0
        for k in firstVisible..<segmentIndex { offset += servedSeconds(segmentDuration(k)) }
        offset += servedSeconds(Swift.max(0, secondsIntoSegment))
        var total: Double = 0
        for k in firstVisible..<visibleCount { total += servedSeconds(segmentDuration(k)) }
        let served = servedSeconds(offset)
        guard served >= 0, served <= servedSeconds(total - 3.0 * Double(targetDuration)) else { return nil }
        return served
    }

    /// Served `#EXT-X-TARGETDURATION`, in whole seconds: `>= ceil(max EXTINF)` (HLS requirement), floored
    /// by `ceil(1.5 x cut target)` (widens AVPlayer's unchanged-playlist patience, anti -12888) and by
    /// what the observed cadence needs to stay inside that patience. `cutTargetSeconds` /
    /// `cadenceFloorSeconds` are nil for VOD/EVENT. Every term is taken at the resolution the playlist
    /// serves (`servedSeconds`), so the value covers the EXTINFs the client is actually handed and no
    /// sub-millisecond noise can buy a whole second of holdback.
    static func targetDurationSeconds(maxSegmentDuration: Double,
                                      cutTargetSeconds: Double?,
                                      cadenceFloorSeconds: Double?) -> Int {
        var td = wholeSecondsCovering(max(1.0, maxSegmentDuration))
        if let cut = cutTargetSeconds { td = max(td, wholeSecondsCovering(cut * 1.5)) }
        if let floor = cadenceFloorSeconds { td = max(td, targetDurationForCadence(floor)) }
        return td
    }

    /// AVPlayer's default (and our explicitly advertised) live-edge holdback: `3 x TARGETDURATION`, the
    /// RFC 8216bis floor for `EXT-X-SERVER-CONTROL:HOLD-BACK`.
    static func holdBackSeconds(targetDuration: Int) -> Double { Double(3 * targetDuration) }

    /// One observed segment duration gives a strict-realtime fastZap source one more chance to fill
    /// naturally, while the clamp keeps the startup bound useful for unusually short or long GOPs.
    static func fastZapDegradedGraceSeconds(
        maxSegmentDuration: Double
    ) -> TimeInterval {
        min(2.0, max(0.5, maxSegmentDuration))
    }

    /// First-serve gate: hold the first live manifest until the window carries at least the live-edge
    /// holdback (`3 x TD`) of content behind the edge, so AVPlayer's initial seek-to-edge-minus-holdback
    /// lands inside the window instead of the stall-danger zone. Bounded above by `windowSegmentCount`: a
    /// tiny-segment source can never be made to wait for more than the sliding window will ever hold (the
    /// wall-clock deadline in `waitForFirstLiveSegment` is the outer bound). A source that arrives with a
    /// backlog (Jellyfin transcode, or an upstream live window pulled at I/O speed) satisfies this almost
    /// immediately; only a strict-realtime origin pays the deepen-the-buffer latency, which is inherent to
    /// joining long-GOP live safely.
    static func startupCushionSatisfied(segmentCount: Int,
                                        summedDurationSeconds: Double,
                                        maxSegmentDuration: Double,
                                        cutTargetSeconds: Double?,
                                        cadenceFloorSeconds: Double?,
                                        windowSegmentCount: Int) -> Bool {
        let td = targetDurationSeconds(maxSegmentDuration: maxSegmentDuration,
                                       cutTargetSeconds: cutTargetSeconds,
                                       cadenceFloorSeconds: cadenceFloorSeconds)
        return startupCushionSatisfied(
            segmentCount: segmentCount,
            summedDurationSeconds: summedDurationSeconds,
            targetDuration: td,
            windowSegmentCount: windowSegmentCount
        )
    }

    static func startupCushionSatisfied(segmentCount: Int,
                                        summedDurationSeconds: Double,
                                        targetDuration: Int,
                                        windowSegmentCount: Int) -> Bool {
        guard segmentCount >= minStartupSegments else { return false }
        if segmentCount >= windowSegmentCount { return true }
        // Judged at the served resolution too, or the depth check disagrees with the value it is checking
        // against. Same accumulated-double error, other direction: three 2.000 s segments sum to exactly
        // 6.0 for some first-segment starts and to a hair under it for others (a first start of 0.030 s
        // lands short, the reporter's 0.060 s does not), and the gate would then hold for a fourth
        // segment it does not need, a full extra segment duration, on some sessions and not others.
        return servedSeconds(summedDurationSeconds) >= holdBackSeconds(targetDuration: targetDuration)
    }

    /// AE#374: the first live manifest's own account of what it cost, for the log.
    ///
    /// The loopback's entire live-join latency is this one withheld response: everything the engine does
    /// for itself is finished before the gate is entered, and the wait that follows is the runway being
    /// filled at whatever rate the origin hands it over. `.standard` used to log only when the gate
    /// failed, so a successful hold of eighteen seconds left no trace at all and a downstream host had to
    /// measure it from the outside. Named here the way the reroute line names the grace it saves (#274).
    static func firstServeAccount(waitedSeconds: TimeInterval,
                                  segmentCount: Int,
                                  summedDurationSeconds: Double,
                                  targetDuration: Int) -> String {
        let holdBack = holdBackSeconds(targetDuration: targetDuration)
        let reached = servedSeconds(summedDurationSeconds) >= holdBack ? ">=" : "<"
        return "first live manifest served after \(seconds(waitedSeconds))s: "
            + "\(segmentCount) segments / \(seconds(summedDurationSeconds))s "
            + "\(reached) \(seconds(holdBack))s holdback (TARGETDURATION \(targetDuration)s)"
    }

    /// Millisecond resolution, because the interval this reports spans four orders of magnitude: a
    /// backlogged origin satisfies the cushion in single-digit milliseconds and a strict-realtime one
    /// takes the full holdback.
    static func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// AE#447 round 3: an absent cadence floor is two different facts, and the seal printed one word for
/// both. A meter exists only where the upstream hands over finished segments (live ingest); a source the
/// engine cuts itself has no arrival cadence at all, so its floor is not pending, it does not exist. The
/// reporter's raw-TS session read `measured floor none yet` on every tune of two runs and reasonably took
/// it for a meter that had not measured anything YET, which credited four fixes on a path none of them
/// could reach. A term that cannot be measured has to say so.
enum CadenceFloorTerm {
    /// The meter has a measurement, in seconds.
    case measured(Double)
    /// A meter is running and has nothing yet: an ingest session before its first closed interval.
    case pending
    /// No meter on this path: the engine cuts these segments itself, so no arrival cadence exists.
    case unmeasurable

    /// The value that feeds the max, which only a real measurement ever does.
    var seconds: Double? {
        if case .measured(let value) = self { return value }
        return nil
    }

    /// The term as the seal line states it, in the list the other terms are joined into.
    var account: String {
        switch self {
        case .measured(let value):
            return "measured floor \(LiveEdgePolicy.seconds(value))s needs "
                + "\(LiveEdgePolicy.targetDurationForCadence(value))s of patience"
        case .pending:
            return "measured floor none yet"
        case .unmeasurable:
            return "no measured floor (segments are cut here, not ingested)"
        }
    }
}

/// AE#447: the served TARGETDURATION with the terms it was derived from, so the seal can say in one
/// line why the session will hold this value for its whole life. Every term but `selfReported` feeds
/// the max; `selfReported` is what the upstream CLAIMED, printed beside what was measured.
struct LiveTargetDurationDerivation {
    let value: Int
    let maxSegmentDuration: Double
    let cutTargetFloor: Double?
    let cadenceFloor: CadenceFloorTerm
    let selfReported: Double?

    /// One line, in the order the terms are maxed. Reads as an argument for the number it reports.
    var account: String {
        var terms = ["max EXTINF \(LiveEdgePolicy.seconds(maxSegmentDuration))s"]
        if let cutTargetFloor {
            terms.append("1.5 x cut target \(LiveEdgePolicy.seconds(cutTargetFloor * 1.5))s")
        }
        terms.append(cadenceFloor.account)
        let claim = selfReported.map {
            "; upstream advertises \(LiveEdgePolicy.seconds($0))s (reported, not used)"
        } ?? ""
        return "live TARGETDURATION sealed at \(value)s "
            + "(holdback \(LiveEdgePolicy.seconds(LiveEdgePolicy.holdBackSeconds(targetDuration: value)))s): "
            + terms.joined(separator: ", ") + claim
    }
}

struct LiveTargetDurationSeal {
    private(set) var value: Int?
    private var didLogUpwardDrift = false

    mutating func resolve(candidate: Int) -> (value: Int, shouldLogDrift: Bool, didSeal: Bool) {
        guard let sealed = value else {
            value = candidate
            return (candidate, false, true)
        }
        guard candidate > sealed, !didLogUpwardDrift else {
            return (sealed, false, false)
        }
        didLogUpwardDrift = true
        return (sealed, true, false)
    }
}

// MARK: - Cache-backed provider

/// Thin HLSSegmentProvider over SegmentCache. Cache misses block the HTTP server's connection
/// thread on a per-index condvar (backpressure model). Scrub policy: in-cache = fast path;
/// forward seek within forwardWaitWindow of cache.max = wait; anything else fires restartHandler.
final class VideoSegmentProvider: HLSSegmentProvider, @unchecked Sendable {

    private let cache: SegmentCache
    /// Immutable for VOD; grows under stateLock for live (producer appends via appendLiveSegment).
    private var segments: [HLSVideoEngine.Segment]
    private let isLive: Bool
    /// Sequential-origin session: playlist grows with finalized real durations (see _seqDurations).
    private let sequentialAppendPlaylist: Bool
    /// Drives both playlist firstVisible and cache eviction cutoff so they never drift.
    private let liveWindowSizing: LiveWindowSizing
    /// Only `.fastZap` sessions may serve a shallow first window after a bounded grace.
    private let allowsBoundedDegradedStart: Bool
    /// AE#374: whether the first-serve gate has already reported the interval it held. Read and written
    /// only under `firstSegmentCondition`, inside `waitForFirstLiveSegment` and its two account helpers.
    private var didAccountForFirstServe = false
    /// Host override for blocking-reload (`LoadOptions.liveBlockingReload`): nil = auto (observed policy for
    /// ingest, on by default for signal-less live), true/false = force. Wins over the policy (#167).
    private let blockingReloadOverride: Bool?
    /// Observed-cadence policy for live ingest sources; drives blocking-reload eligibility and the
    /// TARGETDURATION floor from real arrival cadence. nil for URL live (no cadence signal) and VOD (#167).
    private let liveCadencePolicy: LiveCadencePolicy?

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?
    private let sourceBitrate: Int64

    /// #15: native subtitle cue stores (one per text track) for the WebVTT rendition served to AVPlayer.
    /// Immutable references; each store is internally locked and filled lazily by the readers on selection.
    private let nativeSubStores: [NativeSubtitleCueStore]
    private let nativeSubLanguages: [String?]
    private let nativeSubRenditionInfos: [NativeSubtitleRenditionInfo]
    /// Ordinal advertised as DEFAULT=YES in the master SUBTITLES group (Sodalite#32).
    let nativeSubtitleDefaultOrdinal: Int
    /// Serve the SUBTITLES rendition as ONE whole-program .vtt (single VOD segment spanning the full duration)
    /// instead of one .vtt per video segment. The only AVPlayer-reliable sideload shape (Sodalite#32); requires
    /// eager readers (all cues available up front) and a bounded program (VOD).
    let nativeSubtitleWholeProgram: Bool
    /// Current engine playlist shift (AVPlayer clock = source_pts - shift), read at serve time so whole-program
    /// cues land on the same AVPlayer axis as the video even when the shift was not known at load (Sodalite#32).
    private let currentShiftSeconds: @Sendable () -> Double
    /// AE#418: fired with the index AVPlayer just placed into its timeline. What that segment
    /// carries below its advertised start is what moves the axis every consumer folds with.
    private let segmentPlacedHandler: (@Sendable (Int) -> Void)?
    /// Sodalite#32 Phase 2: tap-fed stores can carry raw ASS event lines (the overlay renders the
    /// styling); the WebVTT rendition must serve plain text, so strip at build time.
    private let stripASSMarkupInVTT: Bool

    /// Synchronous teardown + relaunch at the given absolute segment index.
    private let restartHandler: ((Int) -> Void)?
    /// Called with a plan index the consumer wants and no pump will ever open (#358).
    private let unrecoverableGapHandler: ((Int) -> Void)?
    /// True while the engine's restart coalescer has an in-flight run (#93 residual): waiting
    /// fetches ride it instead of burning fixed retry budgets, and never re-fire at stale indices.
    private let restartActivity: (() -> Bool)?
    /// Base index of the active producer (#93 residual): a fetch for an index within the
    /// producer's forward march window waits for the march instead of tearing it down.
    private let activeProducerBase: (() -> Int?)?
    /// AE#169 round 2: whether the installed producer's pump has EXITED (any reason). A finished
    /// pump can never march, so a forward-window fetch must restart instead of backpressure-waiting
    /// on a front that is provably frozen. nil/false during a coalesced restart (no producer
    /// installed) keeps the normal wait+ride paths.
    private let producerFinished: (() -> Bool)?

    /// AE#169 round 2: single-slot record of the last forward-window fetch that burned its FULL
    /// backpressure wait. Same index + unmoved march front on the next fetch is proof the march is
    /// not coming (the wait would re-arm forever against a dead producer); a moved front overwrites
    /// the record and keeps the patience. Guarded by stateLock.
    private var _forwardMissIndex: Int = .min
    private var _forwardMissFront: Int = .min

    /// Base index of the engine's current producer. Guards against stale-producer waits:
    /// abs(index - lastRestartIndex) <= 2 = cold start, wait; larger = restart needed.
    /// Guarded by stateLock (concurrent workQueue can double-trigger on stale value).
    private var lastRestartIndex: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastRestartIndex }
        set { stateLock.lock(); _lastRestartIndex = newValue; stateLock.unlock() }
    }
    private var _lastRestartIndex: Int = 0

    /// 8 absorbs AVPlayer's 5-7 segment speculative prefetch at 4 s segments (~32 s headroom)
    /// while keeping user-initiated 30+ s scrubs below the threshold. Tightened to 3 once;
    /// every AVPlayer prefetch above cache.max+3 cascaded into restarts and produced cache holes.
    private static let forwardWaitWindow = 8

    /// #50: re-asserting reposition wait. Sliced waits re-fire restart only when lastRestartIndex
    /// changed (orphan signature: #35 coalescer's single slot was overwritten by a newer scrub).
    /// Slice is generous enough to absorb a cold 4K-HDR first-GOP decode. Instance lets so the
    /// wait shape is testable without 8 s sleeps (#93 residual).
    private let repositionWaitSlice: TimeInterval
    /// A cache index range can be sparse after scrubbing. Wait only when the active producer can
    /// actually fill an interior hole; otherwise restart immediately instead of burning this slice.
    private let sparseHoleWaitSlice: TimeInterval
    private static let repositionMaxWaits = 3
    /// Hard cap on riding an in-flight restart (#93 residual): a fetch waits past the fixed
    /// budget while a restart is genuinely executing, but never indefinitely.
    private let repositionRideCapSeconds: TimeInterval
    /// Blocking wait for a forward request the active producer is about to write (test-injectable;
    /// production stays at 30 s, matching AVPlayer's serve patience before it retries).
    private let forwardBackpressureWaitSeconds: TimeInterval
    /// #93 round 3: a VOD serve still running at this age signals `onSlow` so the server can emit
    /// an early chunked header, keeping time-to-first-byte under AVPlayer's ~3.5 s -12889 window.
    private let slowServeThresholdSeconds: TimeInterval

    // MARK: - Playlist state

    private let stateLock = NSLock()
    /// Separate from stateLock so the manifest handler can block without holding the segment-list lock.
    private let firstSegmentCondition = NSCondition()
    /// Set by cancelWaiters() on stop(). Without it, parked LL-HLS blocking-reload threads sleep
    /// their full timeout (18-30 s) and can write stale playlists into a recycled fd of the next session.
    private var waitersCancelled = false
    /// Terminal latch (#167 follow-up): the live pump exited for host retune (SSAI cutter wedge,
    /// source replay, custom-reader death), so no further segment will ever be cut into this provider.
    /// The cadence policy cannot see this (it observes ingest arrivals, which keep flowing while the
    /// cutter is wedged), so it is a separate, producer-level condition.
    private var _liveProductionHalted = false
    /// RFC 8216 requires TARGETDURATION to stay constant for the lifetime of a media playlist.
    /// Guarded by stateLock and preserved across in-provider producer reopens.
    private var liveTargetDurationSeal = LiveTargetDurationSeal()
    /// AE#446: wall time of the newest finalized live segment, and the latch that says the source
    /// stopped delivering. See `liveDeliveryStalled`.
    private var _lastLiveSegmentFinalizedAt: Date?
    private var _liveDeliveryStalledLatched = false
    /// AE#446 round 2: once ENDLIST has been served it can never be withdrawn to the item that saw it,
    /// so the decision latches. See `liveOutageEndlist`.
    private var _liveOutageEndlistLatched = false
    /// AE#454: where a rejoin wants the NEXT item to begin, addressed by CONTENT (which segment, how
    /// far into it) rather than by a clock. The window slides between arming this and the fresh item
    /// fetching the playlist that carries it, so a seconds value would name a different place by the
    /// time it was served; a segment index does not renumber.
    private var _liveRejoinStart: (segmentIndex: Int, secondsIntoSegment: Double)?
    private var refreshCounter: Int = 0
    /// EXT-X-MEDIA-SEQUENCE first index; monotonically advancing, stays 0 for VOD.
    private var _liveFirstVisible: Int = 0
    /// EXT-X-DISCONTINUITY-SEQUENCE: incremented for each discontinuous segment that slides out.
    private var _discontinuitySequence: Int = 0
    /// Rolling EXTINF of the most recent finalized live segments; feeds the observed-cadence
    /// divisor of `LiveWindowSizing.windowSegmentCount(observedSegmentDurationSeconds:)`.
    /// Guarded by stateLock.
    private var _liveRecentDurations: [Double] = []
    /// AE#443: the window-clamp line is a statement about the session, so it is made once.
    private var _loggedLiveWindowClamp = false
    private static let liveRecentDurationSampleCount = 20
    /// One-shot latch for `noteWindowSlideRelativeToConsumer`. Guarded by stateLock.
    private var _liveConsumerOutsideWindowLatched = false

    /// Sequential-origin append playlist: real EXTINF per finalized segment, index-aligned and
    /// contiguous from 0. The static VOD plan's uniform durations are a lie for archives whose
    /// GOP cadence does not divide the cut target (device trace: 1.92 s GOPs against a 4.0 s
    /// plan put every segment's media up to 1.9 s outside its advertised window; AVPlayer
    /// showed a content jump at every resync). Guarded by stateLock.
    private var _seqDurations: [Double] = []
    /// Producer reached true source EOF: the next playlist build appends ENDLIST. Guarded by stateLock.
    private var _seqEnded = false
    /// #370: the pump died before publishing anything; a held startup-playlist GET must not sit out
    /// the rest of its timeout for a session that is already failing. Guarded by stateLock.
    private var _seqStartupAborted = false
    /// #370 follow-up: how many appended entries the playlist renderer will actually advertise. A
    /// zero-duration entry is a plan index a long GOP skipped, and `buildMediaPlaylistText` gives it
    /// no URI, so counting raw entries would let the startup gate release onto a playlist that
    /// renders empty. That is the very thing the gate exists to prevent (-12888 on first read), and
    /// with the cushion down to one entry there is no longer a second entry to mask it.
    /// Guarded by stateLock.
    private var _seqAdvertisableCount = 0

    /// #370: never hold the first media playlist for more than ONE published duration. The live
    /// constant this gate reused (`LiveEdgePolicy.minStartupSegments = 2`) guards a SLIDING window
    /// whose live-edge holdback can't fit one segment; an EVENT playlist starts at media sequence 0,
    /// grows append-only, and its refresh counter already defeats AVPlayer's unchanged-playlist
    /// patience (-12888). The cost of demanding 2 was concrete: a published duration needs the NEXT
    /// segment's ledger open, so "2 durations" = 3 segment opens ≈ 12-18 s of media through a
    /// possibly-stalling origin. The field session held AVPlayer's playlist GET for the full 30 s
    /// and the asset load timed out (-12884) with ~12 s of media already on disk.
    static let sequentialStartupSegments = 1

    init(
        cache: SegmentCache,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?,
        sourceBitrate: Int64,
        isLive: Bool = false,
        sequentialAppendPlaylist: Bool = false,
        liveWindowSizing: LiveWindowSizing = LiveWindowSizing(targetSegmentDurationSeconds: 4.0, dvrWindowSeconds: nil),
        allowsBoundedDegradedStart: Bool = false,
        blockingReloadOverride: Bool? = nil,
        liveCadencePolicy: LiveCadencePolicy? = nil,
        restartHandler: ((Int) -> Void)? = nil,
        unrecoverableGapHandler: ((Int) -> Void)? = nil,
        restartActivity: (() -> Bool)? = nil,
        activeProducerBase: (() -> Int?)? = nil,
        producerFinished: (() -> Bool)? = nil,
        initialRestartIndex: Int = 0,
        repositionWaitSlice: TimeInterval = 8.0,
        sparseHoleWaitSlice: TimeInterval = 2.0,
        repositionRideCapSeconds: TimeInterval = 90.0,
        forwardBackpressureWaitSeconds: TimeInterval = 30.0,
        slowServeThresholdSeconds: TimeInterval = 2.0,
        nativeSubtitleStores: [NativeSubtitleCueStore] = [],
        nativeSubtitleLanguages: [String?] = [],
        nativeSubtitleRenditionInfos: [NativeSubtitleRenditionInfo] = [],
        stripASSMarkupInVTT: Bool = false,
        nativeSubtitleDefaultOrdinal: Int = 0,
        nativeSubtitleWholeProgram: Bool = false,
        currentShiftSeconds: @escaping @Sendable () -> Double = { 0 },
        segmentPlacedHandler: (@Sendable (Int) -> Void)? = nil
    ) {
        self.cache = cache
        self.segments = segments
        self.isLive = isLive
        self.sequentialAppendPlaylist = sequentialAppendPlaylist
        self.liveWindowSizing = liveWindowSizing
        self.allowsBoundedDegradedStart = allowsBoundedDegradedStart
        self.blockingReloadOverride = blockingReloadOverride
        self.liveCadencePolicy = liveCadencePolicy
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
        self.sourceBitrate = sourceBitrate
        self.restartHandler = restartHandler
        self.unrecoverableGapHandler = unrecoverableGapHandler
        self.restartActivity = restartActivity
        self.activeProducerBase = activeProducerBase
        self.producerFinished = producerFinished
        self._lastRestartIndex = initialRestartIndex
        self.repositionWaitSlice = repositionWaitSlice
        self.sparseHoleWaitSlice = sparseHoleWaitSlice
        self.repositionRideCapSeconds = repositionRideCapSeconds
        self.forwardBackpressureWaitSeconds = forwardBackpressureWaitSeconds
        self.slowServeThresholdSeconds = slowServeThresholdSeconds
        self.nativeSubStores = nativeSubtitleStores
        self.nativeSubLanguages = nativeSubtitleLanguages
        self.nativeSubRenditionInfos = nativeSubtitleRenditionInfos
        self.stripASSMarkupInVTT = stripASSMarkupInVTT
        self.nativeSubtitleDefaultOrdinal = nativeSubtitleDefaultOrdinal
        self.nativeSubtitleWholeProgram = nativeSubtitleWholeProgram
        self.currentShiftSeconds = currentShiftSeconds
        self.segmentPlacedHandler = segmentPlacedHandler
    }

    /// Append a finalized live segment. Index must equal segments.count; out-of-order ignored.
    func appendLiveSegment(index: Int, startSeconds: Double, durationSeconds: Double,
                           discontinuous: Bool = false) {
        stateLock.lock()
        guard index == segments.count else {
            stateLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] live segment append out of order: got index=\(index), "
                + "expected \(segments.count); ignoring",
                category: .session
            )
            return
        }
        // source TB not reachable here; DVR restart machinery will supply correct values when wired
        let startPts: Int64 = 0
        let endPts: Int64 = 0
        segments.append(HLSVideoEngine.Segment(
            startPts: startPts,
            endPts: endPts,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            discontinuous: discontinuous
        ))
        _lastLiveSegmentFinalizedAt = Date()
        _liveRecentDurations.append(durationSeconds)
        if _liveRecentDurations.count > Self.liveRecentDurationSampleCount {
            _liveRecentDurations.removeFirst(_liveRecentDurations.count - Self.liveRecentDurationSampleCount)
        }
        stateLock.unlock()
        firstSegmentCondition.lock()
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Append the real duration of a finalized sequential-VOD segment (index-contiguous from 0;
    /// out-of-order appends are ignored like the live path's). The playlist's visible count and
    /// EXTINF values follow these, so AVPlayer only ever sees segments whose advertised duration
    /// matches the media inside them.
    func appendSequentialSegmentDuration(index: Int, durationSeconds: Double) {
        stateLock.lock()
        guard index == _seqDurations.count else {
            stateLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] sequential segment append out of order: got index=\(index), "
                + "expected \(_seqDurations.count); ignoring",
                category: .session
            )
            return
        }
        // Zero marks a plan index a long GOP skipped entirely (no media file exists); the
        // playlist renderer omits those entries. Negative values are producer bugs, clamp them.
        let clamped = max(0, durationSeconds)
        _seqDurations.append(clamped)
        if clamped > 0 { _seqAdvertisableCount += 1 }
        stateLock.unlock()
        firstSegmentCondition.lock()
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Producer reached true source EOF: the next playlist build renders as a completed VOD
    /// asset (ENDLIST). Never called for a torn-down session, whose playlist simply stops
    /// being served.
    func markSequentialEnded() {
        stateLock.lock()
        _seqEnded = true
        stateLock.unlock()
        firstSegmentCondition.lock()
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Hold the first media playlist until the startup segment exists (mirrors the live gate:
    /// an empty playlist is a broken asset to AVPlayer, which never re-polls it). A fast
    /// archive origin cuts the first segments within a second.
    func waitForSequentialStartupSegments(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            stateLock.lock()
            let ready = _seqAdvertisableCount >= Self.sequentialStartupSegments || _seqEnded
            let aborted = _seqStartupAborted
            stateLock.unlock()
            if ready { return true }
            if aborted { return false }
            if !firstSegmentCondition.wait(until: deadline) { return false }
        }
    }

    /// #370: release a held startup-playlist GET when the pump dies before publishing anything.
    /// The session is failing anyway; holding the server thread for the rest of the timeout only
    /// delays the host's failure surface.
    func abortSequentialStartupWait() {
        stateLock.lock()
        _seqStartupAborted = true
        stateLock.unlock()
        firstSegmentCondition.lock()
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Called on each playlist build. For live: advances firstVisible to max(0, highWater - window),
    /// evicts cache below it, and increments _discontinuitySequence for each dropped discontinuous segment.
    /// VOD: returns full count so AVPlayer sees a complete asset (EVENT experiment that reported
    /// visibleHighWater+1 made AVPlayer think the asset was 2:13 and stop there).
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        // AE#443: read the cache's own measure of a segment BEFORE taking stateLock. The cache has its
        // own lock, and nesting it inside this one would invert the ordering `evictBelow`'s async hop
        // below exists to avoid.
        let observedBytes = cache.meanEntryBytes
        stateLock.lock()
        defer { stateLock.unlock() }
        refreshCounter += 1
        if isLive {
            let total = segments.count
            let observedMean = _liveRecentDurations.isEmpty
                ? nil : _liveRecentDurations.reduce(0, +) / Double(_liveRecentDurations.count)
            let window = liveWindowSizing.windowSegmentCount(observedSegmentDurationSeconds: observedMean,
                                                             observedSegmentBytes: observedBytes)
            noteLiveWindowClampLocked(window: window, observedSegmentBytes: observedBytes,
                                      observedSegmentDurationSeconds: observedMean)
            // highWater is the last produced index (total - 1). Keep the
            // last `window` segments visible: firstVisible = highWater -
            // window + 1 = total - window. Until at least `window`
            // segments exist, do not advance past 0 so AVPlayer's first
            // read sees all produced segments and can establish a live
            // edge without losing a not-yet-buffered position.
            let newFirst = max(0, total - window)
            if newFirst > _liveFirstVisible {
                // RFC 8216 §6.2.2: EXT-X-DISCONTINUITY-SEQUENCE must increment for each
                // discontinuity-tagged segment that slides out; segments array is never pruned.
                for i in _liveFirstVisible..<newFirst where segments[i].discontinuous {
                    _discontinuitySequence += 1
                }
                _liveFirstVisible = newFirst
                let cutoff = newFirst
                let cacheRef = cache
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    // Read the consumer's fetch point BEFORE evicting, and off stateLock (the cache has
                    // its own lock; nesting the two here would invert the ordering evictBelow's async
                    // hop exists to avoid).
                    let consumerTarget = cacheRef.targetIndex
                    cacheRef.evictBelow(Self.liveEvictionFloor(firstVisible: cutoff,
                                                               consumerTarget: consumerTarget))
                    self?.noteWindowSlideRelativeToConsumer(cutoff: cutoff, consumerTarget: consumerTarget)
                }
            }
            return (total, _liveFirstVisible, refreshCounter, false, _discontinuitySequence)
        }
        if sequentialAppendPlaylist {
            // Only finalized segments are visible (their EXTINF is real); the playlist grows as
            // the producer cuts and completes with ENDLIST at true source EOF. The plan bounds
            // the count so a source running past the declared window cannot outgrow the asset.
            let visible = min(_seqDurations.count, segments.count)
            return (visible, 0, refreshCounter, _seqEnded, 0)
        }
        return (segments.count, 0, refreshCounter, false, 0)
    }

    /// AE#441 round 3: what a window slide costs is decided by the consumer's NEXT fetch, not its last.
    ///
    /// `declareTarget` is called as a segment is served and the consumer walks indices forward one at a
    /// time, so everything strictly below `consumerTarget` is already in AVPlayer's own buffer and the
    /// index it will ask for next is `consumerTarget + 1`. A viewer parked at the floor therefore sits
    /// at `firstVisible - 1` for part of every segment, by the same one-segment sawtooth
    /// `residentFloorOutputSeconds()` has against the rendered playhead: the slide moves in whole
    /// segments while the consumer moves continuously. Its next fetch is `firstVisible` itself, which is
    /// resident, so nothing is missed. From `firstVisible - 2` down the index it is about to ask for has
    /// been deleted, and that is the cache miss this line exists to name.
    static func windowSlidPastConsumer(firstVisible: Int, consumerTarget: Int) -> Bool {
        return consumerTarget + 1 < firstVisible
    }

    /// The lowest index a window slide may unlink, which is not always the playlist's new first visible.
    ///
    /// A serve holds a URL, not a file handle: `mediaSegmentURL` hands `peekURL`'s result to a response
    /// that stats and opens the file afterwards, so unlinking the segment currently being served turns
    /// into a 404 for an index the playlist offered when it was asked for. And a viewer riding the floor
    /// puts the slide exactly one segment above the fetch point routinely, not rarely (measured: every
    /// latched line of a 220 s parked run had `firstVisible == consumerTarget + 1`). So eviction stops at
    /// the fetch point, which is the bound `evictBelow` already documents for itself.
    ///
    /// Bounded on the other side too: the floor never trails `firstVisible` by more than one segment, so
    /// a consumer that has stopped fetching entirely cannot pin retention behind it.
    static func liveEvictionFloor(firstVisible: Int, consumerTarget: Int) -> Int {
        guard consumerTarget >= 0 else { return firstVisible }
        return max(firstVisible - 1, min(firstVisible, consumerTarget))
    }

    /// The sliding window overtaking the consumer's fetch point is the failure mode the removed advance
    /// park used to make impossible (it capped the producer 10 segments ahead of that point). Live is
    /// source-paced, so a real-time origin cannot get there; an origin that hands over more than one
    /// window of backlog faster than the consumer drains it can, and the consumer then asks for a
    /// segment `evictBelow` has already deleted. That surfaces downstream as a cache miss, a jump, or a
    /// silent rejoin, none of which name this cause, so name it here. Latched: once out, every
    /// subsequent build would repeat it.
    private func noteWindowSlideRelativeToConsumer(cutoff: Int, consumerTarget: Int) {
        guard consumerTarget >= 0 else { return }
        stateLock.lock()
        let outside = Self.windowSlidPastConsumer(firstVisible: cutoff, consumerTarget: consumerTarget)
        let shouldLog = outside && !_liveConsumerOutsideWindowLatched
        _liveConsumerOutsideWindowLatched = outside
        stateLock.unlock()
        guard shouldLog else { return }
        EngineLog.emit(
            "[HLSVideoEngine] live window slid past the consumer: firstVisible=\(cutoff) "
            + "consumerTarget=\(consumerTarget) (producer is running more than one window ahead; "
            + "expect a cache miss or a live-edge jump)",
            category: .session
        )
    }

    /// AE#443: says once that the window a host asked for is deeper than the disk can hold.
    ///
    /// Silent otherwise. The clamp is not a failure, it is the window becoming a fact, and a host that
    /// wants to know what it really got reads `seekableLiveRange` (AE#441), which measures the same
    /// cache. Must be called with stateLock held.
    private func noteLiveWindowClampLocked(window: Int, observedSegmentBytes: Int?,
                                           observedSegmentDurationSeconds: Double?) {
        guard !_loggedLiveWindowClamp else { return }
        let asked = liveWindowSizing.requestedSegmentCount(
            observedSegmentDurationSeconds: observedSegmentDurationSeconds)
        guard window < asked else { return }
        _loggedLiveWindowClamp = true
        let cadence = max(max(0.5, liveWindowSizing.targetSegmentDurationSeconds),
                          observedSegmentDurationSeconds ?? 0)
        let affordable = LiveWindowSizing.affordableSegments(
            retentionBudgetBytes: liveWindowSizing.retentionBudgetBytes,
            observedSegmentBytes: observedSegmentBytes)
        let bound = affordable <= LiveWindowSizing.maxWindowSegments
            ? "\(liveWindowSizing.retentionBudgetBytes / (1 << 20)) MiB of retention holds "
              + "\(affordable) segments of \((observedSegmentBytes ?? 0) / 1024) KiB"
            : "a live playlist is rebuilt and re-served on every poll, so it is capped at "
              + "\(LiveWindowSizing.maxWindowSegments) entries"
        EngineLog.emit(
            "[HLSVideoEngine] #443 live window served at \(window) segments "
            + "(~\(Int(Double(window) * cadence))s) of the \(asked) asked for "
            + "(~\(Int(Double(asked) * cadence))s): \(bound). The window slides here instead of the "
            + "producer parking against a resident cap it cannot pass",
            category: .session
        )
    }

    /// AE#443: the resident segment count the producer's runaway park must stay ABOVE.
    ///
    /// The park exists for a consumer that stopped polling entirely: with no playlist build there is no
    /// `evictBelow`, so nothing bounds the cache. It must never be the thing that bounds a LIVE window,
    /// because its enforcement is a sleeping read thread, and a live pump that stops reading stops
    /// draining the origin. Measured before this fix on the loopback fixture, an edge session with no
    /// seek at all: a 1800 s window at a 1 s cadence parked at resident=180 after 180 s and never
    /// released, the edge froze, and the ladder then reported the SOURCE as starved.
    func liveResidentParkCap() -> Int {
        stateLock.lock()
        let observedMean = _liveRecentDurations.isEmpty
            ? nil : _liveRecentDurations.reduce(0, +) / Double(_liveRecentDurations.count)
        stateLock.unlock()
        let window = liveWindowSizing.windowSegmentCount(observedSegmentDurationSeconds: observedMean,
                                                         observedSegmentBytes: cache.meanEntryBytes)
        return window + Self.liveResidentParkSlackSegments
    }

    /// Segments that can sit between the pump and the playlist build that would evict them, so the park
    /// is reached by a consumer that stopped polling and never by one that is merely a poll behind.
    static let liveResidentParkSlackSegments = 24

    var firstVisibleSegmentIndex: Int {
        guard isLive else { return 0 }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveFirstVisible
    }

    // MARK: - Thumbnail lookup (engine-internal)

    /// Pure lookup for the segment whose [startSeconds, startSeconds+duration) window
    /// contains `seconds`. No clamp past the end (unlike segmentIndex(forPlaylistTime:)):
    /// a scrub past the produced range must miss, not pin to the last segment. Exposed
    /// static for unit tests. lastIndex mirrors the live lookup (picks the most recent
    /// match across a discontinuity; identical to firstIndex for contiguous VOD segments).
    static func thumbnailSegmentIndex(atSeconds seconds: Double,
                                      segments: [HLSVideoEngine.Segment]) -> Int? {
        segments.lastIndex(where: {
            $0.startSeconds <= seconds && seconds < $0.startSeconds + $0.durationSeconds
        })
    }

    /// Pure lookup for a scrub thumbnail: no side effects, no restarts; nil outside the
    /// resident window or on a cache miss. Works for live and VOD (VOD `segments` carry
    /// `startSeconds` from init); callers gate on session type one layer up.
    func thumbnailSegment(atSeconds seconds: Double) -> (index: Int, startSeconds: Double, fileURL: URL)? {
        stateLock.lock()
        let segs = segments
        stateLock.unlock()
        guard let idx = Self.thumbnailSegmentIndex(atSeconds: seconds, segments: segs) else { return nil }
        guard let url = cache.peekURL(index: idx) else { return nil }
        return (idx, segs[idx].startSeconds, url)
    }

    /// AE#441: the oldest position a rewind can actually land on and still play forward, in output
    /// seconds, or nil when nothing is resident yet.
    ///
    /// The DVR window is a POLICY (how much the session is willing to keep); this is the FACT (how much
    /// it currently holds). They diverge for the whole first `window` seconds of every session, and
    /// again whenever the retention budget evicts faster than the window slides, so a rewind strip
    /// scaled on the policy alone promises depth that was never written.
    ///
    /// Walks back from the newest resident segment rather than reading `indexRange().0`, because a
    /// minimum index is not proof of contiguity: an interior hole would make everything below it
    /// unplayable, and a stale band left by a previous producer sits below one.
    func residentFloorOutputSeconds() -> Double? {
        guard let top = cache.highestResidentIndex else { return nil }
        let floor = cache.contiguousBackwardFloor(from: top)
        stateLock.lock()
        let segs = segments
        stateLock.unlock()
        guard floor >= 0, floor < segs.count else { return nil }
        return segs[floor].startSeconds
    }

    /// AE#446 round 4: the newest position the cache holds, in output seconds, i.e. the END of the
    /// newest resident segment.
    ///
    /// The floor above exists because the advertised window over-promises depth. This exists because
    /// at the one moment a rejoin runs, neither clock the engine publishes can be trusted for the
    /// other end: the session's edge is a running maximum that an outage freezes below the playhead,
    /// and a freshly swapped item's own `seekableEnd` is a range it has not finished reporting. The
    /// producer is the only party that knows what is actually there, and it knows it now rather than
    /// at the next publish tick.
    func residentCeilingOutputSeconds() -> Double? {
        guard let top = cache.highestResidentIndex else { return nil }
        stateLock.lock()
        let segs = segments
        stateLock.unlock()
        guard top >= 0, top < segs.count else { return nil }
        return segs[top].startSeconds + segs[top].durationSeconds
    }

    /// Non-blocking init.mp4 peek; the 30s blocking initSegment() is only for the HTTP server path.
    func peekInitSegment() -> Data? {
        cache.fetchInit(timeout: 0)
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    func initVersionID(forSegment index: Int) -> Int {
        cache.initVersionID(forSegment: index)
    }

    func initSegment(versionID: Int) -> Data? {
        if versionID == 0 { return cache.fetchInit(timeout: 30.0) }  // version 0 may not be ready yet at startup
        return cache.initData(versionID: versionID)
    }

    /// File URL for sendfile(2) fast path. Drives same side effects as mediaSegment(at:);
    /// without handleTargetChange the sendfile path would skip producer restarts on out-of-range fetches.
    func mediaSegmentURL(at index: Int) -> URL? {
        guard index >= 0, index < currentSegmentCount else { return nil }
        handleTargetChange(to: index)
        return cache.peekURL(index: index)
    }

    /// Total media-segment requests seen (both serve paths). The #65 consumer re-engage watchdog
    /// reads this after a wedge re-anchor: an unchanged count means AVPlayer stopped requesting
    /// entirely and needs a host-side nudge (#93 residual).
    var mediaFetchCount: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _mediaFetchCount
    }
    private var _mediaFetchCount: UInt64 = 0

    /// The index the consumer is currently blocked on, and how often a pump has passed it without
    /// producing a segment (#358). Two folds mean a re-anchor already tried and rebuilt the same gap.
    var consumerTargetFold: (index: Int, folds: Int) {
        let index = cache.targetIndex
        return (index, cache.foldCount(index))
    }

    /// AE#412: what the stored segment at `index` offers a cold arrival, or nil when the producer
    /// made no claim for it. See `SegmentCache.VideoReach`.
    func videoReach(at index: Int) -> SegmentCache.VideoReach? {
        return cache.videoReach(index)
    }

    /// AE#421: whether the segment for `index` is already on disk, answered without reading it.
    ///
    /// This is what separates the two repairs for a wedge. A producer re-anchor is the fix for a
    /// consumer STARVED of content nobody is producing; a consumer silent on a segment that is
    /// already stored is not starved, and re-anchoring throws away the pump's forward work to
    /// rebuild what it already has.
    func hasStoredSegment(at index: Int) -> Bool {
        return cache.peekURL(index: index) != nil
    }

    /// What to do with a request for a non-resident index, given how often pumps have folded it (#358).
    enum FoldedTargetDecision: Equatable {
        /// Nobody has folded this index: it is ordinary read-ahead, wait for the producer.
        case wait
        /// Folded once. The boundaries move with the producer's base, so anchoring the producer at
        /// this index can open it; measured on a 40 s-GOP source, this turns a permanent freeze into
        /// a session that plays to the end.
        case reanchor
        /// Folded again after that re-anchor, which is the repair reproducing its own trigger. No
        /// further attempt changes the outcome, so the source fails instead of freezing.
        case fail
    }

    /// AE#418 round 2: whether this request puts a segment into AVPlayer's timeline anew.
    ///
    /// Round 1 asked a narrower question here, whether the fetch BEGAN a decode run, and answered it
    /// from the fetch order: anything that did not follow its predecessor. The reporter's seek burst
    /// falsified that. A fetch out of sequence happens while AVPlayer stays inside the run it is
    /// already playing, so the axis was republished from under a picture that had not moved.
    ///
    /// What the axis actually turns on is placement, and every fetch is one, whatever its order.
    /// Asking for the SAME index again is the one exception: that is a retry of a placement already
    /// counted, and counting it twice would move the axis by an offset AVPlayer applied once.
    static func placesSegmentAnew(index: Int, previousTarget: Int) -> Bool {
        return index != previousTarget
    }

    static func foldedTargetDecision(folds: Int, alreadyReanchoredHere: Bool) -> FoldedTargetDecision {
        guard folds > 0 else { return .wait }
        if folds >= HLSVideoEngine.foldsProvingUnrecoverableGap { return .fail }
        // A retry arriving while the repair is still in flight must wait, not fail: the fold count is
        // only cleared once the segment lands, so this is the ordinary case a second or two after the
        // re-anchor. If that pump folds the index again, the count reaches the cap and the next
        // request fails, which is the repeat we actually want to act on.
        return alreadyReanchoredHere ? .wait : .reanchor
    }

    /// Shared by mediaSegment(at:) and mediaSegmentURL(at:). Without sharing, back-scrubs served
    /// via sendfile (cache hits) skip the proactive restart entirely, leaving seg-11+ to fall into
    /// a reactive prune-gap restart with AVPlayer's buffer at its thinnest.
    private func handleTargetChange(to index: Int) {
        stateLock.lock()
        _mediaFetchCount += 1
        stateLock.unlock()
        let previousTarget = cache.targetIndex
        cache.declareTarget(index)

        // AE#418: AVPlayer places this segment at the position the PLAYLIST gives it, read through
        // the axis its timeline already carries (measured with `play --picture-probe`). So a segment
        // whose content starts below its advertised start moves the axis by that much, every time it
        // is placed. A re-request of the same index is a retry of one placement, not a second one.
        if Self.placesSegmentAnew(index: index, previousTarget: previousTarget) {
            segmentPlacedHandler?(index)
        }

        // #358: the consumer is asking for a plan index a pump folded away, because no keyframe
        // reached its boundary. The playlist offers it regardless, so waiting here is waiting for
        // something nobody will produce: the request rides out the slow threshold, the server closes
        // for a retry, and the session freezes with the engine still reporting playing. A rebase can
        // open the index, because the boundaries move with the producer's base, so the first fold
        // asks for exactly that. A second fold is that repair reproducing its own trigger, and then
        // the source has no way past this point.
        if !isLive, cache.peekURL(index: index) == nil {
            let folds = cache.foldCount(index)
            switch VideoSegmentProvider.foldedTargetDecision(
                folds: folds, alreadyReanchoredHere: lastRestartIndex == index
            ) {
            case .wait:
                break
            case .fail:
                EngineLog.emit(
                    "[VideoSegmentProvider] #358 seg\(index) folded by \(folds) pumps and requested again; "
                    + "no re-anchor can open it, failing the source",
                    category: .session
                )
                unrecoverableGapHandler?(index)
                return
            case .reanchor:
                guard let restart = restartHandler else { break }
                EngineLog.emit(
                    "[VideoSegmentProvider] #358 seg\(index) was folded away by the cutter; "
                    + "re-anchoring the producer there so its boundary can open",
                    category: .session
                )
                lastRestartIndex = index
                restart(index)
                cache.resetHighWaterForRestart()
                return
            }
        }

        if previousTarget >= 0, index < previousTarget - 2, let restart = restartHandler {
            // Cache gate: backwardWindow=20 covers Continuous-Audio handover refetches (~7-10 segments
            // backward); unconditional proactive restart re-armed the FLAC bridge and caused audible glitches.
            if cache.peekURL(index: index) != nil {
                let frontier = cache.contiguousForwardFrontier(from: index)
                let front = activeMarchFront
                if Self.residentBackwardTargetKeepsProducer(
                    index: index, residentFrontier: frontier, activeMarchFront: front,
                    prefetchDepth: Self.forwardWaitWindow
                ) {
                    EngineLog.emit(
                        "[HLSVideoEngine] declareTarget backward jump \(previousTarget) -> \(index): "
                        + "resident through seg\(frontier) (march front \(front)), no restart",
                        category: .session
                    )
                    return
                }
                EngineLog.emit(
                    "[HLSVideoEngine] declareTarget backward jump \(previousTarget) -> \(index): resident "
                    + "only through seg\(frontier), which is below the march front \(front), so the band "
                    + "ends in a gap nothing is producing",
                    category: .session
                )
            }
            EngineLog.emit(
                "[HLSVideoEngine] declareTarget backward jump \(previousTarget) → \(index), proactively restarting producer",
                category: .session
            )
            lastRestartIndex = index
            restart(index)
            cache.resetHighWaterForRestart()
        }
    }

    func mediaSegment(at index: Int) -> Data? {
        mediaSegment(at: index, onSlow: nil)
    }

    /// #93 round 3: VOD serves arm a one-shot slow signal so the server can emit an early chunked
    /// header once the serve outlives the threshold (a restart-window segment can take 25-50 s;
    /// AVPlayer -12889s at ~3.5 s of silence and three strikes kill the item). Live keeps its own
    /// contracts (below-window fast 404, LL-HLS blocking reload) and never signals.
    func mediaSegment(at index: Int, onSlow: (@Sendable () -> Void)?) -> Data? {
        guard let onSlow, !isLive else { return serveSegment(at: index) }
        let signal = SlowServeSignal(thresholdSeconds: slowServeThresholdSeconds, onSlow: onSlow)
        defer { signal.complete() }
        return serveSegment(at: index)
    }

    private func serveSegment(at index: Int) -> Data? {
        guard index >= 0, index < currentSegmentCount else { return nil }

        // Segment below the live window is evicted; returning nil = fast 404 so AVPlayer resyncs.
        // Without this, the 30 s cache.fetch parks the connection for a segment that will never reappear.
        if isLive {
            stateLock.lock()
            let firstVisible = _liveFirstVisible
            stateLock.unlock()
            if index < firstVisible {
                EngineLog.emit(
                    "[HLSVideoEngine] seg\(index): below live window (firstVisible=\(firstVisible)), fast 404",
                    category: .session
                )
                return nil
            }
        }

        let totalStart = DispatchTime.now()

        handleTargetChange(to: index)

        // Fast path: serve from cache.
        if let hit = cache.peek(index: index) {
            return logServed(index: index, bytes: hit, totalStart: totalStart, restarted: false)
        }

        // staleBelowProducer: indexRange() can still report stale lower bounds from a previous producer
        // (cold-start probe wrote seg-0/1 before resume restart at baseIndex=N); tolerance of 2 matches
        // the empty-cache cold-start heuristic.
        //
        // producerPassedAndPruned: highWater alone is not enough -- during normal forward-march the producer
        // races ahead while segments are still resident (repro: cache=0..24 highWater=24, request seg15 ->
        // needless restart). Only treat as a pruned gap when index falls OUTSIDE [r.0, r.1].
        // Concrete pruned-gap repro: 110-seg episode, jumped 8->12, back-scrubbed to 0, played 0..10 from cache,
        // seg-11..24 pruned; requested seg-11, waited 30 s, 404 because producer was past seg-24.
        let range = cache.indexRange()
        let highWater = cache.highestStoredIndex
        let staleBelowProducer = index < lastRestartIndex - 2
        let producerPassedAndPruned: Bool
        if highWater > index, let r = range {
            producerPassedAndPruned = index < r.0 || index > r.1
        } else {
            producerPassedAndPruned = highWater > index
        }
        let needsRestart: Bool
        // AE#169 round 2: set when the forward-wait branch has PROOF the active march is never
        // arriving (pump finished, or a full backpressure wait elapsed with zero front progress
        // for this same index). Bypasses the restart loop's producerCovers veto below, which
        // otherwise reads the dead producer's still-installed base and suppresses the fire.
        var marchProvenDead = false
        // AE#169 round 2: true when the fetch takes the VOD forward-window backpressure wait, so a
        // full-timeout miss records (index, front) for the frozen-march escalation above.
        var tookForwardWait = false
        if staleBelowProducer || producerPassedAndPruned {
            needsRestart = true
        } else if let r = range {
            if index < r.0 {
                needsRestart = true
            } else if index > r.1 + Self.forwardWaitWindow {
                needsRestart = true
            } else if index >= r.0 && index <= r.1 {
                // min...max is not proof of residency: retained scrub bands leave interior holes.
                // Only wait when the active producer can actually march into this index.
                if activeProducerCovers(index),
                   let waited = cache.fetch(index: index, timeout: sparseHoleWaitSlice) {
                    return logServed(
                        index: index, bytes: waited, totalStart: totalStart, restarted: false)
                }
                needsRestart = true
            } else {
                // r.1 < index <= r.1 + forwardWaitWindow: only backpressure-wait when the ACTIVE
                // producer's march front is actually near. The resident max alone is not that
                // signal: retained scrub bands (#93 budget) from a dead producer can sit far above
                // the active march (AE#141: band 150-158 from a 600 s scrub, producer re-anchored
                // at 75; the request for seg159 parked 3x30 s into -1017 item death while the
                // march was ~2 minutes away). highWater is reset per provider-fired restart, so
                // max(highWater, lastRestartIndex) tracks the active producer's front.
                //
                // AE#169 round 2: index distance alone is still not proof the march will ARRIVE.
                // A producer that died mid-session (source read error at the tail) freezes the
                // front just below the request, and the 30 s wait re-armed forever (seg719 miss
                // x11 into -12889). A finished pump, or a full wait already burned with zero
                // front progress for this same index, escalates to restart instead. VOD only:
                // live has its own pump watchdogs and reopen machinery.
                let front = activeMarchFront
                tookForwardWait = !isLive
                if !isLive {
                    stateLock.lock()
                    let missIndex = _forwardMissIndex
                    let missFront = _forwardMissFront
                    stateLock.unlock()
                    marchProvenDead = Self.forwardWaitMarchDead(
                        index: index, marchFront: front,
                        producerFinished: producerFinished?() ?? false,
                        lastMissIndex: missIndex, lastMissFront: missFront)
                    if marchProvenDead {
                        EngineLog.emit(
                            "[HLSVideoEngine] seg\(index): #169 forward-wait march dead "
                            + "(front=\(front) "
                            + (producerFinished?() ?? false
                                ? "producer finished" : "frozen across a full wait")
                            + "); escalating to restart",
                            category: .session
                        )
                    }
                }
                needsRestart = index > front + Self.forwardWaitWindow || marchProvenDead
            }
        } else {
            // Empty cache: cold start (producer at lastRestartIndex, hasn't written yet) vs. big scrub
            // (producer far from index, won't backfill). index > 2 heuristic missed the repro where
            // producer was at idx 1314 and AVPlayer requested seg-0 after a back-scrub (30 s timeout).
            needsRestart = abs(index - lastRestartIndex) > 2
        }

        if needsRestart, let restart = restartHandler {
            // #50: re-fire restart per slice only when lastRestartIndex changed (orphan: #35 coalescer
            // slot overwritten by newer scrub; producer settles elsewhere; plain 30 s wait 404s).
            // #93 residual: while a restart is in flight, the fetch RIDES it (slices don't consume
            // the fixed budget, bounded by repositionRideCapSeconds) and never fires its own,
            // possibly stale, index into the coalescer's pending slot. The fixed budget applies
            // only while no restart is executing.
            let rideDeadline = DispatchTime.now() + repositionRideCapSeconds
            var attempt = 0
            var firedThisCall = false
            while attempt < Self.repositionMaxWaits {
                if restartActivity?() == true {
                    if DispatchTime.now() > rideDeadline {
                        break
                    }
                } else {
                    // #93 residual: a fetch whose index was JUST restarted to (lastRestartIndex ==
                    // index) waits for the producer to deliver instead of re-firing; each AVPlayer
                    // re-request otherwise tore down the fresh producer mid-capture (device: three
                    // back-to-back restarts at the same index, one dropped frame each). The #50
                    // same-index orphan (producer settled elsewhere) is covered by one backstop
                    // re-fire on the final attempt. An index the ACTIVE producer demonstrably
                    // covers (base <= index <= base + forward window) never fires OR backstops:
                    // the march will deliver it, and the backstop killed a 75%-complete capture
                    // on device while a forward-march neighbor got its healthy producer restarted.
                    // AE#169 round 2: a march proven dead (finished pump / frozen front across a
                    // full wait) must not veto the fire; the still-installed dead producer's base
                    // covering the index is exactly the wedge being escaped.
                    let producerCovers = !marchProvenDead && activeProducerCovers(index)
                    // A request superseded by a NEWER declared target is an orphan of a skip
                    // storm: AVPlayer's newest request is what it actually wants (the same
                    // newest-wins semantics the coalescer applies to immediate restarts).
                    // Firing the orphan's index tears down the producer serving the REAL
                    // playhead (device: a stale seg262 fire evicted the settled base-252
                    // producer, restarts ping-ponged between stale and playhead indices,
                    // every capture was discarded and the playhead segment took 19.8 s).
                    // Orphans wait out their slices and 503; AVPlayer has abandoned them.
                    let isLatestTarget = cache.targetIndex == index
                    let orphanBackstop = attempt == Self.repositionMaxWaits - 1
                        && !firedThisCall && !producerCovers && isLatestTarget
                    if isLatestTarget
                        && ((lastRestartIndex != index && !producerCovers) || orphanBackstop) {
                        EngineLog.emit(
                            "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty") highWater=\(highWater) attempt=\(attempt + 1)/\(Self.repositionMaxWaits)), restarting producer",
                            category: .session
                        )
                        lastRestartIndex = index
                        clearForwardWaitMiss()
                        restart(index)
                        // Reset highWater AFTER restart() returns (synchronous: old producer has exited).
                        // Pre-restart reset would be clobbered by the old producer's final write re-bumping
                        // highWater, re-arming producerPassedAndPruned and cascading into per-segment restarts.
                        cache.resetHighWaterForRestart()
                        firedThisCall = true
                    }
                    attempt += 1
                }
                if let bytes = cache.fetch(index: index, timeout: repositionWaitSlice) {
                    return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: true)
                }
            }
            return logServed(index: index, bytes: nil, totalStart: totalStart, restarted: true)
        }

        let bytes = cache.fetch(index: index, timeout: forwardBackpressureWaitSeconds)
        if tookForwardWait, !needsRestart {
            if bytes == nil {
                // Record the front as of the END of the burned wait: progress DURING the wait
                // resets the comparison base, so only a truly frozen march escalates next time.
                recordForwardWaitMiss(index: index, front: activeMarchFront)
            } else {
                clearForwardWaitMiss()
            }
        }
        return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: needsRestart)
    }

    /// AE#169 round 2 pure decision: whether the forward-window backpressure wait may still trust
    /// the active march to deliver `index`. A FINISHED pump can never march. A recorded full-wait
    /// miss for the same index with an unmoved front means the wait already failed empirically and
    /// re-arming it would park forever (rrgomes: seg719 miss x11 into -12889). Everything else
    /// keeps the wait: slow sources legitimately take most of the patience window for one segment.
    static func forwardWaitMarchDead(index: Int, marchFront: Int, producerFinished: Bool,
                                     lastMissIndex: Int, lastMissFront: Int) -> Bool {
        if producerFinished { return true }
        return lastMissIndex == index && lastMissFront == marchFront
    }

    private func recordForwardWaitMiss(index: Int, front: Int) {
        stateLock.lock()
        _forwardMissIndex = index
        _forwardMissFront = front
        stateLock.unlock()
    }

    private func clearForwardWaitMiss() {
        stateLock.lock()
        _forwardMissIndex = .min
        _forwardMissFront = .min
        stateLock.unlock()
    }

    private func logServed(index: Int, bytes: Data?, totalStart: DispatchTime, restarted: Bool) -> Data? {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - totalStart.uptimeNanoseconds) / 1_000_000
        if let bytes = bytes {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): served \(bytes.count) B (wait=\(String(format: "%.1f", elapsedMs))ms cache=\(cache.count) restarted=\(restarted))",
                category: .session
            )
        } else {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): cache miss after \(String(format: "%.0f", elapsedMs))ms (cache=\(cache.count) restarted=\(restarted))",
                category: .session
            )
        }
        return bytes
    }

    /// AE#408 pure decision: a backward target jump landed on a segment that is still resident. May the
    /// producer stay anchored where it is?
    ///
    /// The residency gate exists for the Continuous-Audio handover refetch (~7-10 segments backward into
    /// content the ACTIVE pump is still writing): restarting there re-arms the FLAC bridge and glitches
    /// the audio. Residency of the target segment alone does not carry that, because a scrub band left by
    /// an EARLIER pump is resident too, and it ends. Nothing else aims the producer at the new target, so
    /// the band running out is what finally does it: the consumer asks for the first index above it, the
    /// out-of-range restart fires, and the whole re-anchor is paid at the one moment the buffer is empty.
    /// Measured on the `aetherctl play` repro (backward seek to seg38 into a 3-segment band, pump anchored
    /// at seg99): the ask for seg41 arrived 4 s later with 5 s of buffer left. With a longer band the pump
    /// instead sat parked for 24 s until the #65 backpressure wedge breaker moved it.
    ///
    /// Two shapes still keep the producer:
    ///
    /// - The resident run reaches the active march front. There is no gap to fall into: the band carries
    ///   the consumer straight back into the pump's own output. This is the handover case.
    /// - The run is at least a prefetch window deep. AVPlayer asks for a segment 5-7 ahead of what it is
    ///   playing, so the existing out-of-range restart runs with a full cushion, and re-anchoring early
    ///   would re-produce content that is already on disk.
    static func residentBackwardTargetKeepsProducer(
        index: Int, residentFrontier: Int, activeMarchFront: Int, prefetchDepth: Int
    ) -> Bool {
        if residentFrontier >= activeMarchFront { return true }
        return residentFrontier - index >= prefetchDepth
    }

    private func activeProducerCovers(_ index: Int) -> Bool {
        guard let base = activeProducerBase?() else { return false }
        return base <= index && index - base <= Self.forwardWaitWindow
    }

    /// The active producer's write front: the highest index written since its restart (highWater
    /// is reset per provider-fired restart) or its restart anchor before the first write (AE#141).
    private var activeMarchFront: Int {
        max(cache.highestStoredIndex, lastRestartIndex)
    }

    /// AE#141: whether the active producer's march can plausibly deliver `index` without a
    /// re-anchor: at or behind its anchor-to-front span, or within the forward-wait window
    /// ahead of the front. The engine's seek-deadline backstop asks this before preserving a
    /// "progressing" producer whose march would never reach the pending seek target.
    func activeMarchCovers(_ index: Int) -> Bool {
        index >= lastRestartIndex && index <= activeMarchFront + Self.forwardWaitWindow
    }

    private var currentSegmentCount: Int {
        guard isLive else { return segments.count }
        stateLock.lock()
        defer { stateLock.unlock() }
        return segments.count
    }

    var segmentCount: Int { currentSegmentCount }

    func segmentDuration(at index: Int) -> Double {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard index >= 0, index < segments.count else { return 0 }
            return segments[index].durationSeconds
        }
        if sequentialAppendPlaylist {
            stateLock.lock()
            defer { stateLock.unlock() }
            if index >= 0, index < _seqDurations.count { return _seqDurations[index] }
            // Not yet finalized (restart-mapping callers only; the playlist never shows these).
            guard index >= 0, index < segments.count else { return 0 }
            return segments[index].durationSeconds
        }
        guard index >= 0, index < segments.count else { return 0 }
        return segments[index].durationSeconds
    }

    /// #95 audio tap: index of the segment containing playlist-axis time `t` (cumulative EXTINF).
    /// Clamps below 0 and past the end.
    static func segmentIndex(forPlaylistTime t: Double, durations: [Double]) -> Int {
        guard !durations.isEmpty, t > 0 else { return 0 }
        var acc = 0.0
        for (i, d) in durations.enumerated() {
            acc += d
            if t < acc { return i }
        }
        return durations.count - 1
    }

    func segmentIndex(forPlaylistTime t: Double) -> Int {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            return Self.segmentIndex(forPlaylistTime: t, durations: segments.map { $0.durationSeconds })
        }
        return Self.segmentIndex(forPlaylistTime: t, durations: segments.map { $0.durationSeconds })
    }

    func segmentIsDiscontinuous(at index: Int) -> Bool {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard index >= 0, index < segments.count else { return false }
            return segments[index].discontinuous
        }
        guard index >= 0, index < segments.count else { return false }
        return segments[index].discontinuous
    }

    /// EVENT was tried (halved RSS growth 3.0->1.3 MB/s but did not bound it; AVPlayer retains ~93%
    /// regardless of playlist type); side effects: Control Center showed "LIVE" (asset.duration NaN),
    /// replay-from-beginning landed ~2 min in. .live is the only spec-correct shape for a sliding window
    /// (EVENT forbids segment removal; VOD stops playback). VOD stays .vod.
    var playlistType: HLSPlaylistType {
        if isLive { return .live }
        // Sequential archives grow append-only with real durations and never remove segments -
        // exactly EVENT's contract; the completed playlist (ENDLIST) renders as plain VOD.
        return sequentialAppendPlaylist ? .event : .vod
    }
    /// Stable TARGETDURATION from the first manifest; avoids -12888 startup race for high-bitrate live.
    var liveTargetSegmentDuration: Double? {
        isLive ? liveWindowSizing.targetSegmentDurationSeconds : nil
    }
    var liveBlockingReloadEnabled: Bool {
        Self.resolveLiveBlockingReload(halted: liveProductionHalted,
                                       deliveryStalled: liveDeliveryStalled,
                                       override: blockingReloadOverride,
                                       policy: liveCadencePolicy)
    }

    /// AE#446: has the source stopped delivering on its own cadence?
    ///
    /// A blocking reload that can never be satisfied is worse than no blocking reload at all. AVPlayer
    /// issues no segment requests while one is outstanding (measured: a separate, idle connection sat
    /// there the whole time), so the hold starves a client whose cache already holds every second in
    /// front of it. `liveProductionHalted` catches this eventually, but only once the no-cut watchdog
    /// has run, and the stall starts long before that.
    ///
    /// The threshold is 1.5 x TARGETDURATION because that is AVPlayer's own patience for an unchanged
    /// live playlist (-12888): past it the client already considers the source late, so holding its
    /// next poll can only cost it something. Latched, because a source that has missed its cadence once
    /// is exactly the "cannot honor the contract" category the static switch exists for (#167), and
    /// letting the advertisement return would flap CAN-BLOCK-RELOAD across every recovery.
    var liveDeliveryStalled: Bool {
        stateLock.lock()
        if _liveDeliveryStalledLatched {
            stateLock.unlock()
            return true
        }
        guard isLive, let last = _lastLiveSegmentFinalizedAt,
              let targetDuration = liveTargetDurationSeal.value else {
            stateLock.unlock()
            return false
        }
        let since = Date().timeIntervalSince(last)
        guard since > 1.5 * Double(targetDuration) else {
            stateLock.unlock()
            return false
        }
        _liveDeliveryStalledLatched = true
        stateLock.unlock()
        EngineLog.emit(
            "[HLSVideoEngine] #446 source stopped delivering (no segment finalized for "
            + "\(String(format: "%.1f", since))s, TARGETDURATION \(targetDuration)s); withdrawing "
            + "CAN-BLOCK-RELOAD so a held poll cannot starve a client the cache could still feed",
            category: .session
        )
        return true
    }

    /// AE#446 round 2: serve the remaining window as a finished asset while the source is not delivering.
    ///
    /// A live playlist whose tail stops moving stops being fetched, and the segments it still lists go
    /// with it. Measured on the harness, a viewer 147 s inside the window with the source frozen: six
    /// more segments arrive at playback rate, AVPlayer draws `-12888 Playlist File unchanged` on every
    /// reload, and after the sixth it stops polling AND stops requesting, with 115 s of its own runway
    /// resident on disk. Then, when the playlist finally moves again, it rejoins at
    /// edge-minus-HOLD-BACK by itself and the position is gone (measured forward step 117.76 s), which
    /// is a second way to lose a place that no reload policy of ours can cover.
    ///
    /// Two cheaper answers were built and measured and neither moves it, so neither is worth trying again:
    /// - `EXT-X-SODALITE-REFRESH` makes every response byte-distinct (verified live: two polls 4 s apart
    ///   differ in that line alone) and AVPlayer still calls the playlist unchanged. Its test reads the
    ///   parsed playlist, so a tag it does not know cannot count.
    /// - Sliding the window forward on the clock, so `EXT-X-MEDIA-SEQUENCE` advances one segment per
    ///   TARGETDURATION, does not reset that clock either: same `-12888` cadence, same strike-out at the
    ///   same second, and it spends the viewer's rewind depth to buy nothing. What AVPlayer watches is
    ///   the TAIL of the playlist, not its identity.
    ///
    /// So the window is served as what it actually is while the source is down: a finite asset. Latched,
    /// because a playlist that has carried ENDLIST can never take it back.
    ///
    /// Not for a viewer at the edge: with nothing resident ahead, ENDLIST would only convert a stall into
    /// an end. The gate is the consumer's own fetch point.
    var liveOutageEndlist: Bool {
        let consumerTarget = cache.targetIndex
        stateLock.lock()
        if _liveOutageEndlistLatched {
            stateLock.unlock()
            return true
        }
        let total = segments.count
        let stale = sourceIsLateLocked()
        stateLock.unlock()
        guard isLive, consumerTarget >= 0, consumerTarget + 1 < total, stale else { return false }
        stateLock.lock()
        _liveOutageEndlistLatched = true
        stateLock.unlock()
        EngineLog.emit(
            "[VideoSegmentProvider] #446 the source stopped delivering with the consumer at "
            + "\(consumerTarget) of \(total); serving the rest of the window as a finished asset "
            + "(ENDLIST) so AVPlayer keeps fetching the runway it already holds instead of striking "
            + "out on an unchanged playlist",
            category: .session
        )
        return true
    }

    /// AE#446 round 2: has the window already been closed? A pure read, unlike `liveOutageEndlist`,
    /// which decides and latches. Anything outside the playlist build wants this one.
    var liveOutageEndlistLatched: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveOutageEndlistLatched
    }

    /// AE#446 round 3: is a window closed by an outage still feeding its consumer?
    ///
    /// The consumer's own fetch point is the measure, the same one that decided to close the window:
    /// while segments remain above it, the session is still handing out pictures and the source read
    /// must not be abandoned under it. Once the consumer has walked to the end of what the window
    /// holds, nothing is being delivered any more and the starvation exit is the honest answer again.
    var outageRunwayAheadOfConsumer: Bool {
        let consumerTarget = cache.targetIndex
        stateLock.lock()
        let latched = _liveOutageEndlistLatched
        let total = segments.count
        stateLock.unlock()
        return latched && consumerTarget >= 0 && consumerTarget + 1 < total
    }

    /// AE#446 round 2: is the source late by its own advertised cadence? Read FRESH rather than through
    /// `liveDeliveryStalled`, which latches for the lifetime of the session on purpose (#167: a
    /// returning CAN-BLOCK-RELOAD would flap). A window closed by an outage has to be able to re-open,
    /// so the condition that closes it has to be able to become false again. Call under stateLock.
    private func sourceIsLateLocked() -> Bool {
        guard let last = _lastLiveSegmentFinalizedAt, let td = liveTargetDurationSeal.value,
              td > 0 else { return false }
        return Date().timeIntervalSince(last) > 1.5 * Double(td)
    }

    /// AE#446 round 2: the source is delivering again, so the session can go back to being live. Only
    /// an item swap can act on it: an item that has seen ENDLIST never reloads its playlist again,
    /// which is exactly why the swap is required.
    ///
    /// Deliberately the exact complement of what closed the window, rather than "one more segment than
    /// there was". A dying source cuts a last partial segment on its way out (the no-cut watchdog's
    /// final flush is one), and counting that as a recovery swaps the item into a window that is still
    /// closed, where a live rejoin has no edge to aim at and starts the viewer at the beginning of it.
    /// Measured doing exactly that: a rejoin 180 s below the place it was supposed to hold.
    var liveOutageProductionResumed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveOutageEndlistLatched && !sourceIsLateLocked()
    }

    /// AE#446 round 2: re-open the window as live, for a FRESH item only. Safe because the item that
    /// saw the ENDLIST has stopped polling, so it cannot observe the tag being withdrawn.
    func clearLiveOutageEndlist() {
        stateLock.lock()
        let wasLatched = _liveOutageEndlistLatched
        _liveOutageEndlistLatched = false
        stateLock.unlock()
        guard wasLatched else { return }
        EngineLog.emit(
            "[VideoSegmentProvider] #446 the source is cutting again; the window is live once more "
            + "for the next item",
            category: .session
        )
    }

    /// AE#454: tell the next item where to start, in the playlist it will load.
    ///
    /// A rejoin is two operations, attaching an item and placing it, and only the first used to be
    /// expressed to AVPlayer at the swap. So the fresh item did what a live playlist tells any client
    /// to do, joined at the edge, started playing there, and got the place it held ~150 ms later as a
    /// seek. The playlist is ours, and HLS has a tag for this question, so the placement belongs in
    /// the manifest rather than in a correction after the fact.
    ///
    /// Returns the resolved position, or nil when `seconds` names nothing this producer holds (an
    /// evicted target), in which case the caller keeps the edge join it would have had.
    @discardableResult
    func armLiveRejoinStart(atOutputSeconds seconds: Double) -> (segmentIndex: Int, secondsIntoSegment: Double)? {
        stateLock.lock()
        let segs = segments
        stateLock.unlock()
        guard let idx = Self.thumbnailSegmentIndex(atSeconds: seconds, segments: segs) else { return nil }
        let into = Swift.max(0, seconds - segs[idx].startSeconds)
        stateLock.lock()
        _liveRejoinStart = (idx, into)
        stateLock.unlock()
        return (idx, into)
    }

    /// AE#454: the placement is spent once the item that asked for it is running. Left armed, the next
    /// item to load for any other reason would inherit a position it never asked about.
    func clearLiveRejoinStart() {
        stateLock.lock()
        _liveRejoinStart = nil
        stateLock.unlock()
    }

    var liveRejoinStart: (segmentIndex: Int, secondsIntoSegment: Double)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveRejoinStart
    }

    /// Blocking-reload hold bound: 3 x sealed TARGETDURATION (= the advertised HOLD-BACK depth).
    /// The old hardcoded 18 s was 9 x TD under fastZap. A hold that outlives AVPlayer's ~4 s
    /// forward buffer guarantees the stall it exists to prevent. The seal is always resolved before
    /// the first playlist that can advertise CAN-BLOCK-RELOAD is served (every serve path runs
    /// waitForFirstLiveSegment first), so the TD=6 fallback (3 x 6 = legacy 18 s) only covers tests.
    var liveBlockingReloadHoldSeconds: TimeInterval {
        stateLock.lock()
        let sealed = liveTargetDurationSeal.value
        stateLock.unlock()
        return Double(3 * (sealed ?? 6))
    }

    /// AE#442: the TARGETDURATION the live playlist is actually serving, once sealed. nil before the
    /// first playlist build, which is also the only window in which nothing can be parked behind live.
    var sealedLiveTargetDurationSeconds: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return liveTargetDurationSeal.value
    }

    var liveProductionHalted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveProductionHalted
    }

    /// Live pump exited for host retune: no further segment will ever be cut into this provider.
    /// Latch blocking-reload off for every subsequent manifest render (including an item reload
    /// against this server) and release parked ?_HLS_msn= waiters so they 503 now instead of
    /// sleeping out their full hold against a dead producer (-15410, #167 follow-up).
    func markLiveProductionHalted() {
        stateLock.lock()
        _liveProductionHalted = true
        stateLock.unlock()
        cancelWaiters()
    }
    var liveTargetDurationFloorSeconds: Double? {
        // The floor tracks observed cadence regardless of the gate override: patience must cover the real
        // inter-batch gap even when a host forces blocking-reload on/off (#167).
        isLive ? liveCadencePolicy?.targetDurationFloorSeconds : nil
    }

    func currentLiveTargetDuration(
        maxSegmentDuration: Double
    ) -> LiveTargetDurationDerivation {
        let cutTarget = liveWindowSizing.targetSegmentDurationSeconds
        // Which of the two absences this is decides what the seal line may claim: no policy means no
        // meter for the life of the session, not a measurement still to come (AE#447 round 3).
        let floor: CadenceFloorTerm = liveCadencePolicy.map { policy in
            policy.targetDurationFloorSeconds.map { CadenceFloorTerm.measured($0) } ?? .pending
        } ?? .unmeasurable
        return LiveTargetDurationDerivation(
            value: LiveEdgePolicy.targetDurationSeconds(
                maxSegmentDuration: maxSegmentDuration,
                cutTargetSeconds: cutTarget,
                cadenceFloorSeconds: floor.seconds
            ),
            maxSegmentDuration: maxSegmentDuration,
            cutTargetFloor: cutTarget,
            cadenceFloor: floor,
            selfReported: liveCadencePolicy?.selfReportedTargetDurationSeconds
        )
    }

    /// Takes the seal and, on the call that actually takes it, publishes the derivation. The value is
    /// frozen for the session (RFC 8216 forbids a changing TARGETDURATION, AE#209), so the one line that
    /// explains it has to be emitted here or nowhere: a host reading a 9 s holdback later has no way to
    /// tell a measured cadence from an inherited advert (AE#447).
    private func sealLiveTargetDuration(_ derivation: LiveTargetDurationDerivation) -> Int {
        stateLock.lock()
        let resolved = liveTargetDurationSeal.resolve(candidate: derivation.value)
        stateLock.unlock()
        if resolved.didSeal {
            EngineLog.emit("[HLSVideoEngine] \(derivation.account)", category: .session)
        }
        return resolved.value
    }

    func liveTargetDurationSeconds(maxSegmentDuration: Double) -> Int {
        let candidate = currentLiveTargetDuration(maxSegmentDuration: maxSegmentDuration)
        stateLock.lock()
        let resolved = liveTargetDurationSeal.resolve(candidate: candidate.value)
        stateLock.unlock()
        if resolved.didSeal {
            EngineLog.emit("[HLSVideoEngine] \(candidate.account)", category: .session)
        }

        if resolved.shouldLogDrift {
            EngineLog.emit(
                "[HLSVideoEngine] live TARGETDURATION remains sealed at "
                + "\(resolved.value)s, later candidate \(candidate.value)s "
                + "(max segment \(String(format: "%.3f", maxSegmentDuration))s, "
                + candidate.cadenceFloor.account
                + ")",
                category: .session
            )
        }
        return resolved.value
    }

    /// Resolve blocking-reload eligibility: a halted producer disables it unconditionally (no override
    /// can conjure segments from a dead pump, #167 follow-up); otherwise a host override wins; otherwise
    /// the observed-cadence policy decides for ingest sources; signal-less live (plain-url Jellyfin
    /// transcode) keeps the low-latency default. Pure so the precedence is unit-testable without a full
    /// provider (#167).
    static func resolveLiveBlockingReload(halted: Bool = false, deliveryStalled: Bool = false,
                                          override: Bool?, policy: LiveCadencePolicy?) -> Bool {
        // Both outrank an explicit override: a source that is not delivering cannot honor the contract
        // however loudly the host asks for it.
        if halted || deliveryStalled { return false }
        if let override { return override }
        if let policy { return policy.blockingReloadEnabled }
        return true
    }
    /// Under stateLock: (count, summed EXTINF, max EXTINF) over the resident segments. At startup the
    /// window has not slid yet, so this is the full first-served window (LiveEdgePolicy sizes the cushion).
    private func liveCushionSnapshot() -> (count: Int, summed: Double, maxDuration: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var summed = 0.0
        var maxDuration = 0.0
        for seg in segments {
            summed += seg.durationSeconds
            maxDuration = max(maxDuration, seg.durationSeconds)
        }
        return (segments.count, summed, maxDuration)
    }

    /// Block until the first live window holds the live-edge holdback (3 x TARGETDURATION) of content, so
    /// AVPlayer's initial seek to edge-minus-holdback lands inside the window instead of its stall-danger
    /// zone (-16832; AE#189). A `.fastZap` session may take the explicitly bounded shallow-window path
    /// after two segments and one clamped segment-duration grace (AE#208). `.standard` never takes it.
    /// Both paths avoid -12888 on an empty or single-segment playlist. The gate and served playlist use
    /// the same sealed TARGETDURATION.
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool {
        guard isLive else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        // AE#374: monotonic, because this interval is a measurement and a wall-clock jump would corrupt
        // it. The deadline above stays on `Date` because `NSCondition.wait(until:)` takes one.
        let enteredAt = DispatchTime.now()
        let window = liveWindowSizing.windowSegmentCount
        var degradedDeadline: Date?
        var degradedGrace: TimeInterval?
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            if waitersCancelled { return false }
            let snap = liveCushionSnapshot()
            let target = currentLiveTargetDuration(maxSegmentDuration: snap.maxDuration)
            if LiveEdgePolicy.startupCushionSatisfied(segmentCount: snap.count,
                                                       summedDurationSeconds: snap.summed,
                                                       targetDuration: target.value,
                                                       windowSegmentCount: window) {
                let sealed = sealLiveTargetDuration(target)
                accountForFirstServe(since: enteredAt, snapshot: snap, targetDuration: sealed)
                return true
            }
            if allowsBoundedDegradedStart,
               snap.count >= LiveEdgePolicy.minStartupSegments,
               degradedDeadline == nil {
                let grace = LiveEdgePolicy.fastZapDegradedGraceSeconds(
                    maxSegmentDuration: snap.maxDuration
                )
                degradedGrace = grace
                degradedDeadline = Date().addingTimeInterval(grace)
            }
            let effectiveDeadline = degradedDeadline.map { min(deadline, $0) } ?? deadline
            if !firstSegmentCondition.wait(until: effectiveDeadline) {
                // Re-read after the timed-out wait: an append racing the deadline would otherwise be judged
                // on the stale snapshot (waitForLiveSegment below already does this).
                let after = liveCushionSnapshot()
                let afterTarget = currentLiveTargetDuration(maxSegmentDuration: after.maxDuration)
                if LiveEdgePolicy.startupCushionSatisfied(segmentCount: after.count,
                                                          summedDurationSeconds: after.summed,
                                                          targetDuration: afterTarget.value,
                                                          windowSegmentCount: window) {
                    let sealed = sealLiveTargetDuration(afterTarget)
                    accountForFirstServe(since: enteredAt, snapshot: after, targetDuration: sealed)
                    return true
                }
                if let degradedDeadline,
                   Date() >= degradedDeadline,
                   after.count >= LiveEdgePolicy.minStartupSegments {
                    let sealed = sealLiveTargetDuration(afterTarget)
                    // AE#374: the grace is the last leg of this wait, not the wait. Reporting it alone
                    // left a bounded start reading as a half-second one when it had held for twelve.
                    accountForFirstServe(
                        since: enteredAt, snapshot: after, targetDuration: sealed,
                        note: "fastZap bounded start after "
                            + "\(LiveEdgePolicy.seconds(degradedGrace ?? 0))s grace"
                    )
                    return true
                }
                guard Date() >= deadline else { continue }
                // Degraded start: serving before the holdback cushion is built (transcode too slow, or a
                // strict-realtime origin that has not produced 3 x TD of content within the deadline) makes
                // a -16832 "restarting from end of live playlist" stall right after startup likely. Observe it.
                guard after.count > 0 else {
                    // AE#374: nothing was ever cut, so there is no window to account for and no manifest
                    // worth serving. This exit used to return in silence, which from a host's side is the
                    // one outcome indistinguishable from a merely slow origin.
                    accountForUnservedFirstManifest(since: enteredAt)
                    return false
                }
                // The satisfied re-read above has already returned, so reaching the deadline here means the
                // cushion is undersized by definition.
                let sealed = sealLiveTargetDuration(afterTarget)
                accountForFirstServe(
                    since: enteredAt, snapshot: after, targetDuration: sealed, warning: true,
                    note: "\(Int(timeout))s timeout (undersized startup cushion)"
                )
                return true
            }
        }
    }

    /// AE#374: one account per live session, emitted at whichever exit ends the first-serve gate.
    ///
    /// Every `/media.m3u8` request without an `_HLS_msn` re-enters the gate, so without the latch a
    /// steady session would repeat the line at its refresh interval. Called with `firstSegmentCondition`
    /// held, which is what the latch is protected by.
    private func accountForFirstServe(
        since entered: DispatchTime,
        snapshot: (count: Int, summed: Double, maxDuration: Double),
        targetDuration: Int,
        warning: Bool = false,
        note: String? = nil
    ) {
        guard !didAccountForFirstServe else { return }
        didAccountForFirstServe = true
        let account = LiveEdgePolicy.firstServeAccount(
            waitedSeconds: Self.secondsSince(entered),
            segmentCount: snapshot.count,
            summedDurationSeconds: snapshot.summed,
            targetDuration: targetDuration
        )
        EngineLog.emit(
            "[HLSVideoEngine] \(warning ? "WARNING: " : "")\(account)"
            + (note.map { ", \($0)" } ?? ""),
            category: .session
        )
    }

    /// The gate's other ending: the deadline passed and not one segment was ever cut, so there is no
    /// window to describe and the manifest cannot be served at all.
    private func accountForUnservedFirstManifest(since entered: DispatchTime) {
        guard !didAccountForFirstServe else { return }
        didAccountForFirstServe = true
        EngineLog.emit(
            "[HLSVideoEngine] WARNING: first live manifest not served after "
            + "\(LiveEdgePolicy.seconds(Self.secondsSince(entered)))s: no segment was cut",
            category: .session
        )
    }

    private static func secondsSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }

    func cancelWaiters() {
        firstSegmentCondition.lock()
        waitersCancelled = true
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Next index + output-timeline end (seconds) for a live-reopen producer to resume from tfdt.
    func liveContinuationPoint() -> (nextIndex: Int, outputEndSeconds: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let next = segments.count
        let end = segments.last.map { $0.startSeconds + $0.durationSeconds } ?? 0
        return (next, end)
    }

    /// LL-HLS blocking reload: block until segment index exists or timeout. Returns actual existence on timeout.
    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool {
        guard isLive else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            if waitersCancelled { return false }
            stateLock.lock()
            let count = segments.count
            stateLock.unlock()
            if count > index { return true }
            // AE#446: wake in slices rather than parking for the whole bound. A source that stops
            // delivering mid-hold has to be noticed here too, or the poll that was already in flight
            // when it died still costs the client a full 3 x TARGETDURATION of not fetching anything.
            let slice = min(deadline, Date().addingTimeInterval(Self.liveHoldRecheckSeconds))
            if !firstSegmentCondition.wait(until: slice) {
                if Date() >= deadline {
                    stateLock.lock()
                    let final = segments.count
                    stateLock.unlock()
                    return final > index
                }
                if liveDeliveryStalled { return false }
            }
        }
    }

    /// AE#446: how often a blocking-reload hold re-asks whether the source is still alive.
    static let liveHoldRecheckSeconds: TimeInterval = 1.0
    var masterCodecs: String? { codecsString }
    var masterSupplementalCodecs: String? { supplementalCodecsString }
    var masterResolution: (width: Int, height: Int)? {
        return (resolution.0, resolution.1)
    }
    var masterVideoRange: HLSVideoRange? { videoRange }
    /// 25 Mbps fallback: under-declaring fires -12318 "Segment exceeds specified bandwidth" on every segment.
    var masterAverageBandwidth: Int? {
        sourceBitrate > 0 ? Int(sourceBitrate) : 25_000_000
    }

    /// 2x average as peak estimate (4K HDR action bursts to ~2x); 5 Mbps floor for corrupt-bitrate sources.
    var masterBandwidth: Int? {
        let avg = masterAverageBandwidth ?? 25_000_000
        return max(avg * 2, 5_000_000)
    }
    var masterFrameRate: Double? { frameRate }
    var masterHDCPLevel: String? { hdcpLevel }
    var masterClosedCaptions: String? { "NONE" }

    // MARK: - Native subtitle renditions (#15)

    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] {
        guard !nativeSubStores.isEmpty else { return [] }
        return nativeSubStores.indices.map { i in
            // Session-built infos carry deduped NAMEs + forced dispositions; the legacy per-ordinal
            // fallback stays for constructions that pass only languages (duplicate names collapse
            // AVFoundation's legible options, so real sessions should always pass infos).
            if i < nativeSubRenditionInfos.count {
                let info = nativeSubRenditionInfos[i]
                return (ordinal: i, language: info.language, name: info.name, isForced: info.isForced)
            }
            let lang = i < nativeSubLanguages.count ? nativeSubLanguages[i] : nil
            let name = lang.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? "Subtitle \(i + 1)"
            return (ordinal: i, language: lang, name: name, isForced: false)
        }
    }

    /// WebVTT for one subtitle segment: the cues overlapping video segment `segmentIndex`'s [start, end) on
    /// the AVPlayer timeline. `segments[i].startSeconds` is the absolute output-axis start (correct for both
    /// VOD and the live sliding window, where a cumulative EXTINF sum from firstVisible would not be), so the
    /// window is read straight off the segment plan rather than recomputed.
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? {
        guard ordinal >= 0, ordinal < nativeSubStores.count else { return nil }
        let store = nativeSubStores[ordinal]
        if nativeSubtitleWholeProgram {
            // Sodalite#32: serve the ENTIRE program's cues as one .vtt (the only AVPlayer-reliable sideload
            // shape). AVKit fetches this VOD single-segment file ONCE and never re-fetches it, so it MUST be
            // complete. Wait for the reader's definitive EOF signal (isFinished) rather than a cue-count plateau
            // heuristic, which fired early during dialogue gaps and served a truncated file (device-confirmed).
            let deadline = Date().addingTimeInterval(30.0)
            while !store.isFinished, Date() < deadline {
                usleep(100_000)
            }
            // Sodalite#32: the cues are stored at SOURCE pts; AVPlayer clock = source - shift. Apply the CURRENT
            // engine shift (read now, not the possibly-zero load-time value) so cues land on the video's axis.
            let shift = currentShiftSeconds()
            store.setShiftSeconds(shift)
            let cues = stripMarkupIfNeeded(store.allCues())
            EngineLog.emit("[HLSVideoEngine] whole-program subtitle .vtt ord=\(ordinal) cues=\(cues.count) finished=\(store.isFinished) shift=\(String(format: "%.2f", shift)) first=\(cues.first.map { String(format: "%.1f", $0.start) } ?? "-") last=\(cues.last.map { String(format: "%.1f", $0.end) } ?? "-")", category: .hlsServer)
            // PLAIN WebVTT, NO X-TIMESTAMP-MAP (matches the proven-working whole-file sideload). With the map,
            // AVKit anchors cues to the fMP4 sample PTS (which diverges from currentTime over our loopback) and
            // the subtitles render offset by the playback position; without it AVKit uses the cue times as the
            // AVPlayer timeline directly (= our absolute cue axis). Sodalite#32.
            return WebVTTBuilder.body(cues: cues)
        }
        stateLock.lock()
        guard segmentIndex >= 0, segmentIndex < segments.count else {
            stateLock.unlock()
            return nil
        }
        let start = segments[segmentIndex].startSeconds
        let end = start + segments[segmentIndex].durationSeconds
        stateLock.unlock()
        // Sodalite#32: bounded, distance-aware readiness wait replacing the 25 s wait-for-isFinished. AVKit
        // caches an empty-served window forever, so waiting is worth it; but blocking every fetch on a store
        // that never finishes serialized the loopback connection AVPlayer also uses for video (device:
        // scrubbing wedged while a rendition was selected). Wait only while the reader is plausibly about to
        // cover THIS window (read head within the horizon, or still warming up), and only briefly.
        let horizonSeconds = 30.0
        let deadline = Date().addingTimeInterval(3.0)
        while !store.isFinished,
              store.readMaxCueEnd() < end,
              end <= store.readMaxCueEnd() + horizonSeconds || store.readMaxCueEnd() <= 0,
              Date() < deadline {
            usleep(100_000)
        }
        let cues = stripMarkupIfNeeded(store.cuesInWindow(start: start, end: end))
        EngineLog.emit("[HLSVideoEngine] subtitle .vtt ord=\(ordinal) seg=\(segmentIndex) win=[\(String(format: "%.1f", start)),\(String(format: "%.1f", end))) inWin=\(cues.count) readMax=\(String(format: "%.1f", store.readMaxCueEnd()))", category: .hlsServer, level: .verbose)
        // Absolute media-timeline cue times + MPEGTS:0 identity map. Flip to segment-relative here (one line:
        // relativeToStart: true) if on-device PiP shows subtitles shifted by the segment start. See WebVTTBuilder.segment.
        return WebVTTBuilder.segment(cues: cues, segmentStart: start)
    }

    /// Sodalite#32 Phase 2: see `stripASSMarkupInVTT`.
    private func stripMarkupIfNeeded(
        _ cues: [(start: Double, end: Double, text: String)]
    ) -> [(start: Double, end: Double, text: String)] {
        guard stripASSMarkupInVTT else { return cues }
        return cues.compactMap { c in
            guard let plain = SubtitleRectText.plainText(fromASSEventLine: c.text) else { return nil }
            return (c.start, c.end, plain)
        }
    }
}
