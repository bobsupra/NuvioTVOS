import Foundation
import AVFoundation

/// AE#154: remote HLS on the loopback path. FFmpeg is built with --disable-network, so its hls
/// demuxer can neither probe a playlist behind a custom AVIO context (no extension / MIME hint)
/// nor fetch a single variant or segment; a non-live m3u8 handed to the loopback path used to die
/// with a bare AVERROR_INVALIDDATA. Remote HLS is AVPlayer's native domain: `load()` reroutes the
/// source onto the `nativeRemoteHLS` bypass instead, and the bypass surfaces the item's legible
/// AVMediaSelectionGroup as `subtitleTracks` so hosts with their own picker (AetherPlayer) see the
/// external WebVTT renditions AVPlayer already renders.
enum RemoteHLSMediaSelection {

    /// Synthetic id base for legible-option tracks on the remote-HLS bypass. Above
    /// `AetherEngine.externalSubtitleTrackIDBase` so the id spaces stay disjoint
    /// (embedded ids are AVStream indices, external ids start at 100_000).
    static let subtitleTrackIDBase = 200_000

    /// Width of that space. The membership test used to be `id >= base`, which silently claimed every
    /// id range added ABOVE it: the live subtitle renditions at 300_000 (AE#359) were routed here and
    /// their selection never reached their own path. An id space needs both ends.
    static let subtitleTrackIDRangeCount = 100_000

    /// Value snapshot of an `AVMediaSelectionOption` (not constructible in tests).
    struct LegibleOption: Sendable, Equatable {
        let displayName: String
        let extendedLanguageTag: String?
        let isDefault: Bool
        let isForced: Bool
        let isSDH: Bool
        /// The rendition's verbatim playlist NAME, when AVFoundation exposes it (#316).
        var playlistName: String?

        init(displayName: String, extendedLanguageTag: String?, isDefault: Bool, isForced: Bool,
             isSDH: Bool, playlistName: String? = nil) {
            self.displayName = displayName
            self.extendedLanguageTag = extendedLanguageTag
            self.isDefault = isDefault
            self.isForced = isForced
            self.isSDH = isSDH
            self.playlistName = playlistName
        }
    }

    /// `AVMediaSelectionOption.displayName` is NOT the rendition's NAME: AVFoundation derives a
    /// LOCALIZED language name from LANGUAGE and ignores NAME entirely. Measured against Apple's own
    /// CMAF master, `NAME="简体中文"` reads back as "Chinese" and an injected `NAME="DE"` as "German".
    /// The verbatim attribute does survive, in `commonMetadata` under the `m3u8/NAME` identifier, and
    /// that is the only stable handle on a rendition the engine declared itself (#316).
    static let playlistNameIdentifier = AVMetadataIdentifier(rawValue: "m3u8/NAME")

    static func playlistName(of option: AVMediaSelectionOption) async -> String? {
        for item in option.commonMetadata where item.identifier == playlistNameIdentifier {
            if let value = try? await item.load(.stringValue) { return value }
        }
        return nil
    }

    /// Identity of an injected rendition: the playlist NAME when it survived, else the display name
    /// (an OS that exposes no `m3u8/NAME` at least still matches renditions whose NAME is a plain
    /// language label). Used for both the dedupe and the selection lookup so they cannot disagree.
    static func injectionKey(_ option: LegibleOption) -> String {
        option.playlistName ?? option.displayName
    }

    /// Reroute only the typed VOD-path misroute, and only for URL sources: custom readers have no
    /// URL for AVPlayer to open, and the AE#140 live raw-path misroute keeps its fail-closed
    /// contract (live hosts choose their own DVR/rejoin options before going native).
    ///
    /// AE#246: the classification can arrive from either open of the same source. The load-time probe
    /// is the usual one, but when that probe failed for an unrelated (transient) reason the loopback
    /// path reopens the URL, and that second open is then the first to read the playlist body. Both
    /// carry the same typed error, so both are answered here; `isLive` needs no guard because the
    /// reader only classifies as `hlsPlaylistOnVODPath` on the non-live path.
    static func shouldReroute(failure: Error?, isCustomSource: Bool) -> Bool {
        guard !isCustomSource,
              let readerError = failure as? AVIOReaderError,
              case .hlsPlaylistOnVODPath = readerError else { return false }
        return true
    }

    /// Map the legible group's options (in group order) onto the public track model. HLS subtitle
    /// renditions are WebVTT by spec on Apple origins; the codec is informational for host UIs.
    ///
    /// #316: `skippingNames` drops the renditions the engine itself injected for host-declared sidecars;
    /// those are already published under their external ids, and listing them twice would offer the same
    /// file as two tracks. The id stays the option's index in the FULL group, because that is what
    /// `selectRemoteHLSSubtitleTrack` indexes back into.
    static func subtitleTrackInfos(from options: [LegibleOption],
                                   skippingNames: Set<String> = []) -> [TrackInfo] {
        options.enumerated().compactMap { i, option in
            guard !skippingNames.contains(injectionKey(option)) else { return nil }
            return TrackInfo(
                id: subtitleTrackIDBase + i,
                name: option.displayName.isEmpty ? "Subtitle \(i + 1)" : option.displayName,
                codec: "webvtt",
                language: option.extendedLanguageTag,
                isDefault: option.isDefault,
                isForced: option.isForced,
                isHearingImpaired: option.isSDH,
                isNativelyRenderedSubtitle: true
            )
        }
    }

    /// #316: fold a freshly surfaced legible group into the published list. The renditions are
    /// authoritative for their own id range and are replaced wholesale on every surfacing, but the
    /// host's load-declared external tracks (registered before the item existed) have to survive it.
    /// Assigning the legible list straight to `subtitleTracks` delisted them a beat after they were
    /// registered, which is why a bypass sidecar looked like it had never been declared.
    static func mergedSubtitleTracks(existing: [TrackInfo],
                                     legible: [LegibleOption],
                                     injectedNames: Set<String> = []) -> [TrackInfo] {
        existing.filter(\.isExternal)
            + subtitleTrackInfos(from: legible, skippingNames: injectedNames)
    }

    /// Group-order ordinal backing a synthetic track id; nil for ids outside the remote-HLS range.
    static func ordinal(forTrackID id: Int) -> Int? {
        guard id >= subtitleTrackIDBase, id < subtitleTrackIDBase + subtitleTrackIDRangeCount else {
            return nil
        }
        return id - subtitleTrackIDBase
    }
}
