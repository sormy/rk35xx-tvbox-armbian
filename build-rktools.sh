#!/usr/bin/env bash
# Build the maskrom recovery kit into tools/ (gitignored): rkdeveloptool, plus the USB loader its
# `db` verb needs. Both are required when a box won't boot — hold the AV-jack button at power-on,
# plug USB-A-to-A into a real host port, and the SoC enumerates as 2207:350c. Procedure:
# README.md#recovery.
#
# Usage: ./build-rktools.sh <board>        # r69 | h96max
#
# The loader is the board's own DDR init + Rockchip's usbplug. Only the DDR half exists on the eMMC,
# so a backup alone can never stand in for it.
# Built natively, never in a container: USB devices do not pass through to containers on macOS, so a
# containerised binary could compile but never reach the box.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$REPO/tools"                               # gitignored output dir
BUILD="$TOOLS/src"                                # scratch clone
RKBIN="$REPO/uboot-build/rkbin"                   # shared with build-uboot.sh, gitignored

# --- pinned dependencies (bump deliberately, never float) ---
RKDEV_REPO="https://github.com/rockchip-linux/rkdeveloptool.git"
RKDEV_SHA="304f073752fd25c854e1bcf05d8e7f925b1f4e14"   # master @ 2026-08-14
RKBIN_REPO="https://github.com/rockchip-linux/rkbin.git"
RKBIN_SHA="ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4"
USBPLUG="bin/rk35/rk3528_usbplug_v1.04.bin"       # serves rl/wl over USB; maskrom-only, never flashed
SPL="bin/rk35/rk3528_spl_v1.06.bin"               # matches the factory spl-v1.06 banner

BOARD="${1:-}"
IDB="$REPO/firmware/$BOARD/factory_idbloader.bin"
[ -r "$IDB" ] || { echo "usage: $0 <board>   # $(cd "$REPO/firmware" && ls */factory_idbloader.bin | cut -d/ -f1 | tr '\n' ' ')"; exit 1; }

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

mkdir -p "$TOOLS"
if [ -d "$BUILD/.git" ]; then
	git -C "$BUILD" fetch --quiet origin "$RKDEV_SHA" || true
else
	rm -rf "$BUILD"
	git clone --quiet "$RKDEV_REPO" "$BUILD"
fi
git -C "$BUILD" checkout --quiet "$RKDEV_SHA"

cd "$BUILD"
autoreconf -i >/dev/null
./configure "${CONFIGURE_ARGS[@]:-}" >/dev/null
make -j"$(getconf _NPROCESSORS_ONLN)" >/dev/null

install -m 755 "$BUILD/rkdeveloptool" "$TOOLS/rkdeveloptool"

# --- the USB loader: rkdeveloptool packs it itself, so this needs no x86 boot_merger ---
if [ ! -e "$RKBIN/$USBPLUG" ]; then
	rm -rf "$RKBIN" && mkdir -p "$RKBIN" && ( cd "$RKBIN"
		git init -q && git remote add origin "$RKBIN_REPO"
		git fetch -q --depth 1 origin "$RKBIN_SHA" && git checkout -q FETCH_HEAD )
fi

# CODE471 is the box's own DDR init, carved from its factory idbloader rather than guessed from
# rkbin's variants — the IDB entry table at byte 0x78 is u16 start sector + u16 sector count.
DDR=board_ddr.bin
SEC=$(od -An -tu2 -j 120 -N 2 "$IDB" | tr -d ' ')
CNT=$(od -An -tu2 -j 122 -N 2 "$IDB" | tr -d ' ')
dd if="$IDB" of="$RKBIN/$DDR" bs=512 skip="$SEC" count="$CNT" status=none
strings "$RKBIN/$DDR" | grep -q "^ddr-v" || { echo "no DDR blob at sector $SEC of $IDB"; exit 1; }

# `pack` reads config.ini from the cwd. rkbin's own RKBOOT ini is not usable as-is: this parser
# indexes LOADER keys from 0 and rejects the [SYSTEM]/[FLAG] sections.
( cd "$RKBIN"
	cat > config.ini <<-EOF
		[CHIP_NAME]
		NAME=RK3528
		[VERSION]
		MAJOR=1
		MINOR=4
		[CODE471_OPTION]
		NUM=1
		Path1=$DDR
		Sleep=1
		[CODE472_OPTION]
		NUM=1
		Path1=$USBPLUG
		[LOADER_OPTION]
		NUM=2
		LOADER0=FlashData
		LOADER1=FlashBoot
		FlashData=$DDR
		FlashBoot=$SPL
		[OUTPUT]
		PATH=rk3528_spl_loader.bin
	EOF
	"$TOOLS/rkdeveloptool" pack > /dev/null
	mv rk3528_spl_loader*.bin "$TOOLS/rk3528_spl_loader.bin"
	rm -f config.ini "$DDR" )

echo "built: tools/rkdeveloptool  ·  tools/rk3528_spl_loader.bin ($BOARD DDR init, $((CNT * 512)) B)"
"$TOOLS/rkdeveloptool" -v 2>/dev/null || true
echo
echo "Box in maskrom (AV-jack button held at power-on, USB-A-to-A to a real port):"
echo "  tools/rkdeveloptool ld            # list devices — should show a Maskrom entry"
