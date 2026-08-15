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
if [ -z "$app_frameworks_dir" ]; then
    app_wrapper="${WRAPPER_NAME:-${PRODUCT_NAME}.app}"
    app_frameworks_dir="${TARGET_BUILD_DIR}/${app_wrapper}/Frameworks"
fi

for xcframework in "${source_root}"/AetherLib*.xcframework; do
    framework_name="$(basename "$xcframework" .xcframework)"
    source_framework="${xcframework}/tvos-arm64_x86_64-simulator/${framework_name}.framework"
    source_binary="${source_framework}/${framework_name}"

    if [ ! -f "$source_binary" ]; then
        continue
    fi

    package_framework="${TARGET_BUILD_DIR}/${framework_name}.framework"
    if [ -d "$package_framework" ]; then
        target_binary="${package_framework}/${framework_name}"
        /usr/bin/lipo -thin "$arch" "$source_binary" -output "$target_binary"
        /usr/bin/codesign --force --sign - --timestamp=none "$target_binary"
        /usr/bin/codesign --force --sign - --timestamp=none "$package_framework"
    fi

    # Swift package products are not consistently materialized in the app's
    # Frameworks directory for simulator builds. If the embed phase did not
    # create it, copy the framework from the xcframework before thinning it;
    # otherwise the app links successfully but dyld aborts at launch with
    # "Library not loaded: @rpath/AetherLibavcodec.framework/...".
    app_framework="${app_frameworks_dir}/${framework_name}.framework"
    mkdir -p "$app_frameworks_dir"
    if [ ! -d "$app_framework" ]; then
        /usr/bin/ditto "$source_framework" "$app_framework"
    fi

    target_binary="${app_framework}/${framework_name}"
    /usr/bin/lipo -thin "$arch" "$source_binary" -output "$target_binary"
    /usr/bin/codesign --force --sign - --timestamp=none "$target_binary"
    /usr/bin/codesign --force --sign - --timestamp=none "$app_framework"
done
