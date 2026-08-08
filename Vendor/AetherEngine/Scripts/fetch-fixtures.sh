#!/usr/bin/env bash
# Generate a small set of synthetic test clips under ./Fixtures/ for
# engine validation runs. Each clip is short (5 s) and deterministic
# (FFmpeg's testsrc2 source filter), so the output is reproducible
# across machines and copyright-clean. The clips exercise the four
# codec paths AetherEngine cares about:
#
#   sdr-h264.mp4    - H.264 BT.709, native AVPlayer path
#   hdr10-hevc.mp4  - HEVC Main10 BT.2020 / PQ, native AVPlayer path with HDR
#   av1.mp4         - AV1, software dav1d path on devices without HW
#   vp9.webm        - VP9, software libavcodec path
#
# plus two clips for RestartTimelineContinuityTests (the suite skips
# those tests when the clips are absent, e.g. on CI):
#
#   restart-witness-av.mp4        - H.264 B-frames + AAC, 12 s (3 segments)
#   restart-witness-leadaudio.mp4 - same, video delayed 0.3 s so audio leads
#   restart-witness-subs.mkv      - same as MKV with an embedded SRT track (pump tap)
#   a53-captions.mp4              - H.264 with in-picture A/53 CEA-608 SEI (#131, #259)
#   hev1-inband-xps.mp4           - HEVC with in-band VPS/SPS/PPS and an empty hvcC
#
# Real-world DV / Atmos / multichannel sources have to come from your
# own library. Drop those into ./Fixtures/user/ (also gitignored)
# and reference them from aetherctl runs.
#
# Usage:
#   ./Scripts/fetch-fixtures.sh
#
# Requires:
#   - ffmpeg with libx264, libx265, libaom-av1, libvpx-vp9 enabled.
#     macOS: `brew install ffmpeg` covers all four codecs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/Fixtures"
mkdir -p "$FIXTURES_DIR/user"

# Drop a README into the user dir on first run so the gitignore +
# intent are obvious if someone goes looking.
USER_README="$FIXTURES_DIR/user/README.md"
if [[ ! -f "$USER_README" ]]; then
    cat > "$USER_README" <<'EOF'
# user fixtures

This directory is gitignored. Drop real-world test sources here
(Dolby Vision MKVs, Atmos EAC3+JOC streams, multichannel sources,
etc.) and reference them from `aetherctl probe / serve / validate`
runs without worrying about accidentally pushing them.
EOF
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg not on PATH. Install with: brew install ffmpeg" >&2
    exit 1
fi

echo "Fixtures dir: $FIXTURES_DIR"
echo ""

# H.264 SDR 1080p
echo "→ sdr-h264.mp4 (H.264 BT.709 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    "$FIXTURES_DIR/sdr-h264.mp4"

# HEVC HDR10 1080p
echo "→ hdr10-hevc.mp4 (HEVC Main10 BT.2020 / PQ 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -vf "format=yuv420p10le" \
    -c:v libx265 -preset ultrafast \
    -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1" \
    -pix_fmt yuv420p10le \
    -tag:v hvc1 \
    "$FIXTURES_DIR/hdr10-hevc.mp4"

# AV1 SDR 1080p
echo "→ av1.mp4 (AV1 1080p @ 24fps, low CPU preset)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libaom-av1 -crf 30 -b:v 0 -cpu-used 8 \
    "$FIXTURES_DIR/av1.mp4"

# VP9 SDR 1080p
echo "→ vp9.webm (VP9 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libvpx-vp9 -crf 30 -b:v 0 -cpu-used 8 \
    "$FIXTURES_DIR/vp9.webm"

# Restart-continuity witness: A/V with real B-frame reorder (bf 3) and a keyframe
# every 2 s so the 4 s segment plan cuts on keyframes. Drives
# RestartTimelineContinuityTests (continuous vs restarted segment equality).
echo "→ restart-witness-av.mp4 (H.264 B-frames + AAC mono, 12s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=12:size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=12" \
    -c:v libx264 -preset veryfast -bf 3 -g 48 -pix_fmt yuv420p -b:v 200k \
    -c:a aac -b:a 48k -ac 1 -shortest \
    "$FIXTURES_DIR/restart-witness-av.mp4"

