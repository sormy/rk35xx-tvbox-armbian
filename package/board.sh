#!/bin/bash
# Build tvb-<board>, inside the build container: the board's tree, loader files and package.list.
#   board.sh <board>   -> /out/debs/tvb-<board>_<revision>_arm64.deb
set -euo pipefail
BOARD=$1
FW=/repo/firmware
# shellcheck source=/dev/null
. "$FW/$BOARD/board.conf"
: "${BOARD_FAMILY:?firmware/$BOARD/board.conf names no BOARD_FAMILY}"
# Rockchip's defaults: the vendor's ttyFIQ0 console, and CMA for a 4K frame (the tree has 8 MiB)
if [ "$BOARD_FAMILY" = rk35xx ]; then
  : "${BOARD_SERIALCON:=earlycon=uart8250,mmio32,0xff9f0000 console=ttyFIQ0}" "${BOARD_CMA:=256M}"
fi
VERSION=${TVB_BUILD_REVISION:-0~local}
ROOT=/work/package/$BOARD
LIB=$ROOT/usr/lib/tvb
rm -rf "$ROOT" && mkdir -p "$ROOT/DEBIAN" "$LIB"

# the tree: board.dts, plus the patch that brings it to TVBian's kernel where one exists
cp "$FW/$BOARD/board.dts" "$ROOT/board.dts"
[ ! -f "$FW/$BOARD/board.tvbian.patch" ] ||
  patch -s -F0 -p0 -d "$ROOT" <"$FW/$BOARD/board.tvbian.patch"
dtc -q -@ -I dts -O dtb -o "$LIB/board.dtb" "$ROOT/board.dts"
rm "$ROOT/board.dts"
cp "$FW/$BOARD/board-name" "$LIB/board-name"

# loader files only: nothing in this package writes a sector
if [ -n "${BOARD_UBOOT_BUILD:-}" ]; then
  cp "/out/uboot/$BOARD_UBOOT_BUILD/u-boot.bin" "$LIB/u-boot.bin"
elif [ -n "${BOARD_UBOOT:-}" ]; then
  cp "$FW/$BOARD_UBOOT" "$LIB/u-boot.bin"
fi
[ -z "${BOARD_IDBLOADER:-}" ] || cp "$FW/$BOARD_IDBLOADER" "$LIB/idbloader.bin"

while read -r mode src dest; do
  case "$mode" in
    '' | \#*) ;;
    link) mkdir -p "$(dirname "$ROOT$dest")" && ln -s "$src" "$ROOT$dest" ;;
    *) install -D -m "$mode" "$FW/$src" "$ROOT$dest" ;;
  esac
done <"$FW/$BOARD/package.list"

mkdir -p "$ROOT/usr/share/u-boot-menu/conf.d"
# ro: systemd-fsck-root checks the rootfs; net.ifnames=0: eth0 and wlan0, as on Armbian
cmdline="rootwait ro ${BOARD_SERIALCON:-} console=tty1 consoleblank=0 net.ifnames=0 ${BOARD_IR_BLACKLIST:-}"
[ -z "${BOARD_CMA:-}" ] || cmdline="$cmdline cma=$BOARD_CMA"
cat >"$ROOT/usr/share/u-boot-menu/conf.d/tvb.conf" <<CONF
U_BOOT_FDT=/usr/lib/tvb/board.dtb
U_BOOT_TIMEOUT=10
U_BOOT_PARAMETERS="$(echo "$cmdline" | tr -s ' ' | sed 's/ $//')"
CONF

cat >"$ROOT/DEBIAN/postinst" <<'SCRIPT'
#!/bin/sh
set -e
# extlinux.conf names the tree, which the kernel's own hook cannot see before this package exists
[ "$1" != configure ] || [ ! -x /usr/sbin/u-boot-update ] || u-boot-update
# the units this package enables by its .wants links: a running box sees them now
[ ! -d /run/systemd/system ] || systemctl daemon-reload
SCRIPT
chmod 0755 "$ROOT/DEBIAN/postinst"

cat >"$ROOT/DEBIAN/control" <<CONTROL
Package: tvb-$BOARD
Version: $VERSION
Architecture: arm64
Maintainer: TVBian <archive@tvbian.com>
Depends: linux-image-tvb-$BOARD_KERNEL, u-boot-menu${BOARD_DEPENDS:+, $BOARD_DEPENDS}
Provides: tvb-board
Conflicts: tvb-board
Section: admin
Priority: optional
X-Tvb-Inputs: $(bash /repo/release/inputs.sh board "$BOARD")
Description: TVBian board support for the $(cat "$FW/$BOARD/board-name")
 The board's device tree, its firmware and settings, and its loader files.
CONTROL
dpkg-deb --root-owner-group -Zxz -b "$ROOT" "/out/debs/tvb-${BOARD}_${VERSION}_arm64.deb" >/dev/null
echo "✓ tvb-${BOARD}_${VERSION}_arm64.deb"
