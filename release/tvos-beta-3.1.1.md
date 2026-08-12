## tvOS Beta 3.1.1

**Important:** This IPA is unsigned because no tvOS signing identity is configured on this machine.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

### Fixed and improved

- Reworks stream discovery to match Android TV: every compatible configured add-on starts independently, publishes progressive results, and remains visible as its own loading/success/error group.
- Removes the global 80-stream truncation. The All filter combines every playable result in configured add-on order, while each add-on filter shows that provider's complete result set.
- Uses stable configured-add-on identities based on manifest id and URL, so differently configured instances of the same add-on do not collide.
- Adds bounded per-add-on timeouts and success-only manifest caching, allowing temporary provider failures to retry without blocking or hiding working providers.
- Reuses an active or completed search when returning to the same title and prevents playback/source actions from restarting discovery unnecessarily.
- Fixes the source-failure race so stale failures cannot reject a replacement source or suppress the normal MPVKit/HDR fallback path. Upstream connection-refused errors remain visible as server errors.
- Preserves torrent metadata while merging external subtitles and uses a publication revision so metadata-only/subtitle updates refresh cached picker entries even when stream ids and counts stay unchanged.
- Replaces expensive per-focus URL/subtitle scanning and per-card Liquid Glass with revision-based list caching and lightweight focus rendering. Simulator navigation CPU dropped substantially in profiling.
- Keeps add-on filters horizontally scrollable, gives focused chips enough drawing space to avoid clipping, and pins Sort to the trailing side of the picker.
- Fixes watched and library action persistence from details and title-action menus, including immediate local UI updates and account-sync reconciliation.
- Improves Real-Debrid and TorBox TV device linking, Premiumize API-key entry, debrid credential storage, and shared TV-settings synchronization.
- Improves profile, Trakt, watched-state, library, progress, and add-on synchronization while preserving remote changes during refreshes.
- Removes the obsolete Rust/FFI app stubs and duplicate legacy Home/Watchlist implementations; the native tvOS core is now maintained as pure Swift models and services.
- Includes all Dolby Vision, MPVKit fallback, playback resilience, Siri Remote, collection, and player improvements from Beta 3.1.

### Known issues

- The attached IPA is unsigned and must be installed with a compatible tvOS sideloading/signing workflow.
- Native Dolby Vision requires a compatible Apple TV/display chain, Match Dynamic Range, profile 5 or 8 video, and an AVPlayer-compatible audio track. Other combinations use the MPVKit HDR10/PQ fallback.
- Dolby Vision engine handoff and the updated add-on/debrid flows still need broad verification across physical Apple TVs, televisions, receivers, soundbars, HomePods, accounts, and providers.
- Stream availability depends on configured add-ons and upstream servers. A provider or CDN refusing a connection cannot be repaired locally; Nuvio keeps other add-on results available.
- The Apple TV Simulator cannot play AV1 video. Use H.264 or HEVC for simulator testing; physical Apple TV playback is unaffected by this simulator guard.
- Premiumize has no public open-source device OAuth flow. Paste the account API key unless you configure a private `PREMIUMIZE_CLIENT_ID`.
- ASS/SSA karaoke, sign positioning, and custom typesetting are flattened to the app subtitle style.
