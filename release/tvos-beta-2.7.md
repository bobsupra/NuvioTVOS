## tvOS Beta 2.7

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

### Fixed and improved

- Continue Watching cards now start the last watched stream directly instead of opening Details first.
- Synced Continue Watching and Next Up entries without a saved URL now resolve and smart-select a stream in place, with a loading screen and Details fallback when no stream is available.
- Account changes made on Android TV, tvOS, or another client refresh when Apple TV returns to the foreground.
- Entering an add-on manifest URL now installs, normalizes, and syncs it immediately instead of leaving it as a local-only text-field value.
- Enabled Stremio add-ons that advertise subtitle support, including SubMaker, are now queried alongside the built-in OpenSubtitles provider.
- Subtitle providers load progressively after playback begins, so resumed playback and early stream selections continue receiving results without reopening the player.
- The subtitle panel updates live while providers respond and displays a fetching indicator.
- Selecting an external subtitle before the media file finishes loading now queues and applies the selection safely afterward.
- Subtitle-provider requests now time out after 15 seconds instead of holding the player indefinitely.
- Manual subtitle browsing shows every available language; preferred subtitle languages appear first in saved priority order and the rest follow alphabetically.
- Preferred audio tracks appear first, with remaining languages listed alphabetically while preserving each language's original track order.
- ASS/SSA positioning and style tags no longer force dialogue to the top of the screen; text subtitles use the app's configured bottom margin and appearance.
- BetterPosters and other poster-only catalog entries now provide correctly cropped Home backdrops without expanding or shifting the Home layout.
- Home row materialization clamps stale focus indexes safely after catalog changes.
- The Apple TV Simulator filters known AV1 streams and rejects an unlabeled AV1 file safely instead of crashing in the simulated Metal renderer.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible sideloading/signing workflow.
- One user has reported video with no audio on a sideloaded Apple TV setup. The issue has not reproduced locally and may depend on the Apple TV audio output, receiver, soundbar, or HomePod configuration.
- One account has been reported to crash during post-login sync after several add-ons were installed on PC. The issue has not reproduced locally; the affected Apple TV crash report and add-on list are still required.
- Premiumize QR linking remains unavailable until its production OAuth client ID is configured.
- The Apple TV Simulator cannot play AV1 video; Beta 2.7 skips or rejects those streams and requires H.264 or HEVC instead. Physical Apple TV playback is unaffected by this simulator guard.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the normal subtitle style so dialogue remains in the configured lower safe area.
