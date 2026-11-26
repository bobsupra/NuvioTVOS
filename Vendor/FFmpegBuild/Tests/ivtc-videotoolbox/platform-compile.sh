#!/bin/sh
# Compiles the new kernels (metal, per-slice AIR target) and wrappers (-fsyntax-only with
# build.sh's deployment targets and -Werror=partial-availability) for each Apple platform.
cd "$(dirname "$0")/../ffmpeg-src"
P=$(xcode-select -p)/Platforms
T=${TMPDIR:-/tmp}
for t in "AppleTVOS appletvos arm64-apple-tvos16.0" "AppleTVSimulator appletvsimulator x86_64-apple-tvos16.0-simulator" \
         "iPhoneOS iphoneos arm64-apple-ios16.0" "XROS xros arm64-apple-xros1.0" "MacOSX macosx x86_64-apple-macos14.0"; do
  set -- $t
  SDKP=$P/$1.platform/Developer/SDKs/$1.sdk
  AIR=$(echo $3 | sed -E 's/^(arm64|x86_64)/air64/')
  r=ok
  for f in fieldmatch decimate; do
    xcrun -sdk $2 metal -target $AIR -fmodules-cache-path=$T/mc -c libavfilter/metal/vf_${f}_videotoolbox.metal -o $T/$f.air 2>$T/m.err \
      || { r="metal FAIL $f"; grep -v "DVTFile\|ResultBundle\|xcresult" $T/m.err | head -3; }
    clang -fsyntax-only -DHAVE_AV_CONFIG_H -target $3 -isysroot "$SDKP" -I. -Ilibavfilter -Werror=partial-availability -Wall \
      -Werror=missing-prototypes -Werror=implicit-function-declaration libavfilter/vf_${f}_videotoolbox.m 2>$T/c.err \
      || { r="objc FAIL $f"; grep -E "error" $T/c.err | head -5; }
    grep -E "warning:" $T/c.err | grep "videotoolbox\.m" | head -3
  done
  echo "$3: $r"
done 2>&1 | grep -v "DVTFile\|ResultBundle\|xcresult"
