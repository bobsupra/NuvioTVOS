import Foundation
import Libmpv

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
struct MPVStreamBridgeMemorySnapshot: Codable, Equatable, Sendable {
    let activeSessions: Int
    let bufferedDataBytes: Int64
    let suspendedTasks: Int
    let retryCount: Int
}

private struct MPVStreamSessionMemoryState: Sendable {
    let bufferedDataBytes: Int64
    let isTaskSuspended: Bool
    let retryCount: Int
}
#endif

/// Bridges `libmpv` custom stream callbacks (`mpv_stream_cb`) to native `URLSession` HTTP range requests.
/// This allows MPV to stream over `http://` (including the local caching proxy `http://127.0.0.1:...`) and
/// `https://` even when the precompiled `Libavformat` binary lacks embedded network protocol handlers.
final class MPVStreamProtocolBridge: @unchecked Sendable {
    static let shared = MPVStreamProtocolBridge()

    private let lock = NSLock()
    private var customHeaders: [String: String] = [:]
    private var isLiveStream: Bool = false
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
    private let memoryDiagnosticLock = NSLock()
    private var memoryDiagnosticSessions: [UUID: MPVStreamSessionMemoryState] = [:]

    func updateMemoryDiagnostics(sessionID: UUID, bufferedDataBytes: Int64, isTaskSuspended: Bool, retryCount: Int) {
        memoryDiagnosticLock.lock()
        memoryDiagnosticSessions[sessionID] = MPVStreamSessionMemoryState(
            bufferedDataBytes: bufferedDataBytes,
            isTaskSuspended: isTaskSuspended,
            retryCount: retryCount
        )
        memoryDiagnosticLock.unlock()
    }

    func removeMemoryDiagnostics(sessionID: UUID) {
        memoryDiagnosticLock.lock()
        memoryDiagnosticSessions.removeValue(forKey: sessionID)
        memoryDiagnosticLock.unlock()
    }

    func memoryDiagnosticSnapshot() -> MPVStreamBridgeMemorySnapshot {
        memoryDiagnosticLock.lock()
        defer { memoryDiagnosticLock.unlock() }
        let states = memoryDiagnosticSessions.values
        return MPVStreamBridgeMemorySnapshot(
            activeSessions: states.count,
            bufferedDataBytes: states.reduce(Int64(0)) { $0 + $1.bufferedDataBytes },
            suspendedTasks: states.filter(\.isTaskSuspended).count,
            retryCount: states.reduce(0) { $0 + $1.retryCount }
        )
    }
#endif

    func setHTTPHeaders(_ headers: [String: String], isLiveStream: Bool = false) {
        lock.lock()
        customHeaders = headers
        self.isLiveStream = isLiveStream
        lock.unlock()
    }

    func currentConfiguration() -> (headers: [String: String], isLiveStream: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (customHeaders, isLiveStream)
    }

    func currentHTTPHeaders() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return customHeaders
    }

    /// Registers `http` and `https` protocol handlers on the given mpv handle.
    static func register(on mpv: OpaquePointer?) {
        guard let mpv else { return }

        let openCallback: mpv_stream_cb_open_ro_fn = { userData, uriPtr, infoPtr in
            guard let uriPtr, let infoPtr else { return MPV_ERROR_LOADING_FAILED.rawValue }
            let uri = String(cString: uriPtr)
            guard let url = URL(string: uri) else { return MPV_ERROR_LOADING_FAILED.rawValue }

            let bridge = MPVStreamProtocolBridge.shared
            let config = bridge.currentConfiguration()

            guard let session = MPVStreamSession(url: url, headers: config.headers, isLiveStream: config.isLiveStream) else {
                return MPV_ERROR_LOADING_FAILED.rawValue
            }

            let retained = Unmanaged.passRetained(session).toOpaque()
            infoPtr.pointee.cookie = retained
            infoPtr.pointee.read_fn = { cookie, buf, nbytes in
                guard let cookie, let buf else { return -1 }
                let streamSession = Unmanaged<MPVStreamSession>.fromOpaque(cookie).takeUnretainedValue()
                return streamSession.read(into: buf, count: Int(nbytes))
            }
            infoPtr.pointee.seek_fn = { cookie, offset in
                guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
                let streamSession = Unmanaged<MPVStreamSession>.fromOpaque(cookie).takeUnretainedValue()
                return streamSession.seek(to: offset)
            }
            infoPtr.pointee.size_fn = { cookie in
                guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
                let streamSession = Unmanaged<MPVStreamSession>.fromOpaque(cookie).takeUnretainedValue()
                return streamSession.size()
            }
            infoPtr.pointee.close_fn = { cookie in
                guard let cookie else { return }
                let streamSession = Unmanaged<MPVStreamSession>.fromOpaque(cookie).takeRetainedValue()
                streamSession.close()
            }
            infoPtr.pointee.cancel_fn = { cookie in
                guard let cookie else { return }
                let streamSession = Unmanaged<MPVStreamSession>.fromOpaque(cookie).takeUnretainedValue()
                streamSession.cancel()
            }

            return 0 // MPV_ERROR_SUCCESS
        }

        _ = mpv_stream_cb_add_ro(mpv, "http", nil, openCallback)
        _ = mpv_stream_cb_add_ro(mpv, "https", nil, openCallback)
    }
}

