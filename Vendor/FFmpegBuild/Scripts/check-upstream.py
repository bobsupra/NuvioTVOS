#!/usr/bin/env python3
"""Report which pinned upstream sources have a newer release than the one being built.

The versions this package builds are shell variables in `build.sh`, not a manifest, so no
dependency bot sees them. That gap is what this closes: libzvbi 0.2.45 carried a security
advisory for two weeks before anyone here noticed, and only then because of an unrelated audit.

Run it locally:      python3 Scripts/check-upstream.py
Against a sibling:   python3 Scripts/check-upstream.py --libdovi ../LibDovi/build.sh

Exit code is 0 when every pin is current and 1 when at least one is behind, so CI can decide
whether to raise an issue.

Deliberately quiet when there is nothing to do. A watcher that reports every week gets filtered
into a folder and stops being read. It therefore keys on "upstream published something newer",
which is how a security fix arrives for all five of these projects: as a release. Advisories are
attached to the report as context for a component that is already behind, not as a separate
standing alarm.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"

COMPONENTS = [
    {
        "name": "FFmpeg",
        "source": "ffmpegbuild",
        "pattern": r'FFMPEG_VERSION="([^"]+)"',
        "repo": "FFmpeg/FFmpeg",
        "prefix": "n",
        # Only newer patches on the pinned minor line count as actionable. Moving off 8.1 is a
        # deliberate decision with its own tracking issue, and reporting n9.x every week would
        # train the reader to skip the whole report.
        "same_minor_only": True,
        "note": "a minor or major move is a deliberate decision, tracked in FFmpegBuild issue #2",
    },
    {
        "name": "dav1d",
        "source": "ffmpegbuild",
        "pattern": r'DAV1D_VERSION="([^"]+)"',
        "repo": "videolan/dav1d",
        "prefix": "",
    },
    {
        "name": "zimg",
        "source": "ffmpegbuild",
        "pattern": r'ZIMG_VERSION="([^"]+)"',
        "repo": "sekrit-twc/zimg",
        "prefix": "release-",
    },
    {
        "name": "libzvbi",
        "source": "ffmpegbuild",
        "pattern": r'ZVBI_VERSION="([^"]+)"',
        "repo": "zapping-vbi/zvbi",
        "prefix": "v",
    },
    {
        "name": "dolby_vision",
        "source": "libdovi",
        "pattern": r'DOVI_TAG="([^"]+)"',
        "repo": "quietvoid/dovi_tool",
        "prefix": "libdovi-",
    },
]


def api(path):
    request = urllib.request.Request(f"{API}{path}", headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "FFmpegBuild-upstream-watch",
    })
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def version_key(text):
    """Sortable tuple from the numeric run in a tag, ignoring any prefix or suffix.

    Returns None when the tag carries no version at all (a moving tag such as `latest`), so the
    caller can drop it rather than sort it to the front and report a phantom update.
    """
    numbers = re.findall(r"\d+", text)
    return tuple(int(n) for n in numbers) if numbers else None


def latest_tag(component):
    refs = api(f"/repos/{component['repo']}/git/matching-refs/tags/{component['prefix']}")
    candidates = []
    for ref in refs:
        tag = ref["ref"].removeprefix("refs/tags/")
        bare = tag.removeprefix(component["prefix"])
        key = version_key(bare)
        # A release-candidate or point tag with a suffix ("1.5.4-rc1") sorts as its numbers and
        # would outrank the release it precedes, so refuse anything that is not purely numeric.
        if key and re.fullmatch(r"[\d.]+", bare):
            candidates.append((key, tag, bare))
    return max(candidates) if candidates else None


def advisories(component):
    try:
        published = api(f"/repos/{component['repo']}/security-advisories")
    except urllib.error.HTTPError:
        return []   # not every repo has the endpoint enabled; absence is not an answer either way
    return [
        {"id": a.get("ghsa_id", "?"),
         "severity": a.get("severity") or "unspecified",
         "summary": (a.get("summary") or "").strip(),
         "published": (a.get("published_at") or "")[:10]}
        for a in published if a.get("published_at")
    ]


def pinned_version(text, component):
    match = re.search(component["pattern"], text)
    if not match:
        return None
    return match.group(1).removeprefix(component["prefix"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-sh", default="build.sh", help="FFmpegBuild's build.sh")
    parser.add_argument("--libdovi", default="../LibDovi/build.sh", help="LibDovi's build.sh")
    args = parser.parse_args()

    sources = {}
    for key, path in (("ffmpegbuild", args.build_sh), ("libdovi", args.libdovi)):
        try:
            sources[key] = open(path, encoding="utf-8").read()
        except OSError as error:
            print(f"cannot read {path}: {error}", file=sys.stderr)

    behind, current, unknown = [], [], []
    for component in COMPONENTS:
        text = sources.get(component["source"])
        if text is None:
            unknown.append((component["name"], f"{component['source']} build.sh not readable"))
            continue
        pinned = pinned_version(text, component)
        if pinned is None:
            unknown.append((component["name"], "no version string matched in build.sh"))
            continue
        try:
            newest = latest_tag(component)
        except (urllib.error.URLError, urllib.error.HTTPError) as error:
            unknown.append((component["name"], f"upstream query failed: {error}"))
            continue
        if newest is None:
            unknown.append((component["name"], "no numeric tags found upstream"))
            continue
        newest_key, newest_tag, newest_bare = newest
        pinned_key = version_key(pinned)
        if component.get("same_minor_only") and newest_key[:2] != pinned_key[:2]:
            # Newest overall is off our line; ask again restricted to the pinned major.minor.
            line = ".".join(str(n) for n in pinned_key[:2])
            on_line = [c for c in
                       [(version_key(r["ref"].removeprefix(f"refs/tags/").removeprefix(component["prefix"])),
                         r["ref"].removeprefix("refs/tags/"),
                         r["ref"].removeprefix(f"refs/tags/").removeprefix(component["prefix"]))
                        for r in api(f"/repos/{component['repo']}/git/matching-refs/tags/{component['prefix']}{line}.")]
                       if c[0] and re.fullmatch(r"[\d.]+", c[2])]
            if not on_line:
                current.append((component["name"], pinned, f"newest on the {line} line"))
                continue
            newest_key, newest_tag, newest_bare = max(on_line)
        if newest_key > pinned_key:
            behind.append({"name": component["name"], "pinned": pinned, "latest": newest_bare,
                           "tag": newest_tag, "repo": component["repo"],
                           "note": component.get("note"),
                           "advisories": advisories(component)})
        else:
            current.append((component["name"], pinned, None))

    lines = []
    if behind:
        lines.append("The following pinned sources have a newer release upstream.\n")
        for item in behind:
            lines.append(f"### {item['name']}: {item['pinned']} -> {item['latest']}\n")
            lines.append(f"- Pinned here: `{item['pinned']}`")
            lines.append(f"- Upstream: [`{item['tag']}`](https://github.com/{item['repo']}/releases/tag/{item['tag']})")
            if item["note"]:
                lines.append(f"- Note: {item['note']}")
            if item["advisories"]:
                lines.append("- Published security advisories for this project:")
                for a in item["advisories"]:
                    lines.append(f"  - [{a['id']}](https://github.com/{item['repo']}/security/advisories/{a['id']})"
                                 f" ({a['severity']}, {a['published']}): {a['summary']}")
                lines.append("  Check whether the pinned version predates the fix before deciding urgency.")
            lines.append("")
        lines.append("Bumping any of these means editing the version string, rebuilding every slice, "
                     "and releasing: the frameworks are prebuilt binaries in the repository.\n")
    if current:
        lines.append("Current: " + ", ".join(
            f"{name} {version}" + (f" ({why})" if why else "") for name, version, why in current))
    if unknown:
        lines.append("\nCould not be checked:")
        lines.extend(f"- {name}: {why}" for name, why in unknown)

    print("\n".join(lines))
    return 1 if behind else 0


if __name__ == "__main__":
    sys.exit(main())
