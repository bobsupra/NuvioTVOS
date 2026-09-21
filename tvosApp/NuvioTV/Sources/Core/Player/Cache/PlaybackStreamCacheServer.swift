import Foundation
import Network
import OSLog

private enum PlaybackStreamRangeError: Error {
    case invalidResponse
    case invalidContentRange
    case invalidBodyLength
    case httpStatus(Int, retryAfter: String?)
}

/// A bounded bridge between URLSessionDataDelegate callbacks and the async batch reader.
/// URLSession can deliver a large Data value in one callback, so callbacks are split into
/// small pieces; the exact expected range length bounds retained transfer memory.
private final class PlaybackStreamRangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maxSegmentBytes = 256 * 1024

    private let expectedRange: Range<Int64>
    private let expectedFileLength: Int64
    private let condition = NSCondition()
    private var queuedData: [Data] = []
    private var queuedBytes = 0
    private var waiter: CheckedContinuation<Data?, Error>?
    private var finished = false
    private var failure: Error?
    private var receivedBytes: Int64 = 0
    private var expectedResponseBytes: Int64?
    private weak var task: URLSessionDataTask?

    init(expectedRange: Range<Int64>, expectedFileLength: Int64) {
        self.expectedRange = expectedRange
        self.expectedFileLength = expectedFileLength
    }

    func start(in session: URLSession, request: URLRequest) {
        let task = session.dataTask(with: request)
        task.delegate = self
        self.task = task
        task.resume()
    }

    func cancel() {
        finish(with: CancellationError())
        task?.cancel()
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                if let data = queuedData.first {
                    queuedData.removeFirst()
                    queuedBytes -= data.count
                    condition.broadcast()
                    condition.unlock()
                    continuation.resume(returning: data)
                } else if let failure {
                    condition.unlock()
                    continuation.resume(throwing: failure)
                } else if finished {
                    condition.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    condition.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 206 else {
            fail(.httpStatus(
                http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            ))
            completionHandler(.cancel)
            return
        }
        guard Self.responseMatches(
            range: expectedRange,
            response: http,
            bodyCount: nil,
            expectedFileLength: expectedFileLength
        ) else {
            fail(.invalidContentRange)
            completionHandler(.cancel)
            return
        }
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(contentLength), length == expectedRange.count {
            expectedResponseBytes = length
        } else if http.value(forHTTPHeaderField: "Content-Length") != nil {
            fail(.invalidBodyLength)
            completionHandler(.cancel)
            return
        } else if response.expectedContentLength >= 0 {
            guard response.expectedContentLength == expectedRange.count else {
                fail(.invalidBodyLength)
                completionHandler(.cancel)
                return
            }
            expectedResponseBytes = response.expectedContentLength
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + Self.maxSegmentBytes)
            let piece = Data(data[offset..<end])
            guard append(piece) else { return }
            offset = end
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: error)
            return
        }
        condition.lock()
        let validLength = receivedBytes == expectedRange.count
            && (expectedResponseBytes == nil || expectedResponseBytes == receivedBytes)
        condition.unlock()
        if validLength {
            finish(with: nil)
        } else {
            finish(with: PlaybackStreamRangeError.invalidBodyLength)
        }
    }

    private func append(_ data: Data) -> Bool {
        var continuation: CheckedContinuation<Data?, Error>?
        condition.lock()
        guard !finished else {
            condition.unlock()
            return false
        }
        guard receivedBytes + Int64(data.count) <= expectedRange.count else {
            condition.unlock()
            fail(.invalidBodyLength)
            task?.cancel()
            return false
        }
        receivedBytes += Int64(data.count)
        if let waiter {
            self.waiter = nil
            continuation = waiter
        } else {
            queuedData.append(data)
            queuedBytes += data.count
        }
        condition.unlock()
        continuation?.resume(returning: data)
        return true
    }

    private func fail(_ error: PlaybackStreamRangeError) {
        finish(with: error)
    }

    private func finish(with error: Error?) {
        var continuation: CheckedContinuation<Data?, Error>?
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        failure = error
        finished = true
        continuation = waiter
        waiter = nil
        condition.unlock()
        if let continuation {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: nil) }
        }
    }

    private static func responseMatches(
        range: Range<Int64>, response: HTTPURLResponse, bodyCount: Int?, expectedFileLength: Int64
    ) -> Bool {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else { return false }
        let parts = contentRange.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
        guard parts.count == 4, parts[0].lowercased() == "bytes",
              let start = Int64(parts[1]), let end = Int64(parts[2]),
              start == range.lowerBound, end == range.upperBound - 1 else { return false }
        let totalMatches = parts[3] == "*" || Int64(parts[3]) == expectedFileLength
        guard totalMatches else { return false }
        if let bodyCount { return bodyCount == Int(range.count) }
        return true
    }
}

/// Shares completed chunks from one upstream range request with demand and prefetch callers.
/// The retained data is bounded by the server's maximum batch size (8 MiB).
private final class PlaybackStreamSharedBatch: @unchecked Sendable {
    let id = UUID()
    let priority: PlaybackStreamCacheServer.FetchPriority
    let startChunk: Int
    let count: Int
    private let lock = NSLock()
    private var chunks: [Int: Data] = [:]
    private var waiters: [Int: [UUID: CheckedContinuation<Data?, Never>]] = [:]
    private var completed = false

