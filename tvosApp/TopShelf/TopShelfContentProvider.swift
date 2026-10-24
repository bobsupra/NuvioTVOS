import TVServices

/// Populates the Apple TV home-screen Top Shelf from the sections the main app
/// mirrors into the shared App Group (Continue Watching, Up Next, Library and
/// the first Home catalog row). Reads `TopShelfFeedStore` (add
/// `TopShelfFeed.swift` to this target's membership).
final class TopShelfContentProvider: TVTopShelfContentProvider {
    /// Shelf order, with the heading used when the app didn't supply one.
    private static let sections: [(TopShelfSection, String)] = [
        (.continueWatching, "Continue Watching"),
        (.upNext, "Up Next"),
        (.library, "Library"),
        (.catalog, "Popular"),
    ]

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let collections = Self.sections.compactMap { section, fallbackTitle -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            guard let feed = TopShelfFeedStore.read(section), !feed.entries.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: feed.entries.map { Self.item(for: $0, in: section) })
            collection.title = feed.title ?? fallbackTitle
            return collection
        }
        guard !collections.isEmpty else {
            completionHandler(nil)
            return
        }
        completionHandler(TVTopShelfSectionedContent(sections: collections))
    }

    private static func item(for entry: TopShelfEntry, in section: TopShelfSection) -> TVTopShelfSectionedItem {
        // A title can sit on more than one row (e.g. Library and Popular).
        let item = TVTopShelfSectionedItem(identifier: "\(section.rawValue):\(entry.contentId)")
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
}
