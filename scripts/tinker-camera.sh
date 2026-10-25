#!/bin/bash
# CSI camera on the Tinker Board (RK3288 ISP + DPHY RX0), Armbian.
# Files: the four .ko from a kernel built by scripts/build-h264enc-kernel.sh
# (tc358743, ov5647, rockchip-isp1, phy-rockchip-dphy-rx0) and the .dtbo from
# scripts/build-camera-overlays.sh, in one directory (on the board: ~/camera).
#
#   tinker-camera.sh install DIR          modules -> /lib/modules/$(uname -r)/updates/camera
#   tinker-camera.sh enable tc358743|ov5647   overlay -> /boot/overlay-user, user_overlays=  (reboot)
#   tinker-camera.sh disable              remove the overlay from user_overlays= (reboot)
#   tinker-camera.sh uninstall            remove the modules again
#   tinker-camera.sh status               media graph, subdevs, recent kernel messages
#   tinker-camera.sh hdmi [W H]           TC358743: EDID, lock timings, configure the pipeline
#   tinker-camera.sh boot-edid on [FILE]  TC358743: load the EDID whenever it appears (udev),
#                                         so the HDMI source sees a monitor without a capture
#   tinker-camera.sh boot-edid off        remove that again
#   tinker-camera.sh ov5647 [W H]         OV5647: configure the pipeline (default 1296x972)
#   tinker-camera.sh grab [N]             capture N NV12 frames from the main path to /tmp
set -euo pipefail

R=$(uname -r)
UPD=/lib/modules/$R/updates/camera
ENV=/boot/armbianEnv.txt
OVL=(rk3288-tinker-isp-tc358743 rk3288-tinker-isp-ov5647)

set_user_overlays() {   # $1 = new value (may be empty)
	sudo sed -i '/^user_overlays=/d' "$ENV"
	[ -n "$1" ] && echo "user_overlays=$1" | sudo tee -a "$ENV" >/dev/null
	grep -E '^(overlays|user_overlays)=' "$ENV" || true
}

others() {   # current user_overlays minus ours
	local cur
	cur=$(sed -n 's/^user_overlays=//p' "$ENV")
	for o in "${OVL[@]}"; do cur=$(echo " $cur " | sed "s/ $o / /g"); done
	echo $cur
}

subdev_of() {   # entity name prefix -> /dev/v4l-subdevN
	media-ctl -d /dev/media0 -e "$(media-ctl -d /dev/media0 -p | sed -n "s/.*entity [0-9]*: \($1[^(]*\) (.*/\1/p" | head -1 | sed 's/ *$//')"
}

case "${1:-}" in
install)
	D=${2:?directory with the .ko and .dtbo files}
	sudo mkdir -p "$UPD"
	sudo cp "$D"/*.ko "$UPD"/
	sudo mkdir -p /boot/overlay-user
	sudo cp "$D"/*.dtbo /boot/overlay-user/
	sudo depmod "$R"
	modinfo -n rockchip-isp1 tc358743 ov5647 phy-rockchip-dphy-rx0
	;;
enable)
	case "${2:-}" in
	tc358743|ov5647) o=rk3288-tinker-isp-$2 ;;
	*) echo "enable tc358743|ov5647"; exit 1 ;;
	esac
	[ -f /boot/overlay-user/$o.dtbo ] || { echo "run install first"; exit 1; }
	set_user_overlays "$(others) $o"
	echo "reboot to apply"
	;;
disable)
	set_user_overlays "$(others)"
	echo "reboot to apply"
	;;
uninstall)
	sudo rm -rf "$UPD"
	sudo depmod "$R"
	;;
status)
	ls /dev/media* /dev/v4l-subdev* 2>/dev/null || echo "no media device (overlay not active?)"
	[ -e /dev/media0 ] && media-ctl -d /dev/media0 -p | grep -E "entity|pad|fmt|->" | head -60
	sudo dmesg | grep -iE "rkisp1|isp@|dphy|tc358743|ov5647|iommu@ff914000" | tail -20
	;;
hdmi)
	W=${2:-1280} H=${3:-720}
	S=$(subdev_of tc358743)
	# The EDID from the Spotpear C780/C790 guide prefers 720p60 and lists
	# 1080p up to 30 Hz but not 1080p60, which does not fit 2 lanes at
	# 972 Mbit/s. Its checksums are wrong, hence --fix-edid-checksums.
	# Without the file, a stock HDMI EDID.
	# EDID=.../edid-tc358743-1080p50.txt for 1080p50 (scripts/make-edid-1080p50.py)
	EDID=${EDID:-$(dirname "$0")/edid-tc358743.txt}
	if [ -f "$EDID" ]; then
		v4l2-ctl -d "$S" --set-edid=pad=0,file="$EDID" --fix-edid-checksums
	else
		v4l2-ctl -d "$S" --set-edid=pad=0,type=hdmi || true
	fi
	sleep 2
	v4l2-ctl -d "$S" --query-dv-timings
	v4l2-ctl -d "$S" --set-dv-bt-timings query
	M="media-ctl -d /dev/media0"
	E=$($M -p | sed -n 's/.*entity [0-9]*: \(tc358743[^(]*\) (.*/\1/p' | sed 's/ *$//')
	$M -V "\"$E\":0 [fmt:UYVY8_1X16/${W}x${H} field:none]"
	$M -V "\"rkisp1_csi\":0 [fmt:UYVY8_1X16/${W}x${H}]"
	$M -V "\"rkisp1_isp\":0 [fmt:UYVY8_1X16/${W}x${H} crop:(0,0)/${W}x${H}]"
	$M -V "\"rkisp1_isp\":2 [fmt:YUYV8_2X8/${W}x${H} crop:(0,0)/${W}x${H}]"
	$M -V "\"rkisp1_resizer_mainpath\":0 [fmt:YUYV8_2X8/${W}x${H} crop:(0,0)/${W}x${H}]"
	$M -V "\"rkisp1_resizer_mainpath\":1 [fmt:YUYV8_1_5X8/${W}x${H}]"
	$M -p | grep -A2 -E "tc358743|rkisp1_csi|rkisp1_isp|resizer_mainpath" | grep fmt
	;;
boot-edid)
	# The TC358743 raises HDMI hot-plug detect only once an EDID is written.
	# udev starts tc358743-edid@<subdev>.service when the subdevice appears,
	# so nothing happens on a board without one (C790 not fitted, overlay
	# off). Uses tc358743-edid.{sh,rules} and tc358743-edid@.service from
	# the directory of this script.
	D=$(dirname "$0")
	case "${2:-}" in
	on)
		F=${3:-$D/edid-tc358743.txt}
		[ -f "$F" ] || { echo "no EDID file $F"; exit 1; }
		sudo install -m 755 "$D/tc358743-edid.sh" /usr/local/sbin/tc358743-edid.sh
		sudo install -m 644 "$D/tc358743-edid@.service" /etc/systemd/system/tc358743-edid@.service
		sudo install -m 644 "$D/tc358743-edid.rules" /etc/udev/rules.d/99-tc358743-edid.rules
		sudo install -m 644 "$F" /etc/tc358743-edid.txt
		sudo systemctl daemon-reload
		sudo udevadm control --reload
		sudo /usr/local/sbin/tc358743-edid.sh   # now, if one is there
		;;
	off)
		sudo rm -f /usr/local/sbin/tc358743-edid.sh /etc/systemd/system/tc358743-edid@.service \
			/etc/udev/rules.d/99-tc358743-edid.rules /etc/tc358743-edid.txt
		sudo systemctl daemon-reload
		sudo udevadm control --reload
		echo "the EDID now loaded stays until the driver is unloaded (reboot)"
		;;
	*) echo "boot-edid on [EDID file] | off"; exit 1 ;;
	esac
	;;
