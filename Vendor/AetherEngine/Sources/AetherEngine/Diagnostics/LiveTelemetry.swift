import Foundation

/// 1 Hz live playback telemetry snapshot. Nil fields are path-asymmetric:
/// observedFps=nil on native (AVPlayer has no usable live FPS counter);
/// avSyncGapMs=nil on SW (measured by HLSSegmentProducer which only runs on the native/HLS-loopback path);
/// forwardBufferSeconds=nil on SW, and stays nil on purpose (#306): the software demux loop reads on
/// renderer back-pressure, so there is no seconds-deep reservoir of arrived-but-unplayed media to
/// report there. `displayCushionSeconds` and `readerWindowAheadBytes` are what that path holds instead,
/// and putting either of them under the same name would report a near-stall on a healthy session.
public struct LiveTelemetry: Equatable, Sendable {
    // Enthusiast section
    public let instantBitrateMbps: Double?
    public let averageBitrateMbps: Double?
    /// Live bitrate of the audio bridge's encoded output, or nil when no bridge is active (stream-copy /
    /// AVPlayer-native path) or before the first delta. Measured from the bridge's cumulative output-byte
    /// counter, since the common FLAC bridge is lossless VBR and has no fixed configured rate.
    public let audioBridgeBitrateMbps: Double?
    public let observedFps: Double?
    /// Frames the display dropped: AVPlayer's access log on the native path, the render synchronizer's
    /// own metrics on the software one (#306). Software sessions predating that read it as nil, as does
    /// an OS without `videoPerformanceMetrics`.
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
    /// The rate the source link delivers at while it is delivering, so it stays comparable between the
    /// two paths: `observedBitrate` from the access log on native, and on the software path the
    /// demuxer's own byte counter over the seconds bytes arrived in (#306 follow-up). Not a wall-clock
    /// mean: the reader fetches a large range and parks on backpressure until low water, so a healthy
    /// fast link is idle for most of a window and a mean over it would report 0.0 Mbps on a session
    /// that is playing perfectly. nil when nothing arrived in the window at all, which is the honest
    /// reading for "not measurable right now"; it is never zero to mean that.
    public let networkThroughputMbps: Double?
    public let networkTransferredBytes: Int64?
    public let avSyncGapMs: Double?

    // Engine diagnostics section
    public let producerRestartCount: Int
    public let muxedBytesLifetime: Int64
    public let serverBytesSentLifetime: Int64
    public let serverRequestCount: Int
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
