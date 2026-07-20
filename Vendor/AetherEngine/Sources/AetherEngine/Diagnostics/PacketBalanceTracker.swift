import Foundation
import AetherLibavcodec

/// Tracks Swift-initiated av_packet_alloc/free calls; `alive = allocs - frees` in the engine memory probe.
/// Healthy pump steady-state: low single digit (1 in-flight source packet, 1 each for pendingVideoPkt/pendingAudioPkt, 0..N FLAC bridge packets).
/// Linearly rising alive = packet leak (~75 KB/s = 4.5 MB/min per leaked frame-rate packet).
/// Does NOT count libavformat-internal av_packet_ref/unref (mp4 muxer interleave, matroska side data).
enum PacketBalanceTracker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _allocs: Int = 0
    nonisolated(unsafe) private static var _frees: Int = 0

    static func recordAlloc() {
        lock.lock()
        _allocs &+= 1
        lock.unlock()
    }

    static func recordFree() {
        lock.lock()
        _frees &+= 1
        lock.unlock()
    }

    static var alive: Int {
        lock.lock()
        defer { lock.unlock() }
        return _allocs - _frees
    }

    static var totalAllocs: Int {
        lock.lock()
        defer { lock.unlock() }
        return _allocs
    }
}

/// Drop-in for av_packet_alloc() that records the alloc in PacketBalanceTracker.
@inline(__always)
func trackedPacketAlloc() -> UnsafeMutablePointer<AVPacket>? {
    let p = av_packet_alloc()
    if p != nil {
        PacketBalanceTracker.recordAlloc()
    }
    return p
}

/// Drop-in for av_packet_free() that records the free in PacketBalanceTracker.
/// A nil input records nothing: defer chains pass already-nil'd pointers here; counting them would drift alive negative.
@inline(__always)
func trackedPacketFree(_ pkt: inout UnsafeMutablePointer<AVPacket>?) {
    if pkt != nil {
        PacketBalanceTracker.recordFree()
    }
    av_packet_free(&pkt)
}
