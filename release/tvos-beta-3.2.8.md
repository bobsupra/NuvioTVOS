## tvOS Beta 3.2.8

> **Install:** [NuvioTV-3.2.8-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.2.8/NuvioTV-3.2.8-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Home performance and smooth navigation

- Eliminates vertical navigation stutter/lag between catalog rows by removing obsolete scroll-tracking state and using non-lazy row containers with pre-mounted card virtualization.
- Optimizes rendering with `Equatable` view conformances (`TVCatalogRow`, `TVCollectionFolderRow`, `TVHeroView`, `CrossfadingBackdrop`, `NuvioMeta`), skipping unnecessary view body re-evaluations during navigation.
- Defers secondary Details screen enrichment by 350ms for instant, fluid screen transitions without main-thread stalls when backing out quickly.
- Improves Collection Folder and Streaming Addon grid browsing with focused outline tabs (`CollectionFolderTabButton`) and locked lateral card entry.

### iCloud settings sync and Simkl integration

- Adds **iCloud Settings Sync** (`ICloudSettingsSyncManager` via `NSUbiquitousKeyValueStore`) to synchronize appearance themes, layout choices, player preferences, and integration keys across all Apple TVs on your iCloud account (**Settings → Advanced → iCloud Sync**).
- Mirrors Simkl access tokens to profile settings so authenticated sessions restore smoothly across devices via iCloud while maintaining Keychain security.
- Speeds up Simkl Continue Watching loading by resolving title metadata in parallel (bounded concurrency of 4) instead of sequential requests.
- Migrates `CollectionsStore` and `LibraryStore` payloads to file-backed `LargePayloadStore` in Application Support/Caches to protect against tvOS preferences size limits.

### AetherEngine, playback, and subtitles

- Updates the bundled AetherEngine stack from 6.7.0 to 6.21.0 and FFmpegBuild from 2.4.0 to 2.4.2.
- Brings upstream playback fixes for live HLS rotation, subtitle delivery and proxying, frame-time telemetry, transport recovery, display-criteria changes, and PGS missing-palette recovery.
- Automatically preserves backend-selected subtitle preferences during stream load, preventing preferred full subtitle tracks from being replaced by empty forced tracks.
- Separates auto-hide and auto-play timers for Next Episode cards and makes the playback debug HUD toggleable in release builds.

### Watched history, Continue Watching, and search

- Manual episode and season actions now create concrete aired-episode history needed for reliable Next Up and new-season suggestions.
- Derives series watched state from aired regular episodes, avoiding unaired episodes and specials.
- Protects Nuvio, Trakt, and Simkl history from incorrectly removing rows owned by another source, with robust Application Support writes and Caches fallback.
- Enriches settled Home cards and search results from full metadata, decoding Stremio logos and preventing "No Results" flickers during search input debouncing.

### Tests

- Runs 173 unit and regression tests with 0 failures across playback policies, Simkl authentication, iCloud settings sync, artwork merging, catalog decoding, and stream discovery.
- Includes updated AetherEngine regression suite and FFmpegBuild tests.

### Known issues

- Catalog and metadata enrichment still depend on configured add-ons and upstream services.
- Horizontal scrolling can still stutter slightly while high-resolution artwork or preview resources are downloading.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
