## tvOS Beta 3.5.3

> **Install:** [NuvioTV-3.5.3-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.5.3/NuvioTV-3.5.3-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> **Join the community:** [NuvioTVOS Discord](https://discord.gg/2YnNr2xmnJ) — chat, get help, report bugs, and share ideas.

### Native IPTV & Electronic Programme Guide (EPG)

- **Browsable Programme Guide:** Added a full native Electronic Programme Guide (EPG) grid with multi-feed loading, channel categories, and programme timelines.
- **Multi-Feed Guide Merging:** Intelligently aggregates and synchronizes schedule data from multiple XMLTV guide feeds.
- **Per-Source Channel Preferences:** Configure, order, and toggle channel visibility individually per configured IPTV source.
- **Settings Toggle:** Enabled in **Settings → Live TV** to display the dedicated **Live TV** tab in the main navigation.

### Plex Media Server Multi-Library Scalability

- **Server Sync Limit Partitioning:** Shared 150,000-item ceiling across all libraries of a server, preventing high memory peaks and unexpected terminations on massive libraries.
- **Per-Library Storage Serialization:** Each library is saved to its own isolated file on a background serial queue, keeping the main actor fluid. Automatically migrates older monolithic files on first launch.
- **Connection Retry Resilience:** Automatic request retries (up to 2x) for server page queries that experience network timeouts or socket disconnects.
- **On-Demand Title Refresh:** Automatically queries for newly added media when opening a stream list.

### Anime & Metadata Discovery (AniList, MyAnimeList & Kitsu)

- **Community Reviews:** Read user reviews and critiques from AniList and MyAnimeList directly inside the anime Details screen.
- **Contextual Search Menu:** Long-press on any catalog card to trigger instant **"Find on AniList / MyAnimeList / Kitsu"**.
- **Native Kitsu & MAL Titles:** Open titles from Kitsu and MyAnimeList using their native metadata, localized titles, and cover artwork.
- **Voice Actor Filmographies:** View voice actor profiles and related roles directly from AniList cast cards.
- **Season Chains & Clean Tabs:** Formats merged season tabs cleanly as `"Season N"`, preserves subsequent seasons after movie entries in One Title, and stabilizes background backdrop blur.
- **Asynchronous Ratings:** Preserves rating badges as they arrive in the background without layout shift.

### Core Animation & Navigation Smoothness (PR #463)

- **Core Animation Engine:** Details screen, catalog rows, Home rows, and the episode strip are now driven by Core Animation for fluid, stutter-free navigation.
- **Row Title Alignment:** The active card remains positioned directly beneath the row title, scrolled natively by the tvOS Focus Engine.
- **Memory Leak Fix:** Resolved an issue where tab switches leaked ~40 MB of memory per switch.
- **Focus Outlines & Restoration:** Restored consistent tvOS focus borders and reliable focus restoration across Details and Home.

### Playback Engine, Usenet & Subtitles

- **Usenet Read-Ahead Caching:** Prefetches stream chunks to disk so scrubbing or jumping forward into Usenet media begins immediately with zero buffering stalls.
- **Dynamic Subtitle Language Upgrades:** Automatically promotes playback to a higher-ranked subtitle language if one arrives late from an add-on.
- **MPVKit Polish:**
  - Buffered indicator accurately reflects the exact cache boundary.
  - Track lists only rebuild when track inventory changes.
  - Live streams remain open beyond 5 minutes without premature disconnects.
  - Playback continues seamlessly during Control Center or Siri overlays.
- **Aspect Ratio Adaptability:** Video properly fills wide-aspect Apple TV display configurations.
- **Source Badges:** Custom stream badges rendered in-app with official brand marks or optional SF Symbols, decimal file size formatting, and full-card badge rows.

### AIOStreams & On-Device Plugins (r2)

- **Uncapped Addons:** Removed the previous 15-addon cap per AIOStreams configuration.
- **Usenet Retention:** Preserves Usenet streams returned by plugins without dropping them.
- **Configurable Node.js Memory Limits:** Added settings for Node memory allocation (Apple TV Automatic, 1024 MB, 768 MB, 512 MB).
- **V8 ARMv8.0 Snapshot:** Enhanced compatibility for Apple TV HD and Apple TV 4K 1st gen, including `Intl.Segmenter` break iterators.

### Authentication, Profiles & Collections

- **Short Device Code Sign-In:** Authenticate quickly using a short alphanumeric code on your phone or computer (matching the Android TV workflow).
- **Sign-Out Confirmation:** Confirmation modal before signing out to prevent accidental session loss.
- **Sidebar Profile Switcher:** Re-enabled quick profile switching from the sidebar and isolated settings storage per profile.
- **Rewatch Resume:** Resuming previously watched movies from Continue Watching opens cleanly from the recorded position.
- **Collection Ordering:** Pinned collections on Home strictly respect the user's custom sort order.
- **Privacy & Diagnostics:** Caches Trakt ISO8601 date formatters and redacts sensitive stream and subtitle URLs from diagnostic logs.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
