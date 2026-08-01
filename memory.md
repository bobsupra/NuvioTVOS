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
- `tvosApp/NuvioTV/Sources/DomainModels.swift`
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
- `ContinueWatchingStore.persist` returns success only after verified storage. Application Support is preferred, with a verified file-backed Caches fallback for device-specific filesystem failures. Never write a large synced progress payload to UserDefaults: tvOS 27 aborts the process when the preferences domain becomes oversized.
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
peak analysis. AV1 is not VideoToolbox-decoded in the simulator, so filter
AV1-labeled streams from selection and reject an unlabeled AV1 stream once its
actual codec is known. Keep the physical-device renderer, codecs, and user
cache settings unchanged.

## Simulator works but physical Apple TV fails: bind async work to its profile

Last updated: 2026-07-20. The Trakt fix compiles for both the simulator and the
physical tvOS arm64 target; final behavior still requires an on-device run.

### Trakt symptom and root cause

Trakt device approval could briefly succeed on a physical Apple TV and then the
UI returned to **Connect**. The simulator appeared correct. The device-code
polling task repeatedly read and wrote `ProfileSettings.current`, which is a
mutable global store. A profile/account refresh during that asynchronous flow
could therefore start the login in one profile store and save or reload its
token from another. SwiftUI's inherited `defaultAppStorage` could also differ
from the store being consulted by the service.

An additional risk was immediately forcing an OAuth token rotation after a new
device token was issued. A failed refresh could clear an otherwise valid new
login and produce the same Connect-again symptom.

### Required fix and general rule

- Any async operation that belongs to a profile must capture the exact profile
  ID or `UserDefaults` suite when it starts. Do not repeatedly consult
  `ProfileSettings.current` after an `await`, timer, polling loop, callback, or
  view transition.
- Pass that captured store through the complete operation: credentials,
  pending device code, polling interval, token save, token read, username,
  cached data, cancellation, logout, and error cleanup must all use it.
- For profile-sensitive `@AppStorage` involved in the flow, initialize it with
  `ProfileSettings.store(for: profileID)` explicitly. Recreating a view with
  `.id(profileID)` is useful, but it does not replace explicit storage binding.
- After device authorization, use the newly issued access token directly and
  refresh it only when it is expiring. Do not force an immediate token refresh.
- If a feature works in Simulator but not on a real Apple TV, inspect global
  mutable profile state, filesystem assumptions, app lifecycle, persistence,
  and hardware-only behavior before adding simulator-specific workarounds.
- Never report a physical-device issue as verified from Simulator alone. Check
  `xcrun devicectl list devices`, build the generic physical tvOS target, and
  complete the actual on-device reproduction when the Apple TV is available.

Key implementation:

- `TraktAuthService` captures a `UserDefaults` store and uses it for the entire
  OAuth lifecycle.
- `TraktSettingsViewModel` receives the same store and keeps polling/profile
  state bound to it.
- `IntegrationSettingsView` explicitly binds Trakt credential `@AppStorage`
  and its view model to `ProfileSettings.store(for: profileID)`.

Physical-target compile check:

