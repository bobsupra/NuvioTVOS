import TVServices

/// Populates the Apple TV home-screen Top Shelf from the sections the main app
/// mirrors into the shared App Group (Continue Watching, Up Next, Library and
/// the Home catalog rows), laid out as chosen in the app's Settings: a
/// full-screen carousel or labeled rows. Reads `TopShelfFeedStore` and
/// `TopShelfComposer` (`TopShelfFeed.swift`, `TopShelfLayout.swift`).
final class TopShelfContentProvider: TVTopShelfContentProvider {
    /// Headings used when the app didn't supply one.
    private static let fallbackTitles: [TopShelfSection: String] = [
        .continueWatching: "Continue Watching",
        .upNext: "Up Next",
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
            let items = TopShelfComposer.carousel(from: rows).map { Self.carouselItem(for: $0, configuration: configuration) }
            guard !items.isEmpty else {
                completionHandler(nil)
                return
            }
            let style: TVTopShelfCarouselContent.Style = configuration.style == .carouselDetails ? .details : .actions
            completionHandler(TVTopShelfCarouselContent(style: style, items: items))
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

    private static func carouselItem(
        for slot: TopShelfCarouselEntry,
        configuration: TopShelfConfiguration
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

        // The rendered image carries the logo; the raw backdrop stands in until it exists.
        let imageURL = TopShelfFeedStore.carouselArtworkURL(for: entry)
            ?? entry.artworkSourceURL.flatMap(URL.init(string:))
        if let url = imageURL {
            item.setImageURL(url, for: .screenScale1x)
            item.setImageURL(url, for: .screenScale2x)
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
