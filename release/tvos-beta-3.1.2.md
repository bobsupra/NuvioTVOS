## tvOS Beta 3.1.2

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Fixed and improved

- Adds an in-app language picker with System default and 34 supported UI languages.
- Completes Settings localization across every supported language, including nested pages, dialogs, descriptions, actions, and option values.
- Applies language, locale, and right-to-left layout changes immediately, while keeping the selected language profile-scoped.
- Improves title details with richer TMDB and Trakt metadata plus production, company, network, cast, and crew browsing.
- Improves stream quality labeling and selection while preserving the playback, Dolby Vision, debrid, and add-on resilience work from Beta 3.1.1.
- Refines profile PIN, account synchronization, discovery, search, library, and metadata behavior throughout the tvOS app.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Native Dolby Vision requires a compatible Apple TV/display chain, Match Dynamic Range, profile 5 or 8 video, and an AVPlayer-compatible audio track. Other combinations use the MPVKit HDR10/PQ fallback.
- Stream availability depends on configured add-ons and upstream servers.
- The Apple TV Simulator cannot play AV1 video. Use H.264 or HEVC for simulator testing; physical Apple TV playback is unaffected by this simulator guard.
- Premiumize has no public open-source device OAuth flow. Paste the account API key unless you configure a private `PREMIUMIZE_CLIENT_ID`.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
