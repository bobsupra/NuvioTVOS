## tvOS Beta 3.2.8

> **Install:** [NuvioTV-3.2.8-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.2.8/NuvioTV-3.2.8-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

### AetherEngine and playback

- Updates the bundled AetherEngine stack from 6.7.0 to 6.21.0 and FFmpegBuild from 2.4.0 to 2.4.2.
- Brings the upstream playback fixes for live HLS rotation, subtitle delivery and proxying, frame-time telemetry, transport recovery, display-criteria changes, remote HLS readiness, and background teardown.
- Keeps the existing AetherEngine-first playback policy and MPVKit fallback behavior.

### Watched history and Continue Watching

- Manual episode and season actions now create the concrete aired-episode history needed for reliable Next Up and new-season suggestions.
- Series watched state is derived from aired regular episodes, avoiding specials and unaired episodes when marking or unmarking a series.
- Improves title matching across provider-local IDs, IMDb/TMDB aliases, and normalized series names.
- Strengthens durable progress storage with verified Application Support writes and a Caches fallback, and protects Nuvio, Trakt, and Simkl history from incorrectly removing rows owned by another source.

### Catalog and search metadata

- Enriches settled Home cards and search results from full metadata, filling missing posters, backdrops, logos, runtime, status, and external IDs without replacing better source-specific artwork.
- Decodes Stremio logo fields and merges refreshed metadata into the focused card, hero, and search result while preserving focus and row state.
- Adds catalog artwork and search-enrichment regression coverage.

### Tests

- Extends playback policy coverage for watched-series, source reconciliation, episode seeds, and storage behavior.
- Adds `CatalogArtworkMergeTests` for artwork/identifier merging, Stremio logo decoding, and search metadata enrichment.
- Includes the updated AetherEngine regression suite and FFmpegBuild tests shipped with the playback stack update.

### Known issues

- Catalog and metadata enrichment still depend on the configured add-ons and upstream services; large catalogs need further real-device testing.
- Horizontal scrolling can still stutter slightly while artwork or video-preview resources are loading.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
