import Foundation

/// Ready-made TMDB lists for adding many titles to the calendar at once
/// ("anime this season", "series airing now", "upcoming movies").
enum CalendarSuggestionList: String, CaseIterable, Identifiable, Sendable {
    case animeToday
    case animeThisSeason
    case seriesToday
    case airingNow
    case upcomingMovies
    /// Manual and automatic follows already shown by the calendar.
    case inCalendar

    var id: String { rawValue }

    /// Lists built from TMDB/AniList; `inCalendar` shows current follows.
    var isCalendarList: Bool { self == .inCalendar }

    var kind: CalendarMediaKind {
        self == .upcomingMovies ? .movie : .series
    }

    var itemType: String {
        switch self {
        case .animeToday, .animeThisSeason: return "anime"
        case .upcomingMovies: return "movie"
        default: return "series"
        }
    }

    /// Top-level button the list sits under in Add to calendar.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case anime, series, movies, calendar
        var id: String { rawValue }

        var title: String {
            switch self {
            case .anime: return L10n.string("calendar_suggest_group_anime", fallback: "Anime")
            case .series: return L10n.string("calendar_suggest_group_series", fallback: "Series")
            case .movies: return L10n.string("calendar_suggest_group_movies", fallback: "Movies")
            case .calendar: return L10n.string("calendar_suggest_group_calendar", fallback: "In calendar")
            }
        }

        var lists: [CalendarSuggestionList] {
            CalendarSuggestionList.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .animeToday, .animeThisSeason: return .anime
        case .seriesToday, .airingNow: return .series
        case .upcomingMovies: return .movies
        case .inCalendar: return .calendar
        }
    }

    /// Name inside its group's menu.
    var shortTitle: String {
        switch self {
        case .animeToday, .seriesToday: return L10n.string("calendar_suggest_today", fallback: "Today")
        case .animeThisSeason: return L10n.string("calendar_suggest_this_season", fallback: "This season")
        case .airingNow: return L10n.string("calendar_suggest_airing_now", fallback: "Airing now")
        case .upcomingMovies: return L10n.string("calendar_suggest_upcoming", fallback: "Upcoming")
        case .inCalendar: return L10n.string("calendar_suggest_group_calendar", fallback: "In calendar")
        }
    }

    var title: String {
        switch self {
        case .animeToday: return L10n.string("calendar_suggest_anime_today", fallback: "Anime today")
        case .animeThisSeason: return L10n.string("calendar_suggest_anime", fallback: "Anime this season")
        case .seriesToday: return L10n.string("calendar_suggest_series_today", fallback: "Series today")
        case .airingNow: return L10n.string("calendar_suggest_airing", fallback: "Series airing now")
        case .upcomingMovies: return L10n.string("calendar_suggest_movies", fallback: "Upcoming movies")
        case .inCalendar: return L10n.string("calendar_suggest_group_calendar", fallback: "In calendar")
        }
    }
}

struct CalendarSuggestionRequest: Equatable, Sendable {
    let path: String
    let query: [String: String]
}

enum CalendarSuggestions {
    /// TMDB pages per list (20 titles each).
    static let pages = 5

    /// The anime broadcast season `day` falls in: winter Jan–Mar, spring
    /// Apr–Jun, summer Jul–Sep, fall Oct–Dec.
    static func animeSeason(containing day: CalendarDay) -> (first: CalendarDay, last: CalendarDay) {
        let startMonth = ((day.month - 1) / 3) * 3 + 1
        let first = CalendarDay(year: day.year, month: startMonth, day: 1)
        let last = first.addingMonths(2).lastOfMonth
        return (first, last)
    }

    /// Genres left out of "airing now": animation (has its own list), news,
    /// reality and talk shows, which would otherwise crowd the top.
    static let airingNowExcludedGenres = "16,10763,10764,10767"

    static func request(for list: CalendarSuggestionList, today: CalendarDay, region: String) -> CalendarSuggestionRequest {
        switch list {
        case .animeToday:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "with_genres": "16",
                "with_origin_country": "JP",
                "air_date.gte": today.iso,
                "air_date.lte": today.iso,
                "sort_by": "popularity.desc",
            ])
        case .seriesToday:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "without_genres": airingNowExcludedGenres,
                "air_date.gte": today.iso,
                "air_date.lte": today.iso,
                "sort_by": "popularity.desc",
            ])
        case .animeThisSeason:
            let season = animeSeason(containing: today)
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "with_genres": "16",
                "with_origin_country": "JP",
                "air_date.gte": season.first.iso,
                "air_date.lte": season.last.iso,
                "sort_by": "popularity.desc",
            ])
        case .airingNow:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "without_genres": airingNowExcludedGenres,
                "air_date.gte": today.iso,
                "air_date.lte": today.adding(days: 14).iso,
                "sort_by": "popularity.desc",
            ])
        case .upcomingMovies:
            return CalendarSuggestionRequest(path: "movie/upcoming", query: ["region": region])
        case .inCalendar:
            // Built from current calendar follows, no request.
            return CalendarSuggestionRequest(path: "", query: [:])
        }
    }

    static func key(kind: CalendarMediaKind, tmdbId: Int) -> String {
        "\(kind.rawValue):\(tmdbId)"
    }
}

/// One title in the "Add to calendar" picker, from a TMDB list or from the
/// AniList + Simkl "Anime today" list.
struct CalendarSuggestionItem: Identifiable, Hashable, Sendable {
    /// Stable title key, preferring TMDB and then IMDb.
    let key: String
    let kind: CalendarMediaKind
    let type: String
    let tmdbId: Int?
    let imdbId: String?
    let title: String
    let posterURL: URL?
    let year: Int?
    /// Shown under the title instead of the year (e.g. the broadcast time).
    let detail: String?
    var isAutomaticallyFollowed = false

