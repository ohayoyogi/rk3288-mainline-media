#!/bin/bash
# Build the Tinker Board (RK3288) kernel with the H1 H.264 stateless encoder.
# Run inside WSL (Ubuntu 24.04) on the ext4 side; needs docker and network.
#
#   bash scripts/build-h264enc-kernel.sh                # release kernel
#   DEBUG=1 bash scripts/build-h264enc-kernel.sh        # + experiment knobs
#
# Inputs (override with env vars):
#   KVER       kernel.org version          (6.18.58)
#   ARMBIAN    armbian/build commit or tag (needs patch/kernel/archive/rockchip-6.18). Default:
#              main of 2026-10-27, with the rk8xx power-off patch (armbian/build#11115),
#              without which "shutdown -h" only halts
#   CONFIG     kernel config               (Armbian's config/kernel/linux-rockchip-current.config;
#              or the board's /boot/config-*, brought up to date with olddefconfig)
#   WORK       build directory             (~/h264enc)
# Output: $WORK/h264enc-kernel-$KVER.tar.gz (boot/ with the RK3288 DTBs + usr/lib/modules/), install it
# on the board with scripts/tinker-kernel-h264enc.sh install <tarball>.
set -euo pipefail

KVER=${KVER:-6.18.58}
ARMBIAN=${ARMBIAN:-2ca897c5ef976522ff416797426dbff560e260de}
WORK=${WORK:-$HOME/h264enc}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=$WORK/linux-$KVER-h264enc
AB=$WORK/armbian-build-${ARMBIAN:0:12}
P=$AB/patch/kernel/archive/rockchip-${KVER%.*}
CONFIG=${CONFIG:-$AB/config/kernel/linux-rockchip-current.config}
IMG=tinker-kbuild

mkdir -p "$WORK"
cd "$WORK"

[ -f linux-$KVER.tar.xz ] || curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz
if [ ! -d "$AB" ]; then
	# fetch by commit or tag, only the patch set and the config
	git init -q "$AB"
	git -C "$AB" remote add origin https://github.com/armbian/build
	git -C "$AB" sparse-checkout set --no-cone "/patch/kernel/archive/rockchip-${KVER%.*}/" \
		/config/kernel/linux-rockchip-current.config
	git -C "$AB" fetch -q --depth 1 --filter=blob:none origin "$ARMBIAN"
	git -C "$AB" checkout -q FETCH_HEAD
fi
[ -f "$P/series.conf" ] || { echo "no rockchip-${KVER%.*} patches in armbian $ARMBIAN"; exit 1; }
[ -f "$CONFIG" ] || { echo "missing $CONFIG"; exit 1; }

if ! docker image inspect $IMG >/dev/null 2>&1; then
	docker build -q -t $IMG - <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev libelf-dev cpio kmod u-boot-tools \
    gcc-arm-linux-gnueabihf python3 rsync git xz-utils patch ca-certificates file \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

rm -rf "$SRC" && mkdir "$SRC"
tar -xf linux-$KVER.tar.xz -C "$SRC" --strip-components=1
cd "$SRC"
git init -q && git config user.name builder && git config user.email builder@localhost
git add -A && git commit -qm "v$KVER"

grep -vE '^\s*(#|$)' "$P/series.conf" | while read -r l; do
	case "$l" in -*) continue ;; esac
	patch -p1 -s -N --no-backup-if-mismatch < "$P/$l"
done
cp "$P"/dt/* arch/arm/boot/dts/rockchip/ 2>/dev/null || true
git add -A && git commit -qm "armbian ${ARMBIAN:0:12} rockchip-${KVER%.*} patches"

for p in "$REPO"/patches/h264enc/*.patch; do
	case "$(basename "$p")" in *DEBUG*) [ "${DEBUG:-0}" = 1 ] || continue ;; esac
	git am -q -3 "$p"
done
# RK3288 ISP / DPHY RX0 / TC358743 for CSI cameras (modules only)
for p in "$REPO"/patches/camera/*.patch; do
	git am -q -3 "$p"
done
git log --oneline -20
cp "$CONFIG" .config

docker run --rm -u "$(id -u):$(id -g)" -v "$WORK:/w" -w "/w/$(basename "$SRC")" \
	$IMG bash -c '
set -e
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- LOCALVERSION=
./scripts/config --set-str LOCALVERSION "-h264enc"
./scripts/config -m VIDEO_TC358743 -d VIDEO_TC358743_CEC -m VIDEO_OV5647
make olddefconfig >/dev/null
make -j"$(nproc)" zImage modules
# -@: the DT overlays (camera, Armbian) need the symbols
make -j"$(nproc)" DTC_FLAGS=-@ dtbs >/dev/null
R=$(make -s kernelrelease)
rm -rf ../out && mkdir -p ../out/boot/dtb-$R
make -s INSTALL_MOD_PATH=../out/usr INSTALL_MOD_STRIP=1 modules_install
rm -f ../out/usr/lib/modules/$R/build
cp arch/arm/boot/zImage ../out/boot/vmlinuz-$R
cp .config ../out/boot/config-$R
cp System.map ../out/boot/System.map-$R
cp arch/arm/boot/dts/rockchip/rk3288*.dtb ../out/boot/dtb-$R/
echo "release=$R"
'
# modules under usr/lib: /lib is a symlink on Ubuntu, never ship a lib/ dir
tar -czf "$WORK/h264enc-kernel-$KVER.tar.gz" --owner=0 --group=0 -C "$WORK/out" boot usr
ls -la "$WORK/h264enc-kernel-$KVER.tar.gz"
