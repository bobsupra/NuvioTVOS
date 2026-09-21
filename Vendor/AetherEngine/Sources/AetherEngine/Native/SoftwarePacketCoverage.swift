import Foundation

/// Presentation-time coverage of compressed packets that the caller still owns.
///
/// Keep one instance per selected stream and insert actual packet PTS/duration in that stream's
/// time base. Decode timestamps, byte counts and average bitrates cannot prove playable coverage.
/// Decode-order arrival is supported: a future reference picture does not bridge a missing B
/// picture's presentation interval until that packet actually arrives.
///
/// This value does not own packets or synchronize access. The packet owner must reset coverage
/// whenever packets are discarded (seek/flush/stream replacement), and must not prune beyond its
/// verified playback/discard position. `prune` only bounds old metadata; it is not a cache eviction
/// API for packets that are still ahead of the playhead.
struct SoftwarePacketCoverage: Sendable {
    private var ranges: [Range<Int64>] = []
    let maximumRangeCount: Int

    init(maximumRangeCount: Int = 4096) {
        self.maximumRangeCount = max(1, maximumRangeCount)
    }

    var rangeCount: Int { ranges.count }

    /// Adds [pts, pts + duration). Invalid or capacity-exceeding input leaves existing coverage
    /// unchanged. Rejecting a sparse extension is conservative: it never claims a missing packet.
    @discardableResult
    mutating func insert(pts: Int64, duration: Int64) -> Bool {
        guard pts != Int64.min, duration > 0 else { return false }
        let (end, overflow) = pts.addingReportingOverflow(duration)
        guard !overflow else { return false }

        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].upperBound < pts {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let first = lower
        var last = first
        var mergedStart = pts
        var mergedEnd = end
        while last < ranges.count, ranges[last].lowerBound <= mergedEnd {
            mergedStart = min(mergedStart, ranges[last].lowerBound)
            mergedEnd = max(mergedEnd, ranges[last].upperBound)
            last += 1
        }
        guard ranges.count - (last - first) < maximumRangeCount else { return false }
        ranges.replaceSubrange(first..<last, with: [mergedStart..<mergedEnd])
        return true
    }

    /// Returns the exclusive end of the contiguous interval containing this presentation tick.
    /// A future island is not a frontier for a clock in a gap. Endpoints are half-open: once the
    /// clock reaches an interval's end, another adjacent packet must exist to extend it.
    func frontier(containing tick: Int64) -> Int64? {
        guard tick != Int64.min else { return nil }
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].upperBound <= tick {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < ranges.count, ranges[lower].contains(tick) else { return nil }
        return ranges[lower].upperBound
    }

    /// Same coverage check for a source clock expressed in seconds. Convert range boundaries from
    /// integer timestamps rather than rounding the clock to ticks, which can cross a fractional
    /// frame boundary or hide a one-tick gap. There is deliberately no gap/rounding tolerance.
    func frontierSeconds(
        containing seconds: Double,
        timeBaseNumerator: Int32,
        timeBaseDenominator: Int32
    ) -> Double? {
        guard seconds.isFinite, timeBaseNumerator > 0, timeBaseDenominator > 0 else { return nil }
        let numerator = Double(timeBaseNumerator)
        let denominator = Double(timeBaseDenominator)
        for range in ranges {
            // Extremely large timestamps can lose an entire tick in Double. Fail closed instead
            // of silently merging a precision-sized gap in this seconds-facing convenience API.
            guard Int64(exactly: Double(range.lowerBound)) == range.lowerBound,
                  Int64(exactly: Double(range.upperBound)) == range.upperBound else { return nil }
            let start = Double(range.lowerBound) * numerator / denominator
            let end = Double(range.upperBound) * numerator / denominator
            guard start.isFinite, end.isFinite, start < end else { return nil }
            if seconds < start { return nil }
            if seconds < end { return end }
        }
        return nil
    }

    /// Drops intervals wholly behind the supplied presentation tick while retaining the entire
    /// containing interval and future islands. Does not manufacture coverage at the prune point.
    mutating func prune(before tick: Int64) {
        guard tick != Int64.min else { return }
        let expired = ranges.prefix { $0.upperBound <= tick }.count
        if expired > 0 { ranges.removeFirst(expired) }
    }

    mutating func reset() {
        ranges.removeAll(keepingCapacity: true)
    }

    /// A selected audio stream is a required part of A/V cache coverage, even when muted. Unknown
    /// selected-stream coverage stays unknown; an absent audio stream does not limit video-only
    /// playback. Inputs must already be on the same presentation timeline and contain the clock.
    static func combinedFrontier(
        video: Double?, audio: Double?, requiresAudio: Bool
    ) -> Double? {
        guard let video, video.isFinite else { return nil }
        guard requiresAudio else { return video }
        guard let audio, audio.isFinite else { return nil }
        return min(video, audio)
    }
}
