## tvOS Beta 3.5.2

> **Install:** [NuvioTV-3.5.2-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.5.2/NuvioTV-3.5.2-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> **Join the community:** [NuvioTVOS Discord](https://discord.gg/2YnNr2xmnJ) — chat, get help, report bugs, and share ideas.

### Plex Media Server Integration

- **Native Plex Integration:** Connect your Plex Media Server directly to Apple TV with multi-user Plex Home support and watch status synchronization.
- **Intro & Credits Skip Markers:** Automatically skips intros and credits using Plex timeline markers.
- **Plex Stream Labels & Audio Tracks:** Streams reflect native Plex version names, quality tiers, and track titles.
- **Top Shelf & Continue Watching:** In-progress Plex media merges seamlessly into Continue Watching and the Apple TV Top Shelf carousel.

### Unified Library "Servers" Tab

- **All Media Servers in One Hub:** Added a dedicated **Servers** tab inside Library aggregating **Plex**, **Jellyfin**, and **SMB** shares into one unified browsing interface.

### AI-Powered "Surprise Me" & "For You" Catalogs

- **Smart "Surprise Me" Discovery:** Instant movie and series recommendations powered by your watch history across connected trackers (Trakt, Simkl, AniList, MAL).
- **Custom AI Engine Choice:** Select from leading models (Gemini Flash, OpenRouter, DeepSeek, Qwen) in Settings.
- **AI-Curated "For You" Rows:** Dynamically generated recommendation rows on the Home screen, including dedicated rows for Anime Movies and Anime Series.

### Episode Shuffle Play

- **Series Shuffle Play:** Effortlessly shuffle TV show episodes from the series Details screen or from within the in-player Episodes panel.
- **Persistent State:** Shuffle state is preserved across app sessions and integrates cleanly with Continue Watching.

### AIOStreams & JavaScript Add-on Plugins

- **Embedded AIOStreams Scraper:** Direct integration for AIOStreams scraper configurations.
- **On-Device JS Plugins:** Execute Nuvio JavaScript add-on plugins locally on Apple TV with synced stream filtering.

### Ambient Mode Screen Saver

- **Cinematic Idle Display:** Automatically transitions to full-bleed backdrop artwork and metadata highlights when idle, dismissing instantly on any remote interaction.

### Playback Finish Time & Stream Recommendations

- **Estimated Finish Time:** Displays the exact wall-clock completion time for the current movie or episode in the player HUD.
- **Nuvio Recommended Streams:** Ranks streams with prominent badges highlighting the best overall pick and best pick per resolution, factoring in seeders and throughput.
- **Stream Name Filtering:** Filter out unwanted keywords, tags, or release groups in the source selector.

### Navigation, Stream Resolution & Stability Polish

- **Canonical Stream ID Resolution:** Automatically resolves non-canonical TMDB identifiers (`tmdb:...`) to canonical IMDb stream IDs, ensuring seamless stream resolution and prefetching.
- **Source Picker Focus Retention:** Preserves remote focus on the selected source while slower add-ons continue loading in the background.
- **Playback Exit Hardening:** Exits the player cleanly when media finishes with no subsequent episode in queue.
- **Single-Episode Duration Validation:** Scopes expired link detection strictly to the active episode.
- **Jellyfin Rate-Limit Recovery:** Respects server `Retry-After` headers and prevents orphaned pagination states.
- **Session & Keychain Isolation:** Explicitly purges session tokens on sign-out and secures Trakt credentials in Apple TV Keychain.
- **Updated Translations:** Comprehensive localization updates across all supported languages.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
