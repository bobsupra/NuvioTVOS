# AetherEngine + MPVKit coexistence

**Status:** Simulator Debug build succeeded with both stacks embedded (2026-08-12).
**Device validation:** still required on physical Apple TV before treating the gate as fully closed.

## Problem

MPVKit and AetherEngine’s FFmpegBuild both ship frameworks/modules named `Libavcodec`, `Libavformat`, `Libavutil`, etc. Linking stock packages into one app fails SPM/embed identity and C-header redefinition (`av_clipf_c`, …).

## Resolution (vendored forks)

| Package | Location | Change |
|---|---|---|
| FFmpegBuild 3.0.0 | `Vendor/FFmpegBuild` | Upstream-shipped `AetherLib*` frameworks/modules and install names; headers use `<AetherLib…/…>` cross-includes; current FFmpeg/dav1d/zimg/zvbi refresh |
| AetherEngine 6.57.0 | `Vendor/AetherEngine` | Path dep on `../FFmpegBuild`; all `import Libav*` → `import AetherLib*`; preserves Nuvio playback, diagnostics, SMB, subtitle, Dolby Vision, and AV1 Metal integrations |

FFmpegBuild 3.0.0 is already namespaced upstream; do not run the refresh script on its `AetherLib*.xcframework` trees. For older upstream `Lib*.xcframework` trees, use `Vendor/namespace_ffmpegbuild.py` once before adopting them.

## App integration

- Xcode links **MPVKit** (local) + **AetherEngine** (local Vendor).
- The AetherEngine product is **static**; its FFmpeg dependencies remain namespaced as `AetherLib*`,
  keeping their headers and framework identities separate from MPVKit's static FFmpeg objects.
- Default backend: **Aether** via `PlaybackSessionCoordinator`.
- One-way fallback: Aether → MPV on terminal error / audio delay / amplification / dual A/V URL / ASS Scale.
- The retired AVPlayer/Dolby Vision remux path has been deleted; app code does
  not import either FFmpeg C module graph directly. Aether owns DV playback.

## Verified on tvOS Simulator

- `xcodebuild` Debug `NuvioTV` scheme, Apple TV simulator: **BUILD SUCCEEDED**
- App embeds both sets, e.g.:
  - `AetherLibavcodec.framework` … `AetherLibzvbi.framework`
  - `Libavcodec.framework` … (MPVKit) + `Libmpv.framework`
- `otool -L` on Aether frameworks shows `@rpath/AetherLib*` only.
- `otool -L` on `AetherEngine.framework/AetherEngine` shows `@rpath/AetherLib*`;
  the app executable must not define AetherEngine's FFmpeg call sites.

## Remaining gate work (device)

1. Device Debug + Release archive
2. Alternating Aether → MPV → Aether sessions (≥5 cycles)
3. Stereo / 5.1 / Atmos on HDMI AVR or soundbar
4. First-frame / RSS / cache / app-size baseline
5. `otool -L` + codesign on the device archive

## LGPL notes

Aether’s FFmpegBuild frameworks are **dynamic** (LGPL App Store path): reproduce licenses, link source of the exact Vendor pin, do not merge into the main binary.
