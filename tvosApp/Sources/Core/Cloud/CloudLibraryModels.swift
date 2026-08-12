import Foundation

// MARK: - Cloud library model
//
// Browses the files a user already has saved in their debrid account
// (Premiumize / TorBox) and plays them through the built-in player. Sits on top
// of the same provider credentials as `Core/Debrid`. Ported from the Android
// app's `core/cloud`.

/// The kind of cloud entry, which decides how its download link is requested.
enum CloudItemType: String {
    case torrent
    case usenet
    case webDownload
    case file
}

/// One playable (or non-playable) file inside a cloud item.
struct CloudFile: Identifiable, Equatable {
    let id: String
    let name: String
    let sizeBytes: Int64?
    let mimeType: String?
    let playable: Bool
    /// A ready direct URL when the provider already exposes one (Premiumize);
    /// otherwise `nil` and the link is requested on demand (TorBox).
    let playbackUrl: String?
}

/// A saved cloud entry (a torrent/usenet/web download or a single file),
/// grouping one or more files.
struct CloudItem: Identifiable, Equatable {
    let providerId: String
    let id: String
    let type: CloudItemType
    let name: String
    let status: String?
    let sizeBytes: Int64?
    let files: [CloudFile]

    /// Stable across providers and item types for use as a SwiftUI id.
    var stableKey: String { "\(providerId):\(type.rawValue):\(id)" }

    var playableFiles: [CloudFile] { files.filter(\.playable) }
}

/// Outcome of turning a cloud file into a playable URL.
enum CloudPlaybackResult {
    case success(url: URL, filename: String?, videoSize: Int64?)
    case missingCredentials
    case notPlayable
    case failed(String?)
}

/// A cloud backend that can list a user's saved items and resolve one to a link.
protocol CloudLibraryProvider {
    var providerId: String { get }
    var displayName: String { get }
    func listItems(apiKey: String) async throws -> [CloudItem]
    func resolvePlayback(apiKey: String, item: CloudItem, file: CloudFile) async -> CloudPlaybackResult
}

// MARK: - Playback bridge

extension NuvioMeta {
    /// A minimal placeholder meta so a raw cloud file can flow through the
    /// player, which is built around `NuvioMeta`. There's no catalog metadata
    /// for an arbitrary account file, so only the id/name/type are meaningful.
    static func cloudPlaceholder(id: String, name: String) -> NuvioMeta {
        NuvioMeta(
            id: id, name: name, description: nil, posterUrl: nil, backgroundUrl: nil,
            logoUrl: nil, imdbId: nil, tmdbId: nil, type: "movie", year: nil, genres: nil,
            rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil,
            writer: nil, certification: nil, country: nil, released: nil
        )
    }
}
