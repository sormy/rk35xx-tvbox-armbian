#!/usr/bin/env bash
# Stage mainline's mt76 as DKMS source for the MT7668S, patched to claim it.
#   usage: fetch-mt76-src.sh <src-dir> [kernel-version]
#
# The chip is an MT7663 sibling whose firmware owns the MAC; patches/mt76-mt7668 teaches mt7663s
# to drive it, so the vendor driver need not be carried.
#
# The whole SDIO stack is built - mt76, mt76-sdio, mt76-connac-lib, mt7615-common,
# mt7663-usb-sdio-common and mt7663s - since the patches change the core, and it installs over the
# in-tree modules through updates/.
set -e
DIR="${1:?usage: fetch-mt76-src.sh <src-dir> [kernel-version]}"
KVER="${2:-6.18.44}"   # must match the base image's kernel: mt76 tracks its own mac80211

PATCHES="$(cd "$(dirname "$0")/../../patches/mt76-mt7668" && pwd)"
SUB="drivers/net/wireless/mediatek/mt76"

NEW="$DIR.new"
trap 'rm -rf "$NEW" "$NEW.tmp"' EXIT
rm -rf "$NEW" "$NEW.tmp"; mkdir -p "$NEW.tmp"
# the tarball is 140 MB and the same for every board and rebuild, so keep it
CACHE="$(cd "$(dirname "$0")/../.." && pwd)/build/kernel-tarballs"
mkdir -p "$CACHE"
TAR="$CACHE/linux-$KVER.tar.xz"
if [ ! -s "$TAR" ]; then
  curl -fsSL -o "$TAR.part" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
  mv -f "$TAR.part" "$TAR"
fi
tar -xJf "$TAR" -C "$NEW.tmp" "linux-$KVER/$SUB"
[ -f "$NEW.tmp/linux-$KVER/$SUB/mt7615/sdio.c" ] || { echo "fetch-mt76-src: incomplete download" >&2; exit 1; }
mv "$NEW.tmp/linux-$KVER/$SUB" "$NEW"

for p in "$PATCHES"/*.patch; do
  [ -e "$p" ] || continue
  patch -p1 -d "$NEW" < "$p"
done

rm -rf "$DIR"; mv "$NEW" "$DIR"
trap - EXIT
