## tvOS Beta 3.2.2

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

Beta 3.2.2 adds opt-in AI subtitle translation, Android-compatible stream badges and Home settings sync, and playback/navigation refinements. Test it with your own add-ons, streams, Google API credentials, display hardware, and Apple TV device.

### AI subtitle translation

- Adds Gemini-powered live translation for text subtitles in AetherEngine and MPVKit. Original text remains on screen until each translated cue is ready, so a slow or failed request does not hide the subtitle.
- Adds an AI Subtitles settings sheet for the Gemini API key, Flash-model choice, target language, automatic activation, and optional removal of hearing-impaired annotations.
- Keeps the API key in the device Keychain and isolates it per profile. Completed translations are cached locally per profile by a hash of the source text and translation settings; neither the key nor source subtitle text is included in account sync.
- Provides a per-playback `AI Translation` switch when automatic activation is off, and shows a small progress indicator while a cue is being translated.

### Streams and playback

- Retains Stremio `behaviorHints.proxyHeaders.request` values and passes them to AetherEngine and MPVKit, including when a remembered direct stream is used for Continue Watching.
- Adds Android TV-compatible stream-badge packs with custom JSON URLs (up to three), the bundled Gold pack shortcut, regular-expression matching, top/bottom placement, optional file-size badges, and optional add-on logos.
- Keeps MPV text-subtitle decoding active behind the translation overlay, while bitmap subtitles stay under MPV’s renderer.

### Home, catalog, and navigation

- Syncs Home catalog order and enabled/disabled state through the shared account payload, merging changes without discarding Android-authored custom row titles.
- Syncs stream-badge settings with Android-compatible profile settings, preferring the mobile settings blob where Android TV stores them.
- Honors a disabled Cinemeta add-on immediately, removing stale built-in rows and placeholders from Home.
- Returns from collection-root Details screens to the collection, preserves Details navigation when selecting titles from person or production browsing, and restores initial collection focus after loading.
- Speeds up search with a shorter input debounce, in-memory query cache, and faster initial result rendering.

### Tests

- Adds regression coverage for Gemini API-key request handling, subtitle translation settings/cache isolation/cleaning, and Stremio proxy request-header decoding and stream merging.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- AI subtitle translation requires a Gemini API key and network access. When enabled, active text subtitle cues are sent directly to Google’s Gemini API; bitmap/image subtitles are not translated. Translation availability, latency, and quality depend on the selected model and the service.
- Provider results, badge-pack contents, and streams depend on configured add-ons and upstream services. Invalid or slow badge URLs can fail to import without affecting playback.
- Physical Apple TV playback, HDMI mode changes, HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live AI translation still need real-device validation; the Apple TV Simulator cannot reproduce those hardware paths or play AV1.
