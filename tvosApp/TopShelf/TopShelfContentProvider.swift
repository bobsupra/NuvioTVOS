import TVServices

/// Populates the Apple TV home-screen Top Shelf from the sections the main app
/// mirrors into the shared App Group (Continue Watching, Up Next, Library and
/// the Home catalog rows), laid out as chosen in the app's Settings: a
/// full-screen carousel, which can play each title's trailer, or labeled rows.
/// Reads `TopShelfFeedStore` and `TopShelfComposer` (`TopShelfFeed.swift`,
/// `TopShelfLayout.swift`); trailers come from `TopShelfTrailerResolver`
/// (`TopShelfTrailers.swift`).
final class TopShelfContentProvider: TVTopShelfContentProvider {
    /// Headings used when the app didn't supply one.
    private static let fallbackTitles: [TopShelfSection: String] = [
        .continueWatching: "Continue Watching",
        .upNext: "Up Next",
        .today: "Today",
        .library: "Library",
        .catalog: "Popular",
    ]

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let configuration = TopShelfConfigurationStore.load()
        let rows = TopShelfComposer.rows(configuration: configuration) { TopShelfFeedStore.read($0) }
        guard !rows.isEmpty else {
            completionHandler(nil)
            return
        }
        switch configuration.style {
        case .carouselDetails, .carouselActions:
            let slots = TopShelfComposer.carousel(from: rows)
            guard !slots.isEmpty else {
                completionHandler(nil)
                return
            }
            let ratings = TopShelfFeedStore.savedRatings()
            guard configuration.playsTrailers else {
                completionHandler(Self.carousel(slots, configuration: configuration, ratings: ratings, trailers: [:]))
                return
            }
            // The system plays the trailers itself and says nothing when an
            // item gains focus, so their links are looked up now, as the shelf
            // loads, rather than taken from days ago.
            Task {
                let trailers = await TopShelfTrailerResolver.trailers(
                    for: slots.map(\.entry), in: TopShelfFeedStore.containerURL)
                completionHandler(Self.carousel(slots, configuration: configuration, ratings: ratings, trailers: trailers))
            }
        case .rows:
            let collections = rows.map { row -> TVTopShelfItemCollection<TVTopShelfSectionedItem> in
                let collection = TVTopShelfItemCollection(items: row.entries.map { Self.sectionedItem(for: $0, rowID: row.id) })
                collection.title = row.title ?? Self.fallbackTitles[row.section]
                return collection
            }
            completionHandler(TVTopShelfSectionedContent(sections: collections))
        }
    }

    private static func sectionedItem(for entry: TopShelfEntry, rowID: String) -> TVTopShelfSectionedItem {
        // A title can sit on more than one row (e.g. Library and a catalog).
        let item = TVTopShelfSectionedItem(identifier: "\(rowID):\(entry.contentId)")
        item.title = entry.title
        item.imageShape = .hdtv

        let imageURL = TopShelfFeedStore.artworkURL(for: entry)
            ?? entry.artworkSourceURL.flatMap(URL.init(string:))
        if let url = imageURL {
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
        }
        if let progress = entry.progress {
            item.playbackProgress = progress
        }
        if let link = entry.deepLinkURL {
            let action = TVTopShelfAction(url: link)
            item.displayAction = action
            item.playAction = action
        }
        return item
    }

    private static func carousel(
        _ slots: [TopShelfCarouselEntry],
        configuration: TopShelfConfiguration,
        ratings: [String: TopShelfRatingsStore.Record],
        trailers: [String: TopShelfTrailerLink]
    ) -> TVTopShelfCarouselContent {
        let style: TVTopShelfCarouselContent.Style = configuration.style == .carouselDetails ? .details : .actions
        let items = slots.map {
            carouselItem(for: $0, configuration: configuration, ratings: ratings, trailer: trailers[$0.entry.contentId])
        }
        return TVTopShelfCarouselContent(style: style, items: items)
    }

    private static func carouselItem(
        for slot: TopShelfCarouselEntry,
        configuration: TopShelfConfiguration,
        ratings: [String: TopShelfRatingsStore.Record],
        trailer: TopShelfTrailerLink?
    ) -> TVTopShelfCarouselItem {
        let entry = slot.entry
        let item = TVTopShelfCarouselItem(identifier: "\(slot.rowID):\(entry.contentId)")
        item.title = entry.title
        // Why it is here: the row, and for a resumable title the episode and time left.
        let rowTitle = slot.rowTitle ?? fallbackTitles[slot.section]
        item.contextTitle = [rowTitle, entry.subtitle].compactMap { $0 }.joined(separator: "  ·  ")
        item.summary = entry.summary
        if let genres = entry.genres, !genres.isEmpty {
            item.genre = genres.prefix(2).joined(separator: ", ")
        }
        if let minutes = entry.runtimeMinutes {
            item.duration = TimeInterval(minutes * 60)
        }
        item.creationDate = releaseDate(of: entry)
        var attributes: [TVTopShelfNamedAttribute] = []
        if let cast = entry.cast, !cast.isEmpty {
            attributes.append(TVTopShelfNamedAttribute(name: configuration.starringLabel ?? "Starring", values: cast))
        }
        if let directors = entry.directors, !directors.isEmpty {
            attributes.append(TVTopShelfNamedAttribute(name: configuration.directorLabel ?? "Director", values: directors))
        }
        item.namedAttributes = attributes

        // The rendered image carries the logo and the ratings; the raw backdrop
        // stands in until it exists.
        let imageURL = TopShelfFeedStore.carouselArtworkURL(for: entry, ratings: ratings)
            ?? entry.artworkSourceURL.flatMap(URL.init(string:))
        if let url = imageURL {
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
        }
        // Played over the image once the item stays in focus.
        if let trailer, let url = URL(string: trailer.url) {
            item.previewVideoURL = url
        }
        // More Info opens the details page; Play resumes what can be resumed.
        if let details = entry.detailsURL {
            item.displayAction = TVTopShelfAction(url: details)
        }
        if let play = entry.deepLinkURL {
            item.playAction = TVTopShelfAction(url: play)
        }
        return item
    }

    /// The metadata's release date, else the first of the release year.
    private static func releaseDate(of entry: TopShelfEntry) -> Date? {
        if let text = entry.releaseDate {
            let full = ISO8601DateFormatter()
            full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = full.date(from: text) { return date }
            full.formatOptions = [.withInternetDateTime]
            if let date = full.date(from: text) { return date }
            full.formatOptions = [.withFullDate]
            if let date = full.date(from: String(text.prefix(10))) { return date }
        }
        guard let year = entry.year else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1, hour: 12))
    }
}
