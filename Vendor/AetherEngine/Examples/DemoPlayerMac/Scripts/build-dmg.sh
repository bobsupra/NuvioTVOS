#!/bin/bash
#
# build-dmg.sh, build a notarized .dmg of AetherEngine Demo for
# distribution as a GitHub Release asset.
#
# Pre-flight (one-time setup on the build machine):
#
#   1. Developer ID Application certificate installed in the login
#      keychain (the same one Sodalite is signed with).
#
#   2. App-specific password generated at https://appleid.apple.com
#      OR an App Store Connect API key. Then store under a notarytool
#      keychain profile name:
#
#        xcrun notarytool store-credentials NOTARY_PROFILE \
#          --apple-id you@example.com \
#          --team-id YOURTEAM \
#          --password xxxx-xxxx-xxxx-xxxx
#
# Usage:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="NOTARY_PROFILE" \
#   ./Scripts/build-dmg.sh
#
# Optional env overrides: VERSION (default: 2.0.2), APP_NAME, BUNDLE_ID.
#
# If NOTARY_PROFILE is unset the script still builds + signs the .app
# and .dmg but skips notarization. The output won't pass Gatekeeper
# on other machines, so use that mode only for local smoke tests.

set -euo pipefail

VERSION="${VERSION:-2.0.2}"
APP_NAME="${APP_NAME:-AetherEngine Demo}"
BUNDLE_ID="${BUNDLE_ID:-de.superuser404.AetherEngine.DemoPlayer}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cd "$(dirname "$0")/.."

if [[ -z "$DEVELOPER_ID" ]]; then
  cat >&2 <<EOF
ERROR: DEVELOPER_ID env var is required.

Find your identity with:
  security find-identity -v -p codesigning | grep "Developer ID Application"

Then re-run:
  DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \\
  NOTARY_PROFILE="..." \\
  $0
EOF
  exit 1
fi

BUILD_DIR="build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
ENTITLEMENTS="$BUILD_DIR/DemoPlayerMac.entitlements"
DMG="$BUILD_DIR/AetherEngine-Demo-${VERSION}.dmg"

rm -rf "$APP_DIR" "$DMG" "$BUILD_DIR/DemoPlayerMac.zip"
mkdir -p "$BUILD_DIR"

# Phase 1: Universal release build.
echo "==> [1/6] Building universal release..."
swift build -c release --arch arm64 --arch x86_64

BINARY=".build/apple/Products/Release/DemoPlayerMac"
[ -f "$BINARY" ] || { echo "FAIL: $BINARY not produced"; exit 1; }

echo "    binary: $(file "$BINARY" | head -1 | sed 's/.*: //')"
echo "    size:   $(ls -lh "$BINARY" | awk '{print $5}')"

# Phase 2: Wrap binary in .app bundle.
echo "==> [2/6] Wrapping in .app bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/DemoPlayerMac"
chmod +x "$APP_DIR/Contents/MacOS/DemoPlayerMac"

