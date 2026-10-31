import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(TVServices)
import TVServices
#endif

// MARK: - Top Shelf feed
//
// Compact, dependency-free snapshot of the user's Continue Watching row, written
// by the main app into an App Group container and read by the Top Shelf
// extension to populate the Apple TV home row. Kept free of app model types
// (NuvioMeta etc.) so the extension target can compile this file on its own.
//
// The tvOS counterpart of the Android app's `TvRecommendationManager`.

/// App Group shared between the app and the Top Shelf extension. Must match the
/// `com.apple.security.application-groups` entitlement on both targets.
/// The companion extension uses the main app's bundle identifier plus the
/// `.TopShelf` suffix. Derive the shared container from that base identifier
/// so locally signed builds with a different bundle ID keep their shelf feed.
public let topShelfAppGroupID: String = {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.nuvio.app.tv"
    let mainAppBundleID = bundleID.hasSuffix(".TopShelf")
        ? String(bundleID.dropLast(".TopShelf".count))
        : bundleID
    return "group.\(mainAppBundleID)"
}()

/// One Top Shelf row. Each section is mirrored to its own file so the stores
/// that own them (Continue Watching, Library, Home) write independently.
public enum TopShelfSection: String, Codable, CaseIterable, Sendable {
    case continueWatching
    case upNext
    /// The calendar's titles coming out today (Home's Today row).
    case today
    case library
    case catalog

    /// Continue Watching keeps the original filename so a feed written by an
    /// earlier build is still read until the app rewrites it.
    var feedFileName: String {
        self == .continueWatching ? "feed.json" : "feed-\(rawValue).json"
    }
}

/// What selecting a card does.
public enum TopShelfEntryAction: String, Codable, Sendable {
    /// Resume (or start the suggested episode) straight from the shelf.
    case resume
    /// Open the title's details page.
    case details
}

/// One card on the Top Shelf row.
public struct TopShelfEntry: Codable, Equatable, Sendable {
    public let contentId: String
    public let contentType: String
    public let title: String
    public let subtitle: String?
    public let imageURL: String?
    /// Landscape artwork preferred for the 16:9 shelf cards. Optional so feeds
    /// written by earlier versions remain readable.
    public let backdropURL: String?
    /// Filename of the locally rendered card with its episode/time overlay.
    /// Optional so feeds written by earlier versions remain readable.
    public internal(set) var artworkFileName: String?
    /// Filename of the locally rendered full-screen carousel image (backdrop
    /// with the title's logo).
    public internal(set) var carouselArtworkFileName: String?
    /// Fractional progress 0...1, drawn as the card's progress bar.
    public let progress: Double?
    /// Nil in feeds written before actions existed, which were all resumable.
    public let action: TopShelfEntryAction?

    // Carousel details. All optional: older feeds and sparse catalogs have none.
    public let summary: String?
    public let genres: [String]?
    public let year: Int?
    /// Release date as the metadata gives it (ISO 8601 date or date-time).
    public let releaseDate: String?
    public let runtimeMinutes: Int?
    public let logoURL: String?
    public let cast: [String]?
    public let directors: [String]?
    /// The day a Today entry comes out ("yyyy-MM-dd", local). The shelf drops
    /// it once that day has passed, even when the app was not opened.
    public let airDate: String?
    /// What the app needs to look up the title's ratings for the carousel.
    public let imdbId: String?
    public let tmdbId: Int?
    public let imdbRating: Double?

    public init(contentId: String, contentType: String, title: String,
                subtitle: String?, imageURL: String?, backdropURL: String? = nil,
                progress: Double?, action: TopShelfEntryAction = .resume,
                artworkFileName: String? = nil,
                summary: String? = nil, genres: [String]? = nil, year: Int? = nil,
                releaseDate: String? = nil, runtimeMinutes: Int? = nil,
                logoURL: String? = nil, cast: [String]? = nil, directors: [String]? = nil,
                carouselArtworkFileName: String? = nil, airDate: String? = nil,
                imdbId: String? = nil, tmdbId: Int? = nil, imdbRating: Double? = nil) {
        self.contentId = contentId
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.backdropURL = backdropURL
        self.progress = progress
        self.action = action
        self.artworkFileName = artworkFileName
        self.summary = summary
        self.genres = genres
        self.year = year
        self.releaseDate = releaseDate
        self.runtimeMinutes = runtimeMinutes
        self.logoURL = logoURL
        self.cast = cast
        self.directors = directors
        self.carouselArtworkFileName = carouselArtworkFileName
        self.airDate = airDate
        self.imdbId = imdbId
        self.tmdbId = tmdbId
        self.imdbRating = imdbRating
    }

