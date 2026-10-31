import Foundation

// App-only: builds shelf entries from the app's metadata, and gives the shelf
// the app's ratings. The extension target compiles only TopShelfFeed.swift and
// TopShelfLayout.swift, which stay free of app model types.

extension TopShelfEntry {
    /// A shelf entry for `meta`, carrying what the carousel details show.
    init(meta: NuvioMeta, subtitle: String?, progress: Double?, action: TopShelfEntryAction,
         airDate: String? = nil) {
        self.init(
            contentId: meta.id,
            contentType: meta.type,
            title: meta.name,
            subtitle: subtitle,
            imageURL: meta.posterUrl,
            backdropURL: meta.backdropUrl,
            progress: progress,
            action: action,
            summary: Self.nonEmpty(meta.description),
            genres: meta.genres.map { Array($0.prefix(3)) }.flatMap { $0.isEmpty ? nil : $0 },
            year: meta.year,
            releaseDate: Self.nonEmpty(meta.released),
            runtimeMinutes: Self.runtimeMinutes(meta.runtime),
            logoURL: Self.nonEmpty(meta.logoUrl),
            cast: meta.cast.map { Array($0.prefix(4)) }.flatMap { $0.isEmpty ? nil : $0 },
            directors: meta.director.map { Array($0.prefix(2)) }.flatMap { $0.isEmpty ? nil : $0 },
            airDate: airDate,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId,
            imdbRating: meta.rating.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        )
    }

    /// Minutes from the metadata's runtime text: "142 min", "2h 22m",
    /// "2 hr 22 min", "1:58" or a bare number of minutes.
    static func runtimeMinutes(_ runtime: String?) -> Int? {
        guard let text = runtime?.lowercased(), !text.isEmpty else { return nil }
        let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap(Int.init)
        guard let first = numbers.first else { return nil }
        let hasHours = text.contains("h") || text.contains(":")
        let minutes = hasHours ? first * 60 + (numbers.dropFirst().first ?? 0) : first
        return minutes > 0 ? minutes : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Mirrors Home's Today row (the calendar's titles coming out today) for the
/// shelf. Library metadata supplies the backdrop, logo and summary the
/// calendar's compact cards lack.
enum TopShelfTodayFeed {
    private static let lock = NSLock()
    private static var lastWritten: [String]?

    static func write(_ row: CalendarHomeToday) {
        guard TopShelfFeedStore.isAvailable else { return }
        let library = Dictionary(
            LibraryStore.items().map { ($0.meta.id, $0.meta) },
            uniquingKeysWith: { first, _ in first })
        let entries: [TopShelfEntry] = row.metas.prefix(15).compactMap { compact in
            guard let calendarEntry = row.entries[compact.id] else { return nil }
            let label = row.labels[compact.id]
            let subtitle = [label?.episode, label?.badge].compactMap { $0 }.joined(separator: "  ·  ")
            return TopShelfEntry(
                meta: library[compact.id] ?? compact,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                progress: nil,
                action: .details,
                airDate: calendarEntry.date.iso)
        }
        // The calendar republishes often; write only what changed.
        let signature = entries.map { "\($0.contentId)|\($0.subtitle ?? "")|\($0.airDate ?? "")|\($0.backdropURL ?? "")" }
        lock.lock()
        let isNew = signature != lastWritten
        lastWritten = signature
        lock.unlock()
        guard isNew else { return }
        TopShelfFeedStore.write(
            entries, section: .today,
            title: L10n.string("tvos_settings_topshelf_today", fallback: "Today"))
    }
}

/// The carousel's ratings: the ones the Home hero shows (its rating setting),
/// from the providers enabled in Settings, in the user's order, with the
/// icons Details uses.
enum TopShelfRatingsBridge {
    static let maximumBadges = 5

    static func install() {
        TopShelfFeedStore.ratingsProvider = { entry in
            await badges(for: entry)
        }
    }

    static func badges(for entry: TopShelfEntry) async -> [TopShelfRatingBadge] {
        let source = (ProfileSettings.current.string(forKey: SettingsKey.homeHeroRatingSource) ?? "imdb")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let meta = NuvioMeta(
            id: entry.contentId,
            name: entry.title,
            imdbId: entry.imdbId,
            tmdbId: entry.tmdbId,
            type: entry.contentType,
            rating: entry.imdbRating)
        let fetched = AddonRatingsService.heroNeedsFetchedRatings(source: source, meta: meta)
            ? await AddonRatingsService.fetchHomeHeroRatings(for: meta)
            : nil
        let ratings = AddonRatingsService.heroDisplayRatings(for: meta, fetched: fetched)
            .filter { AddonRatingsService.isSourceEnabled($0.source) }
        var badges = TvRatingBadge.badges(from: ratings)
        if !AddonRatingsService.heroShowsAllRatings(source) {
            // One score, as the hero: the chosen source, else IMDb.
            let wanted = AddonRatingsService.normalizedSourceKey(source.isEmpty ? "imdb" : source)
            let imdb = AddonRatingsService.normalizedSourceKey(MdbListDetailsService.providerIMDb)
            let chosen = badges.first { AddonRatingsService.normalizedSourceKey($0.rating.source) == wanted }
                ?? badges.first { AddonRatingsService.normalizedSourceKey($0.rating.source) == imdb }
            badges = chosen.map { [$0] } ?? []
        }
        return badges.prefix(maximumBadges).map { badge in
            TopShelfRatingBadge(
                source: badge.rating.source,
                name: badge.visual.displayName,
                value: badge.formattedValue,
                iconAssetName: badge.visual.assetName,
                iconURL: badge.visual.iconUrl?.absoluteString,
                iconWidth: Double(badge.visual.iconWidth))
        }
    }
}
