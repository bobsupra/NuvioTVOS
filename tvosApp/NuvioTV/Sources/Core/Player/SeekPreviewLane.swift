import CoreGraphics
import Foundation
import AetherEngine

// MARK: - Policy

/// When a seek preview may read the source over the network, outside what playback buffered.
///
/// Aether plays a remote file over ONE held connection (`maxConcurrentSourceRequests: 1`,
/// `heldSourceConnection`), and the engine ends that connection five seconds into a pause. With
/// the "previews beyond the buffer" option off, a preview therefore reads the origin only once
/// that connection is gone, so there is never a second connection. With the option on, a
/// separate preview connection may also run during playback while the buffer is healthy.
enum SeekPreviewNetworkPolicy {
    enum Decision: Equatable, Sendable {
        case allowed
        /// Option off and playback is running: the source connection belongs to playback.
        case playing
        /// Option off and Aether may still hold its paused connection.
        case pauseTooRecent
        case bufferLow
        case throughputLow
        /// Loading, seeking or rebuffering.
        case busy
    }

    /// Aether ends a held playback connection five seconds into a pause; half a second of margin.
    static let heldConnectionReleaseSeconds: TimeInterval = 5.5
    static let minimumForwardBufferSeconds: Double = 15
    /// The link must deliver this many times the media bitrate before previews may share it.
    static let throughputHeadroom: Double = 1.5

