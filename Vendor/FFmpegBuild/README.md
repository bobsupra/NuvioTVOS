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
  <img src="https://img.shields.io/badge/dav1d-1.5.5-blue">
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
| libavformat    | Demux MKV, MP4, WebM, MPEG-TS, MPEG-PS (VOB / DVD), HLS, AVI, ASF / WMV, OGG, FLV, RealMedia (.rm / .rmvb), VobSub (.idx + .sub), plus raw elementary streams (including DTS, TrueHD and LATM AAC) |
| libavcodec     | Decode video + audio (with VideoToolbox bridge)       |
| libavutil      | Shared primitives                                     |
| libswresample  | Audio resampling / channel remap / format convert     |
| libswscale     | Pixel-format convert (YUV → NV12 / P010) for the SW-decode path |
| libavfilter    | Trimmed filter set: zscale + tonemap + colorspace for HDR → SDR still extraction, bwdif + yadif for CPU deinterlacing on the SW-decode path, idet + fieldmatch + decimate for inverse telecine, bwdif_videotoolbox + yadif_videotoolbox + hwupload for GPU (Metal) deinterlacing of VideoToolbox frames, fieldmatch_videotoolbox + decimate_videotoolbox for GPU (Metal) inverse telecine, dialoguenhance + pan + acompressor + alimiter (with abuffer / abuffersink / aformat / aresample) for AetherEngine's audio shaping |
| **dav1d**      | Fast AV1 software decoder (separate xcframework)      |
| **zimg**       | zscale's resampling / colorspace backend (separate xcframework, link-only) |
| **libzvbi**    | DVB teletext decoder backend for `libzvbi_teletext` (separate xcframework, link-only) |

## Out

Anything the app layer should already handle or doesn't need:

- Network / TLS: FFmpeg reads from an `avio_alloc_context` callback, you wire `URLSession` to it
- Encoders, except FLAC and EAC3 (kept for the audio bridge that re-encodes non-streamable sources like TrueHD / DTS / DTS-HD MA. FLAC for the lossless 7.1 path, EAC3 5.1 for the default soundbar-compat path that surfaces surround via HDMI bitstream tunnel; AAC-LC, ALAC and the AC-3 encoder E-AC-3 pulls in, for the silence AetherEngine appends to a stream-copied track whose audio ends before its video, AetherEngine#847)
- Muxers, except MP4 / MOV / HLS (kept for the HLS-fMP4 producer that wraps streams for AVPlayer)
- libavdevice (libavfilter is included but trimmed to a handful of filters, see In)
- Most filters: libavfilter ships only buffer / buffersink / format / scale / zscale / tonemap / colorspace / bwdif / yadif / idet / fieldmatch / decimate / bwdif_videotoolbox / yadif_videotoolbox / fieldmatch_videotoolbox / decimate_videotoolbox / hwupload, and on the audio side abuffer / abuffersink / aformat / aresample / pan / dialoguenhance / acompressor / alimiter
- Programs (`ffmpeg`, `ffplay`, `ffprobe`)
- Hardware accel layers other than VideoToolbox
- Text subtitle rendering (do that in SwiftUI)

## Build

```sh
./build.sh          # all platforms, dynamic frameworks (the shipped shape)
./build.sh static   # static variant, for apps that can meet LGPL 6(a) themselves
./build.sh package  # repackage frameworks without recompiling
./build.sh clean    # wipe everything
./build.sh --without-dtsx-heights   # leave out the DTS:X height patch, see below
```

Needs Xcode 16+ and roughly 10-30 minutes depending on your machine. All sources (FFmpeg, dav1d, zimg, libzvbi) clone on first run.

Later runs reuse the FFmpeg source only if it was patched by exactly the current `build.sh` and `patches/` with the same DTS:X switch. `build/ffmpeg-src.patched` holds a hash of those inputs, and any difference re-clones the source. Before 3.19.2 a tree patched by an older revision of a patch was kept and built silently, because each patch function skips a patch it finds already applied.

Output lands in `Sources/` as xcframeworks, ready to consume via Swift Package Manager. The shipped xcframeworks contain **dynamic frameworks** (dylib-in-framework, `@rpath` install names); Xcode embeds and signs them in the app bundle automatically when you link the package. That is what keeps the LGPL relink requirement satisfiable for closed-source apps, see License below.

## Use

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/FFmpegBuild", from: "3.19.3")
]

