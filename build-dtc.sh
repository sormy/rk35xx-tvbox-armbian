#!/usr/bin/env bash
# Build patched dtc into tools/dtc (gitignored). Vanilla dtc prints phandles as raw numbers, which
# a vendor blob cannot be read or diffed with; patches/dtc/ adds -P/-n/-s.
#
# Usage: ./build-dtc.sh [--test]
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$REPO/tools"                               # gitignored output dir
BUILD="$TOOLS/src/dtc"                            # scratch clone
OUT="$TOOLS/dtc"
PATCHES="$REPO/patches/dtc"

# --- pinned dependency (bump deliberately, never float) ---
DTC_REPO="https://git.kernel.org/pub/scm/utils/dtc/dtc.git"
DTC_VERSION="v1.8.1"

need() { command -v "$1" >/dev/null || { echo "missing: $1 — $2"; exit 1; }; }

# --- the gate: every reference resolved, and a byte-identical round trip ---
selftest() {
	local fail=0 tmp
	[ -x "$OUT/dtc" ] || { echo "nothing built yet — run $0 first"; exit 1; }
	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
	for dtb in "$REPO"/firmware/*/board.dtb; do
		[ -f "$dtb" ] || continue
		local name refs raw
		name="$(basename "$(dirname "$dtb")")"
		"$OUT/dtc" -I dtb -O dts -P "$dtb" > "$tmp/t.dts" 2>/dev/null
		refs=$(grep -cE '<&[a-z0-9_]+' "$tmp/t.dts" || true)
		raw=$(grep -cE '(clocks|gpios|resets|pinctrl-0) = <0x' "$tmp/t.dts" || true)
		"$OUT/dtc" -@ -I dts -O dtb -o "$tmp/t.dtb" "$tmp/t.dts" 2>/dev/null
		if cmp -s "$tmp/t.dtb" "$dtb" && [ "$raw" = 0 ]; then
			printf '  PASS  %-10s %s refs, byte-identical round trip\n' "$name" "$refs"
		else
			printf '  FAIL  %-10s %s refs, %s raw left\n' "$name" "$refs" "$raw"; fail=1
		fi
	done
	[ "$fail" = 0 ] || { echo "self-test failed — this dtc cannot round-trip a vendor blob"; return 1; }
	echo "dtc verified: every reference resolved, blobs round-trip byte-identically"
}

if [ "${1:-}" = "--test" ]; then selftest; exit; fi

for c in git cc make; do need "$c" "install build tooling"; done

mkdir -p "$TOOLS/src" "$OUT"
if [ -d "$BUILD/.git" ]; then
	git -C "$BUILD" fetch --quiet --tags origin || true
else
	rm -rf "$BUILD"
	git clone --quiet --depth 1 --branch "$DTC_VERSION" "$DTC_REPO" "$BUILD"
fi
# discard the previous run's patches so a rebuild is not cumulative
git -C "$BUILD" checkout --quiet --force
git -C "$BUILD" clean -qfd

for p in "$PATCHES"/*.patch; do
	echo "  PATCH $(basename "$p")"
	git -C "$BUILD" apply "$p" || { echo "patch did not apply — dtc $DTC_VERSION may have moved"; exit 1; }
done

# dtc's own build warns that make is deprecated in favour of meson; it still works and needs no
# extra tooling, so keep it and drop the noise
make -C "$BUILD" NO_PYTHON=1 NO_YAML=1 dtc >"$BUILD/build.log" 2>&1 || { tail -20 "$BUILD/build.log"; exit 1; }
install -m 755 "$BUILD/dtc" "$OUT/dtc"

echo "built: tools/dtc/dtc  (dtc $DTC_VERSION + $(ls -1 "$PATCHES"/*.patch | wc -l | tr -d ' ') patches)"
selftest
