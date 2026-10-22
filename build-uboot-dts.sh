#!/usr/bin/env bash
# Regenerate firmware/<board>/uboot.dts from that board's factory U-Boot DTB.
#
# Two stages, so each is auditable on its own:
#   1. mechanical — decompile the blob, then renumber every CRU clock/reset specifier from the
#      vendor's numbering to mainline's. The blob records only integers and no decompiler can
#      recover which symbol produced one, so the vendor header is the dictionary that names it and
#      mainline's header supplies the new value. Nothing that fails to map exactly is touched.
#   2. judgement — apply firmware/<board>/uboot.patch, which says what we change and why.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/firmware"
# any vendor kernel since 2023-02 numbers the RK3528's clocks the same; pinned to stay reproducible
VENDOR_REV=5280f9b4336199c4025c8eed894d2b4e2268dcc6
VHDR="${VHDR:-$REPO/uboot-build/vendor/rk3528-cru.h}"
MDIR="${MDIR:-$REPO/uboot-build/u-boot/dts/upstream/include/dt-bindings}"

# return 0: the last glob entry need not exist, and set -e would take that test as failure
boards() { for d in "$FW"/*/uboot.patch; do [ -f "$d" ] && basename "$(dirname "$d")"; done; return 0; }
BOARDS="${*:-$(boards)}"
[ -n "$BOARDS" ] || { echo "no firmware/<board>/uboot.patch found — name a board"; exit 1; }

[ -x "$REPO/tools/dtc/dtc" ] || { echo "Need the patched dtc. Run: ./build-dtc.sh"; exit 1; }
if [ ! -f "$VHDR" ]; then
  mkdir -p "$(dirname "$VHDR")"
  curl -fsSL -o "$VHDR.tmp" \
    "https://raw.githubusercontent.com/armbian/linux-rockchip/$VENDOR_REV/include/dt-bindings/clock/rk3528-cru.h"
  mv "$VHDR.tmp" "$VHDR"
fi
for h in clock/rockchip,rk3528-cru.h reset/rockchip,rk3528-cru.h; do
  [ -f "$MDIR/$h" ] || { echo "Need mainline's dt-bindings ($h). Run: ./build-uboot.sh"; exit 1; }
done

for BOARD in $BOARDS; do
  BLOB="$REPO/stock/$BOARD/uboot.dtb"
  PATCHF="$FW/$BOARD/uboot.patch"
  [ -f "$BLOB" ]   || { echo "Missing $BLOB"; exit 1; }
  [ -f "$PATCHF" ] || { echo "Missing $PATCHF"; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  "$REPO/tools/dtc/dtc" -P -I dtb -O dts -o "$tmp/raw.dts" "$BLOB" 2>/dev/null
  # the factory blob must survive the round trip untouched, or the base is not the board's own
  "$REPO/tools/dtc/dtc" -I dts -O dtb -o "$tmp/rt.dtb" "$tmp/raw.dts" 2>/dev/null
  cmp -s "$tmp/rt.dtb" "$BLOB" || { echo "$BOARD: decompile does not round-trip — refusing"; exit 1; }

  # one sed, quitting at the first hit: piping into `head` can SIGPIPE the writer, which
  # pipefail turns into a silent abort of the whole regeneration
  CRU_PH=$(sed -n '/clock-controller@ff4a0000 {/,/};/{ s/.*phandle = <\(0x[0-9a-f]*\)>.*/\1/p; }' "$tmp/raw.dts" | sed -n '1p')
  VHDR="$VHDR" MDIR="$MDIR" CRU_PH="$CRU_PH" BOARD="$BOARD" \
    python3 "$REPO/scripts/uboot-renumber.py" "$tmp/raw.dts" > "$tmp/xlat.dts"

  # -F0: a hunk that only applies with fuzz has landed on the wrong node, and the result still
  # compiles — refuse it rather than ship a mis-grafted control tree
  ( cd "$tmp" && patch -F0 -p0 --no-backup-if-mismatch -o "$tmp/out.dts" xlat.dts < "$PATCHF" )
  "$REPO/tools/dtc/dtc" -I dts -O dtb -o /dev/null "$tmp/out.dts" 2>/dev/null \
    || { echo "$BOARD: result does not compile"; exit 1; }
  cp "$tmp/out.dts" "$FW/$BOARD/uboot.dts"
  echo "-> firmware/$BOARD/uboot.dts"
  rm -rf "$tmp"; trap - EXIT
done