// Target:
.product(name: "AetherFFmpegBuild", package: "FFmpegBuild")
```

Pin `branch: "main"` instead of a version if you want to track the latest rebuilds. [AetherEngine](https://github.com/superuser404notfound/AetherEngine) pins a release with `.upToNextMinor(from:)`.

Then import the modules you need: `AetherLibavformat`, `AetherLibavcodec`, `AetherLibavutil`, `AetherLibswresample`, `AetherLibswscale`, `AetherLibavfilter`, `AetherLibdav1d`. (`AetherLibzimg` is a link-only backend for `zscale`, and `AetherLibzvbi` a link-only backend for the teletext decoder; you don't import either directly.) The umbrella `AetherFFmpegBuild` product links all of them plus the system frameworks (AudioToolbox, CoreMedia, CoreVideo, VideoToolbox) in one shot.

The FFmpeg API itself is unchanged: `avformat_open_input`, `avcodec_send_packet` and the rest keep their names. Only the module and framework names carry the prefix.

## Sitting next to another FFmpeg

Every FFmpeg packaged for Apple platforms declares the same target names, so before 3.0.0 this package could not resolve in an app that also had one. A fallback ladder with KSPlayer, mpv or MobileVLCKit in it is exactly such an app:

```
error: multiple similar targets 'Libavcodec', 'Libavfilter', 'Libavformat' and 3 others
appear in package 'ffmpegbuild' and 'ffmpegkit'
```

`moduleAliases` does not reach this: it renames Swift source targets, not binary ones. Two things had to change, and 3.0.0 changes both:

- **SwiftPM target and product names** are unique across the whole dependency graph. `AetherLibavcodec` no longer meets `Libavcodec`.
- **Framework bundle and install names**, because two `Libavcodec.framework` bundles cannot both live at `App.app/Frameworks/` under one `@rpath/Libavcodec.framework/Libavcodec`. The shipped install name is now `@rpath/AetherLibavcodec.framework/AetherLibavcodec`.

What the rename does **not** change is the C symbols: `_avcodec_open2` is still `_avcodec_open2` in every FFmpeg on earth. Distinct dynamic frameworks are enough on their own, because the two-level namespace records per reference which dylib it came from. A **static** FFmpeg in the same executable is the case that still bites: its symbols become definitions inside the executable and win for every object linked beside them. The fix there is to link the code that calls this build into its own dynamic framework, so its `_av*` bind at that framework's link. AetherEngine documents the recipe in [docs/api.md](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/api.md#one-ffmpeg-and-it-has-to-be-the-engines).

## Decoder support

- **Video (hardware via VideoToolbox)**: H.264, HEVC up to Main10 (HDR10 / DV Profile 8)
- **Video (software)**: AV1 (dav1d), VP9, VP8, MPEG-2, MPEG-4, VC-1, QuickTime RLE (qtrle), and the legacy Microsoft tail: MS-MPEG4 v1 / v2 / v3 (DivX 3.x in pre-2005 AVI rips), WMV1 / WMV2, WMV3 (WMV9). A native `.wmv` / `.asf` plays whole: the `asf` demuxer and every WMA decoder ship with it, because a decoder left out is a file with silent audio (the consumer's bridge finds no decoder for the id and the session falls to video-only). The Flash tail is here for the same reason: FLV1 (Sorenson Spark) and On2 VP6 / VP6F / VP6A with the era's audio, so a legacy `.flv` plays whole where before only H.264-in-FLV did. Flash Screen Video stays out, it needs zlib
- **Audio**: AAC, AC3, EAC3 (incl. JOC detection for Atmos), FLAC, MP2, MP3, Opus, Vorbis, TrueHD, MLP, DTS, ALAC, PCM (8, 16, 24 and 32-bit integer and 32 / 64-bit float, little and big endian, unsigned 8-bit, G.711 A-law / mu-law, Blu-ray LPCM via `pcm_bluray`, DVD LPCM), MP1, WMA Standard / Pro / Lossless / Voice, Nellymoser Asao, ADPCM-SWF, Speex
- **Subtitles**: SRT, ASS, SSA, WebVTT, PGS, DVB subtitle, DVB teletext (via libzvbi), DVD

HDR metadata (BT.2020, SMPTE ST 2084 / PQ, HLG, DV RPU) is preserved end-to-end so the decode pipeline can tag frames correctly.

## Size

Release configuration, dynamic framework binaries as embedded in the app (all six FFmpeg libraries plus the dav1d, zimg and zvbi backend frameworks):

| Target                            | FFmpeg    | dav1d    | zimg     | zvbi     | Total     |
| --------------------------------- | --------- | -------- | -------- | -------- | --------- |
| iOS / tvOS / visionOS arm64       | ~8.7 MB   | ~0.8 MB  | ~0.3 MB  | ~0.5 MB  | ~10.5 MB  |
| macOS universal (arm64 + x86_64)  | ~18.3 MB  | ~2.5 MB  | ~0.9 MB  | ~1.0 MB  | ~22.7 MB  |

Assembly-optimized paths are enabled where the Apple toolchain permits.

The dSYMs below add roughly 45 MB to a checkout of this package and nothing at all to your app: they are not embedded, Xcode moves them into the archive.

## Crash symbolication

Every slice a shipped app can embed (iOS, tvOS and visionOS device, macOS) carries its dSYM inside the xcframework. Xcode copies it into `.xcarchive/dSYMs` when it embeds the framework, so a crash inside FFmpeg symbolicates in the Organizer, and App Store Connect stops answering an upload with "The archive did not include a dSYM for Libavcodec.framework with the UUIDs [...]". Nothing to do on your side.

The libraries compile with `-gline-tables-only`: function names, file and line, and inlined frames, which is what a crash report resolves against, without the type information that makes up the bulk of full `-g` DWARF. Generated code is unchanged and the shipped binaries are still stripped; the debug information lives in the dSYM only.

Simulator slices ship without dSYMs deliberately. They reach neither an archive nor a user's crash report, and they would put another 45 MB of binaries into every clone. `./build.sh` writes theirs to `build/dsyms` if you want them locally.

Symbols and binaries are a pair per build. A dSYM from one release symbolicates nothing in an app that shipped another, because the UUIDs differ, and releases before 3.3.0 have no dSYMs at all: the debug information was never compiled in, so it cannot be produced for them after the fact.

## Privacy manifest

The frameworks that call one of Apple's required-reason APIs carry their own `PrivacyInfo.xcprivacy`, so an app embedding them does not declare FFmpeg's calls on its behalf and App Store Connect does not answer the upload with ITMS-91053 (FFmpegBuild#10). Today that is `AetherLibavformat`, `AetherLibavutil` and `AetherLibzvbi`, which `stat` files: file timestamp, reasons C617.1 (files in the app's own container) and 3B52.1 (media the user opened). None of them tracks or collects anything.

`build.sh` derives each manifest from the symbols the shipped binary imports, so an update that starts or stops calling one of these APIs changes the manifest with it, and `PrivacyManifestTests` checks the committed frameworks against their own symbol tables.

## Local FFmpeg patches

`build.sh` applies eighteen patches to the FFmpeg source after checkout (each documented in place; the larger ones live in `patches/`):

- **`patch_ffmpeg_yadif_videotoolbox`** (`patches/yadif-videotoolbox-one-submission.patch`): `vf_yadif_videotoolbox.m` sends each frame to the GPU once. Upstream commits a command buffer and waits for it once per plane, so an NV12 or P010 frame goes to the GPU twice and the decode thread waits twice. The planes are now dispatches in one command buffer with one wait. The output is unchanged (framemd5-identical for NV12 and P010, field and frame mode, both parities), and on an M1 a 1080p59.94 field took 1.86 ms instead of 2.34 ms (AetherEngine issue 1101).

  The same patch carries two fixes. The command buffer and encoder are autoreleased objects under FFmpeg's non-ARC build, and upstream also releases them by hand; that over-release crashed host apps whose GCD queues pop their last-resort autorelease pool at session teardown, so a per-frame `@autoreleasepool` is now their only release. And a texture the texture cache fails to create no longer goes into `CFRelease` as NULL.

  Since 3.19.2 the patch is [FFmpeg PR 26244](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/26244) as reviewed upstream, ported to n8.1.3. That adds two attachment fixes. The output pool hands out the same pixel buffer again, so its attachments are cleared before it takes the current frame's; before, an HLG tag from one frame stayed on every later untagged one. And the progressive output no longer carries the field count, field detail or bottom-field chroma location. The picture is unchanged (framemd5-identical to 3.19.1).

  One fix is ahead of upstream, where it comes with the planned factoring of both VideoToolbox deinterlacers: the output pool falls back to the link's negotiated range when the input frames context leaves it unspecified, as `bwdif_videotoolbox` does. That is the case behind `hwupload`, so full-range NV12 used to come out in a video-range (`420v`) buffer. The patch goes once the PR lands in the pinned tag.
- **`patch_ffmpeg_pgssub`**: `pgssubdec.c` emits an empty (clearing) subtitle instead of dropping a display set whose palette is missing, outside `AV_EF_EXPLODE`. PGS carries no end time, a cue is closed by the start of its successor, so dropping a damaged set also dropped the successor that closes the previous cue, and the predecessor overstayed its authored end until the next intact set arrived (AetherEngine issue 142). The pts is already set and no rect is allocated at that point, so this is the same clearing form the `object_count == 0` path returns. The first version of this patch instead kept the palette/object cache across an Epoch-Continue PCS; that was withdrawn because retained objects occupy the fixed `MAX_EPOCH_OBJECTS` slots and made a conformant connection set fail with "Too many objects in epoch". Proposed upstream as FFmpeg PR 23851.
- **`patch_ffmpeg_visionos`**: `videotoolbox.c` skips `kCVPixelBufferOpenGLESCompatibilityKey` on visionOS, where the key is unavailable because the platform has neither OpenGL ES nor OpenGL. Upstream selects it on `TARGET_OS_IPHONE`, which is 1 on visionOS (`TARGET_OS_IOS` is the one that is 0), so the hardware-decode path does not compile for `xros` without this. Nothing is lost: the attribute only asks CoreVideo to make the buffer bindable as a GL texture, and on visionOS every consumer is Metal, which the IOSurface properties set alongside it already cover.
- **`patch_ffmpeg_vc1_parser`**: `vc1_parser.c` seeds its parse context from `avctx->extradata` the way `vc1_decode_init` does. libavformat closes and reopens the parser on every reposition, so without this a seek lands on a zeroed `VC1Context` and the entry point BDU that follows is read at the wrong bit offset: `hrd_full[]` precedes `coded_size_flag` only when the sequence header set `hrd_param_flag`, which a zeroed context cannot know. The bit taken for `coded_size_flag` is then the leaky bucket fullness at that entry point, so a bucket below half falls back to a zero picture size ("Picture size 0x0 is invalid") and one above half takes a coded size out of the following payload, silently. Affects any VC-1 track whose encoder leaves the sequence header to the container (AetherEngine issue 490). Proposed upstream as FFmpeg PR 24458.
- **`patch_ffmpeg_dav1_tag`**: `isom_tags.c` and `movenc.c` learn the `dav1` sample entry, the AV1 variant of `av01` that MP4RA registers for Dolby Vision. Apple's HLS authoring spec requires it for Dolby Vision Profile 10.0, the AV1 analogue of HEVC Profile 5: an IPT-PQ-c2 signal with no compatible base layer, so `av01` is not an alternative there. FFmpeg carries the tag in neither direction, and both tables matter: without the `isom_tags.c` entry a `dav1` MP4 probes as "unknown codec", and without the `codec_mp4_tags` entry in `movenc.c` `validate_codec_tag()` rejects the requested tag and `avformat_write_header` fails with EINVAL, so a remux never starts. `dvh1` already sits in that second table, which is why the HEVC Profile 5 route works. The cross-compatible profiles (10.1 / 10.4) ride an `av01` sample entry with SUPPLEMENTAL-CODECS and are unaffected (AetherEngine issue 547).
- **`patch_ffmpeg_mpegts_mpeg1_probe`**: `mpegts.c` probes the payload of a PID labelled 0x03 (MPEG-1 audio), as it already does for 0x04 (MPEG-2 audio) and 0x0f (AAC). Upstream takes 0x03 at its word, so a restreamer that labels a DTS PID that way opens it as mp3, every packet fails with "Header missing", and the track never produces a frame (AetherEngine issue 641). A genuine MP2 or MP3 PID settles on its first PES packet, and a probe that finds nothing better keeps the PMT's codec. Proposed upstream as FFmpeg PR 24697. The same issue is why the raw `dts`, `truehd` and `loas` demuxers are enabled: the MPEG-TS content probe confirms a codec by running the raw demuxers' probes over the payload, so a codec without its raw demuxer in the build could never be confirmed, and the lenient mp3 probe named the track instead, whatever the label.
- **`patch_ffmpeg_eac3_dec3`**: `movenc.c` describes a Dolby Digital Plus track whose height channels and Atmos objects live in a dependent substream, the Blu-ray layout of an AC-3 core followed by an E-AC-3 dependent frame. Upstream builds the `dec3` box from the first access unit and gets two of its fields wrong there: `chan_loc` was taken from `chanmap` with a plain shift and a five-bit mask, although `chanmap` is read MSB-first and `chan_loc` spans nine bits, so 5.1.2 came out as no extra channels at all; and `complexity_index_type_a`, the ETSI TS 103 420 JOC extension, was read from the independent substream only, so the box lost it. tvOS then decodes the 5.1 bed and an Atmos receiver reports multichannel PCM (AetherEngine issue 728). The first half is upstream as `f10fdd6310` on master and is skipped once the pinned tag carries it; the second half is proposed upstream as FFmpeg PR 24963.
- **`patch_ffmpeg_movenc_fragment_end`**: `movenc.c` no longer aborts the process when a fragment is flushed with a packet still waiting in the interleaver that lies behind the samples already written for its track. `mov_flush_fragment` takes that packet's dts as the track end, but `check_pkt` may have moved the written samples past it (the first sample of a fragment is placed at the previous fragment's declared end, and later ones still below it are clamped), so the end fell before the last sample and `get_cluster_duration` hit `av_assert0(next_dts >= 0)`. Such a packet says nothing about where the track ends and is now skipped. Reached through AetherEngine's HLS segment muxer, which uses `frag_custom` and flushes with `av_write_frame(NULL)` (StreamX crash report, 2026-10-10). Proposed upstream as FFmpeg PR 25021.
- **`patch_ffmpeg_dca_x_heights`** (`patches/dca-xll-x-heights.patch`): the `dca` decoder decodes the height channels of DTS:X's standard presentation. They travel in a regular XLL channel set at the end of every lossless frame, behind the syncword upstream already recognises (it sets the "DTS-HD MA + DTS:X" profile) and then skips; the encoder also folds each of them at -3 dB into the 7.1 bed speaker under it. With the new decoder option `x_heights` (off by default) the decoder reads that channel set with FFmpeg's own XLL code and outputs 7.1.4: the bed exactly as coded, the heights still folded into it, next to the four height channels. Nothing is subtracted from the bed; separating the heights from it is left to the player (AetherEngine builds its layout from that bed, see its `BedRegression`). Without the option, and for every stream without the extension, the output is byte-identical to upstream (checked against FATE's DTS suite with and without downmix). A frame whose extension does not decode keeps 7.1.4 with silent heights. The alternate presentations (FFmpeg labels some "DTS:X IMAX") carry the same four fixed heights after one to five object channels; the same option locates that height channel set behind their CRC-protected prefix and control blocks and outputs it the same way, while the object channels are never decoded and stay in the bed where the encoder folded them. An alternate stream without heights keeps its 7.1. This replaces LibDTSX in AetherEngine (#798), whose port of this decoder combined with Apache-2.0 code came out LGPL-3.0-or-later.
- **`patch_ffmpeg_av1_delayed_rap`** (`patches/av1-delayed-rap.patch`): an AV1 Temporal Unit that carries a Sequence Header and opens with a hidden Key Frame (`show_frame = 0`) refreshing all eight reference slots is a keyframe. Encodes built on forward key frames open every GOP that way, and decoding from such a unit is correct right away, but upstream treats it as an inter frame in two places: `av1_parser` reports only a shown Key Frame, and for Matroska video that verdict replaces the block's flag; and muxers (mkvmerge, lavf) leave the SimpleBlock flag off, so `matroskadec` never builds an index and every seek fails, including the one back to the start after probing. The reporting file reached AetherEngine without a single keyframe and never started (AetherEngine issue 931). The patch adds `ff_av1_is_random_access_point()` to `libavformat/av1.c`, which reads the first frame header up to `refresh_frame_flags`; `matroskadec` flags an unflagged AV1 SimpleBlock that passes it and `av1_parser` reports the same case. A hidden Key Frame with a partial refresh, which libaom writes for `--enable-fwd-kf`, is left alone, since frames after it still reference the previous shown Key Frame. Proposed upstream as FFmpeg PR 25607.
- **`patch_ffmpeg_matroska_skip_attachments`** (`patches/matroska-skip-attachments.patch`): the matroska demuxer gains an AVClass with the option `skip_attachments` (off by default). Matroska attachments, in practice the fonts of ASS subtitles, are read in full while the file opens, before the first packet: tens of megabytes on anime releases, about 11 s of a WAN open in the report (AetherEngine issue 956). With the option the open passes over the Attachments element, both where mkvmerge and lavf write it (before the first Cluster) and behind the Clusters, where mkvpropedit appends it and only the SeekHead points at it. No attachment streams are created, Tags that target one are dropped without a warning, and tracks, their indices and packets are unchanged. Without the option the demuxer is unchanged.
- **`patch_ffmpeg_matroska_byte_seek_done`** (`patches/matroska-byte-seek-done.patch`): the matroska demuxer forgets an end of stream after a byte seek. It latches end of stream in its private `done` flag, and only its own `read_seek` cleared it, but `AVSEEK_FLAG_BYTE` and the generic fallback a failed index seek takes never reach `read_seek`. So once a file had been read to its end, or a read had failed, every later read returned EOF wherever the seek landed (AetherEngine issue 944: a subtitle side reader read EOF at second 0 of an 888 s file). `read_packet` now honours `io_repositioned` like oggdec and av1dec: it resets the parsing state at the new position, drops queued packets and a pending keyframe skip, and clears the flag.
- **`patch_ffmpeg_mpegts_dovi_descriptor`** (`patches/mpegts-dovi-descriptor.patch`): the `mpegts` muxer writes the Dolby Vision descriptors. The demuxer reads the DOVI video stream descriptor (`0xb0`) into the stream's `AV_PKT_DATA_DOVI_CONF` record, but the muxer never wrote it, so a Dolby Vision stream copied into a transport stream kept every RPU and lost its record. AetherEngine's live recordings are such a copy: played back, Profile 8.1 came out as HDR10, Profile 8.4 as HLG and Profile 5 as HDR10 with the wrong colours.

  An H.264 or HEVC stream whose record carries both its base layer and its RPU now gets the `0xb0` descriptor from that record (version, profile, level, the present flags, base-layer compatibility id, metadata compression). With compatibility id 0 (Profile 5) it also gets the `DOVI` registration descriptor, as Dolby's TS spec asks, placed before the `HEVC` registration so the stream keeps `HEVC` as its codec tag. Profile 5 stays on stream_type `0x24` instead of the spec's `0x06`, because players that do not know Dolby Vision cannot find the video under `0x06`.

  Left as they were: a stream without a base layer (its descriptor needs the base layer's PID, which the record does not carry), a base layer whose RPU was stripped, and streams without a record. The patch is the muxer half of upstream [FFmpeg PR 26097](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/26097) and goes once that lands in the pinned tag.
- **`patch_ffmpeg_mov_lazy_frag_index`** (`patches/mov-lazy-frag-index.patch`): the mov demuxer takes `lazy_frag_index` (off by default). A fragmented MP4 without a complete `sidx` is indexed while it opens: on a seekable input the header reads every top-level `moof` to the end of the file, one seek per fragment, before the first packet (a 4 minute file of 96 fragments on a WAN address: 12 s and about 90 requests to open). With the option the header stops behind the first `moof`, and a seek finds its fragment on demand: it estimates a byte offset, resynchronises on the next `moof`, checks that it is one (box sizes, track ids, a `tfdt` per track, sample data inside the `mdat`, the box chain behind it), and bisects on `tfdt`. An `mfra` is used for its `moof` offsets only, each checked against the `moof` it points at. The streams get their durations at open from the last fragment of each track. Files whose fragments carry no `tfdt`, or whose end cannot be found (a truncated file), are read as before. Checked packet for packet against the unpatched demuxer on 18 fragmented layouts; the same file opens in 0.9 s and 4 requests. Differences that remain with the option on: the per-stream bit rate is not set at open, a file with a separate `moof` per track delivers its packets in file order rather than interleaved across fragments, and a forward seek past a stream's last sync sample leaves the streams that follow at their end (the full index leaves them where they were). Without the option, and on files that are not fragmented, the demuxer is unchanged. `LazyFragIndexTests` checks that the option is there and that seeks land where the full index lands.
- **`patch_ffmpeg_bwdif_videotoolbox`** (`patches/bwdif-videotoolbox.patch`): adds `bwdif_videotoolbox`, bwdif as a Metal compute kernel over VideoToolbox frames. Upstream has bwdif for CUDA and Vulkan but not for Metal, so a GPU deinterlace ran yadif while the CPU fallback ran bwdif, and the picture depended on the path (AetherEngine issue 1102).

  The kernel does the integer arithmetic of `bwdifdsp.c` on integer samples held in floats. That is exact for samples of up to 10 bits, so deeper formats are refused. Its output equals CPU `bwdif` frame for frame (framemd5 on 1080i and 480i MPEG-2, testsrc2, NV12 and P010, both modes, both parities). The wrapper is `vf_yadif_videotoolbox.m` with bwdif's options (`mode` send_frame or send_field, default send_field; `parity`; `deint`), and it submits each frame to the GPU once, like `patch_ffmpeg_yadif_videotoolbox`. On an M1 a 1080p59.94 field costs 2.19 ms against 1.90 ms for `yadif_videotoolbox` in the same run (the 1.86 ms above is a separate run). Formats the kernel cannot run are refused when the graph is configured.

  Since 3.19.2 the patch is [FFmpeg PR 26276](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/26276) as reviewed upstream, ported to n8.1.3 without its docs and FATE tests. Compared with 3.19.x it unpacks 10-bit samples with an integer shift, clears a reused output buffer's attachments and drops the field attachments like the yadif patch, and gives full-range NV12 a full-range output pool when the input's frames context leaves the range unspecified (before, the output buffer said video range while the samples were full range). The patch goes once the PR lands in the pinned tag.

  n8.1.3's yadif filter callback returns nothing, where master returns an error, so both VideoToolbox patches wrap the upstream function and only log a failure. A failed frame still goes out, as it did before, with the attachments a successful frame would carry. Its pixels are whatever the reused buffer held.
- **`patch_ffmpeg_vc1_frame_threads`** (`patches/vc1-frame-threads.patch`): the `vc1` and `wmv3` decoders decode with frame threads. Upstream decodes them on one thread whatever the caller asks for, because neither declares a threading capability, so AetherEngine's software path asked for frame threads and got one. With the patch VC-1 spreads over the cores, and a seek catches up sooner (AetherEngine issue 1107). `vc1image` and `wmv3image` stay single-threaded.

  The patch follows the MPEG-4 Part 2 decoder. A reference picture reports the macroblock rows it has finished, and every read of a reference picture waits for the rows it needs, including reads above the top edge. The field flags that B field pictures read in direct mode move from the decoder context into one buffer per reference field picture. A reference picture that fails partway reports itself finished, so no thread waits for it forever.

  Damaged streams get three guards. Error concealment starts below the last row a picture has already reported, so it never rewrites a row another thread may be reading. A slice that repeats the picture header and turns a B picture into a reference picture, or back, is rejected. And `is_intra_more_likely()` in `error_resilience.c` now waits for the reference row its second comparison reads; that helper is shared, and the frame-threaded MPEG-4 Part 2 decoder gets the fix as well.

  On intact streams the output equals single-threaded decoding. FATE's `vc1`, `wmv3-drm` and `mss2` tests pass at 1 to 16 frame threads, and frame hashes across repeated seeks match at 1, 3 and 8 threads and match the upstream PR head. 304 damaged streams at 1, 3 and 8 threads decode without a hang or a crash, and ThreadSanitizer is clean on all 912 decodes. With the patch before (the PR's second round) it reported races in error concealment on some of them. Their pictures were not compared between thread counts. Slices that overlap still get concealed over each other, but only in a reference picture with slices, and such a picture lets the next frame thread start only once it is fully decoded.

  The reporter measured 1080 Blu-ray VC-1 on an M1 Max with 6 threads against 1. Progressive decodes 4.0 to 4.5 times as fast, interlaced with frame and field pictures mixed 3.6 to 4.6 times, field pictures only 2.2 to 2.4 times.

  The patch is [FFmpeg PR 26273](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/26273) as of its fifth review round (`8a20a7c021`), ported to n8.1.3 without its LoongArch fix and its FATE tests. It goes once the PR lands in the pinned tag.
- **`patch_ffmpeg_ivtc_videotoolbox`** (`patches/ivtc-videotoolbox.patch`): adds `fieldmatch_videotoolbox` and `decimate_videotoolbox`, inverse telecine as Metal compute kernels over VideoToolbox frames (AetherEngine issue 1108). CPU `fieldmatch` is plain C on one thread, and its comb test branches on every pixel, so grainy film costs several times what clean film does. AetherEngine runs both stages after the upload with these filters.

  The kernels do the per-pixel passes of `vf_fieldmatch.c` (the field difference map, the match sums, the comb mask and its block counts, the scene change sum, the woven output frame) and of `vf_decimate.c` (the block differences) on the same 8-bit integers, and return sums per thread. The CPU adds them in 64 bits and runs the CPU filters' decision code unchanged. Output equals CPU `fieldmatch,decimate` frame for frame, timestamps, matches, combed flags and drops included (80 combinations of 8 clips and 10 option sets, 480 to 1080, on the reporter's M1 Max; 63 of them repeated on an M1). `fieldmatch_videotoolbox` scores every candidate in one GPU pass, so a frame costs one wait, plus one for a woven output frame. `decimate_videotoolbox` waits once per cycle, because its metrics are read only when the cycle is complete. Matched and kept frames go out by reference. A woven frame comes from the output pool, whose buffer is reused, so its attachments are cleared before it takes the source frame's (since 3.19.2; before, an earlier frame's color tags could stay on it).

  Cost of AetherEngine's chain (`fieldmatch=order=auto:combmatch=full,decimate`, upload, `bwdif_videotoolbox`) against the same chain with these filters, per input frame on an M1, raw input, one filter thread, user plus system time:

  | Source | CPU stages | GPU stages |
  |---|---|---|
  | 480i 3:2 film, clean | 1.8 ms CPU, 1.7 ms wall | 1.5 ms CPU, 2.6 ms wall |
  | 480i 3:2 film, noisy | 6.1 ms CPU, 6.3 ms wall | 1.8 ms CPU, 3.7 ms wall |
  | 576i 3:2 film | 2.3 ms CPU, 2.5 ms wall | 1.8 ms CPU, 3.2 ms wall |
  | 1080i 3:2 film | 11.5 ms CPU, 12.6 ms wall | 3.5 ms CPU, 7.3 ms wall |

  The CPU time drops everywhere. On clean SD the wall time grows by about 0.8 ms, because the filter thread waits for the GPU, which is far inside a 33 ms frame.

  Supported: NV12, `fieldmatch` modes `pc`, `pc_n` (default) and `pc_u`, `combmatch` none, sc and full, `chroma=0`. Refused when the graph is configured: other pixel formats, `ppsrc`, `combdbg`, `chroma=1`, the `pcn` and `ub` modes, frames smaller than 32x16, and frame heights that are not a multiple of 4 (on a plane with an odd number of rows, `vf_fieldmatch.c` reads a row it never wrote, so its result cannot be reproduced). Not proposed upstream yet.

  The GPU filters carry copies of the CPU filters' decision code, so an FFmpeg tag bump can change one side and not the other while the patch still applies. `Tests/ivtc-videotoolbox/` holds the equality checks to run after every such bump (macOS only, they need the GPU).
- **`patch_ffmpeg_matroska_tts`**: `matroskadec.c` logs a warning when a Matroska track carries a `TrackTimestampScale` other than 1.0. Timestamp behavior stays exactly as upstream implements it, which is what RFC 9559 specifies (block timestamps and BlockDuration are Track Ticks). The element is deprecated (maxver 3) and many readers ignore it, so a file carrying it may have been authored against such readers and mistime silently; the warning surfaces that condition (AetherEngine issue 145). Until 2.1.x this patch clamped TTS to 1.0; the clamp rested on a wrong reading of the RFC and was dropped after upstream review (FFmpeg PR 23852).

## Building without the DTS:X height patch

`./build.sh --without-dtsx-heights` builds everything as usual but leaves out `patch_ffmpeg_dca_x_heights`. The `dca` decoder is then upstream's. DTS core, DTS-HD Master Audio and the 7.1 bed of DTS:X decode exactly as in stock FFmpeg n8.1.3, and the decoder has no `x_heights` or `x_presentation` option. The flag combines with `static`.

This is for apps that build AetherEngine without its `DTSXObjectAudio` trait (off by default) and want the height decoder out of the shipped binary too, not just unused (FFmpegBuild#12). The released xcframeworks always carry the patch, so this variant is one you build yourself.

- Switching in either direction re-clones the FFmpeg source (see Build above), so it needs no `clean`.
- `BUILD-INFO.txt` then says `DTS:X heights patch left out (--without-dtsx-heights)`, and `DTSXHeightsOptionTests` checks that the option is absent instead of present.
- AetherEngine with the trait off never asks for the option. With the trait on against such a build, it logs `no x_heights option` and plays DTS:X as its 7.1 bed.

To ship it, the app has to resolve your build instead of this repo, for AetherEngine too:

1. Fork this repo, run `./build.sh --without-dtsx-heights` and commit `Sources/` and `BUILD-INFO.txt`.
2. Tag that commit with the version you built from. AetherEngine requires FFmpegBuild within a version range, so the tag has to fall inside it. Your fork already carries that tag pointing at the patched binaries; delete it there first.
3. Point SwiftPM at the fork with a mirror. For a package, run `swift package config set-mirror --original https://github.com/superuser404notfound/FFmpegBuild --mirror https://github.com/<you>/FFmpegBuild`. For an Xcode project, put the same mirror into `YourApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json` (and into the `.xcworkspace` if you open one), then run File > Packages > Resolve Package Versions:

