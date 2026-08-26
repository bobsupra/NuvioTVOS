#!/usr/bin/env python3
"""Build Annex-B framed MKV fixtures by in-place EBML surgery (#365).

No muxer will write these files for you: matroskaenc always converts the config record with
ff_isom_write_hvcc and always reformats Annex-B packets to length prefixes, so the shape that
breaks the mp4 muxer (Annex-B config record, length-prefixed blocks) has to be produced by
patching one that already exists.

    ffmpeg -i src.mp4 -c copy base.mkv
    python3 Scripts/mkv-annexb-fixture.py base.mkv annexb-record.mkv --annexb-codecprivate
    python3 Scripts/mkv-annexb-fixture.py base.mkv annexb-both.mkv --annexb-codecprivate --annexb-blocks

Two independent knobs, both byte-count preserving so no parent element size needs rewriting:
  --annexb-codecprivate : replace the hvcC/avcC CodecPrivate with the Annex-B parameter sets it
                          carries, padding the remainder with an EBML Void element.
                          Add --avc for an H.264 track (different record layout).
  --annexb-blocks       : rewrite every video SimpleBlock/Block payload from 4-byte length
                          prefixes to 4-byte start codes (same length, in place).

The three fixtures together are the control set: after the fix all three must produce a
byte-identical init.mp4 and a byte-identical seg0 through `aetherctl serve`.
"""
import sys, struct

def read_vint(buf, pos, keep_marker):
    b0 = buf[pos]
    if b0 == 0:
        raise ValueError("bad vint at %d" % pos)
    length = 1
    mask = 0x80
    while not (b0 & mask):
        mask >>= 1
        length += 1
    val = b0 if keep_marker else (b0 & (mask - 1))
    for i in range(1, length):
        val = (val << 8) | buf[pos + i]
    return val, length

def elements(buf, start, end):
    pos = start
    while pos < end:
        eid, idlen = read_vint(buf, pos, True)
        size, sizelen = read_vint(buf, pos + idlen, False)
        datastart = pos + idlen + sizelen
        unknown = size == (1 << (7 * sizelen)) - 1
        dataend = end if unknown else min(datastart + size, end)
        yield eid, pos, datastart, dataend, sizelen
        pos = dataend

MASTERS = {0x18538067, 0x1654AE6B, 0xAE, 0x1F43B675, 0xA0, 0xE0}

def find(buf, start, end, path):
    """Yield (id, elemstart, datastart, dataend) for elements matching path."""
    want = path[0]
    for eid, es, ds, de, sl in elements(buf, start, end):
        if eid == want:
            if len(path) == 1:
                yield (eid, es, ds, de)
            else:
                yield from find(buf, ds, de, path[1:])

def encode_vint_size(value, length):
    marker = 1 << (7 * length)
    if value >= marker - 1:
        raise ValueError("size too big for length")
    out = bytearray(length)
    v = value | marker
    for i in range(length - 1, -1, -1):
        out[i] = v & 0xFF
        v >>= 8
    return bytes(out)

def avcc_to_annexb(avcc):
    import struct
    if avcc[0] != 1:
        raise ValueError("not an avcC")
    out = bytearray()
    num_sps = avcc[5] & 0x1F
    pos = 6
    for _ in range(num_sps):
        n = struct.unpack('>H', avcc[pos:pos+2])[0]; pos += 2
        out += b'\x00\x00\x01' + avcc[pos:pos+n]; pos += n
    num_pps = avcc[pos]; pos += 1
    for _ in range(num_pps):
        n = struct.unpack('>H', avcc[pos:pos+2])[0]; pos += 2
        out += b'\x00\x00\x01' + avcc[pos:pos+n]; pos += n
    return bytes(out)

