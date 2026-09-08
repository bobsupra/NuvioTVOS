# Native tvOS quality implementation plan

Status: correctness improvements implemented; 111 focused simulator tests pass.
The larger player extractions and hardware/UI navigation validation remain open.

## Current implementation status

- Details owns metadata cancellation and generation checks. Its tests now use
  controlled completions (including different responses for the same title),
  explicit readiness expectations, deterministic metadata/streams, and no live
  enrichment. Watchlist tests load metadata before toggling and clean up fixtures.
- Aether is created only when backend policy selects it. Startup failure uses an
  inert transport; Auto falls back to MPV, while forced Aether remains an error.
  Retry attempts construction once, reconnects callbacks/PiP, and cannot restart a
  stopped session. Startup errors cancel and suppress source failover timers.
- Catalog and folder duplicates collapse at section preparation, before layout.
  Title identity includes provider type and ID; rendering, focus keys, default
  focus, and saved restoration use the same contract. Different source rows stay
  distinct. Removed targets choose a surviving slot, and hidden Home does not
  issue focus requests while an overlay owns input.
- PiP registration clears an old bridge when the new session has no Aether
  controller. Retry refreshes only the matching registered session.
- `scripts/test-tvos.sh` builds/tests the real CocoaPods workspace, chooses an
  available tvOS simulator, propagates test failures, and retains `.xcresult`
  output. CI uses the Apple Silicon Xcode 27 runner, deployment-mode pod install,
  and uploads results. Its external run has not been executed here.

## Validation

The real workspace build and seven initial baseline tests passed without any
temporary framework stub. The focused Details, Home, playback policy, PiP, and
player-control suites passed 111 tests, including successful retry callback/PiP
rebinding. The exact reproduction command is in `scripts/test-tvos.sh`.

The earlier statement that provider startup caused the stalled test run was
unsupported. The observed delay in this run occurred after XCTest completed,
inside Xcode's `simctl diagnose` subprocess. The script disables that lengthy
system diagnostic collection while retaining test results and build logs.

## Outstanding work

- Dedicated deterministic tvOS UI-test target and physical remote/VoiceOver checks.
- Incremental extraction of seeking, episode advancement, source recovery, and
  track-selection responsibilities from `PlayerViewModel`.
- Apple TV/Instruments performance and sustained-playback validation.
- Remote CI execution. The current worktree references the user's untracked
  `Vendor/LibTorrent` package; its package and binary inputs must accompany the
  checkout before remote CI can pass.

## Objective and scope

Improve native interaction, architecture, and maintainability through small, independently reviewable changes. Ratings are subjective; completion is measured by the acceptance criteria below, not a promised score.

This plan follows a targeted source review, not a successful build or hardware validation. Reconfirm findings against the working tree before each change. Preserve existing uncommitted work, including playback and torrent changes. Keep the current product behavior and backend capabilities unless a step explicitly fixes a defect. Avoid a wholesale UI rewrite or vendor-engine refactor.

Paths below are relative to the repository root. Application paths are under `tvosApp/NuvioTV/Sources/`.

## Delivery sequence

| Change | Primary benefit | Depends on | Relative size |
| --- | --- | --- | --- |
| 1. Establish a runnable test baseline | Maintainability | None | Small–medium |
| 2. Make details loading cancellation-safe | Reliability, architecture | 1 | Small |
| 3. Recover from engine initialization failure | Reliability, architecture | 1 | Medium |
| 4. Stabilize card identity and focus restoration | Native interaction | 1 | Medium |
| 5. Add deterministic remote-navigation coverage | Native interaction, maintainability | 4 | Medium |
| 6. Extract player responsibilities incrementally | Architecture, maintainability | 2, 3, 5 | Large; separate PRs |
| 7. Validate hardware behavior and performance | Native interaction, release confidence | 6 | Medium |

Each implementation change includes its focused tests. Step 1 establishes the harness; it does not defer regression coverage until later.

## 1. Establish a runnable test baseline

**Files:** `tvosApp/NuvioTV.xcodeproj/project.pbxproj`, shared `NuvioTV.xcscheme`, `tvosApp/NuvioTVTests/`, and a new `.github/workflows/tvos-tests.yml`.

