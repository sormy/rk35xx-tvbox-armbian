#!/usr/bin/env bash
# Build the maskrom recovery kit into tools/rktools (gitignored): rkdeveloptool plus one USB loader
# per board, since a loader carries that board's own DDR init.
#
# Usage: ./build-rktools.sh              # rkdeveloptool + one loader per board
#        ./build-rktools.sh --test       # re-check what is already built
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$REPO/tools"                               # gitignored output dir
BUILD="$TOOLS/src/rktools"                        # scratch clone, one per tool
OUT="$TOOLS/rktools"
PATCHES="$REPO/patches/rkdeveloptool"
RKBIN="$REPO/uboot-build/rkbin"                   # shared with build-uboot.sh, gitignored

# --- pinned dependencies (bump deliberately, never float) ---
RKDEV_REPO="https://github.com/rockchip-linux/rkdeveloptool.git"
RKDEV_SHA="304f073752fd25c854e1bcf05d8e7f925b1f4e14"   # master @ 2026-08-14
RKBIN_REPO="https://github.com/rockchip-linux/rkbin.git"
RKBIN_SHA="ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4"
RKBOOT_INI="RKBOOT/RK3528MINIALL.ini"             # declares NEWIDB + RC4_OFF; also names the usbplug and SPL
USBPLUG="bin/rk35/rk3528_usbplug_v1.04.bin"       # presence of this marks rkbin as fetched

# --- the gate. `pack` obfuscates the blobs, so the DDR init cannot be seen in the packed file;
# that it came from this board's idbloader is checked at carve time instead. Here: structure. ---
selftest() {
	local fail=0 n=0 L b
	[ -x "$OUT/rkdeveloptool" ] || { echo "nothing built yet — run $0 first"; exit 1; }
	printf '  rkdeveloptool  %s\n' "$("$OUT/rkdeveloptool" -v 2>/dev/null | head -1)"
	for L in "$OUT"/rk3528_spl_loader-*.bin; do
		[ -s "$L" ] || continue
		n=$((n + 1)); b="$(basename "$L" .bin)"; b="${b#rk3528_spl_loader-}"
		# "LDR " is new-IDB, RC4 off — the only format this BootROM answers; the old "BOOT"
		# format packs fine and is then ignored in silence
		if [ "$(head -c 4 "$L")" = "LDR " ] && head -c 64 "$L" | strings | grep -q 8253; then
			printf '  PASS  %-13s %s bytes, LDR header, RK3528\n' "$b" "$(wc -c < "$L" | tr -d ' ')"
		else
			printf '  FAIL  %-13s not an RK3528 new-IDB loader\n' "$b"; fail=1
		fi
	done
	[ "$n" -gt 0 ] || { echo "  FAIL  no loader in $OUT to verify"; return 1; }
	[ "$fail" = 0 ] || return 1
	echo "rktools verified: $n board loader(s), rkdeveloptool runs"
}

if [ "${1:-}" = "--test" ]; then selftest; exit; fi

BOARDS="$(cd "$REPO/firmware" && ls */factory_idbloader.bin 2>/dev/null | cut -d/ -f1 | tr '\n' ' ')"
[ -n "$BOARDS" ] || { echo "no firmware/*/factory_idbloader.bin to build a loader from"; exit 1; }

need() { command -v "$1" >/dev/null || { echo "missing: $1 — $2"; exit 1; }; }

case "$(uname -s)" in
	Darwin)
		need brew "install Homebrew first"
		for p in autoconf automake libtool pkg-config libusb; do
			brew list --formula "$p" >/dev/null 2>&1 || brew install "$p"
		done
		# Homebrew keeps libusb out of the default search paths
		export PKG_CONFIG_PATH="$(brew --prefix libusb)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
		# upstream builds -Werror and uses C++ VLAs, which clang rejects; allow just that one
		CONFIGURE_ARGS=(CXXFLAGS="-O2 -Wno-error=vla-cxx-extension")
		;;
	Linux)
		for c in autoreconf pkg-config g++; do need "$c" "apt install autoconf automake libtool pkg-config g++ libusb-1.0-0-dev"; done
		pkg-config --exists libusb-1.0 || { echo "missing: libusb-1.0 — apt install libusb-1.0-0-dev"; exit 1; }
		;;
	*) echo "unsupported host: $(uname -s)"; exit 1 ;;
esac

mkdir -p "$TOOLS/src" "$OUT"
if [ -d "$BUILD/.git" ]; then
	git -C "$BUILD" fetch --quiet "$RKDEV_REPO" "$RKDEV_SHA" || true
else
	rm -rf "$BUILD"
	git clone --quiet "$RKDEV_REPO" "$BUILD"
fi
git -C "$BUILD" checkout --quiet --force "$RKDEV_SHA"
git -C "$BUILD" clean -qfd

for p in "$PATCHES"/*.patch; do
	echo "  PATCH $(basename "$p")"
	git -C "$BUILD" apply "$p" || { echo "patch did not apply — rkdeveloptool $RKDEV_SHA may have moved"; exit 1; }
done

cd "$BUILD"
autoreconf -i >/dev/null
./configure "${CONFIGURE_ARGS[@]:-}" >/dev/null
make -j"$(getconf _NPROCESSORS_ONLN)" >/dev/null

install -m 755 "$BUILD/rkdeveloptool" "$OUT/rkdeveloptool"

if [ ! -e "$RKBIN/$USBPLUG" ]; then
	rm -rf "$RKBIN" && mkdir -p "$RKBIN" && ( cd "$RKBIN"
		git init -q
		git fetch -q --depth 1 "$RKBIN_REPO" "$RKBIN_SHA" && git checkout -q FETCH_HEAD )
fi

for BOARD in $BOARDS; do
IDB="$REPO/firmware/$BOARD/factory_idbloader.bin"

# CODE471 is the box's own DDR init, carved from its factory idbloader rather than guessed from
# rkbin's variants — the IDB entry table at byte 0x78 is u16 start sector + u16 sector count.
DDR=board_ddr.bin
SEC=$(od -An -tu2 -j 120 -N 2 "$IDB" | tr -d ' ')
CNT=$(od -An -tu2 -j 122 -N 2 "$IDB" | tr -d ' ')
dd if="$IDB" of="$RKBIN/$DDR" bs=512 skip="$SEC" count="$CNT" status=none
strings "$RKBIN/$DDR" | grep -q "^ddr-v" || { echo "no DDR blob at sector $SEC of $IDB"; exit 1; }

# Rockchip's own ini with this board's DDR swapped in, so NEWIDB and RC4_OFF come from their file
# rather than from ours. Paths in it are relative to the rkbin root, so pack from there.
LOADER="rk3528_spl_loader-$BOARD.bin"
sed -e "s|bin/rk35/rk3528_ddr_[^ ]*\.bin|$DDR|g" -e "s|^PATH=.*|PATH=$LOADER|" \
	"$RKBIN/$RKBOOT_INI" > "$RKBIN/config.ini"
pack_rc=0
( cd "$RKBIN" && "$OUT/rkdeveloptool" pack > /dev/null ) || pack_rc=1
[ "$pack_rc" = 0 ] && mv -f "$RKBIN/$LOADER" "$OUT/$LOADER" || true
rm -f "$RKBIN/$DDR" "$RKBIN/config.ini"   # never leave scratch in the pinned checkout
[ "$pack_rc" = 0 ] || { echo "pack failed for $BOARD"; exit 1; }
echo "  loader $BOARD: $((CNT * 512)) B of DDR init"
done

echo "built: tools/rktools/rkdeveloptool + $(echo $BOARDS | wc -w | tr -d ' ') loaders"
selftest
