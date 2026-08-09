#!/bin/sh
# Fetch the pinned Seekwave SWT6621S driver tree (Wi-Fi + BT, GPLv2) and stage it into the given
# dir as the DKMS source. Used by build-image.sh (staged into the image) and h96-update (straight
# into /usr/src on the live box). Needs network + curl + tar.
#   usage: fetch-seekwave-src.sh <src-dir>
set -e
DIR="${1:?usage: fetch-seekwave-src.sh <src-dir>}"

# pinned commit of https://github.com/retro98boy/seekwave-swt6621s (kickpi-k3b-sdio-uart branch)
SHA=b1b15016119cb21965fc64dd374e42f46f011bb4

mkdir -p "$DIR"
curl -fsSL "https://codeload.github.com/retro98boy/seekwave-swt6621s/tar.gz/$SHA" \
  | tar -xz -C "$DIR" --strip-components=1
# the repo's own dkms.conf drives the build (package seekwave-swt6621s/1.0.0: skw_sdio_lite,
# swt6621s_wifi, skwbt); firmware ships separately from firmware/h96max/seekwave-fw/