    static var beyondBufferEnabled: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.seekPreviewBeyondBuffer) as? Bool ?? false
    }

    static func aether(
        beyondBuffer: Bool,
        isPaused: Bool,
        pausedFor: TimeInterval?,
        isPlaying: Bool,
        forwardBufferSeconds: Double?,
        throughputMbps: Double?,
        bitrateMbps: Double?
    ) -> Decision {
        if isPaused {
            if beyondBuffer { return .allowed }
            guard let pausedFor, pausedFor >= heldConnectionReleaseSeconds else { return .pauseTooRecent }
            return .allowed
        }
        guard isPlaying else { return .busy }
        guard beyondBuffer else { return .playing }
        return playingHealth(
            forwardBufferSeconds: forwardBufferSeconds,
            throughputMbps: throughputMbps,
            bitrateMbps: bitrateMbps)
    }

    /// MPV has no single-connection rule (its previews always opened their own request), so a
    /// pause admits previews at once.
    static func mpv(
        beyondBuffer: Bool,
        isPaused: Bool,
        isPlaying: Bool,
        cacheSeconds: Double?
    ) -> Decision {
        if isPaused { return .allowed }
        guard isPlaying else { return .busy }
        guard beyondBuffer else { return .playing }
        return playingHealth(forwardBufferSeconds: cacheSeconds, throughputMbps: nil, bitrateMbps: nil)
    }

    static func playingHealth(forwardBufferSeconds: Double?, throughputMbps: Double?, bitrateMbps: Double?) -> Decision {
        guard let buffer = forwardBufferSeconds, buffer.isFinite,
              buffer >= minimumForwardBufferSeconds else { return .bufferLow }
        if let throughput = throughputMbps, let bitrate = bitrateMbps,
           throughput.isFinite, bitrate.isFinite, bitrate > 0,
           throughput < bitrate * throughputHeadroom {
            return .throughputLow
        }
        return .allowed
    }

    /// The origin a preview reads, or nil when this source is not served by the preview lane:
    /// live, HLS, disc images, and every loopback source (torrent, Usenet, a cache proxy without
    /// its remote descriptor) keep the previews they had.
    static func previewOrigin(
        playbackURL: URL?,
        headerSourceURL: URL?,
        descriptorRemoteURL: URL?,
        isLive: Bool,
        isKnownHLS: Bool
    ) -> URL? {
        guard !isLive, !isKnownHLS,
              let url = descriptorRemoteURL ?? headerSourceURL ?? playbackURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              !["127.0.0.1", "localhost", "::1"].contains(host),
              !PlaybackThumbnailSourceFallback.isKnownHLSURL(url),
              !UsenetStreamServer.isStreamURL(url) else { return nil }
        guard !["iso", "img", "udf"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}

// MARK: - Grid

/// Previews outside the buffer are keyframes on a fixed 5 s grid: one decode serves every target
/// inside its cell, and the cell index is the cache key.
enum SeekPreviewGrid {
    static let cellSeconds: Double = 5

    static func cell(for seconds: Double, duration: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let clamped = duration.isFinite && duration > 1 ? min(seconds, duration - 1) : seconds
        return Int(floor(max(0, clamped) / cellSeconds))
    }

    /// Where the cell is decoded: the keyframe at or before its middle.
    static func center(of cell: Int) -> Double { (Double(cell) + 0.5) * cellSeconds }

    /// Whole-second disk bucket of a cell (`TrickplayDiskCache` rounds to seconds).
    static func storageSeconds(of cell: Int) -> Double { Double(cell) * cellSeconds }

    static func lastCell(duration: Double) -> Int? {
        guard duration.isFinite, duration > 0 else { return nil }
        return cell(for: duration, duration: duration)
    }

    /// `count` cells spread evenly over the title, for the coarse first-scrub storyboard.
    static func storyboardCells(duration: Double, count: Int) -> [Int] {
        guard count > 0, let last = lastCell(duration: duration) else { return [] }
        var cells: [Int] = []
        for index in 0..<count {
            let seconds = (Double(index) + 0.5) * duration / Double(count)
            if let cell = cell(for: seconds, duration: duration), cell <= last, !cells.contains(cell) {
                cells.append(cell)
            }
        }
        return cells
    }

    /// The next cells in the scrub direction, nearest first.
    static func neighbors(of cell: Int, direction: Double, count: Int, lastCell: Int) -> [Int] {
        guard count > 0 else { return [] }
        let step = direction < 0 ? -1 : 1
        return (1...count).map { cell + $0 * step }.filter { $0 >= 0 && $0 <= lastCell }
    }
}

// MARK: - Range transport

/// The preview lane's own HTTP range requests: one request at a time over one keep-alive
/// connection, separate from playback. Paced, and stopped for the rest of the source session when
/// the origin pushes back (429/503/509) or keeps failing.
final class SeekPreviewRangeTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case cancelled
        case tripped(String)
        case http(Int)
        case transport
        case rangeUnsupported
        case endOfFile
    }

    struct Chunk {
        let data: Data
        let totalSize: Int64?
    }

    struct Stats: Equatable, Sendable {
        var requests = 0
        var bytes: Int64 = 0
        var failures = 0
        var trippedReason: String?
        var usesResolvedURL = false
    }

    static let throttleStatuses: Set<Int> = [429, 503, 509]
    static let consecutiveFailureLimit = 3
    static let requestTimeout: TimeInterval = 8
    /// Token bucket: a short burst for one interactive decode, then about 1.7 requests a second.
    static let burstRequests: Double = 4
    static let refillInterval: TimeInterval = 0.6

    private final class Exchange {
        let task: URLSessionDataTask
        let offset: Int64
        let length: Int
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var aborted = false

        init(task: URLSessionDataTask, offset: Int64, length: Int) {
            self.task = task
            self.offset = offset
            self.length = length
        }
    }

    private let originURL: URL
    private let headers: [String: String]
    private let lock = NSLock()
    private var session: URLSession?
    private var active: Exchange?
    private var resolvedURL: URL?
    private var consecutiveFailures = 0
    private var trippedReasonStorage: String?
    private var tokens: Double
    private var lastRefill: Date
    private var statsStorage = Stats()
    private var invalidated = false

    /// `configuration` is a seam for tests (a stub URLProtocol); the lane passes none.
    init(originURL: URL, headers: [String: String], configuration base: URLSessionConfiguration? = nil) {
        self.originURL = originURL
        self.headers = headers
        self.tokens = Self.burstRequests
        self.lastRefill = Date()
        super.init()
        let configuration = base ?? URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "nuvio.seek-preview.transport"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    var trippedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return trippedReasonStorage
    }

    var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        var copy = statsStorage
        copy.trippedReason = trippedReasonStorage
        copy.usesResolvedURL = resolvedURL != nil
        return copy
    }

    /// Blocking; called on the preview decoder's queue, never on the main thread.
    func fetch(offset: Int64, length: Int, isAborted: () -> Bool) -> Result<Chunk, Failure> {
        guard offset >= 0, length > 0 else { return .failure(.transport) }
        var retriedOrigin = false
        while true {
            if let reason = trippedReason { return .failure(.tripped(reason)) }
            guard waitForToken(isAborted: isAborted) else { return .failure(.cancelled) }
            lock.lock()
            let resolved = resolvedURL
            lock.unlock()
            let url = resolved ?? originURL
            guard let exchange = perform(url: url, offset: offset, length: length, isAborted: isAborted) else {
                return .failure(.cancelled)
            }
            if exchange.aborted { return .failure(.cancelled) }
            let status = exchange.response?.statusCode ?? 0
            switch status {
            case 206:
                // A body cut short (timeout) still holds valid bytes from `offset`.
                guard !exchange.data.isEmpty else {
                    recordFailure()
                    return .failure(.transport)
                }
                lock.lock()
                consecutiveFailures = 0
                statsStorage.requests += 1
                statsStorage.bytes += Int64(exchange.data.count)
                if let final = exchange.response?.url, final != url, resolved == nil {
                    resolvedURL = final
                }
                lock.unlock()
                let total = Self.totalSize(fromContentRange: exchange.response?.value(forHTTPHeaderField: "Content-Range"))
                return .success(Chunk(data: exchange.data, totalSize: total))
            case 200:
                // The origin ignored Range: no seeking is possible, so no previews from it.
                trip("no range support")
                return .failure(.rangeUnsupported)
            case 416:
                return .failure(.endOfFile)
            case let code where Self.throttleStatuses.contains(code):
                trip("HTTP \(code)")
                return .failure(.tripped("HTTP \(code)"))
            case let code where [401, 403, 404, 410].contains(code) && resolved != nil && !retriedOrigin:
                // The resolved CDN link expired: resolve again through the original URL, once.
                lock.lock()
                resolvedURL = nil
                lock.unlock()
                retriedOrigin = true
                continue
            case 0:
                recordFailure()
                return .failure(.transport)
            default:
                recordFailure()
                return .failure(.http(status))
            }
        }
    }

    /// Unblocks a waiting fetch; the transport stays usable.
    func cancelInFlight() {
        lock.lock()
        let exchange = active
        exchange?.aborted = true
        lock.unlock()
        exchange?.task.cancel()
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let exchange = active
        exchange?.aborted = true
        let session = self.session
        self.session = nil
        lock.unlock()
        exchange?.task.cancel()
        session?.invalidateAndCancel()
    }

    static func totalSize(fromContentRange value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard let size = Int64(total), size > 0 else { return nil }
        return size
    }

    private func trip(_ reason: String) {
        lock.lock()
        if trippedReasonStorage == nil { trippedReasonStorage = reason }
        lock.unlock()
    }

    private func recordFailure() {
        lock.lock()
        consecutiveFailures += 1
        statsStorage.failures += 1
        let shouldTrip = consecutiveFailures >= Self.consecutiveFailureLimit
        lock.unlock()
        if shouldTrip { trip("\(Self.consecutiveFailureLimit) failed requests") }
    }

    private func waitForToken(isAborted: () -> Bool) -> Bool {
        while true {
            lock.lock()
            if invalidated {
                lock.unlock()
                return false
            }
            let now = Date()
            tokens = min(Self.burstRequests, tokens + now.timeIntervalSince(lastRefill) / Self.refillInterval)
            lastRefill = now
            if tokens >= 1 {
                tokens -= 1
                lock.unlock()
                return true
            }
            let wait = (1 - tokens) * Self.refillInterval
            lock.unlock()
            if isAborted() { return false }
            Thread.sleep(forTimeInterval: min(0.1, max(0.01, wait)))
        }
    }

    private func perform(url: URL, offset: Int64, length: Int, isAborted: () -> Bool) -> Exchange? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        for (field, value) in headers where field.caseInsensitiveCompare("Range") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        lock.lock()
        guard !invalidated, let session else {
            lock.unlock()
            return nil
        }
        let task = session.dataTask(with: request)
        let exchange = Exchange(task: task, offset: offset, length: length)
        active = exchange
        lock.unlock()

        task.resume()
        let deadline = Date().addingTimeInterval(Self.requestTimeout + 2)
        var cancelled = false
        while exchange.done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            guard !cancelled else { continue }
            let abort = isAborted()
            if abort || Date() >= deadline {
                cancelled = true
                if abort {
                    lock.lock()
                    exchange.aborted = true
                    lock.unlock()
                }
                task.cancel()
            }
        }
        lock.lock()
        if active === exchange { active = nil }
        lock.unlock()
        return exchange
    }

    private func exchange(for task: URLSessionTask) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        guard let active, active.task === task else { return nil }
        return active
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let exchange = exchange(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        exchange.response = http
        let status = http?.statusCode ?? 0
        // Only a range answer (or the file head) has a body worth reading; the status is enough otherwise.
        completionHandler(status == 206 || (status == 200 && exchange.offset == 0) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask) else { return }
        let remaining = exchange.length - exchange.data.count
        if remaining > 0 { exchange.data.append(data.prefix(remaining)) }
        if exchange.data.count >= exchange.length, exchange.response?.statusCode == 200 {
            // The origin ignored Range and is sending the whole file: keep the head, stop the body.
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchange(for: task) else { return }
        exchange.error = error
        exchange.done.signal()
    }
}

