<h1 align="center">FFmpegBuild</h1>

<p align="center">
  <b>Slim FFmpeg xcframeworks for Apple platforms.</b><br>
  Demux, decode, and a thin HLS-fMP4 mux path for AVPlayer bridging. No network stack, no CLI binaries.
</p>

<p align="center">
  <a href="https://github.com/superuser404notfound/FFmpegBuild/releases/latest"><img src="https://img.shields.io/github/v/release/superuser404notfound/FFmpegBuild?label=release&color=blue"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/FFmpegBuild"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FFFmpegBuild%2Fbadge%3Ftype%3Dswift-versions"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/FFmpegBuild"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FFFmpegBuild%2Fbadge%3Ftype%3Dplatforms"></a>
  <img src="https://img.shields.io/badge/FFmpeg-8.1-brightgreen">
  <img src="https://img.shields.io/badge/dav1d-1.5.1-blue">
  <img src="https://img.shields.io/badge/license-LGPL--2.1-lightgrey">
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

---

## Why

Full FFmpeg builds for iOS land at 40-70 MB because they bundle a TLS stack, encoders, filters, and a dozen protocols your app will never use. For a player, most of that is dead weight. Apple already ships HTTP/3, `URLSession`, `Network.framework`, VideoToolbox and AVFoundation. So this build strips out everything you don't need and keeps what you do.

**~10 MB per architecture, zero network dependencies, one build script.**

## In

| Library        | What it does                                          |
| -------------- | ----------------------------------------------------- |
| libavformat    | Demux MKV, MP4, WebM, MPEG-TS, MPEG-PS (VOB / DVD), DASH, AVI, OGG, FLV, plus raw elementary streams |
| libavcodec     | Decode video + audio (with VideoToolbox bridge)       |
| libavutil      | Shared primitives                                     |
| libswresample  | Audio resampling / channel remap / format convert     |
| libswscale     | Pixel-format convert (YUV → NV12 / P010) for the SW-decode path |
| libavfilter    | Trimmed filter set: zscale + tonemap + colorspace for HDR → SDR still extraction, bwdif + yadif for CPU deinterlacing on the SW-decode path, yadif_videotoolbox + hwupload for GPU (Metal) deinterlacing of VideoToolbox frames |
| **dav1d**      | Fast AV1 software decoder (separate xcframework)      |
| **zimg**       | zscale's resampling / colorspace backend (separate xcframework, link-only) |
| **libzvbi**    | DVB teletext decoder backend for `libzvbi_teletext` (separate xcframework, link-only) |

## Out

Anything the app layer should already handle or doesn't need:

- Network / TLS: FFmpeg reads from an `avio_alloc_context` callback, you wire `URLSession` to it
- Encoders, except FLAC and EAC3 (kept for the audio bridge that re-encodes non-streamable sources like TrueHD / DTS / DTS-HD MA. FLAC for the lossless 7.1 path, EAC3 5.1 for the default soundbar-compat path that surfaces surround via HDMI bitstream tunnel)
- Muxers, except MP4 / MOV / HLS (kept for the HLS-fMP4 producer that wraps streams for AVPlayer)
- libavdevice (libavfilter is included but trimmed to a handful of filters, see In)
- Most filters: libavfilter ships only buffer / buffersink / format / scale / zscale / tonemap / colorspace / bwdif / yadif / yadif_videotoolbox / hwupload
- Programs (`ffmpeg`, `ffplay`, `ffprobe`)
- Hardware accel layers other than VideoToolbox
- Text subtitle rendering (do that in SwiftUI)

## Build

```sh
./build.sh          # all platforms, dynamic frameworks (the shipped shape)
./build.sh static   # static variant, for apps that can meet LGPL 6(a) themselves
./build.sh package  # repackage frameworks without recompiling
./build.sh clean    # wipe everything
```

Needs Xcode 16+ and roughly 10-30 minutes depending on your machine. All sources (FFmpeg, dav1d, zimg, libzvbi) clone on first run.

Output lands in `Sources/` as xcframeworks, ready to consume via Swift Package Manager. The shipped xcframeworks contain **dynamic frameworks** (dylib-in-framework, `@rpath` install names); Xcode embeds and signs them in the app bundle automatically when you link the package. That is what keeps the LGPL relink requirement satisfiable for closed-source apps, see License below.

## Use

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/FFmpegBuild", from: "1.0.0")
]

