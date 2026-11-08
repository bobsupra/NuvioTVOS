import Foundation

/// Seekable `IOReader` over a remote disc image (ISO 9660 / UDF / Blu-ray BDMV) served over HTTP(S)
/// with byte-range support. The local case has `FileIOReader`; this is its remote twin, so
/// `DiscReader.wrap` can probe and read a remote `.iso` exactly the way it reads a local one (the
/// disc layer issues random-access seeks for the UDF anchor and directory structure, then reads the
/// selected title's m2ts/VOB extents). Without this a remote `.iso` is handed straight to
/// libavformat, which fails to probe it (a disc image is a filesystem, not a media container) (#64).
///
/// Reads are served from an adaptive read-ahead buffer plus a small per-reader LRU of prior base-size
/// windows. The read-ahead window starts at `baseChunkSize` (so scattered, kilobyte-sized
/// disc-structure reads at open do not each pull a megabyte) and doubles up to `maxChunkSize` while
/// reads stay sequential (so steady playback of the title's extents costs few requests); any
/// non-contiguous read resets it. The bounded LRU avoids refetching small windows when UDF metadata
/// alternates between nearby regions. Each range request retries with backoff so a transient
/// network blip does not end playback. The server
/// MUST honor range requests (any static file host does); if it does not, `init` returns nil after a
/// clear log and `open` throws `AVIOReaderError.originIgnoresRange`, and the response is hung up on at
/// its head, so a 40 GB image answered with a 200 is never downloaded to be rejected (audit NET-102).
///
/// A source the host warmed with `AetherEngine.prewarm` (#551) is read out of those bytes first
/// (#647): the warm has already stated the size and proven range support, so the reader neither
/// probes nor refetches the head, and its first request starts at the warm frontier.
final class HTTPDiscIOReader: IOReader, SourceTransferCounting, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let rangeCompletionGrace: TimeInterval
    private let baseChunkSize: Int
    private let maxChunkSize: Int
    private let maxRetries: Int
    private let totalSize: Int64
    /// Progressive response delivery is enabled only for the ISO disc opener. Other HTTP range
    /// consumers keep the full-window-before-return behavior they already use.
    private let allowsProgressiveReads: Bool
    /// Warmed bytes (#647), read before the network. Immutable, so a fork shares them without a copy.
    private let residentSpans: [ResidentSpan]

    /// Guards cursor, active/cached buffers, and the selected progressive request. Never held while
    /// waiting for network bytes, so seek/cancel can interrupt an in-flight read.
    private let lock = NSLock()
    /// IOReader callers normally serialize reads, but keeping that invariant here lets seek and
    /// cancel use `lock` while a read waits on its range request.
    private let readLock = NSLock()
    private var position: Int64 = 0
    private var cursorGeneration: UInt64 = 0
    private var bufferStart: Int64 = -1
    private var buffer = Data()
    private struct CachedWindow {
        let start: Int64
        let data: Data

        var end: Int64 { start + Int64(data.count) }
        func covers(_ position: Int64) -> Bool { position >= start && position < end }
    }
    /// Most recently used first. These are prior active windows only; large adaptive windows are
    /// never retained, and the three-entry limit bounds extra storage to at most 768 KiB.
    private var cachedWindows: [CachedWindow] = []
    private let maxCachedWindows = 3
    /// Give a normal exact-length HTTP response a brief chance to complete and keep its connection
    /// reusable before a following range forces URLSession to cancel it.
    private static let defaultRangeCompletionGrace: TimeInterval = 0.1
    /// End offset of the last buffer refill; a read starting here continues sequentially.
    private var lastFetchEnd: Int64 = -1
    /// Current adaptive read-ahead window; grows on sequential refills, resets on a seek.
    private var currentChunkSize: Int
    /// A single progressive adaptive window is active at a time. Its body stays in one bounded Data
    /// allocation and is promoted into `buffer` after its task has finished.
    private var activeFetch: ProgressiveRangeFetch?
    private var cancelled = false
    /// This reader's own share of `lifetimeFetchedBytes`: each validated body byte received,
    /// including bytes retained across an interrupted attempt before retry.
    private let transferLock = NSLock()
    private var transferredBytes: Int64 = 0

    var sourceBytesFetched: Int64 {
        transferLock.lock(); defer { transferLock.unlock() }
        return transferredBytes
    }

    var hasRangeCompletionWaiterForTesting: Bool {
        lock.lock(); let fetch = activeFetch; lock.unlock()
        return fetch?.hasCompletionWaiterForTesting ?? false
    }

    /// Probes total size and range support with one (retried) `bytes=0-0` request, unless
    /// `prewarmed` has already stated both. Returns nil if the source is unreachable or answers `200`
    /// (full body, no range support); logs which. `open` tells the two apart.
    convenience init?(url: URL,
                      extraHeaders: [String: String] = [:],
                      baseChunkSize: Int = 256 * 1024,
                      maxChunkSize: Int = 8 * 1024 * 1024,
                      maxRetries: Int = 3,
                      requestTimeout: TimeInterval = 30,
                      sessionConfiguration: URLSessionConfiguration? = nil,
                      prewarmed: PrewarmedSource? = nil,
                      knownSize: Int64? = nil,
                      progressiveReads: Bool = false,
                      rangeCompletionGraceForTesting: TimeInterval? = nil) {
        let session = Self.makeSession(sessionConfiguration)
        guard case .size(let size) = Self.resolveSize(
            url: url, extraHeaders: extraHeaders, session: session, requestTimeout: requestTimeout,
            maxRetries: maxRetries, knownSize: knownSize ?? prewarmed?.contentLength) else {
            session.invalidateAndCancel()
            return nil
        }
        self.init(url: url, extraHeaders: extraHeaders, baseChunkSize: baseChunkSize,
                  maxChunkSize: maxChunkSize, maxRetries: maxRetries, requestTimeout: requestTimeout,
                  session: session, totalSize: size,
                  residentSpans: prewarmed.map { [$0.head] + ($0.tail.map { [$0] } ?? []) } ?? [],
                  allowsProgressiveReads: progressiveReads,
                  rangeCompletionGrace: max(0, rangeCompletionGraceForTesting
                                            ?? Self.defaultRangeCompletionGrace))
    }

    /// `init?` for a caller that has to say why a disc image cannot be read: an origin that answers the
    /// range probe with a 200 cannot address bytes, which is a different failure from an unreachable
    /// one, and a disc image is a filesystem that no reader can walk without ranges (audit NET-102).
    /// nil still means unreachable, and the caller falls back to the plain streaming path.
    static func open(url: URL,
                     extraHeaders: [String: String] = [:],
                     baseChunkSize: Int = 256 * 1024,
                     maxChunkSize: Int = 8 * 1024 * 1024,
                     maxRetries: Int = 3,
                     requestTimeout: TimeInterval = 30,
                     sessionConfiguration: URLSessionConfiguration? = nil,
                     prewarmed: PrewarmedSource? = nil) throws -> HTTPDiscIOReader? {
        let session = makeSession(sessionConfiguration)
        switch resolveSize(url: url, extraHeaders: extraHeaders, session: session,
                           requestTimeout: requestTimeout, maxRetries: maxRetries,
                           knownSize: prewarmed?.contentLength) {
        case .size(let size):
            return HTTPDiscIOReader(
                url: url, extraHeaders: extraHeaders, baseChunkSize: baseChunkSize,
                maxChunkSize: maxChunkSize, maxRetries: maxRetries, requestTimeout: requestTimeout,
                session: session, totalSize: size,
                residentSpans: prewarmed.map { [$0.head] + ($0.tail.map { [$0] } ?? []) } ?? [],
                allowsProgressiveReads: true,
                rangeCompletionGrace: defaultRangeCompletionGrace)
        case .ignoresRange:
            session.invalidateAndCancel()
            throw AVIOReaderError.originIgnoresRange
        case .unreachable:
            session.invalidateAndCancel()
            return nil
        }
    }

    private init(url: URL,
                 extraHeaders: [String: String],
                 baseChunkSize: Int,
                 maxChunkSize: Int,
                 maxRetries: Int,
                 requestTimeout: TimeInterval,
                 session: URLSession,
                 totalSize: Int64,
                 residentSpans: [ResidentSpan],
                 allowsProgressiveReads: Bool,
                 rangeCompletionGrace: TimeInterval) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.baseChunkSize = max(64 * 1024, baseChunkSize)
        self.maxChunkSize = max(max(64 * 1024, baseChunkSize), maxChunkSize)
        self.currentChunkSize = max(64 * 1024, baseChunkSize)
        self.maxRetries = max(0, maxRetries)
        self.requestTimeout = requestTimeout
        self.session = session
        self.residentSpans = residentSpans.filter { !$0.isEmpty }
        self.totalSize = totalSize
        self.allowsProgressiveReads = allowsProgressiveReads
        self.rangeCompletionGrace = rangeCompletionGrace
    }

    private static func makeSession(_ sessionConfiguration: URLSessionConfiguration?) -> URLSession {
        let config = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return c
        }()
        return URLSession(configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    /// `knownSize` skips the range probe. Only a source that has already answered a range request
    /// with its total may pass it: the warm, or the reader a fork is made from. The one exception is a
    /// small file of a disc folder, read whole, where a range-blind origin costs nothing.
    private static func resolveSize(url: URL, extraHeaders: [String: String], session: URLSession,
                                    requestTimeout: TimeInterval, maxRetries: Int,
                                    knownSize: Int64?) -> SizeProbe {
        if let knownSize, knownSize > 0 { return .size(knownSize) }
        return probeSize(url: url, extraHeaders: extraHeaders, session: session,
                         timeout: requestTimeout, maxRetries: max(0, maxRetries))
    }

    /// #647: take what a host warmed for this URL, under the rule `AVIOReader` adopts by (#551).
    ///
    /// A take, like every adoption: the reader holds the bytes from here on. A caller whose source
    /// turns out not to be a disc puts them back (`SourcePrewarmStore.store`) so the streaming
    /// reader it falls back to adopts them instead.
    static func takePrewarm(for url: URL, extraHeaders: [String: String],
                            store: SourcePrewarmStore = .shared) -> PrewarmedSource? {
        guard let warm = store.take(for: url) else { return nil }
        guard warm.head.start == 0, !warm.head.isEmpty, warm.contentLength > 0 else { return nil }
        guard warm.requestHeaders == extraHeaders else {
            EngineLog.emit(
                "[HTTPDiscIOReader] \(url.lastPathComponent): a warm exists for this URL but was "
                + "fetched with different headers; opening cold (#647)", category: .demux)
            return nil
        }
        EngineLog.emit(
            "[HTTPDiscIOReader] \(url.lastPathComponent): adopted a prewarmed source: "
            + "head=\(warm.head.data.count)B tail=\(warm.tail?.data.count ?? 0)B of "
            + "\(warm.contentLength)B (#647)", category: .demux)
        return warm
    }

    // MARK: - Pure helpers

    /// Inclusive byte-range header for a half-open `[offset, offset+length)` window.
    static func rangeHeader(offset: Int64, length: Int) -> String {
        "bytes=\(offset)-\(offset + Int64(length) - 1)"
    }

    /// Total size from a `Content-Range` value (`bytes 0-0/12345` -> 12345). Nil for `*` or junk.
    static func parseContentRangeTotal(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard total != "*" else { return nil }
        return Int64(total)
    }

    /// Start offset from a `Content-Range` value (`bytes 100-200/12345` -> 100). Nil for junk.
    static func parseContentRangeStart(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes ") else { return nil }
        let rest = trimmed.dropFirst("bytes ".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash])
    }

    /// Next adaptive window: `base` when `position` is not the sequential continuation of the last
    /// refill, otherwise the previous window doubled and capped at `maxChunkSize`.
    static func nextChunkSize(position: Int64, lastFetchEnd: Int64, current: Int,
                              base: Int, maxChunk: Int) -> Int {
        guard position == lastFetchEnd, lastFetchEnd >= 0 else { return base }
        return min(current * 2, maxChunk)
    }

    private var smallWindowLimit: Int { min(baseChunkSize, 256 * 1024) }

    private func bufferContains(_ offset: Int64) -> Bool {
        bufferStart >= 0 && offset >= bufferStart
            && offset < bufferStart + Int64(buffer.count)
    }

    /// Called with `lock` held. Once the URL task has completed, its Data can be shared with the
    /// active window without copying and the request slot is available for the next range.
    private func promoteFinishedFetch() {
        guard let fetch = activeFetch else { return }
        let snapshot = fetch.finishedSnapshot()
        guard snapshot.finished, let data = snapshot.data else { return }
        if !data.isEmpty && (allowsProgressiveReads || snapshot.successful) {
            parkActiveBuffer(excludingStart: fetch.start)
            cachedWindows.removeAll { $0.start == fetch.start }
            bufferStart = fetch.start
            buffer = data
            lastFetchEnd = fetch.start + Int64(data.count)
        }
        activeFetch = nil
    }

    /// Called with `lock` held.
    private func copyFromBuffer(_ out: UnsafeMutablePointer<UInt8>, maximum: Int) -> Int {
        let offset = Int(position - bufferStart)
        let count = min(maximum, buffer.count - offset, Int(totalSize - position))
        guard count > 0 else { return 0 }
        buffer.withUnsafeBytes { src in
            out.update(from: src.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset),
                       count: count)
        }
        position += Int64(count)
        return count
    }

    /// Park the active window after a replacement is ready. Excluding the replacement's start
    /// avoids retaining a stale, overlapping version of the same range.
    private func parkActiveBuffer(excludingStart: Int64) {
        guard bufferStart >= 0, !buffer.isEmpty,
              buffer.count <= smallWindowLimit, bufferStart != excludingStart else { return }
        cachedWindows.removeAll { $0.start == bufferStart }
        cachedWindows.insert(CachedWindow(start: bufferStart, data: buffer), at: 0)
        if cachedWindows.count > maxCachedWindows {
            cachedWindows.removeLast(cachedWindows.count - maxCachedWindows)
        }
    }

    // MARK: - IOReader

    func read(_ outBuffer: UnsafeMutablePointer<UInt8>?, size n: Int32) -> Int32 {
        guard let out = outBuffer, n > 0 else { return -1 }
        readLock.lock(); defer { readLock.unlock() }

        while true {
            lock.lock()
            promoteFinishedFetch()
            if position >= totalSize {
                lock.unlock()
                return 0
            }

            if let span = residentSpans.first(where: { $0.covers(position) }) {
                let spanOffset = Int(position - span.start)
                let toCopy = min(Int(n), span.data.count - spanOffset, Int(totalSize - position))
                span.data.withUnsafeBytes { src in
                    out.update(from: src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        .advanced(by: spanOffset), count: toCopy)
                }
                position += Int64(toCopy)
                // Reading on past the span is the sequential continuation, so the window grows there.
                lastFetchEnd = position
                lock.unlock()
                return Int32(toCopy)
            }

            if bufferContains(position) {
                let count = copyFromBuffer(out, maximum: Int(n))
                lock.unlock()
                return Int32(count)
            }

            if let cacheIndex = cachedWindows.firstIndex(where: { $0.covers(position) }) {
                let hit = cachedWindows.remove(at: cacheIndex)
                let continuesAtFrontier = position == lastFetchEnd
                parkActiveBuffer(excludingStart: hit.start)
                bufferStart = hit.start
                buffer = hit.data
                if !continuesAtFrontier { currentChunkSize = baseChunkSize }
                // The cache window is now the active window. Its frontier remains eligible for
                // ordinary sequential growth after the cached bytes have been consumed.
                lastFetchEnd = hit.end
                let count = copyFromBuffer(out, maximum: Int(n))
                lock.unlock()
                return Int32(count)
            }

            // Cancellation preserves already resident, active-buffer, and cached bytes, matching
            // the reader's prior behavior. It only rejects work that would need another network read.
            if cancelled {
                if allowsProgressiveReads, let fetch = activeFetch, fetch.covers(position) {
                    let copied = fetch.copyAvailable(at: position, maximum: Int(n), to: out)
                    if copied > 0 {
                        parkActiveBuffer(excludingStart: fetch.start)
                        bufferStart = -1
                        buffer = Data()
                        position += Int64(copied)
                        lock.unlock()
                        return Int32(copied)
                    }
                }
                lock.unlock()
                return -1
            }

            let generation = cursorGeneration
            let requestedPosition = position
            let fetch: ProgressiveRangeFetch
            var shouldStart = false
            if let current = activeFetch {
                if current.covers(requestedPosition) && !current.isCancelled {
                    fetch = current
                } else {
                    // A cancelled or out-of-window task must finish before its replacement starts.
                    // If it already delivered the exact bounded window, let URLSession finish it
                    // naturally so a normal range can keep the connection alive.
                    fetch = current
                    let hasCompleteRange = current.hasCompleteRangeBytes
                    let retirementWakeGeneration = current.currentWakeGeneration
                    if !hasCompleteRange { current.cancel() }
                    lock.unlock()
                    var taskFinished: Bool
                    if hasCompleteRange {
                        taskFinished = current.waitUntilFinished(
                            timeout: rangeCompletionGrace, wakeGeneration: retirementWakeGeneration)
                        if !taskFinished {
                            lock.lock()
                            let stillObsolete = activeFetch === current && !current.covers(position)
                                && !residentSpans.contains { $0.covers(position) }
                                && !bufferContains(position)
                                && !cachedWindows.contains { $0.covers(position) }
                            if stillObsolete { current.cancel() }
                            lock.unlock()
                            if stillObsolete {
                                current.waitUntilFinished()
                                taskFinished = true
                            }
                        }
                    } else {
                        current.waitUntilFinished()
                        taskFinished = true
                    }
                    lock.lock()
                    if activeFetch === current && taskFinished {
                        promoteFinishedFetch()
                        if activeFetch === current { activeFetch = nil }
                    }
                    let cursorStillCurrent = cursorGeneration == generation && position == requestedPosition
                    lock.unlock()
                    if !cursorStillCurrent { return -1 }
                    continue
                }
            } else {
                currentChunkSize = Self.nextChunkSize(
                    position: position, lastFetchEnd: lastFetchEnd,
                    current: currentChunkSize, base: baseChunkSize, maxChunk: maxChunkSize)
                // Stop at the next warmed span: its bytes are already here.
                let limit = residentSpans.lazy.map(\.start).filter { $0 > self.position }.min() ?? totalSize
                let want = Int(min(Int64(currentChunkSize), limit - position))
                guard want > 0 else {
                    lock.unlock()
                    return -1
                }
                fetch = ProgressiveRangeFetch(
                    url: url, extraHeaders: extraHeaders, session: session,
                    timeout: requestTimeout, offset: position, length: want,
                    maxRetries: maxRetries,
                    retriesPartialBodies: allowsProgressiveReads,
                    onBytesReceived: { [weak self] count in
                        guard let self else { return }
                        self.transferLock.lock()
                        self.transferredBytes &+= Int64(count)
                        self.transferLock.unlock()
                        Self.recordFetched(bytes: count)
                    })
                activeFetch = fetch
                shouldStart = true
            }
            // Capture while the cursor lock is still held: seek changes both cursor and wake
            // generations under that same lock, so an older read cannot adopt a newer token.
            let fetchWakeGeneration = fetch.currentWakeGeneration
            lock.unlock()

            if shouldStart { fetch.begin() }
            if allowsProgressiveReads {
                let minimumCount = fetch.readableCapacity(
                    at: requestedPosition,
                    maximum: min(Int(n), Int(totalSize - requestedPosition)))
                _ = fetch.waitForData(at: requestedPosition, minimumCount: minimumCount,
                                      wakeGeneration: fetchWakeGeneration)
            } else {
                _ = fetch.waitForCompletion(wakeGeneration: fetchWakeGeneration)
            }

            lock.lock()
            guard cursorGeneration == generation, position == requestedPosition,
                  activeFetch === fetch else {
                lock.unlock()
                return -1
            }
            let snapshot = fetch.finishedSnapshot()
            if !allowsProgressiveReads && !snapshot.successful {
                if snapshot.finished { activeFetch = nil }
                lock.unlock()
                return -1
            }
            let copied = fetch.copyAvailable(at: requestedPosition, maximum: Int(n), to: out)
            if copied > 0 {
                // Keep the former active window only after this range has passed response validation
                // and supplied readable bytes. Rejected or empty responses leave it untouched.
                parkActiveBuffer(excludingStart: fetch.start)
                bufferStart = -1
                buffer = Data()
                position += Int64(copied)
                promoteFinishedFetch()
                lock.unlock()
                return Int32(copied)
            }

            // A terminal short body is retained, then a later read resumes at its first missing
            // byte. A no-data failure remains an error for this call.
            if snapshot.finished {
                let cleanShortBody = snapshot.successful && snapshot.data?.isEmpty == false
                promoteFinishedFetch()
                if allowsProgressiveReads, cleanShortBody {
                    // This read was already parked at the missing frontier when a clean short 206
                    // finished. Continue there now that its successful prefix is available.
                    lock.unlock()
                    continue
                }
            }
            lock.unlock()
            return -1
        }
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return totalSize }  // AVSEEK_SIZE
        lock.lock()
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = totalSize + offset
        default:
            lock.unlock()
            return -1
        }
        guard target >= 0 else {
            lock.unlock()
            return -1
        }
        let isInResident = residentSpans.contains { $0.covers(target) }
        let isInBuffer = bufferContains(target)
        let isInCache = cachedWindows.contains { $0.covers(target) }
        let cursorChanged = target != position
        var retirementWakeGeneration: UInt64?
        let fetchToRetire = activeFetch.flatMap { fetch in
            fetch.covers(target) || isInResident || isInBuffer || isInCache ? nil : fetch
        }
        let fetchToCancel = fetchToRetire.flatMap { $0.hasCompleteRangeBytes ? nil : $0 }
        if cursorChanged {
            position = target
            cursorGeneration &+= 1
            // Publish the wake generation under the same cursor lock that read captures it with.
            // An in-range seek preserves the useful task while releasing any waiter on the old offset.
            if let fetchToCancel {
                fetchToCancel.cancel()
            } else {
                activeFetch?.wakeWaiters()
                if fetchToRetire != nil {
                    retirementWakeGeneration = fetchToRetire?.currentWakeGeneration
                }
            }
        }
        lock.unlock()
        if cursorChanged, let fetchToRetire {
            if fetchToCancel != nil {
                fetchToRetire.waitUntilFinished()
            } else {
                let completedPromptly = fetchToRetire.waitUntilFinished(
                    timeout: rangeCompletionGrace,
                    wakeGeneration: retirementWakeGeneration)
                if !completedPromptly {
                    lock.lock()
                    let stillObsolete = activeFetch === fetchToRetire
                        && !fetchToRetire.covers(position)
                        && !residentSpans.contains { $0.covers(position) }
                        && !bufferContains(position)
                        && !cachedWindows.contains { $0.covers(position) }
                    if stillObsolete { fetchToRetire.cancel() }
                    lock.unlock()
                    if stillObsolete { fetchToRetire.waitUntilFinished() }
                }
            }
        }
        return target
    }

    func close() {
        lock.lock()
        cancelled = true
        let fetch = activeFetch
        lock.unlock()
        fetch?.cancel()
        // `startAttempt` may have dropped its condition lock while constructing a URLSession task.
        // Let it observe cancellation and finish task creation before invalidating the session.
        fetch?.waitForAttemptStartup()
        session.getAllTasks { $0.forEach { $0.cancel() } }
        session.invalidateAndCancel()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let fetch = activeFetch
        lock.unlock()
        fetch?.cancel()
        session.getAllTasks { $0.forEach { $0.cancel() } }
    }

    func makeIndependentReader() -> IOReader? {
        HTTPDiscIOReader(url: url, extraHeaders: extraHeaders,
                         baseChunkSize: baseChunkSize, maxChunkSize: maxChunkSize,
                         maxRetries: maxRetries, requestTimeout: requestTimeout,
                         session: Self.makeSession(nil),
                         totalSize: totalSize, residentSpans: residentSpans,
                         allowsProgressiveReads: allowsProgressiveReads,
                         rangeCompletionGrace: rangeCompletionGrace)
    }

    // MARK: - HTTP

    /// One range GET retried up to `maxRetries` times with linear backoff; aborts early on cancel.
    ///
    /// Requires a 206 whose `Content-Range` start matches `offset` exactly: a proxy that answers a
    /// range request with a full 200 (cache miss, range coalescing, a Range-stripping origin) or a
    /// 206 that starts somewhere else places its body at `position` regardless, corrupting the disc
    /// structure or media stream read through it (audit NET-9). The body is also trimmed to `length`
    /// in case the server sent more than asked.
    private enum SizeProbe {
        case size(Int64)
        /// The origin answered the range probe with a 200 that is not the byte asked for.
        case ignoresRange
        case unreachable
    }

    private static func probeSize(url: URL, extraHeaders: [String: String], session: URLSession,
                                  timeout: TimeInterval, maxRetries: Int) -> SizeProbe {
        var attempt = 0
        while true {
            let r = rangeGet(url: url, extraHeaders: extraHeaders, session: session,
                             timeout: timeout, offset: 0, length: 1)
            if let r = r, r.status == 206, let cr = r.contentRange,
               let total = parseContentRangeTotal(cr) {
                return .size(total)
            }
            if let r = r, r.status == 200 {
                EngineLog.emit(
                    "[HTTPDiscIOReader] \(url.lastPathComponent): server answered 200 to a range "
                    + "probe (hung up at the head); remote disc images need HTTP byte-range support.",
                    category: .demux)
                return r.answer == .ignored ? .ignoresRange : .unreachable
            }
            attempt += 1
            if attempt > maxRetries {
                EngineLog.emit(
                    "[HTTPDiscIOReader] \(url.lastPathComponent): range probe failed after "
                    + "\(attempt) attempt(s) (status=\(r.map { String($0.status) } ?? "no response")). "
                    + "Falling back to the streaming path.",
                    category: .demux)
                return .unreachable
            }
            Thread.sleep(forTimeInterval: min(0.25 * Double(attempt), 1.0))
        }
    }

    private struct RangeResponse {
        let status: Int
        let contentRange: String?
        let body: Data
        let answer: AVIOReader.RangeAnswer
    }

    /// Synchronous one-byte size probe. Adaptive data windows use `ProgressiveRangeFetch` below so
    /// validated bytes can be returned while the request continues. The short-lived autorelease
    /// pool also keeps this Foundation bridge off the caller's long-lived demux thread.
    private static func rangeGet(url: URL, extraHeaders: [String: String], session: URLSession,
                                 timeout: TimeInterval, offset: Int64, length: Int) -> RangeResponse? {
        autoreleasepool {
            var req = URLRequest(engineURL: url, timeoutInterval: timeout)
            req.httpMethod = "GET"
            req.setValue(rangeHeader(offset: offset, length: length), forHTTPHeaderField: "Range")
            for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

            let delegate = RangeFetchDelegate(offset: offset, length: length)
            let sem = DispatchSemaphore(value: 0)
            delegate.onCompletion = { sem.signal() }
            let task = session.dataTask(with: req)
            task.delegate = delegate
            task.resume()
            if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
                task.cancel()
                return nil
            }
            guard let http = delegate.response else { return nil }
            let body = delegate.body
            Self.recordFetched(bytes: body.count)
            return RangeResponse(status: http.statusCode,
                                 contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                 body: body, answer: delegate.answer)
        }
    }

    // MARK: - Diagnostics

    /// Lifetime bytes pulled by every live `HTTPDiscIOReader` of this session, for the memprobe.
    /// The disc pull path had no byte counter at all (`avioFetchedMB` covers the AVIOReader path
    /// only), so a report on this path could show every engine-tracked pool flat while the reader
    /// forks pulled tens of MB/s, which is how #243 had to be argued from arithmetic instead of a
    /// counter. Reset per session by the memory probe.
    private static let fetchedLock = NSLock()
    nonisolated(unsafe) private static var fetchedBytesTotal: Int64 = 0
    nonisolated(unsafe) private static var fetchedResetCount: Int = 0

    private static func recordFetched(bytes: Int) {
        guard bytes > 0 else { return }
        fetchedLock.lock()
        fetchedBytesTotal &+= Int64(bytes)
        fetchedLock.unlock()
    }

    static var lifetimeFetchedBytes: Int64 {
        fetchedLock.lock(); defer { fetchedLock.unlock() }
        return fetchedBytesTotal
    }

    /// Bumped by every reset, so a reader of `lifetimeFetchedBytes` deltas can tell that a session
    /// start in between (`startMemoryProbe`) zeroed the tally under it.
    static var lifetimeFetchedResetCount: Int {
        fetchedLock.lock(); defer { fetchedLock.unlock() }
        return fetchedResetCount
    }

    static func resetLifetimeFetchedBytes() {
        fetchedLock.lock()
        fetchedBytesTotal = 0
        fetchedResetCount &+= 1
        fetchedLock.unlock()
    }
}

