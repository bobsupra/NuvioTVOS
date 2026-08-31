import Foundation

/// Measures the OBSERVED segment-arrival cadence of a live ingest upstream: the wall-clock interval
/// between successive batches of newly-appeared segments, plus the currently-open gap since the last
/// arrival. This is the signal the engine trusts for LL-HLS playlist shaping instead of the upstream's
/// self-reported `#EXT-X-TARGETDURATION`, which says nothing about real delivery discipline: a relay /
/// budget IPTV origin can advertise a normal target while pushing segments in irregular batches
/// (AetherEngine#167).
///
/// Value type; the ingest reader records arrivals under its own lock and reads the estimate the same way.
struct LiveArrivalCadenceMeter {
    /// Trailing window of closed inter-arrival intervals; the max over it is the recent cadence. A window
    /// (not an all-time max) lets the estimate recover once an origin stops bursting.
    private var recentIntervals: [Double] = []
    private var lastArrival: Double?
    private let windowSize = 8

    /// Record that new segment(s) appeared at monotonic time `now`. The first call only anchors the clock
    /// (the join itself is not a gap); later calls close the interval since the previous arrival.
    mutating func recordArrival(at now: Double) {
        if let last = lastArrival, now > last {
            recentIntervals.append(now - last)
            if recentIntervals.count > windowSize { recentIntervals.removeFirst() }
        }
        lastArrival = now
    }

    /// Observed cadence in seconds at monotonic time `now`: the larger of the recent max closed interval
    /// and the currently-open gap since the last arrival. nil before the first arrival. The open-gap term
    /// makes a lengthening quiet stretch raise the estimate in real time, so a source that goes quiet is
    /// judged bursty while it is quiet rather than a batch later.
    func observedCadence(at now: Double) -> Double? {
        guard let last = lastArrival else { return nil }
        let ongoing = max(0, now - last)
        let closedMax = recentIntervals.max() ?? 0
        return max(closedMax, ongoing)
    }

    /// AE#447: the recent max CLOSED interval alone, nil until one has closed. What the served
    /// TARGETDURATION is sealed from.
    ///
    /// The open-gap term above cannot do that job, because the seal is taken inside the first-serve gate
    /// and the gate is itself a wait: measured there, the open gap is the time the engine has spent
    /// holding its own manifest back, not a cadence the source ever showed. It feeds back, too. A wider
    /// gap raises the floor, a higher floor raises TARGETDURATION, and `3 x TARGETDURATION` of holdback
    /// makes the gate wait longer still. Measured on the loopback fixture at a 2.000 s cadence: a floor
    /// of 3.090 s where nothing upstream was ever slower than 2 s.
    var closedCadence: Double? { recentIntervals.max() }
}
