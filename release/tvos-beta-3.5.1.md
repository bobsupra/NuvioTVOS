## tvOS Beta 3.5.1

> **Install:** [NuvioTV-3.5.1-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.5.1/NuvioTV-3.5.1-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> **Join the community:** [NuvioTVOS Discord](https://discord.gg/2YnNr2xmnJ) — chat, get help, report bugs, and share ideas.

> 🎉 **Thank you for 300+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 300+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### AniList & MyAnimeList Integrations

- **Anime Account Synchronization:** Direct integration for both AniList and MyAnimeList. Effortlessly sync anime watching progress, episode updates, personal scores, and library tracking.
- **On-Device Credential Security:** Client IDs and authentication tokens remain securely isolated and stored directly on the Apple TV without remote proxying.

### Native Top Tab Navigation

- **Apple TV Native Top Tabs:** Added a new navigation layout option in **Settings → Appearance** to switch from the sidebar to native Apple TV top tab bar navigation.

### Custom Subtitle Fonts & Style Presets

- **Custom Subtitle Fonts:** Add and load your own custom subtitle fonts (`.ttf`, `.otf`) sent locally from another device or linked via URL (**Settings → Subtitles**).
- **Style Preset Management:** Create, reorder, and customize subtitle style presets.
- **ASS Subtitle Rendering Fix:** Resolved an issue where ASS subtitles could intermittently stay blank after playback starts.
- **Improved AutoSubSync Candidates:** Enhanced candidate selection scoring for automatic subtitle alignment.

### Stream List Customization & Live Preview

- **Stream List Styling & Preview:** Customize how stream sources look and format with an interactive live preview.
- **Locally Cached Stream Badges:** Stream provider badges and artwork are cached locally on Apple TV for faster rendering.

### Continue Watching Labels & Long Title Scrolling

- **Continue Watching Label Controls:** Added display options for Continue Watching cards (**Focused Only**, **Always**, or **Hidden**) in **Settings → Appearance**.
- **Marquee Title Scrolling:** Long titles on focused cards now automatically scroll horizontally so full titles remain readable without truncation.

### Player Speed Controls & Episode Spoiler Protection

- **Granular Playback Speed:** Fine-tuned speed controls added directly to player settings menus.
- **Episode Spoiler Masking:** Configurable settings to obscure episode thumbnails and descriptions until watched.

### Multi-Source External Hero Ratings & Top Shelf Polish

- **External Hero Ratings:** Added support for external rating sources (IMDb, Rotten Tomatoes, AniList, MyAnimeList, and TMDB) with configurable order and provider switches.
- **Top Shelf Feed & Remote Protection:** Protected remote library refreshes, refined feed composition, and stabilized Top Shelf carousel playback.

### Playback, Pre-buffering & Navigation Hardening

- **Pre-buffering Background Isolation:** Preparing the next episode in the background no longer halts actively playing P2P torrent or Usenet streams.
- **Details Back-Navigation Stabilization:** Eliminated intermittent crashes when exiting Details and prevented quick Back presses during transitions from ejecting to the Home screen.
- **Video Loading Frame Fix:** Loading backdrop no longer misaligns or displaces video frames during playback startup.
- **Keychain Persistence:** Secured Trakt credentials with persistent Keychain storage.
- **Debrid Cache Resilience:** Preserves stream availability when cache status is unknown.
- **Watch Party Stability:** Hardened room lobby handling and participant connection states.
- **Updated Translations:** Expanded localized labels and native translations across all supported languages.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
