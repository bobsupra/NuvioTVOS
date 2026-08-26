#!/usr/bin/env bash
# A picture that states its own source frame number, for `aetherctl play --picture-probe` (AE#418).
#
# Every axis observable the engine has describes what it WROTE. None of them says where AVPlayer then
# PUT that segment, and AE#408 shipped an early-opening gate on an assumption about exactly that. With
# this fixture the question needs no assumption: 12 blocks on one pixel row carry bit k of the frame
# index, so one row of pixels out of AVPlayer's own video output decodes to a source time.
#
# Pair it with Scripts/mkv-cue-fixture.py to get the AE#408 shape (Cues that are not sync samples):
#
#   Scripts/timecode-fixture.sh /tmp
#   python3 Scripts/mkv-cue-fixture.py /tmp/tc-drought.mkv /tmp/tc-cues-lie.mkv \
#       "$(python3 -c 'print(",".join(str(i) for i in range(1,120)))')"
#   swift run aetherctl play --seconds 12 --start-position 53 --picture-probe file:///tmp/tc-cues-lie.mkv
#
# `tc-drought.mkv` is the control arm (its Cues ARE its sync samples, `axisErr` stays 0 on every
# tick); `tc-cues-lie.mkv` is the case. A resume at 53 s re-aims the gate, opens at 43.000 against a
# boundary at 52.000 and reads `axisErr=-9.000`, the whole re-aim, constant for the run. (Before
# AE#423 evened out the backoff steps it opened at 38.417 and read `-13.583`.)
#
# AE#418 round 2 needs one seek on top of that, because the axis COMPOSES and a resume alone cannot
# show it. Add `--seek-every 12 --seek-count 1 --seek-pattern <target>` to the line above:
#
#   80  a seek onto an axis-true segment: the axis must stay -9.000 (the reporter's failing case)
#   65  a seek that re-places the overlong segment: the axis doubles to -18.000
#   60  a seek whose restart re-aims 5 s more: the axis composes to -14.000
#
# `capErr` is the verdict in all three, and it is the error a host placing a cue at `sourceTime`
# would make: about +0.017 (one frame at 24 fps) when the engine describes the axis correctly, and
# -8.983 for each of the three under 6.43.0.
#
# For magnitudes this fixture cannot reach, engineer the droughts: a key 3 s below a boundary gives
# -3, 5 s gives -5, and a key under a second below one gives an axis AVPlayer THROWS AWAY at the
# next seek (measured: -0.500 and -0.875 snap to 0, -1.000 and above survive).
set -euo pipefail
OUT_DIR="${1:?usage: timecode-fixture.sh <out-dir>}"
DUR=120
FPS=24

filters=""
for k in $(seq 0 11); do
  bit=$((1 << k))
  x=$((k * 52))
  [ -n "$filters" ] && filters="${filters},"
  filters="${filters}drawbox=x=${x}:y=0:w=50:h=50:color=white:t=fill:enable='gt(bitand(n\\,${bit})\\,0)'"
done

# Sync samples where we ask for them, with a deliberate 12 s drought between 43 s and 55 s: long
# enough that the gate's 4 / 8 / 16 / 32 s backoff has to escalate to reach a covering sample.
KEYS="0,1.5,3.2,7.1,10.3,14.9,18.2,22.7,26.1,30.5,34.2,38.4,43.0,55.0,56.5,58.9,61.3,64.8,67.2,71.6,75.1,79.4,83.8,87.2,91.6,95.1,99.5,103.2,107.8,111.4,115.9"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=640x360:r=${FPS}:d=${DUR}" \
  -f lavfi -i "sine=frequency=440:duration=${DUR}" \
  -vf "$filters" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 1000 -sc_threshold 0 \
  -force_key_frames "$KEYS" -b:v 2M \
  -c:a aac -b:a 128k -shortest \
  "$OUT_DIR/tc-drought.mkv"
echo "wrote $OUT_DIR/tc-drought.mkv (${DUR}s, ${FPS}fps, source time = frame index / ${FPS})"
