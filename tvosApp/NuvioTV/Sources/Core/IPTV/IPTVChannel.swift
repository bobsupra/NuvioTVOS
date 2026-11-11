import Foundation
import CryptoKit

/// A channel imported from one configured source. The source ID must be a
/// locally generated, stable identifier, not a playlist URL or credential.
struct IPTVChannel: Identifiable, Equatable {
    let id: String
    let sourceID: String
    let name: String
    let streamURL: URL
    let guideID: String?
    let logoURL: URL?
    let group: String?
}

enum IPTVChannelImporter {
    /// Resolve channel and logo links relative to the final playlist URL.
    /// Ignore malformed entries without discarding other channels. Channel IDs
    /// do not expose raw stream URLs, which often include provider credentials.
    static func channels(
        from playlists: [IPTVPlaylistParser.Playlist],
        sourceID: String,
        baseURL: URL?
    ) -> [IPTVChannel] {
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var result: [IPTVChannel] = []
        var seen = Set<String>()
        for playlist in playlists {
            for stream in playlist.streams {
                guard let url = webURL(stream.url, relativeTo: baseURL) else { continue }
                let title = nonempty(stream.title) ?? nonempty(stream.tvgName)
                guard let title else { continue }
                // Xtream provides a stable ID; M3U has no guaranteed unique ID,
                // so preserve distinct labels/groups that share one URL.
                let parts: [String]
                if let providerID = nonempty(stream.providerID) {
                    parts = [sourceID, "provider", providerID]
                } else {
                    parts = [sourceID, "m3u", url.absoluteString, title, nonempty(stream.tvgID) ?? "", nonempty(stream.groupTitle) ?? ""]
                }
                let identity = parts.map { "\($0.utf8.count):\($0)" }.joined()
                let digest = SHA256.hash(data: Data(identity.utf8))
                let id = digest.map { String(format: "%02x", $0) }.joined()
                guard seen.insert(id).inserted else { continue }
                result.append(IPTVChannel(
                    id: id, sourceID: sourceID, name: title, streamURL: url,
                    guideID: nonempty(stream.tvgID),
                    logoURL: stream.tvgLogo.flatMap { webURL($0, relativeTo: baseURL) },
                    group: nonempty(stream.groupTitle)
                ))
            }
        }
        return result
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func webURL(_ value: String, relativeTo baseURL: URL?) -> URL? {
        guard let text = nonempty(value), let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