- Identify the tests actually compiled by the shared scheme. Inventory disconnected or stale tests separately; do not wire all legacy files into the target indiscriminately.
- Record the Xcode version, simulator destination, dependency setup, and exact build/test command that succeeds locally. Confirm binary/vendor dependencies support that destination.
- Connect and repair `DetailsViewModelTests.swift` as needed for step 2, including the required content type argument.
- Add a macOS CI job using the verified environment and dependency setup. Run the supported unit-test target and retain failure results. If dependencies prevent hosted CI, document the concrete blocker and required runner rather than marking this complete.
- Replace sleeps only in the tests touched by this work, using controllable fakes, expectations, or observable completion.

**Acceptance:** the shared scheme executes the intended tests; a deliberately failing assertion fails the job; baseline failures are recorded and resolved or explicitly separated from new regressions.

## 2. Make details loading cancellation-safe

**Files:** `ViewModels/DetailsViewModel.swift`, `tvosApp/NuvioTVTests/DetailsViewModelTests.swift`.

- Retain the primary metadata task, cancel it on replacement and `cancelAllTasks()`, and increment a request generation on both actions.
- Check cancellation and generation after asynchronous boundaries before publishing success, errors, or starting deferred enrichment. Do not rely only on the title ID: two requests for the same title can still complete out of order.
- Ensure cancellation is not displayed as a loading error. Preserve immediate cached metadata and progressive stream loading.
- Inject an explicit stream-discovery dependency or strategy instead of selecting behavior with `repository is MockCatalogRepository`. Keep the existing production default at the composition point.

**Acceptance tests:** request A finishes after B and cannot overwrite B; a completion after dismissal cannot publish state or start enrichment; cancellation does not show an error; same-title reloads reject older completions; cached details still appear immediately.

## 3. Recover from engine initialization failure

**Files:** `Core/Player/AetherPlaybackController.swift`, `PlaybackSessionCoordinator.swift`, `PlaybackBackendPolicy.swift`, `ViewModels/PlayerViewModel.swift`, `UI/Player/PlayerView.swift`, and focused playback tests.

- Remove the second `try! AetherEngine()` attempt. Make initialization failure an explicit result owned by the session coordinator.
- Introduce a small injectable engine/controller factory so tests can force initialization failure. Instantiate backends when needed; update existing nonoptional controller and view-surface assumptions together.
- For Auto, route an unavailable Aether engine to MPV once. For explicitly selected Aether, show a recoverable error and retry action. Keep existing hard capability exceptions governed by `PlaybackBackendPolicy`.
- Keep teardown idempotent and invalidate stale callbacks. Preserve resume position, progress-save guards, and the rule that active picture-in-picture can outlive the player screen.

**Acceptance tests:** Auto survives Aether construction failure and selects MPV once; explicit Aether reports failure without crashing; explicit MPV does not require Aether construction; retry creates a fresh session; stopping prevents delayed loads or fallback from restarting playback. Run existing backend-policy and picture-in-picture tests.

## 4. Stabilize card identity and focus restoration

**Files:** `UI/Home/TVCatalogRow.swift`, `UI/Components/PosterCard.swift`, Home/navigation sections of `NuvioTVApp.swift`, and affected browse/overlay views.

- Replace array-index identity for materialized catalog and folder cards with stable presentation identity. Keep index-based layout calculations and the existing materialization strategy.
- Define identity at row-data preparation: row ID plus content type and content ID, or folder ID. Resolve duplicate entries explicitly: deduplicate accidental duplicates; retain a stable source identity for intentional duplicates. Do not generate UUIDs in view bodies or use array position as a substitute.
- Use the same identity contract for SwiftUI children, focus targets, and saved restoration state. Update all producers and consumers together.
- Preserve native `Button` plus `PosterCardButtonStyle()` for cards. Convert gesture-driven sidebar controls where appropriate without changing specialized player gestures.
- Consolidate overlay restoration into explicit phases with a generation token. Preserve deferred preparation, pending restore IDs, dismissal/unmount signals, and direct completion when the target gains focus.
- Bring the existing 0.6-second safety cleanup within the project limit of 0.5 seconds. Make timeout cleanup idempotent and prevent an old timeout from releasing a newer transition's lock.
- When the saved item disappears, choose the nearest surviving item in that row, then another valid row/control if necessary. Never retain a focus lock for a nonexistent target.

**Acceptance:** focus stays attached to the same surviving item through insertion and reordering; intentional duplicates have distinct identities; all four overlay paths restore focus; removed targets have a usable fallback; a missed callback releases the restriction within the configured limit. Cover transition policy in unit tests and interaction in step 5.

## 5. Add deterministic remote-navigation coverage

**Files:** `tvosApp/NuvioTVUITests/`, Xcode project/shared scheme, test launch setup, and accessibility identifiers on affected controls.

