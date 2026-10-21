#!/usr/bin/env python3
"""Record the rkisp1 main path while reproducing the "stale buffer" problem.

Run as root on the Tinker Board with nothing else streaming:

    sudo python3 csi-record.py [SECONDS] > /tmp/rec.log

Every second it prints one line:
  - frames received and how many were "stale" (nearly identical, noise
    included, to one of the frames 2..8 back),
  - the ISP debugfs counters,
  - the distinct luma write addresses the MI shadow register showed
    (MI_MP_Y_BASE_AD_SHD, sampled every few ms), and the init register.
On the first stale second and every 30 s it also dumps OV5647 registers.
"""
import mmap
import os
import struct
import subprocess
import sys
import threading
import time

W, H = 1296, 972
FS = W * H * 3 // 2
ISP = 0xff910000
MI = 0x1400
REG = {"y_init": MI + 0x08, "y_shd": MI + 0x78, "cb_shd": MI + 0x88,
       "ctrl_shd": MI + 0x74, "status": MI + 0x10c}
DBG = "/sys/kernel/debug/ff910000.isp"
SENSOR_REGS = [0x0100, 0x3500, 0x3501, 0x3502, 0x350a, 0x350b, 0x380c, 0x380d,
               0x380e, 0x380f, 0x3808, 0x3809, 0x380a, 0x380b, 0x4800, 0x4837, 0x503d]

dur = float(sys.argv[1]) if len(sys.argv) > 1 else 300
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
regs = mmap.mmap(fd, 0x2000, mmap.MAP_SHARED, mmap.PROT_READ, offset=ISP)


def rd(off):
    return struct.unpack_from("<I", regs, off)[0]


lock = threading.Lock()
seen = {}          # y_shd value -> samples this second
inits = set()
stop = False


def sampler():
    while not stop:
        a, i = rd(REG["y_shd"]), rd(REG["y_init"])
        with lock:
            seen[a] = seen.get(a, 0) + 1
            inits.add(i)
        time.sleep(0.003)


def counters():
    out = []
    for f in ("complete_frames", "mipi_error", "data_loss", "mp_frame_drop", "inform_size_error"):
        try:
            out.append("%s=%s" % (f.split("_")[0] if f != "mp_frame_drop" else "drop",
                                  open(os.path.join(DBG, f)).read().strip()))
        except OSError:
            pass
    return " ".join(out)


def sensor_dump():
    vals = []
    for r in SENSOR_REGS:
        p = subprocess.run(["i2ctransfer", "-f", "-y", "2", "w2@0x36", "0x%02x" % (r >> 8),
                            "0x%02x" % (r & 0xff), "r1"], capture_output=True, text=True)
        vals.append("%04x=%s" % (r, p.stdout.strip() or "ERR"))
    return " ".join(vals)


def sub(y):
    return bytes(y[r * W + c] for r in range(0, H, 40) for c in range(0, W, 40))


subprocess.run(["v4l2-ctl", "-d", "/dev/video0", "--set-fmt-video=width=%d,height=%d,pixelformat=NV12" % (W, H)])
cap = subprocess.Popen(["v4l2-ctl", "-d", "/dev/video0", "--stream-mmap",
                        "--stream-count=%d" % int(dur * 30 + 60), "--stream-to=-"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
threading.Thread(target=sampler, daemon=True).start()
print("%s start; sensor %s" % (time.strftime("%T"), sensor_dump()), flush=True)

hist, frames, stale, t_last, t0, first_stale = [], 0, 0, time.time(), time.time(), True
while time.time() - t0 < dur:
    d = cap.stdout.read(FS)
    if len(d) < FS:
        break
    s = sub(d)
    n = len(s)
    if any(sum(abs(a - b) for a, b in zip(s, p)) / n < 0.5 for p in hist[:-1]):
        stale += 1
    hist = (hist + [s])[-8:]
    frames += 1
    now = time.time()
    if now - t_last >= 1:
        with lock:
            addrs = sorted(seen.items())
            ini = sorted(inits)
            seen.clear()
            inits.clear()
        line = "%s frames=%d stale=%d %s shd=[%s] init_n=%d" % (
            time.strftime("%T"), frames, stale, counters(),
            " ".join("%08x:%d" % kv for kv in addrs), len(ini))
        if stale and first_stale or int(now - t0) % 30 == 0:
            line += " | sensor " + sensor_dump()
            first_stale = first_stale and not stale
        print(line, flush=True)
        frames = stale = 0
        t_last = now
stop = True
cap.kill()
print("%s end" % time.strftime("%T"), flush=True)
