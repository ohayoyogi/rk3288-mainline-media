#!/bin/bash
# Build the v4l2codecs GStreamer plugin with the stateless H.264 encoder
# (v4l2slh264enc, MR !5676) for the Tinker Board's Ubuntu 24.04 (GStreamer
# 1.24.2, armhf). Run inside WSL; needs docker and network.
#
#   bash scripts/build-gstreamer-h264enc.sh
#
# Inputs (override with env vars):
#   MR_SHA   commit of refs/merge-requests/5676/head that the patches are for
#   WORK     build directory (~/h264enc/gstbuild)
# Output: $WORK/gst-h264enc.tar.gz with
#   lib/libgstcodecs-1.0.so*, lib/libgstcodecparsers-1.0.so*   (newer than 1.24's)
#   lib/gstreamer-1.0/libgstv4l2codecs.so
# On the board: mkdir -p ~/h264enc/gst && tar -C ~/h264enc/gst -xzf gst-h264enc.tar.gz
# kvm.py points GST_PLUGIN_PATH / LD_LIBRARY_PATH there (--gst-dir). Only
# these libraries go into LD_LIBRARY_PATH: shipping the other libgst*-bad
# libraries breaks the system plugins (h264parse etc.).
# Runtime packages: gstreamer1.0-plugins-base / -good / -bad, libgudev-1.0-0.
set -euo pipefail

MR_SHA=${MR_SHA:-9ef0e91}
WORK=${WORK:-$HOME/h264enc/gstbuild}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=$WORK/gst-plugins-bad-mr5676
IMG=tinker-gstx

mkdir -p "$WORK"
cd "$WORK"

if ! docker image inspect $IMG >/dev/null 2>&1; then
	docker build -q -t $IMG - <<'DOCKERFILE'
FROM ubuntu:24.04
RUN dpkg --add-architecture armhf && \
    sed -i 's|^URIs: http://archive.ubuntu.com/ubuntu/|URIs: http://archive.ubuntu.com/ubuntu/\nArchitectures: amd64|; s|^URIs: http://security.ubuntu.com/ubuntu/|URIs: http://security.ubuntu.com/ubuntu/\nArchitectures: amd64|' /etc/apt/sources.list.d/ubuntu.sources && \
    printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports/\nSuites: noble noble-updates noble-security\nComponents: main universe\nArchitectures: armhf\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' > /etc/apt/sources.list.d/ports.sources && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      meson ninja-build pkg-config gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf python3 flex bison glib2.0-dev-bin \
      libgstreamer1.0-dev:armhf libgstreamer-plugins-base1.0-dev:armhf libgudev-1.0-dev:armhf libglib2.0-dev:armhf \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

# gst-plugins-bad from the GStreamer monorepo at the MR head we patched
if [ ! -f bad-mr5676.tar.gz ]; then
	rm -rf mono && git init -q mono
	git -C mono fetch -q --depth 1 https://gitlab.freedesktop.org/gstreamer/gstreamer.git \
		refs/merge-requests/5676/head
	got=$(git -C mono rev-parse FETCH_HEAD)
	case "$got" in
	"$MR_SHA"*) ;;
	*) echo "MR head is now $got, the patches are for $MR_SHA" >&2
	   echo "(set MR_SHA=$got to try anyway)" >&2; exit 1 ;;
	esac
	git -C mono archive --prefix=gst-plugins-bad-mr5676/ FETCH_HEAD:subprojects/gst-plugins-bad |
		gzip > bad-mr5676.tar.gz
	rm -rf mono
fi
rm -rf "$SRC" build stage
tar -xzf bad-mr5676.tar.gz
for p in "$REPO"/patches/gstreamer/*.patch; do
	patch -d "$SRC" -p1 -s < "$p"
done
cp "$REPO"/patches/gstreamer/armhf.cross .

docker run --rm -u "$(id -u):$(id -g)" -v "$WORK:/w" -w /w/gst-plugins-bad-mr5676 $IMG bash -c '
set -e
meson setup /w/build --cross-file /w/armhf.cross --prefix=/opt/gst-h264enc \
	-Dauto_features=disabled -Dv4l2codecs=enabled >/w/meson-setup.log
ninja -C /w/build >/w/ninja.log
DESTDIR=/w/stage ninja -C /w/build install >/dev/null
'

P=stage/opt/gst-h264enc/lib
rm -rf out && mkdir -p out/lib/gstreamer-1.0
cp -a $P/libgstcodecs-1.0.so* $P/libgstcodecparsers-1.0.so* out/lib/
cp -a $P/gstreamer-1.0/libgstv4l2codecs.so out/lib/gstreamer-1.0/
tar -czf gst-h264enc.tar.gz --owner=0 --group=0 -C out lib
ls -la gst-h264enc.tar.gz
