import Foundation

enum IPTVGuideLoadError: Error { case invalidURL, invalidResponse, httpStatus(Int), tooLarge }

struct IPTVGuideLoader {
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
        let parsing = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let xml = payload.starts(with: [0x1f, 0x8b])
                ? try IPTVGuideGzip.decompress(payload, maximumBytes: IPTVXMLTV.maximumBytes)
                : payload
            try Task.checkCancellation()
            let parsed = try IPTVXMLTV.parse(xml, channelIDs: channelIDs, window: window)
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
}
