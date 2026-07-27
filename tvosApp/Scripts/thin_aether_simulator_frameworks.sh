#!/bin/sh
set -eu

if [ "${PLATFORM_NAME:-}" != "appletvsimulator" ]; then
    exit 0
fi

arch=""
for candidate in "${CURRENT_ARCH:-}" ${ARCHS:-} "${NATIVE_ARCH_ACTUAL:-}"; do
    case "$candidate" in
        arm64|x86_64)
            arch="$candidate"
            break
            ;;
    esac
done

if [ -z "$arch" ]; then
    echo "error: Could not determine the tvOS Simulator architecture." >&2
    exit 1
fi

source_root="${SRCROOT}/../Vendor/FFmpegBuild/Sources"
app_frameworks_dir=""
if [ -n "${FRAMEWORKS_FOLDER_PATH:-}" ]; then
    app_frameworks_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
fi

for xcframework in "${source_root}"/AetherLib*.xcframework; do
    framework_name="$(basename "$xcframework" .xcframework)"
    source_binary="${xcframework}/tvos-arm64_x86_64-simulator/${framework_name}.framework/${framework_name}"

    if [ ! -f "$source_binary" ]; then
        continue
    fi

    for target_framework in \
        "${TARGET_BUILD_DIR}/${framework_name}.framework" \
        "${app_frameworks_dir}/${framework_name}.framework"
    do
        if [ ! -d "$target_framework" ]; then
            continue
        fi

        target_binary="${target_framework}/${framework_name}"
        /usr/bin/lipo -thin "$arch" "$source_binary" -output "$target_binary"
        /usr/bin/codesign --force --sign - --timestamp=none "$target_framework"
    done
done
