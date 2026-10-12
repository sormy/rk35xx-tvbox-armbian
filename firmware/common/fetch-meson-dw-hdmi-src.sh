#!/usr/bin/env bash
# Stage mainline's meson-dw-hdmi as DKMS source, patched for the GXLX2 (S905L3).
#   usage: fetch-meson-dw-hdmi-src.sh <src-dir> [kernel-version]
set -e
DIR="${1:?usage: fetch-meson-dw-hdmi-src.sh <src-dir> [kernel-version]}"
KVER="${2:-6.18.44}"   # must match the base image's kernel: the driver reads meson-drm's structs

PATCHES="$(cd "$(dirname "$0")/../../patches/meson-dw-hdmi" && pwd)"
SUB="drivers/gpu/drm/meson"

NEW="$DIR.new"
trap 'rm -rf "$NEW"' EXIT
rm -rf "$NEW"; mkdir -p "$NEW"
# the same tarball fetch-mt76-src.sh keeps
CACHE="$(cd "$(dirname "$0")/../.." && pwd)/build/kernel-tarballs"
mkdir -p "$CACHE"
TAR="$CACHE/linux-$KVER.tar.xz"
if [ ! -s "$TAR" ]; then
  curl -fsSL -o "$TAR.part" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
  mv -f "$TAR.part" "$TAR"
fi
tar -xJf "$TAR" -C "$NEW" --strip-components=5 \
  "linux-$KVER/$SUB/meson_dw_hdmi.c" "linux-$KVER/$SUB/meson_dw_hdmi.h" \
  "linux-$KVER/$SUB/meson_drv.h" "linux-$KVER/$SUB/meson_registers.h"

for p in "$PATCHES"/*.patch; do
  patch -p5 -d "$NEW" < "$p"
done

# its own name: the kernel's meson_dw_hdmi is built in
printf 'obj-m += meson_dw_hdmi_gxlx2.o\nmeson_dw_hdmi_gxlx2-y := meson_dw_hdmi.o\n' > "$NEW/Makefile"
cat > "$NEW/dkms.conf" <<'EOF'
PACKAGE_NAME="meson-dw-hdmi-gxlx2"
PACKAGE_VERSION="1.0.0"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="meson_dw_hdmi_gxlx2"
DEST_MODULE_LOCATION[0]="/kernel/drivers/gpu/drm/meson"
AUTOINSTALL="yes"
EOF

rm -rf "$DIR"; mv "$NEW" "$DIR"
trap - EXIT
