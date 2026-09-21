#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-packet-coverage.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Pure Foundation timestamp model; not a macOS/iOS application target.
xcrun swiftc \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketCoverage.swift" \
  "$TASK_ROOT/Scripts/tests/SoftwarePacketCoverageStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