// MARK: - Reader

/// Byte source of the preview decoder: serves the ranges it already fetched, and fetches a miss
/// through the transport. A read that runs on (the container head, a large keyframe) doubles the
/// next request, up to 8 MB, so FFmpeg's own read pattern decides how much a still costs.
final class SeekPreviewRangeReader: IOReader, @unchecked Sendable {
    static let initialFetchBytes = 512 * 1024
    static let maximumFetchBytes = 8 * 1024 * 1024
    static let cacheLimitBytes = 48 * 1024 * 1024
    private static let avseekSize: Int32 = 0x10000
    private static let avseekForce: Int32 = 0x20000

    private struct Segment {
        let start: Int64
        let data: Data
        var lastUse: UInt64
        var end: Int64 { start + Int64(data.count) }
    }

    private let transport: SeekPreviewRangeTransport
    private let lock = NSLock()
    private var segments: [Segment] = []
    private var cachedBytesStorage = 0
    private var useCounter: UInt64 = 0
    private var position: Int64 = 0
    private var size: Int64?
    private var lastFetchEnd: Int64 = -1
    private var lastFetchLength = 0
    private var cancelGeneration: UInt64 = 0
    private var networkPermitted = false
    private var closed = false

    init(transport: SeekPreviewRangeTransport) {
        self.transport = transport
    }

