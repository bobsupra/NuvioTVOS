import Foundation

/// A contiguous run of bytes already in memory, servable without a network round trip.
///
/// #281: two distinct situations hand the reader bytes it will need again shortly, and both
/// used to throw them away:
///
///  - The open connection's window is discarded whenever a parse seek reconnects elsewhere
///    (`startPersistentConnection` resets `window`). On a non-faststart MP4 the demuxer walks
///    the box chain at the head, jumps to the trailing `moov`, then comes straight back to the
///    first sample. The bytes for that third step were already resident before the second one
///    threw them away, so the return trip cost a whole round trip for data the reader had.
///  - A speculative tail fetch issued alongside `open()` lands bytes the demuxer has not asked
///    for yet.
///
/// Both are the same shape: a known start offset plus the bytes that follow it. Neither is a
/// cache in the `DetourBlockCache` sense; there is no fetch-on-miss, no eviction policy and no
/// block alignment. A span either covers the requested offset or it does not.
struct ResidentSpan: Sendable, Equatable {
    let start: Int64
    let data: Data

    /// One past the last byte this span can serve.
    var end: Int64 { start + Int64(data.count) }

    var isEmpty: Bool { data.isEmpty }

    init(start: Int64, data: Data) {
        self.start = start
        self.data = data
    }

    func covers(_ offset: Int64) -> Bool {
        offset >= start && offset < end
    }

    /// Copies up to `maxLen` bytes starting at `offset` into `dst` and returns the count, or nil
    /// when the span does not cover `offset`. A read running past `end` is served up to the span
    /// boundary; the caller re-enters at the advanced offset and takes whatever path fits there,
    /// exactly as the window path does at its frontier.
    func serve(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int, at offset: Int64) -> Int? {
        guard maxLen > 0, covers(offset) else { return nil }
        let inSpan = Int(offset - start)
        let n = min(maxLen, data.count - inSpan)
        guard n > 0 else { return nil }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inSpan).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return n
    }
}
