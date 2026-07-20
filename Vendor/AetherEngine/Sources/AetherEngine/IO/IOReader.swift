import Foundation

/// Custom byte source for `AetherEngine.load(source:)`. Use for memory buffers, encrypted containers, or anything not a plain URL. `read`/`seek` run on the engine's demux thread (not main); `close()` is called exactly once at teardown, never between probe and playback.
public protocol IOReader: AnyObject, Sendable {
    /// Read up to `size` bytes into `buffer`. Return bytes read, `0` on EOF, or negative on error. The `buffer` optional reflects the C import convention; the engine never passes nil.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32

    /// Reposition the source. `whence`: `SEEK_SET`/`SEEK_CUR`/`SEEK_END` or `AVSEEK_SIZE` (65536, return total size without moving). Return new absolute position or negative on error/unsupported direction. Forward-only sources (AVIO live streams) are supported on the software path only.
    func seek(offset: Int64, whence: Int32) -> Int64

    func close()

    /// Unblock a pending `read` so teardown does not hang. Network readers cancel the in-flight request; memory/file readers can leave this as the default no-op. For readers the engine may reload: unblock only, do not invalidate.
    func cancel()

    /// Return an independent reader with its own cursor over the same source for concurrent access (side demuxer, scrub previews). Return nil for one-shot streams; the engine skips that feature. The returned reader is owned and closed by the engine.
    func makeIndependentReader() -> IOReader?
}

public extension IOReader {
    func cancel() {}
    func makeIndependentReader() -> IOReader? { nil }
}

/// The source AetherEngine loads media from.
public enum MediaSource: Sendable {
    case url(URL)
    /// `formatHint`: optional container short name ("mp4", "matroska", "mpegts") to disambiguate probing when no filename is present; nil probes from content.
    case custom(IOReader, formatHint: String? = nil)
}
