#!/bin/bash
# Check the H.264 stateless encoder on the Tinker Board after booting
# 6.12.13-h264enc. Run as the normal user (member of the video group).
#
#   ./tinker-h264enc-test.sh            # kernel side only
#   ./tinker-h264enc-test.sh gst        # also encode with GStreamer v4l2slh264enc
#
# GStreamer side expects the MR !5676 build (opt/gst-h264enc) unpacked under
# $GSTDIR (default ~/h264enc/gst).
set -u

ENC=$(for d in /sys/class/video4linux/video*; do
	[ "$(cat "$d/name")" = "rockchip,rk3288-vpu-enc" ] && echo "/dev/${d##*/}"
done)

echo "== kernel"; uname -r
echo "== encoder device: ${ENC:-not found}"
[ -n "$ENC" ] || exit 1
echo "== capture (coded) formats"; v4l2-ctl -d "$ENC" --list-formats
echo "== output (raw) formats"; v4l2-ctl -d "$ENC" --list-formats-out
echo "== controls"; v4l2-ctl -d "$ENC" --list-ctrls
echo "== dmesg"; dmesg 2>/dev/null | grep -iE 'hantro|vpu' | tail -20

[ "${1:-}" = gst ] || exit 0

GSTDIR=${GSTDIR:-$HOME/h264enc/gst}
export GST_PLUGIN_PATH=$GSTDIR/lib/gstreamer-1.0
export LD_LIBRARY_PATH=$GSTDIR/lib
out=${OUT:-$HOME/h264enc}
mkdir -p "$out"

echo "== gst-inspect"; gst-inspect-1.0 v4l2slh264enc | head -40

for size in 640x480 1280x720 1920x1080; do
	w=${size%x*}; h=${size#*x}
	f="$out/test-$size.h264"
	echo "== encode $size, 300 frames"
	start=$(date +%s.%N)
	gst-launch-1.0 -q videotestsrc num-buffers=300 pattern=smpte \
		! "video/x-raw,format=NV12,width=$w,height=$h,framerate=30/1" \
		! v4l2slh264enc ! h264parse ! "video/x-h264,stream-format=byte-stream" \
		! filesink location="$f"
	rc=$?
	end=$(date +%s.%N)
	echo "rc=$rc size=$(stat -c %s "$f" 2>/dev/null) fps=$(echo "300 / ($end - $start)" | bc -l | cut -c1-5)"
done
echo "== decode check (HW decoder, 1280x720)"
gst-launch-1.0 -q filesrc location="$out/test-1280x720.h264" ! h264parse \
	! v4l2slh264dec ! fakesink && echo "decode OK"
