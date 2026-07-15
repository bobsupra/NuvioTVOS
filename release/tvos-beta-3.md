## tvOS Beta 3

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

### Fixed and improved

- MPV audio now uses an AVFoundation sample-buffer renderer instead of the failing AudioUnit/RemoteIO callback path on affected Apple TVs.
- Playback remains audible when Apple TV Sound Format is set to Automatic with Dolby Atmos enabled, while `auto-safe` still lets tvOS choose a compatible stereo or multichannel layout.
- MoltenVK video output is enabled in the same custom MPVKit build, fixing the black screen introduced by the first AVFoundation audio test build.
- Failed audio initialization no longer silently falls back to video-only playback.
- Skip Intro, Skip Ending, and Next Episode cards are real focusable SwiftUI buttons, so Select clicks reach their actions reliably.
- Loading a replacement episode clears the previous file's timeline until MPV publishes a coherent new sample, preventing stale end-of-episode overlays.
- Home mirrors its manually positioned catalog rows into native scroll state so tvOS can collapse the Home tab pill consistently with Search and Library.
- Includes all navigation, catalog, library, profile, PIN, and playback improvements from Beta 2.9.1.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible sideloading/signing workflow.
- The AVFoundation audio and MoltenVK video combination still needs broad verification on physical Apple TVs connected to different TVs, receivers, soundbars, and HomePods.
- Automatic/Dolby Atmos output compatibility does not imply Dolby Atmos bitstream passthrough; tvOS controls the final output route and format.
- Home tab-pill collapse behavior still needs final verification on a physical Siri Remote.
- Profile PIN secrets are stored locally in the Apple TV Keychain and do not sync to other devices.
- Premiumize QR linking remains unavailable until its production OAuth client ID is configured.
- The Apple TV Simulator cannot play AV1 video; use H.264 or HEVC streams instead. Physical Apple TV playback is unaffected by this simulator guard.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the normal subtitle style so dialogue remains in the configured lower safe area.