    var id: String { key }
    var isAddable: Bool { tmdbId != nil || imdbId != nil }

    init(key: String, kind: CalendarMediaKind, type: String? = nil, tmdbId: Int?, imdbId: String?, title: String,
         posterURL: URL?, year: Int?, detail: String? = nil, isAutomaticallyFollowed: Bool = false) {
        self.key = key
        self.kind = kind
        self.type = type ?? (kind == .series ? "series" : "movie")
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.title = title
        self.posterURL = posterURL
        self.year = year
        self.detail = detail
        self.isAutomaticallyFollowed = isAutomaticallyFollowed
    }

    init(tmdb result: CalendarTmdb.ListResult, kind: CalendarMediaKind, type: String? = nil) {
        self.init(
            key: CalendarSuggestions.key(kind: kind, tmdbId: result.id),
            kind: kind,
            type: type,
            tmdbId: result.id,
            imdbId: nil,
            title: result.displayTitle,
            posterURL: CalendarTmdb.imageURL(result.posterPath, size: "w342"),
            year: result.year
        )
    }
}

extension CalendarSuggestions {
    /// Lists manual follows and automatic watched/progress titles together,
    /// with their source made explicit. Only manual follows can be removed.
    static func calendarItems(
        manualFollows: [String: CalendarItem],
        automaticFollows: [String: CalendarItem],
        resolvedManualFollows: [String: CalendarItem],
        nextDates: [String: CalendarDay],
        skipped: [String: CalendarSkippedItem],
        today: CalendarDay
    ) -> [CalendarSuggestionItem] {
        func item(
            key: String,
            entry: CalendarItem,
            resultKey: String,
            isManual: Bool,
            isAutomatic: Bool,
            skippedItem: CalendarSkippedItem? = nil
        ) -> CalendarSuggestionItem {
            let tmdb = entry.tmdbId ?? resultKey.split(separator: ":").last.flatMap { Int($0) }
            let date = nextDates[resultKey].map { CalendarFormat.nextDate($0, today: today) }
            let detail = skippedItem.map { CalendarFormat.skipReason($0.reason) }
                ?? date
                ?? L10n.string("calendar_suggest_nothing_upcoming", fallback: "Nothing upcoming")
            let savedTitle = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = tmdb.map {
                L10n.format("calendar_suggest_tmdb_fallback", fallback: "TMDB # %d", $0)
            } ?? (entry.id.isEmpty
                ? L10n.string("calendar_suggest_unknown_title", fallback: "Unknown title")
                : entry.id)
            let title = savedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
            let sourceLabel: String
            if isManual && isAutomatic {
                sourceLabel = L10n.string(
                    "calendar_suggest_manual_and_automatic",
                    fallback: "Manual follow · also followed while watched or in progress"
                )
            } else if isManual {
                sourceLabel = L10n.string("calendar_suggest_manual_follow", fallback: "Manual follow")
            } else {
                sourceLabel = L10n.string(
                    "calendar_suggest_automatic_follow",
                    fallback: "Automatically followed while watched or in progress"
                )
            }
            return CalendarSuggestionItem(
                key: key,
                kind: entry.kind,
                type: entry.type.isEmpty ? (entry.kind == .series ? "series" : "movie") : entry.type,
                tmdbId: tmdb,
                imdbId: entry.imdbId ?? NuvioMeta.canonicalImdbID(from: entry.id),
                title: title,
                posterURL: entry.posterURL.flatMap(URL.init(string:)),
                year: entry.year,
                detail: "\(sourceLabel) · \(detail)",
                isAutomaticallyFollowed: isAutomatic
            )
        }

        let manualRows = manualFollows.map { storageKey, entry -> CalendarSuggestionItem in
            let resolved = resolvedManualFollows.first { CalendarManualFollowStore.sameTitle($0.value, entry) }
            let automatic = resolved.flatMap { resolvedEntry in
                automaticFollows[resolvedEntry.key].map { item in (key: resolvedEntry.key, value: item) }
            }
                ?? automaticFollows.first { CalendarManualFollowStore.sameTitle($0.value, entry) }
            let matchKey = resolved?.key ?? automatic?.key ?? storageKey
            let skip = skipped.values.first { CalendarManualFollowStore.sameTitle($0.item, entry) }
            return item(
                key: storageKey,
                entry: entry,
                resultKey: matchKey,
                isManual: true,
                isAutomatic: automatic != nil,
                skippedItem: skip
            )
        }

        let automaticRows = automaticFollows.compactMap { resultKey, entry -> CalendarSuggestionItem? in
            let stillManuallyFollowed = resolvedManualFollows[resultKey].map { resolved in
                manualFollows.values.contains { CalendarManualFollowStore.sameTitle($0, resolved) }
            } ?? false
            guard !stillManuallyFollowed,
                  !manualFollows.values.contains(where: { CalendarManualFollowStore.sameTitle($0, entry) }) else { return nil }
            let skip = skipped.values.first { CalendarManualFollowStore.sameTitle($0.item, entry) }
            return item(
                key: CalendarManualFollowStore.key(for: entry),
                entry: entry,
                resultKey: resultKey,
                isManual: false,
                isAutomatic: true,
                skippedItem: skip
            )
        }

        return (manualRows + automaticRows)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Keys used by skipped-title rows in the result.
    static func skippedKey(_ skip: CalendarSkippedItem) -> String { "skipped:\(skip.id)" }
}
