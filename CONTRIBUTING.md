# Contributing

Thanks for helping improve Nuvio. Please keep contributions focused and aligned with the current product direction.

## Before you start

- Bug fixes, regressions, stability improvements, translations, and documentation fixes are welcome.
- New features, UX changes, architecture changes, dependency changes, and large refactors require an approved feature request before implementation.
- Cosmetic-only UI changes are not accepted.
- Open one issue per problem and link the issue in your pull request.

## UI and behavior changes

UI changes must fix a specific, reproducible glitch or regression and include before/after screenshots or a short video. Behavior changes must explain the old behavior, the problem, the new behavior, and how it was tested.

Keep pull requests small, focused, and free of unrelated cleanup or refactoring.

## Bug reports

Include:

- App version or commit
- Platform, device model, and OS version
- Install method
- Exact reproduction steps
- Expected and actual behavior
- Frequency of the issue

Crash and force-close reports must include a crash log or relevant device console output. For source-specific problems, name the source without sharing private links or credentials.

## Feature requests and large changes

Describe the problem, use case, proposed solution, and alternatives. Wait for explicit maintainer approval before starting implementation. An open or popular feature request is not approval by itself.

## tvOS testing notes

- Test on a physical Apple TV when possible; the simulator cannot play AV1.
- Catalog, source, Cloud Library, and Top Shelf integrations benefit from real-account/device testing.
- The main known issue is occasional horizontal scrolling stutter while artwork loads.
- If login returns to the Apple TV Home screen, attach a device console or crash log.
- The optional `NuvioTVandroid/` reference checkout is not required.

## Pull request checklist

Before opening a PR, confirm that it:

- Fixes a linked issue or has explicit feature approval
- Is focused and minimal
- Includes appropriate tests or manual verification
- Includes visual proof for UI fixes
- Does not add unrelated changes or dependencies
