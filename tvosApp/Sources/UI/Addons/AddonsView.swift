import SwiftUI

/// Add-on catalog/stream source. The management UI lives in
/// Settings → Integrations → Add-ons (see `AddonsSettingsSection`).
struct AddonItem: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let version: String
    let logoSystemName: String
    let isOfficial: Bool
    var isInstalled: Bool

    /// Core sources that cannot be removed.
    var isLocked: Bool { id == "cinemeta" || id == "opensubtitles-v3" }

    static let defaults: [AddonItem] = [
        AddonItem(id: "cinemeta", name: "Cinemeta", description: "Official Stremio metadata catalog provider for movies and series.", version: "3.0.4", logoSystemName: "film.fill", isOfficial: true, isInstalled: true),
        AddonItem(id: "opensubtitles-v3", name: "OpenSubtitles v3", description: "Official Stremio subtitle provider for movies and series.", version: "1.0.0", logoSystemName: "captions.bubble.fill", isOfficial: true, isInstalled: true),
        AddonItem(id: "youtube", name: "YouTube", description: "Watch official trailers and free YouTube channels directly inside Nuvio.", version: "2.1.0", logoSystemName: "video.fill", isOfficial: false, isInstalled: true)
    ]
}
