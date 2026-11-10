import Foundation

/// What the calendar shows, picked from its header.
enum CalendarFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    /// Series and season premieres and season finales.
    case premieres
    /// Series other than anime.
    case series
    case anime
    case movies

    var id: String { rawValue }

    /// The stored value, or `.all` for an unknown or missing one.
    init(stored: String) {
        self = CalendarFilter(rawValue: stored) ?? .all
    }

    func includes(_ entry: CalendarEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .premieres:
            return [.seriesPremiere, .seasonPremiere, .seasonFinale].contains(entry.releaseKind)
        case .series:
            return entry.kind == .series && !entry.isAnime
        case .anime:
            return entry.isAnime
        case .movies:
            return entry.kind == .movie
        }
    }

    var title: String {
        switch self {
        case .all: return L10n.string("calendar_filter_all", fallback: "Everything")
        case .premieres: return L10n.string("calendar_filter_premieres", fallback: "Premieres & finales")
        case .series: return L10n.string("calendar_filter_series", fallback: "Series")
        case .anime: return L10n.string("calendar_filter_anime", fallback: "Anime")
        case .movies: return L10n.string("calendar_filter_movies", fallback: "Movies")
        }
    }

    /// One word for the header button; the menu shows `title`.
    var shortTitle: String {
        switch self {
        case .premieres: return L10n.string("calendar_filter_premieres_short", fallback: "Premieres")
        default: return title
        }
    }
}

/// The calendar's own options, chosen from its header. Like the app's other
/// `@AppStorage` settings they live in the active profile's store.
enum CalendarOptions {
    static let defaultHideSpoilers = false
    static let defaultCheckAvailability = true
    static let defaultTvmazeTimes = true
    static let defaultAniList = true
    static let defaultAniListPlanning = true

    /// Exact broadcast times for regular series from TVmaze.
    static func tvmazeTimes(in store: UserDefaults = ProfileSettings.current) -> Bool {
        (store.object(forKey: SettingsKey.calendarTvmazeTimes) as? Bool) ?? defaultTvmazeTimes
    }

    /// Anime straight from AniList (`CalendarAniList`), only with AniList switched on in Settings.
    static func aniList(in store: UserDefaults = ProfileSettings.current) -> Bool {
        AniListSettings.isEnabled(in: store)
            && ((store.object(forKey: SettingsKey.calendarAniList) as? Bool) ?? defaultAniList)
    }

    /// With `aniList`: premieres of what is on the viewer's AniList Planning list too.
    static func aniListPlanning(in store: UserDefaults = ProfileSettings.current) -> Bool {
        (store.object(forKey: SettingsKey.calendarAniListPlanning) as? Bool) ?? defaultAniListPlanning
    }

    /// What of the AniList option changes the calendar: the switches, whose list, and the
    /// language of the titles. Empty with the option off.
    static func aniListSignature(in store: UserDefaults = ProfileSettings.current) -> String {
        guard aniList(in: store) else { return "" }
        let viewer = AniListAccount.isLoggedIn ? AniListAccount.login.map { String($0.viewerID) } ?? "" : ""
        return [
            "anilist",
            aniListPlanning(in: store) ? "planning" : "",
            viewer,
            AniListSettings.titleLanguage.rawValue,
        ].joined(separator: ":")
    }
}

extension CalendarResult {
    /// The same result with only the entries `filter` keeps; days left empty
    /// are dropped. Follow sources are unchanged.
    func filtered(_ filter: CalendarFilter) -> CalendarResult {
        guard filter != .all else { return self }
        let kept = days.compactMap { section -> CalendarDaySection? in
            let entries = section.entries.filter(filter.includes)
            return entries.isEmpty ? nil : CalendarDaySection(date: section.date, entries: entries)
        }
        return CalendarResult(
            firstDay: firstDay,
            lastDay: lastDay,
            days: kept,
            skipped: skipped,
            manualFollowKeys: manualFollowKeys,
            manualFollowItems: manualFollowItems,
            automaticFollowItems: automaticFollowItems
        )
    }

    /// The same result with its entries replaced (after air times moved some
    /// of them to another day).
    func replacingEntries(_ entries: [CalendarEntry]) -> CalendarResult {
        CalendarResult(
            firstDay: firstDay,
            lastDay: lastDay,
            days: CalendarBuilder.groupByDay(entries),
            skipped: skipped,
            manualFollowKeys: manualFollowKeys,
            manualFollowItems: manualFollowItems,
            automaticFollowItems: automaticFollowItems
        )
    }

    var allEntries: [CalendarEntry] { days.flatMap(\.entries) }
}
