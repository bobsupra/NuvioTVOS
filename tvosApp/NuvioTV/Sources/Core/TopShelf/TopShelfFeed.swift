import Foundation

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
public let topShelfAppGroupID = "group.com.nuvio.app.tv"

/// One card on the Top Shelf row.
public struct TopShelfEntry: Codable, Equatable {
    public let contentId: String
    public let contentType: String
    public let title: String
    public let subtitle: String?
    public let imageURL: String?
    /// Fractional progress 0...1, drawn as the card's progress bar.
    public let progress: Double?

    public init(contentId: String, contentType: String, title: String,
                subtitle: String?, imageURL: String?, progress: Double?) {
        self.contentId = contentId
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.progress = progress
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
        guard let defaults = sharedDefaults else { return }
        let feed = TopShelfFeed(entries: entries)
        guard let data = try? JSONEncoder().encode(feed) else { return }
        defaults.set(data, forKey: feedKey)
    }

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
