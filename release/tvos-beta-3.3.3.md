## tvOS Beta 3.3.3

> **Install:** [NuvioTV-3.3.3-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.3/NuvioTV-3.3.3-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 100+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 100+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Modular Home Screen & Collection Folders

- Deconstructs the monolithic Home layout into modular, high-performance SwiftUI components: `CollectionFolderBrowseView.swift` and `TVCatalogRow.swift`.
- Smoother collection folder browsing with deferred focus restoration to prevent Apple TV remote freezes during transitions.
- Added comprehensive layout settings validation tests (`HomeLayoutSettingsTests.swift`).

### High-Speed TMDB Metadata Caching & Prefetching

- Implements an optimized multi-tier cache and background prefetching architecture in `TmdbDetailsService.swift`.
- Eliminates delay and loading spinners when opening movie and series details screens by serving cached metadata instantly.

### Comprehensive Stream Quality & Codec Parsing

- Overhauled `StreamQualityTags.swift` with deep pattern matching for all modern video and audio formats:
  - **Video Codecs & Quality:** AV1, HEVC/H.265, AVC/H.264, VP9, 4K UHD, 1080p, HDR10+, Dolby Vision (Profiles 5, 7, 8).
  - **Audio Codecs & Spatial Audio:** Dolby Atmos, Dolby Digital Plus (E-AC-3), TrueHD, DTS-HD MA, DTS:X, FLAC, AAC, along with channel layouts (7.1, 5.1, stereo).
  - **Source & Tag Normalization:** Remux, BluRay, WEB-DL, HDR badges, and release grouping.
- Backed by over 500 new unit test assertions in `StreamQualityTagsTests.swift`.

### Reorganized Integration Settings UI

- Refactored `SettingsView.swift` with streamlined category cards for cloud integrations, debrid providers (Real-Debrid, TorBox, Premiumize), and tracking services (Trakt, Simkl).
- Clearer account connection status indicators and improved focus styling for Apple TV remote navigation.

### Details Screen & Player Refinements

- Refined `DetailsScreen.swift` and `DetailsViewModel.swift` with robust episode grouping and season sorting across third-party addon feeds.
- Smoother poster card scaling and focus state management conforming to the native focus engine.
- Polished player loading state animations (`PlayerLoadingOverlay.swift`) during initial stream handshakes.

### Tests & Stability

- 279 automated tests passing across metadata parsing, layout configuration, playback policies, stream discovery, and sync reconciliation.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
