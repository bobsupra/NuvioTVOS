#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_PROJECT="$ROOT_DIR/iosApp/iosApp.xcodeproj"
IOS_SCHEME="iosApp"
IOS_DERIVED_DATA_BASE="$ROOT_DIR/build/ios-derived"
IOS_APP_NAME="Nuvio.app"
IOS_BUNDLE_ID="com.nuvio.app"
IOS_PREFERRED_DEVICE_MODEL="${IOS_PREFERRED_DEVICE_MODEL:-iPhone 14 Pro}"
TVOS_APP_DIR="$ROOT_DIR/tvosApp"
TVOS_PROJECT="$TVOS_APP_DIR/NuvioTV.xcodeproj"
TVOS_SCHEME="NuvioTV"
TVOS_DERIVED_DATA_BASE="$ROOT_DIR/build/tvos-derived"
TVOS_APP_NAME="NuvioTV.app"
TVOS_BUNDLE_ID="com.nuvio.app.tv"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-mobile.sh ios [s|p] [full|appstore]
  ./scripts/run-mobile.sh tvos s

Builds the debug iOS app, installs it on a booted simulator or the configured
physical device, and launches it.

The tvOS command builds the native SwiftUI tvOS app from tvosApp/, installs it
on a booted Apple TV simulator, and launches it.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

first_booted_ios_simulator() {
  xcrun simctl list devices booted | awk -F '[()]' '/Booted/ { print $2; exit }'
}

first_booted_tvos_simulator() {
  xcrun simctl list devices booted \
    | awk '/^-- tvOS/{is_tvos=1; next} /^-- /{is_tvos=0} is_tvos && /Booted/ { print; exit }' \
    | sed -E 's/.*\(([A-F0-9-]+)\) \(Booted\).*/\1/'
}


preferred_ios_device() {
  xcrun xcdevice list --timeout 5 2>/dev/null | python3 -c '
import json
import os
import sys

try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)

physical = [
    device for device in devices
    if device.get("platform") == "com.apple.platform.iphoneos"
    and not device.get("simulator", False)
    and device.get("available") is True
    and device.get("modelName") == os.environ["IOS_PREFERRED_DEVICE_MODEL"]
]

if physical:
    print(physical[0].get("identifier", ""))
'
}

validate_ios_distribution() {
  local distribution="$1"

  case "$distribution" in
    full|appstore)
      ;;
    *)
      echo "Unknown iOS distribution: $distribution" >&2
      echo "Expected one of: full, appstore" >&2
      exit 1
      ;;
  esac
}

ios_derived_data_path() {
  local target="$1"
  local distribution="$2"

  echo "$IOS_DERIVED_DATA_BASE/$target-$distribution"
}

run_ios_simulator() {
  local distribution="${1:-appstore}"

  validate_ios_distribution "$distribution"
  require_command xcodebuild
  require_command xcrun

  local simulator_id
  simulator_id="$(first_booted_ios_simulator)"

  if [[ -z "$simulator_id" ]]; then
    echo "No booted iOS simulator found." >&2
    echo "Boot a simulator first, then rerun: ./scripts/run-mobile.sh ios s" >&2
    exit 1
  fi

  local derived_data_path
  derived_data_path="$(ios_derived_data_path simulator "$distribution")"

  local simulator_app_path
  simulator_app_path="$derived_data_path/Build/Products/Debug-iphonesimulator/$IOS_APP_NAME"

  echo "Building iOS $distribution debug app for simulator $simulator_id..."
  env NUVIO_IOS_DISTRIBUTION="$distribution" xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -configuration Debug \
    -destination "id=$simulator_id" \
    -derivedDataPath "$derived_data_path" \
    build

  if [[ ! -d "$simulator_app_path" ]]; then
    echo "Expected iOS simulator app not found at: $simulator_app_path" >&2
    exit 1
  fi

  echo "Installing on simulator $simulator_id..."
  xcrun simctl install "$simulator_id" "$simulator_app_path"

  echo "Launching app..."
  xcrun simctl launch "$simulator_id" "$IOS_BUNDLE_ID"
}

