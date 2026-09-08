#!/bin/bash
set -euo pipefail

# Run from the repository root. Extra arguments may select focused test suites.
test -f tvosApp/NuvioTV.xcworkspace/contents.xcworkspacedata
test -f tvosApp/Pods/Manifest.lock || {
  echo 'Run pod install --project-directory=tvosApp --deployment first.' >&2
  exit 1
}

test_artifacts="${NUVIO_TEST_ARTIFACTS:-$(mktemp -d "${TMPDIR:-/tmp}/nuvio-tests.XXXXXX")}"
derived_data="${NUVIO_DERIVED_DATA:-$test_artifacts/DerivedData}"
mkdir -p "$test_artifacts"
test ! -e "$test_artifacts/Tests.xcresult" || {
  echo 'Choose a new NUVIO_TEST_ARTIFACTS directory; Tests.xcresult already exists.' >&2
  exit 1
}

destination="${NUVIO_TEST_DESTINATION:-}"
if [ -z "$destination" ]; then
  simulator_id=$(xcrun simctl list devices available --json | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").select { |runtime, _| runtime.include?(".tvOS-") }.values.flatten
    device = devices.find { |d| d["state"] == "Booted" } || devices.first
    abort "No available tvOS simulator. Install a runtime in Xcode." unless device
    puts device.fetch("udid")
  ')
  destination="platform=tvOS Simulator,id=$simulator_id"
fi

xcodebuild -version | tee "$test_artifacts/environment.txt"
echo "Destination: $destination" | tee -a "$test_artifacts/environment.txt"
echo "Results: $test_artifacts"
set +e
xcodebuild -workspace tvosApp/NuvioTV.xcworkspace -scheme NuvioTV \
  -destination "$destination" -derivedDataPath "$derived_data" \
  -resultBundlePath "$test_artifacts/Tests.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  test CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  "$@" -quiet 2>&1 | tee "$test_artifacts/xcodebuild.log"
build_status=${PIPESTATUS[0]}
set -e

# Xcode 27 can return 65 after writing a complete passing result bundle when
# its build-service cleanup reports a no-output subprocess warning. Trust the
# XCTest result itself when it is complete and has no failures.
if [ -d "$test_artifacts/Tests.xcresult" ]; then
  result_summary=$(xcrun xcresulttool get test-results summary \
    --path "$test_artifacts/Tests.xcresult" --format json 2>/dev/null || true)
  result=$(printf '%s' "$result_summary" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("result", "") rescue ""')
  failed=$(printf '%s' "$result_summary" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("failedTests", -1) rescue -1')
  if [ "$result" = "Passed" ] && [ "$failed" = "0" ]; then
    exit 0
  fi
fi
exit "$build_status"
