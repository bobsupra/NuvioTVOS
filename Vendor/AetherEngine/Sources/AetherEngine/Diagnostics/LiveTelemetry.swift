import Foundation

/// 1 Hz live playback telemetry snapshot. Nil fields are path-asymmetric:
/// droppedFrameCount=nil on SW (dav1d doesn't drop; stalls show as falling observedFps);
/// observedFps=nil on native (AVPlayer has no usable live FPS counter);
/// avSyncGapMs=nil on SW (measured by HLSSegmentProducer which only runs on the native/HLS-loopback path);
/// forwardBufferSeconds=nil on SW (no loadedTimeRanges equivalent).
public struct LiveTelemetry: Equatable, Sendable {
    // Enthusiast section
    public let instantBitrateMbps: Double?
    public let averageBitrateMbps: Double?
    /// Live bitrate of the audio bridge's encoded output, or nil when no bridge is active (stream-copy /
    /// AVPlayer-native path) or before the first delta. Measured from the bridge's cumulative output-byte
    /// counter, since the common FLAC bridge is lossless VBR and has no fixed configured rate.
    public let audioBridgeBitrateMbps: Double?
    public let observedFps: Double?
    public let droppedFrameCount: Int?
    public let forwardBufferSeconds: Double?
    public let cachedBytes: Int64?
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
