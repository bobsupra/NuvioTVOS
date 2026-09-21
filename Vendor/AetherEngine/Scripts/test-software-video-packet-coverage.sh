#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-video-packet-coverage.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Pure Foundation timestamp-model check; no macOS/iOS application or package build.
xcrun swiftc -swift-version 6 \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwarePacketCoverage.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareVideoPacketCoverage.swift" \
  "$TASK_ROOT/Scripts/tests/SoftwareVideoPacketCoverageStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