/// Active read session for an individual MPV stream.
final class MPVStreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum RequestMode: Equatable {
        case finiteRange
        case sequential
    }

    let url: URL
    let headers: [String: String]
    let isLiveStream: Bool

    private let condition = NSCondition()
    private var urlSession: URLSession!
    private var dataTask: URLSessionDataTask?
    private var totalSize: Int64 = -1
    private var currentPosition: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var requestedEnd: Int64?
    private var requestedByteBudget: Int64?
    private var requestMode: RequestMode = .finiteRange
    private var responseByteBudget: Int64?
    private var responseBytesReceived: Int64 = 0
    private var responseExpectedContentLength: Int64?
    private var requestCompleted = false
    private var requestConfirmedEOF = false
    private var requestGeneration: UInt64 = 0
    private var buffer = Data()
    private var isEOF = false
    private var isCancelled = false
    private var isClosed = false
    private var isTaskSuspended = false
    private var taskError: Error?
    private var consecutiveReadFailures = 0
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
    private let memoryDiagnosticSessionID = UUID()
#endif

    private let maxBufferSize: Int
    private let resumeBufferSize: Int
    private let rangeRequestSize: Int64

    init?(
        url: URL,
        headers: [String: String],
        isLiveStream: Bool = false,
        sessionConfiguration: URLSessionConfiguration? = nil,
        rangeRequestSize: Int = 4 * 1024 * 1024,
        bufferLimit: Int = 64 * 1024 * 1024
    ) {
        guard rangeRequestSize > 0, bufferLimit > 0 else { return nil }
        self.url = url
        self.headers = headers
        self.isLiveStream = isLiveStream
        let effectiveBufferLimit = min(bufferLimit, 64 * 1024 * 1024)
        maxBufferSize = effectiveBufferLimit
        resumeBufferSize = min(32 * 1024 * 1024, max(1, effectiveBufferLimit / 2))
        self.rangeRequestSize = Int64(min(rangeRequestSize, effectiveBufferLimit))

        let config = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300

        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.name = "nuvio.mpv.stream-session"

        super.init()
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: operationQueue)

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        condition.lock()
        startRangeRequest(from: 0)
        condition.unlock()
#else
        startRangeRequest(from: 0)