# Same content with the video track delayed 0.3 s, so the audio leads the
# video anchor at head-of-stream (the leading-audio guard scenario).
echo "→ restart-witness-leadaudio.mp4 (audio leads video by 0.3s, 8s)"
ffmpeg -hide_banner -loglevel error -y \
    -itsoffset 0.3 -i "$FIXTURES_DIR/restart-witness-av.mp4" \
    -i "$FIXTURES_DIR/restart-witness-av.mp4" \
    -map 0:v -map 1:a -c copy -t 8 \
    "$FIXTURES_DIR/restart-witness-leadaudio.mp4"

# Same content as MKV with an embedded SRT track (the subtitle pump-tap scenario,
# SubtitlePumpTapTests).
echo "→ restart-witness-subs.mkv (embedded SRT track)"
SRT_TMP="$(mktemp -t witness-subs).srt"
cat > "$SRT_TMP" <<'SRT'
1
00:00:00,500 --> 00:00:02,000
First cue

2
00:00:02,500 --> 00:00:04,500
Second cue crossing the first boundary

3
00:00:05,000 --> 00:00:07,000
Third cue

4
00:00:08,200 --> 00:00:10,000
Fourth cue

5
00:00:10,500 --> 00:00:11,500
Fifth cue
SRT
ffmpeg -hide_banner -loglevel error -y \
    -i "$FIXTURES_DIR/restart-witness-av.mp4" -i "$SRT_TMP" \
    -map 0:v -map 0:a -map 1:0 -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng \
    "$FIXTURES_DIR/restart-witness-subs.mkv"
rm -f "$SRT_TMP"

# A/53 in-picture captions (#131, #259): US broadcast sources carry CEA-608 inside the
# video as user_data_registered_itu_t_t35 SEI, and no encoder emits those from a synthetic
# source, so they are injected here. Every access unit gets a cc_data SEI: the null pad pair
# real encoders send continuously, except every 48th AU (2 s at 24 fps), which carries a
# COMPLETE pop-on sequence (RCL, ENM, PAC, characters, EOC) in one SEI, so the caption is
# atomic inside a single access unit and survives B-frame reordering. B-frames stay on
# (-bf 3): they give the producer a non-zero playlist shift, which is what the axis witness
# in Issue259A53CaptionAxisTests measures.
echo "→ a53-captions.mp4 (H.264 with in-picture A/53 CEA-608 SEI, 12s)"
A53_RAW="$(mktemp -t a53-raw).264"
A53_CC="$(mktemp -t a53-cc).264"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=12:size=320x180:rate=24" \
    -c:v libx264 -preset veryfast -bf 3 -g 48 -pix_fmt yuv420p -b:v 200k \
    -bsf:v "h264_metadata=aud=insert" -f h264 "$A53_RAW"
python3 - "$A53_RAW" "$A53_CC" <<'PY'
import sys

def odd_parity(v):
    v &= 0x7F
    return v if bin(v).count('1') % 2 == 1 else (v | 0x80)

# A complete pop-on caption: RCL, ENM, PAC row 1 col 0, character pairs, EOC.
def caption_pairs(text):
    pairs = [(0x14, 0x20), (0x14, 0x2E), (0x11, 0x40)]
    b = text.encode('ascii')
    for i in range(0, len(b), 2):
        pairs.append((b[i], b[i + 1] if i + 1 < len(b) else 0x00))
    pairs.append((0x14, 0x2F))
    return [(odd_parity(a), odd_parity(c)) for a, c in pairs]

# cc_data SEI: country 0xB5, provider 0x0031, "GA94", user_data_type_code 0x03, then
# process_cc_data_flag | cc_count, em_data, cc_count * (0xFC marker + 608 pair), marker.
def sei_nal(pairs):
    payload = bytearray([0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03])
    payload += bytes([0x40 | len(pairs), 0xFF])
    for d0, d1 in pairs:
        payload += bytes([0xFC, d0, d1])
    payload += b'\xFF'
    rbsp = bytearray([4])                      # payload_type: user_data_registered_itu_t_t35
    n = len(payload)
    while n >= 255:
        rbsp.append(0xFF)
        n -= 255
    rbsp.append(n)
    rbsp += payload
    rbsp.append(0x80)                          # rbsp_trailing_bits
    escaped = bytearray()
    zeros = 0
    for byte in rbsp:                          # emulation prevention
        if zeros >= 2 and byte <= 0x03:
            escaped.append(0x03)
            zeros = 0
        escaped.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return b'\x00\x00\x00\x01\x06' + bytes(escaped)

