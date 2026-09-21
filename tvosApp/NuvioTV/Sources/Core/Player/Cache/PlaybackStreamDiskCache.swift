import Foundation
import OSLog

let diskCacheLog = Logger(subsystem: "com.pyksel.nuviotvos", category: "diskcache")

/// Metadata descriptor stored alongside cached video chunks to verify stream identity
/// and enable safe chunk reuse across renewed URLs without cross-stream mixing.
struct PlaybackStreamManifest: Codable, Equatable, Sendable {
    var sessionID: String
    var fileLength: Int64
    var etag: String?
    var lastModified: String?
    var canonicalMediaKey: String?
    var cacheFileIdentity: String? = nil
    var requestIdentityKey: String? = nil
    var filename: String?
    var normalizedURLPath: String
    var createdAt: Date
    var lastAccessedAt: Date
}

/// Manages chunk-based video caching to Apple TV local flash storage with a sliding-window FIFO eviction policy.
actor PlaybackStreamDiskCache {
    /// 2 MiB per chunk allows fine-grained range fetching, efficient SSD page writes, and low seek latency.
    static let defaultChunkSize: Int64 = 2 * 1024 * 1024
    /// Keep at least 2.0 GiB of free flash storage on Apple TV for system and app breathing room.
    static let defaultFreeSpaceReserveBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Preserve the container header (MKV SeekHead/Tracks, MP4 ftyp/moov) at the start of the stream
    /// so seeking, track changes, and engine re-opens avoid re-downloading container metadata.
    static let defaultHeaderProtectBytes: Int64 = 8 * 1024 * 1024 // 8 MiB (4 chunks @ 2 MiB)
    /// Preserve a rewind margin directly behind the active playhead so quick rewinds (10s/30s/60s)
    /// land on cached disk storage rather than triggering immediate network fetches.
    static let defaultRewindMarginBytes: Int64 = 64 * 1024 * 1024 // 64 MiB (~32 chunks @ 2 MiB)

    typealias FreeSpaceProvider = @Sendable (URL) -> Int64

    nonisolated let sessionID: String
    nonisolated let fileLength: Int64
    nonisolated let chunkSize: Int64
    nonisolated let cacheDirectory: URL
    /// Startup inventory lets the HTTP server avoid a disk-actor hop for cold
    /// chunks while an unrelated write is in progress. Reads still verify files.
    nonisolated let initialCachedChunkIndices: Set<Int>
    private var maxCacheSizeBytes: Int64
    private let freeSpaceReserveBytes: Int64
    private let headerProtectBytes: Int64
    private let rewindMarginBytes: Int64
    private let freeSpaceProvider: FreeSpaceProvider
    private var cachedChunkIndices: Set<Int> = []
    private var chunkAccessOrder: [Int] = []

    init(
        sessionID: String,
        fileLength: Int64,
        chunkSize: Int64 = defaultChunkSize,
        maxCacheSizeBytes: Int64 = 20 * 1024 * 1024 * 1024, // 20 GB default
        freeSpaceReserveBytes: Int64 = defaultFreeSpaceReserveBytes,
        headerProtectBytes: Int64 = defaultHeaderProtectBytes,
        rewindMarginBytes: Int64 = defaultRewindMarginBytes,
        cacheRoot: URL? = nil,
        manifest: PlaybackStreamManifest? = nil,
        freeSpaceProvider: FreeSpaceProvider? = nil
    ) {
        self.sessionID = sessionID
        self.fileLength = fileLength
        self.chunkSize = chunkSize
        self.maxCacheSizeBytes = maxCacheSizeBytes
        self.freeSpaceReserveBytes = freeSpaceReserveBytes
        self.headerProtectBytes = headerProtectBytes
        self.rewindMarginBytes = rewindMarginBytes
        let resolvedProvider = freeSpaceProvider ?? { dir in Self.volumeFreeSpace(at: dir) }
        self.freeSpaceProvider = resolvedProvider

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = cacheRoot ?? caches.appendingPathComponent("PlaybackStreamCache", isDirectory: true)
        let directory = root.appendingPathComponent(sessionID, isDirectory: true)
        self.cacheDirectory = directory

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let manifest {
            Self.writeManifest(manifest, to: directory)
        } else if var existing = Self.readManifest(in: directory) {
            existing.lastAccessedAt = Date()
            Self.writeManifest(existing, to: directory)
        }

        let scanned = Self.scanExistingChunks(in: directory, fileLength: fileLength, chunkSize: chunkSize)
        self.cachedChunkIndices = scanned.chunks
        self.initialCachedChunkIndices = scanned.chunks
        self.chunkAccessOrder = scanned.order
        PlaybackStreamDiskBudget.shared.lock.withLock {
            _ = PlaybackStreamDiskBudget.shared.availableBytes(
                in: root, limit: maxCacheSizeBytes, preserving: directory,
                freeSpaceReserve: freeSpaceReserveBytes, freeSpaceProvider: resolvedProvider
            )
        }
    }

    nonisolated static func manifestURL(for directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    nonisolated static func readManifest(in directory: URL) -> PlaybackStreamManifest? {
        let url = manifestURL(for: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PlaybackStreamManifest.self, from: data)
    }

    nonisolated static func writeManifest(_ manifest: PlaybackStreamManifest, to directory: URL) {
        let url = manifestURL(for: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func volumeFreeSpace(at directory: URL) -> Int64 {
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let available = values.volumeAvailableCapacity else {
            return -1
        }
        return Int64(available)
    }

    var currentManifest: PlaybackStreamManifest? {
        Self.readManifest(in: cacheDirectory)
    }

    nonisolated var totalChunks: Int {
        guard fileLength > 0 else { return 0 }
        return Int((fileLength + chunkSize - 1) / chunkSize)
    }

    var currentCachedBytes: Int64 {
        discardMissingSession()
        let fullChunks = Int64(cachedChunkIndices.count) * chunkSize
        let lastChunk = totalChunks - 1
        let padding = cachedChunkIndices.contains(lastChunk) ? Int64(totalChunks) * chunkSize - fileLength : 0
        return fullChunks - padding
    }

    var cachedFraction: Double {
        discardMissingSession()
        guard fileLength > 0, totalChunks > 0 else { return 0 }
        return Double(cachedChunkIndices.count) / Double(totalChunks)
    }

    // MARK: - Chunk Operations

    nonisolated func chunkIndex(forByteOffset offset: Int64) -> Int {
        guard chunkSize > 0 else { return 0 }
        return Int(offset / chunkSize)
    }

    nonisolated func byteRange(forChunk index: Int) -> Range<Int64> {
        let start = Int64(index) * chunkSize
        let end = min(start + chunkSize, fileLength)
        return start..<end
    }

    private func discardMissingSession() {
        guard !FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        cachedChunkIndices.removeAll()
        chunkAccessOrder.removeAll()
    }

    func isChunkCached(_ index: Int) -> Bool {
        guard cachedChunkIndices.contains(index) else { return false }
        guard FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("chunk_\(index).bin").path) else {
            cachedChunkIndices.remove(index)
            chunkAccessOrder.removeAll { $0 == index }
            return false
        }
        return true
    }

    func contiguousCachedBytesAhead(of byteOffset: Int64) -> Int64 {
        discardMissingSession()
        let startChunk = chunkIndex(forByteOffset: byteOffset)
        let total = totalChunks
        guard startChunk < total else { return 0 }
        var contiguousChunks = 0
        for c in startChunk..<total {
            if cachedChunkIndices.contains(c) {
                contiguousChunks += 1
            } else {
                break
            }
        }
        return Int64(contiguousChunks) * chunkSize
    }

    func hasByteRangeCached(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        let startChunk = chunkIndex(forByteOffset: range.lowerBound)
        let endChunk = chunkIndex(forByteOffset: max(range.lowerBound, range.upperBound - 1))
        for chunk in startChunk...endChunk {
            if !cachedChunkIndices.contains(chunk) { return false }
        }
        return true
    }

    func readChunk(_ index: Int) -> Data? {
        guard cachedChunkIndices.contains(index) else { return nil }
        let fileURL = cacheDirectory.appendingPathComponent("chunk_\(index).bin")
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedChunkIndices.remove(index)
            return nil
        }
        guard data.count == Int(byteRange(forChunk: index).count) else {
            cachedChunkIndices.remove(index)
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        touchChunk(index)
        return data
    }

    /// Background work must not download a chunk that eviction would immediately discard.
    func canPrefetchChunk(_ index: Int, playheadOffset: Int64, evictBehindPlayhead: Bool) -> Bool {
        discardMissingSession()
        guard index >= 0, index < totalChunks else { return false }
        if cachedChunkIndices.contains(index) { return true }
        let playheadChunk = chunkIndex(forByteOffset: max(0, playheadOffset))
        guard index >= playheadChunk else { return false }

        // Headroom reserve: do not prefetch if disk free space is below the reserve.
        // Atomic writes require temporary staging space (2 * chunkBytes).
        let chunkBytes = Int64(byteRange(forChunk: index).count)
        let freeSpace = freeSpaceProvider(cacheDirectory)
        if freeSpace >= 0 {
            let writeOverhead = chunkBytes * 2
            guard freeSpace - writeOverhead >= freeSpaceReserveBytes else {
                return false
            }
        }

        let reclaimable = evictBehindPlayhead ? cachedChunkIndices.reduce(Int64(0)) { bytes, chunk in
            bytes + (chunk < playheadChunk ? Int64(byteRange(forChunk: chunk).count) : 0)
        } : 0
        return currentCachedBytes + chunkBytes - reclaimable <= maxCacheSizeBytes
    }

    @discardableResult
    func writeChunk(
        _ index: Int, data: Data, playheadOffset: Int64 = -1, prefetchEvictsBehind: Bool? = nil
    ) -> Bool {
        guard index >= 0, index < totalChunks,
              data.count == Int(byteRange(forChunk: index).count) else { return false }
        return PlaybackStreamDiskBudget.shared.lock.withLock {
            discardMissingSession()
            if let prefetchEvictsBehind,
               !canPrefetchChunk(index, playheadOffset: playheadOffset, evictBehindPlayhead: prefetchEvictsBehind) {
                return true // Demand may still consume the fetched bytes; do not displace its cache.
            }

            // Headroom check: atomic write requires 2x data.count staging space.
            // If storage is tight, try evicting behind playhead or reject write.
            let freeSpace = freeSpaceProvider(cacheDirectory)
            let writeOverhead = Int64(data.count) * 2
            if freeSpace >= 0 && freeSpace - writeOverhead < freeSpaceReserveBytes {
                enforceSlidingWindow(playheadOffset: playheadOffset, limit: max(0, currentCachedBytes - Int64(data.count)))
                let rechecked = freeSpaceProvider(cacheDirectory)
                if rechecked >= 0 && rechecked - writeOverhead < freeSpaceReserveBytes {
                    diskCacheLog.warning("Free-space reserve boundary reached (\(rechecked) bytes free). Skipping disk write for chunk \(index).")
                    return false
                }
            }

            let fileURL = cacheDirectory.appendingPathComponent("chunk_\(index).bin")
            do {
                // The OS may purge Caches between initialization and a later write.
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                cachedChunkIndices.insert(index)
                touchChunk(index)
                return enforceBudget(playheadOffset: playheadOffset)
            } catch {
                diskCacheLog.error("Failed to write chunk \(index): \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Called under the shared budget lock, so simultaneous sessions cannot overcommit it.
    @discardableResult
    private func enforceBudget(playheadOffset: Int64) -> Bool {
        let budget = PlaybackStreamDiskBudget.shared
        enforceSlidingWindow(playheadOffset: playheadOffset, limit: maxCacheSizeBytes)
        budget.record(cacheDirectory, bytes: currentCachedBytes)
        let available = budget.availableBytes(
            in: cacheDirectory.deletingLastPathComponent(),
            limit: maxCacheSizeBytes, preserving: cacheDirectory,
            freeSpaceReserve: freeSpaceReserveBytes, freeSpaceProvider: freeSpaceProvider
        )
        // Failed removal of an older session must not grant nonexistent capacity.
        enforceSlidingWindow(playheadOffset: playheadOffset, limit: available)
        budget.record(cacheDirectory, bytes: currentCachedBytes)
        return currentCachedBytes <= available
    }

    func readBytes(offset: Int64, length: Int) -> Data? {
        guard length > 0, offset >= 0, offset < fileLength else { return nil }
        let endOffset = min(offset + Int64(length), fileLength)
        let requiredRange = offset..<endOffset
        guard hasByteRangeCached(requiredRange) else { return nil }

        var result = Data(capacity: length)
        let startChunk = chunkIndex(forByteOffset: offset)
        let endChunk = chunkIndex(forByteOffset: endOffset - 1)

        for c in startChunk...endChunk {
            guard let chunkData = readChunk(c) else { return nil }
            let chunkRange = byteRange(forChunk: c)
            let readStart = max(offset, chunkRange.lowerBound) - chunkRange.lowerBound
            let readEnd = min(endOffset, chunkRange.upperBound) - chunkRange.lowerBound
            guard readStart >= 0, readEnd <= chunkData.count, readStart <= readEnd else { return nil }
            result.append(chunkData[Data.Index(readStart)..<Data.Index(readEnd)])
        }
        return result
    }

    // MARK: - Sliding Window & FIFO Eviction

    /// Categorizes a chunk into an eviction priority tier relative to the playhead and protected regions:
    /// - Tier 1: Old watched footage behind the rewind margin (evicted first, oldest footage a < b)
    /// - Tier 2: Watched footage inside the rewind margin (evicted only after old footage is exhausted, a < b)
    /// - Tier 3: Container header at offset 0 (evicted only after watched & rewind footage is exhausted, a < b)
    /// - Tier 4: Current & future prefetch at/ahead of playhead (evicted last from the far end backward, a > b)
    private func evictionTier(for chunk: Int, playheadChunk: Int) -> Int {
        guard playheadChunk >= 0 else { return 4 }
        let headerChunks = max(0, Int(headerProtectBytes / max(1, chunkSize)))
        let rewindChunks = max(0, Int(rewindMarginBytes / max(1, chunkSize)))
        let rewindBoundary = max(headerChunks, playheadChunk - rewindChunks)

        if chunk >= playheadChunk {
            return 4
        } else if chunk < headerChunks {
            return 3
        } else if chunk >= rewindBoundary {
            return 2
        } else {
            return 1
        }
    }

    /// Evicts chunks when disk usage exceeds the allocated limit using a tiered sliding window:
    /// Old watched footage is evicted first, preserving container headers and the immediate rewind buffer.
    private func enforceSlidingWindow(playheadOffset: Int64, limit: Int64) {
        guard currentCachedBytes > limit else { return }
        let playheadChunk = playheadOffset >= 0 ? chunkIndex(forByteOffset: playheadOffset) : -1

        let sortedChunks = Array(cachedChunkIndices).sorted { a, b in
            let tierA = evictionTier(for: a, playheadChunk: playheadChunk)
            let tierB = evictionTier(for: b, playheadChunk: playheadChunk)
            if tierA != tierB {
                return tierA < tierB
            }
            if tierA == 4 {
                return a > b
            } else {
                return a < b
            }
        }

        for chunkToEvict in sortedChunks {
            guard currentCachedBytes > limit else { break }
            deleteChunk(chunkToEvict)
        }
    }

    private func touchChunk(_ index: Int) {
        if let idx = chunkAccessOrder.firstIndex(of: index) {
            chunkAccessOrder.remove(at: idx)
        }
        chunkAccessOrder.append(index)
    }

    private func deleteChunk(_ index: Int) {
        let fileURL = cacheDirectory.appendingPathComponent("chunk_\(index).bin")
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            guard (error as NSError).domain == NSCocoaErrorDomain,
                  (error as NSError).code == NSFileNoSuchFileError else {
                diskCacheLog.error("Failed to evict chunk \(index): \(error.localizedDescription)")
                return
            }
        }
        cachedChunkIndices.remove(index)
        chunkAccessOrder.removeAll { $0 == index }
    }

    private static func scanExistingChunks(
        in directory: URL, fileLength: Int64, chunkSize: Int64
    ) -> (chunks: Set<Int>, order: [Int]) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return ([], []) }
        var chunks = Set<Int>()
        var order = [Int]()
        let total = (fileLength + chunkSize - 1) / chunkSize
        for file in files where file.lastPathComponent.hasPrefix("chunk_") && file.pathExtension == "bin" {
            let indexStr = file.deletingPathExtension().lastPathComponent.dropFirst("chunk_".count)
            guard let index = Int(indexStr), index >= 0, Int64(index) < total,
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == min(chunkSize, fileLength - Int64(index) * chunkSize) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            chunks.insert(index)
            order.append(index)
        }
        return (chunks, order)
    }

    func setMaxCacheSizeBytes(_ bytes: Int64) {
        PlaybackStreamDiskBudget.shared.lock.withLock {
            maxCacheSizeBytes = max(100 * 1024 * 1024, bytes)
            enforceBudget(playheadOffset: -1)
        }
    }

    func purge() {
        PlaybackStreamDiskBudget.shared.lock.withLock {
            cachedChunkIndices.removeAll()
            chunkAccessOrder.removeAll()
            try? FileManager.default.removeItem(at: cacheDirectory)
            PlaybackStreamDiskBudget.shared.forget(cacheDirectory)
        }
    }

    /// Returns a list of contiguous cached byte ranges for timeline visualization.
    func contiguousCachedByteRanges() -> [Range<Int64>] {
        discardMissingSession()
        let sorted = cachedChunkIndices.sorted()
        guard !sorted.isEmpty else { return [] }

        var ranges: [Range<Int64>] = []
        var currentRange: Range<Int64>? = nil

        for chunkIdx in sorted {
            let chunkR = byteRange(forChunk: chunkIdx)
            if let active = currentRange {
                if active.upperBound == chunkR.lowerBound {
                    currentRange = active.lowerBound..<chunkR.upperBound
                } else {
                    ranges.append(active)
                    currentRange = chunkR
                }
            } else {
                currentRange = chunkR
            }
        }
        if let active = currentRange { ranges.append(active) }
        return ranges
    }
}

/// Serializes global budget enforcement across cache actors. Directory timestamps let us
/// reuse sizes for unchanged sessions instead of walking every chunk on every write.
final class PlaybackStreamDiskBudget: @unchecked Sendable {
    static let shared = PlaybackStreamDiskBudget()
    let lock = NSLock()
    private var sizes: [URL: (date: Date?, bytes: Int64)] = [:]

    func record(_ directory: URL, bytes: Int64) {
        let date = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        sizes[directory] = (date, bytes)
    }

    func forget(_ directory: URL) {
        sizes.removeValue(forKey: directory)
    }

    /// Returns capacity left for the preserved session after pruning other titles.
    /// The caller holds `lock` during mutations and this check.
    func availableBytes(
        in root: URL, limit: Int64, preserving current: URL,
        freeSpaceReserve: Int64 = PlaybackStreamDiskCache.defaultFreeSpaceReserveBytes,
        freeSpaceProvider: ((URL) -> Int64)? = nil
    ) -> Int64 {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        let present = Set(directories)
        sizes = sizes.filter { $0.key.deletingLastPathComponent() != root || present.contains($0.key) }
        var sessions: [(url: URL, date: Date, bytes: Int64)] = []
        for directory in directories {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true else { continue }
            let bytes: Int64
            if let known = sizes[directory], known.date == values.contentModificationDate {
                bytes = known.bytes
            } else {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.fileSizeKey]
                ) else { return 0 }
                bytes = files.reduce(0) { sum, file in
                    sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                sizes[directory] = (values.contentModificationDate, bytes)
            }
            sessions.append((directory, values.contentModificationDate ?? .distantPast, bytes))
        }
        let currentBytes = sessions.first { $0.url == current }?.bytes ?? 0
        var otherBytes = sessions.filter { $0.url != current }.reduce(Int64(0)) { $0 + $1.bytes }
        let provider = freeSpaceProvider ?? { dir in PlaybackStreamDiskCache.volumeFreeSpace(at: dir) }

        for session in sessions.filter({ $0.url != current }).sorted(by: { $0.date < $1.date }) {
            let volumeFree = provider(root)
            let isOverBudget = currentBytes + otherBytes > limit
            let isUnderReserve = volumeFree >= 0 && volumeFree < freeSpaceReserve
            guard isOverBudget || isUnderReserve else { break }
            do {
                try FileManager.default.removeItem(at: session.url)
                otherBytes -= session.bytes
                sizes.removeValue(forKey: session.url)
            } catch {
                diskCacheLog.error("Failed to prune cached session: \(error.localizedDescription)")
            }
        }
        let volumeFree = provider(root)
        let budgetAllowance = max(0, limit - otherBytes)
        let headroomAllowance = volumeFree >= 0 ? max(0, volumeFree + currentBytes - freeSpaceReserve) : limit
        return max(0, min(budgetAllowance, headroomAllowance))
    }
}
