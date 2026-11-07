## tvOS Beta 3.5.0

> **Install:** [NuvioTV-3.5.0-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.5.0/NuvioTV-3.5.0-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 300+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 300+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### AutoSubSync & Sync by Audio

- **Automatic Subtitle Alignment (AutoSubSync):** Aligns out-of-sync add-on subtitles with embedded video subtitles using lightweight MKV Cues index range requests without downloading the entire file. Supports individual offsets for scenes, recaps, and openings.
- **Sync by Audio (AetherEngine):** When no embedded subtitle reference exists, AutoSubSync analyzes speech patterns in the soundtrack via the shared audio tap to dynamically align subtitle lines and continuously track delay adjustments.
- **InSight AutoSubSync Tab:** On-screen sync status, manual "Sync Now" trigger, diagnostic timeline breakdown, and customizable auto-sync tolerance in Settings.

### Siri Remote Custom Gestures & Expert Mode

- **Ready-Made Remote Gestures:** Seamless gestures in the player (off by default, enabled in the player's **•••** settings panel under **Gestures**). Includes 8 non-interfering shortcuts: long swipe right/left for chapters, swipe right & back to skip intro/outro, swipe left & back for -30s, swipe up & back to toggle subtitles, swipe down & back for next audio track, tap-and-hold center for chapters, and circle clockwise for next episode.
- **Expert Mode & Gesture Recording:** Record custom gestures for 11 distinct player actions, draw unique touchpad shapes, tune recognition sensitivity, and test with live visual finger feedback.
- **Non-Swallowing Input Architecture:** Gestures without assigned actions preserve native tvOS remote navigation without conflict.

### Watch Party Sidebar Toggle & UI Settings

- **Configurable Sidebar Tab:** Added a dedicated toggle in **Settings → General** to show or hide the Watch Party tab in the main sidebar.
- **Personalized Profile Cloud Sync:** Automatically backs up and syncs custom profile background artwork and custom add-on display names across devices.

### MDBList Catalog Integration & Filters

- **MDBList Source Support:** Deep integration for MDBList lists and curated catalogs directly in Collections.
- **Dynamic Catalog Filters:** Filter collections by score, year, release type, and sort criteria with smooth focus navigation.

### Enhanced Trailer Playback & IMDb Sources

- **Native IMDb Trailer Streams:** Resolves and streams high-definition trailer sources directly from IMDb for rapid, reliable trailer previews on Details screens.

### Calendar & Details Screen Hardening

- **Focus-Safe Calendar Navigation:** Pressing Back from the event list now returns focus reliably to the active event date without triggering unintended sidebar transitions.
- **Day Panel Scroll Stabilization:** Prevented Day Panel focus handoffs from competing with programmatic carousel scrolling.
- **Enriched Titles:** Resolved TMDB and IMDb technical IDs into clean, localized media titles across calendar cards and follow feeds.
- **Long-Series Episode Guide Index Clamping:** Clamped scroll index boundaries when switching seasons or updating provider IDs on series with large episode guides.

### Top Shelf & Playback Core Refinements

- **Remote Library Sources on Top Shelf:** Added remote library items to the Apple TV Top Shelf carousel and poster feed.
- **Shared App Group Resolution:** Hardened App Group container resolution across both signed and sideloaded installations.
- **AetherEngine Dolby Vision & HDR Polish:** Enhanced Dolby Vision Profile 7 FEL handling, HDR stream transitions, and segment packet pipeline stability.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
