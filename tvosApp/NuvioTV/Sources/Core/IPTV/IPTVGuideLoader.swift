import Foundation

enum IPTVGuideLoadError: Error { case invalidURL, invalidResponse, httpStatus(Int), tooLarge }

struct IPTVGuideBatch: Sendable {
    let programmes: [IPTVProgramme]
    let failedFeedCount: Int
}

struct IPTVGuideLoader {
    private static let maximumConcurrentFeeds = 4
    private static let maximumMergedProgrammes = 250_000
    private static let updateInterval: TimeInterval = 0.3
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func load(url: URL, channelIDs: Set<String>, window: Range<Date>) async throws -> [IPTVProgramme] {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw IPTVGuideLoadError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("NuvioTV", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw IPTVGuideLoadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw IPTVGuideLoadError.httpStatus(http.statusCode) }
        guard http.expectedContentLength <= Int64(IPTVXMLTV.maximumBytes) else { throw IPTVGuideLoadError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard data.count < IPTVXMLTV.maximumBytes else { throw IPTVGuideLoadError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        let payload = data
        let responseHost = http.url?.host?.lowercased()
        let allowEPGShareAliases = responseHost == "epgshare01.online" || responseHost == "www.epgshare01.online"
        let parsing = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let xml = payload.starts(with: [0x1f, 0x8b])
                ? try IPTVGuideGzip.decompress(payload, maximumBytes: IPTVXMLTV.maximumBytes)
                : payload
            try Task.checkCancellation()
            let parsed = try IPTVXMLTV.parse(
                xml,
                channelIDs: channelIDs,
                window: window,
                allowEPGShareAliases: allowEPGShareAliases
            )
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
        onUpdate: @escaping @MainActor @Sendable ([IPTVProgramme]) -> Void
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
                    if hasUnpublishedChanges && lastPublishedAt.map({ now.timeIntervalSince($0) >= Self.updateInterval }) != false {
                        let cumulative = published.values.map(\.programme).sorted(by: Self.programmeOrder)
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
        let programmes = published.values.map(\.programme).sorted(by: Self.programmeOrder)
        if hasUnpublishedChanges { await onUpdate(programmes) }
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
