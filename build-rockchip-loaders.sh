#!/usr/bin/env bash
# Pack each Rockchip board's maskrom USB loader into boards/<board>/maskrom_loader.bin: Rockchip's
# usbplug with that board's own DDR init, carved from its factory idbloader.
#
# Stamped with the time of the commit that last changed the idbloader, so a repack is byte-identical.
#
# Usage: ./build-rockchip-loaders.sh [board...]   # default: every board with a factory_idbloader.bin
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/boards"
RKDEV="$REPO/build/bin/rkdeveloptool"
RKBIN="$REPO/build/rkbin"

# --- pinned dependency (bump deliberately, never float) ---
RKBIN_REPO="https://github.com/rockchip-linux/rkbin.git"
RKBIN_SHA="ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4"
RKBOOT_INI="RKBOOT/RK3528MINIALL.ini"             # declares NEWIDB + RC4_OFF; also names the usbplug and SPL
USBPLUG="bin/rk35/rk3528_usbplug_v1.04.bin"       # presence of this marks rkbin as fetched

boards() { for c in "$FW"/*/board.conf; do d=$(dirname "$c"); [ ! -f "$d/factory_idbloader.bin" ] || basename "$d"; done; }
BOARDS="${*:-$(boards)}"
[ -n "$BOARDS" ] || { echo "no boards/*/factory_idbloader.bin to build a loader from"; exit 1; }
[ -x "$RKDEV" ] || { echo "Need the patched rkdeveloptool. Run: ./build.sh tool rkdeveloptool"; exit 1; }

if [ ! -e "$RKBIN/$USBPLUG" ]; then
	rm -rf "$RKBIN" && mkdir -p "$RKBIN" && ( cd "$RKBIN"
		git init -q
		git fetch -q --depth 1 "$RKBIN_REPO" "$RKBIN_SHA" && git checkout -q FETCH_HEAD )
fi

for BOARD in $BOARDS; do
	IDB="$FW/$BOARD/factory_idbloader.bin"
	OUT="$FW/$BOARD/maskrom_loader.bin"

	# CODE471 is the box's own DDR init, carved from its factory idbloader rather than guessed from
	# rkbin's variants — the IDB entry table at byte 0x78 is u16 start sector + u16 sector count.
	DDR=board_ddr.bin
	SEC=$(od -An -tu2 -j 120 -N 2 "$IDB" | tr -d ' ')
	CNT=$(od -An -tu2 -j 122 -N 2 "$IDB" | tr -d ' ')
	dd if="$IDB" of="$RKBIN/$DDR" bs=512 skip="$SEC" count="$CNT" status=none
	strings "$RKBIN/$DDR" | grep -q "^ddr-v" || { echo "no DDR blob at sector $SEC of $IDB"; exit 1; }

	# Rockchip's own ini with this board's DDR swapped in, so NEWIDB and RC4_OFF come from their file
	# rather than from ours. Paths in it are relative to the rkbin root, so pack from there.
	LOADER="loader-$BOARD.bin"
	sed -e "s|bin/rk35/rk3528_ddr_[^ ]*\.bin|$DDR|g" -e "s|^PATH=.*|PATH=$LOADER|" \
		"$RKBIN/$RKBOOT_INI" > "$RKBIN/config.ini"
	# the last commit that changed its content: a move alone must not restamp the loader
	epoch=$(git -C "$REPO" log -1 --follow --diff-filter=AM --format=%ct -- "$IDB")
	pack_rc=0
	( cd "$RKBIN" && SOURCE_DATE_EPOCH="${epoch:-$(date +%s)}" "$RKDEV" pack > /dev/null ) || pack_rc=1
	[ "$pack_rc" = 0 ] && mv -f "$RKBIN/$LOADER" "$OUT" || true
	rm -f "$RKBIN/$DDR" "$RKBIN/config.ini"   # never leave scratch in the pinned checkout
	[ "$pack_rc" = 0 ] || { echo "pack failed for $BOARD"; exit 1; }

	# "LDR " is new-IDB, RC4 off — the only format this BootROM answers; the old "BOOT" format packs
	# fine and is then ignored in silence
	[ "$(head -c 4 "$OUT")" = "LDR " ] && head -c 64 "$OUT" | strings | grep -q 8253 ||
		{ echo "$BOARD: not an RK3528 new-IDB loader"; exit 1; }
	echo "-> boards/$BOARD/maskrom_loader.bin ($((CNT * 512)) B of DDR init)"
done
