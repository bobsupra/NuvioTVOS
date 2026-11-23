import Foundation

enum IPTVGuideLoadError: Error { case invalidURL, invalidResponse, httpStatus(Int), tooLarge }

struct IPTVGuidePayload: Sendable {
    enum Body: Sendable {
        case data(Data)
        case file(IPTVGuideTemporaryFile)
    }

    let body: Body
    let byteCount: Int
    let responseURL: URL?
}

final class IPTVGuideTemporaryFile: @unchecked Sendable {
    let url: URL

    init() throws {
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuvio-iptv-guide-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: candidate.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        url = candidate
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

struct IPTVGuideBatch: Sendable {
    let programmes: [IPTVProgramme]
    let failedFeedCount: Int
}

struct IPTVGuideLoader {
    private static let maximumConcurrentFeeds = 2
    private static let maximumMergedProgrammes = 250_000
    private static let updateInterval: TimeInterval = 1.5
    static let maximumTransferBytes = 128 * 1024 * 1024
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func load(url: URL, channelIDs: Set<String>, window: Range<Date>) async throws -> [IPTVProgramme] {
        try Task.checkCancellation()
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw IPTVGuideLoadError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("NuvioTV", forHTTPHeaderField: "User-Agent")
        let response = try await IPTVGuideDataReceiver().load(request, in: session)
        try Task.checkCancellation()
        let payload = response
        let responseHost = payload.responseURL?.host?.lowercased()
        let allowEPGShareAliases = responseHost == "epgshare01.online" || responseHost == "www.epgshare01.online"
        let parsing = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let parsed: [IPTVProgramme]
            if try IPTVGuideGzip.isGzip(payload.body) {
                let (xmlFile, xmlByteCount) = try IPTVGuideGzip.decompress(
                    payload.body,
                    maximumBytes: IPTVXMLTV.maximumXMLBytes
                )
                try Task.checkCancellation()
                parsed = try withExtendedLifetime(xmlFile) {
                    try IPTVXMLTV.parse(
                        contentsOf: xmlFile.url,
                        byteCount: xmlByteCount,
                        channelIDs: channelIDs,
                        window: window,
                        allowEPGShareAliases: allowEPGShareAliases
                    )
                }
            } else {
                try Task.checkCancellation()
                switch payload.body {
                case .data(let data):
                    parsed = try IPTVXMLTV.parse(
                        data,
                        channelIDs: channelIDs,
                        window: window,
                        allowEPGShareAliases: allowEPGShareAliases
                    )
                case .file(let file):
                    parsed = try withExtendedLifetime(file) {
                        try IPTVXMLTV.parse(
                            contentsOf: file.url,
                            byteCount: payload.byteCount,
                            channelIDs: channelIDs,
                            window: window,
                            allowEPGShareAliases: allowEPGShareAliases
                        )
                    }
                }
            }
            try Task.checkCancellation()
            return parsed
        }
        return try await withTaskCancellationHandler {
            let result = try await parsing.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            parsing.cancel()
        }
    }

    func load(
        urls: [URL],
        channelIDs: Set<String>,
        window: Range<Date>,
        onUpdate: @escaping @MainActor @Sendable ([IPTVProgramme]) async -> Void
    ) async throws -> IPTVGuideBatch {
        guard !urls.isEmpty else { return IPTVGuideBatch(programmes: [], failedFeedCount: 0) }

        // Keep the earliest advertised feed as the deterministic winner for duplicate slots.
        var nextIndex = 0
        var failedFeedCount = 0
        var published: [ProgrammeKey: (feed: Int, programme: IPTVProgramme)] = [:]
        var lastPublishedAt: Date?
        var hasUnpublishedChanges = false

        try await withThrowingTaskGroup(of: (Int, [IPTVProgramme]?).self) { group in
            func enqueue(_ index: Int) {
                let url = urls[index]
                group.addTask {
                    do {
                        return (index, try await self.load(url: url, channelIDs: channelIDs, window: window))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, nil)
                    }
                }
            }

            while nextIndex < min(urls.count, Self.maximumConcurrentFeeds) {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                if let result {
                    var changed = false
                    for programme in result {
                        let key = ProgrammeKey(channelID: programme.channelID, start: programme.start)
                        if let existing = published[key] {
                            if existing.feed > index {
                                published[key] = (index, programme)
                                changed = true
                            }
                        } else if published.count < Self.maximumMergedProgrammes {
                            published[key] = (index, programme)
                            changed = true
                        }
                    }
                    let now = Date()
                    hasUnpublishedChanges = hasUnpublishedChanges || changed
                    if urls.count > 1 && hasUnpublishedChanges && lastPublishedAt.map({ now.timeIntervalSince($0) >= Self.updateInterval }) != false {
                        let snapshot = published.values.map(\.programme)
                        let sorting = Task.detached(priority: .utility) {
                            try Task.checkCancellation()
                            return snapshot.sorted(by: Self.programmeOrder)
                        }
                        let cumulative = try await sorting.value
                        try Task.checkCancellation()
                        await onUpdate(cumulative)
                        lastPublishedAt = now
                        hasUnpublishedChanges = false
                    }
                } else {
                    failedFeedCount += 1
                }

                if nextIndex < urls.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }
        }

        try Task.checkCancellation()
        let snapshot = published.values.map(\.programme)
        let sorting = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return snapshot.sorted(by: Self.programmeOrder)
        }
        let programmes = try await sorting.value
        try Task.checkCancellation()
        guard failedFeedCount < urls.count else {
            throw IPTVGuideLoadError.invalidResponse
        }
        return IPTVGuideBatch(programmes: programmes, failedFeedCount: failedFeedCount)
    }

    private struct ProgrammeKey: Hashable {
        let channelID: String
        let start: Date
    }

    private static func programmeOrder(_ lhs: IPTVProgramme, _ rhs: IPTVProgramme) -> Bool {
        if lhs.channelID != rhs.channelID { return lhs.channelID < rhs.channelID }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.title < rhs.title
    }
}

