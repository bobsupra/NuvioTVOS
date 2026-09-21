#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-partial-ctts.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
xcrun swiftc -swift-version 6 \
  "$TASK_ROOT/Sources/AetherEngine/Video/H264PartialCompositionRepair.swift" \
  "$TASK_ROOT/Scripts/tests/H264PartialCompositionStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
