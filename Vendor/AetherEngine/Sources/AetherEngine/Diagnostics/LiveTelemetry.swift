import Foundation

/// 1 Hz live playback telemetry snapshot. Nil fields are path-asymmetric:
/// observedFps=nil on native (AVPlayer has no usable live FPS counter);
/// avSyncGapMs=nil on SW (measured by HLSSegmentProducer which only runs on the native/HLS-loopback path);
/// forwardBufferSeconds=nil on SW: this remains the native player's loaded-range metric (#306).
/// Software VOD compressed packet read-ahead is reported through engine.bufferedPosition and
/// cachedBytes, separately from displayCushionSeconds and the byte-source reader window. Do not
/// interpret a sub-second decoded queue as the size of the compressed packet cache.
public struct LiveTelemetry: Equatable, Sendable {
    // Enthusiast section
    public let instantBitrateMbps: Double?
    /// Lifetime mean rate of the session, over the seconds it spent consuming media rather than over
    /// wall-clock seconds since it started (AE#514). A pause therefore leaves this value standing
    /// still instead of dragging it toward zero for as long as the pause lasts, and so does the tail
    /// after end-of-media. nil until the session has both accrued active time and fetched something:
    /// like `networkThroughputMbps`, a value that cannot be measured yet is a gap, never a zero.
    public let averageBitrateMbps: Double?
    /// Live bitrate of the audio bridge's encoded output, or nil when no bridge is active (stream-copy /
    /// AVPlayer-native path) or before the first delta. Measured from the bridge's cumulative output-byte
    /// counter, since the common FLAC bridge is lossless VBR and has no fixed configured rate.
    public let audioBridgeBitrateMbps: Double?
    public let observedFps: Double?
    /// Frames the display dropped **for the session**: AVPlayer's access log on the native path, the
    /// render synchronizer's own metrics on the software one (#306). Software sessions predating that
    /// read it as nil, as does an OS without `videoPerformanceMetrics`. Summed across access-log entries
    /// since AE#443; reading the newest entry alone made it fall back to 0 mid-session whenever
    /// AVFoundation opened a new one.
    public let droppedFrameCount: Int?
    public let forwardBufferSeconds: Double?
    /// #306: seconds of decoded video queued ahead of the clock on the software path, nil on native
    /// (where `forwardBufferSeconds` is the analog). Sub-second by design, and the first thing an IO
    /// hiccup eats into: this is a cushion, not a buffer.
    public let displayCushionSeconds: Double?
    /// #306: bytes the playback reader has fetched but the demuxer has not consumed yet, i.e. the
    /// runway that exists ahead of the read cursor. Both paths; nil for sources with no `AVIOReader`
    /// (disc, custom provider). Bytes rather than seconds on purpose: seconds would need a bitrate
    /// estimate baked in, and a host that wants one divides by `averageBitrateMbps` from this same
    /// snapshot. Not by `networkThroughputMbps`: that is the rate the link delivers at, so it answers
    /// how long the runway took to fetch, not how long it will last at playback rate.
    public let readerWindowAheadBytes: Int?
    /// #306: the display's accumulated late-frame delay on the software path, nil on native and before
    /// the first metrics read. Cumulative for the session, so a rate comes from differencing two ticks.
    public let accumulatedFrameDelaySeconds: Double?
    public let cachedBytes: Int64?
    /// Session-local compressed-packet cache counters. nil outside software VOD. A hit reuses
    /// retained packets without changing the source epoch; a miss requires a source reposition.
    public let softwareCacheSeekHits: UInt64?
    public let softwareCacheSeekMisses: UInt64?
    public let softwareCacheSourceEpoch: UInt64?
    /// The rate the source link delivers at while it is delivering, so it stays comparable between the
    /// two paths: `observedBitrate` from the access log on native, and on the software path the
    /// demuxer's own byte counter over the seconds bytes arrived in (#306 follow-up). Not a wall-clock
    /// mean: the reader fetches a large range and parks on backpressure until low water, so a healthy
    /// fast link is idle for most of a window and a mean over it would report 0.0 Mbps on a session
    /// that is playing perfectly. nil when nothing arrived in the window at all, which is the honest
    /// reading for "not measurable right now"; it is never zero to mean that.
    public let networkThroughputMbps: Double?
    /// Bytes the PLAYBACK CONSUMER pulled over its own link, for the whole session. The two paths do not
    /// measure the same link and cannot: on native this is what AVPlayer fetched from the engine's
    /// loopback server, on software it is the demuxer's pull from the source. `demuxerBytesFetched` is
    /// the source-side number on both, and is the one to read when the question is about the origin.
    ///
    /// AE#443: summed across access-log entries on the native path. AVFoundation opens a new entry when
    /// the playback session changes under it, so the previous `.last` read fell back to a partial total
    /// in the middle of a healthy session, which reads as evidence that something underneath was
    /// replaced. nil when the path cannot report it, never zero to mean that.
    public let networkTransferredBytes: Int64?
    public let avSyncGapMs: Double?

