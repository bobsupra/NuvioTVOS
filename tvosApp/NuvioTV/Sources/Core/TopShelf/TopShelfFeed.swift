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

/// One card on the Top Shelf row.
public struct TopShelfEntry: Codable, Equatable {
    public let contentId: String
    public let contentType: String
    public let title: String
    public let subtitle: String?
    public let imageURL: String?
    /// Filename of the locally rendered poster with its episode/time overlay.
    /// Optional so feeds written by earlier versions remain readable.
    public let artworkFileName: String?
    /// Fractional progress 0...1, drawn as the card's progress bar.
    public let progress: Double?

    public init(contentId: String, contentType: String, title: String,
                subtitle: String?, imageURL: String?, progress: Double?,
                artworkFileName: String? = nil) {
        self.contentId = contentId
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.progress = progress
        self.artworkFileName = artworkFileName
    }

    fileprivate func withArtworkFileName(_ artworkFileName: String?) -> TopShelfEntry {
        TopShelfEntry(
            contentId: contentId,
            contentType: contentType,
            title: title,
            subtitle: subtitle,
            imageURL: imageURL,
            progress: progress,
            artworkFileName: artworkFileName
        )
    }

    /// Deep link back into the app for direct Continue Watching playback.
    /// The app resolves URL-less synced and Next Up entries after opening.
    public var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "nuvio-tv"
        components.host = "continue-watching"
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

    public init(entries: [TopShelfEntry], updatedAt: Date = Date()) {
        self.entries = entries
        self.updatedAt = updatedAt
    }
}

/// Reads/writes the feed in the shared App Group. All calls are no-ops when the
/// group container isn't available (e.g. entitlement not provisioned), so the
/// app never crashes or blocks on it.
public enum TopShelfFeedStore {
    private static let feedKey = "nuvio.tv.topShelf.feed"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: topShelfAppGroupID)
    }

    /// Called by the app whenever Continue Watching changes.
    public static func write(_ entries: [TopShelfEntry]) {
        let decoratedEntries = entries.map { entry in
            guard entry.imageURL != nil, entry.subtitle != nil else { return entry }
            return entry.withArtworkFileName(artworkFileName(for: entry))
        }
        writeFeed(decoratedEntries)

        #if canImport(UIKit)
        Task { @MainActor in
            await cacheArtwork(for: decoratedEntries)
        }
        #endif
        notifyTopShelfContentChanged()
    }

    /// Resolves a rendered artwork file that both the app and extension can
    /// read from their shared App Group.
    public static func artworkURL(for entry: TopShelfEntry) -> URL? {
        guard let artworkFileName = entry.artworkFileName,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: topShelfAppGroupID
              ) else { return nil }
        let url = container.appendingPathComponent(artworkFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func writeFeed(_ entries: [TopShelfEntry]) {
        guard let defaults = sharedDefaults else { return }
        let feed = TopShelfFeed(entries: entries)
        guard let data = try? JSONEncoder().encode(feed) else { return }
        defaults.set(data, forKey: feedKey)
    }

    private static func artworkFileName(for entry: TopShelfEntry) -> String {
        let source = [entry.contentId, entry.imageURL ?? "", entry.subtitle ?? ""]
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
    @MainActor
    private static func cacheArtwork(for entries: [TopShelfEntry]) async {
        for entry in entries {
            guard let destination = artworkURLDestination(for: entry),
                  !FileManager.default.fileExists(atPath: destination.path),
                  let sourceText = entry.imageURL,
                  let sourceURL = URL(string: sourceText),
                  let subtitle = entry.subtitle else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: sourceURL)
                guard let image = UIImage(data: data),
                      let rendered = renderedArtwork(from: image, subtitle: subtitle) else { continue }
                try rendered.write(to: destination, options: .atomic)
            } catch {
                continue
            }
        }
        notifyTopShelfContentChanged()
    }

    private static func artworkURLDestination(for entry: TopShelfEntry) -> URL? {
        guard let artworkFileName = entry.artworkFileName,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: topShelfAppGroupID
              ) else { return nil }
        return container.appendingPathComponent(artworkFileName)
    }

    private static func renderedArtwork(from image: UIImage, subtitle: String) -> Data? {
        let size = CGSize(width: 1_000, height: 1_500)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let imageRect = CGRect(
                x: (size.width - imageSize.width) / 2,
                y: (size.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            image.draw(in: imageRect)

            let pillRect = CGRect(x: 44, y: 44, width: size.width - 88, height: 88)
            UIColor.black.withAlphaComponent(0.76).setFill()
            UIBezierPath(roundedRect: pillRect, cornerRadius: 24).fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            subtitle.draw(
                in: pillRect.insetBy(dx: 20, dy: 19),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 36, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: style
                ]
            )
        }
        return rendered.jpegData(compressionQuality: 0.9)
    }
    #endif

    /// Called by the Top Shelf extension to build the row.
    public static func read() -> TopShelfFeed? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: feedKey),
              let feed = try? JSONDecoder().decode(TopShelfFeed.self, from: data) else {
            return nil
        }
        return feed
    }
}
