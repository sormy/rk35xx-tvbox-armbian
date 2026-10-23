#!/bin/bash
# Build tvb-<board>, inside the build container: the board's tree, loader files and package.list.
#   board.sh <board>   -> /out/debs/tvb-<board>_<revision>_arm64.deb
set -euo pipefail
BOARD=$1
FW=/repo/boards
# shellcheck source=/dev/null
. "$FW/$BOARD/board.conf"
: "${BOARD_FAMILY:?boards/$BOARD/board.conf names no BOARD_FAMILY}" "${BOARD_NAME:?boards/$BOARD/board.conf names no BOARD_NAME}"
[ "${BOARD_ID:-}" = "$BOARD" ] || { echo "boards/$BOARD/board.conf: BOARD_ID=${BOARD_ID:-} is not its directory" >&2; exit 1; }
# Rockchip's defaults: the vendor's ttyFIQ0 console, and CMA for a 4K frame (the tree has 8 MiB)
if [ "$BOARD_FAMILY" = rk35xx ]; then
  : "${BOARD_SERIALCON:=earlycon=uart8250,mmio32,0xff9f0000 console=ttyFIQ0}" "${BOARD_CMA:=256M}"
fi
VERSION=${TVB_BUILD_REVISION:-0~local}
ROOT=/work/package/$BOARD
LIB=$ROOT/usr/lib/tvb
rm -rf "$ROOT" && mkdir -p "$ROOT/DEBIAN" "$LIB"

dtc -q -@ -I dts -O dtb -o "$LIB/board.dtb" "$FW/$BOARD/board.dts"
echo "$BOARD_ID" >"$LIB/board-id"
echo "$BOARD_NAME" >"$LIB/board-name"
[ -z "${BOARD_PCB:-}" ] || echo "$BOARD_PCB" >"$LIB/board-pcb"

# loader files only: nothing in this package writes a sector
[ -z "${BOARD_UBOOT:-}" ] || cp "/out/uboot/$BOARD/u-boot.bin" "$LIB/u-boot.bin"
[ ! -f "$FW/$BOARD/factory_idbloader.bin" ] || cp "$FW/$BOARD/factory_idbloader.bin" "$LIB/idbloader.bin"
# tvb-install, on a board that names the sectors a copy leaves as they are: the unit's own
if [ -f "$FW/$BOARD/preserve-sectors" ]; then
  install -D -m 0755 "$FW/common/tvb-install" "$ROOT/usr/sbin/tvb-install"
  cp "$FW/$BOARD/preserve-sectors" "$LIB/preserve-sectors"
fi

while read -r mode src dest; do
  case "$mode" in
    '' | \#*) ;;
    link) mkdir -p "$(dirname "$ROOT$dest")" && ln -s "$src" "$ROOT$dest" ;;
    *) install -D -m "$mode" "$FW/$src" "$ROOT$dest" ;;
  esac
done <"$FW/$BOARD/package.list"

mkdir -p "$ROOT/usr/share/u-boot-menu/conf.d"
# ro: systemd-fsck-root checks the rootfs; net.ifnames=0: eth0 and wlan0, as on Armbian
cmdline="rootwait ro ${BOARD_SERIALCON:-} console=tty1 consoleblank=0 net.ifnames=0"
# the board's firmware ahead of every package's
cmdline="$cmdline firmware_class.path=/usr/lib/tvb/firmware"
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
Depends: linux-image-tvb-$BOARD_KERNEL, u-boot-menu${BOARD_DEPENDS:+, ${BOARD_DEPENDS// /, }}
Provides: tvb-board
Conflicts: tvb-board
Section: admin
Priority: optional
X-Tvb-Inputs: $(bash /repo/release/inputs.sh board "$BOARD")
Description: TVBian board support for the $BOARD_NAME
 The board's device tree, its firmware and settings, and its loader files.
CONTROL
dpkg-deb --root-owner-group -Zxz -b "$ROOT" "/out/debs/tvb-${BOARD}_${VERSION}_arm64.deb" >/dev/null
echo "✓ tvb-${BOARD}_${VERSION}_arm64.deb"
