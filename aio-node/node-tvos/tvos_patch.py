#!/usr/bin/env python3
"""Turns a nodejs-mobile source tree (iOS) into a tvOS build.

nodejs-mobile builds Node.js as NodeMobile.framework for iOS. tvOS is the same
OS family (TARGET_OS_IPHONE is 1 there too), so its patches mostly apply as
they are. What differs:

- the SDKs (appletvos / appletvsimulator) and the minimum-version flags,
- APIs that tvOS forbids outright (fork / exec*), which iOS only fails at run
  time: libuv already returns ENOSYS from uv_spawn on tvOS, Node's
  process.execve() needs the same guard,
- the framework project (device family 3, tvOS deployment target).

Usage: tvos_patch.py <nodejs-mobile source tree> [tvOS deployment target]
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
target = sys.argv[2] if len(sys.argv) > 2 else "18.0"


def edit(relative, transform):
    path = root / relative
    text = path.read_text()
    new = transform(text)
    if new == text:
        sys.exit(f"tvos_patch: nothing changed in {relative}")
    path.write_text(new)
    print(f"patched {relative}")


def replace_once(old, new):
    def transform(text):
        count = text.count(old)
        if count != 1:
            sys.exit(f"tvos_patch: expected one {old!r}, found {count}")
        return text.replace(old, new)
    return transform


def replace_all(old, new, expected):
    def transform(text):
        count = text.count(old)
        if count != expected:
            sys.exit(f"tvos_patch: expected {expected}× {old!r}, found {count}")
        return text.replace(old, new)
    return transform


# 1. gyp: the target SDKs and the deployment target.
def common_gypi(text):
    for old, new in [
        ("'SDKROOT': 'iphoneos',", "'SDKROOT': 'appletvos',"),
        ("'SDKROOT': 'iphonesimulator',", "'SDKROOT': 'appletvsimulator',"),
    ]:
        text = replace_once(old, new)(text)
    text, count = re.subn(
        r"'IPHONEOS_DEPLOYMENT_TARGET': '[0-9.]+',",
        f"'IPHONEOS_DEPLOYMENT_TARGET': '{target}',",
        text,
    )
    if count != 1:
        sys.exit(f"tvos_patch: expected one IPHONEOS_DEPLOYMENT_TARGET in common.gypi, found {count}")
    return text


edit("common.gypi", common_gypi)


# 2. gyp's Xcode emulation: tvOS minimum-version flags for the appletv SDKs.
def xcode_emulation(text):
    pattern = re.compile(r'^(\s*)if sdk_path_basename\.lower\(\)\.startswith\("iphonesimulator"\):', re.M)
    match = pattern.search(text)
    if not match:
        sys.exit("tvos_patch: version-min block not found in xcode_emulation.py")
    indent = match.group(1)
    inner = indent + "    "
    block = (
        f'{indent}if sdk_path_basename.lower().startswith("appletvsimulator"):\n'
        f'{inner}self._Appendf(lst, "IPHONEOS_DEPLOYMENT_TARGET", "-mtvos-simulator-version-min=%s")\n'
        f'{indent}elif sdk_path_basename.lower().startswith("appletvos"):\n'
        f'{inner}self._Appendf(lst, "IPHONEOS_DEPLOYMENT_TARGET", "-mtvos-version-min=%s")\n'
        f'{indent}elif sdk_path_basename.lower().startswith("iphonesimulator"):'
    )
    return text[:match.start()] + block + text[match.end():]


edit("tools/gyp/pylib/gyp/xcode_emulation.py", xcode_emulation)


# 3. Node: process.execve() — execve is unavailable on tvOS.
def process_methods(text):
    text = replace_once(
        '#include "async_wrap-inl.h"\n',
        '#include "async_wrap-inl.h"\n#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n',
    )(text)
    return replace_once(
        "  execve(*executable, argv.data(), envp.data());\n",
        "#if defined(__APPLE__) && TARGET_OS_TV\n"
        "  errno = ENOTSUP;  // no new processes on tvOS\n"
        "#else\n"
        "  execve(*executable, argv.data(), envp.data());\n"
        "#endif\n",
    )(text)


edit("src/node_process_methods.cc", process_methods)


# 4. The framework project and its build script.
def pbxproj(text):
    text = replace_all("SDKROOT = iphoneos;", "SDKROOT = appletvos;", 2)(text)
    text = replace_all('TARGETED_DEVICE_FAMILY = "1,2";', "TARGETED_DEVICE_FAMILY = 3;", 2)(text)
    text, count = re.subn(
        r"(\n(\s*)IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;)",
        lambda m: f"{m.group(1)}\n{m.group(2)}TVOS_DEPLOYMENT_TARGET = {target};",
        text,
    )
    if count == 0:
        sys.exit("tvos_patch: no IPHONEOS_DEPLOYMENT_TARGET in the framework project")
    return text


edit("tools/ios-framework/NodeMobile.xcodeproj/project.pbxproj", pbxproj)


def prepare_script(text):
    text = replace_all('-sdk "iphoneos"', f'-sdk "appletvos" TVOS_DEPLOYMENT_TARGET={target}', 1)(text)
    text = replace_all('-sdk "iphonesimulator"', f'-sdk "appletvsimulator" TVOS_DEPLOYMENT_TARGET={target}', 1)(text)
    text = text.replace("Release-iphoneos", "Release-appletvos")
    text = text.replace("Release-iphonesimulator", "Release-appletvsimulator")
    # CI runners have little disk: move the archives instead of copying them
    # and drop the object files once they are archived.
    text = replace_all("cp $LIBRARY_PATH/$output_file", "mv $LIBRARY_PATH/$output_file", 2)(text)
    text = replace_all(
        "  make -C out v8_compiler BUILDTYPE=Release -j$(getconf _NPROCESSORS_ONLN)\n",
        "  make -C out v8_compiler BUILDTYPE=Release -j$(getconf _NPROCESSORS_ONLN)\n"
        "  rm -rf $LIBRARY_PATH/obj.target $LIBRARY_PATH/obj.host\n",
        2,
    )(text)
    # Keep compiling after an error, so one CI run lists every tvOS problem.
    text, count = re.subn(r"\n(\s*)make -j\$\(getconf _NPROCESSORS_ONLN\)\n", r"\n\1make -k -j$(getconf _NPROCESSORS_ONLN)\n", text)
    if count != 2:
        sys.exit(f"tvos_patch: expected 2 main make calls, found {count}")
    return text


edit("tools/ios_framework_prepare.sh", prepare_script)
print(f"tvOS patches applied (deployment target {target}).")
