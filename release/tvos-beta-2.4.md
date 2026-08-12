tvOS Beta 2.4

Important: this IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

- IntroDB skip intro and skip ending are now available in the player, with a 5-second countdown before the button hides with the controls.
- Skip cards now sit on the left side, return with the player controls after hiding, and can be focused from the progress bar alongside the Next Episode card.
- Next Episode focus is fixed during end credits, including the case where the controls are open.
- Holding the Siri Remote skip buttons now keeps seeking, and the seek step defaults to 15 seconds.
- Playback settings now let you choose the seek step: 5, 10, 15, 30, or 60 seconds.
- Continue Watching now keeps shows in the row when you quit during end credits instead of deleting the series card.
- New aired episodes now show as "New Episode" in Continue Watching. Upcoming episodes stay visible with their air date, and release-day episodes remain locked until the next day if the stream has not arrived yet.
- Trakt connection surfaces are wired through the Nuvio backend flow so tvOS can fetch or start a Trakt login from Settings.
- Profile avatar changes now persist after saving, and the Change Avatar tab uses the same Liquid Glass button treatment as the login buttons.
- Subtitle preview positioning now matches the player placement more closely.

Known issues:

- The attached IPA is unsigned because no tvOS signing identity is configured on this machine.
