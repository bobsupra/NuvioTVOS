# NuvioTVOS Bug Fix Priority & Remediation Plan

**Generated:** 2026-11-25  
**Source:** [BUG_AUDIT_REPORT.md](file:///Users/suupra./Downloads/NuvioTVOS/BUG_AUDIT_REPORT.md)

This plan sequences remediation by **user impact, regression risk, and engineering leverage**. Each phase should land with its corresponding regression tests enabled in CI.

---

## P0 — Fix Immediately (Broken Playback Flows, Security Exposure, Failing Engine Tests)

| Order | Bug ID | Summary | Target Files | Est. Effort | Validation Gate |
|---:|---|---|---|---|---|
| 1 | **BUG-003** | Remove `[.new]` from `AudioOutput` KVO observer (`options: []`) | `Vendor/AetherEngine/Sources/AetherEngine/Audio/AudioOutput.swift:66` | 15m | `swift test --package-path Vendor/AetherEngine --filter Issue998KVOReadsTheObjectTests` |
| 2 | **BUG-005** | Only check `sequence < previous.sequence` when `pts > previous.pts` in `harvestGapCut` | `Vendor/AetherEngine/Sources/AetherEngine/Subtitles/SubtitleOverlayDrainer.swift:174-190` | 30m | `swift test --package-path Vendor/AetherEngine --filter Issue362HarvestHoleTests` |
| 3 | **BUG-004** | Add `feedEpoch` tracking and `flush()` epoch bump to `SoftwareEAC3Passthrough` | `Vendor/AetherEngine/Sources/AetherEngine/Audio/SoftwareEAC3Passthrough.swift:18-239` | 2h | `swift test --package-path Vendor/AetherEngine --filter SoftwareProducerEpochTests` |
| 4 | **BUG-001** | Decouple `reloadWithAudioOverride` from caller `Task` cancellation / avoid `.audioTrackSwitchFailed` on caller cancel | `Vendor/AetherEngine/Sources/AetherEngine/AetherEngine+Loading.swift:3139-3158` | 4h | `swift test --package-path Vendor/AetherEngine --filter CancellableLoadTests` |
| 5 | **BUG-018** | Mutate `proposed.discImageHint = true` in `Issue460SessionOptionCorrectionTests` | `Vendor/AetherEngine/Tests/AetherEngineTests/Issue460ReloadWithOptionsTests.swift:64-76` | 15m | `swift test --package-path Vendor/AetherEngine --filter Issue460SessionOptionCorrectionTests` |
| 6 | **BUG-010** | Add `AppleTVCapability.current.supportsLiquidGlass` check to `TvDetailsGlassBackground` & `TvStreamGlass` | `tvosApp/NuvioTV/Sources/UI/Details/DetailsScreen.swift:11960-12006` | 30m | Verify on Apple TV HD / 4K 1st Gen (`AppleTV5,3`, `AppleTV6,2`) + unit/CI check |

**Milestone Exit Criteria:** `swift test --package-path Vendor/AetherEngine` achieves **0 failures** across all 926 suites, and older Apple TV hardware no longer executes Liquid Glass shaders on Details/Stream Picker overlays.

---

## P1 — Security, Keychain Integrity & Auth/Sync Reliability

| Order | Bug ID | Summary | Target Files | Est. Effort | Validation Gate |
|---:|---|---|---|---|---|
| 7 | **BUG-009** | Restrict Keychain `negativeCache` insertion to `status == errSecItemNotFound` in Trakt & MDBList | `Core/Trakt/TraktAuthService.swift:80`, `Core/MDBList/MdbListAuthService.swift:156-160` | 1h | Unit tests simulating transient `errSecInteractionNotAllowed` followed by `errSecSuccess` |
| 8 | **BUG-008** | Enforce atomic Keychain updates and check `OSStatus` before updating memory caches / returning `true` | `TraktAuthService.swift`, `MdbListAuthService.swift`, `SimklAuthService.swift`, `WeTrakrAuthService.swift`, `AniListAccount.swift` | 4h | Unit tests verifying Keychain write errors return `false` without losing prior tokens |
| 9 | **BUG-011** | Add single-flight OAuth refresh coordinators to `WeTrakrAuthService` and `MALAccount` | `Core/WeTrakr/WeTrakrAuthService.swift:576-611`, `Core/MAL/MALAccount.swift:150-181` | 3h | Concurrent refresh unit tests confirming 1 `POST` per batch of simultaneous callers |
| 10 | **BUG-002** | Strip all OAuth tokens, Debrid tokens, API keys, and AIO secrets from `UserDefaults`, iCloud KVS, and generic `tvos_settings` sync; migrate to Keychain | `UI/Settings/SettingsView.swift:498-581`, `ICloudSettingsSyncManager.swift`, `NuvioSyncService.swift`, `SimklAuthService.swift`, `WeTrakrAuthService.swift`, `AIOStreamsHost.swift` | 2–3d | Migration tests verifying existing logins survive upgrade and `UserDefaults` / KVS payloads stay secret-free |
| 11 | **BUG-006** | Gate AIOStreams LAN proxy behind per-session token & setup-screen lifecycle; keep runtime proxy on `127.0.0.1` only | `tvosApp/NuvioTV/AIOInstaller/nuvio-main.mjs:623, 828`, `AIOStreamsHost.swift` | 1–2d | HTTP probe tests rejecting unauthenticated LAN access with `401`/`404` |
| 12 | **BUG-007** | Block loopback, link-local, and RFC 1918 private destinations (including 3xx redirects) in `PluginInstance.startFetch`; add integrity checks for downloaded plugin/AIO code | `Core/Plugins/PluginRuntime.swift:702-750`, `Core/Plugins/PluginStore.swift`, `image-install.mjs` | 2d | SSRF unit tests against `127.0.0.1`, `[::1]`, `169.254.169.254`, and LAN IPs |

---

## P2 — Memory, Main-Thread Performance & Data-Loss/Crash Prevention

| Order | Bug ID | Summary | Target Files | Est. Effort | Validation Gate |
|---:|---|---|---|---|---|
| 13 | **BUG-012** | Bound `CinemetaCatalogRepository.cachedMetaById` (LRU / `NSCache`) and purge on `didReceiveMemoryWarningNotification` | `Data/Repository/CatalogRepository.swift:645-799` | 1d | Memory-pressure and eviction unit tests |
| 14 | **BUG-015** | Use `UIGraphicsImageRendererFormat` (`scale = 1, opaque = true`) in `TopShelfFeedStore.renderedArtwork` + `CGImageSource` downsampled decoding + bounded timeout `URLSession` | `Core/TopShelf/TopShelfFeed.swift:955-1010` | 1d | Assert output dimensions `1280×720` (`scale == 1`) and peak memory under 4K backdrop rendering |
| 15 | **BUG-017** | Move `ProfileAvatarCache` disk I/O, image decoding, and PNG encoding off `@MainActor`; hash URL filenames | `UI/Profile/UserProfileView.swift:716-789` | 4h | Unit tests with 500-char URLs + Instruments Time Profiler on profile picker |
| 16 | **BUG-016** | Protect all reads/writes of `SeekPreviewRangeTransport.Exchange.aborted` with `lock` | `Core/Player/SeekPreviewLane.swift:280-420` | 1h | TSan stress test racing `fetch` vs `cancelInFlight()` / `invalidate()` |
| 17 | **BUG-014** | Replace `UserDefaults.didChangeNotification` listeners in UI with scoped notifications / `@AppStorage` | `PlayerControls.swift`, `ScenePanelView.swift`, `NuvioTVApp.swift`, `SettingsView.swift` | 1d | Verify unrelated `UserDefaults` writes do not trigger `reloadPlayerButtonOrder()` |
| 18 | **BUG-013** | Fix tvOS Collections export storage/flow (avoid unwritable `.documentDirectory`) and decode local import off `@MainActor` | `UI/Settings/SettingsView.swift:20095-20108, 22646-22668` | 1d | Physical tvOS device export/import verification |

---

## P3 — Code Hygiene, Force-Unwrap Removal & Test Suite Completeness

| Order | Bug ID | Summary | Target Files | Est. Effort | Validation Gate |
|---:|---|---|---|---|---|
| 19 | **BUG-019** | Replace remaining `!` force unwraps in `ServerLibraryViewModel`, `DetailsScreen`, `IPTVLiveView`, and `NuvioTVApp` with safe unwrapping | `ServerLibraryViewModel.swift`, `DetailsScreen.swift`, `IPTVLiveView.swift`, `NuvioTVApp.swift` | 2h | Edge-case unit tests with `nil` `libraryID` / `meta` / EPG programs |
| 20 | **BUG-020** | Fix and re-enable excluded test files (`CatalogDecodingTests`, `DetailsViewModelTests`, `PerformanceTests`, `RustSDKIntegrationTests`, `StreamQualityTagsTests`), fix QoS warning in `DetailsWatchlistQueueOwnershipTests`, and resolve Swift 6 Sendable warnings | `tvosApp/Project.swift:236-249`, `tvosApp/NuvioTVTests/*` | 1–2d | `bash scripts/test-tvos.sh` passes with 0 excluded Swift test files and 0 concurrency warnings |
