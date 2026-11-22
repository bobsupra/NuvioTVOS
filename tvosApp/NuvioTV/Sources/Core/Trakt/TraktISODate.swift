import Foundation

/// Trakt timestamps ("2026-11-20T04:15:46.000Z", sometimes without the
/// fractional seconds). `ISO8601DateFormatter` is expensive to construct, and
/// Continue Watching parses one date per watched episode on the main actor,
/// so the formatters are created once and shared behind a lock (the same
/// approach as the release-date formatters in CatalogModels).
enum TraktISODate {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Fractional seconds first, then without, as the per-call formatters did.
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}
