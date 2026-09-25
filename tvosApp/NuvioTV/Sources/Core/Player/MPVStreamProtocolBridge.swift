import Foundation
import Libmpv

/// Bridges `libmpv` custom stream callbacks (`mpv_stream_cb`) to native `URLSession` HTTP range requests.
/// This allows MPV to stream over `http://` (including the local caching proxy `http://127.0.0.1:...`) and
/// `https://` even when the precompiled `Libavformat` binary lacks embedded network protocol handlers.
final class MPVStreamProtocolBridge: @unchecked Sendable {
    static let shared = MPVStreamProtocolBridge()

    private let lock = NSLock()
    private var customHeaders: [String: String] = [:]

    func setHTTPHeaders(_ headers: [String: String]) {
        lock.lock()
        customHeaders = headers
        lock.unlock()
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
            let headers = bridge.currentHTTPHeaders()

            guard let session = MPVStreamSession(url: url, headers: headers) else {
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
private final class MPVStreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL
    let headers: [String: String]

    private let condition = NSCondition()
    private var urlSession: URLSession!
    private var dataTask: URLSessionDataTask?
    private var totalSize: Int64 = -1
    private var currentPosition: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var requestedEnd: Int64 = 0
    private var buffer = Data()
    private var isEOF = false
    private var isCancelled = false
    private var isClosed = false
    private var isTaskSuspended = false
    private var taskError: Error?
    private var consecutiveReadFailures = 0
    private let rangeRequestBytes: Int64 = 16 * 1024 * 1024

    private let maxBufferSize = 32 * 1024 * 1024 // 32 MB buffer cap
    private let resumeBufferSize = 16 * 1024 * 1024 // 16 MB resume threshold

    init?(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300

        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.name = "nuvio.mpv.stream-session"

        super.init()
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: operationQueue)

        startRangeRequest(from: 0)
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

        guard !isClosed else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        if offset < 0 { return Int64(MPV_ERROR_GENERIC.rawValue) }
        if totalSize >= 0 && offset > totalSize { return Int64(MPV_ERROR_GENERIC.rawValue) }

        if offset == currentPosition && !isEOF {
            return offset
        }

        // Restart data task from the new target offset
        isEOF = false
        taskError = nil
        consecutiveReadFailures = 0
        isTaskSuspended = false
        buffer.removeAll(keepingCapacity: true)
        currentPosition = offset

        startRangeRequest(from: offset)
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
                buffer.withUnsafeBytes { rawBytes in
                    guard let base = rawBytes.baseAddress else { return }
                    buf.withMemoryRebound(to: UInt8.self, capacity: toRead) { dest in
                        dest.initialize(from: base.assumingMemoryBound(to: UInt8.self), count: toRead)
                    }
                }
                buffer.removeSubrange(0..<toRead)
                currentPosition += Int64(toRead)
                consecutiveReadFailures = 0

                if isTaskSuspended && buffer.count < resumeBufferSize {
                    isTaskSuspended = false
                    dataTask?.resume()
                }

                return Int64(toRead)
            }

            if isEOF {
                if totalSize >= 0 && currentPosition < totalSize {
                    isEOF = false
                    startRangeRequest(from: currentPosition)
                    continue
                }
                return 0 // Clean EOF
            }

            if let error = taskError {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain,
                   (nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorTimedOut),
                   consecutiveReadFailures < 3,
                   (totalSize < 0 || currentPosition < totalSize) {
                    consecutiveReadFailures += 1
                    taskError = nil
                    startRangeRequest(from: currentPosition)
                    continue
                }
                print("[MPVStreamBridge] Read failed with error: \(error.localizedDescription)")
                return -1
            }

            // If task was suspended but buffer drained, resume it
            if isTaskSuspended {
                isTaskSuspended = false
                dataTask?.resume()
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
        if isTaskSuspended {
            isTaskSuspended = false
            dataTask?.resume()
        }
        dataTask?.cancel()
        dataTask = nil
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        isClosed = true
        isCancelled = true
        if isTaskSuspended {
            isTaskSuspended = false
            dataTask?.resume()
        }
        dataTask?.cancel()
        dataTask = nil
        condition.broadcast()
        condition.unlock()

        urlSession.invalidateAndCancel()
    }

    // MARK: - Private Range Request

    private func startRangeRequest(from offset: Int64) {
        dataTask?.cancel()
        dataTask = nil
        isTaskSuspended = false

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("NuvioTV/MPVKit", forHTTPHeaderField: "User-Agent")
        }
        let rangeEnd = offset > Int64.max - rangeRequestBytes ? Int64.max : offset + rangeRequestBytes - 1
        let end = min(totalSize > 0 ? totalSize - 1 : Int64.max, rangeEnd)
        requestedOffset = offset
        requestedEnd = end
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

        let task = urlSession.dataTask(with: request)
        self.dataTask = task
        task.resume()
    }

    // MARK: - URLSessionDataDelegate

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

        if let httpResponse = response as? HTTPURLResponse {
            let status = httpResponse.statusCode
            if status >= 400 {
                taskError = NSError(domain: "HTTPError", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
                completionHandler(.cancel)
                return
            }
            if requestedOffset > 0 && status != 206 {
                taskError = NSError(domain: "HTTPError", code: status,
                                    userInfo: [NSLocalizedDescriptionKey: "Server ignored the requested byte range"])
                completionHandler(.cancel)
                return
            }

            if status == 206 {
                // A bounded response's Content-Length is only this range's size.
                // Treating it as the file size would silently stop after 16 MiB.
                let parts = httpResponse.value(forHTTPHeaderField: "Content-Range")?
                    .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
                guard let parts, parts.count == 4, parts[0].lowercased() == "bytes",
                      let start = Int64(parts[1]), let end = Int64(parts[2]),
                      let size = Int64(parts[3]), size > 0,
                      start == requestedOffset, end >= start, end <= requestedEnd, end < size,
                      totalSize < 0 || totalSize == size else {
                    taskError = NSError(domain: "HTTPError", code: status,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid Content-Range response"])
                    completionHandler(.cancel)
                    return
                }
                totalSize = size
            } else if status == 200 && httpResponse.expectedContentLength > 0 {
                totalSize = httpResponse.expectedContentLength
            }
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        guard self.dataTask === dataTask else {
            condition.unlock()
            return
        }
        buffer.append(data)
        if buffer.count >= maxBufferSize && !isTaskSuspended {
            isTaskSuspended = true
            dataTask.suspend()
        }
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
        if let error = error as? NSError, error.code == NSURLErrorCancelled {
            // Explicitly cancelled during seek or close — do not treat as fatal error
        } else if let error {
            self.taskError = error
        } else {
            self.isEOF = true
        }
        condition.broadcast()
        condition.unlock()
    }
}
