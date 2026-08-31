## tvOS Beta 3.3.2

> **Install:** [NuvioTV-3.3.2-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.2/NuvioTV-3.3.2-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 100+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 100+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### AetherEngine 6.57.0, FFmpegBuild 3.0.0 & LibDovi 2.1.0

- Upgrades vendored **AetherEngine to 6.57.0** and **FFmpegBuild to 3.0.0** with native upstream `AetherLib*` module namespaces and dynamic MPVKit coexistence.
- **AV1 Metal GPU Acceleration:** Replaces heavy CPU `sws_scale` pixel conversion with a session-scoped **Metal YUV GPU shader pipeline** (`MetalYUVConverter.swift`) for 4K AV1 (`YUV420P`, `YUV420P10LE`) to NV12/P010 on Apple TV 4K, drastically cutting CPU load and eliminating dropped frames, with seamless CPU fallback.
- **Stream Recovery & Resilience:** Introduces no-cut stall watchdogs, live spooling, session token management, outage rejoin without DVR, audio rate policies, resampler parameter optimizations, and memory region census pruning.
- Updates **LibDovi to 2.1.0** for hardened Dolby Vision RPU conversion (Profile 7 to Profile 8.1).

### Post-Play Next-Episode & Recommendations Overlay

- Adds a sleek **Post-Play Recommendation Overlay** (`PostPlayRecommendationOverlay.swift`) when credits roll or an episode finishes, showing a countdown timer, episode thumbnail, title, and overview to jump directly into the next episode.
- Managed by `PostPlayRecommendationController` for smooth auto-play countdowns, binge-watching state, and manual dismiss.

### Full App Localization & Multi-Language Support

- Integrates a comprehensive **25,000+ line localized strings catalog** (`AppLanguageCatalog.json`) covering menus, settings, player controls, dialogs, and error messages across international languages.
- Dynamic runtime language selection with instant UI updates matching Apple TV system settings (`AppLanguage.swift`).

### Player UI & Stream Loading

- Added a modern **Player Loading Overlay** (`PlayerLoadingOverlay.swift`) during initial stream discovery, buffering, and audio/video track switches.
- Enhanced **IntroDB Auto-Skip** (`IntroDBSkipService.swift`) with improved interval accuracy, retry logic, and responsiveness.

### Authentication & Re-Auth Flow

- Added **ReauthSheet** (`ReauthSheet.swift`) to seamlessly refresh expired Trakt, Real-Debrid, or Addon sessions without disrupting navigation.

### Details Screen & Library Enhancements

- TV Show episode details resolution: TV shows (types `"tv"`, `"show"`, `"tvshow"`) without pre-loaded manifests display full season/episode pickers with TMDB metadata merging.
- Refined action button styling, cast/crew credit lists, and production company browsing grids.

### Tests & Stability

- Comprehensive unit and regression test coverage including `AuthReauthFlowTests`, `PostPlayRecommendationTests`, `MetalYUVConversionPolicyTests`, `StreamsDiscoveryTests`, `CatalogDecodingTests`, and `DetailsViewModelTests`.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