ov5647)
	# RAW10 Bayer in, the ISP demosaics; 1296x972 is the 2x2 binned mode
	W=${2:-1296} H=${3:-972}
	M="media-ctl -d /dev/media0"
	E=$($M -p | sed -n 's/.*entity [0-9]*: \(ov5647[^(]*\) (.*/\1/p' | sed 's/ *$//')
	[ -n "$E" ] || { echo "no ov5647 in the media graph"; exit 1; }
	$M -V "\"$E\":0 [fmt:SBGGR10_1X10/${W}x${H}]"
	$M -V "\"rkisp1_csi\":0 [fmt:SBGGR10_1X10/${W}x${H}]"
	$M -V "\"rkisp1_isp\":0 [fmt:SBGGR10_1X10/${W}x${H} crop:(0,0)/${W}x${H}]"
	$M -V "\"rkisp1_isp\":2 [fmt:YUYV8_2X8/${W}x${H} crop:(0,0)/${W}x${H}]"
	$M -V "\"rkisp1_resizer_mainpath\":0 [fmt:YUYV8_2X8/${W}x${H} crop:(0,0)/${W}x${H}]"
	$M -V "\"rkisp1_resizer_mainpath\":1 [fmt:YUYV8_1_5X8/${W}x${H}]"
	$M -p | grep -A2 -E "ov5647|rkisp1_csi|rkisp1_isp|resizer_mainpath" | grep fmt
	echo "no 3A (AWB/AE in the ISP) yet: expect a dark or green-tinted picture"
	;;
grab)
	N=${2:-30}
	V=$(media-ctl -d /dev/media0 -e rkisp1_mainpath)
	F=$(media-ctl -d /dev/media0 -p | sed -n '/rkisp1_resizer_mainpath/,/^$/s/.*fmt:[^/]*\/\([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)
	set -- $F
	v4l2-ctl -d "$V" --set-fmt-video=width=$1,height=$2,pixelformat=NV12
	v4l2-ctl -d "$V" --stream-mmap --stream-count="$N" --stream-to=/tmp/csi.nv12
	ls -la /tmp/csi.nv12
	echo "view: ffmpeg -f rawvideo -pix_fmt nv12 -s $1x$2 -i /tmp/csi.nv12 -frames 1 /tmp/csi.png"
	;;
*)
	sed -n '2,18p' "$0"; exit 1 ;;
esac
