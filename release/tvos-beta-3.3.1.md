## tvOS Beta 3.3.1

> **Install:** [NuvioTV-3.3.1-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.1/NuvioTV-3.3.1-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 100+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 100+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

> ⚠️ **Important Re-Release Notice:** This updated build fixes a critical issue where TV shows were missing episode details and appearing as movies on the Details screen. If you installed the earlier 3.3.1 package, please reinstall/update to this build.

### Hotfix: TV Show episode details & type classification

- Fixes an issue where TV series metadata (types `"tv"`, `"show"`, `"tvshow"`) were misclassified as non-series or Live TV, causing TV shows to display as movies with missing season/episode pickers.
- Enhances `DetailsViewModel.mergeEpisodes` to reliably merge TMDB episode metadata and overview details with Cinemeta/Stremio video arrays.

### AetherEngine 6.47.0 & FFmpegBuild 2.4.3 upgrade

- Updates **AetherEngine** to **6.47.0** and **FFmpegBuild** to **2.4.3** with isolated `AetherLib*` module namespaces and full MPVKit dynamic coexistence.
- Hardens **Dolby Vision RPU conversion** (Profile 7 to Profile 8.1) with robust multi-packet framing detection (Annex-B vs length-prefixed NAL units) and fail-safe base-layer fallbacks.
- Adds real-time **startup progress reporting** (`StartupProgressEngine`, `PlaybackErrorInfo`), live HLS reopen handling, origin request concurrency budgeting, no-cut stall watchdogs, and rate-limit backoff ladders.
- Integrates stereo and silent audio bridge encoders for seamless audio continuity during stream transitions.

### Details screen & media discovery

- Extensively enriches the **Details screen** (`DetailsScreen.swift`, `TmdbDetailsService.swift`): trailer playback, interactive cast & crew credits, production studio navigation, and high-DPI backdrop crossfading.
- Season and episode picker optimizations with instant episode overview previews and watched status indicators.

### Player controls, subtitles & audio

- Redesigned player controls overlay with live subtitle offset adjustments, audio delay sliders, and audio boost options.
- Enhanced subtitle styling, PGS bitmap palette extraction, and AI subtitle translation state resilience.
- Stream source selection enhancements with cached-only badges and smart binge-watching auto-play source retention.

### Tests

- Comprehensive unit and regression test suite coverage across NuvioTV and AetherEngine.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
