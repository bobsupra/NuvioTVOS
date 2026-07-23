## tvOS Beta 3.1.6

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

### Grid Home

- Adds **Grid View** as a Home layout alongside Modern and Compact.
- Gives every catalog a six-column, three-row poster preview. The final tile opens **See All**, a full catalog browser that loads additional pages as you move through it.
- Adds an automatic featured hero slideshow built from the available Home catalogs.
- Adds a Grid View hero-catalog selector under Settings → Layout & Discovery. An empty selection continues to use all available catalogs.
- Keeps watched badges, focus behavior, collection folders, and Continue Watching available in the new layout.

### Faster Home loading

- Publishes synced collections and built-in catalogs as soon as they are available instead of waiting for every add-on request to finish.
- Adds slower add-on catalogs progressively while Home remains usable.
- Removes the previous 24-row Home limit and retries configured catalog rows that were initially missing.
- Serializes shared metadata-cache access so progressive catalog work cannot race while loading titles.

### Watched-history performance

- Replaces repeated full-history scans with indexed media-identity merging across catalog, IMDb, TMDB, and Trakt aliases.
- Indexes newest watched timestamps before Continue Watching cleanup, avoiding quadratic work as account history grows.

### Apple storage and repository maintenance

- Moves growing shared iOS payloads from `NSUserDefaults` into atomic files under Application Support, with one-time legacy migration and account-cleanup support. This protects the inherited iOS/shared app surface from oversized preferences; it does not change tvOS native account-file formats.
- Removes the unrelated Android TV reference project from GitHub tracking while keeping local developer copies ignored.
- Documents the longer-term storage architecture and the complete repeatable beta-release workflow for future maintainers and AI agents.

### Tests

- Adds a 10,000-item watched-history merge watchdog test. The focused watched-identity suite executes four tests covering alias matching, series markers, title isolation, and large-history performance.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Recap buttons only appear when the skip-segment provider has recap timing data for that specific episode.
- A reported Hawk/RAWR Netflix Atmos embedded-subtitle stream can still drift out of sync even when the comparable Fusion source is synchronized; this source-specific timestamp issue remains under investigation.
- MPVKit is still required for separate video/audio URLs, audio delay, audio amplification, and ASS Scale mode.
- Stream and subtitle availability depends on configured add-ons and their upstream servers.
- The Apple TV Simulator cannot reproduce physical HDMI mode switches or play AV1 video; validate those paths on Apple TV hardware.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