    var discImageProbeEnabled: Bool { false }

    var cachedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedBytesStorage
    }

    /// The lane grants the network per admitted decode. Revoking it also ends a fetch in flight.
    func setNetworkPermitted(_ permitted: Bool) {
        lock.lock()
        let changed = networkPermitted != permitted
        networkPermitted = permitted
        if !permitted, changed { cancelGeneration &+= 1 }
        lock.unlock()
        if !permitted, changed { transport.cancelInFlight() }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size requested: Int32) -> Int32 {
        guard let buffer, requested >= 0 else { return -1 }
        guard requested > 0 else { return 0 }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return -1
        }
        let offset = position
        if let size, offset >= size {
            lock.unlock()
            return 0
        }
        if let copied = copyLocked(into: buffer, at: offset, count: Int(requested)) {
            position = offset + Int64(copied)
            lock.unlock()
            return Int32(copied)
        }
        guard networkPermitted else {
            lock.unlock()
            return -1
        }
        let generation = cancelGeneration
        let length = fetchLengthLocked(at: offset, requested: Int(requested))
        lock.unlock()

        let result = transport.fetch(offset: offset, length: length) { [weak self] in
            self?.isAborted(since: generation) ?? true
        }

        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let chunk):
            if let total = chunk.totalSize { size = total }
            guard !closed else { return -1 }
            guard !chunk.data.isEmpty else { return 0 }
            insertLocked(start: offset, data: chunk.data)
            lastFetchEnd = offset + Int64(chunk.data.count)
            lastFetchLength = chunk.data.count
            guard !closed, generation == cancelGeneration,
                  let copied = copyLocked(into: buffer, at: offset, count: Int(requested)) else { return -1 }
            position = offset + Int64(copied)
            return Int32(copied)
        case .failure(.endOfFile):
            return 0
        case .failure:
            return -1
        }
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        let mode = whence & ~Self.avseekForce
        if mode == Self.avseekSize {
            lock.lock()
            let known = size
            let permitted = networkPermitted && !closed
            lock.unlock()
            if let known { return known }
            guard permitted else { return -1 }
            learnSize()
            lock.lock()
            defer { lock.unlock() }
            return size ?? -1
        }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return -1 }
        let target: Int64
        switch mode {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END:
            guard let size else { return -1 }
            target = size + offset
        default:
            return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }

    /// Unblocks a read in flight without retiring the reader (the decoder reopens it after idle).
    func cancel() {
        lock.lock()
        cancelGeneration &+= 1
        lock.unlock()
        transport.cancelInFlight()
    }

    func close() {
        lock.lock()
        closed = true
        cancelGeneration &+= 1
        segments.removeAll()
        cachedBytesStorage = 0
        lock.unlock()
        transport.cancelInFlight()
    }

    private func isAborted(since generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || !networkPermitted || generation != cancelGeneration
    }

    /// AVSEEK_SIZE before the first read: fetch the head, which the open reads next anyway.
    private func learnSize() {
        lock.lock()
        // A head already fetched without a Content-Range total means the size is not knowable.
        guard size == nil, !closed, networkPermitted, !segments.contains(where: { $0.start == 0 }) else {
            lock.unlock()
            return
        }
        let generation = cancelGeneration
        let length = fetchLengthLocked(at: 0, requested: Self.initialFetchBytes)
        lock.unlock()
        let result = transport.fetch(offset: 0, length: length) { [weak self] in
            self?.isAborted(since: generation) ?? true
        }
        guard case .success(let chunk) = result else { return }
        lock.lock()
        if let total = chunk.totalSize { size = total }
        if !closed, !chunk.data.isEmpty, !segments.contains(where: { $0.start == 0 }) {
            insertLocked(start: 0, data: chunk.data)
            lastFetchEnd = Int64(chunk.data.count)
            lastFetchLength = chunk.data.count
        }
        lock.unlock()
    }

    private func fetchLengthLocked(at offset: Int64, requested: Int) -> Int {
        var length = offset == lastFetchEnd && lastFetchLength > 0
            ? min(lastFetchLength * 2, Self.maximumFetchBytes)
            : Self.initialFetchBytes
        length = max(length, requested)
        if let next = segments.first(where: { $0.start > offset }) {
            length = min(length, Int(next.start - offset))
        }
        if let size { length = min(length, Int(max(0, size - offset))) }
        return max(1, length)
    }

    private func copyLocked(into buffer: UnsafeMutablePointer<UInt8>, at offset: Int64, count: Int) -> Int? {
        guard let index = segments.firstIndex(where: { $0.start <= offset && offset < $0.end }) else { return nil }
        useCounter &+= 1
        segments[index].lastUse = useCounter
        let segment = segments[index]
        let start = Int(offset - segment.start)
        let amount = min(count, segment.data.count - start)
        guard amount > 0 else { return nil }
        let copied = segment.data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            memcpy(buffer, base.advanced(by: start), amount)
            return true
        }
        return copied ? amount : nil
    }

    private func insertLocked(start: Int64, data: Data) {
        useCounter &+= 1
        let segment = Segment(start: start, data: data, lastUse: useCounter)
        let index = segments.firstIndex(where: { $0.start > start }) ?? segments.count
        segments.insert(segment, at: index)
        cachedBytesStorage += data.count
        while cachedBytesStorage > Self.cacheLimitBytes, segments.count > 1 {
            guard let victim = segments.indices
                .filter({ segments[$0].start != start })
                .min(by: { segments[$0].lastUse < segments[$1].lastUse }) else { break }
            cachedBytesStorage -= segments[victim].data.count
            segments.remove(at: victim)
        }
    }
}

