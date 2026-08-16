#!/usr/bin/env bash
# Regenerate a board's submission set from its factory blob and patch. See README.md.
#
# The include-based extras need the kernel's dt-bindings and the reference board dtsi. Pinned to
# the commit our work branches from, fetched sparsely (50M of a 1.8G tree). Set KERNEL to reuse a
# checkout you already have.
BOARD=${BOARD:-r69-xr821}
STOCK=${STOCK:-r69}				# the factory blob is stock/$STOCK/board.dtb
SOC=${SOC:-rk3528}
BASE=${BASE:-rk3528-evb1-ddr4-v10.dtsi}		# the reference design this box derives from
KERNEL_URL=${KERNEL_URL:-https://github.com/armbian/linux-rockchip.git}
KERNEL_REV=${KERNEL_REV:-5280f9b4336199c4025c8eed894d2b4e2268dcc6}
KERNEL=${KERNEL:-$(cd "$(dirname "$0")" && pwd)/.kernel}
BINDINGS=${BINDINGS:-$KERNEL/include/dt-bindings}
DTS_DIR=${DTS_DIR:-$KERNEL/arch/arm64/boot/dts}

set -ex

cd "$(dirname "$0")/.."
B=upstream/$BOARD
DTC=dtcx/dtcx
cpp_dts() { cc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$KERNEL/include" -I "$DTS_DIR" -I "$DTS_DIR/rockchip" "$1" -o "$2"; }

cp stock/$STOCK/board.dtb $B/board.dtb
$DTC -I dtb -O dts -P -n $B/board.dtb 2>/dev/null > $B/board.dts
cp $B/board.dts $B/armbian.dts
patch -s $B/armbian.dts < $B/armbian.patch
$DTC -@ -I dts -O dtb -o $B/armbian.dtb $B/armbian.dts 2>/dev/null

if [ ! -d "$BINDINGS" ]; then
	git init -q "$KERNEL"
	git -C "$KERNEL" remote add origin "$KERNEL_URL" 2>/dev/null || true
	git -C "$KERNEL" fetch -q --depth 1 --filter=blob:none origin "$KERNEL_REV"
	git -C "$KERNEL" sparse-checkout init --cone
	git -C "$KERNEL" sparse-checkout set include/dt-bindings arch/arm64/boot/dts
	git -C "$KERNEL" checkout -q FETCH_HEAD
fi

# dt-bindings names instead of hex; same tree, just legible
upstream/scripts/dts-consts.py $B/armbian.dts "$BINDINGS" "$SOC" > $B/armbian-consts.dts

# the same board as an include of the reference design, with the overrides generated from the diff
printf '/dts-v1/;\n#include "%s"\n#include "%s-linux.dtsi"\n' "$BASE" "$SOC" > /tmp/base.dts
cpp_dts /tmp/base.dts /tmp/base.pp
$DTC -@ -I dts -O dtb -o /tmp/base.dtb /tmp/base.pp 2>/dev/null
$DTC -I dtb -O dts -P -n /tmp/base.dtb 2>/dev/null > /tmp/base.out
$DTC -I dtb -O dts -P -n $B/armbian.dtb 2>/dev/null > /tmp/target.out
{ printf '/dts-v1/;\n#include "%s"\n#include "%s-linux.dtsi"\n\n' "$BASE" "$SOC"
  upstream/scripts/gen-overrides.py /tmp/base.out /tmp/target.out; } > $B/armbian-native.dts
cpp_dts $B/armbian-native-annotated.dts /tmp/native.pp
$DTC -@ -I dts -O dtb -o $B/armbian-native.dtb /tmp/native.pp 2>/dev/null

# the gate: the hand-maintained include-based tree must describe the same hardware as the patched
# one. armbian-native.dts above is the machine-generated reference - diff it against the annotated
# file to see what a patch change means for the submission.
# phandle values are allocated per compile and carry no meaning, so ignore them.
set +x
strip() { $DTC -I dtb -O dts -P -n -s "$1" 2>/dev/null | grep -v 'phandle = <'; }
if diff <(strip $B/armbian.dtb) <(strip $B/armbian-native.dtb) > /tmp/native.diff; then
	echo "VERIFIED: native tree is content-identical to the patched tree"
else
	echo "MISMATCH: $(grep -c '^[<>]' /tmp/native.diff) lines differ - see /tmp/native.diff"
	exit 1
fi
