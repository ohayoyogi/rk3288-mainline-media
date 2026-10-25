# rk3288-mainline-media

Kernel and GStreamer patches, device tree overlays and scripts that make the
RK3288's video hardware usable on a **mainline** kernel (Armbian 6.12),
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

## Results (Tinker Board, Armbian 25.11.1, kernel 6.12.58)

| What | Result |
|---|---|
| H1 H.264 encode | 1080p ~56–68 fps, 720p 122–141 fps (constant QP 28, simple content); 30 min 1080p30 CBR soak without faults |
| OV5647 via ISP | 1296x972 / 1080p NV12 at 30 fps |
| TC358743 (C790) via ISP | 720p60 at 60 fps, 1080p50 at 50 fps (2 lanes), no CSI errors |
| HDMI → capture latency | 67 ms median (Tinker's own HDMI output looped into the C790) |
| HDMI → browser via simplekvm | 113 ms average click-to-display (720p60) |

## Contents

| Path | What it is |
|---|---|
| `patches/h264enc/0001–0008` | Hantro H1 VP8/H.264 stateless encoder RFCs by Andrzej Pietrasiewicz (Collabora) and Hugues Fruchet (ST), with original authorship and links |
| `patches/h264enc/0009–0014` | RK3288 enablement and fixes: contiguous reference frames, legacy H1 quirks, IOMMU fault recovery, signed ENC_CTRL0 fields (0012 and 0014 are debug-only) |
| `patches/camera/0001` | tc358743: 972 Mbit/s link frequency (backport from mainline) |
| `patches/camera/0002–0003` | DPHY RX0 and rkisp1 support for RK3288 (based on Karthik Poduval's 2020 RFC) |
| `patches/camera/0004–0005` | rkisp1 uses the lane count / link frequency the source reports; tc358743 gets `LINK_FREQ` and `PIXEL_RATE` |
| `patches/camera/0006–0008` | RK3288 ISP fixes: 32-beat chroma bursts, error-interrupt storm guard, MI_CTRL reset recovery |
| `patches/camera/dt/` | Tinker Board overlays: ISP + DPHY + TC358743 or OV5647 |
| `patches/camera/edid-*.txt` | TC358743 EDIDs: 720p60 preferred (from Spotpear's guide) and 1080p50 preferred |
| `patches/gstreamer/` | GStreamer MR !5676 (`v4l2slh264enc`) built against 1.24: UYVY input, VUI without reordering, copy into macroblock-padded buffers |
| `scripts/build-h264enc-kernel.sh` | builds the kernel (kernel.org 6.12.58 + Armbian patches + these) in Docker under WSL |
| `scripts/build-gstreamer-h264enc.sh` | builds the patched v4l2codecs plugin for armhf |
| `scripts/build-camera-overlays.sh` | compiles the DT overlays |
| `scripts/tinker-kernel-h264enc.sh` | installs the kernel tarball and switches between it and the stock kernel |
| `scripts/tinker-camera.sh` | installs the camera modules/overlays and sets up the media pipeline (OV5647 / HDMI) |
| `scripts/tc358743-edid.{sh,rules}`, `scripts/tc358743-edid@.service` | loads the EDID when the TC358743 appears, so the HDMI source sees a monitor without a capture running (`tinker-camera.sh boot-edid on`) |
| `scripts/tinker-h264enc-test.sh` | encoder smoke test on the board |
| `scripts/csi-record.py`, `scripts/frame-check.py` | capture diagnostics: stale-buffer detection, MI register sampling |
| `scripts/make-edid-1080p50.py` | generates the 1080p50 EDID |
| `scripts/tinker-sdmmc-hs.dts` | overlay for a faster SD card mode |

## Building and installing

Everything is built on an x86 Linux host (developed under WSL2, Ubuntu 24.04)
with Docker; nothing is built on the board.

```sh
# kernel: needs the board's config at ~/h264enc/config-tinker-6.12.58
bash scripts/build-h264enc-kernel.sh
# on the board
sudo scripts/tinker-kernel-h264enc.sh install h264enc-kernel-6.12.58.tar.gz
sudo scripts/tinker-kernel-h264enc.sh use-test      # then reboot

# GStreamer plugin -> gst-h264enc.tar.gz, unpack to ~/h264enc/gst on the board
bash scripts/build-gstreamer-h264enc.sh

# camera: modules from the kernel build + overlays
bash scripts/build-camera-overlays.sh
tinker-camera.sh install DIR && tinker-camera.sh enable tc358743   # or ov5647, then reboot
tinker-camera.sh hdmi 1280 720 && tinker-camera.sh grab 30
tinker-camera.sh boot-edid on   # optional: EDID (= HDMI hot-plug) at boot; no-op without a TC358743
```

The build scripts pin their inputs (kernel 6.12.58, Armbian v25.11.1,
GStreamer MR !5676 at 9ef0e91); the GStreamer one stops if the MR head moved.

## Known issues

- With the C790, the ISP's MI_CTRL register falls back to its reset value a
  few times a minute (likely electrical); patch 0008 restores it, dropping one
  frame each time. Root cause unknown.
- The H1 encoder here has no B-frames and one reference frame; compression
  efficiency is far below software encoders.
- `v4l2src io-mode=auto` returns stale buffers from the rkisp1 main path; use
  `io-mode=mmap` and `identity drop-allocation=true` in front of the encoder.
- Tested on a single Tinker Board S only.

## License

- Kernel patches: GPL-2.0, like the Linux kernel. Patches by other authors keep
  their authorship and Signed-off-by lines.
- GStreamer patches: LGPL-2.1-or-later, like GStreamer.
- Everything else in this repository (scripts, device tree overlays, EDID
  generator, tools): GPL-2.0, see [LICENSE](LICENSE).
- The 720p60 EDID comes from Spotpear's C780/C790 user guide.