#endif
    }

    func size() -> Int64 {
        condition.lock()
        defer { condition.unlock() }

        // If the initial header response is still in flight, wait briefly (up to 3s)
        if totalSize < 0 && !isEOF && taskError == nil && !isCancelled && !isClosed {
            let deadline = Date().addingTimeInterval(3)
            while totalSize < 0 && !isEOF && taskError == nil && !isCancelled && !isClosed && Date() < deadline {
                condition.wait(until: Date().addingTimeInterval(0.05))
            }
        }
        return totalSize >= 0 ? totalSize : Int64(MPV_ERROR_UNSUPPORTED.rawValue)
    }

    func seek(to offset: Int64) -> Int64 {
        condition.lock()
        defer { condition.unlock() }

        guard !isClosed && !isCancelled else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        if offset < 0 { return Int64(MPV_ERROR_GENERIC.rawValue) }
        if totalSize >= 0 && offset > totalSize { return Int64(MPV_ERROR_GENERIC.rawValue) }

        if offset == currentPosition && !isEOF && taskError == nil {
            return offset
        }

        if totalSize >= 0 && offset == totalSize {
            if isTaskSuspended {
                isTaskSuspended = false
                dataTask?.resume()
            }
            dataTask?.cancel()
            dataTask = nil
            requestGeneration &+= 1
            buffer = Data()
            currentPosition = offset
            requestedOffset = offset
            requestedEnd = nil
            requestedByteBudget = nil
            responseByteBudget = nil
            responseBytesReceived = 0
            responseExpectedContentLength = nil
            requestCompleted = true
            requestConfirmedEOF = true
            isEOF = true
            taskError = nil
            publishMemoryDiagnosticsIfEnabled()
            condition.broadcast()
            return currentPosition
        }

        // Fast forward seek if the requested offset is already inside our in-memory buffer
        let forwardDelta = offset - currentPosition
        if forwardDelta > 0 && forwardDelta < Int64(buffer.count) {
            buffer.removeSubrange(0..<Int(forwardDelta))
            currentPosition = offset
            if buffer.isEmpty { buffer = Data() }
            if isTaskSuspended && buffer.count < resumeBufferSize {
                isTaskSuspended = false
                dataTask?.resume()
            }
            publishMemoryDiagnosticsIfEnabled()
            condition.broadcast()
            return currentPosition
        }

        // Restart data task from the new target offset
        isEOF = false
        taskError = nil
        consecutiveReadFailures = 0
        buffer = Data()
        currentPosition = offset
        requestCompleted = false
        requestConfirmedEOF = false

        startRangeRequest(from: offset)
        condition.broadcast()
        return currentPosition
    }

    func read(into buf: UnsafeMutablePointer<CChar>, count: Int) -> Int64 {
        guard count > 0 else { return 0 }

        condition.lock()
        defer { condition.unlock() }

        while true {
            if isClosed || isCancelled {
                return -1
            }

            if !buffer.isEmpty {
                let toRead = min(count, buffer.count)
                let (nextPosition, overflow) = currentPosition.addingReportingOverflow(Int64(toRead))
                guard !overflow else {
                    setTerminalError("Read position overflow", cancelTask: true)
                    return -1
                }
                buffer.withUnsafeBytes { rawBytes in
                    guard let base = rawBytes.baseAddress else { return }
                    buf.withMemoryRebound(to: UInt8.self, capacity: toRead) { dest in
                        dest.initialize(from: base.assumingMemoryBound(to: UInt8.self), count: toRead)
                    }
                }
                buffer.removeSubrange(0..<toRead)
                currentPosition = nextPosition
                if buffer.isEmpty { buffer = Data() }

                if isTaskSuspended && buffer.count < resumeBufferSize {
                    isTaskSuspended = false
                    dataTask?.resume()
                }
                publishMemoryDiagnosticsIfEnabled()
                condition.broadcast()

                return Int64(toRead)
            }

            if isEOF {
                return 0 // Clean EOF
            }

            if let error = taskError {
                if let backoff = retryBackoff(for: error),
                   (isLiveStream || requestMode == .finiteRange),
                   consecutiveReadFailures < (isLiveStream ? 50 : 5),
                   (isLiveStream || totalSize <= 0 || currentPosition < totalSize) {
                    consecutiveReadFailures += 1
                    publishMemoryDiagnosticsIfEnabled()
                    let generation = requestGeneration
                    let retryDeadline = Date().addingTimeInterval(backoff)
                    while !isClosed && !isCancelled && requestGeneration == generation && Date() < retryDeadline {
                        condition.wait(until: retryDeadline)
                    }

                    guard !isClosed && !isCancelled else { return -1 }
                    if requestGeneration != generation { continue }
                    taskError = nil
                    requestCompleted = false
                    isEOF = false
                    startRangeRequest(from: isLiveStream ? 0 : currentPosition)
                    continue
                }
                print("[MPVStreamBridge] Read failed with error: \(error.localizedDescription)")
                return -1
            }

            if requestCompleted {
                if requestConfirmedEOF {
                    isEOF = true
                    return 0
                }
                switch requestMode {
                case .finiteRange:
                    if totalSize >= 0 && currentPosition == totalSize {
                        isEOF = true
                        return 0
                    }
                    startRangeRequest(from: currentPosition)
                case .sequential where isLiveStream:
                    // Live streams reconnect from zero after a clean disconnect, matching prior behavior.
                    if consecutiveReadFailures < 50 {
                        consecutiveReadFailures += 1
                        #if DEBUG
                        print("[LiveWatchdog][Bridge] 🔄 Live stream connection closed by server, reconnecting seamlessly (attempt \(consecutiveReadFailures)/50)...")
                        #endif
                        startRangeRequest(from: 0)
                    } else {
                        isEOF = true
                        return 0
                    }
                case .sequential:
                    if totalSize >= 0 && currentPosition != totalSize {
                        setTerminalError("Sequential response ended at byte \(currentPosition) of \(totalSize)")
                        continue
                    }
                    isEOF = true
                    return 0
                }
                continue
            }

            // If task was suspended but buffer drained, resume it
            if isTaskSuspended {
                isTaskSuspended = false
                dataTask?.resume()
                publishMemoryDiagnosticsIfEnabled()
            }

            // Wait for incoming data or EOF from URLSession delegate
            condition.wait(until: Date().addingTimeInterval(30))

            // Completion is reported by didCompleteWithError. A completed
            // URLSessionTask alone does not distinguish EOF from a read error.
        }
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        requestGeneration &+= 1
        if isTaskSuspended {
            isTaskSuspended = false
            dataTask?.resume()
        }
        dataTask?.cancel()
        dataTask = nil
        buffer = Data()
        requestCompleted = true
        publishMemoryDiagnosticsIfEnabled()
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        isClosed = true
        isCancelled = true
        requestGeneration &+= 1
        if isTaskSuspended {
            isTaskSuspended = false
            dataTask?.resume()
        }
        dataTask?.cancel()
        dataTask = nil
        buffer = Data()
        requestCompleted = true
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        MPVStreamProtocolBridge.shared.removeMemoryDiagnostics(sessionID: memoryDiagnosticSessionID)
#endif
        condition.broadcast()
        condition.unlock()

        urlSession.invalidateAndCancel()
    }

    // MARK: - Private Range Request

    private func startRangeRequest(from offset: Int64) {
        guard !isClosed && !isCancelled else { return }
        if isTaskSuspended {
            isTaskSuspended = false
            dataTask?.resume()
        }
        dataTask?.cancel()
        dataTask = nil
        requestGeneration &+= 1
        requestCompleted = false
        requestConfirmedEOF = false
        requestedEnd = nil
        requestedByteBudget = nil
        responseByteBudget = nil
        responseBytesReceived = 0
        responseExpectedContentLength = nil
        isEOF = false

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("NuvioTV/MPVKit", forHTTPHeaderField: "User-Agent")
        }
        requestedOffset = offset

        if isLiveStream {
            requestMode = .sequential
            requestedEnd = nil
            requestedByteBudget = nil
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else if let end = finiteRangeEnd(from: offset) {
            requestMode = .finiteRange
            requestedEnd = end
            requestedByteBudget = byteCount(from: offset, through: end)
            guard requestedByteBudget != nil else {
                setTerminalError("Invalid finite byte range at offset \(offset)")
                requestCompleted = true
                condition.broadcast()
                publishMemoryDiagnosticsIfEnabled()
                return
            }
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        } else if totalSize >= 0 && offset == totalSize {
            requestMode = .finiteRange
            requestedEnd = nil
            requestedByteBudget = nil
            requestCompleted = true
            requestConfirmedEOF = true
            isEOF = true
            condition.broadcast()
            publishMemoryDiagnosticsIfEnabled()
            return
        } else {
            setTerminalError("Cannot construct finite byte range at offset \(offset)")
            requestCompleted = true
            condition.broadcast()
            publishMemoryDiagnosticsIfEnabled()
            return
        }

        let task = urlSession.dataTask(with: request)
        self.dataTask = task
        task.resume()
        publishMemoryDiagnosticsIfEnabled()
    }

    private func finiteRangeEnd(from offset: Int64) -> Int64? {
        guard offset >= 0 else { return nil }
        let lastAllowed: Int64
        if totalSize >= 0 {
            guard offset < totalSize else { return nil }
            lastAllowed = totalSize - 1
        } else {
            lastAllowed = Int64.max
        }

        let (candidate, overflow) = offset.addingReportingOverflow(rangeRequestSize - 1)
        return min(overflow ? Int64.max : candidate, lastAllowed)
    }

    private func byteCount(from start: Int64, through end: Int64) -> Int64? {
        guard start >= 0, end >= start else { return nil }
        let (difference, differenceOverflow) = end.subtractingReportingOverflow(start)
        guard !differenceOverflow else { return nil }
        let (count, countOverflow) = difference.addingReportingOverflow(1)
        return countOverflow ? nil : count
    }

    private func adding(_ value: Int64, _ increment: Int64) -> Int64? {
        let (result, overflow) = value.addingReportingOverflow(increment)
        return overflow ? nil : result
    }

    private func unsatisfiedContentRangeTotal(_ value: String) -> Int64? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2, rangeAndTotal[0] == "*",
              !rangeAndTotal[1].isEmpty,
              rangeAndTotal[1].allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int64(rangeAndTotal[1])
    }

    private func terminalError(_ message: String) -> NSError {
        NSError(domain: "MPVStreamError", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Caller holds `condition`.
    private func setTerminalError(_ message: String, cancelTask: Bool = false) {
        if taskError == nil { taskError = terminalError(message) }
        if cancelTask {
            if isTaskSuspended {
                isTaskSuspended = false
                dataTask?.resume()
            }
            dataTask?.cancel()
        }
        publishMemoryDiagnosticsIfEnabled()
        condition.broadcast()
    }

    private func truncatedResponseError(expected: Int64, received: Int64) -> NSError {
        NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "Truncated range response: received \(received) of \(expected) bytes"]
        )
    }

    private func retryBackoff(for error: Error) -> TimeInterval? {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable
        ].contains(nsError.code) {
            return 0.2
        }
        if nsError.domain == "HTTPError" && [429, 500, 502, 503, 504].contains(nsError.code) {
            return min(Double(consecutiveReadFailures + 1) * 0.5, 2.0)
        }
        return nil
    }

    private func publishMemoryDiagnosticsIfEnabled() {
#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
        publishMemoryDiagnostics()
#endif
    }

    // MARK: - URLSessionDataDelegate

    /// The add-on's headers (tokens, cookies, Authorization) go only to the source's own origin,
    /// the same policy the Aether cache applies: a redirect to another host (a CDN) gets the
    /// request without them, and keeps the byte range asked for.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(PlaybackStreamCacheRedirectPolicy.redirectedRequest(
            request,
            response: response,
            originalURL: url,
            range: task.originalRequest?.value(forHTTPHeaderField: "Range"),
            customHeaders: headers
        ))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }

        guard self.dataTask === dataTask else {
            completionHandler(.cancel)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            setTerminalError("Expected an HTTP response")
            completionHandler(.cancel)
            return
        }

        let status = httpResponse.statusCode
        if status == 416 {
            guard requestMode == .finiteRange,
                  let header = httpResponse.value(forHTTPHeaderField: "Content-Range"),
                  let total = unsatisfiedContentRangeTotal(header),
                  requestedOffset == total,
                  totalSize < 0 || totalSize == total else {
                setTerminalError("HTTP 416 did not confirm EOF at byte \(requestedOffset)")
                completionHandler(.cancel)
                return
            }
            totalSize = total
            let eofTask = self.dataTask
            self.dataTask = nil
            requestGeneration &+= 1
            requestConfirmedEOF = true
            requestCompleted = true
            isEOF = true
            isTaskSuspended = false
            responseByteBudget = 0
            responseExpectedContentLength = 0
            eofTask?.cancel()
            publishMemoryDiagnosticsIfEnabled()
            completionHandler(.cancel)
            return
        }

        if status >= 400 {
            if taskError == nil {
                taskError = NSError(domain: "HTTPError", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
            }
            completionHandler(.cancel)
            return
        }

        responseExpectedContentLength = httpResponse.expectedContentLength >= 0
            ? httpResponse.expectedContentLength
            : nil

        if status == 206 {
            guard let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
                  let parsedRange = PlaybackStreamCacheContentRange.parse(contentRange),
                  parsedRange.start == requestedOffset else {
                setTerminalError("Invalid Content-Range for requested byte \(requestedOffset)")
                completionHandler(.cancel)
                return
            }

            if requestMode == .finiteRange {
                guard let requestedEnd,
                      let requestedByteBudget,
                      parsedRange.end <= requestedEnd,
                      let bodyLength = byteCount(from: parsedRange.start, through: parsedRange.end),
                      bodyLength <= requestedByteBudget else {
                    setTerminalError("Content-Range exceeded requested finite range")
                    completionHandler(.cancel)
                    return
                }
                if let expectedLength = responseExpectedContentLength, expectedLength != bodyLength {
                    setTerminalError("Content-Length \(expectedLength) did not match Content-Range length \(bodyLength)")
                    completionHandler(.cancel)
                    return
                }
                if let total = parsedRange.total {
                    guard totalSize < 0 || totalSize == total else {
                        setTerminalError("Content-Range total changed from \(totalSize) to \(total)")
                        completionHandler(.cancel)
                        return
                    }
                    totalSize = total
                }
                responseByteBudget = bodyLength
            } else if isLiveStream {
                // Live 206 responses remain sequential/open-ended. Retain a total only if it is stable.
                if let total = parsedRange.total, totalSize < 0 {
                    totalSize = total
                }
            } else {
                setTerminalError("Unexpected sequential 206 response")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
            return
        }

        if status == 200 {
            guard requestedOffset == 0 else {
                if taskError == nil {
                    taskError = NSError(
                        domain: "HTTPError",
                        code: status,
                        userInfo: [NSLocalizedDescriptionKey: "Server ignored the requested byte range"]
                    )
                }
                completionHandler(.cancel)
                return
            }
            requestMode = .sequential
            responseByteBudget = nil
            if !isLiveStream, let contentLength = responseExpectedContentLength {
                guard totalSize < 0 || totalSize == contentLength else {
                    setTerminalError("Sequential Content-Length changed from \(totalSize) to \(contentLength)")
                    completionHandler(.cancel)
                    return
                }
                totalSize = contentLength
            }
            completionHandler(.allow)
            return
        }

        setTerminalError("Unsupported HTTP status \(status)")
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        guard self.dataTask === dataTask else {
            condition.unlock()
            return
        }

        guard taskError == nil, !requestCompleted, !requestConfirmedEOF else {
            if taskError == nil && !requestConfirmedEOF {
                setTerminalError("Received data after request completion", cancelTask: true)
            }
            condition.broadcast()
            condition.unlock()
            return
        }

        let chunkBytes = Int64(data.count)
        let (receivedAfterChunk, responseOverflow) = responseBytesReceived.addingReportingOverflow(chunkBytes)
        guard !responseOverflow else {
            setTerminalError("Response byte count overflow", cancelTask: true)
            condition.broadcast()
            condition.unlock()
            return
        }

        if requestMode == .finiteRange {
            guard let responseByteBudget,
                  let requestedByteBudget,
                  receivedAfterChunk <= responseByteBudget,
                  receivedAfterChunk <= requestedByteBudget else {
                setTerminalError("Response body exceeded finite range byte budget", cancelTask: true)
                condition.broadcast()
                condition.unlock()
                return
            }
        } else if !isLiveStream, totalSize >= 0 {
            let (maximumSequentialBytes, overflow) = totalSize.subtractingReportingOverflow(requestedOffset)
            guard !overflow, receivedAfterChunk <= maximumSequentialBytes else {
                setTerminalError("Sequential response exceeded declared Content-Length", cancelTask: true)
                condition.broadcast()
                condition.unlock()
                return
            }
        }

        responseBytesReceived = receivedAfterChunk

        if requestMode == .finiteRange {
            guard buffer.count <= maxBufferSize,
                  data.count <= maxBufferSize - buffer.count else {
                setTerminalError("Stream buffer exceeded \(maxBufferSize) byte hard cap", cancelTask: true)
                condition.broadcast()
                condition.unlock()
                return
            }
            buffer.append(data)
        } else {
            var appendedBytes = 0
            while appendedBytes < data.count {
                guard !isClosed, !isCancelled, taskError == nil, self.dataTask === dataTask else {
                    condition.broadcast()
                    condition.unlock()
                    return
                }

                guard buffer.count <= maxBufferSize else {
                    setTerminalError("Stream buffer exceeded \(maxBufferSize) byte hard cap", cancelTask: true)
                    condition.broadcast()
                    condition.unlock()
                    return
                }

                let availableBytes = maxBufferSize - buffer.count
                if availableBytes == 0 {
                    if !isTaskSuspended {
                        isTaskSuspended = true
                        dataTask.suspend()
                    }
                    condition.wait()
                    continue
                }

                let bytesToAppend = min(availableBytes, data.count - appendedBytes)
                let endIndex = appendedBytes + bytesToAppend
                buffer.append(data[appendedBytes..<endIndex])
                appendedBytes = endIndex

                if buffer.count >= maxBufferSize && !isTaskSuspended {
                    isTaskSuspended = true
                    dataTask.suspend()
                }
                publishMemoryDiagnosticsIfEnabled()
                condition.broadcast()
            }
        }
        if isLiveStream && !data.isEmpty { consecutiveReadFailures = 0 }
        publishMemoryDiagnosticsIfEnabled()
        condition.broadcast()
        condition.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        guard dataTask === task else {
            condition.unlock()
            return
        }
        isTaskSuspended = false
        requestCompleted = true

        if requestConfirmedEOF {
            isEOF = true
        } else if let error {
            if taskError == nil {
                if requestMode == .finiteRange,
                   let responseByteBudget,
                   responseBytesReceived == responseByteBudget,
                   totalSize >= 0,
                   let receivedEnd = adding(requestedOffset, responseBytesReceived),
                   receivedEnd == totalSize {
                    isEOF = true
                } else {
                    taskError = error
                }
            }
        } else {
            switch requestMode {
            case .finiteRange:
                if let responseByteBudget, responseBytesReceived < responseByteBudget {
                    if taskError == nil {
                        taskError = truncatedResponseError(
                            expected: responseByteBudget,
                            received: responseBytesReceived
                        )
                    }
                } else {
                    consecutiveReadFailures = 0
                }
            case .sequential where isLiveStream:
                break
            case .sequential:
                if let responseExpectedContentLength,
                   responseBytesReceived != responseExpectedContentLength,
                   taskError == nil {
                    taskError = terminalError(
                        "Sequential response ended after \(responseBytesReceived) of \(responseExpectedContentLength) declared bytes"
                    )
                } else if totalSize >= 0 && responseBytesReceived != totalSize && taskError == nil {
                    taskError = terminalError(
                        "Sequential response ended at \(responseBytesReceived) of \(totalSize) declared bytes"
                    )
                } else if taskError == nil {
                    isEOF = true
                }
            }
        }
        publishMemoryDiagnosticsIfEnabled()
        condition.broadcast()
        condition.unlock()
    }

#if NUVIO_MPV_MEMORY_WATCHDOG && os(tvOS)
    /// Caller holds `condition`; the bridge registry stores only these numeric values.
    private func publishMemoryDiagnostics() {
        MPVStreamProtocolBridge.shared.updateMemoryDiagnostics(
            sessionID: memoryDiagnosticSessionID,
            bufferedDataBytes: Int64(buffer.count),
            isTaskSuspended: isTaskSuspended,
            retryCount: consecutiveReadFailures
        )
    }
#endif
}
