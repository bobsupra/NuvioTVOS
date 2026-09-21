#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_FFMPEG_ROOT="${AETHER_FFMPEG_CHECKOUT:-$TASK_ROOT/.build/checkouts/FFmpegBuild}"
TASK_EXPECTED_REVISION=$(/usr/bin/ruby -rjson -e \
  'pin = JSON.parse(File.read(ARGV.fetch(0))).fetch("pins").find { |p| p.fetch("identity") == "ffmpegbuild" }; abort "Missing FFmpegBuild pin" unless pin; puts pin.fetch("state").fetch("revision")' \
  "$TASK_ROOT/Package.resolved")
TASK_ACTUAL_REVISION=$(git -C "$TASK_FFMPEG_ROOT" rev-parse HEAD)
if [[ "$TASK_ACTUAL_REVISION" != "$TASK_EXPECTED_REVISION" ]]; then
  echo "FAIL: existing FFmpegBuild checkout does not match the frozen package revision" >&2
  exit 1
fi
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-stored-packet.XXXXXX")
trap 'rm -f "$TASK_TMP/check"; rmdir "$TASK_TMP"' EXIT
TASK_FRAMEWORK_ARGS=()
for TASK_LIBRARY in AetherLibavcodec AetherLibavutil AetherLibswresample AetherLibdav1d AetherLibzvbi; do
  TASK_FRAMEWORK_DIR="$TASK_FFMPEG_ROOT/Sources/$TASK_LIBRARY.xcframework/macos-arm64_x86_64"
  if [[ ! -f "$TASK_FRAMEWORK_DIR/$TASK_LIBRARY.framework/$TASK_LIBRARY" ]]; then
    echo "FAIL: required existing host framework is missing: $TASK_LIBRARY" >&2
    exit 1
  fi
  TASK_FRAMEWORK_ARGS+=(-F "$TASK_FRAMEWORK_DIR" -Xlinker -rpath -Xlinker "$TASK_FRAMEWORK_DIR")
done
# Low-level host command-line packet test against the already-pinned binary dependency.
# This does not build/resolve a package, build a macOS/iOS app, or modify package caches.
xcrun swiftc -swift-version 6 \
  "${TASK_FRAMEWORK_ARGS[@]}" -framework AetherLibavcodec -framework AetherLibavutil \
  "$TASK_ROOT/Sources/AetherEngine/Diagnostics/PacketBalanceTracker.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareStoredPacket.swift" \
  "$TASK_ROOT/Sources/AetherEngine/Native/SoftwareStoredPacket+FFmpeg.swift" \
  "$TASK_ROOT/Scripts/tests/SoftwareStoredPacketStandalone.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
echo "FFmpegBuild revision: $TASK_ACTUAL_REVISION"
