import Foundation

/// When Live TV fetches the programme guide (XMLTV) again.
///
/// The guide is loaded for a window around now, and a provider's schedule only
/// runs so far ahead. Without refreshing, the current programme disappears once
/// the loaded programmes run out. The guide is fetched again a while before
/// that, bounded so it's never fetched every minute: the clock only checks
/// whether a refresh is due.
enum IPTVGuideRefreshPolicy {
    /// The window loaded around `now`.
    static let lookBehind: TimeInterval = 6 * 3600
    static let lookAhead: TimeInterval = 48 * 3600
    /// Refresh this long before the loaded programmes (or window) run out.
    static let lead: TimeInterval = 2 * 3600
    /// Never keep a guide longer than this (schedules change).
    static let maxAge: TimeInterval = 12 * 3600
    /// Never fetch again sooner than this after a successful load.
    static let minInterval: TimeInterval = 30 * 60
    /// Waits after consecutive failures: 2, 5, 15, 30, then 60 minutes.
    static let retryDelays: [TimeInterval] = [2, 5, 15, 30, 60].map { $0 * 60 }

    static func window(around now: Date) -> Range<Date> {
        now.addingTimeInterval(-lookBehind)..<now.addingTimeInterval(lookAhead)
    }

    /// When to fetch again after a successful load at `loadedAt`.
    static func nextRefresh(after programmes: [IPTVProgramme], loadedAt: Date) -> Date {
        let windowEnd = loadedAt.addingTimeInterval(lookAhead)
        let lastEnd = min(programmes.map(\.end).max() ?? loadedAt, windowEnd)
        let beforeRunningOut = lastEnd.addingTimeInterval(-lead)
        let latest = loadedAt.addingTimeInterval(maxAge)
        let earliest = loadedAt.addingTimeInterval(minInterval)
        return max(earliest, min(beforeRunningOut, latest))
    }

    /// When to try again after `failures` consecutive failed loads (1 = the first).
    static func retry(afterFailures failures: Int, at now: Date) -> Date {
        let index = min(max(failures, 1), retryDelays.count) - 1
        return now.addingTimeInterval(retryDelays[index])
    }
}
