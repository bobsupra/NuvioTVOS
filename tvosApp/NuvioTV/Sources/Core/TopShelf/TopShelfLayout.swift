import Foundation

// MARK: - Top Shelf layout
//
// What the Apple TV home screen shows for the app: which mirrored sections and
// Home catalogs, and as a carousel or as rows. The app owns the choice (Settings
// → Top Shelf) and mirrors it into the App Group next to the feeds; the Top
// Shelf extension and the artwork renderer compose the same layout from it.
// Shared with the extension target, so free of app model types.

/// The user's Top Shelf choice. Device-wide: the shelf is one per Apple TV.
public struct TopShelfConfiguration: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Full-screen carousel with the summary, genre, year and length.
        case carouselDetails
        /// Full-screen carousel with the title and the two buttons only.
        case carouselActions
        /// Labeled rows of 16:9 cards, one per source.
        case rows
        /// Labeled rows of 2:3 posters, one per source (the shelf before the
        /// 16:9 cards).
        case posters

        public var isCarousel: Bool { self == .carouselDetails || self == .carouselActions }
    }

    public var style: Style
    public var includesContinueWatching: Bool
    public var includesUpNext: Bool
    /// Up Next shares the Continue Watching row, in Home's order, as on Home.
    public var mergesUpNext: Bool
    /// The calendar's titles coming out today.
    public var includesToday: Bool
    public var includesLibrary: Bool
    /// Home catalog rows to show, by row id, in Home order. Nil: the first Home
    /// catalog (the shelf before this setting). Empty: no catalog.
    public var catalogRowIDs: [String]?
    /// Carousel only: play the title's trailer when its item stays in focus.
    public var playsTrailers: Bool
    /// Localized attribute names for the carousel details. The extension has no
    /// string catalog of its own.
    public var starringLabel: String?
    public var directorLabel: String?

    public init(
        style: Style = .carouselDetails,
        includesContinueWatching: Bool = true,
        includesUpNext: Bool = true,
        mergesUpNext: Bool = false,
        includesToday: Bool = true,
        includesLibrary: Bool = true,
        catalogRowIDs: [String]? = nil,
        playsTrailers: Bool = true,
        starringLabel: String? = nil,
        directorLabel: String? = nil
    ) {
        self.style = style
        self.includesContinueWatching = includesContinueWatching
        self.includesUpNext = includesUpNext
        self.mergesUpNext = mergesUpNext
        self.includesToday = includesToday
        self.includesLibrary = includesLibrary
        self.catalogRowIDs = catalogRowIDs
        self.playsTrailers = playsTrailers
        self.starringLabel = starringLabel
        self.directorLabel = directorLabel
    }

    public static let `default` = TopShelfConfiguration()

    private enum CodingKeys: String, CodingKey {
        case style, includesContinueWatching, includesUpNext, mergesUpNext, includesToday, includesLibrary
        case catalogRowIDs, playsTrailers, starringLabel, directorLabel
    }

    /// Missing or unknown values fall back to the defaults, so a file written
    /// by another version still reads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TopShelfConfiguration.default
        style = (try? container.decodeIfPresent(Style.self, forKey: .style)) ?? fallback.style
        includesContinueWatching = (try? container.decodeIfPresent(Bool.self, forKey: .includesContinueWatching))
            ?? fallback.includesContinueWatching
        includesUpNext = (try? container.decodeIfPresent(Bool.self, forKey: .includesUpNext))
            ?? fallback.includesUpNext
        mergesUpNext = (try? container.decodeIfPresent(Bool.self, forKey: .mergesUpNext))
            ?? fallback.mergesUpNext
        includesToday = (try? container.decodeIfPresent(Bool.self, forKey: .includesToday))
            ?? fallback.includesToday
        includesLibrary = (try? container.decodeIfPresent(Bool.self, forKey: .includesLibrary))
            ?? fallback.includesLibrary
        catalogRowIDs = (try? container.decodeIfPresent([String].self, forKey: .catalogRowIDs)) ?? nil
        playsTrailers = (try? container.decodeIfPresent(Bool.self, forKey: .playsTrailers))
            ?? fallback.playsTrailers
        starringLabel = (try? container.decodeIfPresent(String.self, forKey: .starringLabel)) ?? nil
        directorLabel = (try? container.decodeIfPresent(String.self, forKey: .directorLabel)) ?? nil
    }
}

