import Foundation

/// Memoizes a source URL's resolved total byte length across demuxer opens (#112).
///
/// On a remote MPEG-TS the video producer opens the origin first and resolves its size from the persistent
/// connection's `206 Content-Range`, which makes `avformat_seek_file` work (mpegts's timestamp binary search needs
/// `avio_size` + backward byte seeks). A PGS subtitle side demuxer opening the SAME origin later (an audio-track
/// switch or a fast-forward re-arm) runs its own size probe, which under the producer's concurrent origin load can
/// be 429'd or answered without a length; it then collapses to forward-only streaming, where every backward seek
/// returns -1 and PGS reconstruction reads zero packets (ijuniorfu's "the subtitles aren't showing up"). A source's
/// length is immutable within a session, so reusing the already-resolved value keeps the side demuxer byte-seekable.
///
/// Thread-safe: the main pump and the side demuxer open concurrently on different threads. Only positive sizes are
/// stored, so a genuinely length-less source (live remux) never populates it and correctly stays streaming. A small
/// LRU bounds memory; entries are a single Int64 each.
enum SourceContentLengthCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Int64] = [:]
    nonisolated(unsafe) private static var order: [String] = []   // LRU recency, most-recent last
    private static let capacity = 8

    static func lookup(_ url: URL) -> Int64? {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        guard let hit = entries[key] else { return nil }
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        return hit
    }

    static func store(_ size: Int64, for url: URL) {
        guard size > 0 else { return }
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        if entries[key] == nil, order.count >= capacity, let evict = order.first {
            order.removeFirst()
            entries[evict] = nil
        }
        entries[key] = size
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }
}
