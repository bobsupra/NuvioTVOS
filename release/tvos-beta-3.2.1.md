## tvOS Beta 3.2.1

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

Beta 3.2.1 expands metadata and collection support while carrying a substantial AetherEngine playback reliability update. Test it with your own add-ons, providers, displays, and Apple TV hardware, and include the provider, stream, and reproduction steps in any report.

### Metadata, collections, and details

- Adds provider-aware collection folders for add-on catalogs, TMDB lists/collections/discover/company/network/person sources, and Trakt lists, with pagination, legacy-source promotion, useful source errors, and URL-safe Stremio genre/search extras.
- Adds optional TMDB enrichment with selectable language and modules for artwork, basic metadata, details, credits, episodes, season posters, trailers, recommendations, productions, networks, and collections; the selected settings sync through the shared account settings blob.
- Adds TMDB person cards with profile images, person browsing, production and network browsing, and nested back navigation from Details.
- Adds optional MDBList rating badges for IMDb, TMDB, Rotten Tomatoes, Metacritic, Trakt, Letterboxd, and Audience Score, with provider toggles and transient metadata storage that does not inflate sync snapshots.

### Continue Watching, Up Next, and playback selection

- Trakt and Simkl now use refreshed watched-history/progress data to generate Up Next suggestions more consistently, including fallback data when Trakt omits a show's season breakdown.
- Episodes airing today remain visible when future episodes are hidden and display `AIRS TODAY`; refreshed episode-guide dates override stale stored dates.
- URL-less Continue Watching entries can reuse the last successful direct stream for the same title and episode, while new Up Next rows still resolve a fresh episode stream.

### AetherEngine and FFmpeg

- Upgrades the vendored playback stack to AetherEngine 6.0.1, FFmpegBuild 2.4.0, and LibDovi 2.0.0, including visionOS framework slices and the corrected tvOS 17 package floor.
- Improves native remote-HLS VOD resume and second-open rerouting, adds container chapter publication, opt-in native-video Now Playing ownership, and records display-rate diagnostics.
- Makes wireless AirPlay preserve subtitle renditions when possible, rewrites all recovery loads to the receiver-reachable LAN URL, detects silent HDR-master refusal, and falls back to a compatible media playlist without a reload loop.
- Bounds persistent HTTP ranges, enforces hard backpressure limits, arbitrates source-link priority between video and subtitle readers, adds seek anchoring/pacing/restart recovery, and expands memprobe telemetry and large-allocation diagnostics.
- Prevents software video stalls on decoder `EAGAIN`, verifies declared H.264 interlace against decoded frames before taking the software path, repairs degenerate FLAC STREAMINFO for CoreMedia, and primes E-AC-3 metadata so the first HLS cut can carry valid Atmos/sample-entry information.
- Drains disc/file reads through autorelease pools, tracks disc bytes, preserves the video buffer frontier across seeks, and fixes same-PTS subtitle retention and typed remote-HLS failure handling.

### Subtitles

- Preserves ASS styling for bold, italic, underline, strikeout, color, font face, and font size across SRT, WebVTT, ASS/SSA, and teletext instead of flattening it.
- Carries ASS alignment/position and WebVTT cue settings through embedded, sidecar, prefetch, native-reader, and retained-cue paths, and renders styled/placed text in the software compositor.
- Keeps teletext row placement and blank-row folding stable, and adds standalone WebVTT demux support in FFmpegBuild.

### Tests

- Adds regression coverage for provider-aware collection decoding and URL encoding, Up Next/date behavior, AirPlay playlist choice, container chapters, reader bounds and retention, memory telemetry, software decoder draining, FLAC and E-AC-3 muxing, interlace probing, HLS subtitle pacing/restarts/anchors, ASS/WebVTT/teletext styling and placement, same-PTS retention, native-video Now Playing, and second-open remote-HLS rerouting.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Provider results depend on configured add-ons and upstream services. TMDB, MDBList, and Trakt-backed features require the corresponding user API credentials and may return incomplete metadata or lists.
- Physical Apple TV playback, HDMI mode changes, HDR/Dolby Vision, AirPlay receivers, and Atmos hardware still need real-device validation for this beta; the Apple TV Simulator cannot reproduce those hardware paths or play AV1.
- ASS/SSA custom typesetting and karaoke remain flattened beyond the styling and placement features supported here, and bitmap subtitle OCR remains inherently lossy.
