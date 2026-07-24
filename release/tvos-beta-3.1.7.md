## tvOS Beta 3.1.7

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

### Simkl arrives first on Nuvio tvOS

- Ships a native Simkl experience on Apple TV ahead of the official Nuvio client's announced integration.
- Adds Simkl's TV PIN sign-in using your own Client ID, with resumable approval polling, clear credential errors, profile-scoped state, and the long-lived access token stored in Keychain.
- Adds a connected-account dashboard with username, plan, avatar, watched movie/show/episode totals, watched hours, manual refresh, and disconnect controls.
- Lets Simkl be selected independently as the Library source and Watch Progress source, alongside Trakt and Nuvio Sync.
- Imports Simkl watched history, keeps watched and unwatched changes synchronized, exposes Simkl Plan to Watch as the Nuvio library, and routes library mutations back to Simkl.
- Loads Simkl paused movies and episodes into Continue Watching and reports player start, pause, and stop events without sending unnecessary heartbeat scrobbles.

### One-click migration to Simkl

- Adds one-click **Transfer Watch History**, **Transfer Library**, and **Transfer Continue Watching** actions inside the connected Simkl screen.
- Copies data from the active Nuvio profile or a connected Trakt account without deleting existing Simkl history, lists, or progress.
- Preserves watched dates and season/episode numbers, groups episode history into efficient show payloads, and submits older paused items first so the newest item keeps the correct Continue Watching position.
- Shows live percentage progress plus transferred, skipped, and failed totals for every migration.
- Makes the Trakt-to-Simkl path especially simple: connect both accounts, choose Trakt as the source, and copy the selected data with one action.

### Tracking, Home, and artwork reliability

- Keeps Continue Watching snapshots isolated by provider so switching between Nuvio Sync, Trakt, and Simkl cannot display stale rows from another source.
- Prioritizes genuinely paused Trakt playback ahead of generated Next Up suggestions and fetches remote playback inputs concurrently.
- Refreshes Continue Watching when Home becomes active again, even when tvOS kept the Home tab mounted while Settings was open.
- Publishes profile catalog and collection revisions as soon as synced inputs land, cancels stale Home loads, and retries incomplete initial catalog loads.
- Forces one final Home catalog rebuild after all profile-scoped account data has landed, fixing physical Apple TVs that otherwise needed a profile switch before every catalog appeared.
- Preloads landscape artwork before changing a focused poster's aspect presentation, reducing portrait-to-landscape flashes and preserving smooth image transitions.

### Real Apple TV credential entry

- Uses the native tvOS editor for Trakt Client ID, Trakt Client Secret, and Simkl Client ID so typing and choosing Done update reliably on physical Apple TV hardware.
- Keeps the compact glass field design without tvOS's bright duplicate focus layer.
- Holds credential edits as drafts and validates/saves them only when **Connect** is chosen, preventing searches or account resets while the user is still typing.

### Next Episode card

- Temporarily disables automatic next-episode playback, including the end-of-media fallback.
- Changes the Next Episode countdown into a five-second auto-hide timer matching Skip Intro.
- Keeps the card manually playable and brings it back whenever the player controls are shown.

### Tests

- Adds 14 focused Simkl regression tests covering PIN request metadata, pending and approved authentication, credential invalidation, watched-history writes, Plan to Watch writes, scrobble conflict handling, all three migration paths, provider routing, Continue Watching ordering, and cached account statistics.
- Confirms the app builds successfully for an arm64 Apple TV simulator; the generic simulator's unsupported x86_64 LibDovi slice remains an environment limitation rather than an app-source failure.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Simkl and Trakt require user-created API credentials; the Client IDs stay local to the Apple TV and are not included in Nuvio account sync.
- Simkl, Trakt, and Nuvio transfers are additive. They do not remove items that already exist at the destination.
- Automatic next-episode playback is intentionally disabled in this beta; use the manual Next Episode card.
- Recap buttons only appear when the skip-segment provider has recap timing data for that specific episode.
- A reported Hawk/RAWR Netflix Atmos embedded-subtitle stream can still drift out of sync even when the comparable Fusion source is synchronized; this source-specific timestamp issue remains under investigation.
- MPVKit is still required for separate video/audio URLs, audio delay, audio amplification, and ASS Scale mode.
- Stream and subtitle availability depends on configured add-ons and their upstream servers.
- The Apple TV Simulator cannot reproduce physical HDMI mode switches or play AV1 video; validate those paths on Apple TV hardware.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
