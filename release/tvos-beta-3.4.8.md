## tvOS Beta 3.4.8

> **Install:** [NuvioTV-3.4.8-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.8/NuvioTV-3.4.8-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 300+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 300+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Native Usenet & NNTP Streaming Playback

- **Native NZB Streaming Playback:** Stream video directly from NZB URLs (`nzbUrl`) from Stremio addons with zero external daemon requirements.
- **Dynamic Connection Scaling:** Scales up to 100 parallel connections, intelligently adapting to what your Usenet provider accepts.
- **Decoupled 4-Second Read-Ahead Buffer:** Optimized read-ahead buffer decoupled from connection speed caps, preventing stream stalls during high-bitrate scenes.
- **Instant Non-Thrashing Seeks:** Eliminated connection thrashing and superfluous preview reads during scrub and seek operations for near-instant seek response.

### Calendar Tab & Follows Integration

- **Dedicated Calendar Tab:** Added new **Calendar** tab (`TVTab.calendar`) displaying upcoming episodes, seasons, and movie release schedules.
- **Merged Follows Model:** Merged manual and automatic follow tracking into a unified calendar feed with quick navigation to Details.
- **Home "Today" Shelf:** Added a dynamic **Today** shelf row directly on the Home screen spotlighting today's calendar releases.

### Smart Credit Skipping & Enhanced Player Controls

- **Movie Credit Auto-Skipping:** Automatically skip closing credits while preserving mid-credit and post-credit scenes.
- **Expanded Player Controls & Settings:** Added granular player controls and quick toggles directly in player menus.
- **Subtitles & Error Diagnostics:** Polished smooth text subtitle outline rendering and accurately classified HTTP access error banners.
- **Seamless Stream Prewarming:** Prewarms Details stream handoffs for near-instant transitions from browsing to playback.

### Home, Details & Top Shelf Polish

- **Configurable Details Sections:** Customize the ordering and visibility of sections on the Details screen to your preference.
- **"All" Hero Rating Source:** Added an unified "All" rating source to the hero banner alongside the Details ratings row.
- **Top Shelf 16:9 Rows:** Redesigned Apple TV Top Shelf with four 16:9 rows and hardened feed cache writes on physical devices.
- **Fast Addon Search:** Streamlined addon search with linear keyboard sizing in stream selectors.
- **MDBList Request Caching:** Deduplicated MDBList requests with 24-hour disk caching.

### AetherEngine 7.51.0 & Audio Shaping

- **AetherEngine 7.51.0 Upgrade:** Upgraded core playback engine with enhanced stability, lifecycle handling, and Apple required-reason privacy manifest declarations (`PrivacyInfo.xcprivacy`).
- **Audio Shaping & Dialogue Lift:** Added dynamic audio shaping support — fold to at most N channels, boost dialogue (centre/mid signal) up to +12 dB, and dynamic range night compression (`night`) with -1 dBFS peak limiting.
- **Sidecar Bitmap Streaming (.sup):** Packetized streaming drainage for PGS sidecar subtitles, eliminating memory spikes on film-length tracks.
- **HLS Lifecycle & Resource Cleanup:** Fixed playlist shift callbacks and request stores to release stopped HLS sessions cleanly.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.

