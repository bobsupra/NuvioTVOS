# NuvioTVOS Full Codebase Bug & Stability Audit Report

**Audit Date:** 2026-11-25  
**Scope:** Complete `NuvioTVOS` repository (`tvosApp/NuvioTV`, `tvosApp/TopShelf`, `tvosApp/NuvioTV/AIOInstaller`, `supabase`, and `Vendor/AetherEngine`)  
**Policy:** Read-only audit — **zero production source files modified**.

---

## Executive Summary

A repository-wide static, architectural, and test-backed audit of **NuvioTVOS** (392 Swift files in `NuvioTV`, TopShelf extension, NodeMobile/AIOInstaller JS bridge, Supabase edge functions, and 517 source files in `Vendor/AetherEngine`) uncovered **20 distinct bugs and stability/security defects**: **2 Critical**, **8 High**, **8 Medium**, and **2 Low**.

While core subsystems such as `AetherEngine` focus restoration (`<= 0.45s` safety unlock), `HTTPDiscIOReader` autorelease-pool draining, and `NuvioSyncService` generation guards show substantial prior hardening, several high-impact regressions and architectural gaps remain:

1. **Test-Verified Engine Regressions in `Vendor/AetherEngine`:** Running `swift test` on `AetherEngine` (6,958 tests across 926 suites on macOS arm64e) surfaced **6 failing test suites (13 recorded issues)** — 5 representing confirmed defects (`CancellableLoadTests`, `Issue998KVOReadsTheObjectTests`, `SoftwareProducerEpochTests`, `Issue362HarvestHoleTests`, and `Issue460SessionOptionCorrectionTests`), plus 1 load-sensitive concurrency flake (`FrameExtractorLifecycleTests`, which passes standalone).
2. **tvOS Test Baseline Gaps:** `scripts/test-tvos.sh` on Apple TV 4K (3rd gen) simulator passed **2,855 tests (0 failures, 1 skipped)** (`testOriginalAIOStreamsRunsInsideNuvio`), while **5 test files** remain excluded from `NuvioTVTests` in `tvosApp/Project.swift`.
3. **Systemic Credential & Security Weaknesses:** OAuth tokens and API secrets for Simkl, WeTrakr, Debrid, TMDB, MDBList, Seekr, and AIOStreams are persisted in plaintext `UserDefaults` and mirrored unencrypted to iCloud KVS (`NSUbiquitousKeyValueStore`) and Supabase sync blobs; Keychain write errors are silently discarded; AIOStreams binds its configuration proxy to `0.0.0.0` without authentication; and the JavaScript plugin runtime allows SSRF against local loopback/LAN services.
4. **Older Apple TV Hardware & Memory Risks:** `TvDetailsGlassBackground` and `TvStreamGlass` omit `AppleTVCapability.current.supportsLiquidGlass` guards (forcing Liquid Glass shaders on Apple TV HD / Apple TV 4K 1st Gen GPUs), `CatalogRepository.cachedMetaById` grows without bound or memory-pressure eviction, and `TopShelfFeedStore.renderedArtwork` allocates unnecessary 2× alpha bitmaps while `ProfileAvatarCache` performs synchronous disk I/O and PNG encoding on `@MainActor`.

---

## Total Findings by Severity

| Severity | Count | IDs |
|---|---:|---|
| **Critical** | 2 | BUG-001, BUG-002 |
| **High** | 8 | BUG-003, BUG-004, BUG-005, BUG-006, BUG-007, BUG-008, BUG-009, BUG-010 |
| **Medium** | 8 | BUG-011, BUG-012, BUG-013, BUG-014, BUG-015, BUG-016, BUG-017, BUG-018 |
| **Low** | 2 | BUG-019, BUG-020 |
| **Total** | **20** | |

---

## Most Dangerous Architectural Problems

1. **Fragmented Secret & Sync Boundary (`UserDefaults` vs. Keychain vs. Cloud Sync):** Secret management spans Keychain wrappers, plaintext `UserDefaults` mirrors, `ProviderCredentialSync`, `ICloudSettingsSyncManager`, and `NuvioSyncService` allowlists (`SettingsKey.deviceLocal`). Omitting even one key from `SettingsKey.deviceLocal` leaks tokens to unencrypted iCloud KVS and remote sync blobs (BUG-002), while silent Keychain write failures and overly broad negative caching corrupt session state (BUG-008, BUG-009).
2. **Unauthenticated Local Attack Surface Combined with Arbitrary JS `fetch`:** Binding AIOStreams on `0.0.0.0` (BUG-006) alongside unguarded plugin `fetch()` calls (BUG-007) exposes local control planes and LAN hosts to untrusted scripts and neighboring LAN devices.
3. **Shared `UserDefaults.didChangeNotification` Broadcast Storm:** Subscribing heavy UI containers (`PlayerControls`, `ScenePanelView`, Home Hero rating views, Settings screens) directly to `UserDefaults.didChangeNotification` couples unrelated background writes (progress, caches, timestamps) to main-thread SwiftUI view invalidations (BUG-014).

---

## Issues Affecting Older Apple TV Hardware

- **BUG-010 (High):** `TvDetailsGlassBackground` and `TvStreamGlass` apply `.glassEffect(.regular, in:)` on tvOS 26+ without checking `AppleTVCapability.current.supportsLiquidGlass`, which is explicitly `false` for `AppleTV5,3` (Apple TV HD, 2 GB RAM, A8) and `AppleTV6,2` (Apple TV 4K 1st Gen, 3 GB RAM, A10X/PowerVR GT7900) to avoid 4K frame drops.
- **BUG-003 (High):** `AudioOutput` KVO `[.new]` triggers `_castForKVO` ObjC conformance scans on main-actor audio/AVFoundation setup, causing UI/audio hitches on slower A8/A10X CPUs.
- **BUG-012 (Medium):** Unbounded `CatalogRepository.cachedMetaById` retains all visited show/episode metadata in RAM with zero LRU eviction or `didReceiveMemoryWarning` purging — elevating Jetsam risk on 2–3 GB tvOS devices.
- **BUG-015 (Medium):** `TopShelfFeedStore.renderedArtwork` renders 2× RGBA bitmaps (~14.7 MB per card) instead of 1× opaque 720p cards while fetching full `"original"` images without `CGImageSource` downsampling.
- **BUG-017 (Medium):** Synchronous `@MainActor` disk reads/writes and `pngData()` compression in `ProfileAvatarCache` cause frame drops on profile switches and avatar grids.
- **BUG-014 (Medium):** Broad `UserDefaults.didChangeNotification` listeners trigger spurious SwiftUI view updates during playback and navigation.

---

## Issues That Could Cause Crashes or Data Loss

