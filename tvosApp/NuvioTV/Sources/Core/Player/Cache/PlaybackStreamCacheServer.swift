import Foundation
import Network
import OSLog

private enum PlaybackStreamRangeError: LocalizedError {
    case invalidResponse(String)
    case invalidContentRange
    case invalidBodyLength
    case httpStatus(Int, retryAfter: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let type): return "Non-HTTP upstream response (\(type))"
        case .invalidContentRange: return "Upstream Content-Range did not match the requested bytes"
        case .invalidBodyLength: return "Upstream response ended before the requested range was complete"
        case .httpStatus(let status, _): return "Upstream returned HTTP \(status)"
        }
    }
}

/// A bounded bridge between URLSessionDataDelegate callbacks and the async batch reader.
/// URLSession can deliver a large Data value in one callback, so callbacks are split into
/// small pieces; the exact expected range length bounds retained transfer memory.
private final class PlaybackStreamRangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maxSegmentBytes = 256 * 1024

    private let expectedRange: Range<Int64>
    private let expectedFileLength: Int64
    private let customHeaders: [String: String]
    private let requiresExactFileLength: Bool
    private let condition = NSCondition()
    private var queuedData: [Data] = []
    private var queuedBytes = 0
    private var waiter: CheckedContinuation<Data?, Error>?
    private var finished = false
    private var failure: Error?
    private var receivedBytes: Int64 = 0
    private var expectedResponseBytes: Int64?
    private var startedAtNanoseconds: UInt64?
    private var responseStatusCode: Int?
    private var responseLatencyNanoseconds: UInt64?
    private var firstBodyLatencyNanoseconds: UInt64?
    private var completedAtNanoseconds: UInt64?
    private weak var task: URLSessionDataTask?

    init(
        expectedRange: Range<Int64>, expectedFileLength: Int64, customHeaders: [String: String] = [:],
        requiresExactFileLength: Bool = false
    ) {
        self.expectedRange = expectedRange
        self.expectedFileLength = expectedFileLength
        self.customHeaders = customHeaders
        self.requiresExactFileLength = requiresExactFileLength
    }

    func start(in session: URLSession, request: URLRequest) {
        let task = session.dataTask(with: request)
        task.delegate = self
        self.task = task
        condition.lock()
        startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        condition.unlock()
        task.resume()
    }

    func metricsSnapshot() -> (
        statusCode: Int?, responseLatencyMilliseconds: Double?, firstBodyLatencyMilliseconds: Double?,
        receivedBytes: Int64, networkDurationMilliseconds: Double?
    ) {
        condition.lock()
        defer { condition.unlock() }
        let startedAt = startedAtNanoseconds
        let elapsedMilliseconds: (UInt64?) -> Double? = { timestamp in
            guard let startedAt, let timestamp else { return nil }
            return Double(timestamp &- startedAt) / 1_000_000
        }
        return (
            responseStatusCode,
            elapsedMilliseconds(responseLatencyNanoseconds),
            elapsedMilliseconds(firstBodyLatencyNanoseconds),
            receivedBytes,
            elapsedMilliseconds(completedAtNanoseconds)
        )
    }

    func cancel() {
        finish(with: CancellationError())
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let range = "bytes=\(expectedRange.lowerBound)-\(expectedRange.upperBound - 1)"
        let updated = PlaybackStreamCacheRedirectPolicy.redirectedRequest(
            request,
            response: response,
            originalURL: task.originalRequest?.url,
            range: range,
            customHeaders: customHeaders
        )
        completionHandler(updated)
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
        condition.lock()
        let responseAt = DispatchTime.now().uptimeNanoseconds
        if let startedAtNanoseconds {
            responseLatencyNanoseconds = responseAt &- startedAtNanoseconds
        }
        responseStatusCode = (response as? HTTPURLResponse)?.statusCode
        condition.unlock()

        guard let http = response as? HTTPURLResponse else {
            fail(.invalidResponse(String(describing: type(of: response))))
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
            expectedFileLength: expectedFileLength,
            requiresExactFileLength: requiresExactFileLength
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
        if receivedBytes == 0, let startedAtNanoseconds {
            firstBodyLatencyNanoseconds = DispatchTime.now().uptimeNanoseconds &- startedAtNanoseconds
        }
        receivedBytes += Int64(data.count)
        guard receivedBytes <= expectedRange.count else {
            condition.unlock()
            fail(.invalidBodyLength)
            task?.cancel()
            return false
        }
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
        completedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        continuation = waiter
        waiter = nil
        condition.unlock()
        if let continuation {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: nil) }
        }
    }

    private static func responseMatches(
        range: Range<Int64>, response: HTTPURLResponse, bodyCount: Int?, expectedFileLength: Int64,
        requiresExactFileLength: Bool
    ) -> Bool {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else { return false }
        guard let parsedRange = PlaybackStreamCacheContentRange.parse(contentRange),
              parsedRange.start == range.lowerBound,
              parsedRange.end == range.upperBound - 1 else { return false }
        let totalMatches = requiresExactFileLength
            ? parsedRange.total == expectedFileLength
            : parsedRange.total == nil || parsedRange.total == expectedFileLength
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

    /// Atomically stop publishing only when the demanded chunk is still absent. Chunks that were
    /// already published remain available to other waiters and are copied to the server's RAM cache.
    func finishIfChunkUnavailable(_ index: Int) -> Data? {
        var continuations: [(CheckedContinuation<Data?, Never>, Data?)] = []
        lock.lock()
        if let data = chunks[index] {
            lock.unlock()
            return data
        }
        guard !completed else {
            lock.unlock()
            return nil
        }
        completed = true
        for (waitingIndex, pending) in waiters {
            let data = chunks[waitingIndex]
            continuations.append(contentsOf: pending.values.map { ($0, data) })
        }
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { continuation, data in continuation.resume(returning: data) }
        return nil
    }

    func publishedChunks() -> [Int: Data] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

/// Local HTTP loopback proxy providing a 3-tier hybrid disk cache (Demand, Forward Fill, Archive) for video playback.
actor PlaybackStreamCacheServer {
    fileprivate enum FetchPriority: Sendable {
        case demand, forward, archive

        var logName: String {
            switch self {
            case .demand: return "demand"
            case .forward: return "forward"
            case .archive: return "archive"
            }
        }
    }
    private let remoteURL: URL
    private let customHeaders: [String: String]
    private let diskCache: PlaybackStreamDiskCache
    private let urlSession: URLSession
    private var maxDiskCacheSizeBytes: Int64
    private let freeSpaceReserveBytes: Int64

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nuvio.stream.cache.server")
    private var acceptTask: Task<Void, Never>?
    private var forwardFillTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var archiveScanCursor: Int?
    private var seekGeneration: UInt64 = 0
    private var forwardPrefixAuditCursor = 0
    private var lastForwardPrefixAuditUptime: TimeInterval = 0
    private var inFlightBatchFetches: [Int: (batch: PlaybackStreamSharedBatch, task: Task<Bool, Never>)] = [:]
    private struct InFlightDemandFetch {
        let id: UUID
        let task: Task<Data?, Never>
    }
    private var inFlightDemandFetches: [Int: InFlightDemandFetch] = [:]
    private let demandBatchJoinGraceNanoseconds: UInt64
    private var demandOwnedBatchIDs: Set<UUID> = []
    private var preemptedBackgroundBatchIDs: Set<UUID> = []
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
    private var diskWriteRetryAfter: Date?
    private var diskWriteCoolingDown: Bool {
        diskWriteRetryAfter.map { Date() < $0 } ?? false
    }
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

    func matchesActivePlaybackURL(_ url: URL) -> Bool {
        !stopped && url == localURL
    }

    func thumbnailSourceDescriptor() -> PlaybackStreamThumbnailSource? {
        guard !stopped else { return nil }
        return PlaybackStreamThumbnailSource(
            cacheDirectory: diskCache.cacheDirectory,
            fileLength: diskCache.fileLength,
            chunkSize: diskCache.chunkSize,
            sessionID: diskCache.sessionID,
            remoteURL: remoteURL,
            originalHeaders: customHeaders
        )
    }

    // MARK: - Playhead & Prefetch Tuning

    /// Player playback position reported from UI/media player timeline polling.
    private var playerPlayheadOffset: Int64 = 0
    /// Active download offset read by the local HTTP client/socket.
    private var clientReadOffset: Int64? = nil
    private var clientReadGeneration: UInt64 = 0
    /// An established HTTP playback read is authoritative when near the player playhead.
    /// Auxiliary reads (such as index, moov/cues or subtitle track reads near EOF) do not misanchor forward fill.
    private var effectiveAnchorOffset: Int64 {
        if let clientOffset = clientReadOffset {
            let diff = clientOffset - playerPlayheadOffset
            if diff >= 0 && diff < 256 * 1024 * 1024 {
                return clientOffset
            }
            if diff < 0 && abs(diff) < 64 * 1024 * 1024 {
                return clientOffset
            }
        }
        return playerPlayheadOffset
    }
    private var durationSeconds: Double?
    private var lastMeasuredBps: Double?
    private let targetLeadSeconds: Double
    private let thermalStateProvider: @Sendable () -> ProcessInfo.ThermalState
    private let minForwardLeadBytes: Int64 = 80 * 1024 * 1024 // 80 MB minimum
    private let burstSeconds: Double = 60.0
    private let burstFallbackBytes: Int64 = 256 * 1024 * 1024 // 256 MB fallback
    static let defaultBatchChunks = 4 // Default batch up to 4 chunks (8 MiB) per upstream request
    let maxBatchChunks: Int
    private static let tailFetchSpanBytes: Int64 = 64 * 1024

    private struct InFlightTailFetch {
        let id: UUID
        let task: Task<Data?, Never>
    }

    // A tail read never becomes a cache chunk: retain at most this one short
    // span separately from the complete chunk cache.
    private var transientTailSpan: Data?
    private var inFlightTailFetch: InFlightTailFetch?
    private static let transportRetryMaxDelay: TimeInterval = 5.0

    /// Target bytes for the high-priority opening burst (60 seconds of video or 256 MB).
    var burstTargetBytes: Int64 {
        let totalLen = diskCache.fileLength
        if let dur = durationSeconds, dur > 0, totalLen > 0 {
            let byTime = Int64(Double(totalLen) / dur * burstSeconds)
            return max(minForwardLeadBytes, byTime)
        }
        return burstFallbackBytes
    }

    /// Whether the cache is in the opening burst phase.
    var isBursting: Bool {
        get async {
            let playhead = effectiveAnchorOffset
            let leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
            return leadAhead < burstTargetBytes
        }
    }

    /// Adaptive forward buffer lead calculated from video duration and file length,
    /// bounded by the session's allocated disk budget rather than a rigid 1.5 GB ceiling.
    var adaptiveForwardLeadBytes: Int64 {
        let totalLen = diskCache.fileLength
        let diskLimit = max(minForwardLeadBytes, maxDiskCacheSizeBytes - freeSpaceReserveBytes)
        if let dur = durationSeconds, dur > 0, totalLen > 0 {
            let estimatedByteRate = Double(totalLen) / dur
            let targetBytes = Int64(estimatedByteRate * targetLeadSeconds)
            return min(diskLimit, max(minForwardLeadBytes, targetBytes))
        }
        return min(diskLimit, max(minForwardLeadBytes, Int64(targetLeadSeconds * (250 * 1024 * 1024 / 150.0))))
    }

    func updateTimeline(playheadOffset: Int64, durationSeconds: Double? = nil, isSeek: Bool = false) {
        if let durationSeconds, durationSeconds > 0 {
            self.durationSeconds = durationSeconds
        }
        if isSeek {
            seekGeneration &+= 1
            cancelObsoletePrefetch()
            clientReadGeneration &+= 1
            clientReadOffset = playheadOffset
            let total = diskCache.totalChunks
            archiveScanCursor = total > 0
                ? min(max(0, diskCache.chunkIndex(forByteOffset: playheadOffset)), total - 1)
                : nil
            forwardPrefixAuditCursor = archiveScanCursor ?? 0
            lastForwardPrefixAuditUptime = 0
        }
        playerPlayheadOffset = playheadOffset
    }

    private func handleClientReadJump(newOffset: Int64) {
        guard newOffset >= 0 else { return }
        // Client read jumps occur during container probing (tail, indexes, audio/subtitle packets).
        // Forward prefetch is anchored to playerPlayheadOffset / effectiveAnchorOffset, so we do not
        // cancel forward prefetch here; prefetch is cancelled only on explicit seek (updateTimeline isSeek: true).
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
    private var maxConcurrentUpstream = 4
    private let configuredMaxConcurrentUpstream: Int
    private var isThrottled = false
    private var throttleCeiling: Int?
    private var rampInterval: TimeInterval = 5.0
    private static let rampIntervalMin: TimeInterval = 5.0
    private static let rampIntervalMax: TimeInterval = 60.0
    private var lastRampAt = Date()
    private var lastSuccessfulFetchAt: Date?
    private var lastThrottleTime: Date?
    private let throttleRecoveryInterval: TimeInterval = 300 // 5 minutes
    private let transportRetryBaseDelay: TimeInterval
    private var transportRetryStreak = 0
    private var transportRetryNotBefore: Date?

    static func defaultMaxConcurrentUpstream(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let gibPhysical = Double(physicalMemoryBytes) / 1_073_741_824.0
        if gibPhysical > 3.5 {
            return 8 // Apple TV 4K Gen 3 (4 GB)
        } else if gibPhysical > 2.5 {
            return 6 // Apple TV 4K Gen 1/2 (3 GB)
        } else {
            return 4 // Apple TV HD (2 GB)
        }
    }

    init(
        remoteURL: URL,
        fileLength: Int64,
        customHeaders: [String: String] = [:],
        sessionID: String = UUID().uuidString,
        maxDiskCacheSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        freeSpaceReserveBytes: Int64 = PlaybackStreamDiskCache.defaultFreeSpaceReserveBytes,
        targetLeadSeconds: Double = 600.0,
        cacheRoot: URL? = nil,
        manifest: PlaybackStreamManifest? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        maxBatchChunks: Int = PlaybackStreamCacheServer.defaultBatchChunks,
        rateLimitCooldown: TimeInterval = 1,
        transportRetryBaseDelay: TimeInterval = 0.5,
        maxConcurrentUpstream: Int? = nil,
        freeSpaceProvider: PlaybackStreamDiskCache.FreeSpaceProvider? = nil,
        demandBatchJoinGrace: TimeInterval = 2.5,
        thermalStateProvider: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        }
    ) {
        self.remoteURL = remoteURL
        self.customHeaders = customHeaders
        self.token = sessionID
        self.targetLeadSeconds = targetLeadSeconds.isFinite && targetLeadSeconds > 0 ? targetLeadSeconds : 600.0
        self.thermalStateProvider = thermalStateProvider
        self.maxBatchChunks = max(1, min(maxBatchChunks, 32))
        self.rateLimitCooldown = rateLimitCooldown.isFinite ? min(max(0.1, rateLimitCooldown), 60) : 1
        self.transportRetryBaseDelay = transportRetryBaseDelay.isFinite
            ? min(max(0.01, transportRetryBaseDelay), Self.transportRetryMaxDelay)
            : 0.5
        let grace = demandBatchJoinGrace.isFinite ? max(0, demandBatchJoinGrace) : 2.5
        self.demandBatchJoinGraceNanoseconds = UInt64(min(grace, 120) * 1_000_000_000)
        let resolvedConcurrency = maxConcurrentUpstream ?? Self.defaultMaxConcurrentUpstream()
        let isRemoteHTTP = remoteURL.scheme == "http" || remoteURL.scheme == "https"
        let effectiveCap = (maxConcurrentUpstream == nil && isRemoteHTTP)
            ? min(6, resolvedConcurrency)
            : resolvedConcurrency
        self.configuredMaxConcurrentUpstream = max(1, effectiveCap)
        if maxConcurrentUpstream == nil && isRemoteHTTP {
            self.maxConcurrentUpstream = min(2, self.configuredMaxConcurrentUpstream)
        } else {
            self.maxConcurrentUpstream = self.configuredMaxConcurrentUpstream
        }
        self.maxDiskCacheSizeBytes = maxDiskCacheSizeBytes
        self.freeSpaceReserveBytes = freeSpaceReserveBytes
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
        config.httpMaximumConnectionsPerHost = max(8, self.configuredMaxConcurrentUpstream + 2)
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
        recordDiagnostic("local range server started port=\(actualPort)")

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
        let stoppedTailFetch = inFlightTailFetch
        stoppedTailFetch?.task.cancel()
        inFlightBatchFetches.removeAll()
        demandOwnedBatchIDs.removeAll()
        preemptedBackgroundBatchIDs.removeAll()
        recentChunks.removeAll()
        recentChunkOrder.removeAll()
        urlSession.invalidateAndCancel()
        if let stoppedTailFetch {
            _ = await stoppedTailFetch.task.value
        }
        inFlightTailFetch = nil
        transientTailSpan = nil
        await persistenceTask?.value
        for batch in stoppedBatches.values {
            await persistBatch(batch, priority: demandOwnedAtStop.contains(batch.id) ? .demand : batch.priority)
        }
        inFlightDemandFetches.values.forEach { $0.task.cancel() }
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
        // Tier 2: Forward Fill (~10+ minutes ahead of playhead, up to disk cache budget)
        forwardFillTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isBuilding = await self.performForwardFillStep()
                if isBuilding {
                    // Actively building or in opening burst: keep loop responsive to sustain concurrent pipeline
                    try? await Task.sleep(nanoseconds: 10_000_000)
                } else {
                    // Target lead satisfied: rest before polling playhead progress
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }

        // Tier 3: Archive (Fills whole title from 0 to end in background)
        archiveTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let didDispatch = await self.performArchiveStep()
                if didDispatch {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// Dispatches concurrent forward fill batches up to available upstream slots.
    /// Returns `true` if the buffer ahead is still actively building toward the target lead.
    @discardableResult
    private func performForwardFillStep() async -> Bool {
        guard !diskWriteCoolingDown else { return false }
        guard pendingWrites.count < maxBatchChunks * 2 else { return false }
        checkThrottleRecovery()
        let coolingDown = throttleUntil.map { $0 > Date() } ?? false
        let transportCoolingDown = transportRetryNotBefore.map { $0 > Date() } ?? false
        guard !coolingDown && !transportCoolingDown && !isThrottled else { return false }
        let currentSeekGeneration = seekGeneration
        let playhead = effectiveAnchorOffset
        let totalLen = diskCache.fileLength
        guard totalLen > 0 else { return false }

        var leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
        guard currentSeekGeneration == seekGeneration else { return false }

        let startChunk = diskCache.chunkIndex(forByteOffset: playhead)
        let contiguousChunkCount = Int(leadAhead / diskCache.chunkSize)
        let foundStaleChunk = await auditForwardCachedPrefix(
            startingAt: startChunk,
            chunkCount: contiguousChunkCount,
            seekGeneration: currentSeekGeneration
        )
        guard currentSeekGeneration == seekGeneration else { return false }
        if foundStaleChunk {
            leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
            guard currentSeekGeneration == seekGeneration else { return false }
        }

        let bursting = leadAhead < burstTargetBytes
        let targetLead = bursting ? max(burstTargetBytes, adaptiveForwardLeadBytes) : adaptiveForwardLeadBytes
        let isUrgent = leadAhead < targetLead

        guard isUrgent else { return false }

        let endOffset = min(playhead + targetLead, totalLen - 1)
        let endChunk = diskCache.chunkIndex(forByteOffset: endOffset)

        guard endChunk >= startChunk else { return false }

        // Determine how many concurrent slots forward fill can use, always preserving at least 1 slot for demand
        var allowedConcurrency = max(1, maxConcurrentUpstream - 1)
        if bursting && (remoteURL.scheme == "http" || remoteURL.scheme == "https") {
            allowedConcurrency = min(allowedConcurrency, 2)
        }
        let availableSlots = max(0, allowedConcurrency - activeUpstreamFetches - queuedDemandWaiters - (maxConcurrentUpstream <= 1 ? activeDemandFetches : 0))
        guard availableSlots > 0 else { return isUrgent }

        let firstMissingChunk = startChunk + Int(leadAhead / diskCache.chunkSize)
        var dispatched = 0
        var chunk = min(endChunk + 1, firstMissingChunk)
        while chunk <= endChunk && dispatched < availableSlots {
            if Task.isCancelled { break }
            let isCached = await diskCache.isChunkCached(chunk)
            guard currentSeekGeneration == seekGeneration else { return dispatched > 0 }
            if !isCached && inFlightDemandFetches[chunk] == nil && inFlightBatchFetches[chunk] == nil {
                let canPrefetch = await diskCache.canPrefetchChunk(
                    chunk, playheadOffset: playhead, evictBehindPlayhead: true
                )
                guard currentSeekGeneration == seekGeneration else { return dispatched > 0 }
                guard canPrefetch else { break }

                var batchCount = 1
                while batchCount < maxBatchChunks && (chunk + batchCount) <= endChunk {
                    let next = chunk + batchCount
                    let nextIsCached = await diskCache.isChunkCached(next)
                    guard currentSeekGeneration == seekGeneration else { return dispatched > 0 }
                    if nextIsCached || inFlightDemandFetches[next] != nil || inFlightBatchFetches[next] != nil { break }
                    batchCount += 1
                }
                dispatchBatchFetch(startingAt: chunk, count: batchCount, priority: .forward)
                dispatched += 1
                chunk += batchCount
            } else {
                chunk += 1
            }
        }
        return isUrgent
    }

    /// Validates a small rotating slice of the contiguous cached prefix so deleted
    /// chunk files eventually become visible without checking the whole prefix per poll.
    private func auditForwardCachedPrefix(
        startingAt startChunk: Int, chunkCount: Int, seekGeneration: UInt64
    ) async -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard chunkCount > 0, now - lastForwardPrefixAuditUptime >= 0.1 else { return false }
        lastForwardPrefixAuditUptime = now

        let cursorOffset = forwardPrefixAuditCursor >= startChunk &&
            forwardPrefixAuditCursor < startChunk + chunkCount
            ? forwardPrefixAuditCursor - startChunk
            : 0
        let auditCount = min(8, chunkCount)
        var foundStaleChunk = false
        for offset in 0..<auditCount {
            let index = startChunk + (cursorOffset + offset) % chunkCount
            let isCached = await diskCache.isChunkCached(index)
            guard seekGeneration == self.seekGeneration else { return false }
            if !isCached { foundStaleChunk = true }
        }

        guard seekGeneration == self.seekGeneration else { return false }
        forwardPrefixAuditCursor = startChunk + (cursorOffset + auditCount) % chunkCount
        return foundStaleChunk
    }

    /// Dispatches background archive chunks from 0 to EOF once forward fill is healthy.
    @discardableResult
    private func performArchiveStep() async -> Bool {
        let thermalState = thermalStateProvider()
        guard thermalState != .serious && thermalState != .critical else { return false }
        guard !diskWriteCoolingDown else { return false }
        guard pendingWrites.count < maxBatchChunks * 2 else { return false }
        checkThrottleRecovery()
        let coolingDown = throttleUntil.map { $0 > Date() } ?? false
        let transportCoolingDown = transportRetryNotBefore.map { $0 > Date() } ?? false
        guard !coolingDown && !transportCoolingDown && !isThrottled else { return false }
        let archiveBatchInFlight = inFlightBatchFetches.values.contains { $0.batch.priority == .archive }
        guard !archiveBatchInFlight else { return false }

        let total = diskCache.totalChunks
        guard total > 0 else { return false }

        // Protect Tier 2: Only archive if Forward Fill already satisfies target lead
        let currentSeekGeneration = seekGeneration
        let playhead = effectiveAnchorOffset
        let leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
        guard currentSeekGeneration == seekGeneration else { return false }
        let bursting = leadAhead < burstTargetBytes
        guard !bursting else { return false } // Yield completely to opening burst

        let neededLead = adaptiveForwardLeadBytes
        guard leadAhead >= neededLead else {
            return false // Yield bandwidth to Forward Fill until target lead is satisfied
        }

        // Dedicated archive slots (leaving at least 1 slot for demand/forward fill)
        let archiveSlots = min(1, max(0, maxConcurrentUpstream - activeUpstreamFetches - 1))
        guard archiveSlots > 0 else { return false }

        var dispatched = 0
        let playheadChunk = diskCache.chunkIndex(forByteOffset: playhead)
        var scanCursor = min(max(0, archiveScanCursor ?? playheadChunk), total - 1)
        archiveScanCursor = scanCursor
        var scannedChunks = 0
        let scanLimit = min(total, max(128, archiveSlots * maxBatchChunks * 8))
        while scannedChunks < scanLimit && dispatched < archiveSlots {
            if Task.isCancelled { return dispatched > 0 }
            let chunk = scanCursor
            let isCached = await diskCache.isChunkCached(chunk)
            guard currentSeekGeneration == seekGeneration else { return dispatched > 0 }
            if isCached || inFlightDemandFetches[chunk] != nil || inFlightBatchFetches[chunk] != nil {
                scanCursor = (chunk + 1) % total
                archiveScanCursor = scanCursor
                scannedChunks += 1
                continue
            }

            let canPrefetch = await diskCache.canPrefetchChunk(
                chunk, playheadOffset: playhead, evictBehindPlayhead: false
            )
            guard currentSeekGeneration == seekGeneration else { return dispatched > 0 }
            if !canPrefetch {
                // Try other candidates within the bounded scan before yielding.
                scanCursor = (chunk + 1) % total
                archiveScanCursor = scanCursor
                scannedChunks += 1
                continue
            }

            var batchCount = 1
            while batchCount < maxBatchChunks && (chunk + batchCount) < total {
                let next = chunk + batchCount
                let nextIsCached = await diskCache.isChunkCached(next)
                guard currentSeekGeneration == seekGeneration else { return dispatched > 0 }
                if nextIsCached || inFlightDemandFetches[next] != nil || inFlightBatchFetches[next] != nil { break }
                batchCount += 1
            }
            dispatchBatchFetch(startingAt: chunk, count: batchCount, priority: .archive)
            dispatched += 1
            scannedChunks += batchCount
            scanCursor = (chunk + batchCount) % total
            archiveScanCursor = scanCursor
        }

        return dispatched > 0
    }

    private func dispatchBatchFetch(startingAt startChunk: Int, count: Int, priority: FetchPriority) {
        let total = diskCache.totalChunks
        guard startChunk >= 0, startChunk < total, count > 0 else { return }
        let actualCount = min(count, total - startChunk)

        let startByte = diskCache.byteRange(forChunk: startChunk).lowerBound
        let endByte = diskCache.byteRange(forChunk: startChunk + actualCount - 1).upperBound
        let batchRange = startByte..<endByte
        guard !batchRange.isEmpty else { return }

        let batch = PlaybackStreamSharedBatch(priority: priority, startChunk: startChunk, count: actualCount)
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            let result = await self.executeBatchFetch(batch: batch, batchRange: batchRange)
            await self.removeCompletedBatch(batch, count: actualCount)
            return result
        }

        for i in 0..<actualCount {
            inFlightBatchFetches[startChunk + i] = (batch, task)
        }
    }

    // MARK: - Prompt Demand Fetching (Tier 1)

    /// Prompt single-chunk fetch path dedicated to real-time player demand with minimal TTFB.
    /// Does not block on background batch fetches, and delivers data in RAM even if disk headroom is full.
    @discardableResult
    func fetchDemandChunk(_ index: Int) async -> Data? {
        guard !stopped, !Task.isCancelled else { return nil }
        if let cached = recentChunks[index] { return cached }
        if let existing = inFlightDemandFetches[index] {
            return await existing.task.value
        }
        let total = diskCache.totalChunks
        guard index >= 0, index < total else { return nil }

        let id = UUID()
        let task = Task<Data?, Never> { [weak self] in
            await self?.performDemandFetch(index)
        }
        inFlightDemandFetches[index] = InFlightDemandFetch(id: id, task: task)
        let result = await task.value
        if inFlightDemandFetches[index]?.id == id {
            inFlightDemandFetches.removeValue(forKey: index)
        }
        return result
    }

    private func cachedCompleteChunk(_ index: Int) async -> Data? {
        if let cached = recentChunks[index] { return cached }
        if let write = activeWrite, write.index == index { return write.data }
        if let pending = pendingWrites.first(where: { $0.index == index }) { return pending.data }
        guard knownDiskChunks.contains(index) else { return nil }
        if let cached = await diskCache.readChunk(index) { return cached }
        knownDiskChunks.remove(index)
        return nil
    }

    /// Reads a requested tail slice only from already complete cache chunks.
    /// A cache miss leaves the range untouched for the bounded tail fetch path.
    private func cachedCompleteData(in range: Range<Int64>) async -> Data? {
        guard !range.isEmpty else { return Data() }
        var result = Data(capacity: Int(range.count))
        var offset = range.lowerBound
        while offset < range.upperBound {
            let chunk = diskCache.chunkIndex(forByteOffset: offset)
            guard let completeChunk = await cachedCompleteChunk(chunk) else { return nil }
            let chunkRange = diskCache.byteRange(forChunk: chunk)
            let end = min(range.upperBound, chunkRange.upperBound)
            let startIndex = Int(offset - chunkRange.lowerBound)
            let endIndex = Int(end - chunkRange.lowerBound)
            guard startIndex >= 0, endIndex <= completeChunk.count, endIndex > startIndex else { return nil }
            result.append(completeChunk[startIndex..<endIndex])
            offset = end
        }
        return result
    }

    private func tailSpanRange() -> Range<Int64>? {
        let fileLength = diskCache.fileLength
        guard fileLength > 0 else { return nil }
        return max(0, fileLength - Self.tailFetchSpanBytes)..<fileLength
    }

    private func tailSlice(_ span: Data, range: Range<Int64>, spanRange: Range<Int64>) -> Data? {
        guard range.lowerBound >= spanRange.lowerBound, range.upperBound <= spanRange.upperBound else { return nil }
        let start = Int(range.lowerBound - spanRange.lowerBound)
        let end = Int(range.upperBound - spanRange.lowerBound)
        guard start >= 0, end <= span.count, end > start else { return nil }
        return Data(span[start..<end])
    }

    private func fetchTransientTailSpan() async -> Data? {
        guard !stopped, !Task.isCancelled, let range = tailSpanRange() else { return nil }
        if let transientTailSpan { return transientTailSpan }

        if let existing = inFlightTailFetch {
            let data = await existing.task.value
            if inFlightTailFetch?.id == existing.id {
                inFlightTailFetch = nil
                if !stopped, let data { transientTailSpan = data }
            }
            return data
        }

        let id = UUID()
        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.executeTailSpanFetch(range)
        }
        inFlightTailFetch = InFlightTailFetch(id: id, task: task)
        let data = await task.value
        if inFlightTailFetch?.id == id {
            inFlightTailFetch = nil
            if !stopped, let data { transientTailSpan = data }
        }
        return data
    }

    private func executeTailSpanFetch(_ range: Range<Int64>) async -> Data? {
        guard !stopped, !Task.isCancelled, await acquireFetchSlot(priority: .demand) else { return nil }
        var holdsDemandSlot = true
        defer {
            if holdsDemandSlot { releaseFetchSlot(priority: .demand) }
        }
        guard !stopped, !Task.isCancelled else { return nil }

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        for (key, value) in customHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

        let stream = PlaybackStreamRangeDelegate(
            expectedRange: range,
            expectedFileLength: diskCache.fileLength,
            customHeaders: customHeaders,
            requiresExactFileLength: true
        )
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            guard !stopped, !Task.isCancelled else { return nil }
            stream.start(in: urlSession, request: request)
            var data = Data(capacity: Int(range.count))
            while let piece = try await stream.next() {
                guard !stopped, !Task.isCancelled else { throw CancellationError() }
                data.append(piece)
                guard Int64(data.count) <= range.count else { throw PlaybackStreamRangeError.invalidBodyLength }
            }
            guard data.count == Int(range.count), !stopped, !Task.isCancelled else {
                throw PlaybackStreamRangeError.invalidBodyLength
            }
            resetTransportRetryBackoff()
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            if elapsed > 0.05 { updateThroughput(Double(range.count) / elapsed) }
            lastSuccessfulFetchAt = Date()
            return data
        } catch {
            stream.cancel()
            if holdsDemandSlot {
                releaseFetchSlot(priority: .demand)
                holdsDemandSlot = false
            }
            if case let PlaybackStreamRangeError.httpStatus(status, retryAfter) = error,
               status == 429 || status == 503 {
                let delay = applyRateLimitThrottle(retryAfter: retryAfter)
                recordDiagnostic("demand upstream HTTP \(status); cooldownSeconds=\(String(format: "%.1f", delay))")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            let nsError = error as NSError
            noteTransportFailure(error, priority: .demand)
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                noteUpstreamTimeout()
            }
            return nil
        }
    }

    private enum BatchJoinOutcome {
        case chunk(Data)
        case stalled
        case cancelled
    }

    private func performDemandFetch(_ index: Int) async -> Data? {
        guard !stopped, !Task.isCancelled else { return nil }
        if let cached = recentChunks[index] { return cached }
        if let write = activeWrite, write.index == index { return write.data }
        if let pending = pendingWrites.first(where: { $0.index == index }) { return pending.data }
        if knownDiskChunks.contains(index) {
            if let cached = await diskCache.readChunk(index) { return cached }
            guard !stopped, !Task.isCancelled else { return nil }
            knownDiskChunks.remove(index)
        }
        if let cached = await diskCache.readChunk(index) {
            knownDiskChunks.insert(index)
            return cached
        }

        var singleChunkDemand = false
        if let existing = inFlightBatchFetches[index] {
            switch await joinBatchForDemand(existing, index: index) {
            case .chunk(let data):
                return data
            case .stalled, .cancelled:
                singleChunkDemand = true
            }
            guard !stopped, !Task.isCancelled else { return nil }
        }
        if let cached = recentChunks[index] { return cached }
        if let write = activeWrite, write.index == index { return write.data }
        if let pending = pendingWrites.first(where: { $0.index == index }) { return pending.data }
        return await executeDemandFetch(index, singleChunk: singleChunkDemand)
    }

    private func executeDemandFetch(_ index: Int, singleChunk: Bool) async -> Data? {
        let count = singleChunk ? 1 : maxBatchChunks
        let fetched = await fetchAndCacheBatch(
            startingAt: index, count: count,
            priority: .demand, awaitFirstChunk: true
        )
        return fetched?[index]
    }

    private func joinBatchForDemand(
        _ existing: (batch: PlaybackStreamSharedBatch, task: Task<Bool, Never>), index: Int
    ) async -> BatchJoinOutcome {
        demandOwnedBatchIDs.insert(existing.batch.id)
        let coolingDown = throttleUntil.map { $0 > Date() } ?? false
        if coolingDown && existing.batch.priority != .demand {
            existing.task.cancel()
            removeCompletedBatch(existing.batch, count: existing.batch.count)
            return .cancelled
        }
        let grace = demandBatchJoinGraceNanoseconds
        enum TaskResult {
            case chunk(Data?)
            case timedOut
        }
        let outcome = await withTaskGroup(of: TaskResult.self) { group in
            group.addTask {
                let data = await existing.batch.awaitChunk(index)
                return .chunk(data)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: grace)
                return .timedOut
            }
            let first = await group.next()
            group.cancelAll()
            return first
        }
        switch outcome {
        case .chunk(let data):
            if let data { return .chunk(data) }
            // The batch finished or was cancelled without this chunk; clean it up so demand fetches cleanly
            if let current = inFlightBatchFetches[index], current.batch.id == existing.batch.id {
                current.task.cancel()
                removeCompletedBatch(existing.batch, count: existing.batch.count)
            }
            return .cancelled
        case .timedOut:
            guard !stopped, !Task.isCancelled else { return .cancelled }
            if let current = inFlightBatchFetches[index], current.batch.id == existing.batch.id {
                if let data = existing.batch.finishIfChunkUnavailable(index) { return .chunk(data) }
                current.task.cancel()
                removeCompletedBatch(existing.batch, count: existing.batch.count)
            }
            return .stalled
        case .none:
            if let current = inFlightBatchFetches[index], current.batch.id == existing.batch.id {
                current.task.cancel()
                removeCompletedBatch(existing.batch, count: existing.batch.count)
            }
            return .cancelled
        }
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
            if awaitFirstChunk {
                if let data = await existing.batch.awaitChunk(startChunk) {
                    return [startChunk: data]
                }
                // Batch failed to provide startChunk; purge it so we can fetch directly
                existing.task.cancel()
                removeCompletedBatch(existing.batch, count: existing.batch.count)
            } else {
                var result: [Int: Data] = [:]
                for index in startChunk..<(startChunk + actualCount) {
                    if let data = await existing.batch.awaitChunk(index) {
                        result[index] = data
                    }
                }
                if !result.isEmpty {
                    return result
                }
                // Batch yielded no chunks; clear it and proceed to fetch
                existing.task.cancel()
                removeCompletedBatch(existing.batch, count: existing.batch.count)
            }
        }

        for offset in 0..<actualCount where inFlightBatchFetches[startChunk + offset] != nil {
            actualCount = offset
            break
        }
        guard actualCount > 0 else {
            if priority == .demand {
                if let blocking = inFlightBatchFetches[startChunk] {
                    blocking.task.cancel()
                    removeCompletedBatch(blocking.batch, count: blocking.batch.count)
                }
                return await fetchAndCacheBatch(startingAt: startChunk, count: 1, priority: priority, awaitFirstChunk: awaitFirstChunk)
            }
            return nil
        }

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
            if let firstChunk = await batch.awaitChunk(startChunk) {
                return [startChunk: firstChunk]
            }
            // Multi-chunk demand fetch failed to yield the first chunk; fall back to a single chunk demand fetch
            if actualCount > 1 && priority == .demand {
                task.cancel()
                removeCompletedBatch(batch, count: actualCount)
                return await fetchAndCacheBatch(startingAt: startChunk, count: 1, priority: .demand, awaitFirstChunk: true)
            }
            return nil
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
        preemptedBackgroundBatchIDs.remove(batch.id)
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
            if Task.isCancelled || stopped { return false }
            guard await acquireFetchSlot(priority: priority) else { return false }
            guard !stopped, !Task.isCancelled else {
                releaseFetchSlot(priority: priority)
                return false
            }

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
                expectedRange: batchRange,
                expectedFileLength: diskCache.fileLength,
                customHeaders: customHeaders
            )
            do {
                guard !stopped, !Task.isCancelled else {
                    releaseFetchSlot(priority: priority)
                    return false
                }
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
                resetTransportRetryBackoff()
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                if elapsed > 0.05 {
                    updateThroughput(Double(batchRange.count) / elapsed)
                }
                lastSuccessfulFetchAt = Date()
                enqueuePersistence(batch, priority: priority)
                releaseFetchSlot(priority: priority)
                return true
            } catch {
                stream.cancel()
                releaseFetchSlot(priority: priority)
                let nsError = error as NSError
                noteTransportFailure(error, priority: priority)
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                    noteUpstreamTimeout()
                }
                if case let PlaybackStreamRangeError.httpStatus(status, retryAfter) = error {
                    if status == 401 || status == 403 || status == 404 || status == 410 || status == 416 {
                        diskCacheLog.warning("Upstream \(String(describing: priority)) batch [\(startChunk)..<(\(startChunk + actualCount))] non-retryable HTTP \(status)")
                        recordDiagnostic("upstream batch priority=\(priority) chunks=\(startChunk)..<\(startChunk + actualCount) HTTP \(status) non-retryable")
                        break
                    }
                    if status == 429 || status == 503 {
                        let delay = applyRateLimitThrottle(retryAfter: retryAfter)
                        recordDiagnostic("upstream batch priority=\(priority) chunks=\(startChunk)..<\(startChunk + actualCount) HTTP \(status) attempt=\(attempt)/3 cooldownSeconds=\(String(format: "%.1f", delay))")
                        if priority != .demand {
                            diskCacheLog.warning("Upstream \(String(describing: priority)) batch [\(startChunk)..<(\(startChunk + actualCount))] rate limited (\(status)), yielding immediately for \(delay)s cooldown")
                            break
                        } else {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                    }
                }
                if attempt == 3 {
                    diskCacheLog.warning("Upstream \(String(describing: priority)) batch [\(startChunk)..<(\(startChunk + actualCount))] failed after 3 attempts: \(error.localizedDescription)")
                    recordDiagnostic("upstream batch priority=\(priority) chunks=\(startChunk)..<\(startChunk + actualCount) failed attempt=3 errorCode=\(nsError.code)")
                } else {
                    recordDiagnostic("upstream retry priority=\(priority) chunks=\(startChunk)..<\(startChunk + actualCount) attempt=\(attempt)/3 errorCode=\(nsError.code)")
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
            guard pendingWrites.count < maxBatchChunks * 4 else { break }
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
            let transportCoolingDown = transportRetryNotBefore.map { $0 > Date() } ?? false
            let isDemand = priority == .demand
            let isForward = priority == .forward
            if isDemand && !queuedDemand {
                queuedDemandWaiters += 1
                queuedDemand = true
                preemptBackgroundTasksForDemand()
            }
            if isDemand {
                // Real-time playback demand must NEVER be starved by extended background cooldowns (10-60s).
                // However, enforce a brief spacing (up to rateLimitCooldown, capped at 0.2s) after a 429
                // to avoid immediate rate-limit hammering while keeping playback seamless.
                let minDemandSpacing = min(rateLimitCooldown, 0.2)
                let recentThrottle = lastThrottleTime.map { Date().timeIntervalSince($0) < minDemandSpacing } ?? false
                if !transportCoolingDown && !recentThrottle && activeUpstreamFetches < maxConcurrentUpstream {
                    activeUpstreamFetches += 1
                    activeDemandFetches += 1
                    return true
                }
            } else if !transportCoolingDown && !coolingDown {
                let canEnter = isForward || (!hasActiveDemand && activeUpstreamFetches < maxConcurrentUpstream)
                let reservedSlots = hasActiveDemand ? 1 : 0
                if canEnter && (activeUpstreamFetches + reservedSlots) < maxConcurrentUpstream {
                    activeUpstreamFetches += 1
                    return true
                }
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

    private func recordDiagnostic(_ message: String) {
        PlaybackDiagnosticLogStore.shared.append(source: "DiskCache", message: message)
    }

    private func markDiskWriteFailed() {
        diskWriteRetryAfter = Date().addingTimeInterval(30)
        diskCacheLog.error("Pausing background cache fills for 30 seconds after a disk write failure")
        recordDiagnostic("disk write failed; background cache fills cooling down for 30 seconds")
    }

    private func shouldPersistToDisk() -> Bool {
        !diskWriteCoolingDown
    }

    private func applyRateLimitThrottle(retryAfter: String?) -> TimeInterval {
        isThrottled = true
        throttleCeiling = maxConcurrentUpstream
        maxConcurrentUpstream = max(1, maxConcurrentUpstream / 2)
        rampInterval = min(Self.rampIntervalMax, max(Self.rampIntervalMin, rampInterval * 2))
        lastThrottleTime = Date()
        let parsedDelay = retryAfter.flatMap(TimeInterval.init)
        let retryAfter = parsedDelay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? rateLimitCooldown
        let delay = min(max(0.1, retryAfter), 60)
        let newUntil = Date().addingTimeInterval(delay)
        throttleUntil = max(throttleUntil ?? .distantPast, newUntil)
        diskCacheLog.warning("Provider rate limit detected. Concurrency halved to \(self.maxConcurrentUpstream), ramp interval \(self.rampInterval)s")
        recordDiagnostic("provider throttle active; concurrency=\(maxConcurrentUpstream) cooldownSeconds=\(String(format: "%.1f", delay))")
        return delay
    }

    private func noteTransportFailure(_ error: Error, priority: FetchPriority) {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain,
              nsError.code == URLError.Code.cannotConnectToHost.rawValue
                || nsError.code == URLError.Code.networkConnectionLost.rawValue else { return }

        transportRetryStreak = min(transportRetryStreak + 1, 32)
        let exponent = min(transportRetryStreak - 1, 16)
        let delay = min(Self.transportRetryMaxDelay,
                        transportRetryBaseDelay * pow(2.0, Double(exponent)))
        let retryNotBefore = Date().addingTimeInterval(delay)
        transportRetryNotBefore = max(transportRetryNotBefore ?? .distantPast, retryNotBefore)

        // When the upstream host rejects connections (ECONNREFUSED / -1004) or repeatedly drops them,
        // activate provider throttling to halve concurrency and pause background prefetching.
        if (nsError.code == URLError.Code.cannotConnectToHost.rawValue && priority != .demand) || transportRetryStreak >= 2 {
            _ = applyRateLimitThrottle(retryAfter: String(format: "%.2f", delay))
        }

        recordDiagnostic(
            "upstream transport failure priority=\(priority) errorCode=\(nsError.code) " +
            "streak=\(transportRetryStreak) cooldownSeconds=\(String(format: "%.2f", delay))"
        )
    }

    private func resetTransportRetryBackoff() {
        transportRetryStreak = 0
        transportRetryNotBefore = nil
    }

    private func noteUpstreamTimeout() {
        isThrottled = true
        maxConcurrentUpstream = max(1, maxConcurrentUpstream / 2)
        throttleCeiling = maxConcurrentUpstream
        rampInterval = min(Self.rampIntervalMax, max(Self.rampIntervalMin, rampInterval * 2))
        lastThrottleTime = Date()
        diskCacheLog.warning("Upstream range timed out; reducing concurrent fetches to \(self.maxConcurrentUpstream)")
        recordDiagnostic("upstream range timed out; concurrency reduced to \(maxConcurrentUpstream)")
    }

    private func checkThrottleRecovery() {
        let now = Date()
        if isThrottled, let last = lastThrottleTime, now.timeIntervalSince(last) >= throttleRecoveryInterval {
            isThrottled = false
            throttleCeiling = nil
            lastRampAt = now
            rampInterval = Self.rampIntervalMin
            diskCacheLog.notice("Upstream recovery period elapsed. Concurrency may ramp after successful fetches.")
            recordDiagnostic("upstream recovery interval elapsed; concurrency may ramp")
            return
        }
        // Progressive ramp up if running smoothly without errors
        if maxConcurrentUpstream < configuredMaxConcurrentUpstream,
           let lastSuccessfulFetchAt, lastSuccessfulFetchAt > lastRampAt,
           (throttleUntil == nil || throttleUntil! <= now),
           now.timeIntervalSince(lastRampAt) >= rampInterval {
            if let ceiling = throttleCeiling, maxConcurrentUpstream >= ceiling {
                // At known ceiling: wait for full recovery interval before probing again
                return
            }
            maxConcurrentUpstream += 1
            lastRampAt = now
            rampInterval = max(Self.rampIntervalMin, rampInterval * 0.9)
            diskCacheLog.info("Progressive ramp-up: concurrency increased to \(self.maxConcurrentUpstream)")
            recordDiagnostic("upstream recovery ramp; concurrency=\(maxConcurrentUpstream)")
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

        let requestStartTime = CFAbsoluteTimeGetCurrent()
        let startChunkIdx = diskCache.chunkIndex(forByteOffset: requestedStart)
        let endChunkIdx = diskCache.chunkIndex(forByteOffset: requestedEnd)
        let isFullyOnDisk = (startChunkIdx...endChunkIdx).allSatisfy { knownDiskChunks.contains($0) }
        diskCacheLog.debug("[DiskCacheWatchdog] 📥 Range: bytes=\(requestedStart)-\(requestedEnd) (\(responseLength)B, chunks [\(startChunkIdx)..\(endChunkIdx)], allOnDisk: \(isFullyOnDisk))")

        var headers = isRangeRequest ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: video/mp4\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Content-Length: \(responseLength)\r\n"
        if isRangeRequest {
            headers += "Content-Range: bytes \(requestedStart)-\(requestedEnd)/\(fileLength)\r\n"
        }
        headers += "Connection: close\r\n\r\n"

        var prefetchedTailData: Data?
        if method.uppercased() == "GET", isRangeRequest,
           let spanRange = tailSpanRange() {
            let requestedRange = requestedStart..<(requestedEnd + 1)
            if requestedRange.lowerBound >= spanRange.lowerBound,
               requestedRange.upperBound <= spanRange.upperBound {
                // Complete chunk data remains the first choice. The short span
                // path is only used when no complete cached chunk can satisfy it.
                prefetchedTailData = await cachedCompleteData(in: requestedRange)
                if prefetchedTailData == nil, let transientTailSpan {
                    prefetchedTailData = tailSlice(transientTailSpan, range: requestedRange, spanRange: spanRange)
                }
                if prefetchedTailData == nil, let fetchedSpan = await fetchTransientTailSpan() {
                    prefetchedTailData = tailSlice(fetchedSpan, range: requestedRange, spanRange: spanRange)
                }
            }
        }

        try await NetworkIO.send(connection, Data(headers.utf8))
        if method.uppercased() == "HEAD" { return false }
        if let prefetchedTailData {
            try await NetworkIO.send(connection, prefetchedTailData)
            diskCacheLog.debug("[DiskCacheWatchdog] 📤 Served tail range from complete cache or bounded span (\(prefetchedTailData.count)B)")
            return false
        }

        // Stream range to client using Demand Priority, clamped to chunk boundaries
        var currentOffset = requestedStart
        var firstChunkDelivered = false
        while currentOffset <= requestedEnd && !Task.isCancelled {
            let chunkIdx = diskCache.chunkIndex(forByteOffset: currentOffset)
            let chunkRange = diskCache.byteRange(forChunk: chunkIdx)
            let maxInCurrentChunk = Int(chunkRange.upperBound - currentOffset)
            guard maxInCurrentChunk > 0 else { break }
            let bytesToRead = min(maxInCurrentChunk, Int(requestedEnd - currentOffset + 1))

            // Demand owns the RAM fast path while an upstream batch is alive;
            // it falls back to a disk chunk read only when no shared transfer exists.
            let chunkStartTime = CFAbsoluteTimeGetCurrent()
            var data: Data?
            var fetchOrigin = "unknown"
            for retry in 0...2 {
                if let fetched = await fetchDemandChunk(chunkIdx) {
                    let sliceStart = Int(currentOffset - chunkRange.lowerBound)
                    let sliceEnd = sliceStart + bytesToRead
                    if sliceStart >= 0, sliceEnd <= fetched.count {
                        data = Data(fetched[sliceStart..<sliceEnd])
                        fetchOrigin = knownDiskChunks.contains(chunkIdx) ? "DISK" : (recentChunks[chunkIdx] != nil ? "RAM" : "NETWORK")
                        break
                    }
                }
                guard !Task.isCancelled, !stopped else { break }
                if retry < 2 {
                    try? await Task.sleep(nanoseconds: 50_000_000 * UInt64(retry + 1))
                }
            }
            let chunkElapsedMs = (CFAbsoluteTimeGetCurrent() - chunkStartTime) * 1000

            guard let bytesToSend = data, !bytesToSend.isEmpty else {
                diskCacheLog.error("[DiskCacheWatchdog] ❌ Demand fetch failed for offset \(currentOffset) in chunk \(chunkIdx) after retries. Aborting range response.")
                recordDiagnostic("demand exhausted offset=\(currentOffset) chunk=\(chunkIdx) attempts=3; range response aborted")
                break
            }
            try await NetworkIO.send(connection, bytesToSend)
            if !firstChunkDelivered {
                firstChunkDelivered = true
                let ttfbMs = (CFAbsoluteTimeGetCurrent() - requestStartTime) * 1000
                diskCacheLog.debug("[DiskCacheWatchdog] ⚡ TTFB: \(String(format: "%.1f", ttfbMs))ms for chunk [\(chunkIdx)] (origin: \(fetchOrigin), chunkFetch: \(String(format: "%.1f", chunkElapsedMs))ms)")
            }
            currentOffset += Int64(bytesToSend.count)
            if tracksPlaybackAnchor {
                updateClientReadOffset(currentOffset, generation: readGeneration)
            }
        }

        let totalRequestElapsedMs = (CFAbsoluteTimeGetCurrent() - requestStartTime) * 1000
        let totalSentBytes = currentOffset - requestedStart
        diskCacheLog.debug("[DiskCacheWatchdog] 📤 Streamed \(totalSentBytes)/\(responseLength)B in \(String(format: "%.1f", totalRequestElapsedMs))ms (chunks [\(startChunkIdx)..\(self.diskCache.chunkIndex(forByteOffset: max(requestedStart, currentOffset - 1)))])")

        return false
    }

    // MARK: - Telemetry & Ranges

    var fileLength: Int64 {
        diskCache.fileLength
    }

    var currentCachedBytes: Int64 {
        get async {
            await diskCache.currentCachedBytes
        }
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

    var concurrencyMetrics: (active: Int, currentMax: Int, configuredMax: Int) {
        (active: activeUpstreamFetches, currentMax: maxConcurrentUpstream, configuredMax: configuredMaxConcurrentUpstream)
    }
}