# Phase 2b: Embed the FFmpegBuild frameworks the binary links against.
#
# These used to be statically linked, and an earlier revision of this script
# recorded that as a comment saying "if FFmpegBuild ever switches to dynamic
# frameworks, this is where they'd be copied to". It since did (LGPL wants the
# libraries relinkable), and a comment cannot notice that. The shipped 6.5.6
# demo died at launch on a reporter's machine with
#   Library not loaded: @rpath/Libavcodec.framework/Versions/A/Libavcodec
# (AetherPlayer#2). So the copy below is followed by a check that actually
# fails the build, rather than a note describing what someone ought to do.
echo "    embedding frameworks..."
FW_SRC="$(dirname "$BINARY")"
mkdir -p "$APP_DIR/Contents/Frameworks"
fw_count=0
for fw in "$FW_SRC"/*.framework; do
  [ -d "$fw" ] || continue
  cp -R "$fw" "$APP_DIR/Contents/Frameworks/"
  fw_count=$((fw_count + 1))
done
echo "    embedded $fw_count framework(s) from $FW_SRC"

# The xcframework payloads are mode 555 and `cp -R` preserves that, so codesign
# below fails with a bare "Permission denied" when it tries to replace their
# existing signature. Restore owner write on the copies.
chmod -R u+w "$APP_DIR/Contents/Frameworks"

# The binary's own LC_RPATH does not point at Contents/Frameworks, so add it.
# Duplicate entries are harmless but noisy, so only add when absent.
if ! otool -l "$APP_DIR/Contents/MacOS/DemoPlayerMac" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_DIR/Contents/MacOS/DemoPlayerMac"
fi

# Guard, both halves. Presence alone proves nothing: a bundle can hold every
# framework and still abort in dyld when no rpath points at Contents/Frameworks,
# which is exactly how this failed once while a presence-only check passed.
if ! otool -l "$APP_DIR/Contents/MacOS/DemoPlayerMac" | grep -q "@executable_path/../Frameworks"; then
  echo "FAIL: the binary carries no rpath for Contents/Frameworks, so dyld cannot" >&2
  echo "      find the embedded frameworks no matter what was copied in." >&2
  exit 1
fi

# ...and every @rpath load command must resolve to something inside the bundle.
# This is the check whose absence shipped a demo that could not launch.
unresolved=0
while read -r dep; do
  [ -n "$dep" ] || continue
  rel="${dep#@rpath/}"
  if [ ! -e "$APP_DIR/Contents/Frameworks/$rel" ]; then
    echo "    UNRESOLVED: $dep"
    unresolved=$((unresolved + 1))
  fi
done < <(otool -L "$APP_DIR/Contents/MacOS/DemoPlayerMac" | awk '/@rpath\//{print $1}')
if [ "$unresolved" -gt 0 ]; then
  echo "FAIL: $unresolved @rpath dependency/dependencies missing from the bundle." >&2
  echo "      The .app would die at launch with a dyld 'Library not loaded' abort." >&2
  exit 1
fi
echo "    all @rpath dependencies resolve inside the bundle"

# Phase 3: Inject Info.plist + Hardened Runtime entitlements.
echo "==> [3/6] Writing Info.plist + entitlements..."
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DemoPlayerMac</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>AetherEngine demonstrator. LGPL-3.0 with App Store Exception.</string>
</dict>
</plist>
PLIST

# Hardened Runtime entitlements. Both flags are conservative defaults
# for a SwiftUI app that ships static FFmpeg libraries: the unsigned
# executable memory entitlement covers Swift / SwiftUI runtime JIT
# paths; the library-validation disable is a safety net in case
# FFmpegBuild ever introduces a dynamic load. Drop them once a clean
# notarization run confirms they're unnecessary.
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
ENT

# Phase 4: Code-sign with Hardened Runtime.
# Nested code signs first, inside out: signing the .app seals whatever its
# Frameworks/ already contains, so an unsigned framework there makes the
# --strict verify below fail (and notarization reject the submission).
echo "==> [4/6] Code-signing..."
for fw in "$APP_DIR/Contents/Frameworks"/*.framework; do
  [ -d "$fw" ] || continue
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID" \
    "$fw"
done

codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" \
  "$APP_DIR"

codesign --verify --verbose=2 --strict --deep "$APP_DIR"

# Phase 5: Notarize (if profile provided).
if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "==> [5/6] Notarizing .app..."
  ZIP="$BUILD_DIR/DemoPlayerMac.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm "$ZIP"
  echo "    Stapling notarization ticket..."
  xcrun stapler staple "$APP_DIR"
else
  echo "==> [5/6] Skipping notarization (NOTARY_PROFILE not set)"
  echo "    The output will not pass Gatekeeper on other machines."
fi

# Phase 6: Package into signed .dmg.
echo "==> [6/6] Building .dmg..."
hdiutil create -volname "${APP_NAME}" \
  -srcfolder "$APP_DIR" \
  -ov -format UDZO \
  "$DMG" >/dev/null

codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "    Notarizing .dmg (separate submission so Gatekeeper accepts the download itself)..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo ""
echo "==> Done."
echo "    .app: $APP_DIR"
echo "    .dmg: $DMG"
echo "    size: $(ls -lh "$DMG" | awk '{print $5}')"