/// One adaptive range window, filled incrementally by a sequence of strictly single-flight HTTP
/// requests. At every point its storage is capped at the requested window length.
private final class ProgressiveRangeFetch: @unchecked Sendable {
    let start: Int64
    private let length: Int
    private let url: URL
    private let extraHeaders: [String: String]
    private let session: URLSession
    private let timeout: TimeInterval
    private let maxRetries: Int
    /// Legacy range callers accept a nonempty short body as soon as its task ends. The ISO path
    /// alone resumes a failed body from its first missing byte.
    private let retriesPartialBodies: Bool
    private let onBytesReceived: (Int) -> Void

    private let condition = NSCondition()
    private var body = Data()
    private var task: URLSessionDataTask?
    private var attemptDelegate: ProgressiveRangeAttemptDelegate?
    private var startingAttempt = false
    private var attemptID = 0
    private var attemptAccepted = false
    private var attemptOverWide = false
    private var cancelled = false
    private var finished = false
    private var lastAttemptErrored = false
    private var wakeGeneration: UInt64 = 0
    private var waitingForTaskCompletion = false

    init(url: URL, extraHeaders: [String: String], session: URLSession, timeout: TimeInterval,
         offset: Int64, length: Int, maxRetries: Int, retriesPartialBodies: Bool,
         onBytesReceived: @escaping (Int) -> Void) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.session = session
        self.timeout = timeout
        self.start = offset
        self.length = length
        self.maxRetries = max(0, maxRetries)
        self.retriesPartialBodies = retriesPartialBodies
        self.onBytesReceived = onBytesReceived
    }

    var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    func covers(_ offset: Int64) -> Bool {
        offset >= start && offset < start + Int64(length)
    }

    var hasCompleteRangeBytes: Bool {
        condition.lock(); defer { condition.unlock() }
        return body.count >= length
    }

    fileprivate var hasCompletionWaiterForTesting: Bool {
        condition.lock(); defer { condition.unlock() }
        return waitingForTaskCompletion
    }

    var currentWakeGeneration: UInt64 {
        condition.lock(); defer { condition.unlock() }
        return wakeGeneration
    }

    func readableCapacity(at absoluteOffset: Int64, maximum: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        let relative = Int(absoluteOffset - start)
        guard relative >= 0, relative < length else { return 0 }
        return min(maximum, length - relative)
    }

    func wakeWaiters() {
        condition.lock()
        wakeGeneration &+= 1
        condition.broadcast()
        condition.unlock()
    }

    func begin() { startAttempt() }

    /// Waits for the caller's requested bytes (avoids handing short signature reads to disc sniffers),
    /// unless the request completes/fails first. A cursor change interrupts a waiter without
    /// cancelling an otherwise useful in-range download.
    func waitForData(at absoluteOffset: Int64, minimumCount: Int, wakeGeneration expectedWake: UInt64) -> Bool {
        wait(at: absoluteOffset, minimumCount: minimumCount, untilCompletion: false,
             wakeGeneration: expectedWake)
    }

    func waitForCompletion(wakeGeneration expectedWake: UInt64) -> Bool {
        wait(at: start, minimumCount: 0, untilCompletion: true, wakeGeneration: expectedWake)
    }

    private func wait(at absoluteOffset: Int64, minimumCount: Int, untilCompletion: Bool,
                      wakeGeneration expectedWake: UInt64) -> Bool {
        let relativeOffset = Int(absoluteOffset - start)
        condition.lock()
        while true {
            if cancelled || wakeGeneration != expectedWake {
                condition.unlock()
                return false
            }
            let available = relativeOffset >= 0 && relativeOffset < body.count
                ? body.count - relativeOffset : 0
            if untilCompletion, finished {
                condition.unlock()
                return true
            }
            if !untilCompletion, available >= minimumCount {
                condition.unlock()
                return true
            }
            if finished {
                let hasBytes = available > 0
                condition.unlock()
                return hasBytes
            }
            if task != nil || startingAttempt {
                condition.wait()
                continue
            }
            guard attemptID <= maxRetries else {
                finished = true
                condition.broadcast()
                condition.unlock()
                return false
            }

            // The previous task's completion callback has run before this retry is created. Keep
            // its body and resume exactly at the first byte not yet received.
            let retryNumber = attemptID
            let retryDeadline = Date(timeIntervalSinceNow: min(0.25 * Double(retryNumber), 1.0))
            while !cancelled, wakeGeneration == expectedWake, task == nil, !finished,
                  Date() < retryDeadline {
                condition.wait(until: retryDeadline)
            }
            let mayRetry = !cancelled && wakeGeneration == expectedWake && !finished && task == nil
            condition.unlock()
            if mayRetry { startAttempt() }
            condition.lock()
        }
    }

    func copyAvailable(at absoluteOffset: Int64, maximum: Int, to out: UnsafeMutablePointer<UInt8>) -> Int {
        condition.lock(); defer { condition.unlock() }
        let relativeOffset = Int(absoluteOffset - start)
        guard relativeOffset >= 0, relativeOffset < body.count else { return 0 }
        let count = min(maximum, body.count - relativeOffset, length - relativeOffset)
        guard count > 0 else { return 0 }
        body.withUnsafeBytes { src in
            out.update(from: src.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: relativeOffset),
                       count: count)
        }
        return count
    }

    func finishedSnapshot() -> (finished: Bool, data: Data?, successful: Bool) {
        condition.lock(); defer { condition.unlock() }
        guard finished else { return (false, nil, false) }
        let successful = !cancelled && !body.isEmpty
            && (!retriesPartialBodies || body.count >= length || !lastAttemptErrored)
        return (true, body, successful)
    }

    func cancel() {
        condition.lock()
        cancelled = true
        let activeTask = task
        condition.broadcast()
        condition.unlock()
        activeTask?.cancel()
    }

    /// Seeking outside this window waits until URLSession confirms that the obsolete task has
    /// finished. The caller can then start a replacement without overlapping source requests.
    func cancelAndWait() {
        cancel()
        waitUntilFinished()
    }

    func waitUntilFinished() {
        condition.lock()
        while task != nil || startingAttempt { condition.wait() }
        condition.unlock()
    }

    @discardableResult
    func waitUntilFinished(timeout: TimeInterval, wakeGeneration expectedWake: UInt64? = nil) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        waitingForTaskCompletion = true
        condition.broadcast()
        defer {
            waitingForTaskCompletion = false
            condition.broadcast()
            condition.unlock()
        }
        while task != nil || startingAttempt {
            if let expectedWake, wakeGeneration != expectedWake { return false }
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    func waitForAttemptStartup() {
        condition.lock()
        while startingAttempt { condition.wait() }
        condition.unlock()
    }

    private func startAttempt() {
        condition.lock()
        guard !cancelled, !finished, task == nil, !startingAttempt, body.count < length,
              attemptID <= maxRetries else {
            if task == nil && !startingAttempt && (body.count >= length || attemptID > maxRetries) {
                finished = true
            }
            condition.broadcast()
            condition.unlock()
            return
        }
        attemptID += 1
        startingAttempt = true
        let currentID = attemptID
        let offset = start + Int64(body.count)
        let remainingLength = length - body.count
        attemptAccepted = false
        condition.unlock()

        let (task, delegate) = autoreleasepool { () -> (URLSessionDataTask, ProgressiveRangeAttemptDelegate) in
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "GET"
            request.setValue(HTTPDiscIOReader.rangeHeader(offset: offset, length: remainingLength),
                             forHTTPHeaderField: "Range")
            for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
            let task = session.dataTask(with: request)
            let delegate = ProgressiveRangeAttemptDelegate(
                fetch: self, attemptID: currentID, offset: offset, length: remainingLength,
                extraHeaders: extraHeaders)
            task.delegate = delegate
            return (task, delegate)
        }

        condition.lock()
        guard !cancelled, !finished else {
            startingAttempt = false
            condition.broadcast()
            condition.unlock()
            task.cancel()
            return
        }
        self.task = task
        self.attemptDelegate = delegate
        startingAttempt = false
        condition.broadcast()
        condition.unlock()
        task.resume()
    }

    fileprivate func acceptResponse(_ response: HTTPURLResponse, attemptID: Int,
                                    offset: Int64, length: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled, self.attemptID == attemptID,
              response.statusCode == 206,
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              HTTPDiscIOReader.parseContentRangeStart(contentRange) == offset else { return false }
        let answer = AVIOReader.rangeAnswer(
            response, requestedStart: offset, requestedEnd: offset + Int64(length) - 1)
        guard answer == .honoured || answer == .overWide else { return false }
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(self.length)))))
        }
        attemptAccepted = true
        attemptOverWide = answer == .overWide
        condition.broadcast()
        return true
    }

    fileprivate func append(_ data: Data, attemptID: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled, self.attemptID == attemptID, attemptAccepted else { return true }
        let room = length - body.count
        let count = min(data.count, room)
        if count > 0 {
            body.append(data.prefix(count))
            onBytesReceived(count)
            condition.broadcast()
        }
        // Even a nominally exact response is capped at the requested window. Cancelling at the
        // boundary also handles chunked or inaccurate Content-Length responses safely.
        return data.count > room || (attemptOverWide && body.count >= length)
    }

    fileprivate func attemptDidComplete(_ id: Int, error: Error?) {
        condition.lock()
        guard attemptID == id else {
            condition.unlock()
            return
        }
        task = nil
        attemptDelegate = nil
        lastAttemptErrored = error != nil
        if body.count >= length || cancelled || attemptID > maxRetries
            || (!retriesPartialBodies && !body.isEmpty) || (error == nil && !body.isEmpty) {
            finished = true
        }
        condition.broadcast()
        condition.unlock()
    }
}

