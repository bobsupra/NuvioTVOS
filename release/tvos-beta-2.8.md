## tvOS Beta 2.8

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

### Fixed and improved

- Fixed the account-sync crash caused by large Continue Watching payloads falling back to UserDefaults. Synced progress now remains file-backed and storage failure is reported without terminating the app.
- Continue Watching is republished to Apple TV Top Shelf whenever the active profile loads, restoring the row when its shared snapshot was cleared by an update or signing change.
- Top Shelf Continue Watching cards now start playback directly instead of opening Details.
- URL-less synced and Next Up Top Shelf entries use the same automatic stream resolution as Home cards, with Details available only when no stream can be resolved.
- Top Shelf playback actions survive cold launch, login, and profile selection and continue automatically after the active profile is ready.
- Returning to Nuvio after using another tvOS app restores the last verified playback position instead of accepting MPV's transient final-frame timestamp.
- Player restoration preserves whether playback was playing or manually paused before switching apps.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible sideloading/signing workflow.
- One user has reported video with no audio on a sideloaded Apple TV setup. The issue has not reproduced locally and may depend on the Apple TV audio output, receiver, soundbar, or HomePod configuration.
- Premiumize QR linking remains unavailable until its production OAuth client ID is configured.
- The Apple TV Simulator cannot play AV1 video; use H.264 or HEVC streams instead. Physical Apple TV playback is unaffected by this simulator guard.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the normal subtitle style so dialogue remains in the configured lower safe area.
