# tvOS UI tests

UI tests run through the separate `NuvioTV-UI` scheme. Generate the workspace with the
repository's pinned Tuist setup, then build for testing:

```sh
xcodebuild build-for-testing \
  -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV-UI \
  -destination 'platform=tvOS Simulator,name=Apple TV' \
  CODE_SIGNING_ALLOWED=NO
```

Choose an installed Apple TV simulator destination if that example name differs.
The test fixtures depend on catalog, Continue Watching, watchlist, language, account,
latest release notice, and announcement data. Latest-release notice and announcement
tests skip when their fixtures are missing. Supported flows use XCUIRemote directional
presses and Select/Menu.
The helper checks focus before Select; missing or ambiguous controls, missing focus,
changed target identity, and bounded navigation failures are reported as failures.
Custom focus guides may need fixture-specific routes, and the geometric route search
is limited to 40 presses. Catalog-toggle and touch pull-to-refresh cases remain skipped
until their fixtures or observable supported behavior exist. Other legacy fixed waits,
broad outcome assertions, English labels, and external catalog/account data still need
review. A remote press at a scroll boundary need not change focus, and scroll/performance
tests do not establish frame rate, memory bounds, or that all content was traversed.

The unit test script and CI run the `NuvioTV` scheme; they do not automatically run
`NuvioTV-UI`. Build and run the UI scheme with suitable fixtures on a simulator or
device before claiming current validation. This document does not report a current
build or test result.
