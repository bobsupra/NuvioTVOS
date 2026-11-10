import Foundation

/// A calendar day without a time or time zone ("2026-10-19").
///
/// TMDB publishes air dates as plain dates, so the calendar keeps them as
/// plain dates too instead of turning them into instants in some time zone.
struct CalendarDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "yyyy-MM-dd", also accepting a longer ISO-8601 string
    /// ("2026-10-30T00:00:00.000Z") by reading only its date part.
    init?(iso: String?) {
        guard let raw = iso?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d),
              CalendarDay.isValid(year: y, month: m, day: d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The day `date` falls on in `timeZone` (the device's zone by default).
    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var description: String { iso }

    var firstOfMonth: CalendarDay { CalendarDay(year: year, month: month, day: 1) }

    var lastOfMonth: CalendarDay { firstOfMonth.addingMonths(1).adding(days: -1) }

    var daysInMonth: Int { lastOfMonth.day }

    /// 1 = Sunday … 7 = Saturday, as in `Calendar.firstWeekday`.
    var weekday: Int {
        CalendarDay.utc.component(.weekday, from: utcDate)
    }

    func adding(days: Int) -> CalendarDay {
        guard let moved = CalendarDay.utc.date(byAdding: .day, value: days, to: utcDate) else { return self }
        return CalendarDay(date: moved, timeZone: CalendarDay.utc.timeZone)
    }

    /// Same day number clamped to the target month ("Jan 31 + 1 month" → Feb 28).
    func addingMonths(_ months: Int) -> CalendarDay {
        let total = (year * 12 + (month - 1)) + months
        let y = total / 12
        let m = total % 12 + 1
        let first = CalendarDay(year: y, month: m, day: 1)
        let last = CalendarDay.utc.range(of: .day, in: .month, for: first.utcDate)?.count ?? 28
        return CalendarDay(year: y, month: m, day: min(day, last))
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    func days(until other: CalendarDay) -> Int {
        CalendarDay.utc.dateComponents([.day], from: utcDate, to: other.utcDate).day ?? 0
    }

    func isSameMonth(as other: CalendarDay) -> Bool {
        year == other.year && month == other.month
    }

    /// Noon UTC of this day; safe to format in UTC without slipping to a
    /// neighbouring day.
    /// Midnight at the start of this day in `timeZone`.
    func startDate(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? noonDate
    }

    var noonDate: Date {
        CalendarDay.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    private var utcDate: Date {
        CalendarDay.utc.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard let date = utc.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return c.year == year && c.month == month && c.day == day
    }
}

enum CalendarMediaKind: String, Codable, Hashable, Sendable {
    case series
    case movie
}

/// One library title the calendar looks at, identified the way Nuvio
/// identifies it ("tt0903747", "tmdb:1396", ...).
struct CalendarItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: CalendarMediaKind
    var sourceIdentityKey: String { "\(kind.rawValue):\(id)" }
    /// The library item's own type ("series", "anime", ...), used to reopen it.
    var type: String
    var name: String?
    var posterURL: String?
    /// Release year, used to skip movies that are long out.
    var year: Int?
    /// Retained for manual follows so the calendar can resolve a title even
    /// when its preferred id is IMDb or a source-specific id.
    var imdbId: String?
    var tmdbId: Int?

    init(id: String, kind: CalendarMediaKind, type: String = "", name: String? = nil,
         posterURL: String? = nil, year: Int? = nil, imdbId: String? = nil, tmdbId: Int? = nil) {
        self.id = id
        self.kind = kind
        self.type = type
        self.name = name
        self.posterURL = posterURL
        self.year = year
        self.imdbId = imdbId
        self.tmdbId = tmdbId
    }
}

enum CalendarTimeSource: String, Codable, Hashable, Sendable {
    case anilist
    case tvmaze
}

enum CalendarReleaseKind: String, Codable, Hashable, Sendable {
    case episode
    case seasonPremiere
    case seriesPremiere
    case seasonFinale
    case theatrical
    case digital
    case physical
    case release
}

struct CalendarEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let itemId: String
    let itemType: String
    let kind: CalendarMediaKind
    let tmdbId: Int
    let title: String
    /// Local day it comes out. Anime may be moved off TMDB's Japanese date.
    var date: CalendarDay
    let releaseKind: CalendarReleaseKind
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeName: String?
    let overview: String?
    let posterURL: URL?
    let stillURL: URL?
    /// Japanese anime, eligible for broadcast times from AniList.
    var isAnime: Bool = false
    /// Exact broadcast time when known (anime from AniList, other series
    /// from TVmaze).
    var airTime: Date?
    /// Where `airTime` came from, to credit it.
    var airTimeSource: CalendarTimeSource?

    /// Straight from AniList (`CalendarAniList`, which keeps the negative AniList id as
    /// `tmdbId`): one entry per AniList season, numbered as AniList numbers it.
    var isFromAniList: Bool { tmdbId < 0 }

    /// "S2E6", or "E6" for an AniList entry.
    var episodeCode: String? {
        guard let season = seasonNumber, let episode = episodeNumber else { return nil }
        return isFromAniList ? "E\(episode)" : "S\(season)E\(episode)"
    }

    init(
        itemId: String,
        itemType: String = "",
        kind: CalendarMediaKind,
        tmdbId: Int,
        title: String,
        date: CalendarDay,
        releaseKind: CalendarReleaseKind,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        episodeName: String? = nil,
        overview: String? = nil,
        posterURL: URL? = nil,
        stillURL: URL? = nil
    ) {
        switch kind {
        case .series:
            self.id = "tv:\(tmdbId):\(seasonNumber ?? -1):\(episodeNumber ?? -1)"
        case .movie:
            self.id = "movie:\(tmdbId):\(releaseKind.rawValue):\(date.iso)"
        }
        self.itemId = itemId
        self.itemType = itemType
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.date = date
        self.releaseKind = releaseKind
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeName = episodeName
        self.overview = overview
        self.posterURL = posterURL
        self.stillURL = stillURL
    }
}

struct CalendarDaySection: Codable, Hashable, Identifiable, Sendable {
    var id: String { date.iso }
    let date: CalendarDay
    let entries: [CalendarEntry]
}

enum CalendarSkipReason: Codable, Hashable, Sendable {
    /// The id has a format the calendar cannot turn into a TMDB id.
    case unsupportedId
    case failed(String)
}

struct CalendarSkippedItem: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(item.kind.rawValue):\(item.id)" }
    let item: CalendarItem
    let reason: CalendarSkipReason
}

