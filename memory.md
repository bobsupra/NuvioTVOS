# tvOS post-login sync fix

Last verified: 2026-07-11 on a clean Apple TV simulator install.

## Symptom

After deleting and reinstalling NuvioTV, signing in showed the local **Nuvio Guest** profile. Entering it produced an empty Home screen. Opening Switch Profile and selecting the profile again triggered a second sync, after which the correct profile and content appeared.

## Root cause

The reliable account pull was accidentally coming from the profile-switch path. The initial login pull could be missed, canceled, or considered finished before profiles, settings, add-ons, library, progress, and Home inputs were all applied. A canceled older task could also lower the shared loading gate while its replacement was still running. Slow profile recovery previously continued in the background after Guest had already become selectable.

The fresh-install Guest also used to overlap with remote profile slot `1`, making the temporary placeholder look like account identity.

## Fix and required invariants

- Successful login explicitly calls `NuvioSyncManager.beginPostLoginSync()`.
- Profile selection remains blocked by `isPullingAccountProfiles` until the login-owned pull finishes.
- A fixed UI timeout must not reveal Guest while sync is still active.
- `pullGeneration` gives each pull ownership of the loading gate. A stale/canceled task must never clear a newer task or its gate.
- Same-account token refreshes must join the active bootstrap, not cancel and restart it.
- The bootstrap pulls and applies the real profiles before profile-scoped data.
- Settings, add-ons, collections, catalog settings, library, watched state, and progress are pulled before the picker is released.
- Partial account pulls retry automatically. Profile backfill is awaited inside the same bootstrap task rather than detached in the background.
- Failed recovery shows an error. Only the visible Retry action re-arms the blocking gate and starts another full pull.
- Home receives `homeContentSyncedNotification` after synced Home inputs are persisted so any existing cache is rebuilt.
- Local fresh-install Guest has ID `guest`; remote primary profile slot `1` replaces it cleanly.
- Placeholder detection is identity-based. A legitimate remote profile named "Nuvio Guest" must not be treated as the local placeholder.
- Initial data loading must never depend on `activeProfileChanged` or the user selecting the same profile twice.
- Account snapshots must not be pushed until the initial pull has completed successfully, or empty local state could overwrite remote data.

## Key code

- `tvosApp/NuvioTV/Sources/Core/Sync/NuvioSyncService.swift`
  - `authStateChanged`
  - `beginPostLoginSync`
  - `schedulePull`
  - `pullThenPush`
  - `backfillAccountProfiles`
  - `isPlaceholderProfile`
- `tvosApp/NuvioTV/Sources/NuvioTVApp.swift`
  - Login continuation starts/joins sync.
  - Profile selection and Retry use the blocking sync gate.
  - Restored sessions with only a local Guest use the same gate.
- `tvosApp/NuvioTV/Sources/NuvioCoreStubs.swift`
  - `ProfileViewModel.loadProfiles` seeds the temporary `guest` identity.
  - `profileChosen` is emitted only for an explicit user selection.
- `tvosApp/NuvioTV/Sources/Core/Auth/AuthManager.swift`
  - The freshly authenticated in-memory session is immediately available to sync.
  - Same-user refresh publication must not interrupt bootstrap.

## Regression test

1. Build from `tvosApp/NuvioTV.xcworkspace`, not the standalone project.
2. Boot an Apple TV simulator.
3. Uninstall `com.nuvio.app.tv` to remove local app data.
4. Install and launch the new `NuvioTV.app` build.
5. Sign in once.
6. Confirm the sync screen remains visible until the account is ready.
7. Confirm the first profile picker shows the real account profile, not local Guest.
8. Enter the profile once and confirm Home, add-ons, library, and progress are already populated.
9. Do not use Switch Profile during this test; needing it means the regression has returned.

Build verification:

```sh
xcodebuild -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV \
  -sdk appletvsimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

The repository currently has test source folders but no runnable `NuvioTVTests` bundle in the project, so the clean-install simulator flow is the important regression check.

## Physical Apple TV follow-up (build 32)

A real-device install later exposed two silent failures that the simulator did not:

- If profile-file persistence was unavailable, `applyRemoteProfiles` could leave the local placeholder active. The normal post-pull snapshot then uploaded that placeholder as remote profile 1, changing the account name to **Nuvio User** and clearing its avatar.
- Continue Watching persistence discarded encoding and file-write errors. A non-finite Cinemeta rating such as `NaN` could make `JSONEncoder` reject the complete progress array, while sync still marked the pull complete. The diagnostic then showed `remote 9, stored 0` and a missing file.

Required invariants:

- Startup/general snapshots never push profile identity. Names and avatars are pushed only by `syncProfilesAfterLocalEdit`, after a completed initial pull and an explicit user edit.
- An empty local avatar is omitted from the RPC payload; it must never be sent as `null`, which clears the remote avatar.
- Applying pulled profiles returns a verified result and falls back to the actual remote list in memory if profile-file persistence is unavailable.
- A failed/cancelled delayed task must re-check cancellation and initial-pull completion before uploading snapshots.
- `ContinueWatchingStore.persist` returns success only after verified storage. Application Support is preferred, with a marked and verified UserDefaults fallback for device-specific filesystem failures.
- A failed progress merge counts as an incomplete account pull and retries; it must never silently release uploads as if persistence succeeded.
- Non-finite Cinemeta ratings normalize to `nil`, and the progress encoder/decoder also handles non-conforming floats defensively.
- Failed migrations retain their original data. Corrupt payloads remain available to the Home debug panel instead of being deleted before inspection.
- The Home debug panel distinguishes a missing payload from a successful decode and shows the last persistence result.

## Player background-resume regression (build 33)

### Symptom

Pausing a title, opening another tvOS app, and returning to Nuvio could make a
short resume position appear as the full runtime or mark the title watched.

### Root cause and invariant

`MPVPlayerViewController` handled application lifecycle directly: backgrounding
paused and detached video, but foregrounding always resumed playback. It did
not preserve a manual pause or force-save a stable sample. During MPV's
`keep-open` video reattach, a transient EOF/last-frame `time-pos` can equal the
duration. The polling loop could then use that value for progress bookkeeping.

- Capture and persist the last coherent position before background video detach.
- Resume only if the title was playing before suspension; a user pause remains
  paused on return.
- Freeze the saved position while MPV reattaches and seeks back to it. A failed
  restore is an error, never a completed watch.
- Treat playback as ended only after an explicit MPV `END_FILE` EOF event, not
  merely the `eof-reached` property, which may arrive before an error event.
- Force saves use the last stable non-EOF sample. Invalid/zero time reads must
  not delete existing Continue Watching progress.

## Simulator renderer crash (build 34)

The tvOS simulator's `MTLSimDevice` can trap with `_xpc_api_misuse` in
MoltenVK/libplacebo's PBO frame upload path (`pl_tex_upload_pbo`). This is a
simulator-only renderer issue; the physical Apple TV uses the normal Vulkan
path. In `targetEnvironment(simulator)` only, use VideoToolbox-to-Metal
interop (`vulkan-disable-interop=no`), a 64 MiB/16 MiB cache, and disable HDR
peak analysis. Keep the physical-device renderer and user cache settings
unchanged.
