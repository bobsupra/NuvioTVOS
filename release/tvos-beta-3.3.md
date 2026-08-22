## tvOS Beta 3.3

> **Install:** [NuvioTV-3.3-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3/NuvioTV-3.3-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Cloud Library & remote streaming

- Introduces **Cloud Library** (`CloudLibraryView` and `CloudLibraryService`): browse, index, search, and stream your remote cloud storage and debrid torrent downloads directly within Nuvio TV.
- Adds cloud library synchronization with Nuvio account profiles, categorized folder browsing, poster and metadata resolution, and instant playback through AetherEngine.

### Picture in Picture (PiP) support

- Adds native Apple TV **Picture in Picture (PiP)** support for the Aether playback engine via `AVPictureInPictureController` and `PictureInPictureManager`.
- Features dynamic surface rebinding, video layer swapping, background audio/video playback continuation, and PiP controls on the player chrome.

### Library & Collection overhaul

- Overhauls the **Library** view with powerful new filtering tabs (All, Movies, Series, Continue Watching, Watchlist), sorting options (Recently Added, Name, Rating, Release Date), and refined responsive poster grids.
- Improves focus retention and spatial navigation across multi-row collections, genres, and production company catalogs.

### Player chrome, side panels & audio/subtitles

- Redesigned player side panels for audio tracks, subtitle selections, stream providers, and playback settings.
- Real-time audio delay adjustments, subtitle timing offsets, audio boost, and enhanced subtitle style rendering.
- Refined Next Episode card auto-play deadlines and countdown controls.

### UI styling, PosterCards & translations

- Modernizes `PosterCard` styling with unified badge overlays, progress bars, smooth focus scaling, and theme accent highlights.
- Expands language catalog with additional localizations and improved internationalization support.

### Tests

- Extensive regression and unit test suite including tests for Picture in Picture, Cloud Library sync, Continue Watching reconciliation, and PosterCard styling.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Initial indexing of large Cloud Library or debrid accounts may take a few moments depending on network connectivity.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
