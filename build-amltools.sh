#!/usr/bin/env bash
# Build amlcmd, the host tool for talking to an Amlogic box over USB — both the
# burning gadget and the mask ROM behind it.
set -euo pipefail

cd "$(dirname "$0")"

if ! pkg-config --exists libusb-1.0; then
  echo "libusb not found. On macOS: brew install libusb" >&2
  echo "On Debian/Ubuntu: apt install libusb-1.0-0-dev" >&2
  exit 1
fi

mkdir -p tools/aml
cc -O2 -Wall -Wextra -o tools/aml/amlcmd src/amlcmd/amlcmd.c \
  $(pkg-config --cflags --libs libusb-1.0)

echo "amlcmd ready: tools/aml/amlcmd"
