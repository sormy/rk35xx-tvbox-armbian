#!/usr/bin/env bash
# Regenerate firmware/<board>/board.dts and board.dtb from that board's factory kernel DTB.
#
# Two stages, so each is auditable on its own:
#   1. mechanical — decompile the factory blob. It does not round-trip byte for byte: dtc re-packs
#      the string table and writes path references where the vendor wrote phandles. The content is
#      what matters, and the patch's own -F0 gate catches a base that has moved.
#   2. judgement — apply firmware/<board>/board.patch, which says what we change and why.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/firmware"
DTC="$REPO/build/tools/dtc/dtc"

# return 0: the last glob entry need not exist, and set -e would take that test as failure
boards() { for d in "$FW"/*/board.patch; do [ -f "$d" ] && basename "$(dirname "$d")"; done; return 0; }
BOARDS="${*:-$(boards)}"
[ -n "$BOARDS" ] || { echo "no firmware/<board>/board.patch found — name a board"; exit 1; }

[ -x "$DTC" ] || { echo "Need the patched dtc. Run: ./build.sh tool dtc"; exit 1; }

for BOARD in $BOARDS; do
	BLOB="$REPO/stock/$BOARD/board.dtb"
	PATCHF="$FW/$BOARD/board.patch"
	[ -f "$BLOB" ]   || { echo "Missing $BLOB"; exit 1; }
	[ -f "$PATCHF" ] || { echo "Missing $PATCHF"; exit 1; }
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

	"$DTC" -I dtb -O dts -P -n "$BLOB" 2>/dev/null > "$tmp/base.dts"

	# -F0: a hunk that only applies with fuzz has landed on the wrong node, and the result still
	# compiles — refuse it rather than ship a mis-grafted tree
	( cd "$tmp" && patch -F0 -p0 --no-backup-if-mismatch -o "$tmp/out.dts" base.dts < "$PATCHF" >/dev/null )
	"$DTC" -@ -I dts -O dtb -o "$tmp/out.dtb" "$tmp/out.dts" 2>/dev/null \
		|| { echo "$BOARD: result does not compile"; exit 1; }

	cp "$tmp/out.dts" "$FW/$BOARD/board.dts"
	cp "$tmp/out.dtb" "$FW/$BOARD/board.dtb"
	echo "-> firmware/$BOARD/board.dts + board.dtb"
	rm -rf "$tmp"; trap - EXIT
done
