#!/usr/bin/env python3
"""Inject CuePoints at times that are NOT random-access points (AE#408).

No muxer will write this file for you: matroskaenc writes a cue for each packet it was handed
with AV_PKT_FLAG_KEY, so a Cues table that points at ordinary frames has to be built by
rewriting one that already exists. That shape is not exotic, it is what the AE#408 reporting
asset carries: 6004 cue points over 5355 s against sync samples 1 to 12.7 s apart.

It matters because libavformat enters EVERY cue point into the index as AVINDEX_KEYFRAME
regardless of the block's own keyframe flag (matroskadec.c, matroska_add_index_entries). Cues
mark seek points, not sync points. A segment plan built from that index therefore advertises
boundaries the producer cannot open on.

    # sync samples where we ask for them, with a 12 s drought at 43 s
    ffmpeg -f lavfi -i testsrc2=size=640x360:rate=24:duration=120 \\
           -f lavfi -i sine=frequency=440:duration=120 \\
           -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 1000 -sc_threshold 0 \\
           -force_key_frames "0,1.5,3.2,7.1,10.3,14.9,18.2,22.7,26.1,30.5,34.2,38.4,43.0,55.0,\\
56.5,58.9,61.3,64.8,67.2,71.6,75.1,79.4,83.8,87.2,91.6,95.1,99.5,103.2,107.8,111.4,115.9" \\
           -c:a aac -b:a 128k drought.mkv
    python3 Scripts/mkv-cue-fixture.py drought.mkv cues-lie.mkv \\
        "$(python3 -c 'print(",".join(str(i) for i in range(1,120)))')"

`drought.mkv` is the control arm (its cues ARE its sync samples), `cues-lie.mkv` the case. On
the latter, resuming at 45 s opened the gate at 55.0 and started playback at 55.8 before the
fix; after it the gate re-aims once, opens at 43.0 and starts where it was asked to.

Rewrites the Cues element in place at the end of the Segment and patches the Segment size, so
no cluster moves and no SeekHead entry needs fixing up. Refuses a file with elements after Cues.

Usage: mkv-cue-fixture.py <src.mkv> <dst.mkv> <t0,t1,...>   (times in seconds)
"""
import sys

SEGMENT = 0x18538067
SEEKHEAD = 0x114D9B74
CLUSTER = 0x1F43B675
CUES = 0x1C53BB6B
TIMESTAMP = 0xE7
CUE_POINT = 0xBB
CUE_TIME = 0xB3
CUE_TRACK_POSITIONS = 0xB7
CUE_TRACK = 0xF7
CUE_CLUSTER_POSITION = 0xF1


def read_id(buf, pos):
    b = buf[pos]
    n = 1 if b & 0x80 else 2 if b & 0x40 else 3 if b & 0x20 else 4
    return int.from_bytes(buf[pos:pos + n], "big"), pos + n


def read_size(buf, pos):
    b = buf[pos]
    n, mask = 1, 0x80
    while not (b & mask):
        n += 1
        mask >>= 1
    value = int.from_bytes(buf[pos:pos + n], "big") & ((1 << (7 * n)) - 1)
    unknown = value == (1 << (7 * n)) - 1
    return (None if unknown else value), pos + n, n


def uint(buf, pos, size):
    return int.from_bytes(buf[pos:pos + size], "big")


def enc_id(eid):
    for n in (1, 2, 3, 4):
        if eid < (1 << (8 * n)):
            return eid.to_bytes(n, "big")
    raise ValueError(eid)


def enc_size(value, length=None):
    if length is None:
        length = 1
        while value >= (1 << (7 * length)) - 1:
            length += 1
    return (value | (1 << (7 * length))).to_bytes(length, "big")


def elem(eid, payload):
    return enc_id(eid) + enc_size(len(payload)) + payload


