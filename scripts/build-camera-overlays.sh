#!/bin/bash
# Compile the Tinker Board camera DT overlays (patches/camera/dt/*.dts).
# Run inside WSL; needs a kernel source tree for the dt-bindings headers.
#
#   bash scripts/build-camera-overlays.sh [kernel-src]   # -> patches/camera/dt/*.dtbo
#
# On the board (Armbian): copy a .dtbo to /boot/overlay-user/ and add its
# name (without .dtbo) to user_overlays= in /boot/armbianEnv.txt, reboot.
set -euo pipefail

KSRC=${1:-$HOME/h264enc/linux-6.18.58-h264enc}
DIR=$(cd "$(dirname "$0")/../patches/camera/dt" && pwd)
DTC=$(command -v dtc || echo "$KSRC/scripts/dtc/dtc")
[ -x "$DTC" ] || { echo "install device-tree-compiler"; exit 1; }

for f in "$DIR"/*.dts; do
	o=${f%.dts}.dtbo
	cpp -nostdinc -undef -x assembler-with-cpp -I "$KSRC/include" \
		-I "$KSRC/scripts/dtc/include-prefixes" "$f" |
		"$DTC" -q -@ -I dts -O dtb -o "$o" -
	echo "$(basename "$o")"
done