    init(priority: PlaybackStreamCacheServer.FetchPriority, startChunk: Int, count: Int) {
        self.priority = priority
        self.startChunk = startChunk
        self.count = count
    }

    func awaitChunk(_ index: Int) async -> Data? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else if let data = chunks[index] {
                    lock.unlock()
                    continuation.resume(returning: data)
                } else if completed {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiters[index, default: [:]][waiterID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelWaiter(index: index, id: waiterID)
        }
    }

    private func cancelWaiter(index: Int, id: UUID) {
        lock.lock()
        let continuation = waiters[index]?.removeValue(forKey: id)
        if waiters[index]?.isEmpty == true { waiters.removeValue(forKey: index) }
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    func publish(_ index: Int, data: Data) {
        var continuations: [CheckedContinuation<Data?, Never>] = []
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        chunks[index] = data
        continuations = Array((waiters.removeValue(forKey: index) ?? [:]).values)
        lock.unlock()
        continuations.forEach { $0.resume(returning: data) }
    }

    func finish() {
        var continuations: [(CheckedContinuation<Data?, Never>, Data?)] = []
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        for (index, pending) in waiters {
            let data = chunks[index]
            continuations.append(contentsOf: pending.values.map { ($0, data) })
        }
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { continuation, data in continuation.resume(returning: data) }
    }

    func publishedChunks() -> [Int: Data] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

/// Local HTTP loopback proxy providing a 3-tier hybrid disk cache (Demand, Forward Fill, Archive) for video playback.
actor PlaybackStreamCacheServer {
    fileprivate enum FetchPriority: Sendable { case demand, forward, archive }
    private let remoteURL: URL
    private let customHeaders: [String: String]
    private let diskCache: PlaybackStreamDiskCache
    private let urlSession: URLSession

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nuvio.stream.cache.server")
    private var acceptTask: Task<Void, Never>?
    private var forwardFillTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var inFlightBatchFetches: [Int: (batch: PlaybackStreamSharedBatch, task: Task<Bool, Never>)] = [:]
    private var inFlightDemandFetches: [Int: Task<Data?, Never>] = [:]
    private var demandOwnedBatchIDs: Set<UUID> = []
    // Retain at most one batch after completion. Disk-full playback must not
    // redownload the remaining chunks of a batch after its first chunk is sent.
    private var recentChunks: [Int: Data] = [:]
    private var recentChunkOrder: [Int] = []
    private var knownDiskChunks: Set<Int>
    private struct PendingWrite {
        let index: Int
        let data: Data
        let playhead: Int64
        let evictsBehind: Bool?
    }
    // At most 8 MiB queued plus the single 2 MiB write currently executing.
    // Persistence is best effort: playback never waits for write admission.
    private var pendingWrites: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var writingChunk: Int? { activeWrite?.index }
    private var persistenceTask: Task<Void, Never>?
    private var diskWriteFailed = false
    private var stopped = false
    private var activeUpstreamFetches = 0
    private var queuedDemandWaiters = 0
    private var activeDemandFetches = 0
    var hasActiveDemand: Bool { queuedDemandWaiters > 0 || activeDemandFetches > 0 }
    private var throttleUntil: Date?
    private let rateLimitCooldown: TimeInterval

    private(set) var port: UInt16 = 0
    nonisolated let token: String
    nonisolated var path: String { "/stream/\(token)" }
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    // MARK: - Playhead & Prefetch Tuning

    /// Player playback position reported from UI/media player timeline polling.
    private var playerPlayheadOffset: Int64 = 0
    /// Active download offset read by the local HTTP client/socket.
    private var clientReadOffset: Int64? = nil
    private var clientReadGeneration: UInt64 = 0
    /// An established HTTP playback read is authoritative. Timeline values are only a
    /// fallback before playback has supplied an actual byte position.
    private var effectiveAnchorOffset: Int64 {
        clientReadOffset ?? playerPlayheadOffset
    }
    private var durationSeconds: Double?
    private var lastMeasuredBps: Double?
    private let targetLeadSeconds: Double
    private let minForwardLeadBytes: Int64 = 80 * 1024 * 1024 // 80 MB minimum
    private let maxForwardLeadBytes: Int64 = 1500 * 1024 * 1024 // 1.5 GB maximum
    static let maxBatchChunks = 4 // Batch up to 4 chunks (8 MiB) per sequential upstream request

    /// Adaptive forward buffer lead calculated from video duration and file length.
    var adaptiveForwardLeadBytes: Int64 {
        let totalLen = diskCache.fileLength
        if let dur = durationSeconds, dur > 0, totalLen > 0 {
            let estimatedByteRate = Double(totalLen) / dur
            let targetBytes = Int64(estimatedByteRate * targetLeadSeconds)
            return min(maxForwardLeadBytes, max(minForwardLeadBytes, targetBytes))
        }
        return min(maxForwardLeadBytes, max(minForwardLeadBytes, Int64(targetLeadSeconds * (250 * 1024 * 1024 / 150.0))))
    }

    func updateTimeline(playheadOffset: Int64, durationSeconds: Double? = nil, isSeek: Bool = false) {
        if let durationSeconds, durationSeconds > 0 {
            self.durationSeconds = durationSeconds
        }
        if isSeek {
            cancelObsoletePrefetch()
            clientReadGeneration &+= 1
            clientReadOffset = playheadOffset
        }
        playerPlayheadOffset = playheadOffset
    }

    private func handleClientReadJump(newOffset: Int64) {
        guard newOffset >= 0 else { return }
        let oldOffset = clientReadOffset ?? playerPlayheadOffset
        let diffFromClient = abs(newOffset - oldOffset)
        let diffFromPlayer = abs(newOffset - playerPlayheadOffset)
        let seekThreshold: Int64 = 8 * 1024 * 1024 // 8 MiB (4 chunks)
        // If HTTP read jumps away from both current client read and player playhead, cancel obsolete prefetch
        if clientReadOffset != nil && diffFromClient > seekThreshold && diffFromPlayer > seekThreshold {
            cancelObsoletePrefetch()
        }
        // Every new playback request retires the old socket's position updates,
        // including overlapping reconnects inside the seek threshold.
        clientReadGeneration &+= 1
        clientReadOffset = newOffset
    }

    private func updateClientReadOffset(_ offset: Int64, generation: UInt64) {
        guard generation == clientReadGeneration else { return }
        clientReadOffset = offset
    }

    private func cancelObsoletePrefetch() {
        var toCancel: [UUID: Task<Bool, Never>] = [:]
        for (_, entry) in inFlightBatchFetches {
            if (entry.batch.priority == .forward || entry.batch.priority == .archive),
               !demandOwnedBatchIDs.contains(entry.batch.id) {
                entry.batch.finish()
                demandOwnedBatchIDs.remove(entry.batch.id)
                toCancel[entry.batch.id] = entry.task
            }
        }
        for (_, task) in toCancel {
            task.cancel()
        }
    }

    private func updateThroughput(_ byteRate: Double) {
        guard byteRate > 0 else { return }
        if let current = lastMeasuredBps {
            lastMeasuredBps = current * 0.7 + byteRate * 0.3
        } else {
            lastMeasuredBps = byteRate
        }
    }

    /// Concurrency throttle and rate-limit backoff state
    private var maxConcurrentUpstream = 3
    private let configuredMaxConcurrentUpstream: Int
    private var isThrottled = false
    private var lastThrottleTime: Date?
    private let throttleRecoveryInterval: TimeInterval = 300 // 5 minutes

    init(
        remoteURL: URL,
        fileLength: Int64,
        customHeaders: [String: String] = [:],
        sessionID: String = UUID().uuidString,
        maxDiskCacheSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        freeSpaceReserveBytes: Int64 = PlaybackStreamDiskCache.defaultFreeSpaceReserveBytes,
        targetLeadSeconds: Double = 150.0,
        cacheRoot: URL? = nil,
        manifest: PlaybackStreamManifest? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        rateLimitCooldown: TimeInterval = 1,
        maxConcurrentUpstream: Int = 3,
        freeSpaceProvider: PlaybackStreamDiskCache.FreeSpaceProvider? = nil
    ) {
        self.remoteURL = remoteURL
        self.customHeaders = customHeaders
        self.token = sessionID
        self.targetLeadSeconds = targetLeadSeconds.isFinite && targetLeadSeconds > 0 ? targetLeadSeconds : 150.0
        self.rateLimitCooldown = rateLimitCooldown.isFinite ? min(max(0.1, rateLimitCooldown), 60) : 1
        self.configuredMaxConcurrentUpstream = max(1, maxConcurrentUpstream)
        self.maxConcurrentUpstream = self.configuredMaxConcurrentUpstream
        self.diskCache = PlaybackStreamDiskCache(
            sessionID: sessionID,
            fileLength: fileLength,
            maxCacheSizeBytes: maxDiskCacheSizeBytes,
            freeSpaceReserveBytes: freeSpaceReserveBytes,
            cacheRoot: cacheRoot,
            manifest: manifest,
            freeSpaceProvider: freeSpaceProvider
        )
        self.knownDiskChunks = self.diskCache.initialCachedChunkIndices

        let config = sessionConfiguration ?? URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 6
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Server Lifecycle

    func start() async throws -> URL {
        stopped = false
        if let listener, listener.state == .ready { return localURL }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: .any
        )
        let listener = try NWListener(using: params)

        let incoming = AsyncStream<NWConnection> { continuation in
            listener.newConnectionHandler = { continuation.yield($0) }
            continuation.onTermination = { _ in listener.cancel() }
        }

        let bound = await Self.bind(listener, on: queue)

        guard bound, let actualPort = listener.port?.rawValue else {
            throw TorrentEngineError.failedToStart
        }
        self.listener = listener
        self.port = actualPort
        diskCacheLog.notice("PlaybackStreamCacheServer started on 127.0.0.1:\(actualPort)")

        acceptTask = Task { await self.acceptLoop(incoming) }
        startBackgroundWorkers()
        return localURL
    }

    private nonisolated static func bind(_ listener: NWListener, on queue: DispatchQueue) async -> Bool {
        let gate = OnceGate<Bool>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        gate.resume(true)
                    case .failed, .cancelled:
                        listener.stateUpdateHandler = nil
                        gate.resume(false)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 3) {
                    listener.stateUpdateHandler = nil
                    gate.resume(false)
                }
            }
        } onCancel: {
            listener.stateUpdateHandler = nil
            listener.cancel()
            gate.resume(false)
        }
    }

    func stop() async {
        stopped = true
        acceptTask?.cancel()
        acceptTask = nil
        forwardFillTask?.cancel()
        forwardFillTask = nil
        archiveTask?.cancel()
        archiveTask = nil
        var stoppedBatches: [UUID: PlaybackStreamSharedBatch] = [:]
        for entry in inFlightBatchFetches.values {
            stoppedBatches[entry.batch.id] = entry.batch
        }
        let demandOwnedAtStop = demandOwnedBatchIDs
        stoppedBatches.values.forEach { $0.finish() }
        inFlightBatchFetches.values.forEach { $0.task.cancel() }
        inFlightBatchFetches.removeAll()
        demandOwnedBatchIDs.removeAll()
        recentChunks.removeAll()
        recentChunkOrder.removeAll()
        urlSession.invalidateAndCancel()
        await persistenceTask?.value
        for batch in stoppedBatches.values {
            await persistBatch(batch, priority: demandOwnedAtStop.contains(batch.id) ? .demand : batch.priority)
        }
        inFlightDemandFetches.values.forEach { $0.cancel() }
        inFlightDemandFetches.removeAll()
        activeUpstreamFetches = 0
        activeDemandFetches = 0
        queuedDemandWaiters = 0
        listener?.cancel()
        listener = nil
        urlSession.invalidateAndCancel()
    }

    // MARK: - Background Workers (Tier 2 & Tier 3)

    private func startBackgroundWorkers() {
        // Tier 2: Forward Fill (~10 minutes ahead of playhead)
        forwardFillTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isUrgent = await self.performForwardFillStep()
                if isUrgent {
                    // Low lead ahead: burst fill without artificial sleep delay
                    await Task.yield()
                } else {
                    // Target lead satisfied: rest before polling playhead progress
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        // Tier 3: Archive (Fills whole title from 0 to end in background)
        archiveTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let didFetch = await self.performArchiveStep()
                if didFetch {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    /// Returns `true` if the buffer ahead is still actively building toward the target lead.
    @discardableResult
    private func performForwardFillStep() async -> Bool {
        guard !diskWriteFailed else { return false }
        guard pendingWrites.count < Self.maxBatchChunks * 2 else { return false }
        checkThrottleRecovery()
        let playhead = effectiveAnchorOffset
        let totalLen = diskCache.fileLength
        guard totalLen > 0 else { return false }

        let leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
        let targetLead = adaptiveForwardLeadBytes
        let isUrgent = leadAhead < targetLead

        let startChunk = diskCache.chunkIndex(forByteOffset: playhead)
        let endOffset = min(playhead + targetLead, totalLen - 1)
        let endChunk = diskCache.chunkIndex(forByteOffset: endOffset)

        guard endChunk >= startChunk else { return false }
        var chunk = startChunk
        while chunk <= endChunk {
            if Task.isCancelled { return false }
            let isCached = await diskCache.isChunkCached(chunk)
            if !isCached && inFlightDemandFetches[chunk] == nil && inFlightBatchFetches[chunk] == nil {
                guard await diskCache.canPrefetchChunk(chunk, playheadOffset: playhead, evictBehindPlayhead: true) else {
                    return false
                }
                var batchCount = 1
                while batchCount < Self.maxBatchChunks && (chunk + batchCount) <= endChunk {
                    let next = chunk + batchCount
                    if await diskCache.isChunkCached(next) || inFlightDemandFetches[next] != nil || inFlightBatchFetches[next] != nil { break }
                    batchCount += 1
                }
                let fetched = await fetchAndCacheBatch(startingAt: chunk, count: batchCount, priority: .forward)
                return isUrgent && fetched != nil
            }
            chunk += 1
        }
        return false
    }

    /// Returns `true` if an archive chunk was fetched, or `false` if yielding/paused.
    @discardableResult
    private func performArchiveStep() async -> Bool {
        guard !diskWriteFailed else { return false }
        guard pendingWrites.isEmpty, writingChunk == nil else { return false }
        guard !isThrottled else { return false }
        guard !hasActiveDemand else {
            // Priority scheduling: player demand takes complete priority over archive
            return false
        }
        let total = diskCache.totalChunks
        guard total > 0 else { return false }

        // Protect Tier 2: Only archive if Forward Fill already satisfies target lead
        let playhead = effectiveAnchorOffset
        let leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
        let neededLead = adaptiveForwardLeadBytes
        guard leadAhead >= neededLead else {
            return false // Yield bandwidth completely to Forward Fill
        }

        let startChunk = diskCache.chunkIndex(forByteOffset: playhead)
        guard startChunk < total else { return false }
        var chunk = startChunk
        while chunk < total {
            if Task.isCancelled || hasActiveDemand { return false }
            let isCached = await diskCache.isChunkCached(chunk)
            if !isCached,
               await diskCache.canPrefetchChunk(chunk, playheadOffset: playhead, evictBehindPlayhead: false) {
                var batchCount = 1
                while batchCount < Self.maxBatchChunks && (chunk + batchCount) < total {
                    let next = chunk + batchCount
                    if await diskCache.isChunkCached(next) { break }
                    batchCount += 1
                }
                let fetched = await fetchAndCacheBatch(startingAt: chunk, count: batchCount, priority: .archive)
                return fetched != nil
            }
            chunk += 1
        }
        return false
    }

    // MARK: - Prompt Demand Fetching (Tier 1)

    /// Prompt single-chunk fetch path dedicated to real-time player demand with minimal TTFB.
    /// Does not block on background batch fetches, and delivers data in RAM even if disk headroom is full.
    @discardableResult
    func fetchDemandChunk(_ index: Int) async -> Data? {
        guard !stopped, !Task.isCancelled else { return nil }
        if let cached = recentChunks[index] { return cached }
        if let existing = inFlightDemandFetches[index] {
            return await existing.value
        }
        let total = diskCache.totalChunks
        guard index >= 0, index < total else { return nil }

        // A shared transfer is the authoritative fast path while its RAM chunks
        // are alive; a slow disk writer must not delay demand delivery.
        if let existing = inFlightBatchFetches[index] {
            demandOwnedBatchIDs.insert(existing.batch.id)
            if let data = await existing.batch.awaitChunk(index) { return data }
            guard !stopped, !Task.isCancelled else { return nil }
            removeCompletedBatch(existing.batch, count: existing.batch.count)
        }
        if let write = activeWrite, write.index == index { return write.data }
        if let pending = pendingWrites.first(where: { $0.index == index }) { return pending.data }
        if knownDiskChunks.contains(index) {
            if let cached = await diskCache.readChunk(index) { return cached }
            knownDiskChunks.remove(index)
        }

        let task = Task<Data?, Never> { [weak self] in
            await self?.executeDemandFetch(index)
        }
        inFlightDemandFetches[index] = task
        let result = await task.value
        inFlightDemandFetches.removeValue(forKey: index)
        return result
    }

    private func executeDemandFetch(_ index: Int) async -> Data? {
        if let existing = inFlightBatchFetches[index] {
            demandOwnedBatchIDs.insert(existing.batch.id)
            if let data = await existing.batch.awaitChunk(index) { return data }
            guard !stopped, !Task.isCancelled else { return nil }
            removeCompletedBatch(existing.batch, count: existing.batch.count)
        }
        let fetched = await fetchAndCacheBatch(
            startingAt: index, count: Self.maxBatchChunks, priority: .demand, awaitFirstChunk: true
        )
        return fetched?[index]
    }

    // MARK: - Background Batch Fetching (Tier 2 & Tier 3)

    @discardableResult
    private func fetchAndCacheBatch(
        startingAt startChunk: Int, count: Int, priority: FetchPriority, awaitFirstChunk: Bool = false
    ) async -> [Int: Data]? {
        let total = diskCache.totalChunks
        guard startChunk >= 0, startChunk < total, count > 0 else { return nil }
        var actualCount = min(count, total - startChunk)

        // Single chunk fast-path if already cached
        if actualCount == 1, knownDiskChunks.contains(startChunk),
           let cached = await diskCache.readChunk(startChunk) {
            return [startChunk: cached]
        }

        if let existing = inFlightBatchFetches[startChunk] {
            var result: [Int: Data] = [:]
            for index in startChunk..<(startChunk + actualCount) {
                if let data = await existing.batch.awaitChunk(index) {
                    result[index] = data
                }
            }
            return result.isEmpty ? nil : result
        }

        for offset in 0..<actualCount where inFlightBatchFetches[startChunk + offset] != nil {
            actualCount = offset
            break
        }
        guard actualCount > 0 else { return nil }

        let startByte = diskCache.byteRange(forChunk: startChunk).lowerBound
        let endByte = diskCache.byteRange(forChunk: startChunk + actualCount - 1).upperBound
        let batchRange = startByte..<endByte
        guard !batchRange.isEmpty else { return nil }

        let batch = PlaybackStreamSharedBatch(priority: priority, startChunk: startChunk, count: actualCount)
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.executeBatchFetch(
                batch: batch, batchRange: batchRange
            )
        }

        for i in 0..<actualCount {
            inFlightBatchFetches[startChunk + i] = (batch, task)
        }

        if awaitFirstChunk {
            Task { [weak self] in
                _ = await task.value
                await self?.removeCompletedBatch(batch, count: actualCount)
            }
            guard let firstChunk = await batch.awaitChunk(startChunk) else { return nil }
            return [startChunk: firstChunk]
        }

        let result = await task.value
        removeCompletedBatch(batch, count: actualCount)
        let chunks = batch.publishedChunks()
        return result && !chunks.isEmpty ? chunks : nil
    }

    private func removeCompletedBatch(_ batch: PlaybackStreamSharedBatch, count: Int) {
        if !stopped {
            for (index, data) in batch.publishedChunks().sorted(by: { $0.key < $1.key }) {
                recentChunks[index] = data
                recentChunkOrder.removeAll { $0 == index }
                recentChunkOrder.append(index)
                while recentChunkOrder.count > 16 {
                    recentChunks.removeValue(forKey: recentChunkOrder.removeFirst())
                }
            }
        }
        for index in batch.startChunk..<(batch.startChunk + count) {
            if inFlightBatchFetches[index]?.batch.id == batch.id {
                inFlightBatchFetches.removeValue(forKey: index)
            }
        }
        demandOwnedBatchIDs.remove(batch.id)
    }

    private func executeBatchFetch(
        batch: PlaybackStreamSharedBatch, batchRange: Range<Int64>
    ) async -> Bool {
        let startChunk = batch.startChunk
        let actualCount = batch.count
        let priority = batch.priority
        var req = URLRequest(url: remoteURL)
        req.httpMethod = "GET"
        for (k, v) in customHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(batchRange.lowerBound)-\(batchRange.upperBound - 1)", forHTTPHeaderField: "Range")

        defer { batch.finish() }
        for attempt in 1...3 {
            if Task.isCancelled { return false }
            guard await acquireFetchSlot(priority: priority) else { return false }

            let admissionPlayhead = effectiveAnchorOffset
            if priority == .forward,
               !(await diskCache.canPrefetchChunk(startChunk, playheadOffset: admissionPlayhead, evictBehindPlayhead: true)) {
                releaseFetchSlot(priority: priority)
                return false
            }
            if priority == .archive,
               !(await diskCache.canPrefetchChunk(startChunk, playheadOffset: admissionPlayhead, evictBehindPlayhead: false)) {
                releaseFetchSlot(priority: priority)
                return false
            }

            let t0 = CFAbsoluteTimeGetCurrent()
            let stream = PlaybackStreamRangeDelegate(
                expectedRange: batchRange, expectedFileLength: diskCache.fileLength
            )
            do {
                stream.start(in: urlSession, request: req)
                var assembled = Data()
                var emitted = 0
                while let piece = try await stream.next() {
                    guard !Task.isCancelled else { throw CancellationError() }
                    assembled.append(piece)
                    while emitted < actualCount {
                        let chunk = startChunk + emitted
                        let chunkLength = Int(diskCache.byteRange(forChunk: chunk).count)
                        guard assembled.count >= chunkLength else { break }
                        let chunkBytes = Data(assembled.prefix(chunkLength))
                        assembled.removeFirst(chunkLength)
                        batch.publish(chunk, data: chunkBytes)
                        emitted += 1
                    }
                }
                guard assembled.isEmpty, emitted == actualCount, !Task.isCancelled else {
                    throw PlaybackStreamRangeError.invalidBodyLength
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                if elapsed > 0.05 {
                    updateThroughput(Double(batchRange.count) / elapsed)
                }
                enqueuePersistence(batch, priority: priority)
                releaseFetchSlot(priority: priority)
                return true
            } catch {
                stream.cancel()
                releaseFetchSlot(priority: priority)
                if case let PlaybackStreamRangeError.httpStatus(status, retryAfter) = error,
                   status == 429 || status == 503 {
                    let delay = applyRateLimitThrottle(retryAfter: retryAfter)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if attempt == 3 {
                    diskCacheLog.warning("Upstream batch fetch [\(startChunk)..<(\(startChunk + actualCount))] failed after 3 attempts: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(attempt))
            }
        }
        return false
    }

    private func enqueuePersistence(_ batch: PlaybackStreamSharedBatch, priority: FetchPriority) {
        guard !stopped, shouldPersistToDisk() else { return }
        let evictsBehind: Bool? = priority == .demand || demandOwnedBatchIDs.contains(batch.id)
            ? nil : priority == .forward
        for (index, data) in batch.publishedChunks().sorted(by: { $0.key < $1.key }) {
            guard pendingWrites.count < Self.maxBatchChunks else { break }
            guard writingChunk != index, !pendingWrites.contains(where: { $0.index == index }) else { continue }
            pendingWrites.append(PendingWrite(index: index, data: data,
                                             playhead: effectiveAnchorOffset, evictsBehind: evictsBehind))
        }
        if persistenceTask == nil, !pendingWrites.isEmpty {
            persistenceTask = Task { await self.drainPersistence() }
        }
    }

    private func drainPersistence() async {
        defer {
            pendingWrites.removeAll()
            activeWrite = nil
            persistenceTask = nil
        }
        while !pendingWrites.isEmpty, shouldPersistToDisk() {
            let write = pendingWrites.removeFirst()
            activeWrite = write
            let persisted = await diskCache.writeChunk(
                write.index, data: write.data, playheadOffset: write.playhead,
                prefetchEvictsBehind: write.evictsBehind
            )
            if persisted { knownDiskChunks.insert(write.index) }
            else { markDiskWriteFailed() }
            activeWrite = nil
        }
    }

    /// Stop drains only this session's bounded completed data after cancelling
    /// upstream work. Normal playback uses the separate bounded write queue.
    private func persistBatch(_ batch: PlaybackStreamSharedBatch, priority: FetchPriority) async {
        guard shouldPersistToDisk() else { return }
        let playhead = effectiveAnchorOffset
        // A forward batch joined by playback also contains just-consumed bytes.
        // Keep those eligible for persistence so quit/reopen can reuse them.
        let evictsBehind: Bool? = priority == .demand || demandOwnedBatchIDs.contains(batch.id)
            ? nil : priority == .forward
        for (index, data) in batch.publishedChunks().sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled, shouldPersistToDisk() else { return }
            let persisted = await diskCache.writeChunk(
                index, data: data, playheadOffset: playhead, prefetchEvictsBehind: evictsBehind
            )
            if !persisted {
                markDiskWriteFailed()
                return
            }
            knownDiskChunks.insert(index)
        }
    }

    // MARK: - Upstream Concurrency & Priority Scheduling

    private func preemptBackgroundTasksForDemand() {
        var archiveTasks: [UUID: Task<Bool, Never>] = [:]
        var forwardTasks: [UUID: Task<Bool, Never>] = [:]
        for (_, entry) in inFlightBatchFetches {
            if entry.batch.priority == .archive,
               !demandOwnedBatchIDs.contains(entry.batch.id) {
                archiveTasks[entry.batch.id] = entry.task
            } else if entry.batch.priority == .forward,
                      !demandOwnedBatchIDs.contains(entry.batch.id) {
                forwardTasks[entry.batch.id] = entry.task
            }
        }
        for (_, task) in archiveTasks { task.cancel() }
        if activeUpstreamFetches >= maxConcurrentUpstream {
            for (_, task) in forwardTasks { task.cancel() }
        }
    }

    private func acquireFetchSlot(priority: FetchPriority) async -> Bool {
        var queuedDemand = false
        if priority == .demand {
            queuedDemandWaiters += 1
            queuedDemand = true
            preemptBackgroundTasksForDemand()
        }
        defer {
            if queuedDemand {
                queuedDemandWaiters -= 1
            }
        }

        while !Task.isCancelled && !stopped {
            checkThrottleRecovery()
            let coolingDown = throttleUntil.map { $0 > Date() } ?? false
            let isDemand = priority == .demand
            let isForward = priority == .forward
            if isDemand && !queuedDemand {
                queuedDemandWaiters += 1
                queuedDemand = true
                preemptBackgroundTasksForDemand()
            }
            let canEnter = isDemand || isForward || (!hasActiveDemand && activeUpstreamFetches == 0)
            if !coolingDown && canEnter && activeUpstreamFetches < maxConcurrentUpstream {
                activeUpstreamFetches += 1
                if isDemand {
                    activeDemandFetches += 1
                }
                return true
            }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return false }
        }
        return false
    }

    private func releaseFetchSlot(priority: FetchPriority) {
        if priority == .demand {
            activeDemandFetches = max(0, activeDemandFetches - 1)
        }
        activeUpstreamFetches = max(0, activeUpstreamFetches - 1)
    }

    private func markDiskWriteFailed() {
        diskWriteFailed = true
        diskCacheLog.error("Disabling background cache fills after a disk write failure")
    }

    private func shouldPersistToDisk() -> Bool {
        !diskWriteFailed
    }

    private func applyRateLimitThrottle(retryAfter: String?) -> TimeInterval {
        isThrottled = true
        maxConcurrentUpstream = max(1, maxConcurrentUpstream - 1)
        lastThrottleTime = Date()
        let parsedDelay = retryAfter.flatMap(TimeInterval.init)
        let retryAfter = parsedDelay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? rateLimitCooldown
        let delay = min(max(0.1, retryAfter), 60)
        let newUntil = Date().addingTimeInterval(delay)
        throttleUntil = max(throttleUntil ?? .distantPast, newUntil)
        diskCacheLog.warning("Provider rate limit detected. Concurrency lowered to \(self.maxConcurrentUpstream)")
        return delay
    }

    private func checkThrottleRecovery() {
        guard isThrottled, let last = lastThrottleTime else { return }
        if Date().timeIntervalSince(last) >= throttleRecoveryInterval {
            isThrottled = false
            maxConcurrentUpstream = configuredMaxConcurrentUpstream
            diskCacheLog.notice("Rate limit recovery period elapsed. Concurrency restored to \(self.maxConcurrentUpstream).")
        }
    }

    // MARK: - Client Request Handling (Tier 1 Demand)

    private func acceptLoop(_ incoming: AsyncStream<NWConnection>) async {
        await withDiscardingTaskGroup { group in
            for await connection in incoming {
                group.addTask { await self.serve(connection) }
            }
        }
    }

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        var buffer = Data()
        do {
            try await NetworkIO.start(connection, on: queue)
            while !Task.isCancelled {
                let (head, rest) = try await readRequestHead(connection, buffer: buffer)
                buffer = rest
                guard try await respond(to: head, on: connection) else { return }
            }
        } catch {}
    }

    private func readRequestHead(_ connection: NWConnection, buffer: Data) async throws -> (head: String, rest: Data) {
        var buffer = buffer
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let end = buffer.range(of: terminator) {
                let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
                return (head, Data(buffer[end.upperBound...]))
            }
            guard buffer.count < 64 * 1024 else { throw NetworkIO.Failure.closed }
            buffer.append(try await NetworkIO.receive(connection, atMost: 8192))
        }
    }

    private func respond(to request: String, on connection: NWConnection) async throws -> Bool {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }
        let requestParts = first.components(separatedBy: " ")
        let method = requestParts.first ?? "GET"

        let fileLength = diskCache.fileLength

        // Parse Range Header
        var requestedStart: Int64 = 0
        var requestedEnd: Int64 = fileLength - 1
        var isRangeRequest = false

        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                isRangeRequest = true
                let rangeVal = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
                if rangeVal.hasPrefix("bytes=") {
                    let spec = String(rangeVal.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
                    if spec.hasPrefix("-") {
                        // Suffix range: bytes=-N (e.g. bytes=-65536 asks for the last 64 KB of the file)
                        if let suffixLength = Int64(spec.dropFirst()), suffixLength > 0 {
                            requestedStart = max(0, fileLength - suffixLength)
                            requestedEnd = fileLength - 1
                        }
                    } else if let dashIndex = spec.firstIndex(of: "-") {
                        let startStr = spec[..<dashIndex].trimmingCharacters(in: .whitespaces)
                        let endStr = spec[spec.index(after: dashIndex)...].trimmingCharacters(in: .whitespaces)
                        if let start = Int64(startStr) {
                            requestedStart = start
                        }
                        if let end = Int64(endStr) {
                            requestedEnd = end
                        } else {
                            requestedEnd = fileLength - 1
                        }
                    }
                }
            }
        }

        requestedEnd = min(requestedEnd, fileLength - 1)
        guard requestedStart <= requestedEnd else {
            let errorResponse = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(fileLength)\r\n\r\n"
            try await NetworkIO.send(connection, Data(errorResponse.utf8))
            return false
        }

        let responseLength = requestedEnd - requestedStart + 1
        // HEAD and small metadata/tail probes must not steal the sequential
        // playback anchor. Only a substantive GET range establishes ownership.
        let tracksPlaybackAnchor = method.uppercased() == "GET" && responseLength >= 256 * 1024
        if tracksPlaybackAnchor {
            handleClientReadJump(newOffset: requestedStart)
        }
        let readGeneration = clientReadGeneration

        var headers = isRangeRequest ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: video/mp4\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Content-Length: \(responseLength)\r\n"
        if isRangeRequest {
            headers += "Content-Range: bytes \(requestedStart)-\(requestedEnd)/\(fileLength)\r\n"
        }
        headers += "Connection: close\r\n\r\n"

        try await NetworkIO.send(connection, Data(headers.utf8))
        if method == "HEAD" { return false }

        // Stream range to client using Demand Priority, clamped to chunk boundaries
        var currentOffset = requestedStart
        while currentOffset <= requestedEnd && !Task.isCancelled {
            let chunkIdx = diskCache.chunkIndex(forByteOffset: currentOffset)
            let chunkRange = diskCache.byteRange(forChunk: chunkIdx)
            let maxInCurrentChunk = Int(chunkRange.upperBound - currentOffset)
            guard maxInCurrentChunk > 0 else { break }
            let bytesToRead = min(maxInCurrentChunk, Int(requestedEnd - currentOffset + 1))

            // Demand owns the RAM fast path while an upstream batch is alive;
            // it falls back to a disk chunk read only when no shared transfer exists.
            var data: Data?
            if let fetched = await fetchDemandChunk(chunkIdx) {
                let sliceStart = Int(currentOffset - chunkRange.lowerBound)
                let sliceEnd = sliceStart + bytesToRead
                if sliceStart >= 0, sliceEnd <= fetched.count {
                    data = Data(fetched[sliceStart..<sliceEnd])
                }
            }

            guard let bytesToSend = data, !bytesToSend.isEmpty else {
                diskCacheLog.error("Demand fetch failed for offset \(currentOffset) in chunk \(chunkIdx). Aborting range response.")
                break
            }
            try await NetworkIO.send(connection, bytesToSend)
            currentOffset += Int64(bytesToSend.count)
            if tracksPlaybackAnchor {
                updateClientReadOffset(currentOffset, generation: readGeneration)
            }
        }

        return false
    }

    // MARK: - Telemetry & Ranges

    var fileLength: Int64 {
        diskCache.fileLength
    }

    func contiguousCachedBytesAhead(of byteOffset: Int64) async -> Int64 {
        await diskCache.contiguousCachedBytesAhead(of: byteOffset)
    }

    func cachedByteRanges() async -> [Range<Int64>] {
        await diskCache.contiguousCachedByteRanges()
    }

    func cachedFraction() async -> Double {
        await diskCache.cachedFraction
    }
}
