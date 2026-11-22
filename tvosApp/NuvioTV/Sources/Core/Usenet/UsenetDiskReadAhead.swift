import Foundation

/// Decoded articles of the playing Usenet stream on disk, one file per article in Caches, so the
/// read-ahead can reach minutes past what fits in memory and a seek into what was already
/// downloaded doesn't download it again. Only one stream plays at a time: a new one clears
/// what an earlier one left (also after the app was closed mid-stream), and stopping the
/// stream deletes its folder.
actor UsenetDiskStore {
    static let folderName = "UsenetReadAhead"

    nonisolated let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// A fresh folder for a stream under `root` (Caches/UsenetReadAhead by default).
    static func make(root: URL? = nil) -> UsenetDiskStore? {
        let manager = FileManager.default
        guard let base = root ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true) else { return nil }
        try? manager.removeItem(at: base)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return UsenetDiskStore(directory: directory)
    }

    /// False when the article couldn't be written (no room left, folder gone).
    func write(_ index: Int, _ data: Data) -> Bool {
        (try? data.write(to: url(of: index))) != nil
    }

    /// Nil when the file is gone (the system may clear Caches while the app isn't running).
    func read(_ index: Int) -> Data? {
        try? Data(contentsOf: url(of: index))
    }

    func remove(_ indices: [Int]) {
        for index in indices { try? FileManager.default.removeItem(at: url(of: index)) }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What tvOS reports free where the read-ahead goes (-1: unknown), for Settings.
    static func reportedFreeSpace() -> Int64 {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return -1 }
        return PlaybackStreamDiskCache.volumeFreeSpace(at: caches)
    }

    /// What tvOS reports free on the disk (-1: unknown). Space the system could clear (other
    /// apps' caches, screensavers) isn't in it; tvOS gives apps no way to ask for that.
    func freeSpace() -> Int64 {
        PlaybackStreamDiskCache.volumeFreeSpace(at: directory)
    }

    private func url(of index: Int) -> URL {
        directory.appendingPathComponent("\(index).art")
    }
}

/// The disk read-ahead of a stream (Settings → Usenet → Read Ahead on Disk): where its
/// articles go and the size chosen for it, most of it for reading ahead and the rest for what
/// was played. How much of it is used follows the free space while the stream plays.
struct UsenetDiskReadAhead: Sendable {
    let store: UsenetDiskStore
    let sizeBytes: Int64

    /// The largest size that can be typed in.
    static let maxBytes: Int64 = 64 << 30
    /// Below this much room it isn't worth it: memory only, until tvOS clears space.
    static let minActiveBytes: Int64 = 256 << 20
    /// The disk always keeps this much free: the read-ahead stops growing there and waits for
    /// tvOS to clear space (it clears other apps' caches when the disk fills).
    static let minFreeBytes: Int64 = 1 << 30
    /// The share of the budget for reading ahead; the rest keeps what was played for seeking back.
    static let aheadShare = 0.8

    /// For the chosen size (nil: off); nil when its folder can't be made.
    static func make(sizeBytes: Int64?, root: URL? = nil) -> UsenetDiskReadAhead? {
        guard let sizeBytes, sizeBytes > 0, let store = UsenetDiskStore.make(root: root) else { return nil }
        return UsenetDiskReadAhead(store: store, sizeBytes: min(sizeBytes, maxBytes))
    }

    /// What the stream may use now: the chosen size, as far as what it holds plus the free
    /// space above `minFreeBytes` reach (all of it when the free space is unknown).
    static func budgetBytes(size: Int64, holding: Int64, freeSpace: Int64) -> Int64 {
        guard freeSpace >= 0 else { return size }
        return min(size, max(0, holding + freeSpace - minFreeBytes))
    }
}
