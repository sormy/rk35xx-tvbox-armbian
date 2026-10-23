#!/usr/bin/env bash
# Build gxlimg into build/tools/gxlimg: it unpacks and signs Amlogic boot images.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="$REPO/build/tools/gxlimg"
BUILD="$OUT/src"

GXLIMG_REPO="https://github.com/repk/gxlimg.git"
GXLIMG_SHA="d7a8d33ef7d330a8dc77f3f53ab1e12b00a6ec8f"   # master @ 2025-11-10

# Homebrew keeps OpenSSL keg-only
if command -v brew >/dev/null; then
  PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export PKG_CONFIG_PATH
fi
pkg-config --exists openssl || { echo "missing: openssl — brew install openssl@3, or apt install libssl-dev" >&2; exit 1; }

mkdir -p "$OUT"
[ -d "$BUILD/.git" ] || git clone --quiet "$GXLIMG_REPO" "$BUILD"
git -C "$BUILD" fetch --quiet "$GXLIMG_REPO" "$GXLIMG_SHA" || true
git -C "$BUILD" checkout --quiet --force "$GXLIMG_SHA"
git -C "$BUILD" clean -qfd
for p in "$REPO"/patches/gxlimg/*.patch; do
  git -C "$BUILD" apply "$p"
done
make -s -C "$BUILD" CC=cc LD=cc \
  CFLAGS="-W -Wall -std=gnu99 -D_GNU_SOURCE $(pkg-config --cflags openssl)" \
  LDFLAGS="$(pkg-config --libs openssl)"
cp "$BUILD/gxlimg" "$OUT/"
echo "built: build/tools/gxlimg/gxlimg"