// MARK: - Lane

/// Resumes exactly once: with the decode's result, or with nil when the waiting request is
/// superseded first. The decode itself keeps running and fills the cache.
private final class SeekPreviewResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var pending: CGImage??
    private var finished = false

    func install(_ continuation: CheckedContinuation<CGImage?, Never>) {
        lock.lock()
        if let pending {
            finished = true
            self.pending = nil
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: CGImage?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let continuation {
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            if pending == nil { pending = .some(value) }
            lock.unlock()
        }
    }
}

/// What the debug HUD shows about seek previews.
@MainActor
final class SeekPreviewDiagnostics {
    static let shared = SeekPreviewDiagnostics()
    private(set) var line = ""

    func update(_ line: String) { self.line = line }
    func clear() { line = "" }
}

/// Seek previews for one remote source session, outside what playback buffered: one persistent
/// software decoder over `SeekPreviewRangeReader`, a 5 s keyframe grid, one decode at a time
/// (a new one retires the previous), cache first (memory, then disk), neighbours in the scrub
/// direction, and with the option on a 16-frame storyboard on the first scrub.
@MainActor
final class SeekPreviewLane {
    typealias Admission = @MainActor () -> SeekPreviewNetworkPolicy.Decision
    typealias LocalFrame = @MainActor (_ seconds: Double, _ maxDistance: Double) async -> CGImage?

    static let width = 360
    static let maximumNetworkDecodes = 200
    static let memoryCells = 64
    static let storyboardFrames = 16
    static let neighborCount = 2
    static let backgroundSpacingNanoseconds: UInt64 = 800_000_000
    static let consecutiveDecodeFailureLimit = 4
    /// Disk namespace version of grid keyframes; bump when what a cell holds changes.
    nonisolated static let diskKeySuffix = "_kf1"

    nonisolated static func diskKey(for streamKey: String) -> String { streamKey + diskKeySuffix }

    private struct MemoryEntry {
        let image: CGImage
        var lastUse: UInt64
    }

    private struct InFlight {
        let id: UInt64
        let cell: Int
        let task: Task<CGImage?, Never>
        let background: Bool
    }

    let originURL: URL
    let diskKey: String
    private let transport: SeekPreviewRangeTransport
    private let reader: SeekPreviewRangeReader
    private let admission: Admission
    private let localFrame: LocalFrame
    private var extractor: FrameExtractor?
    private var memory: [Int: MemoryEntry] = [:]
    private var useCounter: UInt64 = 0
    private var inFlight: InFlight?
    private var decodeSequence: UInt64 = 0
    private var backgroundQueue: [Int] = []
    private var backgroundTask: Task<Void, Never>?
    private var backgroundToken: UInt64 = 0
    private var storyboardQueued = false
    private var networkDecodes = 0
    private var networkFrames = 0
    private var consecutiveDecodeFailures = 0
    private var decodeDisabledReason: String?
    private var recentDecodeSeconds: [Double] = []
    private(set) var lastDecision: SeekPreviewNetworkPolicy.Decision = .busy
    private(set) var isShutDown = false

    init(originURL: URL, headers: [String: String], diskKey: String,
         admission: @escaping Admission, localFrame: @escaping LocalFrame) {
        self.originURL = originURL
        self.diskKey = diskKey
        self.admission = admission
        self.localFrame = localFrame
        let transport = SeekPreviewRangeTransport(originURL: originURL, headers: headers)
        self.transport = transport
        self.reader = SeekPreviewRangeReader(transport: transport)
        publishDiagnostics()
    }

