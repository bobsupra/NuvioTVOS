import SwiftUI

/// Home's "Today" row: what comes out today from the library, taken from the
/// calendar (series, anime and movies alike), one card per title in airing
/// order.
struct CalendarHomeToday: Equatable {
    /// What the card shows besides the title, in the slots Continue
    /// Watching's Up Next cards use.
    struct CardLabel: Equatable {
        /// "S2E5" for episodes.
        let episode: String?
        /// The episode's name, unless spoilers are hidden.
        let episodeTitle: String?
        /// The broadcast time, "AIRING TODAY", or the movie's release kind.
        let badge: String
        /// The episode's picture for landscape cards, unless spoilers are hidden.
        let artworkURL: String?
    }

    var metas: [NuvioMeta] = []
    /// By title id (the row's card ids).
    var labels: [String: CardLabel] = [:]
    /// The calendar entry each card opens, by title id.
    var entries: [String: CalendarEntry] = [:]

    var isEmpty: Bool { metas.isEmpty }

    /// The row for `today`. A title with several entries today (a double
    /// episode) gets one card, for its first entry.
    static func build(
        from result: CalendarResult?,
        today: CalendarDay,
        hideSpoilers: Bool,
        time: (Date) -> String = CalendarFormat.time
    ) -> CalendarHomeToday {
        guard let result else { return CalendarHomeToday() }
        var row = CalendarHomeToday()
        // Already in airing order (timed first), then by title.
        for entry in result.entries(on: today) where isWatchableToday(entry) && row.entries[entry.itemId] == nil {
            row.entries[entry.itemId] = entry
            row.metas.append(meta(for: entry))
            row.labels[entry.itemId] = CardLabel(
                episode: entry.seasonNumber.flatMap { season in entry.episodeNumber.map { "S\(season)E\($0)" } },
                episodeTitle: hideSpoilers ? nil : entry.episodeName,
                badge: badge(for: entry, time: time),
                artworkURL: hideSpoilers ? nil : entry.stillURL?.absoluteString
            )
        }
        return row
    }

    /// Cinema releases can't be watched at home, so they are left out.
    static func isWatchableToday(_ entry: CalendarEntry) -> Bool {
        entry.releaseKind != .theatrical
    }

    static func badge(for entry: CalendarEntry, time: (Date) -> String) -> String {
        if let airTime = entry.airTime { return time(airTime) }
        if entry.kind == .movie, let release = CalendarFormat.releaseLabel(entry.releaseKind) { return release }
        // Matches Nuvio's own green "airing today" badge, so not translated.
        return "AIRING TODAY"
    }

    /// A compact card; Home fills in the hero's details once it is focused,
    /// as for add-on catalogs. The show's backdrop is left to that too: the
    /// episode's picture would be a spoiler there.
    private static func meta(for entry: CalendarEntry) -> NuvioMeta {
        let imdb = entry.itemId.hasPrefix("tt") ? String(entry.itemId.prefix { $0 != ":" }) : nil
        return NuvioMeta(
            id: entry.itemId,
            name: entry.title,
            posterUrl: entry.posterURL?.absoluteString,
            imdbId: imdb,
            tmdbId: entry.tmdbId,
            type: entry.itemType.isEmpty ? (entry.kind == .series ? "series" : "movie") : entry.itemType
        )
    }

    /// Seconds to a few moments after the next local midnight.
    static func secondsUntilTomorrow(from now: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(24 * 60 * 60)
        return max(60, next.timeIntervalSince(now) + 5)
    }
}

/// Keeps Home's Today row in step with the shared calendar: the saved one
/// at once, a newer one a moment after Home's own rows have loaded, and the
/// next day's at midnight.
struct CalendarTodayHomeFeed: ViewModifier {
    /// How old the calendar may be before Home asks for a new one.
    static let maxAge: TimeInterval = 3 * 60 * 60

    let enabled: Bool
    let homeReady: Bool
    let isActive: Bool
    @Binding var row: CalendarHomeToday
    @AppStorage(SettingsKey.calendarHideSpoilers) private var hideSpoilers = CalendarOptions.defaultHideSpoilers

    /// Not observed: Home redraws only when its row changes.
    private var model: CalendarViewModel { .shared }

    private struct Trigger: Equatable {
        let enabled: Bool
        let ready: Bool
        let active: Bool
    }

    func body(content: Content) -> some View {
        content
            .onReceive(model.$state) { update($0) }
            .onChange(of: enabled) { _, _ in update(model.state) }
            .onChange(of: hideSpoilers) { _, _ in update(model.state) }
            .task(id: Trigger(enabled: enabled, ready: homeReady, active: isActive)) {
                guard enabled, isActive else { return }
                model.showSaved()
                guard homeReady else { return }
                // Home's own rows first.
                try? await Task.sleep(for: .seconds(2))
                while !Task.isCancelled {
                    model.loadIfNeeded(maxAge: Self.maxAge)
                    // The day may have changed since the row was made.
                    update(model.state)
                    try? await Task.sleep(for: .seconds(CalendarHomeToday.secondsUntilTomorrow(from: Date())))
                }
            }
    }

    private func update(_ state: CalendarViewModel.State) {
        let today = CalendarHomeToday.build(
            from: model.currentResult(from: state),
            today: CalendarDay(date: Date()),
            hideSpoilers: hideSpoilers
        )
        // The Top Shelf can show Today even when Home's row is off.
        TopShelfTodayFeed.write(today)
        let next = enabled ? today : CalendarHomeToday()
        if next != row { row = next }
    }
}
