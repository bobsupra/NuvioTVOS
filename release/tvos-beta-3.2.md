## tvOS Beta 3.2

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

Beta 3.2 is a broad reliability and polish release spanning Home, metadata, Continue Watching, synchronization, details, and playback. Please test it with your own add-ons and providers—especially on physical Apple TV hardware—and report the stream, provider, and steps needed to reproduce any problem.

### Home, catalogs, and profiles

- Holds the Home transition behind the profile switch cover until the new profile's rows are ready, preventing content and focus from assembling under the user.
- Adds loading skeleton rows, avoids automatic retries for permanently failing add-ons, and lets Home catalog settings hide, restore, and reorder both add-on and built-in Cinemeta rows.
- Improves add-on settings with manifest artwork, a direct uninstall action, and synchronized removal.
- Fixes grid and row mode transitions, vertical focus restoration, sidebar behavior, full-bleed backdrops, and poster geometry across Home and Search.
- Adds a URL-keyed poster disk cache with bounded storage and network timeouts, while keeping missing-artwork placeholders stable instead of spinning indefinitely.
- Persists profile avatar catalogs and retries cold-launch rate limits, and resets category scroll position when moving between Settings sections.
- Refreshes focused non-Cinemeta hero metadata to recover missing runtime and ongoing status while preserving the source add-on's artwork and description.
- Accepts Stremio cast, director, and writer fields as either arrays or comma-separated strings so an optional metadata shape cannot discard the entire catalog page.

### Continue Watching and synchronization

- Moves large progress and Simkl caches out of `UserDefaults` into file-backed storage, including startup migration and cleanup, to avoid oversized tvOS preferences.
- Reconciles confirmed Nuvio Sync deletions without treating an ambiguous empty response as permission to erase local progress, and preserves unsent or concurrently changed rows.
- Queues and rate-limits provider pulls, refreshes stale account state on foreground and Home re-entry, and reports expired credentials as a sign-in requirement without logging users out for ordinary offline errors.
- Scopes rendered Continue Watching caches to the active profile and memoizes large decoded progress ledgers for faster Home rebuilds.
- Makes episode watched actions clear the rendered card, raw ledger, and optimistic provider checkpoint immediately without disturbing other episodes.
- Adds batch mark-watched and unwatch actions for a full season with a single local/provider update.
- Lets Up Next prefer either the furthest episode reached or the most recently watched episode.
- Tightens New Episode and New Season badges to real post-watch releases, sorts new drops by air date, and filters unreleased episodes using their full release date.
- Retires stale Simkl paused rows when cards are removed or an episode is marked watched, with improved cache invalidation and file cleanup.

### Details, metadata, and navigation

- Adds Simkl community rating, vote count, rank, drop rate, and More Like This recommendations, with fallback between Simkl, Trakt, and TMDB.
- Resolves Simkl recommendation identifiers before opening them and adds a nested Details back stack so Back returns to the previous recommended title.
- Hydrates missing related-title posters and restores episode focus after stream selection.
- Adds season-wide watched controls and updates episode progress and watched badges immediately.
- Opens the stream picker directly in a loading state and transfers focus to the first result as soon as streams arrive.

### Playback, audio, and subtitles

- Upgrades AetherEngine from 5.14.1 to 5.23.3 and FFmpegBuild from 2.1.3 to 2.2.0.
- Fixes HEVC streams that could freeze at 00:00 when codec parameters arrive in-band and improves hardware/software route selection.
- Keeps slow VOD seeks anchored to the requested position, improves tail and end-of-media recovery, and lets seek-to-end playback restart cleanly.
- Improves HLS and live playback cadence, low-latency playlist reloads, startup time, reconnect recovery, backpressure, memory use, and HEVC transport-stream fallback.
- Strengthens E-AC-3 JOC Atmos detection and confirmation, fixes lingering audio after player teardown, and expands EAC3, FLAC, and live AAC fallback paths.
- Converts PGS, DVB, and DVD bitmap subtitles into a native rendition for PiP, AirPlay, and external displays while improving PGS seek landing, clear events, and subtitle packet memory limits.
- Preserves track selection across AirPlay and background reloads, adds disk-aware whole-film prebuffering, and improves deinterlacing and software-decoder recovery.
- Makes source and episode switches close the panel immediately, show a labeled loading state until playback begins, and use the same default source ordering as Details.

### Tests

- Adds regression coverage for flexible Stremio people fields, watched-progress cleanup, Up Next selection, remote-deletion reconciliation, unsent-row retention, release-date filtering, new-release badge semantics, and Simkl paused-row retirement.
- Expands AetherEngine coverage for Atmos confirmation, audio teardown, HEVC signaling and parameter sets, live cadence and backpressure, slow seeks, PGS/OCR subtitles, route recovery, cold starts, and HLS target duration.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Provider and playback behavior still needs testing on real Apple TV hardware with real accounts, HDMI displays, HDR modes, and Atmos receivers.
- Simkl and Trakt require user-created API credentials; Client IDs stay local to the Apple TV and are not included in Nuvio account sync.
- Automatic next-episode playback remains intentionally disabled; use the manual Next Episode card.
- Stream, subtitle, metadata, and recap availability still depends on configured add-ons and their upstream providers.
- The Apple TV Simulator cannot reproduce physical HDMI mode switches or play AV1 video.
- Bitmap subtitle OCR is inherently lossy; fullscreen playback continues to use the original pixel-accurate bitmap path where available.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
