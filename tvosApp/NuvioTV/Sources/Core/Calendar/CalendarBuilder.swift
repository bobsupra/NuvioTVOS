import Foundation

/// Pure functions that turn TMDB responses into calendar entries. No I/O,
/// so everything here is covered by unit tests.
enum CalendarBuilder {
    static let maxSeasonsPerShow = 3

    // MARK: Period

    /// The period the calendar loads: the start of the previous month up to
    /// the end of the month `monthsAhead` months after `today`.
    static func period(today: CalendarDay, monthsBack: Int = 1, monthsAhead: Int = 2) -> (first: CalendarDay, last: CalendarDay) {
        let first = today.firstOfMonth.addingMonths(-monthsBack)
        let last = today.firstOfMonth.addingMonths(monthsAhead).lastOfMonth
        return (first, last)
    }

    /// Cells of a month grid, row by row: `nil` for the blanks before the
    /// first day, then every day of the month, padded to whole weeks.
    static func monthGrid(for month: CalendarDay, firstWeekday: Int) -> [CalendarDay?] {
        let first = month.firstOfMonth
        let leading = (first.weekday - firstWeekday + 7) % 7
        var cells: [CalendarDay?] = Array(repeating: nil, count: leading)
        for offset in 0..<first.daysInMonth {
            cells.append(first.adding(days: offset))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    /// Weekday numbers (1 = Sunday) in display order.
    static func weekdayOrder(firstWeekday: Int) -> [Int] {
        (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
    }

    // MARK: Series

    /// Seasons worth fetching for a show: the season of the last aired and the
    /// next announced episode when they fall in the period, plus any season
    /// whose premiere does.
    static func seasonsToFetch(for details: CalendarTmdb.TvDetails, first: CalendarDay, last: CalendarDay) -> [Int] {
        var seasons = Set<Int>()
        if let next = details.nextEpisodeToAir,
           let number = next.seasonNumber, number > 0,
           let date = CalendarDay(iso: next.airDate),
           date <= last {
            seasons.insert(number)
        }
        if let previous = details.lastEpisodeToAir,
           let number = previous.seasonNumber, number > 0,
           let date = CalendarDay(iso: previous.airDate),
           date >= first {
            seasons.insert(number)
        }
        for season in details.seasons ?? [] {
            guard let number = season.seasonNumber, number > 0,
                  let premiere = CalendarDay(iso: season.airDate),
                  premiere >= first, premiere <= last else { continue }
            seasons.insert(number)
        }
        return Array(seasons.sorted().suffix(maxSeasonsPerShow))
    }

    static func episodeEntries(
        item: CalendarItem,
        details: CalendarTmdb.TvDetails,
        episodes: [CalendarTmdb.Episode],
        first: CalendarDay,
        last: CalendarDay
    ) -> [CalendarEntry] {
        // A library name in Japanese/Chinese/Korean script gives way to the
        // readable (localized or English) TMDB name.
        let libraryName = CalendarText.readableLibraryTitle(item.name)
        let title = libraryName.flatMap { CalendarText.isNonLatin($0) ? nil : $0 }
            ?? details.readableName
            ?? libraryName ?? nonEmpty(details.name) ?? item.id
        let poster = CalendarTmdb.imageURL(details.posterPath, size: "w342")
            ?? item.posterURL.flatMap(URL.init(string:))
        var seen = Set<String>()
        var result: [CalendarEntry] = []
        for episode in episodes {
            guard let number = episode.episodeNumber,
                  let season = episode.seasonNumber, season > 0,
                  let date = CalendarDay(iso: episode.airDate),
                  date >= first, date <= last else { continue }
            var entry = CalendarEntry(
                itemId: item.id,
                itemType: item.type,
                kind: .series,
                tmdbId: details.id,
                title: title,
                date: date,
                releaseKind: releaseKind(for: episode, season: season, number: number),
                seasonNumber: season,
                episodeNumber: number,
                // Untranslated episode titles come back in Japanese; leave them out.
                episodeName: nonEmpty(episode.name).flatMap { CalendarText.isNonLatin($0) ? nil : $0 },
                overview: nonEmpty(episode.overview),
                posterURL: poster,
                stillURL: CalendarTmdb.imageURL(episode.stillPath, size: "w500")
            )
            entry.isAnime = details.isJapaneseAnime
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result
    }

    static func releaseKind(for episode: CalendarTmdb.Episode, season: Int, number: Int) -> CalendarReleaseKind {
        if season == 0 { return .episode }
        if number == 1 { return season == 1 ? .seriesPremiere : .seasonPremiere }
        if episode.episodeType?.lowercased() == "finale" { return .seasonFinale }
        return .episode
    }

    // MARK: Movies

    /// Release-date types the calendar shows, with the label they map to.
    static let movieReleaseTypes: [Int: CalendarReleaseKind] = [3: .theatrical, 4: .digital, 5: .physical]

    /// Releases of a movie in `region` inside the period. When TMDB has no
    /// theatrical, digital or physical date for that region, `fallbackRegion`
    /// is used, and as a last resort the movie's primary release date.
    static func movieEntries(
        item: CalendarItem,
        details: CalendarTmdb.MovieDetails,
        region: String,
        fallbackRegion: String = "US",
        first: CalendarDay,
        last: CalendarDay
    ) -> [CalendarEntry] {
        let countries = details.releaseDates?.results ?? []

        func releases(in country: String) -> [(CalendarDay, CalendarReleaseKind)] {
            let dates = countries.first { $0.country?.uppercased() == country.uppercased() }?.releaseDates ?? []
            return dates.compactMap { release in
                guard let type = release.type, let kind = movieReleaseTypes[type],
                      let day = CalendarDay(iso: release.releaseDate) else { return nil }
                return (day, kind)
            }
        }

        var candidates = releases(in: region)
        if candidates.isEmpty, fallbackRegion.uppercased() != region.uppercased() {
            candidates = releases(in: fallbackRegion)
        }
        if candidates.isEmpty, let primary = CalendarDay(iso: details.releaseDate) {
            candidates = [(primary, .release)]
        }

        let title = CalendarText.readableLibraryTitle(item.name) ?? nonEmpty(details.title) ?? item.id
        let poster = CalendarTmdb.imageURL(details.posterPath, size: "w342")
            ?? item.posterURL.flatMap(URL.init(string:))
        let backdrop = CalendarTmdb.imageURL(details.backdropPath, size: "w500")
        var seen = Set<String>()
        var result: [CalendarEntry] = []
        for (day, kind) in candidates.sorted(by: { $0.0 < $1.0 }) where day >= first && day <= last {
            let entry = CalendarEntry(
                itemId: item.id,
                itemType: item.type,
                kind: .movie,
                tmdbId: details.id,
                title: title,
                date: day,
                releaseKind: kind,
                overview: nonEmpty(details.overview),
                posterURL: poster,
                stillURL: backdrop
            )
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: Grouping

    static func groupByDay(_ entries: [CalendarEntry]) -> [CalendarDaySection] {
        Dictionary(grouping: entries, by: \.date)
            .map { date, items in
                CalendarDaySection(date: date, entries: items.sorted(by: entryOrder))
            }
            .sorted { $0.date < $1.date }
    }

    static func entryOrder(_ a: CalendarEntry, _ b: CalendarEntry) -> Bool {
        // Titles with a known broadcast time first, in airing order.
        switch (a.airTime, b.airTime) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        let titleOrder = a.title.localizedCaseInsensitiveCompare(b.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        if (a.seasonNumber ?? 0) != (b.seasonNumber ?? 0) { return (a.seasonNumber ?? 0) < (b.seasonNumber ?? 0) }
        if (a.episodeNumber ?? 0) != (b.episodeNumber ?? 0) { return (a.episodeNumber ?? 0) < (b.episodeNumber ?? 0) }
        return a.id < b.id
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