src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
out = bytearray()
prev = 0
au = 0
captions = 0
i = 0
while i + 3 <= len(data):
    if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
        payload = i + 3
        if data[payload] & 0x1F == 9:          # access unit delimiter: AU boundary
            end = payload + 2                  # AUD is header + primary_pic_type
            out += data[prev:end]
            if au % 48 == 0:
                captions += 1
                out += sei_nal(caption_pairs('CUE %d' % captions))
            else:
                out += sei_nal([(0x80, 0x80)])
            prev = end
            au += 1
        i += 3
    else:
        i += 1
out += data[prev:]
open(dst, 'wb').write(bytes(out))
print('    %d access units, %d captions' % (au, captions))
PY
ffmpeg -hide_banner -loglevel error -y \
    -f h264 -r 24 -i "$A53_CC" \
    -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=12" \
    -map 0:v -map 1:a -c:v copy -c:a aac -b:a 48k -ac 1 -shortest \
    "$FIXTURES_DIR/a53-captions.mp4"
rm -f "$A53_RAW" "$A53_CC"

# HEVC whose parameter sets live IN-BAND only: hev1 sample entry, hvcC header with
# numOfArrays = 0. That is what `MP4Box ...:xps_inband` and the common Dolby-Vision MP4
# authoring recipes write, and what the init.mp4 normalizer has to rebuild from packets
# (AetherPlayer#2, engine #19). ffmpeg always writes the parameter-set arrays, so the
# shape is synthesized: x265 repeats the headers in-band, then the hvcC payload is
# truncated to its 22-byte header + numOfArrays = 0 and the freed bytes are absorbed by a
# sibling `free` box, which keeps every parent box size and chunk offset valid.
# keyint 120 (5 s at 24 fps) puts the IRAPs far enough apart that a mid-GOP scan cannot
# stumble onto one by luck.
echo "→ hev1-inband-xps.mp4 (HEVC with in-band VPS/SPS/PPS, empty hvcC)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240:rate=24 -t 6 \
    -c:v libx265 -x265-params "repeat-headers=1:keyint=120:min-keyint=120:log-level=none" \
    -tag:v hev1 "$FIXTURES_DIR/hev1-inband-xps.mp4"
python3 - "$FIXTURES_DIR/hev1-inband-xps.mp4" <<'PY'
import sys

path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
tag = data.find(b'hvcC')
start = tag - 4
size = int.from_bytes(data[start:start + 4], 'big')
payload = data[tag + 4:start + size]
emptied = bytes(payload[:22]) + b'\x00'   # numOfArrays = 0
freed = size - (8 + len(emptied))
assert freed >= 8, f'hvcC too small to empty in place: {size}'
replacement = bytearray()
replacement += (8 + len(emptied)).to_bytes(4, 'big') + b'hvcC' + emptied
replacement += freed.to_bytes(4, 'big') + b'free' + bytes(freed - 8)
data[start:start + size] = replacement
open(path, 'wb').write(bytes(data))
PY