    /// Artwork the card is rendered from: the backdrop, else the poster.
    var artworkSourceURL: String? {
        backdropURL ?? imageURL
    }

    /// Deep link back into the app. Resumable entries go straight to
    /// Continue Watching playback (the app resolves URL-less synced and Next Up
    /// entries after opening); the rest open the details page.
    public var deepLinkURL: URL? {
        link(host: (action ?? .resume) == .resume ? "continue-watching" : "details")
    }

    /// The title's details page, whatever selecting the card does.
    public var detailsURL: URL? {
        link(host: "details")
    }

    private func link(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "nuvio-tv"
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "id", value: contentId),
            URLQueryItem(name: "type", value: contentType)
        ]
        return components.url
    }
}

/// One Home catalog row in the catalog feed.
public struct TopShelfFeedRow: Codable, Equatable, Sendable {
    /// The Home row id, which Settings stores to choose it.
    public let id: String
    public let title: String?
    public let entries: [TopShelfEntry]

    public init(id: String, title: String?, entries: [TopShelfEntry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }
}

public struct TopShelfFeed: Codable, Equatable, Sendable {
    public let entries: [TopShelfEntry]
    public let updatedAt: Date
    /// Row heading. Nil for the fixed sections, whose titles the extension owns
    /// unless the app supplies a localized one.
    public let title: String?
    /// Catalog feed only: every Home catalog row, in Home order; Settings picks
    /// which of them the shelf shows. Nil in the fixed sections and in catalog
    /// feeds written before the choice existed.
    public let rows: [TopShelfFeedRow]?

    public init(entries: [TopShelfEntry], title: String? = nil,
                rows: [TopShelfFeedRow]? = nil, updatedAt: Date = Date()) {
        self.entries = entries
        self.title = title
        self.rows = rows
        self.updatedAt = updatedAt
    }

    /// The catalog rows this feed offers. A feed from before rows existed is
    /// its single first-catalog row.
    public var catalogRows: [TopShelfFeedRow] {
        if let rows { return rows }
        return entries.isEmpty ? [] : [TopShelfFeedRow(id: Self.legacyCatalogRowID, title: title, entries: entries)]
    }

    static let legacyCatalogRowID = "catalog"

    var allEntries: [TopShelfEntry] {
        entries + (rows ?? []).flatMap(\.entries)
    }
}

/// One rating drawn under the logo in the carousel image, as Nuvio's Details
/// and hero show it: the provider's icon and the formatted score.
public struct TopShelfRatingBadge: Codable, Equatable, Sendable {
    public let source: String
    public let name: String
    /// Formatted as Nuvio shows it ("8.1", "85%").
    public let value: String
    /// A bundled icon (the app's asset catalog), else one to download.
    public let iconAssetName: String?
    public let iconURL: String?
    /// Icon width at an icon height of 38.
    public let iconWidth: Double

    public init(source: String, name: String, value: String,
                iconAssetName: String?, iconURL: String?, iconWidth: Double) {
        self.source = source
        self.name = name
        self.value = value
        self.iconAssetName = iconAssetName
        self.iconURL = iconURL
        self.iconWidth = iconWidth
    }
}

/// Ratings fetched for carousel titles, kept next to the feeds so each title
/// is looked up at most once a day.
public enum TopShelfRatingsStore {
    public struct Record: Codable, Equatable, Sendable {
        public let badges: [TopShelfRatingBadge]
        public let fetchedAt: Date
    }

    static let fileName = "ratings.json"
    static let maximumAge: TimeInterval = 24 * 60 * 60

    static func read(in directory: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return records
    }

    static func write(_ records: [String: Record], in directory: URL) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        TopShelfArtworkPruner.withFeedLock {
            try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
    }

