## tvOS Beta 3.2.5

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

Beta 3.2.5 refines immersive Home previews, makes Siri Remote focus transitions more deliberate, and fixes catalog access for tokenized Stremio add-ons.

### Focused posters and trailer previews

- Adds a dedicated **Focused Poster** setting to expand a settled Home card into a backdrop after a configurable 2–15 second delay.
- Keeps focused-poster backdrops independent from trailer playback, so the visual expansion can be used with trailers disabled.
- Plays a resolved video trailer inside an expanded Home card when trailers are enabled, retaining the backdrop until video is ready and stopping playback immediately when focus changes.
- Adds an opt-in **Trailer Preview Sound** setting; previews remain muted by default.

### Home, collections, and focus

- Keeps pinned collection rows above catalog rows even when a saved catalog order is applied.
- Preserves collection-browser state, focus, watched badges, and long-press actions when opening title Details and returning to the collection.
- Improves Home row-entry locks and focus restoration when returning from overlays or switching tabs.
- Shows the profile picker after a long background period when an explicit profile selection is required.
- Gives PIN pads a stable initial focus target and reliable Menu-button dismissal.

### Details and episodes

- Routes Siri Remote focus through Details sections in order instead of allowing spatial jumps across Cast, related titles, networks, production, and comments.
- Restores sensible vertical navigation between Play, season pills, episodes, and Creator and Cast.
- Opens series on the Continue Watching episode when available, otherwise on the next unwatched episode.

### Stremio catalog access

- Preserves query parameters from configured add-on URLs when constructing catalog requests, so tokenized manifests continue to authenticate correctly.

### Tests

- Adds regression coverage for catalog URLs that carry configured manifest query parameters.

### Known issues

- The IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Trailer availability and playback depend on YouTube metadata and upstream stream resolution; previews may be unavailable for some titles.
- Catalogs, streams, provider logos, and metadata depend on configured add-ons and upstream services.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