    /// The still for `seconds`: a cached one, or one decoded from the network when admitted.
    func image(at seconds: Double, duration: Double) async -> CGImage? {
        guard !isShutDown, let cell = SeekPreviewGrid.cell(for: seconds, duration: duration) else { return nil }
        if let cached = await cachedImage(for: cell) { return cached }
        guard !isShutDown, !Task.isCancelled else { return nil }
        if let inFlight, inFlight.cell == cell {
            return await Self.awaitUnlessCancelled(inFlight.task)
        }
        guard canDecodeFromNetwork() else {
            publishDiagnostics()
            return nil
        }
        if SeekPreviewNetworkPolicy.beyondBufferEnabled { queueStoryboard(duration: duration) }
        let task = startDecode(cell: cell, duration: duration, background: false)
        return await Self.awaitUnlessCancelled(task)
    }

    /// The cell's still when it is already in memory; no disk, no decode.
    func memoryImage(at seconds: Double, duration: Double) -> CGImage? {
        guard !isShutDown, let cell = SeekPreviewGrid.cell(for: seconds, duration: duration),
              var entry = memory[cell] else { return nil }
        useCounter &+= 1
        entry.lastUse = useCounter
        memory[cell] = entry
        return entry.image
    }

    /// The nearest still the lane holds in memory within `maxDistance` of `seconds`.
    func nearestImage(to seconds: Double, maxDistance: Double) -> CGImage? {
        guard seconds.isFinite, maxDistance > 0 else { return nil }
        var best: (distance: Double, image: CGImage)?
        for (cell, entry) in memory {
            let distance = abs(SeekPreviewGrid.center(of: cell) - seconds)
            guard distance <= maxDistance else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (distance, entry.image) }
        }
        return best?.image
    }

    /// Background neighbours in the scrub direction; never retires a foreground decode.
    func prefetch(around seconds: Double, direction: Double, duration: Double) {
        guard !isShutDown, let cell = SeekPreviewGrid.cell(for: seconds, duration: duration) else { return }
        queueNeighbors(of: cell, direction: direction, duration: duration)
    }

    /// Seconds until a pause has released Aether's held connection, while that is what blocks.
    func admissionDelay(pausedFor: TimeInterval?) -> TimeInterval? {
        guard lastDecision == .pauseTooRecent, let pausedFor else { return nil }
        let remaining = SeekPreviewNetworkPolicy.heldConnectionReleaseSeconds - pausedFor
        return remaining > 0 ? remaining : nil
    }

    /// Playback took the connection back (resume, seek): stop reading the origin now.
    func revokeNetwork() {
        reader.setNetworkPermitted(false)
        backgroundTask?.cancel()
        backgroundTask = nil
        backgroundToken &+= 1
        lastDecision = .busy
        publishDiagnostics()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        backgroundTask?.cancel()
        backgroundTask = nil
        backgroundQueue.removeAll()
        reader.setNetworkPermitted(false)
        transport.invalidate()
        memory.removeAll()
        let extractor = self.extractor
        self.extractor = nil
        if let extractor {
            Task { await extractor.shutdown() }
        } else {
            reader.close()
        }
        SeekPreviewDiagnostics.shared.clear()
    }

    // MARK: Private

    private func canDecodeFromNetwork() -> Bool {
        guard decodeDisabledReason == nil, transport.trippedReason == nil,
              networkDecodes < Self.maximumNetworkDecodes else {
            reader.setNetworkPermitted(false)
            return false
        }
        let decision = admission()
        lastDecision = decision
        reader.setNetworkPermitted(decision == .allowed)
        return decision == .allowed
    }

    private func cachedImage(for cell: Int) async -> CGImage? {
        if var entry = memory[cell] {
            useCounter &+= 1
            entry.lastUse = useCounter
            memory[cell] = entry
            return entry.image
        }
        // A still playback already produced inside the cell (passive capture, resident decode).
        if let local = await localFrame(SeekPreviewGrid.center(of: cell), SeekPreviewGrid.cellSeconds / 2) {
            remember(local, for: cell)
            return local
        }
        let storage = SeekPreviewGrid.storageSeconds(of: cell)
        if let disk = await TrickplayDiskCache.shared.lookup(streamKey: diskKey, seconds: storage, tolerance: 0) {
            guard !isShutDown else { return nil }
            remember(disk, for: cell)
            return disk
        }
        return nil
    }

    private func ensureExtractor() -> FrameExtractor {
        if let extractor { return extractor }
        // Software decode: a still never takes a VideoToolbox session from playback, and a Dolby
        // Vision profile 5 keyframe gets the same reshaping as every other still.
        let created = FrameExtractor(reader: reader, formatHint: nil, allowsHardwareDecode: false)
        extractor = created
        return created
    }

    private func startDecode(cell: Int, duration: Double, background: Bool) -> Task<CGImage?, Never> {
        let extractor = ensureExtractor()
        if inFlight != nil {
            // The new request retires the decode in flight (FrameExtractor cancels its token);
            // ending its network read too lets the new one start without waiting for it.
            reader.cancel()
        }
        decodeSequence &+= 1
        let id = decodeSequence
        networkDecodes += 1
        let center = SeekPreviewGrid.center(of: cell)
        let storage = SeekPreviewGrid.storageSeconds(of: cell)
        let key = diskKey
        let started = Date()
        let task = Task { @MainActor [weak self] () -> CGImage? in
            let image = await extractor.thumbnail(at: center, maxWidth: Self.width)
            guard let self else { return image }
            let superseded = self.decodeSequence != id
            if self.inFlight?.id == id { self.inFlight = nil }
            guard !self.isShutDown else { return image }
            if let image {
                self.consecutiveDecodeFailures = 0
                self.networkFrames += 1
                self.remember(image, for: cell)
                self.recordDecodeTime(Date().timeIntervalSince(started))
                Task { await TrickplayDiskCache.shared.store(image: image, streamKey: key, seconds: storage) }
                if !background {
                    self.queueNeighbors(of: cell, direction: self.scrubDirection(to: cell), duration: duration)
                }
            } else {
                // A retired decode gets its budget back; a real failure counts toward stopping.
                self.networkDecodes = max(0, self.networkDecodes - 1)
                if !superseded, self.lastDecision == .allowed, self.transport.trippedReason == nil {
                    self.consecutiveDecodeFailures += 1
                    if self.consecutiveDecodeFailures >= Self.consecutiveDecodeFailureLimit {
                        self.decodeDisabledReason = "decode failed"
                    }
                }
            }
            self.publishDiagnostics()
            return image
        }
        inFlight = InFlight(id: id, cell: cell, task: task, background: background)
        publishDiagnostics()
        return task
    }

    private var previousDirectionCell: Int?
    private var direction: Double = 1

    private func scrubDirection(to cell: Int) -> Double {
        if let previous = previousDirectionCell, previous != cell {
            direction = cell > previous ? 1 : -1
        }
        previousDirectionCell = cell
        return direction
    }

    private func remember(_ image: CGImage, for cell: Int) {
        useCounter &+= 1
        memory[cell] = MemoryEntry(image: image, lastUse: useCounter)
        while memory.count > Self.memoryCells,
              let victim = memory.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            memory.removeValue(forKey: victim)
        }
    }

    private func recordDecodeTime(_ seconds: TimeInterval) {
        recentDecodeSeconds.append(seconds)
        if recentDecodeSeconds.count > 8 { recentDecodeSeconds.removeFirst(recentDecodeSeconds.count - 8) }
    }

    private func queueNeighbors(of cell: Int, direction: Double, duration: Double) {
        guard let last = SeekPreviewGrid.lastCell(duration: duration) else { return }
        let neighbors = SeekPreviewGrid.neighbors(of: cell, direction: direction, count: Self.neighborCount, lastCell: last)
        for neighbor in neighbors.reversed() where memory[neighbor] == nil {
            backgroundQueue.removeAll { $0 == neighbor }
            backgroundQueue.insert(neighbor, at: 0)
        }
        if backgroundQueue.count > 32 { backgroundQueue.removeLast(backgroundQueue.count - 32) }
        runBackgroundIfNeeded(duration: duration)
    }

    private func queueStoryboard(duration: Double) {
        guard !storyboardQueued else { return }
        storyboardQueued = true
        for cell in SeekPreviewGrid.storyboardCells(duration: duration, count: Self.storyboardFrames)
            where memory[cell] == nil && !backgroundQueue.contains(cell) {
            backgroundQueue.append(cell)
        }
        runBackgroundIfNeeded(duration: duration)
    }

    private func runBackgroundIfNeeded(duration: Double) {
        guard backgroundTask == nil, !backgroundQueue.isEmpty, !isShutDown else { return }
        backgroundToken &+= 1
        let token = backgroundToken
        backgroundTask = Task { @MainActor [weak self] in
            await self?.drainBackground(duration: duration)
            // A revoke may have replaced this worker; only the current one clears the handle.
            if let self, self.backgroundToken == token { self.backgroundTask = nil }
        }
    }

    private func drainBackground(duration: Double) async {
        while !isShutDown, !backgroundQueue.isEmpty {
            try? await Task.sleep(nanoseconds: Self.backgroundSpacingNanoseconds)
            guard !isShutDown, !Task.isCancelled else { return }
            // A foreground decode owns the decoder; wait for it.
            if inFlight != nil { continue }
            let cell = backgroundQueue.removeFirst()
            if await cachedImage(for: cell) != nil { continue }
            guard !isShutDown, !Task.isCancelled else { return }
            guard inFlight == nil else {
                backgroundQueue.insert(cell, at: 0)
                continue
            }
            guard canDecodeFromNetwork() else {
                backgroundQueue.insert(cell, at: 0)
                publishDiagnostics()
                return
            }
            let image = await startDecode(cell: cell, duration: duration, background: true).value
            if image == nil, !isShutDown, decodeDisabledReason == nil, transport.trippedReason == nil,
               !backgroundQueue.contains(cell) {
                // Retired by a foreground request: try again after the queue moves on.
                backgroundQueue.append(cell)
            }
        }
    }

    private func publishDiagnostics() {
        guard !isShutDown else { return }
        let stats = transport.stats
        var parts: [String] = []
        if let reason = stats.trippedReason ?? decodeDisabledReason {
            parts.append("stopped (\(reason))")
        } else {
            parts.append(Self.label(for: lastDecision))
        }
        parts.append("\(networkFrames) frames")
        parts.append("\(stats.requests) req")
        parts.append(String(format: "%.1f MB", Double(stats.bytes) / 1_048_576))
        if !recentDecodeSeconds.isEmpty {
            let mean = recentDecodeSeconds.reduce(0, +) / Double(recentDecodeSeconds.count)
            parts.append(String(format: "%.2f s/frame", mean))
        }
        if !backgroundQueue.isEmpty { parts.append("queue \(backgroundQueue.count)") }
        if stats.usesResolvedURL { parts.append("cdn") }
        SeekPreviewDiagnostics.shared.update(parts.joined(separator: " · "))
    }

    private static func label(for decision: SeekPreviewNetworkPolicy.Decision) -> String {
        switch decision {
        case .allowed: return "net on"
        case .playing: return "net off (playing)"
        case .pauseTooRecent: return "net waiting (pause)"
        case .bufferLow: return "net off (buffer)"
        case .throughputLow: return "net off (speed)"
        case .busy: return "net idle"
        }
    }

    static func awaitUnlessCancelled(_ task: Task<CGImage?, Never>) async -> CGImage? {
        let gate = SeekPreviewResumeGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                gate.install(continuation)
                Task { gate.resume(await task.value) }
            }
        } onCancel: {
            gate.resume(nil)
        }
    }
}

