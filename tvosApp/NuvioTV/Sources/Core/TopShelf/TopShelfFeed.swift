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

    public init(contentId: String, contentType: String, title: String,
                subtitle: String?, imageURL: String?, backdropURL: String? = nil,
                progress: Double?, action: TopShelfEntryAction = .resume,
                artworkFileName: String? = nil,
                summary: String? = nil, genres: [String]? = nil, year: Int? = nil,
                releaseDate: String? = nil, runtimeMinutes: Int? = nil,
                logoURL: String? = nil, cast: [String]? = nil, directors: [String]? = nil,
                carouselArtworkFileName: String? = nil) {
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
    private static let artworkRenderVersion = 3
    private static let carouselRenderVersion = 1
    /// Rendered card size. 16:9, large enough for the 2x shelf scale.
    private static let artworkSize = CGSize(width: 1_280, height: 720)
    /// Rendered carousel size: the full screen at 1x. Sources are rarely
    /// larger, and the system scales it for 4K.
    private static let carouselArtworkSize = CGSize(width: 1_920, height: 1_080)
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
            await cacheArtwork(for: displayed, carousel: configuration.style.isCarousel)
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

    /// Resolves the rendered full-screen carousel image.
    public static func carouselArtworkURL(for entry: TopShelfEntry) -> URL? {
        existingArtwork(named: entry.carouselArtworkFileName)
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
    private static func cacheArtwork(for entries: [TopShelfEntry], carousel: Bool) async {
        #if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        print("[TVTrace] topShelf.cacheArtwork begin entries=\(entries.count) carousel=\(carousel)")
        #endif
        for entry in entries {
            let name = carousel ? entry.carouselArtworkFileName : entry.artworkFileName
            guard let name, let container = containerURL else { continue }
            let destination = container.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let sourceText = entry.artworkSourceURL,
                  let sourceURL = URL(string: sourceText) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: sourceURL)
                guard let image = UIImage(data: data) else { continue }
                let rendered: Data?
                if carousel {
                    rendered = renderedCarouselArtwork(from: image, logo: await logoImage(for: entry))
                } else {
                    rendered = renderedArtwork(from: image, subtitle: entry.subtitle)
                }
                guard let rendered else { continue }
                try rendered.write(to: destination, options: .atomic)
            } catch {
                continue
            }
        }
        #if DEBUG
        let totalElapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("[TVTrace] topShelf.cacheArtwork end totalMs=\(String(format: "%.1f", totalElapsed))")
        #endif
    }

    private static func logoImage(for entry: TopShelfEntry) async -> UIImage? {
        guard let text = entry.logoURL, let url = URL(string: text),
              let response = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: response.0)
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

    /// Renders a full-screen carousel image: the backdrop, darkened toward the
    /// left edge where the system draws its text, with the title's logo there.
    private static func renderedCarouselArtwork(from image: UIImage, logo: UIImage?) -> Data? {
        let size = carouselArtworkSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { context in
            drawBackground(image, in: size, context: context)

            let shade = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shade as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size.width * 0.6, y: 0), options: [])
            }

            guard let logo, logo.size.width > 0, logo.size.height > 0 else { return }
            let maximum = CGSize(width: size.width * 0.34, height: size.height * 0.2)
            let scale = min(maximum.width / logo.size.width, maximum.height / logo.size.height)
            let logoSize = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
            let origin = CGPoint(x: 120, y: size.height * 0.42 - logoSize.height / 2)
            logo.draw(in: CGRect(origin: origin, size: logoSize))
        }
        return rendered.jpegData(compressionQuality: 0.85)
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
            let rows = TopShelfComposer.rows(configuration: configuration) { feeds[$0] }
            let keep = Set(rows.flatMap(\.entries).flatMap {
                [$0.artworkFileName, $0.carouselArtworkFileName].compactMap { $0 }
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