- Create or reconnect a supported tvOS UI-test target. Use a launch configuration with deterministic catalog fixtures and no account or live-provider requirement.
- Test with remote button actions and explicit element/focus assertions. Replace conditional assertions that silently pass when the expected control is absent.
- Cover Home → Details → Back, folder and browse dismissal, rapid repeated dismissal, row refresh while focused, and removal of the saved card.
- Add focused checks for player controls, Back/Menu routing, and audio/subtitle panel navigation where a deterministic playback fixture is supported.
- Verify accessibility labels and focused/selected states for affected controls. Record VoiceOver hardware checks separately from automated coverage.

**Acceptance:** each navigation test asserts its starting control, destination, and restored focus; missing elements fail the test; tests run through the shared scheme. Simulator limitations and hardware-only scenarios are documented explicitly.

## 6. Extract player responsibilities incrementally

**Files:** `ViewModels/PlayerViewModel.swift`, `UI/Player/PlayerView.swift`, `Core/Player/`, and focused tests.

Before each extraction, add behavioral coverage for its boundaries. Move state, tasks, and cancellation ownership together; merely moving methods into extensions is insufficient. Introduce only the dependencies needed by that component, keeping UI publication on the main actor and media processing on existing background queues.

1. **Seeking:** introduce `PlaybackSeekController` for scrub sessions, accumulated remote input, debounce/hold tasks, clamping, and commit/cancel decisions. Pass a narrow transport dependency and a controllable clock. Test rapid nudges, seek bounds, cancellation, and replacement/shutdown during a pending seek.
2. **Episode advancement:** introduce `NextEpisodeController` for eligibility, countdown, cancellation, and stream resolution. Reuse `PostPlayRecommendationController`; keep post-play recommendations distinct. Test manual/automatic advancement racing, countdown cancellation, and stale resolution after title replacement.
3. **Source recovery:** introduce `PlaybackSourceRecoveryController` for the startup watchdog, URL retry/exclusion policy, and source-resolution tasks. Keep Aether/MPV selection and handoff exclusively in `PlaybackSessionCoordinator`. Test late resolver responses and repeated failures without loops or duplicate progress writes.
4. **Track selection:** introduce a track-selection controller for audio/subtitle selection, preferences, and external subtitle fetch ownership. Reuse existing translation state and cache components. Test track refresh preserving a valid selection and stale subtitle results after switching titles.

After each extraction, keep `PlayerViewModel` as the UI coordinator and verify existing progress saving, remote controls, fallback, and PiP lifecycle behavior. Use separate PRs so a regression can be isolated and reverted. Evaluate splitting Home restoration out of `NuvioTVApp.swift` only after step 4 has established its tested transition contract.

**Acceptance:** each extracted component has explicit inputs/outputs and owns its asynchronous work; shutdown or replacement cancels that work; the view model no longer duplicates its state machine. Focused tests and the existing playback suite pass after each extraction. File length is a secondary signal, not the completion criterion.

## 7. Validate hardware behavior and performance

- Record a baseline on the oldest available supported Apple TV and a newer model when available, with the same build configuration, catalog fixtures, media, and network conditions used for comparison.
- Exercise rapid directional navigation, at least 20 repeated overlay open/close cycles, source switching, seeking, audio/subtitle selection, PiP entry/return, app background/foreground, and a 60-minute playback session.
- Use Instruments to inspect main-thread stalls, retained player/controller instances, memory trends, and high-frequency UI updates. Keep subtitle/clock updates isolated from unnecessary whole-screen publication.
- Compare against baseline before setting numerical performance budgets. Investigate repeatable regressions rather than claiming smoothness from source structure alone.
- Perform VoiceOver and physical Siri Remote checks. Record device, OS, media/backend, scenario, and result. Mark unavailable hardware scenarios as unverified.

**Acceptance:** no reproduced focus freeze, duplicate playback session, stale-content update, or crash in the matrix; released sessions do not accumulate retained controllers; measured performance has no unexplained regression against baseline. Save the results and outstanding limitations with the final PR.

## Execution and review

For each bounded change: root confirms scope and current baseline; the named researcher investigates only unresolved questions; coder implements the approved slice and focused tests; reviewer reviews the actual diff; coder addresses valid findings; root checks acceptance evidence. Use the repository's specified isolated subagent context and model policy. Browser debugging is not a substitute for tvOS simulator or device verification.

Completion requires the acceptance evidence for all seven steps. Tests or hardware checks that could not run remain explicit outstanding work. This document authorizes no deployment or release and records no implementation as completed.
