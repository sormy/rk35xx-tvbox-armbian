#!/bin/bash
# Build one board's U-Boot, inside the build container, from the uboot/<conf>.conf its board.conf
# names as BOARD_UBOOT: /out/uboot/<board>/u-boot.bin. A board with a firmware/<board>/uboot.dts
# gets it as the control tree, and a conf naming a BL31 gets binman's FIT around the ATF.
set -euo pipefail
BOARD=$1
# shellcheck source=/dev/null
. "/repo/firmware/$BOARD/board.conf"
# shellcheck source=/dev/null  # the conf: REPO, TAG, DEFCONFIG; CONFIGS, PATCHES, SOC, RKBIN...
. "/repo/uboot/${BOARD_UBOOT:?firmware/$BOARD/board.conf names no BOARD_UBOOT}.conf"
TREE=/work/uboot/$BOARD
OUT=/out/uboot/$BOARD
DTS=/repo/firmware/$BOARD/uboot.dts

rm -rf "$TREE" && mkdir -p "$TREE" "$OUT" && cd "$TREE"
git init -q && git fetch -q --depth=1 "$REPO" "refs/tags/$TAG" && git checkout -q FETCH_HEAD
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
export SOURCE_DATE_EPOCH
rm -rf .git   # a git checkout suffixes the version: 2026.10+, or -g<hash>
for p in ${PATCHES:-}; do patch -s -p1 -F0 <"/repo/$p"; done

configs=${CONFIGS:-}
if [ -f "$DTS" ]; then
  DT=$SOC-$BOARD
  cp "$DTS" "arch/arm/dts/$DT.dts"
  # the name upstream's Makefile globs for: binman's nodes, and what the factory tree lacks
  cp "/repo/uboot/$SOC-u-boot.dtsi" "arch/arm/dts/$DT-u-boot.dtsi"
  # the defconfig's own tree renamed throughout, before Kconfig derives OF_LIST and the FDT file from it
  generic=$(sed -n 's/^CONFIG_DEFAULT_DEVICE_TREE="\(.*\)"$/\1/p' "configs/$DEFCONFIG")
  sed "s|$generic|$DT|g" "configs/$DEFCONFIG" >"configs/tvb-${BOARD}_defconfig"
  DEFCONFIG=tvb-${BOARD}_defconfig
  configs="$configs DEFAULT_DEVICE_TREE=\"$DT\""
fi
make -s "$DEFCONFIG"
for c in $configs; do scripts/config --set-val "${c%%=*}" "${c#*=}"; done
make -s olddefconfig
# a symbol Kconfig drops, through a renamed or unmet dependency, would ship a quietly different build
for c in $configs; do
  grep -qx "CONFIG_$c" .config || { echo "✗ $BOARD: CONFIG_$c did not stick" >&2; exit 1; }
done

if [ -n "${BL31:-}" ]; then
  RK=/work/rkbin/$RKBIN_COMMIT
  [ -f "$RK/$BL31" ] || { rm -rf "$RK" && git init -q "$RK" && git -C "$RK" fetch -q --depth=1 "$RKBIN" "$RKBIN_COMMIT" &&
    git -C "$RK" checkout -q FETCH_HEAD; }
  make -s -j"${TVB_BUILD_CPUS:-$(nproc)}" BL31="$RK/$BL31" ROCKCHIP_TPL="$RK/$TPL"
  cp u-boot.itb "$OUT/u-boot.bin"
else
  make -s -j"${TVB_BUILD_CPUS:-$(nproc)}" u-boot.bin
  cp u-boot.bin "$OUT/"
fi
echo "✓ $BOARD: U-Boot $TAG, $(stat -c %s "$OUT/u-boot.bin") bytes"
