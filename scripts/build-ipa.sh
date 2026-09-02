#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TVOS_PROJECT="$ROOT_DIR/tvosApp/NuvioTV.xcodeproj"
TVOS_SCHEME="NuvioTV"
OUTPUT_DIR="$ROOT_DIR/build-ipa"
ARCHIVE_DIR="$(mktemp -d)/NuvioTV.xcarchive"

cleanup() {
  rm -rf "$(dirname "$ARCHIVE_DIR")"
}
trap cleanup EXIT

echo "==> Archiving ${TVOS_SCHEME} for tvOS (Release, unsigned)..."
xcodebuild archive \
  -project "$TVOS_PROJECT" \
  -scheme "$TVOS_SCHEME" \
  -configuration Release \
  -destination 'generic/platform=tvOS' \
  -archivePath "$ARCHIVE_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  -quiet

APP_PATH="$ARCHIVE_DIR/Products/Applications/NuvioTV.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Archive failed, NuvioTV.app not found at $APP_PATH" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || echo "latest")

echo "==> Packaging unsigned IPA for version ${VERSION}..."
rm -rf "$OUTPUT_DIR/Payload" "$OUTPUT_DIR"/*.ipa
mkdir -p "$OUTPUT_DIR/Payload"
cp -R "$APP_PATH" "$OUTPUT_DIR/Payload/"

(
  cd "$OUTPUT_DIR"
  zip -qry "NuvioTV-unsigned.ipa" Payload
  cp "NuvioTV-unsigned.ipa" "NuvioTV-${VERSION}-unsigned-release.ipa"
)

echo "==> Unsigned IPA created successfully:"
ls -lh "$OUTPUT_DIR"/*.ipa