def uint_elem(eid, value):
    n = max(1, (value.bit_length() + 7) // 8)
    return elem(eid, value.to_bytes(n, "big"))


def main():
    src, dst, times_arg = sys.argv[1], sys.argv[2], sys.argv[3]
    inject = sorted({round(float(t) * 1000) for t in times_arg.split(",")})
    buf = bytearray(open(src, "rb").read())

    seg_id, pos = read_id(buf, 0)
    if seg_id != 0x1A45DFA3:
        raise SystemExit("not an EBML file")
    hdr_size, pos, _ = read_size(buf, pos)
    pos += hdr_size
    seg_id, pos = read_id(buf, pos)
    if seg_id != SEGMENT:
        raise SystemExit("expected Segment")
    seg_size, after_size, size_len = read_size(buf, pos)
    seg_size_pos, seg_size_len = pos, size_len
    seg_data_start = after_size

    clusters = []          # (relative position, timestamp)
    cues_span = None       # (absolute offset, total length)
    existing = []          # (time, track, cluster position)
    trailing = []          # elements after Cues, if any

    p = seg_data_start
    end = len(buf) if seg_size is None else seg_data_start + seg_size
    while p < end:
        eid, q = read_id(buf, p)
        size, q, _ = read_size(buf, q)
        if size is None:
            break
        if eid == CLUSTER:
            ts = None
            c = q
            while c < q + size:
                cid, c2 = read_id(buf, c)
                csize, c2, _ = read_size(buf, c2)
                if cid == TIMESTAMP:
                    ts = uint(buf, c2, csize)
                    break
                c = c2 + csize
            clusters.append((p - seg_data_start, ts if ts is not None else 0))
        elif eid == CUES:
            cues_span = (p, (q - p) + size)
            c = q
            while c < q + size:
                cid, c2 = read_id(buf, c)
                csize, c2, _ = read_size(buf, c2)
                if cid == CUE_POINT:
                    t = track = cpos = None
                    d = c2
                    while d < c2 + csize:
                        did, d2 = read_id(buf, d)
                        dsize, d2, _ = read_size(buf, d2)
                        if did == CUE_TIME:
                            t = uint(buf, d2, dsize)
                        elif did == CUE_TRACK_POSITIONS:
                            e = d2
                            while e < d2 + dsize:
                                eid2, e2 = read_id(buf, e)
                                esize, e2, _ = read_size(buf, e2)
                                if eid2 == CUE_TRACK:
                                    track = uint(buf, e2, esize)
                                elif eid2 == CUE_CLUSTER_POSITION:
                                    cpos = uint(buf, e2, esize)
                                e = e2 + esize
                        d = d2 + dsize
                    if t is not None and track is not None and cpos is not None:
                        existing.append((t, track, cpos))
                c = c2 + csize
        elif cues_span is not None:
            trailing.append((eid, p, (q - p) + size))
        p = q + size

    if cues_span is None:
        raise SystemExit("no Cues element found")
    if trailing:
        raise SystemExit(f"elements follow Cues ({[hex(t[0]) for t in trailing]}); "
                         "rewriting would move them")

    track = existing[0][1] if existing else 1
    have = {t for t, _, _ in existing}
    merged = list(existing)
    for t in inject:
        if t in have:
            continue
        cpos = 0
        for rel, ts in clusters:
            if ts <= t:
                cpos = rel
            else:
                break
        merged.append((t, track, cpos))
    merged.sort()

    payload = bytearray()
    for t, tr, cpos in merged:
        positions = uint_elem(CUE_TRACK, tr) + uint_elem(CUE_CLUSTER_POSITION, cpos)
        point = uint_elem(CUE_TIME, t) + elem(CUE_TRACK_POSITIONS, positions)
        payload += elem(CUE_POINT, point)
    new_cues = enc_id(CUES) + enc_size(len(payload)) + payload

    cues_off, cues_len = cues_span
    out = bytearray(buf[:cues_off]) + new_cues + bytearray(buf[cues_off + cues_len:])
    if seg_size is not None:
        new_seg_size = seg_size + (len(new_cues) - cues_len)
        out[seg_size_pos:seg_size_pos + seg_size_len] = enc_size(new_seg_size, seg_size_len)
    open(dst, "wb").write(out)
    print(f"cues: {len(existing)} -> {len(merged)} "
          f"(+{len(merged) - len(existing)} injected), {len(clusters)} clusters, "
          f"segment {seg_size} -> {seg_size + len(new_cues) - cues_len}")


if __name__ == "__main__":
    main()
