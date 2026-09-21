#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-read-admission.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
# Pure Foundation generation-policy check; no macOS/iOS application/package build.
xcrun swiftc -swift-version 6 \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareReadAdmission.swift" \
  "$TASK_ROOT/Scripts/tests/SoftwareReadAdmissionStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