/// Owns the lane of the current source session for one playback controller.
@MainActor
final class SeekPreviewLaneHost {
    private var lane: SeekPreviewLane?
    private var laneContextID: UUID?
    private var unavailableContextID: UUID?

    var current: SeekPreviewLane? { lane }

    /// The lane for `context`, created on first use; nil when the source is not one it serves.
    func lane(
        for context: PlaybackThumbnailSourceContext,
        diskStreamKey: String,
        isCurrent: @MainActor () -> Bool,
        admission: @escaping SeekPreviewLane.Admission,
        localFrame: @escaping SeekPreviewLane.LocalFrame
    ) async -> SeekPreviewLane? {
        if let lane, laneContextID == context.contextID, !lane.isShutDown { return lane }
        guard unavailableContextID != context.contextID, let playbackURL = context.playbackURL else { return nil }
        let descriptor = PlaybackThumbnailSourceFallback.isCacheProxyURL(playbackURL)
            ? await PlaybackStreamCacheManager.shared.thumbnailSource(for: playbackURL)
            : nil
        guard isCurrent() else { return nil }
        if let lane, laneContextID == context.contextID, !lane.isShutDown { return lane }
        guard let origin = SeekPreviewNetworkPolicy.previewOrigin(
            playbackURL: playbackURL,
            headerSourceURL: context.headerSourceURL,
            descriptorRemoteURL: descriptor?.remoteURL,
            isLive: context.isLive,
            isKnownHLS: context.isKnownHLS
        ) else {
            unavailableContextID = context.contextID
            return nil
        }
        lane?.shutdown()
        let created = SeekPreviewLane(
            originURL: origin,
            headers: descriptor?.originalHeaders ?? context.requestHeaders,
            diskKey: SeekPreviewLane.diskKey(for: diskStreamKey),
            admission: admission,
            localFrame: localFrame)
        lane = created
        laneContextID = context.contextID
        return created
    }

    /// Whether the lane may serve `context` (without creating it); a cache proxy counts, its
    /// remote origin is resolved when the lane is created.
    static func mayServe(_ context: PlaybackThumbnailSourceContext?) -> Bool {
        guard let context, let playbackURL = context.playbackURL, !context.isLive, !context.isKnownHLS else { return false }
        if PlaybackThumbnailSourceFallback.isCacheProxyURL(playbackURL) { return true }
        return SeekPreviewNetworkPolicy.previewOrigin(
            playbackURL: playbackURL,
            headerSourceURL: context.headerSourceURL,
            descriptorRemoteURL: nil,
            isLive: context.isLive,
            isKnownHLS: context.isKnownHLS) != nil
    }

    func revokeNetwork() {
        lane?.revokeNetwork()
    }

    func reset() {
        lane?.shutdown()
        lane = nil
        laneContextID = nil
        unavailableContextID = nil
    }
}
