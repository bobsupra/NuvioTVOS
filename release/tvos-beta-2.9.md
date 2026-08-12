## tvOS Beta 2.9

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Fixed and improved

- Backing out after a stream has started returns to Details. If a selected stream never starts, Back returns to the stream picker at the same movie or episode so another source can be chosen immediately.
- Home, Search results, Discover catalogs, and Library retain the selected card outline while Details is open and restore focus without flashing another control or jumping up a row after repeated entries.
- Discovery locks its parent Search and Recent Searches controls during the Details transition, leaving only the selected card focusable.
- Add-on Home catalogs now load additional pages from the originating manifest and preserve required genre parameters, instead of pagination working only for Cinemeta.
- Search and Discover catalog cards remain below their fixed controls while scrolling.
- The Recent Searches Clear action now uses Liquid Glass, is fully focusable, and appears after the final recent-search chip.
- Library adds content-type and genre filters and uses consistent poster sizing, labels, and focus treatment.
- tvOS 27 now shows the active account name and avatar in the sidebar header.
- On earlier tvOS versions, selecting the profile tab opens profile switching directly; the redundant standalone profile-management page has been removed.
- Profile name and avatar editing now live in Settings and sync after an explicit account edit.
- Four-digit profile PINs now work: PINs are validated, stored securely in the Apple TV Keychain, required when entering a protected profile, and can be enabled, changed, or removed from Settings.
- Signed-out profile state is reset cleanly, and automatic profile entry no longer bypasses PIN-protected profiles.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible sideloading/signing workflow.
- Search bottom-edge presentation still needs verification on a physical Apple TV after the latest scroll-layout changes.
- Profile PIN secrets are stored locally in the Apple TV Keychain and do not sync to other devices.
- One user has reported video with no audio on a sideloaded Apple TV setup. The issue has not reproduced locally and may depend on the Apple TV audio output, receiver, soundbar, or HomePod configuration.
- Premiumize QR linking remains unavailable until its production OAuth client ID is configured.
- The Apple TV Simulator cannot play AV1 video; use H.264 or HEVC streams instead. Physical Apple TV playback is unaffected by this simulator guard.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the normal subtitle style so dialogue remains in the configured lower safe area.
