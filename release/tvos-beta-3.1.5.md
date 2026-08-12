## tvOS Beta 3.1.5

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Trakt watched history and sync

- Treats Trakt as the authoritative watched-history source whenever a Trakt account is connected, independently of whether resume progress comes from Trakt or Nuvio Sync.
- Imports complete watched movie and episode snapshots from Trakt during startup and **Sync Now**, including paginated episode-history fallback when Trakt's show response is incomplete.
- Reconciles watched state using timestamps plus IMDb, TMDB, Trakt, and catalog aliases so the same title cannot split into conflicting local and remote records.
- Preserves newer local changes, retries pending watched/unwatched mutations, and uses durable tombstones so stale Nuvio Sync or partial Trakt responses cannot resurrect removed history.
- Updates episode cards, watched badges, Continue Watching, and Nuvio's durable watched store immediately after reconciliation while keeping profile-scoped work from crossing account switches.
- Keeps a short-lived optimistic Trakt progress checkpoint so Home and details use the latest position immediately instead of waiting for Trakt to echo the scrobble.

### Resume and playback continuity

- Stores resume state separately for every episode using show identity, season, episode, and episode ID when available; one episode can no longer inherit another episode's position.
- Prevents completed episodes and movies from resuming stale progress that predates their watched timestamp.
- Protects an explicit seek from stale backend samples for the settling window, saves it synchronously on exit, and serializes Trakt progress reports so an older request cannot win.
- Fixes immediate re-entry from a Continue Watching card and the details-page Resume → source-selection flow without requiring a five-second wait.
- Uses the exact active episode when recovering from a failed stream instead of falling back to the show's latest generic progress row.

### Episodes, sources, audio, and subtitles

- Adds a focusable episode eye button plus a long-press **Mark as watched** / **Mark as unwatched** action, using the same durable local and Trakt path as playback completion.
- Keeps a manually chosen source for the next episode by strongly preferring matching Stremio `bingeGroup` data and then the same add-on/provider when no binge group is available.
- Carries the current audio and subtitle choice through seamless episode changes. Episode-specific external subtitle URLs are rebound by label and language instead of being reused incorrectly.
- Preserves subtitle delay, audio delay, and audio amplification during seamless next-episode playback.
- Makes saved track matching validate language/name metadata instead of trusting reused numeric track IDs from a different episode.

### Skip segments

- Keeps a skipped Intro, Recap, or Ending segment hidden for the remainder of the current playback item, including while the seek is still settling.
- Ignores late skip-segment responses from the previous episode after an episode change.
- Replaces the ambiguous duration/countdown text with **Ends at mm:ss** for Intro, Recap, and Ending cards.

### Player presentation and controls

- Redesigns Episodes and Sources as right-aligned liquid-glass panels with a translucent backdrop, rounded border, and safer edge spacing.
- Prevents long source and episode metadata from clipping outside rows and gives multi-line text enough vertical layout priority.
- Keeps focus inside the active panel as source results arrive and disables the underlying player remote handlers, preventing panel navigation from seeking or revealing player controls.
- Waits for Apple TV's frame-rate and HDR/Dolby Vision display-mode handshake before starting AetherEngine direct HLS playback.
- Keeps MPV paused through the HDMI mode switch, reattaches video, allows the landing frame to settle, and only then starts playback at the requested start or resume position.
- Correctly waits for refresh-rate changes even when the television was already in HDR mode.

### Tests

- Adds regression coverage for IMDb/TMDB watched-identity matching, Trakt snapshot behavior, independent episode resume points, watched-vs-resume timestamps, stale remote progress, and manually selected next-episode source continuity.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Recap buttons only appear when the skip-segment provider has recap timing data for that specific episode.
- A reported Hawk/RAWR Netflix Atmos embedded-subtitle stream can still drift out of sync even when the comparable Fusion source is synchronized; this source-specific timestamp issue remains under investigation.
- MPVKit is still required for separate video/audio URLs, audio delay, audio amplification, and ASS Scale mode.
- Stream and subtitle availability depends on configured add-ons and their upstream servers.
- The Apple TV Simulator cannot reproduce physical HDMI mode switches or play AV1 video; validate those paths on Apple TV hardware.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
