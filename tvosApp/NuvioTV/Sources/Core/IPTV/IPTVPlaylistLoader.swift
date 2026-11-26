import Foundation

enum IPTVPlaylistLoadError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case tooLarge
    case invalidEncoding
    case invalidSourceID
}

struct IPTVLoadedPlaylist {
    let channels: [IPTVChannel]
    let guideURLs: [URL]
    var guideURL: URL? { guideURLs.first }
}

/// Downloads only user-configured playlists. Callers own any previously loaded
/// list and decide whether to replace it after this operation succeeds.
struct IPTVPlaylistLoader {
    static let maximumBytes = 64 * 1024 * 1024
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func load(url: URL, sourceID: String) async throws -> [IPTVChannel] {
        try await loadPlaylist(url: url, sourceID: sourceID).channels
    }

    func loadPlaylist(url: URL, sourceID: String) async throws -> IPTVLoadedPlaylist {
        guard Self.isWebURL(url) else { throw IPTVPlaylistLoadError.invalidURL }
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IPTVPlaylistLoadError.invalidSourceID }
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("NuvioTV", forHTTPHeaderField: "User-Agent")
        let response: IPTVBoundedDownloadResponse
        do {
            response = try await IPTVBoundedDataDownloader.download(
                request,
                in: session,
                maximumBytes: Self.maximumBytes
            )
        } catch IPTVBoundedDownloadError.invalidResponse {
            throw IPTVPlaylistLoadError.invalidResponse
        } catch IPTVBoundedDownloadError.httpStatus(let code) {
            throw IPTVPlaylistLoadError.httpStatus(code)
        } catch IPTVBoundedDownloadError.tooLarge {
            throw IPTVPlaylistLoadError.tooLarge
        }
        guard let finalURL = response.httpResponse.url, Self.isWebURL(finalURL) else {
            throw IPTVPlaylistLoadError.invalidResponse
        }
        try Task.checkCancellation()
        return try Self.parsePlaylist(data: response.data, sourceID: sourceID, baseURL: finalURL)
    }

    static func parse(data: Data, sourceID: String, baseURL: URL) throws -> [IPTVChannel] {
        try parsePlaylist(data: data, sourceID: sourceID, baseURL: baseURL).channels
    }

    static func parsePlaylist(data: Data, sourceID: String, baseURL: URL) throws -> IPTVLoadedPlaylist {
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IPTVPlaylistLoadError.invalidSourceID }
        guard data.count <= maximumBytes else { throw IPTVPlaylistLoadError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw IPTVPlaylistLoadError.invalidEncoding }
        let playlists: [IPTVPlaylistParser.Playlist]
        do {
            playlists = try IPTVPlaylistParser(string: text).parse()
        } catch IPTVPlaylistParser.ParserError.tooLarge {
            throw IPTVPlaylistLoadError.tooLarge
        }
        let channels: [IPTVChannel]
        do {
            channels = try IPTVChannelImporter.channels(from: playlists, sourceID: sourceID, baseURL: baseURL)
        } catch IPTVChannelImportError.tooLarge {
            throw IPTVPlaylistLoadError.tooLarge
        }
        var guideURLs: [URL] = []
        var seenGuideURLs = Set<String>()
        for playlist in playlists {
            for raw in [playlist.tvgURL, playlist.xTvgURL].compactMap({ $0 }) {
                for candidate in raw.split(separator: ",", omittingEmptySubsequences: false) {
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
                          isWebURL(url), seenGuideURLs.insert(url.absoluteString).inserted else { continue }
                    guideURLs.append(url)
                }
            }
        }
        return IPTVLoadedPlaylist(channels: channels, guideURLs: guideURLs)
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}

enum IPTVBoundedDownloadError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case tooLarge
}

struct IPTVBoundedDownloadResponse: Sendable {
    let data: Data
    let httpResponse: HTTPURLResponse
}

/// Downloads a bounded HTTP body chunk-by-chunk via `URLSessionDataDelegate`
/// instead of byte-by-byte async iteration. Leaves redirect handling to the
/// session delegate so origin guards remain active.
final class IPTVBoundedDataDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let initialReserveCap = 8 * 1024 * 1024
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IPTVBoundedDownloadResponse, Error>?
    private weak var task: URLSessionDataTask?
    private var data = Data()
    private var httpResponse: HTTPURLResponse?
    private var finished = false

    private init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    static func download(
        _ request: URLRequest,
        in session: URLSession,
        maximumBytes: Int
    ) async throws -> IPTVBoundedDownloadResponse {
        let receiver = IPTVBoundedDataDownloader(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(request, in: session, continuation: continuation)
            }
        } onCancel: {
            DispatchQueue.global(qos: .utility).async { receiver.cancel() }
        }
    }

    private func start(
        _ request: URLRequest,
        in session: URLSession,
        continuation: CheckedContinuation<IPTVBoundedDownloadResponse, Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let task = session.dataTask(with: request)
        task.delegate = self

        lock.lock()
        guard !finished else {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let (continuation, task) = finishLocked()
        lock.unlock()

        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(with: IPTVBoundedDownloadError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish(with: IPTVBoundedDownloadError.httpStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= Int64(maximumBytes) else {
            finish(with: IPTVBoundedDownloadError.tooLarge)
            completionHandler(.cancel)
            return
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        httpResponse = http
        if http.expectedContentLength > 0 {
            let reserve = min(Int(http.expectedContentLength), min(maximumBytes, Self.initialReserveCap))
            data.reserveCapacity(reserve)
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incomingData: Data) {
        lock.lock()
        guard !finished else {
            let task = self.task
            lock.unlock()
            task?.cancel()
            return
        }
        guard incomingData.count <= maximumBytes - data.count else {
            let (continuation, task) = finishLocked()
            lock.unlock()

            task?.cancel()
            continuation?.resume(throwing: IPTVBoundedDownloadError.tooLarge)
            return
        }
        data.append(incomingData)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: error)
            return
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let result: Result<IPTVBoundedDownloadResponse, Error>
        if let httpResponse {
            result = .success(IPTVBoundedDownloadResponse(data: data, httpResponse: httpResponse))
        } else {
            result = .failure(IPTVBoundedDownloadError.invalidResponse)
        }
        let (continuation, _) = finishLocked()
        lock.unlock()

        continuation?.resume(with: result)
    }

    private func finish(with error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let (continuation, task) = finishLocked()
        lock.unlock()

        task?.cancel()
        continuation?.resume(throwing: error)
    }

    private func finishLocked() -> (CheckedContinuation<IPTVBoundedDownloadResponse, Error>?, URLSessionDataTask?) {
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        httpResponse = nil
        data.removeAll(keepingCapacity: false)
        return (continuation, task)
    }
}
