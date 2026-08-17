## tvOS Beta 3.2.9

> **Install:** [NuvioTV-3.2.9-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.2.9/NuvioTV-3.2.9-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Local & network media servers (SMB & Jellyfin)

- Adds native **SMB file sharing** support via AetherEngineSMB and SMBClient: discover, browse, index, and stream movies and series directly from local network storage (NAS, Windows, macOS, Linux shares).
- Adds **Jellyfin server integration** (`JellyfinClient`, `JellyfinSessionManager`, `JellyfinLibraryResolver`): connect to your Jellyfin server, authenticate, index libraries, and stream media directly with native Aether playback.
- Implements intelligent filename parsing (`MediaFilenameParser`) to extract show titles, seasons, episodes, years, editions, and video quality tags from local server file hierarchies.
- Adds dedicated management screens under **Settings → Integrations → Local Servers (SMB / Jellyfin)** with secure credential storage and connection testing.

### Poster card and UI improvements

- Refactors `PosterCard` into a modular, clean component hierarchy with unified badge overlays (`PosterCardBadgeOverlay`), progress indicators, and labels.
- Refines focus outline styling, smooth focus scaling, and theme accent highlights across Home, Library, Discover, and Collection folders.
- Improves `ProductionBrowseView` for browsing production company and network catalogs.

### Sync, Simkl, and stream tagging stability

- Hardens Simkl authentication flow with token refresh lifecycle management and Keychain-to-ProfileSettings mirroring for multi-device sync.
- Improves Nuvio account sync reliability with error handling and retry logic.
- Strengthens stream quality tag parsing for 4K UHD, HDR10+, Dolby Vision, Dolby Atmos, IMAX Enhanced, Remux, and HEVC/AV1 codecs.

### Tests

- Runs 176 unit and regression tests with 0 failures across catalog decoding, stream quality tags, SMB authentication, and playback policies.

### Known issues

- Catalog and metadata enrichment still depend on configured add-ons and upstream services.
- Initial indexing of very large SMB shares or Jellyfin libraries may take extra time depending on local network performance.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
