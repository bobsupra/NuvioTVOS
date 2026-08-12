## tvOS Beta 2.9.1

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Fixed and improved

- Playback now follows the active tvOS audio route's preferred channel layout instead of preferring the source file's original layout unconditionally.
- When a TV, HDMI receiver, soundbar, or HomePod route cannot report a compatible multichannel layout, playback falls back safely to stereo instead of risking video with no usable audio.
- Includes all navigation, catalog, library, profile, PIN, and playback improvements from Beta 2.9.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible sideloading/signing workflow.
- The audio-route change still needs broad verification on physical Apple TVs connected to different TVs, receivers, soundbars, and HomePods.
- Search bottom-edge presentation still needs verification on a physical Apple TV after the latest scroll-layout changes.
- Profile PIN secrets are stored locally in the Apple TV Keychain and do not sync to other devices.
- Premiumize QR linking remains unavailable until its production OAuth client ID is configured.
- The Apple TV Simulator cannot play AV1 video; use H.264 or HEVC streams instead. Physical Apple TV playback is unaffected by this simulator guard.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the normal subtitle style so dialogue remains in the configured lower safe area.