private final class IPTVGuideDataReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let spoolThresholdBytes = 4 * 1024 * 1024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IPTVGuidePayload, Error>?
    private weak var task: URLSessionDataTask?
    private var data = Data()
    private var temporaryFile: IPTVGuideTemporaryFile?
    private var writer: FileHandle?
    private var receivedBytes = 0
    private var responseURL: URL?
    private var receivedHTTPResponse = false
    private var finished = false

    func load(_ request: URLRequest, in session: URLSession) async throws -> IPTVGuidePayload {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(request, in: session, continuation: continuation)
            }
        } onCancel: {
            DispatchQueue.global(qos: .utility).async { self.cancel() }
        }
    }

    private func start(
        _ request: URLRequest,
        in session: URLSession,
        continuation: CheckedContinuation<IPTVGuidePayload, Error>
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
            finish(with: IPTVGuideLoadError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish(with: IPTVGuideLoadError.httpStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= Int64(IPTVGuideLoader.maximumTransferBytes) else {
            finish(with: IPTVGuideLoadError.tooLarge)
            completionHandler(.cancel)
            return
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        responseURL = http.url
        receivedHTTPResponse = true
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
        guard incomingData.count <= IPTVGuideLoader.maximumTransferBytes - receivedBytes else {
            let (continuation, task) = finishLocked()
            lock.unlock()

            task?.cancel()
            continuation?.resume(throwing: IPTVGuideLoadError.tooLarge)
            return
        }

        do {
            if writer == nil, receivedBytes + incomingData.count <= Self.spoolThresholdBytes {
                data.append(incomingData)
            } else {
                if writer == nil {
                    let file = try IPTVGuideTemporaryFile()
                    let fileWriter = try FileHandle(forWritingTo: file.url)
                    try fileWriter.write(contentsOf: data)
                    temporaryFile = file
                    writer = fileWriter
                    data.removeAll(keepingCapacity: false)
                }
                try writer?.write(contentsOf: incomingData)
            }
            receivedBytes += incomingData.count
            lock.unlock()
        } catch {
            let (continuation, task) = finishLocked()
            lock.unlock()

            task?.cancel()
            continuation?.resume(throwing: error)
        }
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
        let result: Result<IPTVGuidePayload, Error>
        do {
            guard receivedHTTPResponse else { throw IPTVGuideLoadError.invalidResponse }
            let body: IPTVGuidePayload.Body
            let byteCount = receivedBytes
            if let writer {
                try writer.close()
                self.writer = nil
                guard let file = temporaryFile else { throw IPTVGuideLoadError.invalidResponse }
                temporaryFile = nil
                body = .file(file)
            } else {
                body = .data(data)
            }
            result = .success(IPTVGuidePayload(body: body, byteCount: byteCount, responseURL: responseURL))
        } catch {
            result = .failure(error)
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

    private func finishLocked() -> (CheckedContinuation<IPTVGuidePayload, Error>?, URLSessionDataTask?) {
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        if let writer {
            try? writer.close()
            self.writer = nil
        }
        temporaryFile = nil
        data.removeAll(keepingCapacity: false)
        return (continuation, task)
    }
}
