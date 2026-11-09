import CryptoKit
import Foundation
import UIKit

/// The images of imported stream badges, kept on this Apple TV.
///
/// A badge pack stores only links to its images. Each badge used to load its image with
/// `AsyncImage` every time a stream card came on screen, showing a spinner meanwhile, and only
/// the system's HTTP cache (when the server allowed it) spared the download. Now the images are
/// downloaded when a pack is saved (and again after launch for any that are missing), kept in
/// the Caches folder and in memory, and a badge shows its image at once.
final class StreamBadgeImageStore: @unchecked Sendable {
    static let shared = StreamBadgeImageStore()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL?

    init(directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("StreamBadgeImages", isDirectory: true)) {
        self.directory = directory
    }

    /// The image when it is already in memory. Never reads the disk or downloads.
    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    /// From memory, else from the Caches folder, else downloaded (and kept).
    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let pending = inFlight[key] { return pending }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> UIImage? in
                guard let self else { return nil }
                let image = await self.load(url)
                self.finish(key: key, image: image)
                return image
            }
            inFlight[key] = task
            return task
        }
        return await task.value
    }

    /// Downloads, in the background, the images of every badge in `rules` not yet on disk.
    func prefetch(_ rules: StreamBadgeRules) {
        let urls = Self.imageURLs(in: rules)
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for url in urls where !self.isOnDisk(url) {
                _ = await self.image(for: url)
            }
        }
    }

    /// The badge image links in `rules`, each once.
    static func imageURLs(in rules: StreamBadgeRules) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for item in rules.imports {
            for filter in item.filters {
                let text = filter.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let url = URL(string: text), seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    /// The file a badge image is kept in: a hash of its link, so any link makes a safe name.
    static func fileName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func fileURL(for url: URL) -> URL? {
        // `data:` images carry their bytes in the link; there is nothing to keep.
        guard url.scheme?.lowercased() != "data" else { return nil }
        return directory?.appendingPathComponent(Self.fileName(for: url), isDirectory: false)
    }

    private func isOnDisk(_ url: URL) -> Bool {
        guard let file = fileURL(for: url) else { return true }
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func load(_ url: URL) async -> UIImage? {
        let file = fileURL(for: url)
        if let file, let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            return image
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) { return nil }
        guard let image = Self.decode(data) else { return nil }
        if let file, let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return image
    }

    /// Decoded here, off the main thread, so drawing the badge doesn't decode it.
    private static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    private func finish(key: String, image: UIImage?) {
        if let image { memory.setObject(image, forKey: key as NSString) }
        lock.withLock { inFlight[key] = nil }
    }
}
