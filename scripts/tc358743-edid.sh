#!/bin/bash
# Load the EDID into a TC358743 (Geekworm C790), so the HDMI source sees a
# monitor whether or not anything captures: the bridge raises hot-plug
# detect only once an EDID has been written, and keeps it until the driver
# is unloaded. Started by udev (tc358743-edid.rules) when the subdevice
# appears, so on a board without a TC358743 nothing runs.
#
#   tc358743-edid.sh [/dev/v4l-subdevN] [EDID file]
#
# EDID file: hex as in "v4l2-ctl --get-edid" (default /etc/tc358743-edid.txt,
# or $TC358743_EDID); checksums are fixed. Without the file a stock HDMI EDID
# is loaded, unless one is already there. An identical EDID is not written
# again: every write drops hot-plug detect for a moment.
set -euo pipefail

DEV=${1:-}
EDID=${2:-${TC358743_EDID:-/etc/tc358743-edid.txt}}

if [ -z "$DEV" ]; then
	for n in /sys/class/video4linux/v4l-subdev*/name; do
		[ -e "$n" ] || continue
		case "$(cat "$n")" in
		tc358743*) DEV=/dev/$(basename "$(dirname "$n")") ;;
		esac
	done
fi
if [ -z "$DEV" ]; then
	echo "no TC358743 subdevice"
	exit 0
fi

hexbytes() {   # any hex text -> "xx xx xx ..." (lower case)
	tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f' | sed 's/../& /g'
}

fix_checksums() {   # the last byte of each 128-byte block makes its sum 0 (mod 256)
	awk 'function hex(h,  i, v) { v = 0; for (i = 1; i <= 2; i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return v }
	{
		for (i = 1; i <= NF; i++) b[i - 1] = hex($i)
		for (s = 0; s + 128 <= NF; s += 128) {
			t = 0
			for (i = s; i < s + 127; i++) t += b[i]
			b[s + 127] = (256 - t % 256) % 256
		}
		for (i = 0; i < NF; i++) printf "%02x ", b[i]
	}'
}

cur=$(v4l2-ctl -d "$DEV" --get-edid=pad=0,format=hex 2>/dev/null | hexbytes || true)
if [ -f "$EDID" ]; then
	want=$(hexbytes <"$EDID" | fix_checksums)
	if [ "$cur" = "$want" ]; then
		echo "$DEV: EDID from $EDID already loaded"
		exit 0
	fi
	v4l2-ctl -d "$DEV" --set-edid=pad=0,file="$EDID" --fix-edid-checksums
	echo "$DEV: EDID loaded from $EDID"
elif [ -n "$cur" ]; then
	echo "$DEV: no $EDID, keeping the EDID that is there"
else
	v4l2-ctl -d "$DEV" --set-edid=pad=0,type=hdmi
	echo "$DEV: no $EDID, stock HDMI EDID loaded"
fi
