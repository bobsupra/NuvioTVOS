# Vendored playback dependencies

## AetherEngine (pin 6.0.1)

Local pin of [AetherEngine 6.0.1](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.0.1) with imports rewritten to the namespaced FFmpeg modules below.

## FFmpegBuild (based on 2.4.0, namespaced)

Local pin of [FFmpegBuild 2.4.0](https://github.com/superuser404notfound/FFmpegBuild/tree/2.4.0) with frameworks/modules renamed to `AetherLib*` so they can embed next to MPVKit’s `Libav*` stack in the same app binary.

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
2. Replace `Vendor/FFmpegBuild/Sources/Lib*.xcframework` (or re-run after restoring original names).
3. Run `python3 Vendor/namespace_ffmpegbuild.py`.
4. Re-apply `Package.swift` product/target renames if the script does not.
5. Rebase AetherEngine to the same pin and re-apply `import AetherLib*` renames + `Package.swift` path dependency on `../FFmpegBuild`.

Keep the AetherEngine patch surface minimal so rebases stay manageable.
