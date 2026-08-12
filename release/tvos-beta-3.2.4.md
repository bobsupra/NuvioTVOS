## tvOS Beta 3.2.4

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

Beta 3.2.4 strengthens AI subtitle translation, introduces customizable Home collection templates, and improves catalog browsing and Apple TV presentation.

### AI subtitles and subtitle style

- Sizes translation batches by estimated request bytes and tokens while preserving subtitle cue boundaries and IDs.
- Recovers from oversized or malformed provider responses by splitting batches within a bounded retry budget, honors `Retry-After`, and paces requests by provider and model.
- Stops cleanly on permanent quota, billing, credit, or daily-limit errors while retaining original subtitle text.
- Cancels stale MPV translation requests after seeking or playback completion, so old subtitle results cannot appear after a position change.
- Adds subtitle background controls for color and opacity, rendered consistently by both Aether and MPV playback.

### Home collections and catalog browsing

- Adds ready-to-customize Streaming Services, Studios & Franchises, and Discover by Genre templates to Collections settings.
- Migrates existing Streaming Services collections with recent rails, Crunchyroll, and curated service backdrops without discarding user customization.
- Uses template-aware Home tiles, label handling, focus restoration, and full-bleed navigation for curated collections.
- Reworks TMDB network browsing into a cinematic network view with Popular, Top Rated, and Recent series rails, network identity details, and title backdrops.

### tvOS experience

- Refines TV Details focus, related-title labels, production cards, profile PIN entry, add-profile flow, and Trakt/Simkl connected-state presentation.
- Keeps AI-subtitle status toasts out of trailers and live streams.

### Tests

- Adds regression coverage for AI subtitle batch sizing, response validation, retry limits, provider quota handling, split recovery, MPV cancellation, shared pacing, and live/trailer toast suppression.

### Known issues

- The IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- AI subtitle quality, latency, quotas, and privacy depend on the selected provider and model; subtitle text is sent to that provider only while translation is enabled.
- Catalogs, streams, provider logos, and metadata depend on configured add-ons and upstream services.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