/// Keeps the configuration in the app's own defaults (Caches can be purged)
/// and mirrors it into the App Group, where the extension reads it.
public enum TopShelfConfigurationStore {
    static let defaultsKey = "topShelf.configuration"
    static let fileName = "config.json"

    /// The app's saved choice, else the mirrored file (all the extension has),
    /// else the defaults.
    public static func load() -> TopShelfConfiguration {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let configuration = try? JSONDecoder().decode(TopShelfConfiguration.self, from: data) {
            return configuration
        }
        if let directory = TopShelfFeedStore.containerURL, let configuration = read(in: directory) {
            return configuration
        }
        return .default
    }

    /// Saves the choice and redraws the shelf with it.
    public static func save(_ configuration: TopShelfConfiguration) {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if let directory = TopShelfFeedStore.containerURL {
            write(configuration, in: directory)
        }
        TopShelfFeedStore.refreshArtwork()
    }

    /// Keeps the carousel's attribute names in the app's language. No redraw:
    /// the app calls this right before writing a feed, which redraws.
    public static func setLabels(starring: String, director: String) {
        var configuration = load()
        guard configuration.starringLabel != starring || configuration.directorLabel != director else { return }
        configuration.starringLabel = starring
        configuration.directorLabel = director
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if let directory = TopShelfFeedStore.containerURL {
            write(configuration, in: directory)
        }
    }

    static func read(in directory: URL) -> TopShelfConfiguration? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TopShelfConfiguration.self, from: data)
    }

    static func write(_ configuration: TopShelfConfiguration, in directory: URL) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        TopShelfArtworkPruner.withFeedLock {
            try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
    }

    /// Restores the mirror when the system purged it, or the app's choice
    /// changed while the container was unavailable.
    static func mirror(_ configuration: TopShelfConfiguration, in directory: URL) {
        guard read(in: directory) != configuration else { return }
        write(configuration, in: directory)
    }
}

/// One source on the shelf: a mirrored section, or one Home catalog row.
public struct TopShelfRow: Equatable, Sendable {
    /// `continueWatching`, `upNext`, `library` or `catalog:<Home row id>`.
    public let id: String
    public let section: TopShelfSection
    public let title: String?
    public let entries: [TopShelfEntry]
}

/// A carousel slot and the row it was picked from.
public struct TopShelfCarouselEntry: Equatable, Sendable {
    public let rowID: String
    public let rowTitle: String?
    public let section: TopShelfSection
    public let entry: TopShelfEntry
}

public enum TopShelfComposer {
    /// A carousel is swiped one item at a time; more than this is a chore.
    public static let carouselLimit = 15
    /// Each chosen source gets at least this many carousel slots before any
    /// source gets more.
    public static let carouselMinimumShare = 3