struct CalendarResult: Codable, Sendable {
    let firstDay: CalendarDay
    let lastDay: CalendarDay
    let days: [CalendarDaySection]
    let skipped: [CalendarSkippedItem]
    /// Manually followed titles matched on TMDB, keyed as "series:1396".
    var manualFollowKeys: Set<String> = []
    var manualFollowItems: [String: CalendarItem] = [:]
    /// Watched or in-progress titles followed automatically, keyed on TMDB.
    var automaticFollowItems: [String: CalendarItem] = [:]

    var entryCount: Int { days.reduce(0) { $0 + $1.entries.count } }

    func entries(on day: CalendarDay) -> [CalendarEntry] {
        days.first { $0.date == day }?.entries ?? []
    }
}

/// Asks Details to open a series with this episode selected.
struct DetailsEpisodeFocus: Hashable, Sendable {
    let metaID: String
    let season: Int
    let episode: Int
    /// When the episode airs, to find it when the addon numbers seasons
    /// differently from TMDB (Bleach TYBW is TMDB season 2 but a later
    /// season on Cinemeta).
    var airDate: CalendarDay? = nil

    /// Days an addon's release date may differ from TMDB's (time zones,
    /// Japanese vs local broadcast day).
    static let dateTolerance = 2

    /// The addon episode this focus means: the same season/episode when its
    /// date agrees (or no date is known), otherwise the episode released
    /// closest to the air date within the tolerance.
    func pick(from videos: [NuvioVideo]) -> NuvioVideo? {
        let exact = videos.first { $0.season == season && $0.episode == episode }
        guard let airDate else { return exact }
        func distance(_ video: NuvioVideo) -> Int? {
            guard let released = CalendarDay(iso: video.released) else { return nil }
            let gap = abs(released.days(until: airDate))
            return gap <= Self.dateTolerance ? gap : nil
        }
        if let exact, distance(exact) != nil { return exact }
        let byDate = videos
            .filter { $0.season > 0 }
            .compactMap { video in distance(video).map { (video, $0) } }
            .min { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                // Same distance: prefer the same episode number, then season.
                if (a.0.episode == episode) != (b.0.episode == episode) { return a.0.episode == episode }
                return a.0.season == season && b.0.season != season
            }
        return byDate?.0 ?? exact
    }
}
