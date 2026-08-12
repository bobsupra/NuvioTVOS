import Foundation

/// Pure playlist choice for the wireless-AirPlay loopback rewrite (#86, #227). Kept separate and pure
/// so the gate is testable offline, matching `MasterFallbackDecision` / `StartupReadinessGate`.
///
/// #86 rewrites the loopback playback URL to the device's LAN IP (the receiver cannot reach 127.0.0.1)
/// and originally forced the MEDIA playlist for every source, on DrHurt's caveat that "AVPlayer will
/// reject a DV/HDR master playlist on an SDR receiver and will not automatically switch". That caveat is
/// about the HDR/DV variant, not about masters as such, but the blanket downgrade also dropped the
/// master-only `EXT-X-MEDIA:TYPE=SUBTITLES` renditions, so `setNativeSubtitleSelected(track:)` had no
/// legible group to select against and native subtitles never reached any receiver (#227, thatcube).
///
/// **What an Apple TV 4K receiver accepts, measured 2026-07-27** (iPhone 17 Pro, DV P8.1 4K source; the
/// receiver fetches for itself, its own address shows up in the server log):
///
/// | Receiver output format | Master handed over | Result |
/// | --- | --- | --- |
/// | 4K SDR, Match Dynamic Range on | SDR 1080p H.264 | plays, subtitles travel |
/// | 4K SDR, Match Dynamic Range on | SDR 720p HEVC | plays |
/// | 4K SDR, Match Dynamic Range on | 4K PQ, every variation tried | refused |
/// | fixed 4K Dolby Vision | 4K PQ + DV `SUPPLEMENTAL-CODECS` | plays, subtitles travel |
///
/// The receiver's own output mode decides it, exactly as DrHurt wrote in #86 ("TV MUST be in HDR or DV
/// mode to accept any non-SDR content via AirPlay"). Match Dynamic Range does not count: it switches only
/// when tvOS decides the content warrants it and evidently never does for AirPlay content, so a receiver
/// configured that way sits in SDR and refuses an HDR master. That is the same rule the engine already
/// applies locally, where `resolveUseMasterPlaylist` serves media for an HDR source on a panel that is not
/// in HDR mode. Against the parked receiver, dropping the DV `SUPPLEMENTAL-CODECS`, clamping the declared
/// `BANDWIDTH`, omitting `RESOLUTION` and declaring `HDCP-LEVEL=TYPE-1` each changed nothing, and
/// declaring the range as SDR was disproven in #98 Stage 1.5, so there is nothing to gain by dressing the
/// manifest up: what the variant filter wants is a receiver that can present the range.
///
/// The master is therefore always offered. A receiver that will not take it fails silently, with no
/// `-11868`, no failed item, and the rate flickering to `playing` for one tick so even `hasEverPlayed`
/// latches, which is why `AetherEngine`'s progress watchdog is the thing that catches it: five seconds
/// without a segment fetched reloads the LAN media playlist, and that receiver is remembered for the rest
/// of the process so it is never made to wait again. Offering the master a second time to exploit the
/// output switch the first attempt triggers was tried on device and changed nothing but the wait.
enum AirPlayPlaylistDecision {

    /// Which of the loopback server's playlists is handed to a wireless AirPlay receiver.
    enum ReceiverPlaylist: Equatable {
        /// The playlist the session resolved locally, subtitle renditions included.
        case master
        /// `media.m3u8`: no renditions, the manifest every receiver takes.
        case media
    }

    /// - Parameters:
    ///   - servingMasterPlaylist: what `HLSVideoEngine.start()` resolved for local playback. When it is
    ///     already the media playlist there is no master to hand over.
    ///   - sourceIsHDR: the served variant advertises HDR (`HLSVideoEngine.servedSourceIsHDR`). Must be the
    ///     real `VIDEO-RANGE`, not the DV-capability-inflated `sourceIsHDR`, or SDR content on a DV-capable
    ///     device takes the HDR branch and the renditions are dropped for no reason.
    ///   - receiverRefusedHDRMaster: this receiver already failed to start on an HDR master this process.
    ///     Skips the offer and the watchdog wait it would cost again.
    static func playlistForReceiver(
        servingMasterPlaylist: Bool,
        sourceIsHDR: Bool,
        receiverRefusedHDRMaster: Bool = false
    ) -> ReceiverPlaylist {
        guard servingMasterPlaylist else { return .media }
        guard sourceIsHDR else { return .master }
        return receiverRefusedHDRMaster ? .media : .master
    }

    /// Whether the playlist handed to the receiver carries the `EXT-X-MEDIA:TYPE=SUBTITLES` renditions.
    static func carriesSubtitleRenditions(_ playlist: ReceiverPlaylist) -> Bool {
        playlist == .master
    }

    /// Whether a wireless-AirPlay route change has to reload the session so the playback URL is re-resolved
    /// for the new route (#86, and #316 for the second case).
    ///
    /// The `nativeRemoteHLS` bypass was excluded wholesale on the premise that remote HLS is already
    /// receiver-reachable, which held as long as the bypass could only ever play the origin URL. #316 gave
    /// it a second shape: with text sidecars declared at load, the bypass plays a master the engine serves
    /// from its own loopback origin, and that address means nothing on the receiver. So the discriminator
    /// is not the backend, it is where the session's playback URL points.
    ///
    /// Both edges reload, matching the loopback path: engaging swaps the loopback host for the LAN IP,
    /// ending puts the session back on 127.0.0.1 rather than leaving it depending on a LAN address that
    /// outlives the receiver.
    ///
    /// - Parameters:
    ///   - isRemoteHLSBypass: `LoadOptions.nativeRemoteHLS` for the loaded session.
    ///   - bypassServesLoopbackOrigin: a #316 subtitle proxy is mounted, so the bypass is playing the
    ///     engine's rewritten master off the loopback instead of the origin URL. Meaningless off the bypass.
    static func routeChangeNeedsReload(isRemoteHLSBypass: Bool,
                                       bypassServesLoopbackOrigin: Bool) -> Bool {
        guard isRemoteHLSBypass else { return true }
        return bypassServesLoopbackOrigin
    }

    /// The loopback URL rewritten for the receiver: same port and query, the device's LAN IP for the host
    /// (the receiver cannot reach 127.0.0.1), and the path of the chosen playlist. `.master` keeps whatever
    /// the session resolved. The playlists' `EXT-X-MEDIA` and segment URIs are relative, so everything
    /// resolves against the LAN base with no further work.
    static func receiverURL(base: URL, lanIP: String, playlist: ReceiverPlaylist) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.host = lanIP
        if playlist == .media { components?.path = "/media.m3u8" }
        return components?.url
    }
}