```sh
xcodebuild -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV \
  -sdk appletvos \
  -destination 'generic/platform=tvOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Player chrome focus (progress bar ↔ transport row)

Last updated: 2026-07-20. Applies to `tvosApp/NuvioTV/Sources/UI/Player/PlayerControls.swift`.
Same pattern as Settings category pills in `SettingsView` (`categoryGrid`).

### Symptoms

- Up from the progress bar did not land on Play, or briefly flashed Episodes /
  Streams / Settings first, then jumped to Play.
- Right from Play skipped the Streams (sources) button and landed on Settings.

### Root cause

tvOS applies **spatial focus before** `onMoveCommand` runs. Reading
`focusedControl` inside the move handler is already wrong: the engine may have
jumped across the large transport-row `Spacer` to the geometric nearest button
(often Episodes or Settings).

Re-assigning focus after the fact can still **flash** the wrong button for a
frame if that button was focusable during the spatial hop.

### Required invariants (do not regress)

1. **Route moves from the origin that received the command**, not from the
   post-spatial `focusedControl`:
   - Timeline `.onMoveCommand` → `handleMove(direction, from: .timeline)`
   - Each transport button → `handleMove(direction, from: focusKey)`
2. **Up from timeline always goes to Play.** Down from any transport button
   always goes to the timeline.
3. **Left/right on the transport row** walk `transportFocusOrder`:
   `play → episodes? → sources? → settings` (only include panels that are shown).
4. **Left/right on the timeline** nudge seek and keep timeline focus (hold-to-seek
   must not promote focus onto buttons).
5. **Flash prevention (Settings-style):** while the timeline owns focus (or focus
   is nil), only Play is focusable in the transport row. Other transport buttons
   use `.disabled(!isTransportButtonFocusable(key))` so they leave the spatial
   graph. With a single upward candidate, spatial focus lands on Play with no
   intermediate flash. Once any transport button is focused, every visible
   transport button is focusable again so left/right still work.
6. Use `.disabled` for focusability, **not** toggling `.focusable(...)` on the
   Button — that previously left Select dead. `PosterCardButtonStyle` ignores
   `isEnabled`, so disabled pills look the same.
7. `moveFocus(to:)` sets `focusedControl` immediately **and** re-asserts on the
   next main-queue turn so a late spatial update cannot keep the wrong target.
8. Do not gate transport/timeline focusability on `focusedControl != .timeline`
   in a way that unmounts buttons mid-row; Select and panel return depend on
   stable `.focused($focusedControl, equals:)` identities.

### Key code

- `PlayerControls` — `transportFocusOrder`, `isTransportButtonFocusable`,
  `moveFocus`, `handleMove(from:)`, `glassIconButton`, `timelineBar`
- Settings analogue: `SettingsView.categoryGrid` — only the open category pill
  stays focusable while focus is in the detail pane (`isFocusable =
  isSelectedCategory || focusedCategory != nil`)

### Manual check

1. Reveal player chrome; default focus on the progress bar.
2. Press **up** → focus lands on **Play** with no Episodes/Streams flash.
3. Press **right** repeatedly → Play → Episodes (if series) → Streams → Settings.
4. Press **left** back through the same order; **down** from any button returns
   to the progress bar.
5. On the bar, left/right still seek; hold left/right still hold-to-seek.

## Beta release workflow

Last verified end-to-end: Beta 3.1.5 on 2026-07-22.

Use this checklist from start to finish for every beta. Replace `X.Y.Z` with
the release version and `BUILD` with the next integer build number.

### 1. Audit before changing anything

1. Run `git status --short`, note every modified/untracked file, and treat
   pre-existing changes as user work. Never discard, reset, or overwrite them.
2. Confirm the active branch is `main`, inspect `HEAD`, `origin/main`, recent
   commits, and the latest `tvos-beta-*` tags.
3. Fetch `origin` and stop if `main` and `origin/main` have diverged or the
   target tag/release already exists.
4. Inspect both committed changes since the previous release and the intended
   uncommitted diff. Use actual code behavior—not only issue descriptions—to
   decide what belongs in the release.
5. Keep unrelated dirty files out of the release. Stage exact paths later;
   never use broad staging such as `git add -A` in a dirty worktree.
6. If unrelated dirty files are tvOS build inputs, do not archive from that
   worktree: stop for direction or prepare a separate release worktree from the
   exact approved source state. Never stash user work without permission.

### 2. Build the complete change list

1. Review `git diff --stat`, `git diff --name-status`, focused source diffs,
   added regression-test names, and the previous release notes.
2. Group user-visible changes by subject, for example:
   - Trakt/sync and watched history
   - resume and playback continuity
   - episodes, sources, audio, and subtitles
   - skip segments
   - player presentation and controls
   - tests
3. Describe only behavior actually present in the release tree. Do not claim
   that an investigated-but-unfixed issue was fixed.
4. Carry unresolved reports into **Known issues**. Mention provider/data
   dependencies explicitly (for example, Recap appears only when its timing
   provider returns a recap interval).

### 3. Bump every version consistently

1. Increment the build number from the previous release.
2. Update `CFBundleShortVersionString` in:
   - `tvosApp/NuvioTV/Info.plist`
   - `tvosApp/TopShelf/Info.plist`
3. Update every applicable `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` in
   `tvosApp/NuvioTV.xcodeproj/project.pbxproj` (app, Top Shelf, and tests).
4. Validate both plists with `plutil -lint`.
5. Search the release-facing files for the old version/build and confirm no
   stale value remains.

### 4. Write structured patch notes and README

1. Add `release/tvos-beta-X.Y.Z.md`.
2. Use this release-note structure:

   ```text
   ## tvOS Beta X.Y.Z

   Important unsigned-IPA notice

   ### Feature/fix group 1
   - Specific user-visible changes

   ### Feature/fix group 2
   - Specific user-visible changes

   ### Tests
   - New regression coverage

   ### Known issues
   - Honest remaining limitations
   ```

3. Keep bullets concrete: state what was wrong, what now happens, and any
   relevant conflict/fallback rule. Prefer several clear themed sections over
   one long “Fixed and improved” list.
4. Update README's **Latest tvOS Beta** version/build, tag URL, IPA URL, and
   **New in Beta X.Y.Z** summary. The summary should be shorter than the full
   notes but cover every major change group.
5. Standard release identifiers:
   - tag: `tvos-beta-X.Y.Z`
   - release name: `Beta X.Y.Z`
   - asset: `NuvioTV-X.Y.Z-unsigned-release.ipa`

### 5. Validate before the Release build

1. Run `git diff --check`.
2. Run the focused unit/regression tests for every changed subsystem. Be
   careful that `-only-testing` names the newly added test classes as well as
   older classes in the same file.
3. Record the number of executed tests and require zero failures.
4. For risky player/device changes, compile both simulator and generic-device
   destinations. Do not claim physical Apple TV validation when only a device
   compile was performed.
5. Stop the release on test, compile, plist, or formatting failure.

### 6. Create the unsigned Release archive

1. Archive from `tvosApp/NuvioTV.xcworkspace`, scheme `NuvioTV`,
   configuration `Release`, destination `generic/platform=tvOS`.
2. Disable signing with:
   - `CODE_SIGNING_ALLOWED=NO`
   - `CODE_SIGNING_REQUIRED=NO`
3. Keep `SWIFT_ENABLE_BATCH_MODE=NO`; Xcode 27 beta has previously crashed
   during Release optimization without this workaround.
4. Use a release-specific archive and DerivedData path so older artifacts are
   not overwritten:

   ```text
   artifacts/NuvioTV-X.Y.Z-unsigned-release.xcarchive
   /tmp/NuvioTVOS-X-Y-Z-ReleaseDerivedData
   ```

5. Require `** ARCHIVE SUCCEEDED **`. Existing deprecation/concurrency
   warnings may be reported, but new errors must block the release.

### 7. Package and verify the IPA

1. Copy the archived `NuvioTV.app` into a fresh staging directory as
   `Payload/NuvioTV.app`.
2. ZIP the `Payload` root into
   `artifacts/NuvioTV-X.Y.Z-unsigned-release.ipa` using `ditto`.
3. Verify all of the following:
   - `unzip -tq` reports no compressed-data errors
   - app version and build equal `X.Y.Z (BUILD)`
   - Top Shelf version and build equal `X.Y.Z (BUILD)`
   - the main executable is Mach-O `arm64`
   - the app bundle reports “code object is not signed at all”
   - byte size is recorded
   - SHA-256 is recorded
4. The archive, staging folder, and IPA are intentionally ignored by Git and
   uploaded as release artifacts. Do not force-add them to the repository.

### 8. Review and commit the exact source state

1. Re-run `git diff --check` and inspect `git status --short`.
2. Stage only the intended source, tests, project version, README, release
   notes, and explicitly requested memory files by exact path.
3. Confirm the cached diff contains no unrelated files or build products.
4. Commit as `Release tvOS Beta X.Y.Z`.
5. Confirm the worktree has no unintended unstaged release changes and that
   the built artifact corresponds to the committed source state.

### 9. Tag and push safely

1. Fetch `origin` again and confirm `origin/main` still points to the pre-release
   base; stop on unexpected remote movement.
2. Create annotated tag `tvos-beta-X.Y.Z` with message
   `tvOS Beta X.Y.Z`.
3. Push `main` and the tag atomically when supported.
4. Verify:
   - local `HEAD`
   - `origin/main`
   - the peeled local tag
   - the peeled remote tag

   All four must point to the release commit.

### 10. Publish and verify the GitHub release

1. Create a GitHub release from the annotated tag:
   - name `Beta X.Y.Z`
   - body from `release/tvos-beta-X.Y.Z.md`
   - non-draft
   - non-prerelease
   - marked latest
2. Upload exactly
   `NuvioTV-X.Y.Z-unsigned-release.ipa` with
   `application/octet-stream`.
3. Prefer `gh` when installed. If it is unavailable, use the authenticated
   GitHub REST API through the existing Git credential helper without printing,
   storing, or exposing the credential. Never ask the user to paste a token
   into chat.
4. Verify through the public GitHub release/latest API:
   - correct tag/name and latest status
   - `draft=false` and `prerelease=false`
   - asset state is `uploaded`
   - remote asset byte size equals the local IPA
   - GitHub's SHA-256 digest equals the local checksum
   - public download returns HTTP 200 and the exact byte count
5. Verify README's release and download links resolve.
6. Final handoff should include the release link, direct IPA link, commit,
   tag, version/build, test count, byte size, SHA-256, and a concise grouped
   change list. Call out any physical-device behavior that still needs real
   Apple TV validation.

## Future exact-ID IPA creation for the physical Apple TV

Last verified: 2026-08-01 with NuvioTV 3.2.2 (build 53).

Use this procedure when creating a future IPA that the user can install over
the existing beta app instead of receiving a second app:

1. Preserve the exact main-app bundle identifier in the packaged app:
   `CFBundleIdentifier = com.nuvio.app.tv`.
2. Create the device-signed installation IPA separately from the unsigned
   GitHub release artifact. Use a name such as
   `NuvioTV-X.Y.Z-BUILD-exact-id-signed.ipa` so the two cannot be confused.
3. Sign with a currently valid tvOS provisioning profile and its matching
   certificate/private key. The working free-provisioning arrangement keeps
   both `CFBundleIdentifier` and `ALTBundleIdentifier` set to
   `com.nuvio.app.tv`; its profile/application-identifier may contain Apple's
   generated suffix. Never commit or print the signing key or credentials.
4. Verify the final IPA before installation:
   - version and build are the intended release
   - `CFBundleIdentifier` is exactly `com.nuvio.app.tv`
   - `ALTBundleIdentifier`, when present, is `com.nuvio.app.tv`
   - the embedded profile contains the target Apple TV UDID and has not expired
   - `codesign --verify --deep --strict` succeeds on the extracted app
   - record the byte size and SHA-256
5. Deliver the verified exact-ID IPA to the user. Do not open, control, or
   install it through Sideloadly unless the user explicitly asks. Mention in
   the handoff that this already-signed IPA should be installed with
   Sideloadly's **Normal Install** mode; Apple ID Sideload can re-sign it,
   rewrite the identifier to a suffixed ID, and install a duplicate app.
6. Free provisioning expires. Generate a fresh matching profile/signature for
   later IPAs rather than reusing an expired package. The profile used for the
   verified build expires on 2026-08-06.
7. Top Shelf needs its own valid extension provisioning profile. If one is not
   available, omit `PlugIns/TopShelf.appex` from the sideloaded package and
   state that limitation in the handoff; do not leave an incorrectly signed
   extension in the IPA.

Verified reference artifact:

- `build/NuvioTV-3.2.2-53-exact-id-signed.ipa`
- SHA-256:
  `bac3d45ad2694b04645bef533cf00a7725da837b08bcbd218707d4d62a888f0e`