# AetherEngine#268: finite HEVC-in-MPEG-TS HLS VOD, the carriage AVFoundation refuses to build a
# video track for. Three shapes, because each one only shows its own defect:
#   hls-hevc-vod/        PTS origin at ffmpeg's default 1.4 s, 6 s segments, 2 s GOP
#   hls-hevc-vod-offset/ PTS origin at ~1001 s, what broadcast-derived VOD carries (seek axis)
#   hls-hevc-vod-longgop/ 20 min, 10 s segments, ONE I-frame per segment (segment plan)
# plus an H.264 control that has to STAY on the native AVPlayer route. Serve the parent directory
# over HTTP (any static, range-capable origin) and drive it with
# `aetherctl play --seek-every 6 --seek-pattern 500,120 http://127.0.0.1:PORT/hls-hevc-vod/media.m3u8`.
echo "→ user/hls-hevc-vod* (HEVC-in-MPEG-TS HLS VOD, #268 route)"
hls_vod_fixture() {  # <dir> <encoder> <extra-out-args...>
    local dir="$FIXTURES_DIR/user/$1"; shift
    local codec="$1"; shift
    rm -rf "$dir" && mkdir -p "$dir"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=960x540:rate=25" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 120 \
        -c:v "$codec" -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 96k "$@" \
        -f hls -hls_time 6 -hls_list_size 0 -hls_playlist_type vod \
        -hls_segment_filename "$dir/seg%03d.ts" "$dir/media.m3u8"
}
hls_vod_fixture hls-hevc-vod libx265 -x265-params "keyint=50:min-keyint=50:scenecut=0:log-level=none"
hls_vod_fixture hls-h264-vod libx264 -g 50 -keyint_min 50 -sc_threshold 0

# The GOP is the point: one I-frame per 10 s segment, the reporter's shape. A 2 s GOP (above) hides
# the #268 round 2 defect entirely, because every plan boundary then still catches a keyframe. It
# also has to be long enough that a seek lands outside what the ingest has already produced, so
# 20 min rather than 120 s. Drive it with a target that is NOT a multiple of 20 s, e.g.
# `aetherctl play --seek-every 14 --seek-pattern 1055.79,333.3,777.7 http://127.0.0.1:PORT/hls-hevc-vod-longgop/media.m3u8`
# and watch `video gate open`: `anchorPts - target` must stay at the plan's boundary backoff.
LONGGOP_TS="$FIXTURES_DIR/user/hevc-longgop.ts"
LONGGOP_DIR="$FIXTURES_DIR/user/hls-hevc-vod-longgop"
rm -rf "$LONGGOP_DIR" && mkdir -p "$LONGGOP_DIR"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=25" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1200 \
    -c:v libx265 -preset ultrafast \
    -x265-params "keyint=250:min-keyint=250:scenecut=0:log-level=none" \
    -pix_fmt yuv420p -c:a aac -b:a 64k -f mpegts "$LONGGOP_TS"
ffmpeg -hide_banner -loglevel error -y -i "$LONGGOP_TS" -c copy \
    -f hls -hls_time 10 -hls_list_size 0 -hls_playlist_type vod \
    -hls_segment_filename "$LONGGOP_DIR/seg%03d.ts" "$LONGGOP_DIR/media.m3u8"

# Broadcast-style PTS origin: mux once with the offset, then segment with -copyts so the segments
# keep it. A reader that mistakes an absolute source PTS for playlist time seeks to the wrong end of
# this one.
OFFSET_TS="$FIXTURES_DIR/user/hevc-offset.ts"
rm -rf "$FIXTURES_DIR/user/hls-hevc-vod-offset" && mkdir -p "$FIXTURES_DIR/user/hls-hevc-vod-offset"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=960x540:rate=25" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 120 \
    -c:v libx265 -preset ultrafast -x265-params "keyint=50:min-keyint=50:scenecut=0:log-level=none" \
    -pix_fmt yuv420p -c:a aac -b:a 96k -output_ts_offset 1000 -f mpegts "$OFFSET_TS"
ffmpeg -hide_banner -loglevel error -y -copyts -i "$OFFSET_TS" -c copy \
    -f hls -hls_time 6 -hls_list_size 0 -hls_playlist_type vod \
    -hls_segment_filename "$FIXTURES_DIR/user/hls-hevc-vod-offset/seg%03d.ts" \
    "$FIXTURES_DIR/user/hls-hevc-vod-offset/media.m3u8"

echo ""
echo "Done. Try:"
echo "  swift run aetherctl probe $FIXTURES_DIR/sdr-h264.mp4"
echo "  swift run aetherctl probe $FIXTURES_DIR/hdr10-hevc.mp4"
echo "  swift run aetherctl validate $FIXTURES_DIR/av1.mp4"
echo ""
echo "Real-world DV / Atmos sources go in $FIXTURES_DIR/user/ (gitignored)."
