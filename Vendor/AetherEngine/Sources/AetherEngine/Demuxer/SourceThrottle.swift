import Foundation

/// Virtual-clock leaky-bucket rate limiter for the source IO read path (slow-CDN simulation).
/// Pure value logic so the pacing can be unit-tested without sleeping. `AVIOReader` keeps one
/// `vclockNs` per reader and calls `advance` after each delivered chunk; the returned nanoseconds
/// are how long to `Thread.sleep` before returning the bytes to the demuxer.
enum SourceThrottle {

    /// Wall-clock nanoseconds it should take to deliver `bytes` at `kbps` kilobits/s. 0 when disabled.
    static func costNs(bytes: Int, kbps: Int) -> UInt64 {
        guard kbps > 0, bytes > 0 else { return 0 }
        let bytesPerSec = Double(kbps) * 125.0   // kbit/s -> byte/s (1000 bits / 8)
        return UInt64((Double(bytes) / bytesPerSec) * 1_000_000_000)
    }

    /// Advance the virtual delivery clock by one chunk and return the sleep (ns) needed to hold the rate.
    /// `vclockNs` is the real time by which all bytes so far should have been delivered. An idle gap
    /// (now past the clock) resets the base to `now`, so a pause never banks burst credit.
    static func advance(vclockNs: inout UInt64, nowNs: UInt64, deliveredBytes: Int, kbps: Int) -> UInt64 {
        guard kbps > 0, deliveredBytes > 0 else { return 0 }
        let base = max(vclockNs, nowNs)
        let deadline = base &+ costNs(bytes: deliveredBytes, kbps: kbps)
        vclockNs = deadline
        return deadline > nowNs ? deadline - nowNs : 0
    }
}
