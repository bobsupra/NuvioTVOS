## tvOS Beta 3.3.7

> **Install:** [NuvioTV-3.3.7-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.7/NuvioTV-3.3.7-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 200+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 200+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

> ⚠️ **Important Re-Release Notice:** This updated Beta 3.3.7 build fixes a critical bug where MPVKit was unreachable for remote HTTPS streams (breaking stylized ASS subtitle rendering), resolves a Settings persistence sync issue when switching tabs, and refines Siri Remote seeking gestures.

### Hotfix: MPVKit Remote HTTPS & Stylized ASS Subtitle Rendering
- **Direct HTTPS Capability:** Corrected `PlaybackEngineCapabilities.mpv.supportsDirectHTTPS` to `true`. Previously, MPVKit was marked without direct HTTPS support, causing remote HTTPS sessions to erroneously fall back to AetherEngine and preventing users from selecting MPVKit for complex ASS typesetting.
- **Engine Fallback Routing:** Ensured remote HTTPS streams with `.scale` ASS subtitle modes route to MPVKit cleanly as intended (`PlaybackBackendPolicyTests.swift`).

### Hotfix: Settings Persistence & Sync Flush
- **Instant Push Flushing:** Added `UserDefaults.didChangeNotification` observer and immediate push flushes (`flushPendingPushesNow()`) in `NuvioSyncService.swift`. Navigating away from Settings or backgrounding the app now immediately saves modifications, preventing remote profile sync pulls from overwriting freshly changed local settings.

### Player Controller & Remote Gesture Refinements
- **Discrete Linear Clickpad Seeking:** Directional clickpad clicks perform crisp linear skips (+10s, +20s, +30s) per press, preventing rapid multi-taps from accidentally triggering hold-to-seek acceleration loops.
- **Gesture Conflict Prevention:** Isolated touch host recognition in `RemoteInput.swift` from tap and long-press recognizers, preventing accidental trackpad touch events from interrupting active button seeks.
- **Persistent Controls During Seek:** Player controls and timeline scrubbing previews stay smoothly visible throughout seek actions without flickering.
- **Next Episode Prompt:** Polished the cancel auto-play button styling with a modern tvOS capsule and smooth focus navigation.

### High-Throughput Stream Caching Architecture
- **Local Stream Cache & Proxy Server:** Integrated a resilient local HTTP caching proxy (`PlaybackStreamCacheServer.swift`, `PlaybackStreamCacheManager.swift`, `PlaybackStreamDiskCache.swift`) to pre-buffer media segments onto disk and memory.
- **Configurable Cache Limits & Policies:** Fine-tune maximum stream cache sizes, prefetch margins, and eviction strategies directly in playback settings (`PlaybackCacheSettings.swift`), backed by comprehensive unit tests (`PlaybackStreamCacheTests.swift`).

### Direct Jellyfin & SMB Media Library Indexing
- **Direct SMB Share Indexing:** Faster scanning, metadata extraction, and robust reconnect handling for local SMB file shares (`SMBLibraryIndex.swift`).
- **Jellyfin Library Integration:** Enriched metadata resolution, directory structure traversal, and synchronized watch status with remote Jellyfin instances (`JellyfinLibraryIndex.swift`).

### Intro & Outro Auto-Skip Detection
- **IntroDB Integration:** Automated skip triggers with high-precision timestamp markers (`IntroDBSkipService.swift`) to smoothly skip show intros and recap segments.

### Tests & Stability
- 424 automated unit and regression tests passing with 0 failures across playback backend policy, stream caching, remote input, profile isolation, and sync reconciliation.

### Known issues
- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
