#!/usr/bin/env bash
# Regenerate boards/<board>/factory_board.dts, board.dts and board.dtb from factory_board.dtb, the
# board's factory kernel DTB.
#
# Two stages, so each is auditable on its own:
#   1. mechanical — decompile the factory blob to factory_board.dts. It does not round-trip byte for byte: dtc re-packs
#      the string table and writes path references where the vendor wrote phandles. The content is
#      what matters, and the patch's own -F0 gate catches a base that has moved.
#   2. judgement — apply board.patch to factory_board.dts: what we change and why.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/boards"
DTC="$REPO/build/bin/dtc"

boards() { for c in "$FW"/*/board.conf; do d=$(dirname "$c"); [ ! -f "$d/board.patch" ] || basename "$d"; done; }
BOARDS="${*:-$(boards)}"
[ -n "$BOARDS" ] || { echo "no boards/<board>/board.patch found — name a board"; exit 1; }

[ -x "$DTC" ] || { echo "Need the patched dtc. Run: ./build.sh tool dtc"; exit 1; }

for BOARD in $BOARDS; do
	BLOB="$FW/$BOARD/factory_board.dtb"
	FACTORY="$FW/$BOARD/factory_board.dts"
	PATCHF="$FW/$BOARD/board.patch"
	[ -f "$BLOB" ]   || { echo "Missing $BLOB"; exit 1; }
	[ -f "$PATCHF" ] || { echo "Missing $PATCHF"; exit 1; }
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

	"$DTC" -I dtb -O dts -P -n "$BLOB" 2>/dev/null > "$FACTORY"

	# -F0: a hunk that only applies with fuzz has landed on the wrong node, and the result still
	# compiles — refuse it rather than ship a mis-grafted tree
	patch -F0 -p0 --no-backup-if-mismatch -o "$tmp/out.dts" "$FACTORY" < "$PATCHF" >/dev/null
	"$DTC" -@ -I dts -O dtb -o "$tmp/out.dtb" "$tmp/out.dts" 2>/dev/null \
		|| { echo "$BOARD: result does not compile"; exit 1; }

	cp "$tmp/out.dts" "$FW/$BOARD/board.dts"
	cp "$tmp/out.dtb" "$FW/$BOARD/board.dtb"
	echo "-> boards/$BOARD/board.dts + board.dtb"
	rm -rf "$tmp"; trap - EXIT
done
