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

[ -x tools/dtc/dtc ] || { echo "Need patched dtc. Run: ./build-dtc.sh"; exit 1; }

cd "$(dirname "$0")/.."
B=upstream/$BOARD
DTC=tools/dtc/dtc
cpp_dts() { cc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$KERNEL/include" -I "$DTS_DIR" -I "$DTS_DIR/rockchip" "$1" -o "$2"; }

cp stock/$STOCK/board.dtb $B/board.dtb
$DTC -I dtb -O dts -P -n $B/board.dtb 2>/dev/null > $B/board.dts
cp $B/board.dts $B/armbian.dts
patch -s $B/armbian.dts < $B/armbian.patch
$DTC -@ -I dts -O dtb -o $B/armbian.dtb $B/armbian.dts 2>/dev/null

# The overlay ships firmware/<board>/board.dtb, which may deliberately differ from the submission:
# a downstream workaround for a kernel fix that has not merged yet. Never overwrite it silently.
set +x
if cmp -s $B/armbian.dtb firmware/$STOCK/board.dtb; then
	echo "firmware/$STOCK: matches the submission"
elif [ "${SYNC:-0}" = 1 ]; then
	cp $B/armbian.dts firmware/$STOCK/board.dts
	cp $B/armbian.dtb firmware/$STOCK/board.dtb
	echo "firmware/$STOCK: synced from the submission"
else
	echo "firmware/$STOCK: DIFFERS from the submission, left alone (SYNC=1 to overwrite)"
	diff <($DTC -I dtb -O dts -s $B/armbian.dtb 2>/dev/null) \
	     <($DTC -I dtb -O dts -s firmware/$STOCK/board.dtb 2>/dev/null) \
	  | grep -E '^[<>]' | sed 's/^/    /' | head -20 || true
fi
set -x

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

# the submission: header.dts plus overrides against the reference design
printf '/dts-v1/;\n#include "%s"\n#include "%s-linux.dtsi"\n' "$BASE" "$SOC" > /tmp/base.dts
cpp_dts /tmp/base.dts /tmp/base.pp
$DTC -@ -I dts -O dtb -o /tmp/base.dtb /tmp/base.pp 2>/dev/null
$DTC -I dtb -O dts -P -n /tmp/base.dtb 2>/dev/null > /tmp/base.out
$DTC -I dtb -O dts -P -n $B/armbian.dtb 2>/dev/null > /tmp/target.out
{ cat $B/header.dts
  printf '/dts-v1/;\n#include "%s"\n#include "%s-linux.dtsi"\n\n' "$BASE" "$SOC"
  upstream/scripts/gen-overrides.py /tmp/base.out /tmp/target.out; } > $B/armbian-native.dts
cpp_dts $B/armbian-native.dts /tmp/native.pp
$DTC -@ -I dts -O dtb -o $B/armbian-native.dtb /tmp/native.pp 2>/dev/null

# the gate: the include-based tree must describe the same hardware as the patched one
set +x
$DTC -I dtb -O dts -P -n -s $B/armbian.dtb 2>/dev/null > /tmp/gate-patched.dts
$DTC -I dtb -O dts -P -n -s $B/armbian-native.dtb 2>/dev/null > /tmp/gate-native.dts

# a numeric reference is the one difference a diff cannot see, so rule it out first
upstream/scripts/check-refs.py /tmp/gate-patched.dts /tmp/gate-native.dts || exit 1

# every line compared, phandle values translated rather than dropped; -s leaves node order free
upstream/scripts/remap-phandles.py /tmp/gate-patched.dts /tmp/gate-native.dts > /tmp/gate-native-remapped.dts
if diff /tmp/gate-patched.dts /tmp/gate-native-remapped.dts > /tmp/native.diff; then
	echo "VERIFIED: native tree is content-identical to the patched tree"
else
	echo "MISMATCH: $(grep -c '^[<>]' /tmp/native.diff) lines differ - see /tmp/native.diff"
	exit 1
fi
