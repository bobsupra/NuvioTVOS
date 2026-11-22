import Foundation

/// How much memory the engine may use for decoded articles, and how far it
/// reads ahead of the player. Mirrors the profiles of NuvioTV (Android).
enum UsenetMemoryProfile: String, CaseIterable, Sendable {
    case lowMemory
    case balanced
    case highThroughput

    var cacheBytes: Int {
        switch self {
        case .lowMemory: return 32 << 20
        case .balanced: return 64 << 20
        case .highThroughput: return 128 << 20
        }
    }

    /// Read-ahead as a share of the cache, so prefetched articles aren't
    /// evicted before the player reaches them.
    var readAheadBytes: Int { cacheBytes * 3 / 5 }

    var title: String {
        switch self {
        case .lowMemory: return L10n.string("usenet_profile_low", fallback: "Low Memory")
        case .balanced: return L10n.string("usenet_profile_balanced", fallback: "Balanced")
        case .highThroughput: return L10n.string("usenet_profile_high", fallback: "High Throughput")
        }
    }
}

/// Where each article's decoded bytes sit in the file.
///
/// Posters split files into equal parts, so after decoding the first article
/// (`=ypart begin/end`, `=ybegin size`) every other article's range follows
/// arithmetically. When the article count doesn't fit that, ranges learned
/// from decoded articles are used and the rest are estimated from the NZB's
/// encoded sizes and corrected as articles arrive.
struct UsenetFileLayout: Sendable, Equatable {
    let totalSize: Int64
    let partSize: Int64
    let segmentCount: Int
    /// Equal parts that add up to `totalSize`.
    let isRegular: Bool
    /// Cumulative encoded sizes, for estimating irregular layouts.
    private let encodedStarts: [Int64]
    private let encodedTotal: Int64
    private(set) var known: [Int: Range<Int64>] = [:]

    init(totalSize: Int64, firstPart: Range<Int64>, segments: [UsenetSegment]) {
        self.totalSize = totalSize
        self.segmentCount = segments.count
        let part = max(1, firstPart.upperBound - firstPart.lowerBound)
        self.partSize = part
        let expected = Int((totalSize + part - 1) / part)
        self.isRegular = expected == segments.count && firstPart.lowerBound == 0
        var starts: [Int64] = []
        var running: Int64 = 0
        for segment in segments {
            starts.append(running)
            running += Int64(max(1, segment.bytes))
        }
        self.encodedStarts = starts
        self.encodedTotal = max(1, running)
        known[0] = firstPart
    }

    mutating func learn(_ index: Int, range: Range<Int64>) {
        known[index] = range
    }

    /// The bytes article `index` holds, when known or regular.
    func range(of index: Int) -> Range<Int64>? {
        if let range = known[index] { return range }
        guard isRegular, index >= 0, index < segmentCount else { return nil }
        let start = Int64(index) * partSize
        return start..<min(totalSize, start + partSize)
    }

    /// The article holding `offset`, or the best guess to probe next.
    func index(for offset: Int64) -> (index: Int, certain: Bool) {
        if isRegular {
            return (min(segmentCount - 1, max(0, Int(offset / partSize))), true)
        }
        if let hit = known.first(where: { $0.value.contains(offset) }) {
            return (hit.key, true)
        }
        // Scale the offset into the encoded sizes, then nudge by neighbours we know.
        let target = Int64(Double(offset) / Double(max(1, totalSize)) * Double(encodedTotal))
        var low = 0, high = segmentCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if encodedStarts[mid] <= target { low = mid } else { high = mid - 1 }
        }
        var guess = low
        if let below = known.filter({ $0.value.upperBound <= offset }).max(by: { $0.key < $1.key }) {
            guess = max(guess, below.key + 1)
        }
        if let above = known.filter({ $0.value.lowerBound > offset }).min(by: { $0.key < $1.key }) {
            guess = min(guess, above.key - 1)
        }
        return (min(segmentCount - 1, max(0, guess)), false)
    }
}

/// Counters a session exposes to the stats overlay.
struct UsenetSessionStats: Equatable, Sendable {
    var downloadedBytes: Int64 = 0
    var missingArticles = 0
    var cacheHits = 0
    var cacheMisses = 0
    var bufferedAheadBytes: Int64 = 0
    /// The same in seconds of video, once the player knows the duration.
    var bufferedAheadSeconds: Double?
    var cachedBytes = 0
    /// Articles kept on disk (Read Ahead on Disk), what they may use now and what tvOS
    /// reports free (-1: unknown).
    var diskBytes: Int64 = 0
    var diskBudgetBytes: Int64 = 0
    var diskFreeBytes: Int64 = -1
}

