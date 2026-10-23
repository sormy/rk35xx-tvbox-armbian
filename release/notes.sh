#!/bin/bash
# The release page, inside the build container, once the images exist: one row a box, with what its
# image carries beyond the base every image shares.
#   notes.sh -> /out/release/notes.md
set -euo pipefail
cd /repo
REL=/out/release
# origin <kernel>: mainline when it is kernel.org's, vendor otherwise
# shellcheck source=/dev/null
origin() { (. "kernel/$1.conf"; case $REPO in *kernel.org*) echo mainline ;; *) echo vendor ;; esac); }
# vendor <family>: the SoC maker a BOARD_FAMILY belongs to
vendor() { case $1 in rk*) echo Rockchip ;; meson*) echo Amlogic ;; sun*) echo Allwinner ;; *) echo "$1" ;; esac; }
version() { awk -v c="kernel/$1.conf" '$1 == "kernel" && $2 == c { sub(/-[0-9]+$/, "", $3); print $3 }' "$REL/plan"; }

{
  echo "Weekly release of TVBian."
  echo
  echo "| Box | Silkscreen | Family | Base | Kernel | Opt-in next | Extras | Image |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
  for img in /out/images/*.img.xz; do
    board=$(basename "$img" | sed -E 's/^tvbian-(.*)-[a-z]+-[0-9]{4}-[0-9]{2}-[0-9]{2}\.img\.xz$/\1/')
    unset "${!BOARD_@}"   # a key one board leaves out must not carry over from the last
    # shellcheck source=/dev/null
    . "boards/$board/board.conf"
    next=$(version "$BOARD_KERNEL-next")
    # the board's own chips, firmware and driver both; the SoC's, named after its maker, go unsaid
    soc=$(vendor "$BOARD_FAMILY")
    extras=$(tr ' ' '\n' <<<"$BOARD_DEPENDS" | sed -n 's/^tvb-firmware-//p' | grep -vix "$soc" |
      tr '[:lower:]' '[:upper:]' | paste -sd, | sed 's/,/, /g')
    echo "| $BOARD_NAME | ${BOARD_PCB:--} | $(vendor "$BOARD_FAMILY") ($BOARD_KERNEL) | Debian ${TVB_BUILD_SUITE:?} | $(version "$BOARD_KERNEL"), $(origin "$BOARD_KERNEL") | ${next:+$next, $(origin "$BOARD_KERNEL-next")} | $extras | \`$(basename "$img")\` |"
  done
  echo
  next=$(for k in kernel/*-next.conf; do basename "$k" -next.conf; done | paste -sd'|')
  echo "Next kernel: \`sudo apt install linux-image-tvb-<$next>-next\`"
} >"$REL/notes.md"
echo "✓ release notes"
