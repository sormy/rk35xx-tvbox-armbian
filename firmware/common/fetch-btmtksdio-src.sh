#!/usr/bin/env bash
# Stage mainline's btmtksdio as DKMS source, patched for the MT7668S.
#   usage: fetch-btmtksdio-src.sh <src-dir> [kernel-version]
set -e
DIR="${1:?usage: fetch-btmtksdio-src.sh <src-dir> [kernel-version]}"
KVER="${2:-6.18.44}"   # must match the base image's kernel: the driver tracks btmtk's exports

PATCHES="$(cd "$(dirname "$0")/../../patches/btmtksdio-mt7668" && pwd)"
SUB="drivers/bluetooth"

NEW="$DIR.new"
trap 'rm -rf "$NEW"' EXIT
rm -rf "$NEW"; mkdir -p "$NEW"
# the same tarball fetch-mt76-src.sh keeps
CACHE="$(cd "$(dirname "$0")/../.." && pwd)/build/kernel-tarballs"
mkdir -p "$CACHE"
TAR="$CACHE/linux-$KVER.tar.xz"
if [ ! -s "$TAR" ]; then
  curl -fsSL -o "$TAR.part" "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
  mv -f "$TAR.part" "$TAR"
fi
tar -xJf "$TAR" -C "$NEW" --strip-components=3 \
  "linux-$KVER/$SUB/btmtksdio.c" "linux-$KVER/$SUB/btmtk.h" "linux-$KVER/$SUB/hci_uart.h"

for p in "$PATCHES"/*.patch; do
  patch -p3 -d "$NEW" < "$p"
done

echo 'obj-m += btmtksdio.o' > "$NEW/Makefile"
cat > "$NEW/dkms.conf" <<'EOF'
PACKAGE_NAME="btmtksdio-mt7668"
PACKAGE_VERSION="1.0.0"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="btmtksdio"
DEST_MODULE_LOCATION[0]="/kernel/drivers/bluetooth"
AUTOINSTALL="yes"
EOF

rm -rf "$DIR"; mv "$NEW" "$DIR"
trap - EXIT
