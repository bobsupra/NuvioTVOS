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
public enum TopShelfSection: String, Codable, CaseIterable {
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
public enum TopShelfEntryAction: String, Codable {
    /// Resume (or start the suggested episode) straight from the shelf.
    case resume
    /// Open the title's details page.
    case details
}

/// One card on the Top Shelf row.
public struct TopShelfEntry: Codable, Equatable {
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
    public let artworkFileName: String?
    /// Fractional progress 0...1, drawn as the card's progress bar.
    public let progress: Double?
    /// Nil in feeds written before actions existed, which were all resumable.
    public let action: TopShelfEntryAction?

    public init(contentId: String, contentType: String, title: String,
                subtitle: String?, imageURL: String?, backdropURL: String? = nil,
                progress: Double?, action: TopShelfEntryAction = .resume,
                artworkFileName: String? = nil) {
        self.contentId = contentId
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.backdropURL = backdropURL
        self.progress = progress
        self.action = action
        self.artworkFileName = artworkFileName
    }

    /// Artwork the card is rendered from: the backdrop, else the poster.
    var artworkSourceURL: String? {
        backdropURL ?? imageURL
    }

    fileprivate func withArtworkFileName(_ artworkFileName: String?) -> TopShelfEntry {
        TopShelfEntry(
            contentId: contentId,
            contentType: contentType,
            title: title,
            subtitle: subtitle,
            imageURL: imageURL,
            backdropURL: backdropURL,
            progress: progress,
            action: action ?? .resume,
            artworkFileName: artworkFileName
        )
    }

    /// Deep link back into the app. Resumable entries go straight to
    /// Continue Watching playback (the app resolves URL-less synced and Next Up
    /// entries after opening); the rest open the details page.
    public var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "nuvio-tv"
        components.host = (action ?? .resume) == .resume ? "continue-watching" : "details"
        components.queryItems = [
            URLQueryItem(name: "id", value: contentId),
            URLQueryItem(name: "type", value: contentType)
        ]
        return components.url
    }
}

public struct TopShelfFeed: Codable, Equatable {
    public let entries: [TopShelfEntry]
    public let updatedAt: Date
    /// Row heading. Nil for the fixed sections, whose titles the extension owns
    /// unless the app supplies a localized one.
    public let title: String?

    public init(entries: [TopShelfEntry], title: String? = nil, updatedAt: Date = Date()) {
        self.entries = entries
        self.title = title
        self.updatedAt = updatedAt
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

/// Reads/writes the feed in the shared App Group. All calls are no-ops when the
/// group container isn't available (e.g. entitlement not provisioned), so the
/// app never crashes or blocks on it.
public enum TopShelfFeedStore {
    private static let artworkRenderVersion = 3
    /// Rendered card size. 16:9, large enough for the 2x shelf scale.
    private static let artworkSize = CGSize(width: 1_280, height: 720)
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
    private static var containerURL: URL? {
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
        guard isAvailable, let writeCoordinator = writeCoordinators[section] else { return }
        let generation = writeCoordinator.beginWrite()
        Task.detached(priority: .utility) {
            let decoratedEntries = entries.map { entry in
                guard entry.artworkSourceURL != nil else { return entry }
                return entry.withArtworkFileName(artworkFileName(for: entry))
            }
            guard writeCoordinator.commitIfCurrent(generation, commit: {
                writeFeed(decoratedEntries, title: title, section: section)
            }) else { return }

            #if canImport(UIKit)
            await cacheArtwork(for: decoratedEntries)
            #endif
            if let container = containerURL {
                TopShelfArtworkPruner.prune(in: container)
            }
            notifyTopShelfContentChanged()
        }
    }

    /// Resolves a rendered artwork file that both the app and extension can
    /// read from their shared App Group.
    public static func artworkURL(for entry: TopShelfEntry) -> URL? {
        guard let artworkFileName = entry.artworkFileName,
              let container = containerURL else { return nil }
        let url = container.appendingPathComponent(artworkFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func writeFeed(_ entries: [TopShelfEntry], title: String?, section: TopShelfSection) {
        guard let url = feedFileURL(for: section) else { return }
        let feed = TopShelfFeed(entries: entries, title: title)
        guard let data = try? JSONEncoder().encode(feed) else { return }
        TopShelfArtworkPruner.withFeedLock {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func artworkFileName(for entry: TopShelfEntry) -> String {
        let source = [
            String(artworkRenderVersion),
            entry.contentId,
            entry.artworkSourceURL ?? "",
            entry.subtitle ?? ""
        ]
            .joined(separator: "\u{1F}")
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
    private static func cacheArtwork(for entries: [TopShelfEntry]) async {
        #if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        print("[TVTrace] topShelf.cacheArtwork begin entries=\(entries.count) onMainActor=\(Thread.isMainThread)")
        #endif
        for entry in entries {
            guard let destination = artworkURLDestination(for: entry),
                  !FileManager.default.fileExists(atPath: destination.path),
                  let sourceText = entry.artworkSourceURL,
                  let sourceURL = URL(string: sourceText) else { continue }
            #if DEBUG
            let itemStart = DispatchTime.now().uptimeNanoseconds
            print("[TVTrace] topShelf.cacheArtwork rendering entry=\(entry.contentId)")
            #endif
            do {
                let (data, _) = try await URLSession.shared.data(from: sourceURL)
                guard let image = UIImage(data: data),
                      let rendered = renderedArtwork(from: image, subtitle: entry.subtitle) else { continue }
                try rendered.write(to: destination, options: .atomic)
                #if DEBUG
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - itemStart) / 1_000_000
                print("[TVTrace] topShelf.cacheArtwork finished entry=\(entry.contentId) size=\(rendered.count) bytes in \(String(format: "%.1f", elapsed))ms")
                #endif
            } catch {
                continue
            }
        }
        #if DEBUG
        let totalElapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("[TVTrace] topShelf.cacheArtwork end totalMs=\(String(format: "%.1f", totalElapsed))")
        #endif
        notifyTopShelfContentChanged()
    }

    private static func artworkURLDestination(for entry: TopShelfEntry) -> URL? {
        guard let artworkFileName = entry.artworkFileName,
              let container = containerURL else { return nil }
        return container.appendingPathComponent(artworkFileName)
    }

    /// Renders a 16:9 card. Landscape art fills it; portrait art (a poster used
    /// when no backdrop exists) sits centered over a dimmed, filled copy of
    /// itself rather than being cropped to a sliver.
    private static func renderedArtwork(from image: UIImage, subtitle: String?) -> Data? {
        let size = artworkSize
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { context in
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

/// Removes unreferenced generated artwork, preserving the persisted feed.
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
            // Every section's feed references artwork; keep anything any of
            // them still points at. A section that was never written is
            // skipped, but an unreadable one (or none at all) stops cleanup
            // rather than risk deleting artwork it still uses.
            var keep = Set<String>()
            var readAnyFeed = false
            for section in TopShelfSection.allCases {
                let feedURL = container.appendingPathComponent(section.feedFileName)
                guard FileManager.default.fileExists(atPath: feedURL.path) else { continue }
                guard let data = try? Data(contentsOf: feedURL),
                      let feed = try? JSONDecoder().decode(TopShelfFeed.self, from: data) else { return }
                keep.formUnion(feed.entries.compactMap(\.artworkFileName))
                readAnyFeed = true
            }
            guard readAnyFeed else { return }
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
