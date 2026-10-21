#!/bin/bash
# Switch the Tinker Board between the stock Armbian kernel and the
# H.264-encoder test kernel ($TEST, default 6.12.58-h264enc). Run on the
# Tinker with sudo. Build the tarball with scripts/build-h264enc-kernel.sh.
#
#   sudo ./tinker-kernel-h264enc.sh install /tmp/h264enc-kernel-6.12.58.tar.gz
#   sudo ./tinker-kernel-h264enc.sh use-test     # boot the test kernel next time
#   sudo ./tinker-kernel-h264enc.sh use-stock    # boot the stock kernel next time
#   sudo ./tinker-kernel-h264enc.sh status
#
# Only the /boot/zImage and /boot/uInitrd symlinks are switched; the stock
# kernel, its modules and the DTBs are never touched.
#
# If the test kernel does not boot, stop U-Boot on the serial console
# (UART2, 115200) and run:
#   load mmc 1:1 ${kernel_addr_r} /boot/vmlinuz-6.12.58-current-rockchip
#   load mmc 1:1 ${ramdisk_addr_r} /boot/uInitrd-6.12.58-current-rockchip
#   load mmc 1:1 ${fdt_addr_r} /boot/dtb/rk3288-tinker-s.dtb
#   setenv bootargs root=UUID=<root-uuid> rootwait console=ttyS2,115200n8
# (root UUID: "findmnt -no UUID /" on the board; it changes with the SD card)
#   bootz ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
# then "sudo ./tinker-kernel-h264enc.sh use-stock".
# (mmc device number may differ; "mmc list" / "ls mmc 1:1 /boot" to check.)
set -euo pipefail

STOCK=${STOCK:-$(ls /boot/vmlinuz-*-current-rockchip 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||')}
TEST=${TEST:-6.12.58-h264enc}

link() {
	ln -sfn "vmlinuz-$1" /boot/zImage
	ln -sfn "uInitrd-$1" /boot/uInitrd
	sync
	echo "next boot: $1"
}

case "${1:-status}" in
install)
	tarball=${2:?tarball path}
	# /lib is a symlink to usr/lib on Ubuntu; without --keep-directory-symlink
	# GNU tar replaces it with a real directory and breaks every program.
	tar -xzf "$tarball" -C / --keep-directory-symlink --no-overwrite-dir
	depmod -a "$TEST"
	if [ -e "/boot/initrd.img-$TEST" ]; then
		update-initramfs -u -k "$TEST"
	else
		update-initramfs -c -k "$TEST"
	fi
	mkimage -A arm -O linux -T ramdisk -C gzip -n uInitrd \
		-d "/boot/initrd.img-$TEST" "/boot/uInitrd-$TEST" >/dev/null
	# update-initramfs may move the generic initrd.img symlink; keep stock
	ln -sfn "initrd.img-$STOCK" /boot/initrd.img
	ls -la "/boot/vmlinuz-$TEST" "/boot/uInitrd-$TEST" "/lib/modules/$TEST" | head
	echo "installed; run 'use-test' to boot it"
	;;
use-test)  link "$TEST" ;;
use-stock) link "$STOCK" ;;
status)
	echo "running: $(uname -r)"
	ls -la /boot/zImage /boot/uInitrd
	;;
*) echo "usage: $0 install <tar.gz>|use-test|use-stock|status" >&2; exit 1 ;;
esac