/// A task-specific delegate lets the range window validate response headers before it exposes any
/// data, while keeping EngineTLS's trust handling and cross-origin redirect credential scrubbing.
private final class ProgressiveRangeAttemptDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var fetch: ProgressiveRangeFetch?
    private let attemptID: Int
    private let offset: Int64
    private let length: Int
    private let extraHeaders: [String: String]

    init(fetch: ProgressiveRangeFetch, attemptID: Int, offset: Int64, length: Int,
         extraHeaders: [String: String]) {
        self.fetch = fetch
        self.attemptID = attemptID
        self.offset = offset
        self.length = length
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(RedirectHeaderPolicy.redirectRequest(
            request, originalURL: task.originalRequest?.url,
            originalRange: task.originalRequest?.value(forHTTPHeaderField: "Range"),
            extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let fetch = fetch, let http = response as? HTTPURLResponse,
              fetch.acceptResponse(http, attemptID: attemptID, offset: offset, length: length) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let fetch else {
            dataTask.cancel()
            return
        }
        if fetch.append(data, attemptID: attemptID) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        fetch?.attemptDidComplete(attemptID, error: error)
    }
}

/// One range request's delivery. The decision is made at the response head, where nothing of the body
/// has been taken yet, and the body is capped at the range that was asked for.
private final class RangeFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let offset: Int64
    private let length: Int
    private(set) var response: HTTPURLResponse?
    private(set) var answer: AVIOReader.RangeAnswer = .unjudged
    private(set) var body = Data()
    var onCompletion: (() -> Void)?

    init(offset: Int64, length: Int) {
        self.offset = offset
        self.length = length
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        self.response = http
        answer = AVIOReader.rangeAnswer(
            http, requestedStart: offset, requestedEnd: offset + Int64(length) - 1)
        switch answer {
        case .honoured, .overWide:
            body.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(length)))))
            completionHandler(.allow)
        case .ignored, .wholeFile, .misplaced, .unjudged:
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let room = length - body.count
        if room > 0 { body.append(data.prefix(room)) }
        // A body that ends on the range end is left to finish, which keeps the connection for the
        // next range. Hanging up is for what runs past it.
        if data.count > room || (answer == .overWide && body.count >= length) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?()
    }
}
