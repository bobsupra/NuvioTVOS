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
    ///
    /// Channels' listings can run out at different times, so the channel that
    /// runs out first decides, not the one with the longest schedule. Only
    /// channels with listings from `loadedAt` on count: one with none, or only
    /// past ones, may legitimately have no guide and can't keep the rest
    /// refreshing. `minInterval` bounds it either way.
    static func nextRefresh(after programmes: [IPTVProgramme], loadedAt: Date) -> Date {
        let windowEnd = loadedAt.addingTimeInterval(lookAhead)
        var lastEndByChannel: [String: Date] = [:]
        for programme in programmes {
            lastEndByChannel[programme.channelID] = max(lastEndByChannel[programme.channelID] ?? .distantPast, programme.end)
        }
        let covered = lastEndByChannel.values.filter { $0 > loadedAt }
        let lastEnd = min(covered.min() ?? loadedAt, windowEnd)
        let beforeRunningOut = lastEnd.addingTimeInterval(-lead)
        let latest = loadedAt.addingTimeInterval(maxAge)
        let earliest = loadedAt.addingTimeInterval(minInterval)
        return max(earliest, min(beforeRunningOut, latest))
    }

    /// Whether to fetch the guide now, for every trigger (the minute clock and
    /// returning to the view): never while a load runs; at once if this source's
    /// guide was never tried; otherwise only once its scheduled time comes, so a
    /// failed load's backoff holds even if the guide is empty.
    static func shouldLoad(isLoading: Bool, nextRefresh: Date?, now: Date) -> Bool {
        guard !isLoading else { return false }
        guard let nextRefresh else { return true }
        return now >= nextRefresh
    }

    /// When to try again after `failures` consecutive failed loads (1 = the first).
    static func retry(afterFailures failures: Int, at now: Date) -> Date {
        let index = min(max(failures, 1), retryDelays.count) - 1
        return now.addingTimeInterval(retryDelays[index])
    }
}
