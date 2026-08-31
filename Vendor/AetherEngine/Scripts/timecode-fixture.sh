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
# Arm 60 lands two ways, 2 of 4 each, and both are correct: AVPlayer either fetches seg12 (worth
# -5.000, the axis composes to -14.000 and the placement is confirmed) or seg17 (worth 0.000, which
# extends the run it is already playing, so it opens no run of its own and prints
# `#418 seg17 opened no run of its own to measure`). Read `capErr`, not the segment number: it stays
# inside a frame of zero either way. Under round 3 the second shape printed a CONFIRMATION, because
# the reading it took was the previous epoch's run.
#
# `capErr` is the verdict in all three, and it is the error a host placing a cue at `sourceTime`
# would make: about +0.017 (one frame at 24 fps) when the engine describes the axis correctly, and
# -8.983 for each of the three under 6.43.0.
#
# AE#418 round 3 uses the same three arms as a CONTROL. The axis is no longer predicted: the engine
# reads `AVPlayerItem.loadedTimeRanges` after each seam and measures where AVPlayer put the segment,
# so every arm above must print `#418 segN placement confirmed` and none of them may print
# `#418 segN placed on base ...`.
#
# AE#418 round 4 needs a second fixture, because this one has no B-FRAMES and that is what hid the
# case. `-preset ultrafast` disables them, so its dts and pts are one number and a gate opening on a
# random-access point is presented where it is decoded. Real content is not like that. The script
# writes `tc-bframes.mkv` alongside (`-bf 3`, `b-pyramid=normal`, `has_b_frames=2`), and on it the
# same resume opens `actual=42917 anchorPts=43000`: an epoch worth -9.083 s by the decode time and
# -9.000 s by the presented one. Round 4 takes the presented one, and the composition is then
# corrected by the reading rather than confirmed against itself:
#
#   Scripts/timecode-fixture.sh /tmp
#   python3 Scripts/mkv-cue-fixture.py /tmp/tc-bframes.mkv /tmp/tc-bf-cues-lie.mkv \
#       "$(python3 -c 'print(",".join(str(i) for i in range(1,120)))')"
#   swift run aetherctl play --seconds 40 --start-position 53 --picture-probe \
#       --seek-every 14 --seek-count 2 --seek-pattern 65,60 file:///tmp/tc-bf-cues-lie.mkv
#
# The verdict is the mean of `capErr` per axis over the run (a single tick carries up to two frames
# of the probe's own quantisation, so read the mean, not a tick). Measured, 39 ticks, twice:
#
#   before   axis -9.000 mean +0.113   axis -18.083 mean +0.113
#   after    axis -9.000 mean +0.031   axis -18.083 mean +0.031   (+0.030 is this probe's own bias)
#
# and the second epoch prints the correction the reading makes:
# `#418 seg13 placed on base -9.083s, not -9.000s (... residual -0.083s): axis -18.000s -> -18.083s`.
#
# AE#418 round 5 turns that correction into a prediction, because the 0.083 s is not noise: it is the
# gate sample's own presentation lead, and a composition lands on the BASE, which sits that far under
# the axis. The pair is the whole proof, same arm on both fixtures:
#
#   tc-bframes.mkv   AVPlayer holds the re-placed seg13 from item 61.083, picture reads -18.083
#   tc-drought.mkv   AVPlayer holds it from item 61.000,                  picture reads -18.000
#
# So on the B-frame arm both placements must now print `#418 segN placement confirmed` (3 of 3 runs)
# and none of them `placed on base ...`. The case that pays for it is the one that cannot be measured
# at all, a seek burst that reopens backwards inside the buffer:
#
#   swift run aetherctl play --seconds 30 --start-position 53 --picture-probe \
#       --seek-every 2 --seek-count 4 --seek-pattern 65,60,70,58 file:///tmp/tc-bf-cues-lie.mkv
#
# It ends on `#418 segN opened no run of its own to measure`, so whatever the composition said is
# what the session keeps. Measured, two shapes, both matching the picture exactly: `-23.166` after two
# compositions and `-27.166` after three. Under round 4 those were kept at -23.083 and -27.000, i.e.
# one lead per composition, which is why an unmeasured chain drifts and a measured one does not.
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

# The same fixture WITH B-frames (AE#418 round 4). Everything else is identical, so the pair isolates
# one variable: whether the epoch's first random-access point is presented where it is decoded.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=640x360:r=${FPS}:d=${DUR}" \
  -f lavfi -i "sine=frequency=440:duration=${DUR}" \
  -vf "$filters" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 1000 -sc_threshold 0 \
  -bf 3 -x264-params "b-pyramid=normal:open-gop=0" \
  -force_key_frames "$KEYS" -b:v 2M \
  -c:a aac -b:a 128k -shortest \
  "$OUT_DIR/tc-bframes.mkv"
echo "wrote $OUT_DIR/tc-bframes.mkv (same, has_b_frames=2)"
