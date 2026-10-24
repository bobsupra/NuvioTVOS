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
    var cachedBytes = 0
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

    init(source: UsenetStreamSource, pool: UsenetConnectionPool, profile: UsenetMemoryProfile,
         onDamaged: @escaping @Sendable () -> Void = {}) {
        self.source = source
        self.pool = pool
        self.profile = profile
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
        while let data = cache[index] {
            ahead += Int64(data.count)
            index += 1
        }
        snapshot.bufferedAheadBytes = ahead
        return snapshot
    }

    func stop() async {
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
        queued = [:]
        cache = [:]
        cacheOrder = []
        cachedBytes = 0
        await pool.shutdown()
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
        if let task = inflight[index] {
            // Take over the read-ahead instead of fetching twice.
            if prefetching.remove(index) != nil { counters.cacheHits += 1 }
            return .fetching(promote(index, to: .playback, onlyWhileWaitingForCap: false) ?? task)
        }
        counters.cacheMisses += 1
        return .fetching(startFetch(index, priority: .playback))
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
        store(index, decoded.data)
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

    /// Prefetch slots: all connections but one, so a demand read after a seek
    /// isn't stuck behind read-ahead.
    private var prefetchSlots: Int { max(1, pool.totalConnections - 1) }

    /// Read-ahead this close to the playhead is needed in a moment, so the
    /// speed cap never holds it back.
    static let nextArticles = 4

    static func priority(of index: Int, playhead: Int) -> UsenetConnectionPool.FetchPriority {
        index > playhead && index - playhead <= nextArticles ? .next : .readAhead
    }

    private func noteRead(_ index: Int) {
        let jumped = abs(index - playhead) > 2
        playhead = index
        if jumped {
            // A seek: read-ahead for the old position is no longer useful.
            let window = index...(index + readAheadSegments)
            for (pending, task) in inflight where prefetching.contains(pending) && !window.contains(pending) {
                task.cancel()
                clearInflight(pending)
                prefetching.remove(pending)
            }
            // Read-ahead kept for the next articles may still wait for the
            // speed cap: they are needed now. (One already waiting for a
            // connection keeps its place in line.)
            let nextLast = min(articleCount - 1, index + Self.nextArticles)
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
        let last = min(articleCount - 1, index + readAheadSegments)
        guard index + 1 <= last else { return }
        for next in (index + 1)...last {
            guard prefetching.count < prefetchSlots else { return }
            startPrefetch(next)
        }
    }

    private func startPrefetch(_ index: Int) {
        guard cache[index] == nil, inflight[index] == nil else { return }
        let task = startFetch(index, priority: Self.priority(of: index, playhead: playhead))
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
        }
    }

    private func touch(_ index: Int) {
        cacheOrder.removeAll { $0 == index }
        cacheOrder.append(index)
    }
}
