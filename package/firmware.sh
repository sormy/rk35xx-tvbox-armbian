#!/bin/bash
# Build tvb-firmware-<chip>, inside the build container: one chip's blobs, shared by its boards.
#   firmware.sh <dir>   firmware/<dir>/ holds firmware.conf and package.list
set -euo pipefail
FW=/repo/firmware
DIR=$FW/$1
# shellcheck source=/dev/null  # FIRMWARE_CHIP, FIRMWARE_NAME
. "$DIR/firmware.conf"
VERSION=${TVB_BUILD_REVISION:-0~local}
ROOT=/work/package/firmware-$FIRMWARE_CHIP
rm -rf "$ROOT" && mkdir -p "$ROOT/DEBIAN"
bash /repo/package/install-list.sh "$DIR/package.list" "$FW" "$ROOT"
cat >"$ROOT/DEBIAN/control" <<CONTROL
Package: tvb-firmware-$FIRMWARE_CHIP
Version: $VERSION
Architecture: all
Maintainer: TVBian <archive@tvbian.com>
Section: non-free-firmware/kernel
Priority: optional
X-Tvb-Inputs: $(bash /repo/release/inputs.sh firmware "$1")
Description: $FIRMWARE_NAME firmware for TVBian
 The chip's code and settings every board carrying it loads alike.
CONTROL
dpkg-deb --root-owner-group -Zxz -b "$ROOT" "/out/debs/tvb-firmware-${FIRMWARE_CHIP}_${VERSION}_all.deb" >/dev/null
echo "✓ tvb-firmware-${FIRMWARE_CHIP}_${VERSION}_all.deb"
