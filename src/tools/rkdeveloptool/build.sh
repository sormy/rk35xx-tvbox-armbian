#!/usr/bin/env bash
# Build patched rkdeveloptool into build/tools/rkdeveloptool, for talking to a Rockchip box in
# maskrom. Each board's loader is packed with it by build-rockchip-loaders.sh.
#
# Usage: ./build.sh tool rkdeveloptool
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="$REPO/build/tools/rkdeveloptool"
BUILD="$OUT/src"                                  # scratch clone
PATCHES="$HERE/patches"

# --- pinned dependencies (bump deliberately, never float) ---
RKDEV_REPO="https://github.com/rockchip-linux/rkdeveloptool.git"
RKDEV_SHA="304f073752fd25c854e1bcf05d8e7f925b1f4e14"   # master @ 2026-08-14

need() { command -v "$1" >/dev/null || { echo "missing: $1 — $2"; exit 1; }; }

case "$(uname -s)" in
	Darwin)
		need brew "install Homebrew first"
		for p in autoconf automake libtool pkg-config libusb; do
			brew list --formula "$p" >/dev/null 2>&1 || brew install "$p"
		done
		# Homebrew keeps libusb out of the default search paths
		PKG_CONFIG_PATH="$(brew --prefix libusb)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
		export PKG_CONFIG_PATH
		# upstream builds -Werror and uses C++ VLAs, which clang rejects; allow just that one
		CONFIGURE_ARGS=(CXXFLAGS="-O2 -Wno-error=vla-cxx-extension")
		;;
	Linux)
		for c in autoreconf pkg-config g++; do need "$c" "apt install autoconf automake libtool pkg-config g++ libusb-1.0-0-dev"; done
		pkg-config --exists libusb-1.0 || { echo "missing: libusb-1.0 — apt install libusb-1.0-0-dev"; exit 1; }
		;;
	*) echo "unsupported host: $(uname -s)"; exit 1 ;;
esac

mkdir -p "$OUT"
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
echo "built: build/tools/rkdeveloptool/rkdeveloptool ($("$OUT/rkdeveloptool" -v | head -1))"
