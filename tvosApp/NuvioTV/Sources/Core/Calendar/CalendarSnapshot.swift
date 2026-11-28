import CryptoKit
import Foundation

/// The last calendar, kept on disk so the Calendar tab and Home's Today row
/// open with it at once while a newer one loads.
///
/// It is shown whenever it was made for the same profile and settings, also
/// when the followed and watched shows changed since or it is a few days old:
/// a new one then loads behind it. Those sources are often not known yet right
/// after launch (Continue Watching still loading), and requiring them to match
/// sent the first visit after every start through a whole load.
struct CalendarSnapshot: Codable, Sendable {
    static let currentVersion = 2
    /// Older calendars are not shown at all; the new one loads from scratch.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    var version = CalendarSnapshot.currentVersion
    /// SHA-256 of the settings the calendar was made with. They include the
    /// TMDB key, so they are never written as they are.
    let settingsDigest: String
    /// SHA-256 of the shows it was made from (follows, watched, in progress).
    let sourcesDigest: String
    /// The day the calendar was made on.
    let day: CalendarDay
    let loadedAt: Date
    let result: CalendarResult

    init(settings: String, sources: String = "", day: CalendarDay, loadedAt: Date, result: CalendarResult) {
        self.settingsDigest = Self.digest(settings)
        self.sourcesDigest = Self.digest(sources)
        self.day = day
        self.loadedAt = loadedAt
        self.result = result
    }

    static func digest(_ settings: String) -> String {
        SHA256.hash(data: Data(settings.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Made with these settings, within `maxAge`, and not in the future (a
    /// clock set back): fine to show while a new one loads.
    func isUsable(settings: String, now: Date) -> Bool {
        version == Self.currentVersion
            && settingsDigest == Self.digest(settings)
            && now.timeIntervalSince(loadedAt) < Self.maxAge
            && loadedAt.timeIntervalSince(now) < 5 * 60
    }

    /// Made from these shows: it is the current calendar, not only one to show.
    func hasSources(_ sources: String) -> Bool {
        sourcesDigest == Self.digest(sources)
    }
}

/// Reads and writes the snapshot off the main thread, one write at a time.
actor CalendarSnapshotStore {
    static let shared = CalendarSnapshotStore()

    private let url: URL?
    private var lastSequence = 0

    init(url: URL? = CalendarSnapshotStore.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("calendar-result-v1.json")
    }

    func read() -> CalendarSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CalendarSnapshot.self, from: data)
    }

    /// Settings → Clear cache. A save already on its way may still land.
    func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `snapshot` unless a later one (by `sequence`) is written already:
    /// saves started in order may reach the store out of order.
    func write(_ snapshot: CalendarSnapshot, sequence: Int) {
        guard let url, sequence > lastSequence else { return }
        lastSequence = sequence
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
