import Foundation

// MARK: - Track Info

struct PlaybackTrackInfo: Equatable {
    let index: Int
    let id: Int
    let type: String
    let title: String
    let lang: String
    let selected: Bool
    /// mpv `external-filename` — the URL a `sub-add`ed track was loaded from,
    /// empty for tracks embedded in the container.
    let externalFilename: String
    /// AVPlayer renders this track outside Nuvio's subtitle overlay, so custom
    /// timing and appearance require a compatibility-renderer handoff.
    var isNativelyRenderedSubtitle: Bool = false
    /// Localized language name for audio cards ("Russian"), empty for subs.
    var languageName: String = ""
    /// Technical summary for audio cards ("AC-3 | 6 ch | 48 kHz"), empty for subs.
    var detail: String = ""
}
