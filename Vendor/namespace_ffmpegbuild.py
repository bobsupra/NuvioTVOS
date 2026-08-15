#!/usr/bin/env python3
"""Rename FFmpegBuild dynamic frameworks so they coexist with MPVKit's Libav* stack."""
from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "FFmpegBuild" / "Sources"

LIBS = [
    "Libavcodec",
    "Libavformat",
    "Libavutil",
    "Libswresample",
    "Libswscale",
    "Libavfilter",
    "Libdav1d",
    "Libzimg",
    "Libzvbi",
]

PREFIX = "Aether"


def new_name(old: str) -> str:
    return f"{PREFIX}{old}"


def run(cmd: list[str]) -> None:
    subprocess.check_call(cmd)


def install_name_id(binary: Path, framework: str) -> None:
    run(["install_name_tool", "-id", f"@rpath/{framework}.framework/{framework}", str(binary)])


def rewrite_deps(binary: Path) -> None:
    out = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    for line in out.splitlines()[1:]:
        path = line.strip().split(" (", 1)[0]
        if not path.startswith("@rpath/Lib"):
            continue
        # @rpath/Libavcodec.framework/Libavcodec
        parts = path.split("/")
        if len(parts) < 3:
            continue
        old_fw = parts[1].removesuffix(".framework")
        if old_fw not in LIBS:
            continue
        new_fw = new_name(old_fw)
        new_path = f"@rpath/{new_fw}.framework/{new_fw}"
        if path == new_path:
            continue
        run(["install_name_tool", "-change", path, new_path, str(binary)])