    // Engine diagnostics section
    /// Producer restarts in the session, across every producer it has had (AE#443: this used to read a
    /// 0/1 flag off the current instance). Structurally 0 on a live session: the live recoveries replace
    /// the producer rather than restart one, and they announce themselves in the log instead
    /// (`live reopen attempt`, `live producer rebuilt in place`).
    public let producerRestartCount: Int
    /// Fragment bytes the muxer emitted in the session, across muxer rotations and producer
    /// replacements. A leak baseline, so it has to outlive both (AE#443).
    public let muxedBytesLifetime: Int64
    public let serverBytesSentLifetime: Int64
    public let serverRequestCount: Int
    /// Bytes pulled from the SOURCE in the session, across every demuxer it has had. The origin-side
    /// counterpart to `networkTransferredBytes`, and the one that is about the same link on both paths.
    public let demuxerBytesFetched: Int64
    public let audioBridgeLiveBytes: Int
    public let rssMb: Int

    public init(
        instantBitrateMbps: Double?,
        averageBitrateMbps: Double?,
        audioBridgeBitrateMbps: Double?,
        observedFps: Double?,
        droppedFrameCount: Int?,
        forwardBufferSeconds: Double?,
        displayCushionSeconds: Double? = nil,
        readerWindowAheadBytes: Int? = nil,
        accumulatedFrameDelaySeconds: Double? = nil,
        cachedBytes: Int64?,
        softwareCacheSeekHits: UInt64? = nil,
        softwareCacheSeekMisses: UInt64? = nil,
        softwareCacheSourceEpoch: UInt64? = nil,
        networkThroughputMbps: Double?,
        networkTransferredBytes: Int64?,
        avSyncGapMs: Double?,
        producerRestartCount: Int,
        muxedBytesLifetime: Int64,
        serverBytesSentLifetime: Int64,
        serverRequestCount: Int,
        demuxerBytesFetched: Int64,
        audioBridgeLiveBytes: Int,
        rssMb: Int
    ) {
        self.instantBitrateMbps = instantBitrateMbps
        self.averageBitrateMbps = averageBitrateMbps
        self.audioBridgeBitrateMbps = audioBridgeBitrateMbps
        self.observedFps = observedFps
        self.droppedFrameCount = droppedFrameCount
        self.forwardBufferSeconds = forwardBufferSeconds
        self.displayCushionSeconds = displayCushionSeconds
        self.readerWindowAheadBytes = readerWindowAheadBytes
        self.accumulatedFrameDelaySeconds = accumulatedFrameDelaySeconds
        self.cachedBytes = cachedBytes
        self.softwareCacheSeekHits = softwareCacheSeekHits
        self.softwareCacheSeekMisses = softwareCacheSeekMisses
        self.softwareCacheSourceEpoch = softwareCacheSourceEpoch
        self.networkThroughputMbps = networkThroughputMbps
        self.networkTransferredBytes = networkTransferredBytes
        self.avSyncGapMs = avSyncGapMs
        self.producerRestartCount = producerRestartCount
        self.muxedBytesLifetime = muxedBytesLifetime
        self.serverBytesSentLifetime = serverBytesSentLifetime
        self.serverRequestCount = serverRequestCount
        self.demuxerBytesFetched = demuxerBytesFetched
        self.audioBridgeLiveBytes = audioBridgeLiveBytes
        self.rssMb = rssMb
    }
}