- **Session / Credential Data Loss:** BUG-008 (Keychain write failures silently ignored while returning `true`), BUG-009 (Keychain permanent negative caching on transient `errSecInteractionNotAllowed`), BUG-011 (uncoordinated concurrent refresh-token rotation races in WeTrakr and MAL).
- **Functional Data / Export Failure:** BUG-013 (writing collections JSON export to `.documentDirectory`, which is non-persistent / unwritable on physical tvOS devices).
- **Fatal Playback Stop / Lost Audio/Subtitles:** BUG-001 (cancelled audio-switch caller stops active playback with error), BUG-004 (`SoftwareEAC3Passthrough` stale packet timestamps after flush), BUG-005 (subtitle harvest false-positive cut truncating cues).
- **Potential Process Aborts / Crashes:** BUG-019 (force unwraps `!` in ViewModels/Views), BUG-016 (unsynchronized cross-thread access on `Exchange.aborted` under TSan/race conditions).

---

## Detailed Findings

### BUG-001: `reloadWithAudioOverride` treats cancelled caller `Task` as a terminal playback failure

- **Severity:** Critical
- **Confidence:** Confirmed
- **Category:** Playback / Swift Concurrency
- **Location:** [AetherEngine+Loading.swift](file:///Users/suupra./Downloads/NuvioTVOS/Vendor/AetherEngine/Sources/AetherEngine/AetherEngine+Loading.swift#L3139-L3158)
- **Root cause:** In `reloadWithAudioOverride`, the `catch` ladder handles `CancellationError` **only** `where loadGeneration != gen` (lines 3139–3142). If the caller task awaiting `selectAudioTrack` is cancelled while `loadGeneration == gen` (no newer load or `stop()` superseded it), `CancellationError` falls through into the generic `catch` block (lines 3147–3158), which releases the held picture, logs `"selectAudioTrack reload failed: ..., playback stopped"`, reverts `activeAudioTrackIndex`, and calls `publishError(.audioTrackSwitchFailed, ..., underlying: error)`, halting playback.
- **Trigger:** User initiates an audio track switch, then the UI/caller `Task` awaiting the switch is cancelled (e.g., view update or menu dismissal) before the rebuild completes while `loadGeneration` has not advanced.
- **Impact:** Playback abruptly terminates with `.audioTrackSwitchFailed` and a black screen instead of finishing the rebuild cleanly.
- **Reproduction:** Run `swift test --package-path Vendor/AetherEngine --filter CancellableLoadTests`. Fails at `CancellableLoadTests.swift:600, 602` (`"An audio-switch rebuild whose caller is cancelled still finishes"`).
- **Recommended fix:** Isolate the rebuild work from caller task cancellation (e.g., run inside an unstructured `Task` owned by the engine keyed by `loadGeneration`) or explicitly handle `catch is CancellationError` when `loadGeneration == gen` without publishing `.audioTrackSwitchFailed` and stopping the active session.
- **Regression test:** Keep `CancellableLoadTests` (`"An audio-switch rebuild whose caller is cancelled still finishes"`) in CI gating.

---

### BUG-002: Plaintext OAuth tokens and API secrets stored in `UserDefaults` and synced unencrypted via iCloud KVS & Supabase

- **Severity:** Critical
- **Confidence:** Confirmed
- **Category:** Security / Persistence / Sync
- **Location:**
  - [SettingsView.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Settings/SettingsView.swift#L498-L581)
  - [ICloudSettingsSyncManager.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Sync/ICloudSettingsSyncManager.swift#L248-L280)
  - [NuvioSyncService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Sync/NuvioSyncService.swift#L36-L67)
  - [SimklAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Simkl/SimklAuthService.swift#L122-L152)
  - [WeTrakrAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/WeTrakr/WeTrakrAuthService.swift#L108-L138)
  - [AIOStreamsHost.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/AIO/AIOStreamsHost.swift#L47-L51) and [AIOStreamsHost.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/AIO/AIOStreamsHost.swift#L1562-L1569)
- **Root cause:**
  1. `SettingsKey.all` (`SettingsView.swift:517-581`) includes `simklAccessToken`, `simklRefreshToken`, `wetrakrAccessToken`, `wetrakrRefreshToken`, `tmdbApiKey`, `mdbListApiKey`, `debridApiKey`, `torboxAccessToken`, `premiumizeAccessToken`, `realDebridAccessToken`, and `seekrApiKey` — **none** of which are listed in `SettingsKey.deviceLocal` (`SettingsView.swift:498-505`) or `SettingsKey.syncedViaAddonRPC`.
  2. Consequently, `ICloudSettingsSyncManager.extractSettingsPayload` copies all of those bearer tokens and API keys in plaintext into `NSUbiquitousKeyValueStore` (and `ProfileSettingsSnapshot.capture` in `NuvioSyncService` exports them into the generic `tvos_settings` JSON blob).
  3. `SimklKeychainTokenStorage.writeToken` and `WeTrakrKeychainTokenStorage.writeToken` explicitly mirror Keychain OAuth tokens back into plaintext `UserDefaults`.
  4. `AIOStreamsHost.secret()` stores the 64-char hex encryption `SECRET_KEY` (`aio.experiment.secret`) in `UserDefaults.standard` rather than the Keychain, and `AIOStreamsHost` also mirrors Keychain backup blobs into `UserDefaults.standard` (`aio.experiment.backup` at lines 1009, 1022).
- **Trigger:** Connecting Simkl, WeTrakr, MDBList, Debrid, Seekr, TMDB, or starting the AIOStreams host; especially when iCloud Sync or Nuvio Sync is active.
- **Impact:** Long-lived OAuth refresh/access tokens, debrid tokens, and encryption keys sit in unencrypted property lists on disk, device backups, unencrypted iCloud KVS containers, and generic settings sync blobs.
- **Reproduction:** Inspect the profile plist / `NSUbiquitousKeyValueStore` dictionary or run `ProfileSettingsSnapshot.capture` / `ICloudSettingsSyncManager.extractSettingsPayload` with authenticated Simkl/WeTrakr/Debrid state.
- **Recommended fix:** Move all tokens/secrets (`simklAccessToken`, `simklRefreshToken`, `wetrakrAccessToken`, `wetrakrRefreshToken`, `tmdbApiKey`, `mdbListApiKey`, `debridApiKey`, `torboxAccessToken`, `premiumizeAccessToken`, `realDebridAccessToken`, `seekrApiKey`, `aio.experiment.secret`, `aio.experiment.backup`) into Keychain-only storage; add them to `SettingsKey.deviceLocal` so neither `ICloudSettingsSyncManager` nor `ProfileSettingsSnapshot` reads them; and sync credentials exclusively via dedicated encrypted/scoped RPCs (`ProviderCredentialSync` or Keychain-backed E2E channels).
- **Regression test:** Assert in unit tests that `ProfileSettingsSnapshot.capture` and `ICloudSettingsSyncManager.extractSettingsPayload` never contain any token, secret, or API key, and that `SimklKeychainTokenStorage`/`WeTrakrKeychainTokenStorage` write zero keys into `UserDefaults`.

---

### BUG-003: `AudioOutput` uses KVO `options: [.new]`, triggering main-thread `_castForKVO` conformance scan stall

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** Playback / Performance / Main Thread
- **Location:** [AudioOutput.swift](file:///Users/suupra./Downloads/NuvioTVOS/Vendor/AetherEngine/Sources/AetherEngine/Audio/AudioOutput.swift#L66)
- **Root cause:** `AudioOutput` registers `renderer.observe(\.status, options: [.new]) { ... }` without using either `old` or `new` values in the closure. Requesting `.new` causes the Swift runtime/Foundation KVO bridge to call `_castForKVO` on `AVSampleBufferAudioRenderer.status` and run dynamic ObjC/Swift protocol conformance scans (AE#998), stalling the main thread during player setup and route transitions.
- **Trigger:** Every software playback session that initializes `AudioOutput` (and whenever `renderer.status` transitions).
- **Impact:** Main-thread stutter / frame drop at playback start and audio route transitions, especially noticeable on older Apple TV hardware; fails `Issue998KVOReadsTheObjectTests`.
- **Reproduction:** Run `swift test --package-path Vendor/AetherEngine --filter Issue998KVOReadsTheObjectTests`. Fails at `Issue998KVOReadsTheObjectTests.swift:34`.
- **Recommended fix:** Change `options: [.new]` to `options: []` at `AudioOutput.swift:66` (matching the other KVO observers in `AetherEngine`).
- **Regression test:** `Issue998KVOReadsTheObjectTests` (`"no KVO observer requests a decoded old or new value"`).

---

### BUG-004: `SoftwareEAC3Passthrough` omits `feedEpoch` tracking, letting pre-flush packets corrupt post-flush timestamps

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** Playback / Audio / Seeking
- **Location:** [SoftwareEAC3Passthrough.swift](file:///Users/suupra./Downloads/NuvioTVOS/Vendor/AetherEngine/Sources/AetherEngine/Audio/SoftwareEAC3Passthrough.swift#L18-L239)
- **Root cause:** `SoftwareEAC3Passthrough` conforms to `SoftwareAudioProducing` but inherits the protocol defaults (`feedEpoch: UInt64 { 0 }` and `decode(packet:epoch:)` ignoring `epoch`). Unlike `AudioDecoder` (`_feedEpoch`), `SoftwareEAC3Passthrough.flush()` clears `nextSeconds = nil` without bumping a `feedEpoch`. An in-flight pre-flush packet decoded after `flush()` passes `epoch` check (because `feedEpoch` stayed `0`), sets `nextSeconds` to the stale pre-flush timestamp, and causes subsequent unstamped leading post-flush packets to inherit the pre-flush PTS.
- **Trigger:** Seeking or flushing during E-AC-3 JOC (Dolby Atmos over DD+) software passthrough playback when an unstamped leading packet follows a seek while a pre-seek packet completes decode.
- **Impact:** Audio/video desync or dropped/mis-ordered Atmos audio after seeks on the software playback path.
- **Reproduction:** Run `swift test --package-path Vendor/AetherEngine --filter SoftwareProducerEpochTests`. Fails at `SoftwareProducerEpochTests.swift:144-168` (`"stale JOC timestamps cannot anchor an unstamped leading packet"`).
- **Recommended fix:** Add `private var _feedEpoch: UInt64 = 0` guarded by `lock` (matching `AudioDecoder`), bump `_feedEpoch &+= 1` inside `flush()`, implement `var feedEpoch: UInt64`, and validate `epoch == _feedEpoch` inside `decode(packet:epoch:)` and `endOfStream(epoch:)` under `lock` before reading/updating `nextSeconds`.
- **Regression test:** `SoftwareProducerEpochTests` (`"stale JOC timestamps cannot anchor an unstamped leading packet"`).

---

### BUG-005: `SubtitleOverlayDrainer.harvestGapCut` triggers false-positive harvest holes on equal-PTS sequence drops

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** Playback / Subtitles
- **Location:** [SubtitleOverlayDrainer.swift](file:///Users/suupra./Downloads/NuvioTVOS/Vendor/AetherEngine/Sources/AetherEngine/Subtitles/SubtitleOverlayDrainer.swift#L166-L192)
- **Root cause:** In `harvestGapCut`, when `isRead` is `nil`, the hole detector computes `let isHole = isRead.map { !$0(previous.pts, pts) } ?? (sequence < previous.sequence)` without checking `pts > previous.pts`. If two entries share the exact same PTS (`pts == previous.pts`) and the second entry has a smaller `sequence` (`sequence < previous.sequence`), `harvestGapCut` falsely reports a gap cut even though lines 186–190 explicitly track `max(prior.sequence, sequence)` for an equal-PTS run.
- **Trigger:** Subtitle harvest packets containing multiple overlays at an identical PTS whose sequence numbers are non-monotonic within that PTS run.
- **Impact:** Prematurely cuts/truncates harvested subtitle overlays during playback and seeking.
- **Reproduction:** Run `swift test --package-path Vendor/AetherEngine --filter Issue362HarvestHoleTests`. Fails at `Issue362HarvestHoleTests.swift:105, 122`.
- **Recommended fix:** Gate the default sequence-drop check on advancing timestamps (`pts > previous.pts && sequence < previous.sequence`).
- **Regression test:** `Issue362HarvestHoleTests` (`"sequence drops within one PTS run are ignored, while the run maximum still reveals a later hole"`).

---

### BUG-006: Embedded AIOStreams HTTP proxy binds `0.0.0.0`, exposing unauthenticated configuration & user APIs on the LAN

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** Security / Networking
- **Location:** [nuvio-main.mjs](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/AIOInstaller/nuvio-main.mjs#L623) and [nuvio-main.mjs](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/AIOInstaller/nuvio-main.mjs#L828)
- **Root cause:** The NodeMobile AIOStreams wrapper creates an HTTP + WebSocket (`upgrade`) reverse proxy to `127.0.0.1:aioPort` and explicitly calls `originalListen.call(proxy, lanPort, '0.0.0.0', ...)` (and rebinds to `'0.0.0.0'` on wakeup) with no path secret/token (unlike `PluginWebServer` or `SubtitleFontUploadServer`) and no client authentication.
- **Trigger:** Any user running the built-in AIOStreams host while connected to Wi-Fi/LAN (including shared/untrusted networks).
- **Impact:** Any device on the same LAN can view, modify, or extract AIOStreams configuration, installed addon URLs, and embedded debrid/proxy credentials, or trigger `/api/v1/user` and update endpoints.
- **Reproduction:** Start `AIOStreamsHost` on Apple TV / simulator and connect from another LAN host to `http://<apple-tv-ip>:<lanPort>/`.
- **Recommended fix:** Require a short-lived per-session path or bearer token (similar to `PluginWebServer` / `SubtitleFontUploadServer`) for the LAN proxy while the Setup UI is explicitly open, stop the LAN proxy automatically when the setup screen closes or idles out, and keep normal playback traffic bound strictly to `127.0.0.1`.
- **Regression test:** Add integration/unit check asserting unauthenticated requests to the AIO LAN proxy return `401`/`404`, and that the LAN proxy is stopped outside the setup view.

---

### BUG-007: JavaScript plugin `fetch()` allows SSRF to loopback/LAN services and remote plugin code has no integrity verification

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** Security / Plugins & Addons
- **Location:**
  - [PluginRuntime.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Plugins/PluginRuntime.swift#L702-L750)
  - [PluginStore.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Plugins/PluginStore.swift#L415-L417) and [PluginStore.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Plugins/PluginStore.swift#L543-L553)
  - [nuvio-main.mjs](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/AIOInstaller/nuvio-main.mjs#L644-L656)
- **Root cause:**
  1. `PluginInstance.startFetch` (`PluginRuntime.swift:703-708`) only validates `scheme == "http" || scheme == "https"`. It performs **no** host/IP blocking against `127.0.0.1`, `localhost`, `::1`, link-local (`169.254.0.0/16`), or RFC 1918 LAN addresses (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`). A third-party JS plugin (which executes unsandboxed logic via `JavaScriptCore` and auto-updates every 24h in `PluginStore.updateRepositoriesIfDue`) can probe or hit `PluginLoopbackServer` / `AIOStreamsHost` / `SubtitleFontUploadServer` / LAN routers.
  2. `PluginStore.downloadText` and `AIOInstaller` (`runUpdate` / `image-install.mjs`) fetch and run remote JS bundles without verifying a cryptographic signature or pinned digest from a manifest.
- **Trigger:** User installs a community plugin repository (or a previously benign repository is compromised and auto-updated) whose JS invokes `fetch("http://127.0.0.1:...")` or a LAN target.
- **Impact:** SSRF against local host servers and LAN devices, exfiltration of internal responses, or silent arbitrary JS execution on auto-update.
- **Reproduction:** Call `fetch("http://127.0.0.1:<port>/...")` inside a test plugin evaluated by `PluginRuntime` and observe the request executing on `URLSession`.
- **Recommended fix:** Reject loopback, link-local, and private RFC 1918 / ULA IP destinations (including DNS-resolved IP checks via `URLSession` custom protocol/redirect handler so 3xx redirects cannot pivot into `127.0.0.1`), and support/enforce SHA-256 checksums or signed manifests for plugin & AIO updates.
- **Regression test:** Add `PluginRuntime` unit test verifying `fetch()` to `127.0.0.1`, `[::1]`, `169.254.169.254`, and `192.168.1.1` (direct and via HTTP 302 redirect) fails safely.

---

### BUG-008: Keychain write/update failures are silently ignored across tracker token stores, causing silent session loss

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** Persistence / Authentication / Data Loss
- **Location:**
  - [TraktAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Trakt/TraktAuthService.swift#L91-L108) and [TraktAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Trakt/TraktAuthService.swift#L171-L183)
  - [MdbListAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/MDBList/MdbListAuthService.swift#L170-L187)
  - [SimklAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Simkl/SimklAuthService.swift#L140-L149)
  - [WeTrakrAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/WeTrakr/WeTrakrAuthService.swift#L125-L135)
  - [AniListAccount.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/AniList/AniListAccount.swift#L758-L760)
- **Root cause:**
  - `TraktKeychainStorage.saveSession` (`TraktAuthService.swift:91-108`) discards non-duplicate `SecItemAdd` failure statuses and discards `_ = SecItemUpdate(...)`, unconditionally caching `session` in `Self.sessionCache[profileScope]` and returning `true`. `writeString` (lines 171–183) deletes the item before checking if `SecItemAdd`/`SecItemUpdate` succeeds.
  - `MdbListKeychainTokenStorage.save` (`MdbListAuthService.swift:170-187`) similarly discards `SecItemAdd` non-duplicate errors and `_ = SecItemUpdate(...)`, caching in memory and returning `true`.
  - `SimklKeychainTokenStorage.writeToken`, `WeTrakrKeychainTokenStorage.writeToken`, and `AniListAccount` ignore `SecItemAdd`/`SecItemUpdate` status codes and delete existing items before confirming the replacement write succeeded.
- **Trigger:** Any Keychain write failure during login or OAuth refresh (e.g., `errSecInteractionNotAllowed`, entitlement mismatch `-34018`, or temporary Keychain daemon failure).
- **Impact:** The UI displays a successful login/refresh for the current run via the in-memory cache, but on next app launch the credentials are gone (or in the delete-then-add stores, previously valid refresh tokens are permanently wiped).
- **Reproduction:** Simulate `SecItemAdd`/`SecItemUpdate` returning an error (such as `errSecInteractionNotAllowed`); observe `saveSession` / `save` returning `true` and populating memory cache while Keychain remains empty.
- **Recommended fix:** Perform atomic update-or-add without pre-deleting existing items, verify `status == errSecSuccess` before updating in-memory caches or returning `true`, and surface/handle failed persistence explicitly.
- **Regression test:** Inject mock Keychain operations returning errors and assert `saveSession`/`save` returns `false` without poisoning cache or wiping prior tokens.

---

### BUG-009: Keychain `negativeCache` permanently hides valid Trakt & MDBList tokens after any transient Keychain error

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** Persistence / Authentication
- **Location:**
  - [TraktAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Trakt/TraktAuthService.swift#L76-L82) (contrast with line 154)
  - [MdbListAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/MDBList/MdbListAuthService.swift#L155-L161)
- **Root cause:** While `TraktKeychainStorage.readString` was hardened to insert into `missingStrings` **only** when `status == errSecItemNotFound` (`TraktAuthService.swift:153-156`), both `TraktKeychainStorage.loadSession` (`TraktAuthService.swift:76-82`) and `MdbListKeychainTokenStorage.tokens(for:)` (`MdbListAuthService.swift:155-161`) insert `profileScope` into `Self.negativeCache` on **any** failure (whether `errSecInteractionNotAllowed`, `errSecIO`, or decode failure). Subsequent reads hit `if isNegative { return nil }` before ever calling `SecItemCopyMatching` again.
- **Trigger:** A background launch or early read executes before Keychain access succeeds (returning a transient Keychain error rather than `errSecItemNotFound`).
- **Impact:** The user appears permanently signed out of Trakt or MDBList for the entire process lifetime until force-quitting the app.
- **Reproduction:** Force `SecItemCopyMatching` to fail once (non-`errSecItemNotFound`) during `loadSession` / `tokens(for:)`, then restore Keychain access; subsequent calls still return `nil`.
- **Recommended fix:** Capture the `OSStatus` from `SecItemCopyMatching` in both `loadSession` and `MdbListKeychainTokenStorage.tokens(for:)` and insert into `negativeCache` **only** when `status == errSecItemNotFound`.
- **Regression test:** Unit test with an injected `copyMatching` hook returning `errSecInteractionNotAllowed` first and `errSecSuccess` second, asserting the second call recovers the session.

---

### BUG-010: `TvDetailsGlassBackground` and `TvStreamGlass` bypass `AppleTVCapability.current.supportsLiquidGlass` on older Apple TVs

- **Severity:** High
- **Confidence:** Confirmed
- **Category:** UI / Performance / Older Apple TV Hardware
- **Location:**
  - [DetailsScreen.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Details/DetailsScreen.swift#L11960-L12006)
  - [AppleTVCapability.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Player/AppleTVCapability.swift#L39-L58)
- **Root cause:** `AppleTVCapability.swift:41-58` sets `supportsLiquidGlass: false` for `"AppleTV5,3"` (Apple TV HD, A8) and `"AppleTV6,2"` (Apple TV 4K 1st Gen, A10X/PowerVR GT7900), explicitly noting: *"PowerVR GT7900 GPU cannot sustain real-time tvOS 26 Liquid Glass shaders at 4K without dropping frames."* Every other Glass helper (`PlayerControls`, `PosterCard`, `SettingsView`, `SearchView`, `IPTVLiveView`, `LoginView`, `SceneDetailView`, `WatchPartyLobbyView`, `DiscoverView`, `LibraryView`) checks `if #available(tvOS 26.0, *), AppleTVCapability.current.supportsLiquidGlass`. However, `TvDetailsGlassBackground` (`DetailsScreen.swift:11960-11985`) and `TvStreamGlass` (`DetailsScreen.swift:11990-12006`) check only `if #available(tvOS 26.0, *)` and omit `AppleTVCapability.current.supportsLiquidGlass`.
- **Trigger:** Rendering Details screens, the Home Hero action pills (`NuvioTVApp.swift:18032-18115`), Stream Picker overlay cards (`DetailsScreen.swift:13102`), Scene panels, Post-Play recommendations, Calendar buttons, or Settings rows on tvOS 26 running on Apple TV HD or Apple TV 4K 1st Gen.
- **Impact:** Severe GPU shader overhead, animation hitches, and dropped focus-movement frames across core navigation screens on older Apple TV hardware.
- **Reproduction:** Inspect `TvDetailsGlassBackground` / `TvStreamGlass` or profile Details / Stream Picker GPU frame times on `"AppleTV6,2"` running tvOS 26.
- **Recommended fix:** Add `, AppleTVCapability.current.supportsLiquidGlass` to the `if #available(tvOS 26.0, *)` conditions inside `TvDetailsGlassBackground` and `TvStreamGlass` so legacy hardware falls back cleanly to solid/material backgrounds.
- **Regression test:** Unit test inspecting view modifier behavior or capability branch when `supportsLiquidGlass == false` (plus `rg` CI lint ensuring no `.glassEffect(` call lacks a `supportsLiquidGlass` check).

---

### BUG-011: Missing single-flight token refresh coalescing in `WeTrakrAuthService` and `MALAccount`

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** Networking / Authentication / Concurrency
- **Location:**
  - [WeTrakrAuthService.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/WeTrakr/WeTrakrAuthService.swift#L576-L611)
  - [MALAccount.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/MAL/MALAccount.swift#L150-L181)
- **Root cause:** Unlike Trakt (`TraktRefreshCoordinator`), Simkl (`SimklRefreshCoordinator`), and MDBList (`MdbListRefreshCoordinator`), neither `WeTrakrAuthService.refreshAccessToken()` nor `MALAccount.validToken()` serializes or coalesces concurrent refresh calls. When multiple parallel tasks encounter an expired/expiring token simultaneously, each issues its own `POST` refresh request with the same `refresh_token`.
- **Trigger:** Parallel metadata/watchlist/progress/calendar calls firing simultaneously just as the WeTrakr or MAL access token expires.
- **Impact:** With rotating OAuth refresh tokens, the first request invalidates the old refresh token; racing requests fail with `invalid_grant` / `401` and can mark sync operations failed or invalidate local auth state.
- **Reproduction:** Trigger 2+ concurrent `WeTrakrAuthService.refreshAccessToken()` or `MALAccount.validToken()` calls on an expired token with a mock server enforcing single-use refresh tokens.
- **Recommended fix:** Add an actor-based single-flight refresh coordinator (keyed by profile scope / client ID, mirroring `SimklRefreshCoordinator`) to both `WeTrakrAuthService` and `MALAccount`.
- **Regression test:** Concurrent unit test firing 5 parallel `refreshAccessToken()` / `validToken()` calls and asserting the network endpoint receives exactly 1 refresh `POST`.

---

### BUG-012: Unbounded static metadata cache in `CatalogRepository` leaks memory across long browsing sessions

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** Memory / Performance / Older Apple TV Hardware
- **Location:** [CatalogRepository.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Data/Repository/CatalogRepository.swift#L645-L799)
- **Root cause:** `CinemetaCatalogRepository.cachedMetaById: [String: NuvioMeta]` and `cachedFullMetaIds: Set<String>` are raw Swift dictionary/set statics protected by a `DispatchQueue` barrier (`metadataCacheQueue`). Entries are inserted on every catalog fetch, library sync, and details load (including full `NuvioMeta.videos` episode arrays and descriptions), and are **only** cleared on profile/language/TMDB-flag changes (`prepareMetadataCache`) or explicit `clearMetadataCache()`. There is no count/cost cap, no LRU eviction, and no `UIApplication.didReceiveMemoryWarningNotification` purge.
- **Trigger:** Extended browsing across multiple catalogs, Search, Discover, Collection folders, and long-running series details screens within one session.
- **Impact:** Continuous resident heap growth throughout the session, accelerating memory-pressure kills (Jetsam) on 2–3 GB Apple TV models when combined with video playback buffers.
- **Reproduction:** Load multiple catalog pages and series `NuvioMeta` objects with hundreds of episodes; observe `cachedMetaById.count` growing monotonically without eviction or purge on memory warning.
- **Recommended fix:** Replace `[String: NuvioMeta]` with an `NSCache<NSString, Box>` (or bounded LRU dictionary with max entry count, e.g., 500–1,000 items, and separate smaller cap for full episode-heavy records) and purge on `UIApplication.didReceiveMemoryWarningNotification`.
- **Regression test:** Unit test inserting > cap items and posting `didReceiveMemoryWarningNotification`, asserting bounded count and eviction.

---

### BUG-013: Collections JSON export uses `.documentDirectory` without tvOS `Library/Caches` fallback and imports synchronously on `@MainActor`

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** Persistence / Platform Compatibility / Main Thread
- **Location:**
  - [SettingsView.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Settings/SettingsView.swift#L20095-L20108)
  - [SettingsView.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Settings/SettingsView.swift#L22646-L22668)
- **Root cause:**
  1. `CollectionsSettingsSection.collectionsExportURL` resolves `.documentDirectory` unconditionally (`SettingsView.swift:20104-20108`) and `exportCollections` reports `"Exported to Documents/nuvio-collections.json"`. On physical tvOS devices (unlike Simulator), `.documentDirectory` is not writable/persistent (`NSCocoaErrorDomain` permission failure), which is why `LargePayloadStore`, `DomainModels`, and `TopShelfFeed` fall back to `.cachesDirectory`.
  2. `CollectionsImportSheet.loadLocalExport()` calls `Data(contentsOf: url)` and JSON parsing synchronously on `@MainActor` inside `.onAppear` (line 22655).
- **Trigger:** User taps Export or Import Collections from Local Export in Settings on a physical Apple TV.
- **Impact:** Local collection export fails on physical Apple TV hardware, and importing large exports blocks the main thread.
- **Reproduction:** Execute `CollectionsSettingsSection.collectionsExportURL` write on a real Apple TV device (or read-only `.documentDirectory`).
- **Recommended fix:** Use `LargePayloadStore` or `.cachesDirectory` fallback (or share via the local web configuration server / Nuvio Sync / QR transfer) for tvOS exports, and move `loadLocalExport()` file reading + JSON decoding off `@MainActor` into an async `Task`.
- **Regression test:** Unit test verifying fallback directory behavior when `.documentDirectory` is unwritable, and async import decoding.

---

### BUG-014: Global `UserDefaults.didChangeNotification` observers cause excessive SwiftUI invalidations across Player & Home UI

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** UI / Performance
- **Location:**
  - [PlayerControls.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Player/PlayerControls.swift#L152-L154)
  - [ScenePanelView.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Player/Scene/ScenePanelView.swift#L160)
  - [NuvioTVApp.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/NuvioTVApp.swift#L17682) and [NuvioTVApp.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/NuvioTVApp.swift#L18476)
  - [SettingsView.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Settings/SettingsView.swift#L7840)
- **Root cause:** Multiple SwiftUI views subscribe to `NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)`. `UserDefaults.didChangeNotification` carries no key filter (`object: nil`) and fires whenever **any** subsystem (sync timestamps, watch history, plugin update timestamps, profile settings, playback cache keys) writes to any `UserDefaults` domain — triggering main-thread closures and state/Identity checks inside `PlayerControls`, `ScenePanelView`, Home Hero metadata views, and Settings views.
- **Trigger:** Periodic writes to `UserDefaults` during playback (e.g., `LastPlaybackStreamStore`, `ProfileSettings.notifySettingsChanged`, `ICloudSettingsSyncManager` timestamps, `PluginStore` timestamps).
- **Impact:** Unnecessary main-thread work and SwiftUI view re-evaluations during video playback overlay interactions and Home scrolling.
- **Reproduction:** Observe `reloadPlayerButtonOrder()` / `refreshHeroRatingConfigurationIdentity()` firing on unrelated `UserDefaults.standard.set(..., forKey: "unrelated")` writes.
- **Recommended fix:** Replace `UserDefaults.didChangeNotification` with domain-specific notifications (e.g., `TVPlayerButtonOrder.changedNotification`, `AddonRatingsService.ratingsConfigurationChangedNotification`, `ProfileSettings.settingsChangedNotification` with changed-key `userInfo`) or targeted `@AppStorage` bindings.
- **Regression test:** Unit/UI test verifying unrelated `UserDefaults.standard` mutations do not re-trigger `PlayerControls.reloadPlayerButtonOrder()`.

---

### BUG-015: `TopShelfFeedStore.renderedArtwork` allocates 2× alpha bitmaps (~14.7 MB each) and downloads full `"original"` art without `CGImageSource` downsampling

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** Performance / Memory / TopShelf
- **Location:** [TopShelfFeed.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/TopShelf/TopShelfFeed.swift#L528-L531) and [TopShelfFeed.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/TopShelf/TopShelfFeed.swift#L955-L1010)
- **Root cause:**
  1. While `renderedPoster` explicitly creates a `UIGraphicsImageRendererFormat` with `scale = 1` and `opaque = true`, `renderedArtwork(from:subtitle:)` (line 970) calls `UIGraphicsImageRenderer(size: artworkSize)` with the default format (`opaque = false`, `scale = UIScreen.main.scale`). Even though `artworkSize` (`1280x720`) was already sized in pixels (`/// Rendered card size. 16:9, large enough for the 2x shelf scale`), on a 4K Apple TV (`scale = 2.0`) this allocates a `2560 × 1440` RGBA surface (~14.7 MB per rendered card) unnecessarily.
  2. `downloadedImage(_:)` upgrades TMDB URLs to `/original/` and decodes the full source image into memory with `UIImage(data:)` before scaling down inside CoreGraphics (`UIGraphicsImageRenderer`), creating large temporary uncompressed decoded bitmaps (`>40 MB` for high-res backdrops) and issuing unbounded `URLSession.shared` requests with default 60s timeouts.
- **Trigger:** Updating Top Shelf feeds (`Continue Watching`, `Up Next`, `Catalog Rows`) on a 4K Apple TV, especially during background app refresh or profile load.
- **Impact:** Transient memory spikes (and slower background refresh completion) due to decoding multi-megapixel `"original"` artwork and rendering oversized intermediate backing stores.
- **Reproduction:** Inspect `rendered.size` and `rendered.scale` returned by `TopShelfFeedStore.renderedArtwork` on a 2× scale screen, and trace peak memory during `cacheArtwork` for 10+ `"original"` TMDB images.
- **Recommended fix:** Configure `UIGraphicsImageRendererFormat` with `scale = 1` and `opaque = true` in `renderedArtwork`, use `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize`) to decode downloaded images directly at the target pixel dimensions, and use a dedicated `URLSession` with shorter timeouts (e.g., 10–15s) instead of `URLSession.shared`.
- **Regression test:** Unit test checking `renderedArtwork` pixel dimensions (`1280×720`, not `2560×1440`) and bounded memory decode of a 4K test JPEG.

---

### BUG-016: Data race on `SeekPreviewRangeTransport.Exchange.aborted` across decoder and cancellation threads

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** Concurrency / Playback
- **Location:** [SeekPreviewLane.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Player/SeekPreviewLane.swift#L207) and [SeekPreviewLane.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/Core/Player/SeekPreviewLane.swift#L280-L420)
- **Root cause:** `SeekPreviewRangeTransport.Exchange` is shared between `perform(...)` (running on the preview decoder queue), `cancelInFlight()` / `invalidate()` (called from main/playback queues), and `URLSessionDataDelegate` callbacks. Line 329 (`cancelInFlight`) and line 338 (`invalidate`) write `exchange?.aborted = true` **under `lock`**, line 419 (`perform` polling loop) writes `exchange.aborted = true` **under `lock`**, yet line 280 reads `if exchange.aborted` **without holding `lock`** immediately after `exchange.done.wait(...)` wakes (if `cancelInFlight()` fires concurrently as `done` is signalled, the read at line 280 races with the write at line 329/338).
- **Trigger:** Scrub cancellation or player teardown occurring at the exact moment a range HTTP task completes.
- **Impact:** Formal Swift/TSan data race (`aborted` boolean torn/stale read, causing a cancelled fetch to be processed as active or vice versa).
- **Reproduction:** Run `SeekPreviewRangeTransport` under Thread Sanitizer while interleaving `fetch(...)` completion with `cancelInFlight()` / `invalidate()`.
- **Recommended fix:** Guard every read and write of `exchange.aborted` with `lock` (or snapshot `aborted` under `lock` in `perform` before returning/checking).
- **Regression test:** TSan stress test calling `fetch` against a fast stub `URLProtocol` while racing `cancelInFlight()` / `invalidate()`.

---

### BUG-017: `ProfileAvatarCache` performs synchronous disk I/O, image decoding, and PNG re-encoding on `@MainActor` with unbounded filename length

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** Performance / Main Thread / Persistence
- **Location:** [UserProfileView.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Profile/UserProfileView.swift#L716-L789)
- **Root cause:** `ProfileAvatarCache` is annotated `@MainActor`.
  1. `image(for:)` (lines 743–756) calls `Data(contentsOf: diskURL)` and `UIImage(data: data)` synchronously on the main actor directly from SwiftUI `body` (`currentImage` in `ProfileAvatarView`).
  2. `setImage(_:for:)` (lines 758–766) runs `image.pngData()` and `data.write(to: diskURL, options: .atomic)` synchronously on `@MainActor`.
  3. `fetchImage(for:)` (lines 768–789) decodes `UIImage(data:)` and writes to disk on `@MainActor`.
  4. `diskFileURL(for:)` (lines 738–741) percent-encodes the entire `url.absoluteString`, which can exceed the 255-byte APFS filename limit for long CDN URLs with query tokens, causing silent write failures (`try?`).
- **Trigger:** Opening the profile picker ("Who's Watching?") or profile settings when multiple profiles have custom/remote avatar URLs.
- **Impact:** Main-thread hitching during profile gate rendering and silent disk-cache misses on long avatar URLs.
- **Reproduction:** Populate 6 profiles with cached remote avatars or a >200-char signed avatar URL and open `UserProfileView`.
- **Recommended fix:** Move disk reads/writes, `CGImageSource` downsampled decoding, and file serialization off `@MainActor` to a background actor or detached utility task; hash `url.absoluteString` (SHA-256) for fixed-length filenames; keep only the in-memory `NSCache` lookup synchronous.
- **Regression test:** Unit test verifying `diskFileURL` handles 500-char URLs and persists/reloads without error, plus main-thread responsiveness check.

---

### BUG-018: `Issue460SessionOptionCorrectionTests.everyIdentityFieldIsCompared` fails because test fixture omits `discImageHint`

- **Severity:** Medium
- **Confidence:** Confirmed
- **Category:** Engine / Test Reliability
- **Location:** [Issue460ReloadWithOptionsTests.swift](file:///Users/suupra./Downloads/NuvioTVOS/Vendor/AetherEngine/Tests/AetherEngineTests/Issue460ReloadWithOptionsTests.swift#L64-L76) (production enforcement at [AetherEngine+ReloadWithOptions.swift](file:///Users/suupra./Downloads/NuvioTVOS/Vendor/AetherEngine/Sources/AetherEngine/AetherEngine+ReloadWithOptions.swift#L381))
- **Root cause:** `discImageHint` was properly added to `SessionOptionCorrection.loadIdentityFields` and `refusedFields(from:to:)` (`AetherEngine+ReloadWithOptions.swift:340, 381`), and `identityChangesAreRefused` passes. However, `everyIdentityFieldIsCompared` (`Issue460ReloadWithOptionsTests.swift:64-76`) forgot to mutate `proposed.discImageHint = true`, causing `refusedFields` to omit `"discImageHint"` and fail the equality check against `loadIdentityFields`.
- **Trigger:** Running `swift test --package-path Vendor/AetherEngine`.
- **Impact:** `Issue460SessionOptionCorrectionTests` fails on every test run, masking real regressions in `AetherEngine` CI.
- **Reproduction:** Run `swift test --package-path Vendor/AetherEngine --filter Issue460SessionOptionCorrectionTests`. Fails at `Issue460ReloadWithOptionsTests.swift:74`.
- **Recommended fix:** Add `proposed.discImageHint = true` to `everyIdentityFieldIsCompared` (and ensure any new `loadIdentityFields` entry automatically asserts a corresponding mutation check).
- **Regression test:** `Issue460SessionOptionCorrectionTests.everyIdentityFieldIsCompared`.

---

### BUG-019: Force-unwrap (`!`) crash hazards on optional lookups and dictionary groupings

- **Severity:** Low
- **Confidence:** High Confidence
- **Category:** Stability / Crash Risk
- **Location:**
  - [ServerLibraryViewModel.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/ViewModels/ServerLibraryViewModel.swift#L126) and [ServerLibraryViewModel.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/ViewModels/ServerLibraryViewModel.swift#L149) (`grouped[lhs]!.first!`)
  - [DetailsScreen.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Details/DetailsScreen.swift#L387-L388) and [DetailsScreen.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/Details/DetailsScreen.swift#L420) (`viewModel.uiState.meta!`)
  - [IPTVLiveView.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/UI/IPTV/IPTVLiveView.swift#L2168-L2173) (`prog!`, `next1!`, `next2!`)
  - [NuvioTVApp.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/NuvioTVApp.swift#L13330), [NuvioTVApp.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/NuvioTVApp.swift#L13465), and [NuvioTVApp.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/NuvioTV/Sources/NuvioTVApp.swift#L18345)
- **Root cause:** Multiple UI and ViewModel code paths rely on implicit invariants with `!` (such as `grouped[lhs]!.first!`, `viewModel.uiState.meta!`, `prog!`, `episodeId!`, `$0.libraryID!`). If an edge-case state transition clears `meta`, passes a `JellyfinHomeRow` with `nil` `libraryID`, or triggers a deferred closure after reset, force unwrapping immediately traps (`EXC_BREAKPOINT`).
- **Trigger:** Asynchronous state mutation clearing optional values between view render and closure invocation, or malformed server metadata.
- **Impact:** Immediate app termination (`EXC_BREAKPOINT`).
- **Reproduction:** Inspect callers or exercise edge-case transitions where `uiState.meta` becomes `nil` while a button action fires, or construct a server item whose `libraryID` is `nil`.
- **Recommended fix:** Replace `!` with `guard let` / optional chaining (`meta` captured or safely unwrapped, `prog.map { formatTimeRange(start: $0.start, end: $0.end) } ?? liveBadge`, `grouped[lhs]?.first`).
- **Regression test:** Unit tests covering empty/nil optional edge cases in `ServerLibraryViewModel` sorting and `IPTVLiveView` display mapping.

---

### BUG-020: Five unit test files excluded from `NuvioTVTests` target and QoS priority inversion warning in watchlist tests

- **Severity:** Low
- **Confidence:** Confirmed
- **Category:** Build / Test Coverage / Concurrency Hygiene
- **Location:**
  - [Project.swift](file:///Users/suupra./Downloads/NuvioTVOS/tvosApp/Project.swift#L236-L249)
  - `NuvioTVTests/AIOStreamsHostTests.swift` (`testOriginalAIOStreamsRunsInsideNuvio` skipped in `test-tvos.sh` output)
  - `NuvioTVTests/DetailsWatchlistQueueOwnershipTests.swift` (runtime QoS warning observed during `test-tvos.sh`)
- **Root cause:** `Project.swift:242-248` explicitly excludes `CatalogDecodingTests.swift`, `DetailsViewModelTests.swift`, `PerformanceTests.swift`, `RustSDKIntegrationTests.swift`, and `StreamQualityTagsTests.swift` from `NuvioTVTests` because they were never folded into the compiled target. Separately, `AIOStreamsHostTests/testOriginalAIOStreamsRunsInsideNuvio` skips under simulator test runs, and `DetailsWatchlistQueueOwnershipTests` emits a runtime QoS priority inversion warning (`Thread running at User-initiated quality-of-service class waiting on a thread without a QoS class specified`), alongside 18 Swift 6 concurrency/Sendable compiler warnings during the tvOS test build.
- **Trigger:** Running `bash scripts/test-tvos.sh`.
- **Impact:** Regressions in catalog decoding, details view model, performance benchmarks, and stream quality tag parsing go untested by CI.
- **Reproduction:** Run `NUVIO_TEST_ARTIFACTS="/tmp/out" NUVIO_DERIVED_DATA="/tmp/dd" bash scripts/test-tvos.sh` and inspect `Project.swift:236-249`.
- **Recommended fix:** Repair and re-include the 4 active Swift test files (`CatalogDecodingTests`, `DetailsViewModelTests`, `PerformanceTests`, `StreamQualityTagsTests` — plus `RustSDKIntegrationTests` if applicable) into `NuvioTVTests`, and address the Swift 6 Sendable warnings / QoS mismatch.
- **Regression test:** Remove exclusions in `Project.swift` and run `scripts/test-tvos.sh`.

---

## Quick Fixes vs. Complex Fixes

| Effort | Findings | Notes |
|---|---|---|
| **Quick (< 1 day each)** | **BUG-003** (`options: []`), **BUG-005** (`pts > previous.pts`), **BUG-009** (`status == errSecItemNotFound`), **BUG-010** (`supportsLiquidGlass` check), **BUG-016** (lock around `aborted`), **BUG-018** (`proposed.discImageHint = true`), **BUG-019** (remove `!`) | Surgical, localized fixes with existing or trivial tests. |
| **Moderate (1–3 days each)** | **BUG-001** (isolate audio switch rebuild from caller cancellation), **BUG-004** (`feedEpoch` on `SoftwareEAC3Passthrough`), **BUG-008** (atomic Keychain error handling), **BUG-011** (single-flight refresh in WeTrakr & MAL), **BUG-012** (bounded `NSCache` + memory warning purge in `CatalogRepository`), **BUG-014** (scoped notifications instead of `UserDefaults.didChangeNotification`), **BUG-015** (`scale = 1, opaque = true` + `CGImageSource` downsampling in `TopShelfFeed`), **BUG-017** (background actor/task for `ProfileAvatarCache`) | Straightforward refactors with clear module boundaries. |
| **Complex (3+ days each)** | **BUG-002** (migrate all secrets out of `UserDefaults` / iCloud KVS / `tvos_settings` with backwards-compatible Keychain migration), **BUG-006** (token-gated + lifecycle-bounded AIOStreams LAN proxy), **BUG-007** (SSRF IP/redirect filtering + manifest/package integrity verification for Plugins & AIOStreams), **BUG-013** (tvOS collections export transport/storage redesign), **BUG-020** (repair & re-enable 5 excluded test suites) | Require cross-system migration, protocol design, or multi-file test updates. |

---

## Recommended Implementation Order

1. **Phase 1 — Immediate Stability & Crash/Test Greens (1–2 days):** BUG-003 (`AudioOutput` KVO), BUG-005 (`SubtitleOverlayDrainer` hole check), BUG-004 (`SoftwareEAC3Passthrough` `feedEpoch`), BUG-001 (`reloadWithAudioOverride` cancellation), BUG-018 (`Issue460SessionOptionCorrectionTests`), BUG-010 (`supportsLiquidGlass` guard on Details glass).
2. **Phase 2 — Authentication, Keychain & Sync Security (3–5 days):** BUG-009 (`negativeCache`), BUG-008 (Keychain write error handling), BUG-011 (WeTrakr/MAL refresh coalescing), BUG-002 (remove secrets from `UserDefaults` / iCloud KVS / `tvos_settings` + Keychain migration).
3. **Phase 3 — Local Server Hardening & SSRF Protection (3–4 days):** BUG-006 (AIOStreams LAN proxy auth/lifecycle), BUG-007 (Plugin `fetch()` SSRF protection + integrity checks).
4. **Phase 4 — Older Apple TV Memory, Latency & Platform Fixes (3–4 days):** BUG-012 (`CatalogRepository` cache bounds), BUG-015 (`TopShelfFeed` bitmap/downsampling), BUG-017 (`ProfileAvatarCache` off-main-actor), BUG-014 (scoped settings notifications), BUG-016 (`SeekPreviewRangeTransport` lock), BUG-013 (Collections export tvOS path/async), BUG-019 (`!` cleanup), BUG-020 (re-enable excluded test files).

---

## Areas That Could Not Be Adequately Verified

Because this audit was performed on macOS without a physical Apple TV attached or live external backend credentials:

1. **Physical Apple TV Hardware Behavior (`AppleTV5,3`, `AppleTV6,2`, `AppleTV11,1`, `AppleTV14,1`):** Real GPU frame pacing under Liquid Glass shaders, actual `os_proc_available_memory()` Jetsam thresholds under 4K Dolby Vision Profile 7 FEL playback, `AVSampleBufferAudioRenderer` E-AC-3 JOC / TrueHD / DTS:X passthrough behavior over real HDMI eARC receivers, and `CADisplayLink` / `AVDisplayManager` HDMI mode switching could not be measured on hardware.
2. **tvOS Simulator Limitations:** `AIOStreamsHostTests/testOriginalAIOStreamsRunsInsideNuvio` skipped in the simulator run; real physical-device sandbox restrictions (such as `.documentDirectory` vs `Library/Caches` enforcement, background `NSExtension` Top Shelf execution, and mediaserverd multi-hour sleep/wake resets) were verified via source inspection rather than device telemetry.
3. **Live External Integrations:** End-to-end network behavior against live production Supabase, Trakt, Simkl, WeTrakr, MDBList, AniList, MAL, Debrid providers, live Watch Party multi-client rooms, real LibTorrent P2P swarms, and live NNTP Usenet servers was audited statically and via unit tests rather than live integration runs.
4. **Concurrency & Sanitizer Runs:** Full Thread Sanitizer (`TSan`) and Address Sanitizer (`ASan`) test passes across all targets (`NuvioTV` + `AetherEngine` + `LibTorrent` C++ bridge) were not executed end-to-end.