```json
{
  "object" : [
    {
      "mirror" : "https://github.com/<you>/FFmpegBuild",
      "original" : "https://github.com/superuser404notfound/FFmpegBuild"
    }
  ],
  "version" : 1
}
```

Your fork is then the source of the build you ship, which is what step 3 under [Shipping in an App Store app](#shipping-in-an-app-store-app) links to.

## Build record

The binaries are built on a local Mac, not in CI, so there is no attestation. Instead every build writes `BUILD-INFO.txt`, committed with the binaries it describes:

- the upstream tag and resolved commit of FFmpeg, dav1d, zimg and libzvbi, and a SHA-256 over the changes the patch functions made to each tree (tracked edits plus added files such as the libzvbi stub),
- the SHA-256 of `build.sh` and of every file in `patches/`,
- whether the DTS:X height patch was applied or left out (`--without-dtsx-heights`; a record without that line applied it),
- macOS, Xcode, clang and SDK versions, and the versions of meson, ninja, autotools and pkg-config,
- FFmpeg's configure line for every slice, as recorded in its `config.h`,
- the SHA-256 of every shipped binary.

The inputs are captured right after patching, before anything compiles, so `./build.sh package` does not credit the current toolchain with older objects. Releases up to 3.9.0 have no build record; for those, the toolchain can still be read from the binaries (`LC_BUILD_VERSION`) and their dSYMs (`DW_AT_producer`). A rebuild from the same inputs is not expected to be byte-identical.

## Keeping the pins current

The versions this package builds are shell variables in `build.sh`, not a manifest, so no dependency bot sees them. `Scripts/check-upstream.py` compares all five (FFmpeg, dav1d, zimg, libzvbi, and `dolby_vision` over in [LibDovi](https://github.com/superuser404notfound/LibDovi)) against what upstream has published:

```bash
python3 Scripts/check-upstream.py --libdovi ../LibDovi/build.sh
```

It exits 1 when something is behind and prints why, with any published security advisory for that project attached as context. FFmpeg is compared against the newest patch on the pinned minor line rather than the newest tag overall: moving off `8.1` is a deliberate decision, not a weekly reminder.

The [Upstream watch](.github/workflows/upstream-watch.yml) workflow runs it every Monday and keeps exactly one issue: opened when a pin falls behind, rewritten while it stays behind, and closed by the run that finds everything current again. Nothing is posted when there is nothing to do.

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