/// Serves byte ranges of the played file to the local HTTP server, fetching
/// and decoding articles on demand with read-ahead and an in-memory cache.
///
/// The played file can span several NZB files (RAR volumes, raw splits):
/// `source.extents` say where its bytes sit. Articles are numbered globally
/// across the volumes, in order, so read-ahead runs straight through them.
actor UsenetStreamSession {
    let source: UsenetStreamSource
    private let pool: UsenetConnectionPool
    private let profile: UsenetMemoryProfile

    private var layouts: [UsenetFileLayout]
    /// Global number of each volume's first article.
    private let bases: [Int]
    private let extentStarts: [Int64]
    private let articleCount: Int
    let totalSize: Int64

    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var cachedBytes = 0
    private var inflight: [Int: Task<Data, Error>] = [:]
    private var prefetching: Set<Int> = []
    private var playhead = 0
    /// The articles holding the start and the end of the file (the MKV header
    /// and its seek index): never evicted, as a player may read them again
    /// on a seek.
    private var pinned: Set<Int> = []
    /// Fetches still waiting for the speed cap or a connection, by article:
    /// one the player now needs sooner can be moved up.
    private var queued: [Int: QueuedFetch] = [:]

    private struct QueuedFetch {
        let priority: UsenetConnectionPool.FetchPriority
        let token: UUID
        /// Still held back by the speed cap (read-ahead with a cap set).
        var waitingForCap: Bool
    }

    private var counters = UsenetSessionStats()

    /// Recent article outcomes (true = missing), for spotting a release that
    /// is too damaged to keep playing.
    private var recentOutcomes: [Bool] = []
    private var consecutiveMissing = 0
    private var reportedDamage = false
    private let onDamaged: @Sendable () -> Void
    /// Bytes of video per second, once the player knows the duration.
    private var bytesPerSecond: Double?

    /// Read Ahead on Disk: the read-ahead reaches most of its budget past the memory one,
    /// and every article fetched stays on disk until the stream stops (the ones farthest
    /// behind the playhead go first when the budget is full), so a seek into what was
    /// downloaded doesn't download it again.
    private let diskReadAhead: UsenetDiskReadAhead?
    /// Articles on disk and their sizes.
    private var onDisk: [Int: Int] = [:]
    private var diskBytes: Int64 = 0
    /// Articles on their way to the disk, served from here meanwhile.
    private var writing: [Int: Data] = [:]
    /// Articles being read back from the disk.
    private var diskLoads: [Int: Task<Data, Error>] = [:]
    private var diskStopped = false
    /// What the disk read-ahead may use now: the chosen size, as far as the free space allows
    /// (checked again every few articles written).
    private var diskBudgetBytes: Int64 = 0
    private var diskFreeBytes: Int64 = -1
    /// Articles written or read since the free space was last checked.
    private var eventsSinceSpaceCheck = 0
    private var spaceCheckRunning = false
    static let spaceCheckEvery = 16
    /// A write failed (the disk is full): memory only from then on.
    private var diskFailed = false
    /// Reading ahead onto the disk: on, writing works, and the free space leaves it room.
    private var diskActive: Bool {
        diskReadAhead != nil && !diskStopped && !diskFailed
            && diskBudgetBytes >= UsenetDiskReadAhead.minActiveBytes
    }

    init(source: UsenetStreamSource, pool: UsenetConnectionPool, profile: UsenetMemoryProfile,
         diskReadAhead: UsenetDiskReadAhead? = nil,
         onDamaged: @escaping @Sendable () -> Void = {}) {
        self.source = source
        self.pool = pool
        self.profile = profile
        self.diskReadAhead = diskReadAhead
        self.diskBudgetBytes = diskReadAhead?.sizeBytes ?? 0
        self.onDamaged = onDamaged
        var layouts: [UsenetFileLayout] = []
        var bases: [Int] = []
        var running = 0
        for (volume, head) in zip(source.volumes, source.firstArticles) {
            let size = Int64(head.header.size ?? head.data.count)
            let begin = Int64(head.fileOffset)
            layouts.append(UsenetFileLayout(
                totalSize: size,
                firstPart: begin..<(begin + Int64(head.data.count)),
                segments: volume.segments
            ))
            bases.append(running)
            running += volume.segments.count
        }
        self.layouts = layouts
        self.bases = bases
        self.articleCount = running
        self.extentStarts = source.extentStarts
        self.totalSize = source.totalSize
    }

    /// Keeps the first articles that hold the start and the end of the file,
    /// then warms the head and the tail (MKV keeps its seek index at the end).
    func prepare() async throws {
        guard articleCount > 0, totalSize > 0, let first = source.extents.first, let last = source.extents.last else {
            throw UsenetError.noPlayableFile
        }
        var ends: Set<Int> = []
        if let start = globalIndex(at: 0) { ends.formUnion([start, start + 1]) }
        if let end = globalIndex(at: totalSize - 1) { ends.formUnion([end - 1, end]) }
        pinned = ends.filter { $0 >= 0 && $0 < articleCount }
        for volume in Set([first.volume, last.volume]) {
            store(bases[volume], source.firstArticles[volume].data)
            counters.downloadedBytes += Int64(source.firstArticles[volume].data.count)
        }
        var warm: Set<Int> = []
        if let start = globalIndex(at: 0) { warm.insert(start + 1) }
        if let end = globalIndex(at: totalSize - 1) {
            warm.insert(end)
            warm.insert(end - 1)
        }
        for index in warm where index >= 0 && index < articleCount { startPrefetch(index) }
        if let start = globalIndex(at: 0) { prefetch(after: start) }
        checkDiskSpace()
    }

    /// Up to `maxLength` bytes starting at `offset`, never crossing an article
    /// or extent boundary. Side reads (the player's index lookups at the end of
    /// the file) pass `updatesPlayhead: false` so they don't move the read-ahead.
    func read(offset: Int64, maxLength: Int, updatesPlayhead: Bool = true) async throws -> Data {
        guard offset < totalSize,
              let place = UsenetStreamSource.locate(offset, extents: source.extents, starts: extentStarts) else { return Data() }
        let extent = source.extents[place.extent]
        let volume = extent.volume
        let extentEnd = extentStarts[place.extent] + extent.length
        let limit = Int(min(Int64(maxLength), extentEnd - offset))
        let target = place.volumeOffset
        let segmentCount = source.volumes[volume].segments.count

        var probe = layouts[volume].index(for: target)
        let firstProbeCertain = probe.certain
        var hops = 0
        while true {
            let global = bases[volume] + probe.index
            // The player's own article goes first in line, then the read-ahead
            // moves: after a seek the next articles download together with it,
            // not after it. A guessed position waits until it is confirmed.
            let pending = demand(global)
            if updatesPlayhead, hops == 0, firstProbeCertain { noteRead(global) }
            let data = try await finish(global, pending)
            guard let range = layouts[volume].range(of: probe.index) else { throw UsenetError.noPlayableFile }
            if range.contains(target) {
                if updatesPlayhead, hops > 0 || !firstProbeCertain { noteRead(global) }
                let start = Int(target - range.lowerBound)
                let end = min(data.count, start + limit)
                guard start < end else { return Data() }
                return data.subdata(in: start..<end)
            }
            // Irregular layout: walk towards the article that holds the offset.
            hops += 1
            guard hops < 64 else { throw UsenetError.noPlayableFile }
            let next = target < range.lowerBound ? probe.index - 1 : probe.index + 1
            guard next >= 0, next < segmentCount else { return Data() }
            probe = (next, false)
        }
    }

    func stats() -> UsenetSessionStats {
        var snapshot = counters
        snapshot.cachedBytes = cachedBytes
        var ahead: Int64 = 0
        var index = playhead + 1
        while let bytes = cache[index]?.count ?? writing[index]?.count ?? onDisk[index] {
            ahead += Int64(bytes)
            index += 1
        }
        snapshot.bufferedAheadBytes = ahead
        snapshot.bufferedAheadSeconds = bytesPerSecond.map { Double(ahead) / $0 }
        snapshot.diskBytes = diskBytes
        snapshot.diskBudgetBytes = diskReadAhead == nil ? 0 : diskBudgetBytes
        snapshot.diskFreeBytes = diskFreeBytes
        return snapshot
    }

    /// The video's length, from the player: sizes the read-ahead that the
    /// speed cap never holds back in seconds of video.
    func setDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 60, totalSize > 0 else { return }
        bytesPerSecond = Double(totalSize) / seconds
    }

    func stop() async {
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
        queued = [:]
        cache = [:]
        cacheOrder = []
        cachedBytes = 0
        previewStopped = true
        previewCache = [:]
        previewOrder = []
        previewCachedBytes = 0
        diskStopped = true
        diskLoads.values.forEach { $0.cancel() }
        diskLoads = [:]
        writing = [:]
        onDisk = [:]
        diskBytes = 0
        let preview = previewConnection
        previewConnection = nil
        await preview?.close()
        await pool.shutdown()
        await diskReadAhead?.store.removeAll()
    }

    // MARK: - Seek previews

    /// Seek previews read through one NNTP connection reserved from the pool (taken on the first
    /// preview, kept for the stream) and a small cache of their own. They never move the playhead
    /// or the read-ahead and never evict what playback holds; an article playback already has, or
    /// is fetching, is shared instead of downloaded twice.
    static let previewCacheBytes = 24 * 1024 * 1024
    /// Longest the reserved preview connection waits unused before it is replaced: providers
    /// drop idle connections after one to a few minutes.
    static let previewMaxIdle: Duration = .seconds(60)
    private var previewCache: [Int: Data] = [:]
    private var previewOrder: [Int] = []
    private var previewCachedBytes = 0
    private var previewConnection: UsenetNNTPConnection?
    /// Since when the reserved connection waits unused: past `previewMaxIdle` the
    /// server has likely dropped it, so a fresh one is opened before the next preview.
    private var previewIdleSince: ContinuousClock.Instant?
    private var previewSlotReserved = false
    private var previewUnavailable = false
    private var previewStopped = false
    /// Preview fetches run one after another: the reserved connection carries one command at a time.
    private var previewTail: Task<Void, Never>?

    /// Like `read`, for a seek preview.
    func previewRead(offset: Int64, maxLength: Int) async throws -> Data {
        guard !previewStopped, offset < totalSize,
              let place = UsenetStreamSource.locate(offset, extents: source.extents, starts: extentStarts) else { return Data() }
        let extent = source.extents[place.extent]
        let volume = extent.volume
        let extentEnd = extentStarts[place.extent] + extent.length
        let limit = Int(min(Int64(maxLength), extentEnd - offset))
        let target = place.volumeOffset
        let segmentCount = source.volumes[volume].segments.count

        var probe = layouts[volume].index(for: target)
        var hops = 0
        while true {
            let data = try await previewArticle(bases[volume] + probe.index)
            guard let range = layouts[volume].range(of: probe.index) else { throw UsenetError.noPlayableFile }
            if range.contains(target) {
                let start = Int(target - range.lowerBound)
                let end = min(data.count, start + limit)
                guard start < end else { return Data() }
                return data.subdata(in: start..<end)
            }
            hops += 1
            guard hops < 64 else { throw UsenetError.noPlayableFile }
            let next = target < range.lowerBound ? probe.index - 1 : probe.index + 1
            guard next >= 0, next < segmentCount else { return Data() }
            probe = (next, false)
        }
    }

    private func previewArticle(_ index: Int) async throws -> Data {
        if let data = cache[index] ?? writing[index] { return data }
        if let data = previewCache[index] {
            touchPreview(index)
            return data
        }
        if let task = inflight[index] ?? diskLoads[index] { return try await task.value }
        if onDisk[index] != nil, let data = await diskReadAhead?.store.read(index) {
            storePreview(index, data)
            return data
        }
        let place = split(index)
        let segment = source.volumes[place.volume].segments[place.index]
        let body = try await fetchPreviewBody(segment.messageID)
        if let data = cache[index] ?? previewCache[index] { return data }
        let decoded = try await Self.decode(body)
        let begin = Int64(decoded.fileOffset)
        layouts[place.volume].learn(place.index, range: begin..<(begin + Int64(decoded.data.count)))
        storePreview(index, decoded.data)
        return decoded.data
    }

    private func fetchPreviewBody(_ messageID: String) async throws -> Data {
        let previous = previewTail
        let task = Task { () throws -> Data in
            _ = await previous?.result
            return try await self.previewBody(messageID)
        }
        previewTail = Task { _ = await task.result }
        return try await task.value
    }

    private func previewBody(_ messageID: String) async throws -> Data {
        for attempt in 0..<2 {
            let connection = try await readyPreviewConnection()
            do {
                let body = try await connection.fetchBody(messageID: messageID)
                if previewConnection === connection { previewIdleSince = .now }
                return body
            } catch let error as UsenetNNTPError where error.isTransient && attempt == 0 {
                // The server dropped the idle connection: open a replacement once.
                await connection.close()
                if previewConnection === connection { previewConnection = nil }
            }
        }
        throw UsenetNNTPError.connectionClosed
    }

    private func readyPreviewConnection() async throws -> UsenetNNTPConnection {
        guard !previewStopped, !previewUnavailable else { throw UsenetNNTPError.notConnected }
        if let connection = previewConnection, !(await connection.isClosed) {
            guard let since = previewIdleSince, ContinuousClock.now - since > Self.previewMaxIdle else {
                return connection
            }
            // Idle too long (a pause, a while without previews): replace it rather than
            // have the first preview wait for it to fail.
            await connection.close()
            if previewConnection === connection { previewConnection = nil }
        }
        let connection: UsenetNNTPConnection
        if previewSlotReserved {
            connection = try await pool.reopenPreviewConnection()
        } else {
            guard let reserved = try await pool.reservePreviewConnection() else {
                previewUnavailable = true
                throw UsenetNNTPError.notConnected
            }
            previewSlotReserved = true
            connection = reserved
        }
        guard !previewStopped else {
            await connection.close()
            throw CancellationError()
        }
        previewConnection = connection
        previewIdleSince = .now
        return connection
    }

    private func storePreview(_ index: Int, _ data: Data) {
        if previewCache[index] == nil { previewCachedBytes += data.count }
        previewCache[index] = data
        touchPreview(index)
        while previewCachedBytes > Self.previewCacheBytes, let oldest = previewOrder.first {
            previewOrder.removeFirst()
            if let removed = previewCache.removeValue(forKey: oldest) { previewCachedBytes -= removed.count }
        }
    }

    private func touchPreview(_ index: Int) {
        if let position = previewOrder.firstIndex(of: index) { previewOrder.remove(at: position) }
        previewOrder.append(index)
    }

    // MARK: - Addressing

    /// The global article holding byte `offset` of the played file (a guess
    /// for irregular layouts, good enough for warming).
    private func globalIndex(at offset: Int64) -> Int? {
        guard let place = UsenetStreamSource.locate(offset, extents: source.extents, starts: extentStarts) else { return nil }
        let volume = source.extents[place.extent].volume
        return bases[volume] + layouts[volume].index(for: place.volumeOffset).index
    }

    /// Volume and local article number of a global article.
    private func split(_ global: Int) -> (volume: Int, index: Int) {
        var low = 0
        var high = bases.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if bases[mid] <= global { low = mid } else { high = mid - 1 }
        }
        return (low, global - bases[low])
    }

    // MARK: - Articles

    private enum Demand {
        case cached(Data)
        case fetching(Task<Data, Error>)
    }

    /// The player's own article: from the cache, from a read-ahead fetch
    /// already on its way (moved up if it still waits its turn), or from a
    /// new fetch first in line at the server.
    private func demand(_ index: Int) -> Demand {
        if let data = cache[index] {
            counters.cacheHits += 1
            touch(index)
            return .cached(data)
        }
        if let data = writing[index] {
            counters.cacheHits += 1
            store(index, data)
            return .cached(data)
        }
        if let task = inflight[index] {
            // Take over the read-ahead instead of fetching twice.
            if prefetching.remove(index) != nil { counters.cacheHits += 1 }
            return .fetching(promote(index, to: .playback, onlyWhileWaitingForCap: false) ?? task)
        }
        if let task = diskLoads[index] ?? (onDisk[index] != nil ? loadFromDisk(index) : nil) {
            counters.cacheHits += 1
            return .fetching(task)
        }
        counters.cacheMisses += 1
        return .fetching(startFetch(index, priority: .playback))
    }

    /// An article back from the disk into memory; downloaded again if its file is gone.
    @discardableResult
    private func loadFromDisk(_ index: Int) -> Task<Data, Error>? {
        if let task = diskLoads[index] { return task }
        guard let store = diskReadAhead?.store else { return nil }
        let task = Task { () throws -> Data in
            if let data = await store.read(index) {
                self.loadedFromDisk(index, data)
                return data
            }
            let lost = self.lostOnDisk(index)
            defer { if lost.started { self.clearFetch(index, lost.task) } }
            return try await lost.task.value
        }
        diskLoads[index] = task
        return task
    }

    private func loadedFromDisk(_ index: Int, _ data: Data) {
        diskLoads[index] = nil
        guard !diskStopped else { return }
        store(index, data)
    }

    /// The file is gone: forget it and download the article (or join a download on its way).
    private func lostOnDisk(_ index: Int) -> (task: Task<Data, Error>, started: Bool) {
        diskLoads[index] = nil
        if let bytes = onDisk.removeValue(forKey: index) { diskBytes -= Int64(bytes) }
        rescan(from: index)
        if let task = inflight[index] { return (task, false) }
        return (startFetch(index, priority: .playback), true)
    }

    private func clearFetch(_ index: Int, _ task: Task<Data, Error>) {
        if inflight[index] == task { clearInflight(index) }
    }

    private func finish(_ index: Int, _ demand: Demand) async throws -> Data {
        switch demand {
        case .cached(let data):
            return data
        case .fetching(let task):
            defer { if inflight[index] == task { clearInflight(index) } }
            return try await task.value
        }
    }

    private func startFetch(_ index: Int, priority: UsenetConnectionPool.FetchPriority) -> Task<Data, Error> {
        let token = UUID()
        let task = makeTask(index, priority: priority, token: token)
        inflight[index] = task
        queued[index] = QueuedFetch(
            priority: priority,
            token: token,
            waitingForCap: priority == .readAhead && pool.speedLimitMbps > 0
        )
        return task
    }

    private func fetchProgressed(_ index: Int, token: UUID, _ progress: UsenetConnectionPool.FetchProgress) {
        guard queued[index]?.token == token else { return }
        switch progress {
        case .passedCap:
            queued[index]?.waitingForCap = false
        case .connected:
            // Downloading (or opening a connection): restarting it would only lose time.
            queued[index] = nil
        }
    }

    /// Starts `index` again with a more urgent priority while its fetch still
    /// waits (for the cap, or also for a connection); nil when it is already
    /// downloading or urgent enough.
    private func promote(_ index: Int, to priority: UsenetConnectionPool.FetchPriority,
                         onlyWhileWaitingForCap: Bool) -> Task<Data, Error>? {
        guard let entry = queued[index], Self.urgency(entry.priority) < Self.urgency(priority),
              !onlyWhileWaitingForCap || entry.waitingForCap,
              let old = inflight[index] else { return nil }
        old.cancel()
        return startFetch(index, priority: priority)
    }

    private static func urgency(_ priority: UsenetConnectionPool.FetchPriority) -> Int {
        switch priority {
        case .startup, .readAhead: return 0
        case .next: return 1
        case .playback: return 2
        }
    }

    private func clearInflight(_ index: Int) {
        inflight[index] = nil
        queued[index] = nil
    }

    private func makeTask(_ index: Int, priority: UsenetConnectionPool.FetchPriority, token: UUID) -> Task<Data, Error> {
        let place = split(index)
        let segment = source.volumes[place.volume].segments[place.index]
        let pool = self.pool
        return Task {
            let outcome = try await pool.fetch(
                messageID: segment.messageID,
                expectedBytes: segment.bytes,
                priority: priority,
                onProgress: { progress in Task { await self.fetchProgressed(index, token: token, progress) } }
            )
            switch outcome {
            case .body(let body):
                let decoded = try await Self.decode(body)
                self.accept(index, place, decoded)
                return decoded.data
            case .missing:
                // Keep playing past a hole rather than failing the whole stream:
                // the player usually skips a damaged frame.
                let filler = self.filler(for: index, place)
                self.counters.missingArticles += 1
                self.recordOutcome(missing: true)
                return filler
            }
        }
    }

    private func accept(_ index: Int, _ place: (volume: Int, index: Int), _ decoded: UsenetYEncSegment) {
        let begin = Int64(decoded.fileOffset)
        layouts[place.volume].learn(place.index, range: begin..<(begin + Int64(decoded.data.count)))
        // Read-ahead past the memory one goes to the disk only, so it doesn't push out what
        // the player needs first; everything else is kept in both.
        if !diskActive || index <= playhead + readAheadSegments {
            store(index, decoded.data)
        }
        keepOnDisk(index, decoded.data)
        counters.downloadedBytes += Int64(decoded.data.count)
        recordOutcome(missing: false)
    }

    // MARK: - Damage

    static let damageConsecutiveMissing = 3
    static let damageWindow = 50
    static let damageMissingInWindow = 8

    /// A short hole (a damaged frame or two) is skipped; a run of missing
    /// articles, or many in a short stretch, means the release is broken.
    static func isDamaged(consecutiveMissing: Int, recent: [Bool]) -> Bool {
        consecutiveMissing >= damageConsecutiveMissing
            || recent.suffix(damageWindow).filter { $0 }.count >= damageMissingInWindow
    }

    private func recordOutcome(missing: Bool) {
        recentOutcomes.append(missing)
        if recentOutcomes.count > Self.damageWindow { recentOutcomes.removeFirst(recentOutcomes.count - Self.damageWindow) }
        consecutiveMissing = missing ? consecutiveMissing + 1 : 0
        guard !reportedDamage, Self.isDamaged(consecutiveMissing: consecutiveMissing, recent: recentOutcomes) else { return }
        reportedDamage = true
        usenetLog.error("usenet: release damaged (\(self.counters.missingArticles) missing articles), asking for another source")
        onDamaged()
    }

    private func filler(for index: Int, _ place: (volume: Int, index: Int)) -> Data {
        let length = layouts[place.volume].range(of: place.index).map { Int($0.upperBound - $0.lowerBound) } ?? 0
        let data = Data(count: length)
        store(index, data)
        return data
    }

    private static func decode(_ body: Data) async throws -> UsenetYEncSegment {
        try await Task.detached(priority: .userInitiated) {
            try UsenetYEnc.decode(body: body)
        }.value
    }

    // MARK: - Read-ahead

    private var readAheadSegments: Int {
        let part = Int(layouts.first?.partSize ?? 716_800)
        return max(4, profile.readAheadBytes / max(1, part))
    }

    /// How far the read-ahead reaches: the memory one, or with Read Ahead on Disk the share
    /// of its budget for reading ahead.
    private var aheadSegments: Int {
        guard diskActive else { return readAheadSegments }
        return Self.diskAheadSegments(
            partSize: layouts.first?.partSize ?? 716_800,
            budgetBytes: diskBudgetBytes,
            memory: readAheadSegments
        )
    }

    static func diskAheadSegments(partSize: Int64, budgetBytes: Int64, memory: Int) -> Int {
        let fits = Int(Double(budgetBytes) * UsenetDiskReadAhead.aheadShare / Double(max(1, partSize)))
        return max(memory, fits)
    }

    /// The read-ahead scan starts here: every article between the playhead and it is in
    /// memory, on disk or on its way, so a disk read-ahead of thousands of articles isn't
    /// walked again for every article read. Whatever may open a gap moves it back.
    private var scanFrom = 0

    private func have(_ index: Int) -> Bool {
        cache[index] != nil || inflight[index] != nil || writing[index] != nil
            || onDisk[index] != nil || diskLoads[index] != nil
    }

    private func rescan(from index: Int) {
        scanFrom = min(scanFrom, index)
    }

    /// Prefetch slots: all connections but one, so a demand read after a seek
    /// isn't stuck behind read-ahead.
    private var prefetchSlots: Int { max(1, pool.totalConnections - 1) }

    /// Read-ahead this close to the playhead is needed in a moment, so the
    /// speed cap never holds it back: `nextSeconds` of video once the bitrate
    /// is known (dozens of articles in a 4K remux), never fewer than
    /// `nextArticles`.
    static let nextArticles = 4
    static let nextSeconds: Double = 4

    static func nextWindow(bytesPerSecond: Double?, partSize: Int64, limit: Int) -> Int {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nextArticles }
        let articles = Int((bytesPerSecond * nextSeconds / Double(max(1, partSize))).rounded(.up))
        return max(nextArticles, min(limit, articles))
    }

    private var nextWindow: Int {
        Self.nextWindow(bytesPerSecond: bytesPerSecond, partSize: layouts.first?.partSize ?? 716_800,
                        limit: readAheadSegments)
    }

    static func priority(of index: Int, playhead: Int,
                         next: Int = UsenetStreamSession.nextArticles) -> UsenetConnectionPool.FetchPriority {
        index > playhead && index - playhead <= next ? .next : .readAhead
    }

    private func noteRead(_ index: Int) {
        let jumped = abs(index - playhead) > 2
        // The player reads an article in several pieces: the read-ahead moves once per
        // article (a finished fetch moves it too).
        guard index != playhead || jumped else { return }
        playhead = index
        noteDiskEvent()
        if jumped {
            scanFrom = 0
            // A seek: read-ahead for the old position is no longer useful.
            let window = index...(index + aheadSegments)
            for (pending, task) in inflight where prefetching.contains(pending) && !window.contains(pending) {
                task.cancel()
                clearInflight(pending)
                prefetching.remove(pending)
            }
            // Read-ahead kept for the next articles may still wait for the
            // speed cap: they are needed now. (One already waiting for a
            // connection keeps its place in line.)
            let nextLast = min(articleCount - 1, index + nextWindow)
            if index + 1 <= nextLast {
                for next in (index + 1)...nextLast where prefetching.contains(next) {
                    if let promoted = promote(next, to: .next, onlyWhileWaitingForCap: true) {
                        watchPrefetch(next, promoted)
                    }
                }
            }
        }
        prefetch(after: index)
    }

    private func prefetch(after index: Int) {
        let last = min(articleCount - 1, index + aheadSegments)
        guard index + 1 <= last else { return }
        // What the disk holds of the memory read-ahead comes back into memory before the
        // player asks for it.
        let memoryLast = min(last, index + readAheadSegments)
        for next in (index + 1)...memoryLast where cache[next] == nil && onDisk[next] != nil {
            loadFromDisk(next)
        }
        var next = max(index + 1, scanFrom)
        while next <= last {
            if !have(next) {
                guard prefetching.count < prefetchSlots else { break }
                startPrefetch(next)
            }
            next += 1
        }
        scanFrom = next
    }

    private func startPrefetch(_ index: Int) {
        guard cache[index] == nil, inflight[index] == nil, writing[index] == nil,
              onDisk[index] == nil, diskLoads[index] == nil else { return }
        let task = startFetch(index, priority: Self.priority(of: index, playhead: playhead, next: nextWindow))
        prefetching.insert(index)
        watchPrefetch(index, task)
    }

    private func watchPrefetch(_ index: Int, _ task: Task<Data, Error>) {
        Task {
            _ = try? await task.value
            self.prefetchFinished(index, task)
        }
    }

    private func prefetchFinished(_ index: Int, _ task: Task<Data, Error>) {
        // A cancelled read-ahead was already replaced, maybe by a newer fetch
        // of the same article: leave that one's bookkeeping alone.
        guard inflight[index] == task else { return }
        clearInflight(index)
        guard prefetching.remove(index) != nil else { return }
        if !have(index) { rescan(from: index) }
        prefetch(after: playhead)
    }

    // MARK: - Cache

    private func store(_ index: Int, _ data: Data) {
        if cache[index] == nil { cachedBytes += data.count }
        cache[index] = data
        touch(index)
        while cachedBytes > profile.cacheBytes,
              let oldest = cacheOrder.first(where: { $0 != index && !pinned.contains($0) }) {
            cacheOrder.removeAll { $0 == oldest }
            cachedBytes -= cache.removeValue(forKey: oldest)?.count ?? 0
            if oldest > playhead, !have(oldest) { rescan(from: oldest) }
        }
    }

    private func touch(_ index: Int) {
        cacheOrder.removeAll { $0 == index }
        cacheOrder.append(index)
    }

    // MARK: - Disk

    private func keepOnDisk(_ index: Int, _ data: Data) {
        guard diskActive, let store = diskReadAhead?.store, !data.isEmpty,
              onDisk[index] == nil, writing[index] == nil else { return }
        writing[index] = data
        Task {
            let written = await store.write(index, data)
            self.diskWritten(index, bytes: written ? data.count : nil)
        }
    }

    private func diskWritten(_ index: Int, bytes: Int?) {
        writing[index] = nil
        guard !diskStopped, diskReadAhead != nil else { return }
        guard let bytes else {
            usenetLog.error("usenet: an article couldn't be written to disk, reading ahead in memory only")
            diskFailed = true
            rescan(from: index)
            return
        }
        if onDisk[index] == nil { diskBytes += Int64(bytes) }
        onDisk[index] = bytes
        noteDiskEvent()
        trimDisk()
    }

    /// What tvOS reports free decides how much of the chosen size the stream may use: it
    /// grows when tvOS clears space and shrinks when something else fills the disk.
    private func checkDiskSpace() {
        guard let store = diskReadAhead?.store, !spaceCheckRunning, !diskStopped else { return }
        spaceCheckRunning = true
        eventsSinceSpaceCheck = 0
        Task {
            let free = await store.freeSpace()
            self.diskSpaceChecked(free)
        }
    }

    /// Every few articles written or played: also while the read-ahead waits for room.
    private func noteDiskEvent() {
        guard diskReadAhead != nil, !diskFailed else { return }
        eventsSinceSpaceCheck += 1
        if eventsSinceSpaceCheck >= Self.spaceCheckEvery { checkDiskSpace() }
    }

    private func diskSpaceChecked(_ free: Int64) {
        spaceCheckRunning = false
        guard !diskStopped, let diskReadAhead else { return }
        diskFreeBytes = free
        diskBudgetBytes = UsenetDiskReadAhead.budgetBytes(
            size: diskReadAhead.sizeBytes, holding: diskBytes, freeSpace: free
        )
        trimDisk()
    }

    private func trimDisk() {
        guard let store = diskReadAhead?.store, diskBytes > diskBudgetBytes else { return }
        let evicted = Self.diskEvictions(
            onDisk: onDisk,
            budgetBytes: diskBudgetBytes,
            keep: playhead...(playhead + aheadSegments),
            pinned: pinned
        )
        guard !evicted.isEmpty else { return }
        for index in evicted {
            if let bytes = onDisk.removeValue(forKey: index) { diskBytes -= Int64(bytes) }
            if index > playhead { rescan(from: index) }
        }
        Task { await store.remove(evicted) }
    }

    /// Over the budget: the articles farthest behind the playhead go first, then the ones
    /// farthest past the read-ahead; the read-ahead itself and the pinned ones stay. Down to
    /// 90 % of the budget, so it isn't trimmed again with every article.
    static func diskEvictions(onDisk: [Int: Int], budgetBytes: Int64,
                              keep: ClosedRange<Int>, pinned: Set<Int>) -> [Int] {
        var total = onDisk.values.reduce(Int64(0)) { $0 + Int64($1) }
        guard total > budgetBytes else { return [] }
        let target = budgetBytes / 10 * 9
        let behind = onDisk.keys.filter { $0 < keep.lowerBound && !pinned.contains($0) }.sorted()
        let past = onDisk.keys.filter { $0 > keep.upperBound && !pinned.contains($0) }.sorted(by: >)
        var evicted: [Int] = []
        for index in behind + past {
            guard total > target else { break }
            total -= Int64(onDisk[index] ?? 0)
            evicted.append(index)
        }
        return evicted
    }
}
