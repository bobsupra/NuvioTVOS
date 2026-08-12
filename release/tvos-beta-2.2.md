tvOS Beta 2.2

Important: if you installed Beta 2 or Beta 2.1 and still run into sign-in/profile issues, delete the old app before installing this build. This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

- Player now prevents the Apple TV screensaver from starting while video is playing or buffering, so waking the device should no longer kick you back out of playback.
- Play/Pause focus is steadier inside the player; toggling pause/resume no longer swaps the button structure and drops focus down to the timeline.
- Audio language and subtitle choices made inside the player are remembered per movie/episode, including subtitle Off and external subtitle URLs, and restored when you reopen playback.
- Preferred Audio is applied when there is no saved per-episode audio choice yet.
- Fixed a real-device login crash caused by large watched-history sync data exceeding the tvOS UserDefaults storage limit.
- Profile avatars now come from the synced Nuvio avatar catalog, and blank avatar IDs sync as null instead of the old local placeholder.
- Who's Watching refreshes live when profile sync writes updated profiles, so imported profile names and avatars can appear without leaving the screen.

Known issues (coming later):

- Intro skip is not available yet.
- Next episode inside the player is not available yet.
- Trakt integration is not available yet.
- If the app still returns to the Apple TV Home screen after login, please send the Xcode device console or crash log.

Note: the attached IPA is unsigned because no tvOS signing identity is configured on this machine.
