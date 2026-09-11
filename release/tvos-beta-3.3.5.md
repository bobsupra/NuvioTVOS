## tvOS Beta 3.3.5

> **Install:** [NuvioTV-3.3.5-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.5/NuvioTV-3.3.5-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **AltStore / SideStore / Feather Source:** Add `https://raw.githubusercontent.com/bobsupra/NuvioTVOS/main/apps.json` · [Add to AltStore](altstore://source?url=https://raw.githubusercontent.com/bobsupra/NuvioTVOS/main/apps.json) · [Add to SideStore](sidestore://source?url=https://raw.githubusercontent.com/bobsupra/NuvioTVOS/main/apps.json)

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 100+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 100+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### MDBList Integration & List Sync

- **MDBList Authentication:** Added TV PIN / QR-code device pairing workflow with real-time approval polling (`MdbListAuthService.swift`).
- **Custom Lists & Watchlists:** Syncs user custom lists, watchlists, and curated collections into Nuvio TV catalog rows (`MdbListLibraryService.swift`, `MdbListListService.swift`).
- **Progress Scrobbling & Ratings:** Real-time playback scrobbling, watch status sync, and rating updates (`MdbListProgressService.swift`, `MdbListRatingsService.swift`), backed by automated test coverage (`MdbListScrobbleTests.swift`).

### Custom Backend & Server Discovery

- **Self-Hosted Server Support:** Added custom backend endpoint configuration (`ServerConfiguration.swift`, `AuthManager.swift`), allowing users to connect to self-hosted or remote server instances.
- **Server Discovery & Reachability:** Automatic local discovery and reachability validation with smooth authentication fallback (`ServerDiscoveryPolicyTests.swift`).

### Native P2P / Torrent Streaming

- **Direct Torrent & Magnet Streaming:** Embedded local streaming server (`TorrentEngineManager.swift`, `TorrentStreamServer.swift`) enables direct P2P playback on Apple TV without requiring a Debrid service.
- **Live P2P HUD on Buffering Overlay:** Real-time download speed, connected seed count, and active peer count display during stream loading.

### Playback Engine & Buffering Polish

- **Smart Buffering Spinner Policy:** Prevents the loading spinner from popping up during brief connection fluctuations when the video buffer is already full and media is actively rendering (`AetherPlaybackController.swift`).
- **Background Teardown Safety:** Added `BackgroundTeardownSelection.swift` to ensure media resources are cleanly deallocated when exiting playback.
- **In-Player Audio Delay:** Real-time audio track latency calibration directly from player controls.

### Search & Native Keyboard Polish

- **Native Search Focus Lifecycle:** Refined focus transitions between search input, content filters (`All`, `Movies`, `Series`), recent searches, and result grids in `NativeSearchView.swift` and `NetflixSearchView.swift`.

### Tests & Stability

- 302 automated unit and regression tests passing with 0 failures across playback policies, scrobbling, discovery, and catalog decoding.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
