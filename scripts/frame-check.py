#!/usr/bin/env python3
"""Check captured frames for stale (repeated) buffers and dump one as PNG.

    python3 frame-check.py FILE WIDTH HEIGHT nv12|gray [--png N out.png]

A frame counts as stale when it is nearly identical, noise included (mean
absolute difference < 0.5 on a sparse grid), to one of the 2..12 frames
before it: what the rkisp1 MI_CTRL reset and v4l2src io-mode=auto
problems looked like.
"""
import argparse
import struct
import zlib

p = argparse.ArgumentParser()
p.add_argument("file")
p.add_argument("width", type=int)
p.add_argument("height", type=int)
p.add_argument("fmt", choices=["nv12", "gray"])
p.add_argument("--png", nargs=2, metavar=("N", "OUT"))
a = p.parse_args()
w, h = a.width, a.height
fs = w * h * 3 // 2 if a.fmt == "nv12" else w * h
d = open(a.file, "rb").read()
n = len(d) // fs
step_y, step_x = max(1, h // 24), max(1, w // 32)
F = [bytes(d[i * fs + r * w + c] for r in range(0, h, step_y) for c in range(0, w, step_x))
     for i in range(n)]
m = len(F[0])


def diff(x, y):
    return sum(abs(p - q) for p, q in zip(x, y)) / m


stale = [i for i in range(4, n) if min(diff(F[i], F[j]) for j in range(max(0, i - 12), i - 1)) < 0.5]
print("%s: %d frames, stale %d, first stale %s, consecutive diffs %s"
      % (a.file, n, len(stale), stale[:1], [round(diff(F[i], F[i + 1]), 1) for i in range(min(12, n - 1))]))

if a.png:
    k, out = int(a.png[0]), a.png[1]
    base = k * fs
    rows = []
    for y in range(0, h, 2):                       # half size, NV12 -> RGB
        r = bytearray([0])
        for x in range(0, w, 2):
            yy = d[base + y * w + x] - 16
            if a.fmt == "nv12":
                uv = base + w * h + (y // 2) * w + x
                u, v = d[uv] - 128, d[uv + 1] - 128
            else:
                u = v = 0
            c = [1.164 * yy + 1.596 * v, 1.164 * yy - 0.392 * u - 0.813 * v, 1.164 * yy + 2.017 * u]
            r += bytes(0 if t < 0 else 255 if t > 255 else int(t) for t in c)
        rows.append(bytes(r))

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)

    open(out, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w // 2, h // 2, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b""))
    print("wrote", out)
