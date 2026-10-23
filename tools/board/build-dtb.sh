#!/usr/bin/env bash
# Regenerate a board's tree from its factory DTB: kernel -> factory_board.dts, board.dts and
# board.dtb; uboot -> factory_uboot.dts and uboot.dts.
#
# Two stages, so each is auditable on its own:
#   1. mechanical — dtcx decompiles the blob as its vendor wrote it, named from the headers of
#      BOARD_<KIND>_DTB_SOURCE, and refuses a tree that does not decompile back to the blob's own.
#   2. judgement — apply the patch: what we change, and the move onto BOARD_<KIND>_DTB_TARGET,
#      whose headers the result must name and compile against.
#
# Usage: tools/board/build-dtb.sh <kernel|uboot> [board...]   # default: every board with the patch
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BOARDS_DIR="$REPO/boards"
BASES="$REPO/tools/dtcx/bases"
DTC="$REPO/build/bin/dtc"
DTCX="$REPO/tools/dtcx/dtcx.py"

case "${1:-}" in
	kernel) NAME=board; KEY=BOARD_KERNEL; DTCX_FLAGS=-n; DTC_FLAGS=-@ ;;
	# the factory U-Boot blob has no __symbols__ to drop or rebuild
	uboot) NAME=uboot; KEY=BOARD_UBOOT; DTCX_FLAGS=--strict; DTC_FLAGS= ;;
	*) echo "usage: $0 <kernel|uboot> [board...]"; exit 1 ;;
esac
shift

boards() { for c in "$BOARDS_DIR"/*/board.conf; do d=$(dirname "$c"); [ ! -f "$d/$NAME.patch" ] || basename "$d"; done; }
BOARDS="${*:-$(boards)}"
[ -n "$BOARDS" ] || { echo "no boards/<board>/$NAME.patch found — name a board"; exit 1; }
[ -x "$DTC" ] || { echo "Need the patched dtc. Run: ./build.sh tool dtc"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

for BOARD in $BOARDS; do
	DIR="$BOARDS_DIR/$BOARD"
	if [ ! -f "$DIR/factory_$NAME.dtb" ] || [ ! -f "$DIR/$NAME.patch" ]; then
		echo "$BOARD has no factory_$NAME.dtb and $NAME.patch"; exit 1
	fi
	SOURCE=$(sed -n "s/^${KEY}_DTB_SOURCE=//p" "$DIR/board.conf")
	TARGET=$(sed -n "s/^${KEY}_DTB_TARGET=//p" "$DIR/board.conf")
	for base in "$SOURCE" "$TARGET"; do
		[ -f "$BASES/$base.conf" ] ||
			{ echo "boards/$BOARD/board.conf: ${KEY}_DTB_SOURCE/_TARGET names no base in tools/dtcx/bases/: '$base'"; exit 1; }
	done
	TARGET_SOURCE=$(sed -n 's/^source //p' "$BASES/$TARGET.conf")
	TARGET_INCLUDE=$(python3 "$DTCX" --include "$TARGET")

	printf '  %s %s:' "$BOARD" "$NAME" >&2
	python3 "$DTCX" "$DTCX_FLAGS" "$SOURCE" "$DIR/factory_$NAME.dtb" > "$tmp/factory.dts"
	mv "$tmp/factory.dts" "$DIR/factory_$NAME.dts"

	# -F0: a hunk that only applies with fuzz has landed on the wrong node, and the result still
	# compiles — refuse it rather than ship a mis-grafted tree
	patch -s -F0 -p0 --no-backup-if-mismatch -o "$tmp/out.dts" "$DIR/factory_$NAME.dts" < "$DIR/$NAME.patch"
	grep -qF "/* dt-bindings from $TARGET_SOURCE */" "$tmp/out.dts" ||
		{ echo "$BOARD: $NAME.patch names another source than $TARGET's"; exit 1; }
	cc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P -I "$TARGET_INCLUDE" -o "$tmp/out.pp" "$tmp/out.dts"
	# shellcheck disable=SC2086  # DTC_FLAGS is empty or one flag
	"$DTC" -q $DTC_FLAGS -I dts -O dtb -o "$tmp/out.dtb" "$tmp/out.pp" ||
		{ echo "$BOARD: $NAME.dts does not compile against $TARGET"; exit 1; }

	cp "$tmp/out.dts" "$DIR/$NAME.dts"
	# U-Boot's build compiles uboot.dts itself; the kernel's board.dtb is what the package ships
	[ "$NAME" = uboot ] || cp "$tmp/out.dtb" "$DIR/board.dtb"
	echo "-> boards/$BOARD/$NAME.dts"
done
