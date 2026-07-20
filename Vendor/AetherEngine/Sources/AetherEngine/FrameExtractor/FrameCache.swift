import Foundation
import CoreGraphics

/// Size-bounded LRU cache of rendered frames keyed by `(mode, position bucket)`.
/// Per-mode count limit caps the cache at `thumbnailLimit + snapshotLimit` CGImages.
/// Key omits target size: one extractor serves one fixed-size surface, so a repeat
/// position at a different maxWidth/maxSize returns the first-rendered image.
/// Not thread-safe; FrameExtractor owns the only instance and touches it actor-isolated.
final class FrameCache {
    private let thumbnailLimit: Int
    private let snapshotLimit: Int
    private let thumbnailBucketSeconds: Double
    // Snapshots are frame-accurate, so a 0.1 s grid (~3 frames at 30 fps) suffices.
    private static let snapshotBucketSeconds: Double = 0.1

    // Each FrameMode case needs a matching store + order pair below, plus
    // mirroring in get/set/clear. Add both when introducing a new case.
    /// Use order per mode, front = MRU; holds bucket keys, `store` holds payloads.
    private var thumbnailOrder: [Int] = []
    private var snapshotOrder: [Int] = []
    private var thumbnailStore: [Int: CGImage] = [:]
    private var snapshotStore: [Int: CGImage] = [:]

    init(thumbnailLimit: Int, snapshotLimit: Int, thumbnailBucketSeconds: Double) {
        precondition(thumbnailBucketSeconds > 0, "thumbnailBucketSeconds must be positive")
        self.thumbnailLimit = thumbnailLimit
        self.snapshotLimit = snapshotLimit
        self.thumbnailBucketSeconds = thumbnailBucketSeconds
    }

    private func bucket(_ seconds: Double, mode: FrameMode) -> Int {
        let grid = mode == .thumbnail ? thumbnailBucketSeconds : Self.snapshotBucketSeconds
        let scaled = max(0, seconds) / grid
        // Thumbnails floor to grid; snapshots round to nearest so a value within
        // half a bucket of a stored position resolves to the same entry.
        let rounded = mode == .thumbnail ? scaled.rounded(.down) : scaled.rounded()
        return Int(rounded)
    }

    func get(mode: FrameMode, seconds: Double) -> CGImage? {
        let key = bucket(seconds, mode: mode)
        switch mode {
        case .thumbnail:
            guard let img = thumbnailStore[key] else { return nil }
            touch(&thumbnailOrder, key)
            return img
        case .snapshot:
            guard let img = snapshotStore[key] else { return nil }
            touch(&snapshotOrder, key)
            return img
        }
    }

    func set(_ image: CGImage, mode: FrameMode, seconds: Double) {
        let key = bucket(seconds, mode: mode)
        switch mode {
        case .thumbnail:
            thumbnailStore[key] = image
            touch(&thumbnailOrder, key)
            evict(&thumbnailOrder, &thumbnailStore, limit: thumbnailLimit)
        case .snapshot:
            snapshotStore[key] = image
            touch(&snapshotOrder, key)
            evict(&snapshotOrder, &snapshotStore, limit: snapshotLimit)
        }
    }

    func clear() {
        thumbnailOrder.removeAll()
        snapshotOrder.removeAll()
        thumbnailStore.removeAll()
        snapshotStore.removeAll()
    }

    private func touch(_ order: inout [Int], _ key: Int) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.insert(key, at: 0)
    }

    private func evict(_ order: inout [Int], _ store: inout [Int: CGImage], limit: Int) {
        while store.count > limit, let lru = order.popLast() {
            store[lru] = nil
        }
    }
}
