## tvOS Beta 3.1.8

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

This beta includes a large synchronization and Continue Watching overhaul. Please test it with your own Nuvio Sync, Trakt, and Simkl setup. If something does not work, message the maintainer with what you expected, what happened, and which provider you selected so it can be reproduced and fixed faster.

### Simkl synchronization reliability

- Fixes Simkl library and watched-history imports that could return no usable titles by decoding the nested movie, show, and anime objects used by Simkl's real API response.
- Invalidates the old broken Simkl item/history caches and performs a full history refresh when Simkl reports removals, preventing deleted titles from remaining watched locally.
- Selects Simkl as the watch-progress source when it is connected unless the user already made an explicit source choice, so a connected account no longer appears ready while scrobbles are silently routed elsewhere.
- Rounds scrobble progress to Simkl's accepted precision, refreshes playback after successful scrobbles, retries temporary per-user write-lock collisions, and exposes the latest scrobble result in diagnostics.
- Paces Continue Watching transfers to Simkl's write limit and counts items in Simkl's `not_found` response as rejected instead of reporting false success.
- Adds Simkl support for MAL, AniDB, AniList, Kitsu, and TVDB identifiers, including the correct anime scrobble container.
- Makes whole-series unwatch requests remove watched seasons without deleting the title's Simkl watchlist entry.
- Reduces expensive account-stat requests by refreshing them only after an explicit action and gates profile refreshes on Simkl's account-change watermark.

### Nuvio Sync, Trakt, and source isolation

- Tracks which provider confirmed each watched mark and shows checkmarks only for the selected Nuvio Sync, Trakt, or Simkl source.
- Prevents Nuvio Sync from uploading a Trakt or Simkl-owned library, watched history, or progress snapshot into the Nuvio account.
- Migrates existing profiles to the connected tracker when no source was stored, while preserving every source the user selected manually.
- Persists optimistic Trakt and Simkl playback checkpoints across app relaunches, covering the delay before a provider publishes a new resume position.
- Fixes movie progress uploads by omitting invalid null season/episode fields and requeues previously rejected movie rows once.
- Uploads only locally changed raw progress rows and deletes remote rows only after an explicit removal, preventing a limited rendered list from erasing valid progress created on another device.

### Continue Watching and Next Up

- Stores raw watch progress in a durable per-profile ledger before metadata or display filtering, so temporary add-on failures and unknown runtimes no longer discard synced history.
- Separates metadata rendering from synchronization and retries unresolved titles after Home and add-on catalogs are ready.
- Pages Continue Watching beyond the first 20 titles while keeping the most recent page lightweight for cold starts and Top Shelf.
- Keeps only the newest resumable episode per series, prevents duplicate-card crashes, and gives actual playback priority over a Next Up suggestion for the same title.
- Uses a consistent 90% completion rule, preserves completed episodes as Next Up seeds, and avoids suggesting unreleased episodes.
- Rebuilds the rendered row after cache eviction while keeping the underlying synced history intact.
- Lets a removed card stay hidden across provider refreshes and retires Nuvio Sync progress remotely; new playback automatically makes the title eligible again.

### Continue Watching controls and diagnostics

- Adds a long-press menu with **Go to details**, **Play manually**, **Start from beginning**, and **Remove** actions.
- Opens manual playback on the exact episode represented by the card and keeps its resume point unless **Start from beginning** is chosen.
- Shows a Liquid Glass loading state while poster artwork is in flight and keeps the static placeholder for titles with no artwork URL.
- Adds on-device diagnostics for raw progress sync, Continue Watching row construction, and the most recent Simkl scrobble.
- Adds advanced test-history controls that can seed a large account to exercise paging and remove only those seeded rows afterward.

### Tests

- Adds focused regression coverage for provider attribution, durable progress, completion and Next Up rules, paging, cache-eviction recovery, movie re-upload, dismissal scoping, Simkl source selection, nested API decoding, scrobble cache invalidation, progress precision, anime identifiers, safe series unwatch, and accurate transfer results.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- This build has been compiled for a generic physical tvOS target, but provider and playback behavior still needs testing on real Apple TV hardware with real accounts.
- Simkl and Trakt require user-created API credentials; Client IDs stay local to the Apple TV and are not included in Nuvio account sync.
- Automatic next-episode playback remains intentionally disabled; use the manual Next Episode card.
- Stream, subtitle, metadata, and recap availability still depends on configured add-ons and their upstream providers.
- The Apple TV Simulator cannot reproduce physical HDMI mode switches or play AV1 video.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
