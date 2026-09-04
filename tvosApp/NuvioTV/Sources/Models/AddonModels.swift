import Foundation

/// Add-on catalog/stream source used in Settings → Integrations → Add-ons.
struct AddonItem: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let version: String
    let logoSystemName: String
    let isOfficial: Bool
    var isInstalled: Bool

    /// Core sources that cannot be removed (kept for backwards compatibility if needed, defaults to unlocked).
    var isLocked: Bool { false }

    static let defaults: [AddonItem] = [
        AddonItem(id: "cinemeta", name: "Cinemeta", description: "The official addon for movie and series catalogs", version: "3.0.14", logoSystemName: "arrow.triangle.2.circlepath", isOfficial: true, isInstalled: true),
        AddonItem(id: "opensubtitles-v3", name: "OpenSubtitles v3", description: "OpenSubtitles v3 Addon for Stremio", version: "1.0.0", logoSystemName: "captions.bubble.fill", isOfficial: true, isInstalled: true),
        AddonItem(id: "youtube", name: "YouTube", description: "Watch official trailers and free YouTube channels directly inside Nuvio.", version: "2.1.0", logoSystemName: "video.fill", isOfficial: false, isInstalled: true)
    ]
}