def hvcc_to_annexb(hvcc):
    if hvcc[0] != 1:
        raise ValueError("not an hvcC")
    num_arrays = hvcc[22]
    pos = 23
    out = bytearray()
    for _ in range(num_arrays):
        pos += 1
        num_nalus = struct.unpack('>H', hvcc[pos:pos + 2])[0]
        pos += 2
        for _ in range(num_nalus):
            nal_len = struct.unpack('>H', hvcc[pos:pos + 2])[0]
            pos += 2
            out += b'\x00\x00\x01' + hvcc[pos:pos + nal_len]
            pos += nal_len
    return bytes(out)

def main():
    src, dst = sys.argv[1], sys.argv[2]
    do_cp = '--annexb-codecprivate' in sys.argv
    do_blocks = '--annexb-blocks' in sys.argv
    buf = bytearray(open(src, 'rb').read())

    segs = list(find(buf, 0, len(buf), [0x18538067]))
    seg_ds, seg_de = segs[0][2], segs[0][3]

    video_track_num = None
    for _, es, ds, de, sl in elements(buf, seg_ds, seg_de):
        if _ != 0x1654AE6B:
            continue
        for eid2, es2, ds2, de2, sl2 in elements(buf, ds, de):
            if eid2 != 0xAE:
                continue
            tnum, ttype, cp = None, None, None
            for eid3, es3, ds3, de3, sl3 in elements(buf, ds2, de2):
                if eid3 == 0xD7:
                    tnum = int.from_bytes(buf[ds3:de3], 'big')
                elif eid3 == 0x83:
                    ttype = int.from_bytes(buf[ds3:de3], 'big')
                elif eid3 == 0x63A2:
                    cp = (es3, ds3, de3, sl3)
            if ttype == 1:
                video_track_num = tnum
                if do_cp and cp:
                    es3, ds3, de3, sl3 = cp
                    old_total = de3 - es3
                    raw = bytes(buf[ds3:de3])
                    annexb = (avcc_to_annexb(raw) if '--avc' in sys.argv
                              else hvcc_to_annexb(raw))
                    idlen = ds3 - es3 - sl3
                    new_elem = buf[es3:es3 + idlen] + encode_vint_size(len(annexb), sl3) + annexb
                    pad = old_total - len(new_elem)
                    if pad < 2:
                        raise SystemExit("no room for Void padding (%d)" % pad)
                    void = b'\xEC' + encode_vint_size(pad - 2, 1) + b'\x00' * (pad - 2)
                    buf[es3:de3] = new_elem + void
                    assert len(new_elem) + len(void) == old_total
                    print("CodecPrivate: hvcC %d B -> annex-B %d B (+%d B Void)"
                          % (de3 - ds3, len(annexb), pad))

    print("video track number:", video_track_num)

    if do_blocks:
        patched = 0
        for eid, es, ds, de, sl in elements(buf, seg_ds, seg_de):
            if eid != 0x1F43B675:
                continue
            for eid2, es2, ds2, de2, sl2 in elements(buf, ds, de):
                blocks = []
                if eid2 == 0xA3:
                    blocks.append((ds2, de2))
                elif eid2 == 0xA0:
                    for eid3, es3, ds3, de3, sl3 in elements(buf, ds2, de2):
                        if eid3 == 0xA1:
                            blocks.append((ds3, de3))
                for bs, be in blocks:
                    tnum, tl = read_vint(buf, bs, False)
                    if tnum != video_track_num:
                        continue
                    p = bs + tl + 3  # timecode(2) + flags(1)
                    while p + 4 <= be:
                        nal_len = struct.unpack('>I', buf[p:p + 4])[0]
                        if nal_len == 0 or p + 4 + nal_len > be:
                            print("  block walk mismatch at %d (len=%d, left=%d)" % (p, nal_len, be - p))
                            break
                        buf[p:p + 4] = b'\x00\x00\x00\x01'
                        p += 4 + nal_len
                    patched += 1
        print("blocks patched:", patched)

    open(dst, 'wb').write(bytes(buf))
    print("wrote", dst, len(buf), "B")

main()
