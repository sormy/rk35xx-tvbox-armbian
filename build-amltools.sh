#!/usr/bin/env bash
# Build the Amlogic host tools into tools/aml (gitignored): amlcmd, which talks to a box over USB,
# and gxlimg, which unpacks and signs its boot images.
set -euo pipefail

cd "$(dirname "$0")"

GXLIMG_REPO="https://github.com/repk/gxlimg.git"
GXLIMG_SHA="d7a8d33ef7d330a8dc77f3f53ab1e12b00a6ec8f"   # master @ 2025-11-10
GXLIMG_SRC="tools/src/gxlimg"

# Homebrew keeps both libraries keg-only
if command -v brew >/dev/null; then
  export PKG_CONFIG_PATH="$(brew --prefix libusb)/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi
for lib in libusb-1.0 openssl; do
  pkg-config --exists "$lib" || {
    echo "missing: $lib — brew install libusb openssl@3, or apt install libusb-1.0-0-dev libssl-dev" >&2
    exit 1
  }
done

mkdir -p tools/aml tools/src
cc -O2 -Wall -Wextra -o tools/aml/amlcmd src/amlcmd/amlcmd.c \
  $(pkg-config --cflags --libs libusb-1.0)

[ -d "$GXLIMG_SRC/.git" ] || git clone --quiet "$GXLIMG_REPO" "$GXLIMG_SRC"
git -C "$GXLIMG_SRC" fetch --quiet origin "$GXLIMG_SHA" || true
git -C "$GXLIMG_SRC" checkout --quiet --force "$GXLIMG_SHA"
git -C "$GXLIMG_SRC" clean -qfd
for p in patches/gxlimg/*.patch; do
  git -C "$GXLIMG_SRC" apply "$PWD/$p"
done
make -s -C "$GXLIMG_SRC" CC=cc LD=cc \
  CFLAGS="-W -Wall -std=gnu99 -D_GNU_SOURCE $(pkg-config --cflags openssl)" \
  LDFLAGS="$(pkg-config --libs openssl)"
cp "$GXLIMG_SRC/gxlimg" tools/aml/

echo "ready: tools/aml/amlcmd tools/aml/gxlimg"
