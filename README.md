# rk3288-mainline-media

Kernel and GStreamer patches, device tree overlays and scripts that make the
RK3288's video hardware usable on a **mainline** kernel (Armbian 6.18 LTS),
developed on an ASUS Tinker Board for the
[simplekvm](https://github.com/ohayoyogi/simplekvm) IP-KVM:

- **H.264 encoding on the Hantro H1 VPU** (stateless encoder, V4L2 RFC uAPI),
  used from GStreamer as `v4l2slh264enc`.
- **CSI-2 capture through the RK3288 ISP** (rkisp1 + MIPI DPHY RX0), with an
  **OV5647** camera or a **TC358743 HDMI-to-CSI-2 bridge** (Geekworm C790).

```
HDMI ── TC358743 (C790) ─CSI-2─▶ DPHY RX0 ─▶ rkisp1 ─▶ NV12 ─▶ Hantro H1 ─▶ H.264
         or OV5647 (RAW10)                  (ISP)              (VPU)
```

Status: **works on one Tinker Board**, not upstream. The H.264 encoder uAPI is
an RFC that mainline has not accepted, so these patches will need rework when
the stateless encoder API lands.

## Results (Tinker Board, Armbian 25.11.1 userland, measured on kernel 6.12.58)

| What | Result |
|---|---|
| H1 H.264 encode | 1080p ~56–68 fps, 720p 122–141 fps (constant QP 28, simple content); 30 min 1080p30 CBR soak without faults |
| OV5647 via ISP | 1296x972 / 1080p NV12 at 30 fps |
| TC358743 (C790) via ISP | 720p60 at 60 fps, 1080p50 at 50 fps (2 lanes), no CSI errors |
| HDMI → capture latency | 67 ms median (Tinker's own HDMI output looped into the C790) |
| HDMI → browser via simplekvm | 113 ms average click-to-display (720p60) |

Re-checked on kernel 6.18.58 (Armbian `rockchip-6.18`): H1 hardware time per
frame 13.3 ms at 1080p and 5.8 ms at 720p (14.6 / 6.4 ms on 6.12); C790 720p60
at 60.00 fps with no stale frames; simplekvm `--source csi --fps 60` at 60 fps;
`shutdown -h` powers the board off. OV5647, 1080p50 and the latency figures
were not re-measured.

## Contents

| Path | What it is |
|---|---|
| `patches/h264enc/0001–0008` | Hantro H1 VP8/H.264 stateless encoder RFCs by Andrzej Pietrasiewicz (Collabora) and Hugues Fruchet (ST), with original authorship and links |
| `patches/h264enc/0009–0014` | RK3288 enablement and fixes: contiguous reference frames, legacy H1 quirks, IOMMU fault recovery, signed ENC_CTRL0 fields (0012 and 0014 are debug-only) |
| `patches/camera/0002–0003` | DPHY RX0 and rkisp1 support for RK3288 (based on Karthik Poduval's 2020 RFC); `0001`, a mainline backport of the tc358743 972 Mbit/s link frequency, was dropped because 6.18 has it |
| `patches/camera/0004–0005` | rkisp1 uses the lane count / link frequency the source reports; tc358743 gets `LINK_FREQ` and `PIXEL_RATE` |
| `patches/camera/0006–0008` | RK3288 ISP fixes: 32-beat chroma bursts, error-interrupt storm guard, MI_CTRL reset recovery |
| `patches/camera/0009` | rkisp1 allocates at least four capture buffers again (6.18 lowered `min_queued_buffers` to 1, and GStreamer's `v4l2src` then took only two and lost every third frame at 720p60) |
| `patches/camera/dt/` | Tinker Board overlays: ISP + DPHY + TC358743 or OV5647 |
| `patches/camera/edid-*.txt` | TC358743 EDIDs: 720p60 preferred (from Spotpear's guide) and 1080p50 preferred |
| `patches/gstreamer/` | GStreamer MR !5676 (`v4l2slh264enc`) built against 1.24: UYVY input, VUI without reordering, copy into macroblock-padded buffers |
| `scripts/build-h264enc-kernel.sh` | builds the kernel (kernel.org 6.18.58 + Armbian `rockchip-6.18` patches + these) in Docker under WSL |
| `scripts/build-gstreamer-h264enc.sh` | builds the patched v4l2codecs plugin for armhf |
| `scripts/build-camera-overlays.sh` | compiles the DT overlays |
| `scripts/tinker-kernel-h264enc.sh` | installs the kernel tarball and switches between it and the stock kernel |
| `scripts/tinker-camera.sh` | installs the camera modules/overlays and sets up the media pipeline (OV5647 / HDMI) |
| `scripts/tc358743-edid.{sh,rules}`, `scripts/tc358743-edid@.service` | loads the EDID when the TC358743 appears, so the HDMI source sees a monitor without a capture running (`tinker-camera.sh boot-edid on`) |
| `scripts/tinker-h264enc-test.sh` | encoder smoke test on the board |
| `scripts/csi-record.py`, `scripts/frame-check.py` | capture diagnostics: stale-buffer detection, MI register sampling |
| `scripts/make-edid-1080p50.py` | generates the 1080p50 EDID |
| `scripts/tinker-sdmmc-hs.dts` | overlay for a faster SD card mode |

Power off: on RK3288 `shutdown -h` only halted (`Power off not available:
System halted instead`) and every rail stayed on. The rk8xx fix for that is not
kept here; it went to Armbian's `rockchip-6.18` / `rockchip-7.3` patch sets as
[armbian/build#11115](https://github.com/armbian/build/pull/11115), and the
kernel build uses that pull request's head until it is merged.

## Building and installing

Everything is built on an x86 Linux host (developed under WSL2, Ubuntu 24.04)
with Docker; nothing is built on the board.

```sh
# kernel: config from Armbian (linux-rockchip-current.config), or CONFIG=<file>
bash scripts/build-h264enc-kernel.sh
# on the board
sudo scripts/tinker-kernel-h264enc.sh install h264enc-kernel-6.18.58.tar.gz
sudo scripts/tinker-kernel-h264enc.sh use-test      # then reboot

# GStreamer plugin -> gst-h264enc.tar.gz, unpack to ~/h264enc/gst on the board
bash scripts/build-gstreamer-h264enc.sh

# camera: modules from the kernel build + overlays
bash scripts/build-camera-overlays.sh
tinker-camera.sh install DIR && tinker-camera.sh enable tc358743   # or ov5647, then reboot
tinker-camera.sh hdmi 1280 720 && tinker-camera.sh grab 30
tinker-camera.sh boot-edid on   # optional: EDID (= HDMI hot-plug) at boot; no-op without a TC358743
```

The build scripts pin their inputs (kernel 6.18.58; an Armbian commit, the head
of armbian/build#11115 until it is merged; GStreamer MR !5676 at 9ef0e91); the
GStreamer one stops if the MR head moved.

## Known issues

- With the C790, the ISP's MI_CTRL register falls back to its reset value a
  few times a minute (likely electrical); patch 0008 restores it, dropping one
  frame each time. Root cause unknown.
- The H1 encoder here has no B-frames and one reference frame; compression
  efficiency is far below software encoders.
- `v4l2src io-mode=auto` returns stale buffers from the rkisp1 main path, or
  imports the encoder's padded pool (EINVAL); use `io-mode=mmap`, and let the
  allocation query through to the encoder so that v4l2src sizes its pool from
  the encoder's minimum (4 buffers). Dropping the query (`identity
  drop-allocation=true`) leaves v4l2src with 2 buffers, and since Linux 6.14
  rkisp1 no longer rounds that up: frames are lost (720p60 at 40 fps).
  `patches/camera/0009` makes rkisp1 allocate at least four again.
- Tested on a single Tinker Board S only.

## Use of AI tools

The patches and scripts written by ohayoyogi (h264enc 0009–0014, camera
0002–0009, the scripts, and the rk8xx power-off patch sent to Armbian) were
developed with the help of Claude Code (Anthropic); the submitter reviewed them and tested them on the
hardware. The patches by other authors (h264enc 0001–0008, and the former
camera 0001 backport) are not part of this.

## License

- Kernel patches: GPL-2.0, like the Linux kernel. Patches by other authors keep
  their authorship and Signed-off-by lines.
- GStreamer patches: LGPL-2.1-or-later, like GStreamer.
- Everything else in this repository (scripts, device tree overlays, EDID
  generator, tools): GPL-2.0, see [LICENSE](LICENSE).
- The 720p60 EDID comes from Spotpear's C780/C790 user guide.
