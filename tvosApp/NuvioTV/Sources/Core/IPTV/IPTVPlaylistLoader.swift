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
    let guideURL: URL?
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
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, Self.isWebURL(finalURL) else {
            throw IPTVPlaylistLoadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw IPTVPlaylistLoadError.httpStatus(http.statusCode) }
        if http.expectedContentLength > Int64(Self.maximumBytes) { throw IPTVPlaylistLoadError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard data.count < Self.maximumBytes else { throw IPTVPlaylistLoadError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try Self.parsePlaylist(data: data, sourceID: sourceID, baseURL: finalURL)
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
        let guideURL = playlists.lazy.compactMap { playlist -> URL? in
            for raw in [playlist.tvgURL, playlist.xTvgURL].compactMap({ $0 }) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.contains(","),
                      let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL, isWebURL(url) else { continue }
                return url
            }
            return nil
        }.first
        return IPTVLoadedPlaylist(channels: channels, guideURL: guideURL)
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
