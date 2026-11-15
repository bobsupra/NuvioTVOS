import Foundation

/// Whether the source list may open a connection to a stream just because the
/// viewer's focus rests on it, so playback starts faster if they pick it.
///
/// Many add-ons (AIOStreams, Comet, Torrentio, MediaFusion and others) don't
/// list files: their links point back at the add-on, which resolves the
/// stream on request by adding the torrent to the debrid account or fetching
/// the NZB for Usenet. Requesting one of those links has real side effects
/// (it fills the debrid or NzbDav library and uses indexer quota), so it must
/// only happen when the viewer picks the source.
enum FocusedStreamWarmPolicy {
    /// - Parameters:
    ///   - backgroundPreFetchEnabled: Settings > Playback > Background pre-fetch.
    ///   - addonManifestURLs: the installed stream add-ons.
    static func mayWarm(
        url: URL,
        backgroundPreFetchEnabled: Bool,
        addonManifestURLs: [URL]
    ) -> Bool {
        guard backgroundPreFetchEnabled,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let addonHosts = Set(addonManifestURLs.compactMap { $0.host?.lowercased() })
        return !addonHosts.contains(host)
    }
}
