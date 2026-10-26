#!/bin/bash
# Build the Tinker Board (RK3288) kernel with the H1 H.264 stateless encoder.
# Run inside WSL (Ubuntu 24.04) on the ext4 side; needs docker and network.
#
#   bash scripts/build-h264enc-kernel.sh                # release kernel
#   DEBUG=1 bash scripts/build-h264enc-kernel.sh        # + experiment knobs
#
# Inputs (override with env vars):
#   KVER       kernel.org version          (6.12.58)
#   ARMBIAN    armbian/build tag            (v25.11.1)
#   CONFIG     kernel config from the board (scp tinker:/boot/config-$KVER-current-rockchip)
#   WORK       build directory              (~/h264enc)
# Output: $WORK/h264enc-kernel-$KVER.tar.gz (boot/ + usr/lib/modules/), install it
# on the board with scripts/tinker-kernel-h264enc.sh install <tarball>.
set -euo pipefail

KVER=${KVER:-6.12.58}
ARMBIAN=${ARMBIAN:-v25.11.1}
WORK=${WORK:-$HOME/h264enc}
CONFIG=${CONFIG:-$WORK/config-tinker-$KVER}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=$WORK/linux-$KVER-h264enc
IMG=tinker-kbuild

mkdir -p "$WORK"
cd "$WORK"
[ -f "$CONFIG" ] || { echo "missing $CONFIG (copy /boot/config-$KVER-current-rockchip from the board)"; exit 1; }

[ -f linux-$KVER.tar.xz ] || curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz
if [ ! -d armbian-build-$ARMBIAN ]; then
	git clone -q --depth 1 --branch "$ARMBIAN" --filter=blob:none --sparse \
		https://github.com/armbian/build armbian-build-$ARMBIAN
	git -C armbian-build-$ARMBIAN sparse-checkout set --no-cone '/patch/kernel/archive/rockchip-6.12/'
fi

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

P=$WORK/armbian-build-$ARMBIAN/patch/kernel/archive/rockchip-6.12
grep -vE '^\s*(#|$)' "$P/series.conf" | while read -r l; do
	case "$l" in -*) continue ;; esac
	patch -p1 -s -N --no-backup-if-mismatch < "$P/$l"
done
cp "$P"/dt/* arch/arm/boot/dts/rockchip/ 2>/dev/null || true
git add -A && git commit -qm "armbian $ARMBIAN rockchip-6.12 patches"

for p in "$REPO"/patches/h264enc/*.patch; do
	case "$(basename "$p")" in *DEBUG*) [ "${DEBUG:-0}" = 1 ] || continue ;; esac
	git am -q -3 "$p"
done
# RK3288 ISP / DPHY RX0 / TC358743 for CSI cameras (modules only)
for p in "$REPO"/patches/camera/*.patch; do
	git am -q -3 "$p"
done
# RK808 power off ("shutdown -h" only halted, the board stayed powered)
for p in "$REPO"/patches/power/*.patch; do
	git am -q -3 "$p"
done
git log --oneline | head -20

docker run --rm -u "$(id -u):$(id -g)" -v "$WORK:/w" -w "/w/$(basename "$SRC")" \
	-e CONFIG_IN="/w/$(basename "$CONFIG")" $IMG bash -c '
set -e
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- LOCALVERSION=
cp "$CONFIG_IN" .config
./scripts/config --set-str LOCALVERSION "-h264enc"
./scripts/config -m VIDEO_TC358743 -d VIDEO_TC358743_CEC -m VIDEO_OV5647
make olddefconfig >/dev/null
make -j"$(nproc)" zImage modules
R=$(make -s kernelrelease)
rm -rf ../out && mkdir -p ../out/boot
make -s INSTALL_MOD_PATH=../out/usr INSTALL_MOD_STRIP=1 modules_install
rm -f ../out/usr/lib/modules/$R/build
cp arch/arm/boot/zImage ../out/boot/vmlinuz-$R
cp .config ../out/boot/config-$R
cp System.map ../out/boot/System.map-$R
echo "release=$R"
'
# modules under usr/lib: /lib is a symlink on Ubuntu, never ship a lib/ dir
tar -czf "$WORK/h264enc-kernel-$KVER.tar.gz" --owner=0 --group=0 -C "$WORK/out" boot usr
ls -la "$WORK/h264enc-kernel-$KVER.tar.gz"