    static func isFresh(_ record: Record?, now: Date = Date()) -> Bool {
        guard let record else { return false }
        return now.timeIntervalSince(record.fetchedAt) < maximumAge
    }
}

/// Orders writes independently of detached-task scheduling. All mutable state
/// and the synchronous commit are protected by the same lock.
final class TopShelfWriteCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginWrite() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    @discardableResult
    func commitIfCurrent(_ expected: UInt64, commit: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return false }
        commit()
        return true
    }
}

/// Runs artwork refreshes one at a time; a request made during a pass runs
/// one more pass after it, so the last feed and setting always win.
actor TopShelfArtworkRefresher {
    static let shared = TopShelfArtworkRefresher()

    private var isRunning = false
    private var isPending = false

    func refresh(_ pass: @Sendable () async -> Void) async {
        isPending = true
        guard !isRunning else { return }
        isRunning = true
        while isPending {
            isPending = false
            await pass()
        }
        isRunning = false
    }
}

/// Reads/writes the feed in the shared App Group. All calls are no-ops when the
/// group container isn't available (e.g. entitlement not provisioned), so the
/// app never crashes or blocks on it.
public enum TopShelfFeedStore {
    // Version 4 / 2: drawn from the largest source the image host offers, the
    // carousel at the screen's scale.
    private static let artworkRenderVersion = 4
    private static let carouselRenderVersion = 3
    /// Rendered card size. 16:9, large enough for the 2x shelf scale.
    private static let artworkSize = CGSize(width: 1_280, height: 720)
    /// Rendered carousel size: the full screen, in points. Drawn at the
    /// screen's scale, so 3840x2160 pixels on a 4K TV.
    private static let carouselArtworkSize = CGSize(width: 1_920, height: 1_080)
    /// Set by the app: the ratings the carousel shows for a title, in Nuvio's
    /// own sources and order. Nil in the extension, which only reads them.
    public static var ratingsProvider: (@Sendable (TopShelfEntry) async -> [TopShelfRatingBadge])?
    private static let writeCoordinators: [TopShelfSection: TopShelfWriteCoordinator] =
        Dictionary(uniqueKeysWithValues: TopShelfSection.allCases.map { ($0, TopShelfWriteCoordinator()) })

    /// True when the shared App Group directory actually exists on this device.
    /// Accessing `UserDefaults(suiteName:)` on an unprovisioned App Group causes
    /// cfprefsd to detach and hang on subsequent IPC locks. Using direct container
    /// files completely bypasses cfprefsd and avoids IPC stalls.
    public static var isAvailable: Bool {
        groupContainerURL != nil
    }

