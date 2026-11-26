# Equality checks for fieldmatch_videotoolbox and decimate_videotoolbox

These scripts check that `patches/ivtc-videotoolbox.patch` still gives the output of CPU `fieldmatch` and `decimate`. Run them after any change to the patch and after every FFmpeg tag bump. The GPU filters copy the CPU filters' decision code, so an upstream change to `vf_fieldmatch.c` or `vf_decimate.c` would apply cleanly and still make the two disagree. Nothing in `swift test` catches that.

They come from AetherEngine issue 1108 (classicjazz) and run on macOS only, because they need the GPU.

## Layout

The scripts expect this next to each other:

```
<dir>/ffmpeg-src      FFmpeg n8.1.3 with patches/bwdif-videotoolbox.patch and patches/ivtc-videotoolbox.patch applied
<dir>/ivtc-tests      a copy of this folder, with a fixtures/ folder inside
```

## Steps

1. In `ffmpeg-src`, run `ivtc-configure.sh` (a minimal macOS build), then `make ffmpeg`.
2. `make-fixtures.sh` writes the test clips into `fixtures/` with a Homebrew ffmpeg. It needs the GPL `telecine` and `tinterlace` filters, which is why it uses Homebrew's build. The clips are only inputs.
3. `harness/build.sh`, then `harness/harness_fm <ffmpeg-src>/libavfilter/metal/vf_fieldmatch_videotoolbox.metal` and `harness/harness_dm <ffmpeg-src>/libavfilter/metal/vf_decimate_videotoolbox.metal`. They compare every number the decision code reads against `vf_fieldmatch.c` and `vf_decimate.c` compiled from the same tree. Expected: `0 differences` and exit code 0.
4. `matrix.sh` runs every clip through ten option sets, CPU against GPU, and compares the framemd5 (timestamps included), `fieldmatch`'s per-frame debug line and `decimate`'s per-cycle lines. Every line should read `same` three times.

`timing-engine.sh` compares AetherEngine's GPU-engine chain with CPU and GPU cadence filters. `platform-compile.sh` compiles the kernels and wrappers for every Apple platform.

Last run: 2026-11-22 on an M1, harness 0 differences, matrix 63 of 63 identical.
