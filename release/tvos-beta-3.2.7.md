## tvOS Beta 3.2.7

> **Install:** [NuvioTV-3.2.7-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.2.7/NuvioTV-3.2.7-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

### Faster catalog browsing

- Reduces catalog-driven UI lag by sharing add-on manifest responses and virtualizing Home rows: the focused row and its nearby neighbours stay mounted while off-screen rows use lightweight placeholders.
- Preserves row geometry, focus, and scroll position while catalog content loads or refreshes, avoiding large SwiftUI rebuilds during navigation.
- Refines vertical Home-row navigation and focus restoration after opening Details or Player.

### Netflix-style search is now the default

- Makes the contributor-built Netflix-style Search screen the default, with its embedded key-by-key keyboard, title list, and poster grid.
- To restore the previous full-width grid with the system keyboard, go to **Settings → Layout & Discovery → Search Style → Classic**.
- Keeps recent searches shared between the two layouts, so changing styles does not lose them.

### Playback and integrations

- Includes AetherEngine renderer and audio-path refinements plus player, stream, Top Shelf, and settings improvements shipped since Beta 3.2.6.

### Tests

- Extends playback-backend policy coverage and includes AetherEngine regression updates.

### Known issues

- Catalog browsing is substantially smoother but still needs real-device testing and refinement with large add-on sets and artwork-heavy rows.
- Horizontal scrolling can still stutter slightly while artwork or video-preview resources are loading.
- Catalogs, streams, provider logos, and metadata depend on configured add-ons and upstream services.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
