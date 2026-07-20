import Foundation
import AetherLibavformat
import AetherLibavutil

/// Bridges an `IOReader` into `AVIOContext` via avio_alloc_context callbacks,
/// mirroring AVIOReader's lifecycle at the same Demuxer seam.
/// @unchecked Sendable: isClosed is a benign-race plain Bool (read callback
/// only needs to eventually observe it); context written once under teardown ordering.
final class CustomIOReaderBridge: AVIOProvider, @unchecked Sendable {
    private let reader: IOReader
    private static let bufferSize: Int32 = 256 * 1024  // matches AVIOReader.avioBufferSize
    private var buffer: UnsafeMutablePointer<UInt8>?
    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var isClosed = false
    private var isFullyClosed = false
    private(set) var isSeekable: Bool = true

    var cumulativeBytesFetched: Int64 { 0 }  // custom readers don't track network bytes

    /// #112 round 9: same demux-thread-only contract as AVIOReader's deadline. Armed by
    /// `Demuxer.seekBounded` around a positioning seek; `performRead` checks it between callbacks, so
    /// an index-less remote disc's read_timestamp binary search aborts within one chunk fetch instead
    /// of parking for minutes (ijuniorfu round 9, remote ISO: one seek sat wedged ~230 s).
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    private(set) var readDeadlineFired = false

    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        readDeadlineFired = false
        readDeadline = Date(timeIntervalSinceNow: seconds)
    }

    func endReadDeadline() {
        readDeadline = .distantFuture
    }

    /// #112 round 9: the byte axis libavformat sees through this bridge (for a disc adapter, the
    /// virtual concat stream length via AVSEEK_SIZE), backing the byte-estimate seek fallback.
    var resolvedByteSize: Int64? {
        let size = reader.seek(offset: 0, whence: 65536)  // AVSEEK_SIZE: report length, don't move
        return size > 0 ? size : nil
    }

    init(reader: IOReader) {
        self.reader = reader
    }

    func open() throws {
        guard let buf = av_malloc(Int(Self.bufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.bufferSize,
            0,                       // read-only (write_flag = 0)
            opaque,
            customBridgeReadCallback,
            nil,                     // no write
            customBridgeSeekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }
        context = ctx

        // SEEK_SET to 0 is a no-op for seekable, refused by forward-only (returns negative).
        isSeekable = reader.seek(offset: 0, whence: 0) >= 0
    }

    func markClosed() {
        isClosed = true
        reader.cancel()
    }

    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if let ctx = context {
            // avio_context_free does NOT free ctx->buffer (verified, aviobuf.c).
            // Free ctx.pointee.buffer (not original av_malloc ptr: FFmpeg may
            // realloc via ffio_set_buf_size).
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil
        // Bridge does NOT own the reader; engine/side-path owns lifetime.
    }

    func performRead(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        // -1 = forced abort (not EOF); mirrors AVIOReader.read so FFmpeg doesn't run EOS handling.
        guard !isClosed else { return -1 }
        if isPastReadDeadline { readDeadlineFired = true; return -1 }
        let n = reader.read(buf, size: size)
        if n == 0 { return FFmpegErr.eof }  // IOReader uses 0 for EOF; avio expects AVERROR_EOF.
        return n
    }

    fileprivate func performSeek(offset: Int64, whence: Int32) -> Int64 {
        guard !isClosed else { return -1 }
        return reader.seek(offset: offset, whence: whence)
    }
}

// MARK: - C Callbacks


private func customBridgeReadCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let bridge = Unmanaged<CustomIOReaderBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.performRead(into: buf, size: size)
}

private func customBridgeSeekCallback(
    opaque: UnsafeMutableRawPointer?,
    offset: Int64,
    whence: Int32
) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let bridge = Unmanaged<CustomIOReaderBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.performSeek(offset: offset, whence: whence)
}
