# Vendored playback dependencies

## AetherEngine (pin 7.55.0)

Local pin of [AetherEngine 7.55.0](https://github.com/superuser404notfound/AetherEngine/releases/tag/7.55.0), upstream commit `0947e2951475aece20a9a973a5a87265fe002444`. Imports remain rewritten to the namespaced FFmpeg modules below, and Nuvio's static product, four enabled default traits, local FFmpeg path dependency, and host integration patches are retained. The 7.55.0 upgrade incorporates exact seeks (`seek(to:exact:)`), AV1 dav1d keyframe snapping (`SWKeyframeSnap`), Matroska attachment skipping on open (`skipsContainerAttachments`), direct live audio read-ahead under video pressure (`DirectLiveAudioReadAhead`), 4:4:4 chroma site optimizations for Dolby Vision FEL, Profile 5 preview reshaping, AirPlay seek audio/bitmap subtitle fixes, and network trickle protection. Nuvio's custom remote playback startup patches, frame extraction, and local traits are preserved.

Retain the local spatial-bridge patch that reports persistent APAC encoding failures independently of successful TrueHD decoding, along with its regression tests. The patch is merged with the 7.40 bed-split renderer and its telemetry reporting.

Nuvio also retains its supplemental-codecs guard for non-Dolby-Vision displays, including the upstream Profile 7 to Profile 8.1 conversion. Explicit host DV assertions still enable the guarded route. The tagged API, architecture, and format docs are included for upstream documentation-consistency tests.

## FFmpegBuild 3.9.0 (namespaced upstream)

Local pin of [FFmpegBuild 3.9.0](https://github.com/superuser404notfound/FFmpegBuild/tree/3.9.0), upstream commit `3b398c8f6340fe5fb4a7cb9a2a211a16677171e0`. The upstream release ships the nine dynamic frameworks and SwiftPM targets under the `AetherLib*` namespace so they can embed next to MPVKit’s `Libav*` stack in the same app binary. The umbrella product is `AetherFFmpegBuild`.

| Upstream module | Nuvio module / framework |
|---|---|
| Libavcodec | AetherLibavcodec |
| Libavformat | AetherLibavformat |
| Libavutil | AetherLibavutil |
| Libswresample | AetherLibswresample |
| Libswscale | AetherLibswscale |
| Libavfilter | AetherLibavfilter |
| Libdav1d | AetherLibdav1d |
| Libzimg | AetherLibzimg |
| Libzvbi | AetherLibzvbi |

### Refreshing from upstream

1. Clone upstream FFmpegBuild at the desired tag into a temp dir.
2. For 3.0.0 and later, copy the already-namespaced `AetherLib*.xcframework` trees directly; do not run `namespace_ffmpegbuild.py` on them.
3. For older unprefixed releases, restore `Lib*.xcframework` trees and run `python3 Vendor/namespace_ffmpegbuild.py` once.
4. Rebase AetherEngine and retain its `../FFmpegBuild` path dependency and `import AetherLib*` names.

Keep the AetherEngine patch surface minimal so rebases stay manageable.

The Nuvio host offers an off-by-default setting for TrueHD Atmos and DTS:X spatial rendering to 9.1.6 (.render(.l916), delivering multichannel LPCM for direct routes such as AirPods Pro and HDMI, and APAC over AirPlay). LibTrueHD remains pinned to 3.1.0. DTS:X standard-presentation heights come from FFmpegBuild's patched `dca` decoder; object presentations continue to use the ordinary audio bridge. Spatial rendering requires tvOS 26 or later and a supported 48 kHz VOD source. TrueHD uses the source's channel presentation split into a speaker bed. The engine retains its ordinary audio bridge for other content, including ordinary DTS-HD MA.