// Target:
.product(name: "FFmpegBuild", package: "FFmpegBuild")
```

Pin `branch: "main"` instead of a version if you want to track the latest rebuilds (that is how [AetherEngine](https://github.com/superuser404notfound/AetherEngine) consumes it).

Then import the modules you need: `Libavformat`, `Libavcodec`, `Libavutil`, `Libswresample`, `Libswscale`, `Libavfilter`, `Libdav1d`. (`Libzimg` is a link-only backend for `zscale`, and `Libzvbi` a link-only backend for the teletext decoder; you don't import either directly.) The umbrella `FFmpegBuild` product links all of them plus the system frameworks (AudioToolbox, CoreMedia, CoreVideo, VideoToolbox) in one shot.

## Decoder support

- **Video (hardware via VideoToolbox)**: H.264, HEVC up to Main10 (HDR10 / DV Profile 8)
- **Video (software)**: AV1 (dav1d), VP9, VP8, MPEG-2, MPEG-4, VC-1
- **Audio**: AAC, AC3, EAC3 (incl. JOC detection for Atmos), FLAC, MP2, MP3, Opus, Vorbis, TrueHD, MLP, DTS, ALAC, PCM (incl. Blu-ray LPCM via `pcm_bluray`)
- **Subtitles**: SRT, ASS, SSA, WebVTT, PGS, DVB subtitle, DVB teletext (via libzvbi), DVD

HDR metadata (BT.2020, SMPTE ST 2084 / PQ, HLG, DV RPU) is preserved end-to-end so the decode pipeline can tag frames correctly.

## Size

Release configuration, dynamic framework binaries as embedded in the app (all six FFmpeg libraries plus the dav1d, zimg and zvbi backend frameworks):

| Target                            | FFmpeg    | dav1d    | zimg     | zvbi     | Total     |
| --------------------------------- | --------- | -------- | -------- | -------- | --------- |
| iOS / tvOS arm64                  | ~8.2 MB   | ~0.7 MB  | ~0.3 MB  | ~0.5 MB  | ~9.8 MB   |
| macOS universal (arm64 + x86_64)  | ~17.3 MB  | ~2.3 MB  | ~0.9 MB  | ~1.0 MB  | ~21.5 MB  |

Assembly-optimized paths are enabled where the Apple toolchain permits.

## Local FFmpeg patches

`build.sh` applies three small patches to the FFmpeg source after checkout (each documented in place):

- **`patch_ffmpeg`**: balances autoreleased Metal objects in `vf_yadif_videotoolbox.m` (upstream over-release crashes host apps whose GCD queues pop their last-resort autorelease pool at session teardown).
- **`patch_ffmpeg_pgssub`**: `pgssubdec.c` no longer flushes retained palettes/objects on an Epoch-Continue PCS (composition_state 3). An Epoch Continue set marks a seamless connection between two clips: a conformant set re-conveys everything it references (so skipping the flush is output-neutral), while a non-conformant bare PCS+WDS+END set relies on retained state and was dropped whole with "Invalid palette id 0" under the upstream flush (AetherEngine issue 142). Error resilience, not a spec requirement; Acquisition Point and Epoch Start keep flushing. Proposed upstream as FFmpeg PR 23851.
- **`patch_ffmpeg_matroska_tts`**: `matroskadec.c` logs a warning when a Matroska track carries a `TrackTimestampScale` other than 1.0. Timestamp behavior stays exactly as upstream implements it, which is what RFC 9559 specifies (block timestamps and BlockDuration are Track Ticks). The element is deprecated (maxver 3) and many readers ignore it, so a file carrying it may have been authored against such readers and mistime silently; the warning surfaces that condition (AetherEngine issue 145). Until 2.1.x this patch clamped TTS to 1.0; the clamp rested on a wrong reading of the RFC and was dropped after upstream review (FFmpeg PR 23852).

## Built with

This package is vibe-coded, assembled and maintained by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## License

**LGPL-2.1-or-later** ([LICENSE](LICENSE)), matching upstream FFmpeg's default license. The build enables neither `--enable-gpl` nor `--enable-version3`, so no GPL or LGPL-3.0 components are compiled in. Per component:

| Component | License |
| --- | --- |
| FFmpeg (all six libraries) | LGPL-2.1-or-later |
| dav1d | BSD-2-Clause |
| zimg | WTFPL |
| libzvbi (library sources) | LGPL-2.0-or-later, `ure.c` MIT |
| Build scripts / SPM stubs (this repo) | LGPL-2.1-or-later |

libzvbi's three GPL-2 source files (`packet-830.c`, `pdc.c`, `exp-vtx.c`) are **excluded from the build** and the two referenced entry points are replaced with LGPL stubs (`build.sh`, `patch_zvbi`), so the shipped binaries contain no GPL code. All license texts live in [LICENSES/](LICENSES/).

### Shipping in an App Store app

The xcframeworks are dynamic frameworks on purpose: LGPL section 6 requires that end users can swap in a modified version of the library. With dynamic linking your app binary stays yours (closed source is fine) and the obligations reduce to:

1. Link the package normally; Xcode embeds the frameworks in `YourApp.app/Frameworks/`. Do not merge them into the app binary (no mergeable-library trickery), that would recreate static linking.
2. Reproduce the license texts from [LICENSES/](LICENSES/) somewhere reasonable (acknowledgements screen, bundled file).
3. State that your app uses FFmpeg and friends, and link to the source of the exact build you ship (a tagged release of this repo, or your fork if you modified it).

If you build the `static` variant instead, those steps are not sufficient: LGPL 6(a) then requires you to provide your app's object files (or full source) so users can relink. That is realistic for open-source apps and rarely anything else, which is why static is not the shipped shape.

---

<p align="center"><sub>Used by <a href="https://github.com/superuser404notfound/AetherEngine">AetherEngine</a>.</sub></p>
