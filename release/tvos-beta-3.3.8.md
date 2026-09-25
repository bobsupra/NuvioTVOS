## tvOS Beta 3.3.8

> **Install:** [NuvioTV-3.3.8-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.8/NuvioTV-3.3.8-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 200+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 200+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Native ASS/SSA Typeset Subtitle Engine (`SwiftAssRenderer`)

- **Typeset Subtitle Rendering:** Integrated `SwiftAssRenderer` with `ASSRenderCoordinator.swift`, `ASSRenderedSubtitles.swift`, and `PlayerSubtitleOverlay.swift` to render complex styled ASS/SSA subtitles, typography, karaoke, dialogue styling, and custom font positioning natively in AetherEngine.
- **Dynamic Text & Positioning Overlays:** Refined rectangle parsing, clipping, and coordinate positioning in `SubtitleRectText.swift` to deliver frame-accurate subtitle timing without stutter.

### High-Throughput Stream Caching & MPV Stream Bridge

- **Dynamic Lead Windowing:** Overhauled `PlaybackStreamCacheServer.swift` and `PlaybackStreamCacheManager.swift` with smart forward-lead ranges and proactive chunk prefetching for rock-solid media playback over high-latency networks.
- **MPV Stream Protocol Bridge:** Added `MPVStreamProtocolBridge.swift` to seamlessly connect local cache proxy streams to MPVKit for unified buffering and memory management across both playback backends.

### Playback Error Diagnostics & Telemetry

- **Structured Diagnostic Insights:** Added `PlaybackErrorDiagnostic.swift` to classify stream failures (timeouts, demux errors, network dropouts, codec mismatches) and present actionable, user-friendly diagnostics and recovery paths.
- **Real-Time Performance Telemetry:** Enhanced `PlaybackDebugHUDView.swift` and `SoftwarePlaybackHost.swift` with real-time framerate cadence tracking, bit-depth indicators, active buffer lead depth, and dropped frame metrics.

### Backend Routing, Anime Detection & Picture-in-Picture

- **Intelligent Playback Policy:** Enhanced `PlaybackBackendPolicy.swift` with automatic anime classification and metadata heuristics to intelligently route streams to the optimal engine and subtitle pipeline.
- **PiP Lifecycle Management:** Hardened Picture-in-Picture lifecycle handling and audio session transitions in `PictureInPictureManager.swift` and `PlaybackSessionCoordinator.swift`.

### Full App Localization Catalog (4,000+ New Keys)

- **Comprehensive Multilingual Coverage:** Added over 4,000 translated strings across all major UI components, settings sections, player controls, dialogs, and error messages in `AppLanguageCatalog.json`.
- **Translation Validation Tools:** Added `scripts/check_translations.py` and `scripts/translate_catalog.py` to continuously validate and synchronize localized strings.

### UI, Details & Navigation Polish

- **Async Details Screen:** Implemented asynchronous background loading, season/episode tab transitions, and rich cast/crew credits in `DetailsScreen.swift` and `DetailsViewModel.swift`.
- **Catalog Navigation & Focus Restoration:** Polished horizontal row transitions in `TVCatalogRow.swift`, library views, and native search overlays for fluid 60fps Apple TV navigation.
- **Continue Watching & Sync Refinements:** Streamlined `ContinueWatchingBuilder.swift` and `NuvioSyncService.swift` with robust merge deduplication and instant settings synchronization.

### Tests & Stability

- Automated unit and regression test suites passing with 0 failures across subtitle rendering, playback backend policies, stream caching, remote input, and sync reconciliation.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
