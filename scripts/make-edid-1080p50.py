#!/usr/bin/env python3
"""Make patches/camera/edid-tc358743-1080p50.txt from the Spotpear EDID.

The Spotpear C780/C790 EDID prefers 720p60 and its range limits
(59-61 Hz, 15-46 kHz) rule out 1080p50, although 1080p50 UYVY
(1.66 Gbit/s) fits the C790's 2 CSI-2 lanes at 972 Mbit/s (1.94 Gbit/s).
1080p60 (1.99 Gbit/s) does not, so it stays out.

Changes:
  - first detailed timing (preferred): 720p60 -> 1080p50 (CEA VIC 31)
  - second detailed timing: 480p -> 720p60
  - range limits: vertical 23-61 Hz, horizontal 15-57 kHz, 150 MHz
  - correct checksums for both blocks (the original's are wrong)

    python3 scripts/make-edid-1080p50.py [--decode FILE]
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "patches", "camera", "edid-tc358743.txt")
DST = os.path.join(HERE, "..", "patches", "camera", "edid-tc358743-1080p50.txt")


def dtd(pclk_khz, ha, hb, hfp, hs, va, vb, vfp, vs, hmm=0, vmm=0, flags=0x1e):
    """18-byte detailed timing descriptor. flags 0x1e = digital separate
    sync, +vsync +hsync."""
    p = pclk_khz // 10
    return bytes([
        p & 0xff, p >> 8,
        ha & 0xff, hb & 0xff, (ha >> 8) << 4 | hb >> 8,
        va & 0xff, vb & 0xff, (va >> 8) << 4 | vb >> 8,
        hfp & 0xff, hs & 0xff, (vfp & 0xf) << 4 | (vs & 0xf),
        (hfp >> 8) << 6 | (hs >> 8) << 4 | (vfp >> 4) << 2 | (vs >> 4),
        hmm & 0xff, vmm & 0xff, (hmm >> 8) << 4 | vmm >> 8,
        0, 0, flags])


def fix_checksum(block):
    block[127] = (-sum(block[:127])) & 0xff


def decode(b):
    out = []
    for i in range(4):
        d = b[54 + 18 * i:72 + 18 * i]
        pc = (d[0] | d[1] << 8) * 10e3
        if pc:
            ha = d[2] | (d[4] & 0xf0) << 4
            hb = d[3] | (d[4] & 0x0f) << 8
            va = d[5] | (d[7] & 0xf0) << 4
            vb = d[6] | (d[7] & 0x0f) << 8
            out.append("DTD%d %dx%d @ %.2f Hz, %.2f MHz, %.2f kHz"
                       % (i + 1, ha, va, pc / ((ha + hb) * (va + vb)), pc / 1e6, pc / (ha + hb) / 1e3))
        elif d[3] == 0xFD:
            out.append("range: V %d-%d Hz, H %d-%d kHz, max %d MHz" % (d[5], d[6], d[7], d[8], d[9] * 10))
        elif d[3] == 0xFC:
            out.append("name: " + d[5:18].decode(errors="replace").strip())
    e = b[128:256]
    i = 4
    while i < e[2]:
        if e[i] >> 5 == 2:
            out.append("CTA VICs: %s" % [x & 0x7f for x in e[i + 1:i + 1 + (e[i] & 31)]])
        i += 1 + (e[i] & 31)
    out.append("checksums: %s %s" % (sum(b[:128]) % 256 == 0, sum(b[128:]) % 256 == 0))
    return "\n".join(out)


def read_hex(path):
    return bytearray.fromhex("".join(open(path).read().split()))


if len(sys.argv) == 3 and sys.argv[1] == "--decode":
    print(decode(read_hex(sys.argv[2])))
    sys.exit()

b = read_hex(SRC)
assert len(b) == 256
# 1080p50: 148.5 MHz, H 1920 + 720 (fp 528, sync 44), V 1080 + 45 (fp 4, sync 5)
b[54:72] = dtd(148500, 1920, 720, 528, 44, 1080, 45, 4, 5, 0x210, 0x128)
# 720p60: 74.25 MHz, H 1280 + 370 (fp 110, sync 40), V 720 + 30 (fp 5, sync 5)
b[72:90] = dtd(74250, 1280, 370, 110, 40, 720, 30, 5, 5, 0x210, 0x128)
r = 54 + 18 * 3
assert b[r + 3] == 0xFD, "range limits descriptor moved"
b[r + 5], b[r + 6] = 23, 61       # vertical Hz
b[r + 7], b[r + 8] = 15, 57       # horizontal kHz: 1080p50 is 56.25, 1080p60 67.5
b[r + 9] = 15                     # 150 MHz
for blk in (0, 128):
    view = b[blk:blk + 128]
    fix_checksum(view)
    b[blk:blk + 128] = view
with open(DST, "w") as f:
    for i in range(0, 256, 16):
        f.write(b[i:i + 16].hex() + "\n")
print("wrote", os.path.relpath(DST))
print(decode(b))