    private static var groupContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: topShelfAppGroupID
        )
    }

    /// Where the feeds and artwork live. tvOS only allows writes under
    /// Library/Caches, App Group containers included: a write to the
    /// container root fails on device (the simulator allows it).
    static var containerURL: URL? {
        guard let base = groupContainerURL else { return nil }
        let directory = base.appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func feedFileURL(for section: TopShelfSection) -> URL? {
        containerURL?.appendingPathComponent(section.feedFileName)
    }

    /// Called by the app whenever a mirrored section changes. Writes for one
    /// section are ordered; sections never block or reorder each other.
    public static func write(
        _ entries: [TopShelfEntry],
        section: TopShelfSection = .continueWatching,
        title: String? = nil
    ) {
        commit(section: section) {
            TopShelfFeed(entries: entries.map(decorated), title: title)
        }
    }

    /// Mirrors every Home catalog row; Settings chooses which the shelf shows.
    public static func writeCatalogRows(_ rows: [TopShelfFeedRow]) {
        commit(section: .catalog) {
            TopShelfFeed(
                entries: [],
                rows: rows.map { TopShelfFeedRow(id: $0.id, title: $0.title, entries: $0.entries.map(decorated)) })
        }
    }

    private static func commit(section: TopShelfSection, feed makeFeed: @escaping @Sendable () -> TopShelfFeed) {
        guard isAvailable, let writeCoordinator = writeCoordinators[section] else { return }
        let generation = writeCoordinator.beginWrite()
        Task.detached(priority: .utility) {
            let feed = makeFeed()
            guard writeCoordinator.commitIfCurrent(generation, commit: {
                writeFeed(feed, section: section)
            }) else { return }
            await refreshArtworkNow()
        }
    }

    /// Redraws the shelf for the current setting: renders the artwork the
    /// chosen layout shows, removes what it no longer shows, and asks the
    /// system to reload the shelf.
    public static func refreshArtwork() {
        guard isAvailable else { return }
        Task.detached(priority: .utility) {
            await refreshArtworkNow()
        }
    }

    private static func refreshArtworkNow() async {
        await TopShelfArtworkRefresher.shared.refresh {
            guard let container = containerURL else { return }
            let configuration = TopShelfConfigurationStore.load()
            TopShelfConfigurationStore.mirror(configuration, in: container)
            #if canImport(UIKit)
            let rows = TopShelfComposer.rows(configuration: configuration) { read($0) }
            let displayed = TopShelfComposer.displayedEntries(configuration: configuration, rows: rows)
            let scale = await MainActor.run { min(max(UIScreen.main.scale, 1), 2) }
            var ratings = TopShelfRatingsStore.read(in: container)
            if configuration.style.isCarousel, let provider = ratingsProvider {
                var changed = false
                for entry in displayed where !TopShelfRatingsStore.isFresh(ratings[entry.contentId]) {
                    let badges = await provider(entry)
                    ratings[entry.contentId] = TopShelfRatingsStore.Record(badges: badges, fetchedAt: Date())
                    changed = true
                }
                // Titles no longer on the shelf drop out, so the file stays small.
                let shown = Set(rows.flatMap(\.entries).map(\.contentId))
                let kept = ratings.filter { shown.contains($0.key) }
                if changed || kept.count != ratings.count {
                    ratings = kept
                    TopShelfRatingsStore.write(ratings, in: container)
                }
            }
            await cacheArtwork(for: displayed, carousel: configuration.style.isCarousel, ratings: ratings, scale: scale)
            #endif
            TopShelfArtworkPruner.prune(in: container)
            notifyTopShelfContentChanged()
        }
    }

    /// Resolves a rendered card that both the app and extension can read from
    /// their shared App Group.
    public static func artworkURL(for entry: TopShelfEntry) -> URL? {
        existingArtwork(named: entry.artworkFileName)
    }

    /// Resolves the rendered full-screen carousel image: with the title's
    /// ratings when it has them, else without.
    public static func carouselArtworkURL(for entry: TopShelfEntry, ratings: [String: TopShelfRatingsStore.Record]) -> URL? {
        existingArtwork(named: carouselImageName(for: entry, badges: ratings[entry.contentId]?.badges))
            ?? existingArtwork(named: entry.carouselArtworkFileName)
    }

    /// The ratings saved for the shelf's titles.
    public static func savedRatings() -> [String: TopShelfRatingsStore.Record] {
        containerURL.map(TopShelfRatingsStore.read(in:)) ?? [:]
    }

    /// The carousel render's name. Ratings change it, so new scores redraw it.
    static func carouselImageName(for entry: TopShelfEntry, badges: [TopShelfRatingBadge]?) -> String? {
        guard let base = entry.carouselArtworkFileName else { return nil }
        guard let badges, !badges.isEmpty else { return base }
        return generatedName(for: [base] + badges.map { "\($0.source)=\($0.value)" })
    }

    private static func existingArtwork(named name: String?) -> URL? {
        guard let name, let container = containerURL else { return nil }
        let url = container.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func writeFeed(_ feed: TopShelfFeed, section: TopShelfSection) {
        guard let url = feedFileURL(for: section),
              let data = try? JSONEncoder().encode(feed) else { return }
        TopShelfArtworkPruner.withFeedLock {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Names both renders up front. Which one gets drawn depends on the
    /// setting, which can change without the feed being written again.
    private static func decorated(_ entry: TopShelfEntry) -> TopShelfEntry {
        var entry = entry
        entry.artworkFileName = entry.artworkSourceURL == nil ? nil : artworkFileName(for: entry)
        entry.carouselArtworkFileName = entry.artworkSourceURL == nil ? nil : carouselArtworkFileName(for: entry)
        return entry
    }

    private static func artworkFileName(for entry: TopShelfEntry) -> String {
        generatedName(for: [
            String(artworkRenderVersion),
            entry.contentId,
            entry.artworkSourceURL ?? "",
            entry.subtitle ?? ""
        ])
    }

    private static func carouselArtworkFileName(for entry: TopShelfEntry) -> String {
        generatedName(for: [
            "carousel",
            String(carouselRenderVersion),
            entry.contentId,
            entry.artworkSourceURL ?? "",
            entry.logoURL ?? ""
        ])
    }

    /// The same image at the largest size its host serves, then the URL as
    /// given. Catalogs hand out mid-size artwork (TMDB w1280, Cinemeta
    /// "medium"), which a full-screen 4K shelf shows soft.
    static func highResolutionCandidates(for text: String) -> [URL] {
        guard let url = URL(string: text) else { return [] }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return [url] }
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch host {
        case "image.tmdb.org":
            // /t/p/<size>/<file>
            guard parts.count > 4, parts[1] == "t", parts[2] == "p", parts[3] != "original" else { return [url] }
            parts[3] = "original"
        case "images.metahub.space":
            // /<kind>/<size>/<imdb id>/img
            guard parts.count > 3, ["small", "medium"].contains(parts[2]) else { return [url] }
            parts[2] = "large"
        case "assets.fanart.tv":
            // /preview/<path> is a downscaled copy of /fanart/<path>.
            guard parts.count > 2, parts[1] == "preview" else { return [url] }
            parts[1] = "fanart"
        default:
            return [url]
        }
        components.path = parts.joined(separator: "/")
        guard let upgraded = components.url, upgraded != url else { return [url] }
        return [upgraded, url]
    }

    private static func generatedName(for parts: [String]) -> String {
        let source = parts.joined(separator: "\u{1F}")
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a offset basis
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "top-shelf-\(String(hash, radix: 16)).jpg"
    }

    private static func notifyTopShelfContentChanged() {
        #if canImport(TVServices)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    #if canImport(UIKit)
    private static func cacheArtwork(
        for entries: [TopShelfEntry],
        carousel: Bool,
        ratings: [String: TopShelfRatingsStore.Record],
        scale: CGFloat
    ) async {
        #if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        print("[TVTrace] topShelf.cacheArtwork begin entries=\(entries.count) carousel=\(carousel)")
        #endif
        var icons: [String: UIImage] = [:]
        for entry in entries {
            let badges = ratings[entry.contentId]?.badges ?? []
            let name = carousel ? carouselImageName(for: entry, badges: badges) : entry.artworkFileName
            guard let name, let container = containerURL else { continue }
            let destination = container.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let sourceText = entry.artworkSourceURL,
                  let image = await downloadedImage(sourceText) else { continue }
            let rendered: Data?
            if carousel {
                var logo: UIImage?
                if let logoText = entry.logoURL { logo = await downloadedImage(logoText) }
                var drawn: [(icon: UIImage?, badge: TopShelfRatingBadge)] = []
                for badge in badges {
                    let icon = await ratingIcon(for: badge, cache: &icons)
                    drawn.append((icon: icon, badge: badge))
                }
                rendered = renderedCarouselArtwork(from: image, logo: logo, ratings: drawn, scale: scale)
            } else {
                rendered = renderedArtwork(from: image, subtitle: entry.subtitle)
            }
            guard let rendered else { continue }
            try? rendered.write(to: destination, options: .atomic)
        }
        #if DEBUG
        let totalElapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("[TVTrace] topShelf.cacheArtwork end totalMs=\(String(format: "%.1f", totalElapsed))")
        #endif
    }

    /// A bundled provider icon, else the add-on's, downloaded once per pass.
    private static func ratingIcon(for badge: TopShelfRatingBadge, cache: inout [String: UIImage]) async -> UIImage? {
        if let asset = badge.iconAssetName, let image = UIImage(named: asset) { return image }
        guard let url = badge.iconURL, let iconURL = URL(string: url) else { return nil }
        if let cached = cache[url] { return cached }
        guard let result = try? await URLSession.shared.data(from: iconURL),
              let image = UIImage(data: result.0) else { return nil }
        cache[url] = image
        return image
    }

    /// The image at the largest size offered, else as given.
    private static func downloadedImage(_ text: String) async -> UIImage? {
        for url in highResolutionCandidates(for: text) {
            guard let result = try? await URLSession.shared.data(from: url) else { continue }
            if let http = result.1 as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
            if let image = UIImage(data: result.0) { return image }
        }
        return nil
    }

    /// Renders a 16:9 card. Landscape art fills it; portrait art (a poster used
    /// when no backdrop exists) sits centered over a dimmed, filled copy of
    /// itself rather than being cropped to a sliver.
    private static func renderedArtwork(from image: UIImage, subtitle: String?) -> Data? {
        let size = artworkSize
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { context in
            drawBackground(image, in: size, context: context)

            guard let subtitle else { return }
            let font = UIFont.systemFont(ofSize: 40, weight: .bold)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: style
            ]
            let textSize = (subtitle as NSString).size(withAttributes: attributes)
            let horizontalPadding: CGFloat = 64
            let maximumPillWidth = size.width - 80
            let pillWidth = min(maximumPillWidth, ceil(textSize.width) + horizontalPadding)
            let pillHeight = max(88, ceil(textSize.height) + 32)
            let pillRect = CGRect(
                x: (size.width - pillWidth) / 2,
                y: size.height - pillHeight - 40,
                width: pillWidth,
                height: pillHeight
            )

            UIColor.black.withAlphaComponent(0.76).setFill()
            UIBezierPath(roundedRect: pillRect, cornerRadius: pillHeight / 2).fill()

            let textRect = CGRect(
                x: pillRect.minX + horizontalPadding / 2,
                y: pillRect.midY - ceil(textSize.height) / 2,
                width: pillRect.width - horizontalPadding,
                height: ceil(textSize.height)
            )
            subtitle.draw(
                in: textRect,
                withAttributes: attributes
            )
        }
        return rendered.jpegData(compressionQuality: 0.85)
    }

    /// Where the logo's center sits, as a fraction of the image height. Logo
    /// and ratings end above the system's arrow at mid-height.
    private static let logoCenterHeight: CGFloat = 0.26

    /// Renders a full-screen carousel image: the backdrop, darkened toward the
    /// left edge where the system draws its text, with the title's logo there
    /// and its ratings below the logo.
    private static func renderedCarouselArtwork(
        from image: UIImage,
        logo: UIImage?,
        ratings: [(icon: UIImage?, badge: TopShelfRatingBadge)],
        scale: CGFloat
    ) -> Data? {
        let size = carouselArtworkSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { context in
            drawBackground(image, in: size, context: context)

            let shade = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shade as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size.width * 0.6, y: 0), options: [])
            }

            // The upper part: the system draws its previous-item arrow at the left edge
            // around mid-height, and its buttons and summary in the lower third.
            var ratingsTop = size.height * logoCenterHeight
            if let logo, logo.size.width > 0, logo.size.height > 0 {
                let maximum = CGSize(width: size.width * 0.34, height: size.height * 0.18)
                let logoScale = min(maximum.width / logo.size.width, maximum.height / logo.size.height)
                let logoSize = CGSize(width: logo.size.width * logoScale, height: logo.size.height * logoScale)
                let origin = CGPoint(x: 120, y: size.height * logoCenterHeight - logoSize.height / 2)
                logo.draw(in: CGRect(origin: origin, size: logoSize))
                ratingsTop = origin.y + logoSize.height + 32
            }
            drawRatings(ratings, at: CGPoint(x: 120, y: ratingsTop), maximumX: size.width * 0.55)
        }
        return rendered.jpegData(compressionQuality: 0.85)
    }

    /// One row of provider icons with their scores, as on the Details page.
    private static func drawRatings(
        _ ratings: [(icon: UIImage?, badge: TopShelfRatingBadge)],
        at origin: CGPoint,
        maximumX: CGFloat
    ) {
        guard !ratings.isEmpty else { return }
        let iconHeight: CGFloat = 40
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: UIColor.white,
            .shadow: shadow
        ]
        var x = origin.x
        for (icon, badge) in ratings {
            // No icon: the provider's name stands in for it.
            let text = icon == nil ? "\(badge.name) \(badge.value)" : badge.value
            let textSize = (text as NSString).size(withAttributes: attributes)
            let iconWidth = icon == nil ? 0 : iconHeight * CGFloat(badge.iconWidth / 38)
            let width = iconWidth + (icon == nil ? 0 : 12) + ceil(textSize.width)
            guard x + width <= maximumX else { break }
            if let icon {
                icon.draw(in: aspectRect(
                    for: icon.size,
                    in: CGSize(width: iconWidth, height: iconHeight),
                    fill: false
                ).offsetBy(dx: x, dy: origin.y))
            }
            let textX = x + iconWidth + (icon == nil ? 0 : 12)
            (text as NSString).draw(
                at: CGPoint(x: textX, y: origin.y + (iconHeight - textSize.height) / 2),
                withAttributes: attributes)
            x += width + 36
        }
    }

    private static func drawBackground(_ image: UIImage, in size: CGSize, context: UIGraphicsImageRendererContext) {
        UIColor.black.setFill()
        context.fill(CGRect(origin: .zero, size: size))

        let fillRect = aspectRect(for: image.size, in: size, fill: true)
        let isLandscape = image.size.width >= image.size.height * 1.2
        if isLandscape {
            image.draw(in: fillRect)
        } else {
            image.draw(in: fillRect, blendMode: .normal, alpha: 0.35)
            image.draw(in: aspectRect(for: image.size, in: size, fill: false))
        }
    }

    private static func aspectRect(for imageSize: CGSize, in size: CGSize, fill: Bool) -> CGRect {
        let widthScale = size.width / imageSize.width
        let heightScale = size.height / imageSize.height
        let scale = fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let scaled = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (size.width - scaled.width) / 2,
            y: (size.height - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height
        )
    }
    #endif

    /// Called by the Top Shelf extension to build a row.
    public static func read(_ section: TopShelfSection = .continueWatching) -> TopShelfFeed? {
        guard let url = feedFileURL(for: section),
              let data = try? Data(contentsOf: url),
              let feed = try? JSONDecoder().decode(TopShelfFeed.self, from: data) else {
            return nil
        }
        return feed
    }
}

