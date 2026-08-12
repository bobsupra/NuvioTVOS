tvOS Beta 2.3

Important: if you installed Beta 2.2 or earlier and still run into sign-in/profile issues, delete the old app before installing this build. This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

- Up Next auto-play: near the end of an episode a Liquid Glass card shows the next episode with a 10-second countdown and plays it in place, so you never have to leave the player and pick a stream again. Press Play to start it immediately, or fast-forward to cancel the countdown when you want to watch the credits or a post-credit scene. Turn the countdown off in Settings → Playback → Auto-Play Next Episode.
- Streams now load in parallel: the first add-on's results appear right away and more fill in as each add-on responds, instead of waiting for every add-on before showing anything. A slow or dead add-on no longer holds up the ones that answer quickly.
- Expired stream links recover on their own: when a link expires (the "wrong IP / link expired" slate), the player quietly fetches a fresh link for the same title or episode and resumes where you left off, instead of dropping you back to the stream list. It retries a few times before showing an error.
- Finishing an episode now rolls Continue Watching over to the next episode ("Next Up") instead of dropping the whole series off the row.
- Home catalog layout now follows your account: catalogs you have hidden or reordered on another device are applied on Apple TV.

Known issues (coming later):

- Intro skip is not available yet.
- Trakt integration is not available yet.
- If the app still returns to the Apple TV Home screen after login, please send the Xcode device console or crash log.

Note: the attached IPA is unsigned because no tvOS signing identity is configured on this machine.
