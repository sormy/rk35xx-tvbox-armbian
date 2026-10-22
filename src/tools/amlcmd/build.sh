#!/usr/bin/env bash
# Build amlcmd into build/tools/amlcmd: it drives an Amlogic box's burning mode over USB.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/../../.." && pwd)/build/tools/amlcmd"

# Homebrew keeps libusb keg-only
if command -v brew >/dev/null; then
  PKG_CONFIG_PATH="$(brew --prefix libusb)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export PKG_CONFIG_PATH
fi
pkg-config --exists libusb-1.0 || { echo "missing: libusb-1.0 — brew install libusb, or apt install libusb-1.0-0-dev" >&2; exit 1; }

mkdir -p "$OUT"
# shellcheck disable=SC2046  # pkg-config's flags are words
cc -O2 -Wall -Wextra -o "$OUT/amlcmd" "$HERE/amlcmd.c" $(pkg-config --cflags --libs libusb-1.0)
echo "built: build/tools/amlcmd/amlcmd"