/// Removes generated artwork the shelf no longer shows, preserving the
/// persisted feeds.
enum TopShelfArtworkPruner {
    private static let feedLock = NSLock()

    // Feed replacement and cleanup must agree on the referenced filenames.
    static func withFeedLock(_ operation: () -> Void) {
        feedLock.lock()
        defer { feedLock.unlock() }
        operation()
    }

    static func prune(in container: URL) {
        withFeedLock {
            // Keep both renders of every entry the chosen layout shows: a
            // style switch reuses them. A section that was never written is
            // skipped, but an unreadable one (or none at all) stops cleanup
            // rather than risk deleting artwork it still uses.
            var feeds: [TopShelfSection: TopShelfFeed] = [:]
            for section in TopShelfSection.allCases {
                let feedURL = container.appendingPathComponent(section.feedFileName)
                guard FileManager.default.fileExists(atPath: feedURL.path) else { continue }
                guard let data = try? Data(contentsOf: feedURL),
                      let feed = try? JSONDecoder().decode(TopShelfFeed.self, from: data) else { return }
                feeds[section] = feed
            }
            guard !feeds.isEmpty else { return }
            let configuration = TopShelfConfigurationStore.read(in: container) ?? .default
            let ratings = TopShelfRatingsStore.read(in: container)
            let rows = TopShelfComposer.rows(configuration: configuration) { feeds[$0] }
            let keep = Set(rows.flatMap(\.entries).flatMap { entry in
                [
                    entry.artworkFileName,
                    entry.carouselArtworkFileName,
                    TopShelfFeedStore.carouselImageName(for: entry, badges: ratings[entry.contentId]?.badges)
                ].compactMap { $0 }
            })
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else { return }
            for file in files {
                let name = file.lastPathComponent
                guard isGeneratedArtworkName(name), !keep.contains(name),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func isGeneratedArtworkName(_ name: String) -> Bool {
        guard name.hasPrefix("top-shelf-"), name.hasSuffix(".jpg") else { return false }
        let hash = name.dropFirst("top-shelf-".count).dropLast(".jpg".count)
        return (1...16).contains(hash.count)
            && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
