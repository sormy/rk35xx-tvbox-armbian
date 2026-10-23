#!/usr/bin/env bash
# Regenerate everything derived under boards/<board>/ — board tree, U-Boot tree, maskrom
# loader — for the boards named, or for every board when none is.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

boards() { for c in boards/*/board.conf; do basename "$(dirname "$c")"; done; return 0; }
BOARDS="${*:-$(boards)}"

# Each generator owns a different subset — a board carrying no uboot.patch has no U-Boot tree to
# rebuild. Select here rather than let a generator refuse a board and take the whole run with it.
with() { for b in $BOARDS; do [ -e "boards/$b/$1" ] && printf '%s ' "$b"; done; return 0; }

sel=$(with board.patch)                      # stock board.dtb + board.patch -> board.dts + board.dtb
[ -z "$sel" ] || ./build-board-dts.sh $sel

sel=$(with uboot.patch)                      # stock uboot.dtb + uboot.patch -> uboot.dts
[ -z "$sel" ] || ./build-uboot-dts.sh $sel

sel=$(with factory_idbloader.bin)            # factory idbloader + rkbin usbplug -> maskrom_loader.bin
[ -z "$sel" ] || ./build-rockchip-loaders.sh $sel
