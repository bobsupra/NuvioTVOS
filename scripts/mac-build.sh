#!/usr/bin/env bash
# Runs ON THE MAC (invoked by scripts/remote-build.sh, or directly).
# Builds the tvOS app and launches it on the simulator or a paired Apple TV.
#
#   scripts/mac-build.sh              # simulator
#   scripts/mac-build.sh device       # needs TVOS_DEVICE_NAME + DEVELOPMENT_TEAM
set -euo pipefail

TARGET="${1:-simulator}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/tvosApp/NuvioTV.xcodeproj"
SCHEME="NuvioTV"
BUNDLE_ID="com.nuvio.app.tv"
# Under tvosApp/build, which is gitignored (the root build/ folder is not).
DERIVED="$ROOT/tvosApp/build/DerivedData"
LOG="$ROOT/tvosApp/build/xcodebuild.log"
SIM_NAME="${TVOS_SIM_NAME:-Apple TV}"
mkdir -p "$(dirname "$LOG")"

# MPVKit is a submodule; a plain clone leaves it empty and package
# resolution fails on its missing Package.swift. Idempotent.
git -C "$ROOT" submodule update --init --recursive

# Full output goes to the log; only errors and the verdict reach the terminal.
build() {
  set +e
  # No `|| true` here: it would replace PIPESTATUS with `true`'s exit code.
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -derivedDataPath "$DERIVED" "$@" build 2>&1 | tee "$LOG" \
    | grep -E --line-buffered "error:|error |BUILD (SUCCEEDED|FAILED)|warning: .*\.swift"
  local status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -ne 0 ]; then
    echo ">> build failed (full log: $LOG)"
    exit "$status"
  fi
}

case "$TARGET" in
  simulator)
    build -destination "platform=tvOS Simulator,name=$SIM_NAME"
    APP="$DERIVED/Build/Products/Debug-appletvsimulator/$SCHEME.app"
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    open -a Simulator
    xcrun simctl install booted "$APP"
    xcrun simctl launch booted "$BUNDLE_ID"
    ;;
  device)
    : "${TVOS_DEVICE_NAME:?set TVOS_DEVICE_NAME to the Apple TV name in Xcode > Devices}"
    : "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Xcode team id}"
    build -destination "platform=tvOS,name=$TVOS_DEVICE_NAME" \
      -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    APP="$DERIVED/Build/Products/Debug-appletvos/$SCHEME.app"
    xcrun devicectl device install app --device "$TVOS_DEVICE_NAME" "$APP"
    xcrun devicectl device process launch --device "$TVOS_DEVICE_NAME" "$BUNDLE_ID"
    ;;
  *)
    echo "usage: $0 [simulator|device]" >&2
    exit 2
    ;;
esac
