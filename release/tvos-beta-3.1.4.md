## tvOS Beta 3.1.4

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Fixed and improved

- Improves the new AetherEngine player with more predictable Siri Remote focus, timeline-to-transport navigation, seeking, and playback state updates.
- Improves embedded and external subtitle discovery, selection, rendering, and timing, including HLS subtitle-track refreshes and styled-text handling.
- Uses the MPVKit compatibility player when native HLS subtitles need Nuvio's subtitle appearance controls.
- Fixes saved progress after fast-forwarding so an older pre-seek position cannot overwrite the new playback position.
- Marks movies and episodes watched at 90%, matching Android TV, and sends the completed state to Trakt without waiting through the credits.
- Mirrors manual watched and unwatched actions to Trakt history and makes **Sync Now** refresh Trakt watch progress, user information, and cached statistics.
- Makes Home catalog loading resilient to partial provider failures, retries missing catalogs, and automatically refreshes incomplete results.
- Keeps catalog and Trakt updates scoped to the active profile to prevent stale results from being applied after switching profiles.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- MPVKit is still required for separate video/audio URLs, audio delay, audio amplification, and ASS Scale mode.
- Stream and subtitle availability depends on configured add-ons and their upstream servers.
- The Apple TV Simulator cannot play AV1 video; use a physical Apple TV for AV1 testing.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