    /// The chosen sources in shelf order: Continue Watching, Up Next, Today,
    /// Library, then the chosen Home catalogs in Home order. Empty sources are
    /// left out, and so are Today's titles once their day (`today`) passed.
    /// Merged, Up Next joins the Continue Watching row and has none of its own.
    public static func rows(
        configuration: TopShelfConfiguration,
        today: String = TopShelfComposer.day(of: Date()),
        feed: (TopShelfSection) -> TopShelfFeed?
    ) -> [TopShelfRow] {
        var rows: [TopShelfRow] = []
        let fixed: [(TopShelfSection, Bool)] = [
            (.continueWatching, configuration.includesContinueWatching),
            (.upNext, configuration.includesUpNext && !configuration.mergesUpNext),
            (.today, configuration.includesToday),
            (.library, configuration.includesLibrary),
        ]
        for (section, included) in fixed {
            guard included else { continue }
            if section == .continueWatching, configuration.mergesUpNext {
                let inProgress = feed(.continueWatching)
                let entries = homeOrdered(inProgress?.entries ?? [], feed(.upNext)?.entries ?? [])
                guard !entries.isEmpty else { continue }
                rows.append(TopShelfRow(
                    id: section.rawValue, section: section, title: inProgress?.title, entries: entries))
                continue
            }
            guard let sectionFeed = feed(section) else { continue }
            let entries = section == .today
                ? sectionFeed.entries.filter { $0.airDate == nil || $0.airDate == today }
                : sectionFeed.entries
            guard !entries.isEmpty else { continue }
            rows.append(TopShelfRow(
                id: section.rawValue, section: section, title: sectionFeed.title, entries: entries))
        }
        guard let catalogFeed = feed(.catalog) else { return rows }
        let available = catalogFeed.catalogRows.filter { !$0.entries.isEmpty }
        let chosen: [TopShelfFeedRow]
        if let ids = configuration.catalogRowIDs {
            let selected = Set(ids)
            let matching = available.filter { selected.contains($0.id) }
            // Chosen catalogs that left Home: the first one, rather than none.
            chosen = ids.isEmpty ? [] : (matching.isEmpty ? Array(available.prefix(1)) : matching)
        } else {
            chosen = Array(available.prefix(1))
        }
        for row in chosen {
            rows.append(TopShelfRow(
                id: "\(TopShelfSection.catalog.rawValue):\(row.id)",
                section: .catalog, title: row.title, entries: row.entries))
        }
        return rows
    }

    /// Continue Watching and Up Next as one list, in the order Home shows them.
    /// Feeds written before that order was kept: in progress first.
    static func homeOrdered(_ inProgress: [TopShelfEntry], _ upNext: [TopShelfEntry]) -> [TopShelfEntry] {
        var seen = Set<String>()
        let combined = (inProgress + upNext).filter { seen.insert($0.contentId).inserted }
        guard combined.allSatisfy({ $0.homeOrder != nil }) else { return combined }
        return combined.enumerated()
            .sorted { ($0.element.homeOrder ?? 0, $0.offset) < ($1.element.homeOrder ?? 0, $1.offset) }
            .map(\.element)
    }

    /// The local calendar day of `date`, as Today entries carry it.
    public static func day(of date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Carousel slots: every source gets its share first, then the remaining
    /// slots go round the sources in turn. A title already picked is skipped.
    /// Slots stay grouped by source in shelf order.
    public static func carousel(
        from rows: [TopShelfRow],
        limit: Int = carouselLimit
    ) -> [TopShelfCarouselEntry] {
        guard !rows.isEmpty, limit > 0 else { return [] }
        let share = max(carouselMinimumShare, limit / rows.count)
        var picked = Array(repeating: [TopShelfEntry](), count: rows.count)
        var cursors = Array(repeating: 0, count: rows.count)
        var seen = Set<String>()
        var total = 0

        func takeNext(from index: Int) -> Bool {
            let entries = rows[index].entries
            while cursors[index] < entries.count {
                let entry = entries[cursors[index]]
                cursors[index] += 1
                guard seen.insert(entry.contentId).inserted else { continue }
                picked[index].append(entry)
                total += 1
                return true
            }
            return false
        }

        for index in rows.indices {
            while picked[index].count < share, total < limit, takeNext(from: index) {}
        }
        var progressed = true
        while total < limit, progressed {
            progressed = false
            for index in rows.indices where total < limit {
                if takeNext(from: index) { progressed = true }
            }
        }
        return rows.indices.flatMap { index in
            picked[index].map {
                TopShelfCarouselEntry(
                    rowID: rows[index].id, rowTitle: rows[index].title,
                    section: rows[index].section, entry: $0)
            }
        }
    }

    /// The entries that get artwork rendered for the configured style: the
    /// carousel's picks, else every row's entries.
    public static func displayedEntries(
        configuration: TopShelfConfiguration,
        rows: [TopShelfRow]
    ) -> [TopShelfEntry] {
        configuration.style.isCarousel
            ? carousel(from: rows).map(\.entry)
            : rows.flatMap(\.entries)
    }
}