run_ios_physical() {
  local distribution="${1:-appstore}"

  validate_ios_distribution "$distribution"
  require_command xcodebuild
  require_command xcrun
  require_command python3

  local physical_device_id
  physical_device_id="$(IOS_PREFERRED_DEVICE_MODEL="$IOS_PREFERRED_DEVICE_MODEL" preferred_ios_device)"

  if [[ -z "$physical_device_id" ]]; then
    echo "Preferred iOS device not available: $IOS_PREFERRED_DEVICE_MODEL" >&2
    echo "Connect and unlock that device, then rerun: ./scripts/run-mobile.sh ios p" >&2
    exit 1
  fi

  local derived_data_path
  derived_data_path="$(ios_derived_data_path device "$distribution")"

  local device_app_path
  device_app_path="$derived_data_path/Build/Products/Debug-iphoneos/$IOS_APP_NAME"

  echo "Building iOS $distribution debug app for physical device $physical_device_id..."
  env NUVIO_IOS_DISTRIBUTION="$distribution" xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -configuration Debug \
    -destination "id=$physical_device_id" \
    -derivedDataPath "$derived_data_path" \
    build

  if [[ ! -d "$device_app_path" ]]; then
    echo "Expected iOS app not found at: $device_app_path" >&2
    exit 1
  fi

  echo "Installing on physical device $physical_device_id..."
  xcrun devicectl device install app --device "$physical_device_id" "$device_app_path"

  echo "Launching app..."
  xcrun devicectl device process launch --device "$physical_device_id" "$IOS_BUNDLE_ID"
}

run_tvos_simulator() {
  require_command xcodebuild
  require_command xcrun

  local simulator_id
  simulator_id="$(first_booted_tvos_simulator)"

  if [[ -z "$simulator_id" ]]; then
    echo "No booted Apple TV simulator found." >&2
    echo "Boot an Apple TV simulator first, then rerun: ./scripts/run-mobile.sh tvos s" >&2
    exit 1
  fi

  local derived_data_path
  derived_data_path="$TVOS_DERIVED_DATA_BASE/simulator"

  local simulator_app_path
  simulator_app_path="$derived_data_path/Build/Products/Debug-appletvsimulator/$TVOS_APP_NAME"

  echo "Building tvOS debug app for simulator $simulator_id..."
  xcodebuild \
    -project "$TVOS_PROJECT" \
    -scheme "$TVOS_SCHEME" \
    -configuration Debug \
    -destination "id=$simulator_id" \
    -derivedDataPath "$derived_data_path" \
    build

  if [[ ! -d "$simulator_app_path" ]]; then
    echo "Expected tvOS simulator app not found at: $simulator_app_path" >&2
    exit 1
  fi

  echo "Installing on Apple TV simulator $simulator_id..."
  xcrun simctl install "$simulator_id" "$simulator_app_path"

  echo "Launching tvOS app..."
  xcrun simctl terminate "$simulator_id" "$TVOS_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$simulator_id" "$TVOS_BUNDLE_ID"
}

main() {
  case "${1:-}" in
    ios)
      if [[ $# -lt 2 || $# -gt 3 ]]; then
        usage
        exit 1
      fi

      local ios_distribution="${3:-appstore}"

      case "$2" in
        s)
          run_ios_simulator "$ios_distribution"
          ;;
        p)
          run_ios_physical "$ios_distribution"
          ;;
        *)
          echo "Unknown iOS target: $2" >&2
          usage
          exit 1
          ;;
      esac
      ;;
    tvos)
      if [[ $# -ne 2 ]]; then
        usage
        exit 1
      fi

      case "$2" in
        s)
          run_tvos_simulator
          ;;
        *)
          echo "Unknown tvOS target: $2" >&2
          usage
          exit 1
          ;;
      esac
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown platform: ${1:-}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