def remove_code_signature(binary: Path) -> None:
    """Remove the upstream signature after renaming the Mach-O and bundle.

    Xcode may preserve an existing framework CodeDirectory identifier while
    signing an embedded package. After namespacing, that leaves (for example)
    ``com.aetherengine.Libzimg`` inside ``AetherLibzimg.framework`` and
    installd rejects the app before launch. The bundle's Info.plist is updated
    below and the consuming app supplies the final platform signature, so the
    vendored binary must not carry the upstream identifier.
    """
    result = subprocess.run(
        ["codesign", "--remove-signature", str(binary)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(
            f"codesign --remove-signature failed for {binary}: {result.stderr.strip()}"
        )


def update_framework_plist(plist_path: Path, framework: str) -> None:
    with plist_path.open("rb") as f:
        data = plistlib.load(f)
    data["CFBundleExecutable"] = framework
    data["CFBundleName"] = framework
    old_id = data.get("CFBundleIdentifier", f"com.aetherengine.{framework}")
    # Keep domain; replace trailing product name
    if "." in old_id:
        base = old_id.rsplit(".", 1)[0]
        data["CFBundleIdentifier"] = f"{base}.{framework}"
    else:
        data["CFBundleIdentifier"] = f"com.aetherengine.{framework}"
    with plist_path.open("wb") as f:
        plistlib.dump(data, f)


def update_xcframework_plist(plist_path: Path, old: str, new: str) -> None:
    with plist_path.open("rb") as f:
        data = plistlib.load(f)
    libs = data.get("AvailableLibraries", [])
    for entry in libs:
        for key in ("BinaryPath", "LibraryPath"):
            if key in entry and isinstance(entry[key], str):
                entry[key] = entry[key].replace(old, new)
    with plist_path.open("wb") as f:
        plistlib.dump(data, f)


def write_modulemap(path: Path, framework: str) -> None:
    # Preserve prior excludes if present
    excludes = [
        "d3d11va.h",
        "d3d12va.h",
        "dxva2.h",
        "qsv.h",
        "vdpau.h",
    ]
    lines = [f"framework module {framework} [system] {{", '    umbrella "."']
    for h in excludes:
        lines.append(f'    exclude header "{h}"')
    lines.append("    export *")
    lines.append("}")
    lines.append("")
    path.write_text("\n".join(lines))


def rewrite_header_imports(framework_dir: Path) -> None:
    """Point cross-framework FFmpeg includes at the namespaced modules."""
    headers = framework_dir / "Headers"
    if not headers.is_dir():
        return
    for header in headers.rglob("*.h"):
        text = header.read_text(errors="surrogateescape")
        rewritten = text
        for old in LIBS:
            new = new_name(old)
            rewritten = rewritten.replace(f"<{old}/", f"<{new}/")
            rewritten = rewritten.replace(f'"{old}/', f'"{new}/')
            # FFmpeg 8.1.2 exports canonical lowercase include prefixes
            # (`libavutil/...`) rather than framework-cased ones.
            lowercase = old.lower()
            rewritten = rewritten.replace(f"<{lowercase}/", f"<{new}/")
            rewritten = rewritten.replace(f'"{lowercase}/', f'"{new}/')
        if rewritten != text:
            header.write_text(rewritten, errors="surrogateescape")


def find_binaries(framework_dir: Path, framework: str) -> list[Path]:
    found: list[Path] = []
    # iOS/tvOS: FrameworkName/FrameworkName
    direct = framework_dir / framework
    if direct.is_file():
        found.append(direct)
    # macOS: Versions/A/FrameworkName
    versions = framework_dir / "Versions"
    if versions.is_dir():
        for p in versions.rglob(framework):
            if p.is_file() and not p.is_symlink():
                found.append(p)
    return found


def process_xcframework(old: str) -> None:
    new = new_name(old)
    src = ROOT / f"{old}.xcframework"
    if not src.exists():
        print(f"skip missing {src}")
        return
    dst = ROOT / f"{new}.xcframework"
    if dst.exists():
        shutil.rmtree(dst)
    print(f"copy {src.name} -> {dst.name}")
    # Preserve versioned macOS framework symlinks. Dereferencing them duplicates
    # Versions/Current and leaves the renamed top-level binary link dangling.
    shutil.copytree(src, dst, symlinks=True)

    # Rename each slice's .framework directory
    for slice_dir in [p for p in dst.iterdir() if p.is_dir()]:
        old_fw = slice_dir / f"{old}.framework"
        new_fw = slice_dir / f"{new}.framework"
        if not old_fw.exists():
            continue
        old_fw.rename(new_fw)

        # Rename binary / Versions structure
        # macOS style
        versions_a = new_fw / "Versions" / "A"
        if versions_a.exists():
            old_bin = versions_a / old
            new_bin = versions_a / new
            if old_bin.exists() and not old_bin.is_symlink():
                old_bin.rename(new_bin)
            # Update Current symlink if needed later
            # Headers stay; Resources; rename Current binary symlink
            current = new_fw / "Versions" / "Current"
            # top-level symlinks typically: Headers, Modules, framework binary
            for link_name in [old, "Headers", "Modules", "Resources", "Info.plist"]:
                link = new_fw / link_name
                if link.is_symlink() or link.exists():
                    # recreate binary symlink
                    pass
            top_bin_link = new_fw / old
            if top_bin_link.is_symlink() or top_bin_link.exists():
                if top_bin_link.is_symlink() or top_bin_link.is_file():
                    top_bin_link.unlink()
                # point to Versions/Current/new
                try:
                    os.symlink(f"Versions/Current/{new}", new_fw / new)
                except FileExistsError:
                    pass
            # Fix Versions/Current if it's a symlink to A
            current_bin = versions_a / new
        else:
            old_bin = new_fw / old
            new_bin = new_fw / new
            if old_bin.exists():
                old_bin.rename(new_bin)

        # Remove code signature (invalid after install_name_tool)
        sig = new_fw / "_CodeSignature"
        if sig.exists():
            shutil.rmtree(sig)
        sig_a = versions_a / "_CodeSignature" if versions_a.exists() else None
        if sig_a and sig_a.exists():
            shutil.rmtree(sig_a)

        # Info.plist
        for plist in [new_fw / "Info.plist", versions_a / "Resources" / "Info.plist" if versions_a.exists() else None]:
            if plist and plist.exists() and not plist.is_symlink():
                update_framework_plist(plist, new)

        # modulemap
        for mm in new_fw.rglob("module.modulemap"):
            if mm.is_file() and not mm.is_symlink():
                write_modulemap(mm, new)

        rewrite_header_imports(new_fw)

        # install names on all arch slices of the binary
        for binary in find_binaries(new_fw, new):
            print(f"  rewrite {binary.relative_to(dst)}")
            try:
                install_name_id(binary, new)
                rewrite_deps(binary)
                remove_code_signature(binary)
            except subprocess.CalledProcessError as e:
                print(f"  WARN install_name_tool failed: {e}", file=sys.stderr)

    # xcframework Info.plist paths
    xcf_plist = dst / "Info.plist"
    if xcf_plist.exists():
        update_xcframework_plist(xcf_plist, old, new)

    # Remove original after successful processing of all? Keep until all done for safety.
    print(f"done {new}")


def main() -> None:
    if not ROOT.exists():
        sys.exit(f"missing {ROOT}")
    for old in LIBS:
        process_xcframework(old)
    # Remove originals so SPM only sees namespaced artifacts
    for old in LIBS:
        src = ROOT / f"{old}.xcframework"
        if src.exists():
            print(f"remove original {src.name}")
            shutil.rmtree(src)
    print("all frameworks namespaced")


if __name__ == "__main__":
    main()
