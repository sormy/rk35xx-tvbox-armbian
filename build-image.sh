#!/usr/bin/env bash
# Build a flash-and-go Armbian image for a supported RK3518 TV box (r69, h96max).
#
# Takes a stock Armbian rk35xx (vendor 6.1) base image — the ROCK 2F image, used only as the
# donor of the kernel/rootfs/boot plumbing — and bakes in everything board-specific:
#   - the board's factory idbloader @ sector 64   (the only DDR config stable on its DRAM die)
#   - our shared u-boot.itb @ sector 16384        (mainline + BL31 v1.21; build-uboot.sh)
#   - the board device tree                       (see docs/<board>/dtb.md)
#   - the firmware payload                        (firmware/<board>/payload.list)
#   - DKMS driver sources fetched on this host    (built offline on first boot)
#
# Board specifics live in firmware/<board>/board.conf (vars + two hooks). No kernel build, no
# Docker — native macOS via e2tools, or native Linux via a loop device.
#
# Usage:  ./build-image.sh  Armbian_rk35xx.img[.xz]  <board>  [out.img]
#   board is required (run without it to list what's available). With no out.img, output is
#   "<base>-<board>.img" next to the base.
#   brew install e2tools xz    (macOS)   /   apt install e2tools xz-utils  (Linux)
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/firmware"

boards() { for d in "$FW"/*/board.conf; do [ -f "$d" ] && basename "$(dirname "$d")"; done | tr '\n' ' '; }
usage() { echo "usage: build-image.sh Armbian_rk35xx.img[.xz] <board> [out.img]"; echo "boards: $(boards)"; exit 1; }

BASE="${1:-}"; BOARD="${2:-}"
[ -n "$BASE" ] && [ -n "$BOARD" ] || usage
[ -f "$FW/$BOARD/board.conf" ] || { echo "Unknown board '$BOARD'"; echo "boards: $(boards)"; exit 1; }
# shellcheck source=/dev/null
. "$FW/$BOARD/board.conf"

if [ -n "${3:-}" ]; then OUT="$3"; else
  base_noext="${BASE%.xz}"; OUT="${base_noext%.img}-$BOARD.img"
fi

IDBLOADER="$FW/$BOARD_IDBLOADER"          # -> sector 64
UBOOT="$FW/common/u-boot.itb"             # -> sector 16384
DTB="$FW/$BOARD_DTB"
PAYLOAD="$FW/$BOARD_PAYLOAD"
IDBLOADER_SEEK=64
UBOOT_SEEK=16384
# serial console on ff9f0000/ttyS0, not Armbian's stock ttyS2 (= a data UART on these boards)
SERIALCON="earlycon=uart8250,mmio32,0xff9f0000 console=ttyS0,1500000"

# every static payload file (mode src dest) must exist
PAYLOAD_SRCS="$(sed -E 's/^[[:space:]]*#.*//; /^[[:space:]]*$/d' "$PAYLOAD" | awk '{print $2}')"
for f in "$BASE" "$IDBLOADER" "$UBOOT" "$DTB" "$PAYLOAD" "$FW/common/fetch-dkms-src.sh"; do
  [ -f "$f" ] || { echo "Missing: $f"; exit 1; }
done
for s in $PAYLOAD_SRCS; do
  [ -f "$FW/$s" ] || { echo "Missing payload source: firmware/$s"; exit 1; }
done
# the patched e2tools, never the stock ones: stock e2rm frees a symlink's target string as block
# numbers and leaks removed directories, and both corrupt the image silently
E2DIR="$REPO/tools/e2tools"
PATH="$E2DIR:$PATH"
for t in e2cp e2ls e2ln e2mkdir e2rm; do
  [ -x "$E2DIR/$t" ] || { echo "Need patched e2tools ($t). Run: ./build-e2tools.sh"; exit 1; }
done
for t in curl patch tar; do
  command -v "$t" >/dev/null || { echo "Need $t (DKMS source fetch)"; exit 1; }
done

# ---- 1. base image -> OUT ------------------------------------------------------------
echo "[1/5] Writing base image -> $OUT"
case "$BASE" in
  *.xz) command -v xz >/dev/null || { echo "Need xz to decompress $BASE"; exit 1; }; xz -dc "$BASE" > "$OUT" ;;
  *)    cp "$BASE" "$OUT" ;;
esac

# ---- 2. factory bootloader (raw sectors, before the first partition) -----------------
echo "[2/5] Overlaying $BOARD factory idbloader @${IDBLOADER_SEEK} + our u-boot.itb @${UBOOT_SEEK}"
dd if="$IDBLOADER" of="$OUT" bs=512 seek="$IDBLOADER_SEEK" conv=notrunc 2>/dev/null
dd if="$UBOOT"     of="$OUT" bs=512 seek="$UBOOT_SEEK"     conv=notrunc 2>/dev/null

# ---- 3. attach the image, find the Armbian rootfs partition --------------------------
echo "[3/5] Attaching image to reach the ext4 rootfs"
OS="$(uname -s)"
ATTACHED=""
detach() { [ -n "$ATTACHED" ] || return 0
  case "$OS" in Darwin) hdiutil detach "$ATTACHED" >/dev/null 2>&1 || true ;;
                Linux)  sudo losetup -d "$ATTACHED" 2>/dev/null || true ;; esac; }
trap detach EXIT

if [ "$OS" = Darwin ]; then
  ATTACHED="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" | head -1 | awk '{print $1}')"
  PART="$(diskutil list "$ATTACHED" | awk '/[0-9]+:/{p=$NF} END{print p}')"   # last partition = rootfs
  # buffered BLOCK node (not /dev/r…): libext2fs does unaligned I/O, which the raw char
  # node rejects. hdiutil hands the node to the attaching user (rw), so no sudo needed.
  FS="/dev/${PART}"
else
  ATTACHED="$(sudo losetup -fP --show "$OUT")"
  FS="$(lsblk -lnpo NAME "$ATTACHED" | tail -1)"
  # own the node so e2tools run unprivileged (root + user-owned /tmp scratch breaks e2cp copy-out)
  sudo chown "$(id -un)" "$FS"
fi
echo "      rootfs partition: $FS"

# ---- 4. install the board device tree + console --------------------------------------
echo "[4/5] Installing $BOARD DTB + console"
VERDIR="$(e2ls "$FS:/boot" | tr -s ' \t' '\n' | grep '^dtb-' | head -1)"
[ -n "$VERDIR" ] || { echo "Could not find /boot/dtb-<ver> in the image"; exit 1; }
FDT="rockchip/board.dtb"
e2cp "$DTB" "$FS:/boot/$VERDIR/$FDT"

ENV="$(mktemp)"
e2cp "$FS:/boot/armbianEnv.txt" "$ENV"
# console=display drops boot.cmd's stray console=ttyS2; ours goes via extraargs
grep -v -E '^fdtfile=|^extraargs=|^console=' "$ENV" > "$ENV.new" || true
printf 'fdtfile=%s\nconsole=display\nextraargs=%s\n' "$FDT" "$SERIALCON" >> "$ENV.new"
e2cp "$ENV.new" "$FS:/boot/armbianEnv.txt"
rm -f "$ENV" "$ENV.new"

# ---- 5. firmware payload + drop-ins + DKMS sources + rebrand -------------------------
echo "[5/5] Installing $BOARD payload + DKMS sources + rebrand"
TMP="$(mktemp -d)"

# --- static payload: every file from the board's payload.list, verbatim ---
while read -r mode src dest; do
  case "$mode" in ''|\#*) continue ;; esac
  e2mkdir "$FS:$(dirname "$dest")" 2>/dev/null || true
  e2cp -P "$mode" "$FW/$src" "$FS:$dest"
done < "$PAYLOAD"

# --- enable the board's oneshots without a wants/ symlink (e2tools can't symlink) ---
printf '[Unit]\nWants=%s\n' "$BOARD_WANTS" > "$TMP/10-$BOARD_HOSTNAME.conf"
e2mkdir "$FS:/etc/systemd/system/multi-user.target.d" 2>/dev/null || true
e2cp "$TMP/10-$BOARD_HOSTNAME.conf" "$FS:/etc/systemd/system/multi-user.target.d/10-$BOARD_HOSTNAME.conf"

# (the ttyFIQ0 getty override now ships in payload.list, so updates install it too)

# --- board-specific drop-ins + DKMS source staging (hooks from board.conf) ---
board_image_tweaks "$FS" "$TMP"
DKMSTMP="$(mktemp -d)"
board_stage_dkms "$FS" "$DKMSTMP"
rm -rf "$DKMSTMP"

# --- Bluetooth AutoEnable — only if the base already ships bluez (gate on non-empty copy) ---
BTMAIN="$(mktemp)"
if e2cp "$FS:/etc/bluetooth/main.conf" "$BTMAIN" 2>/dev/null && [ -s "$BTMAIN" ]; then
  if grep -qiE '^[[:space:]]*#?[[:space:]]*AutoEnable=' "$BTMAIN"; then
    sed -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable=.*/AutoEnable=true/' "$BTMAIN" > "$BTMAIN.new"
  else
    cp "$BTMAIN" "$BTMAIN.new"; printf '\n[Policy]\nAutoEnable=true\n' >> "$BTMAIN.new"
  fi
  e2cp "$BTMAIN.new" "$FS:/etc/bluetooth/main.conf"
fi
rm -f "$BTMAIN" "$BTMAIN.new"

# ---- rebrand: the ROCK 2F base ships hostname "rock-2f" ------------------------------
e2cp "$FS:/etc/hostname" "$TMP/oldhost" 2>/dev/null || true
OLDH="$(tr -d '[:space:]' < "$TMP/oldhost" 2>/dev/null)"
printf '%s\n' "$BOARD_HOSTNAME" > "$TMP/hostname"
e2cp "$TMP/hostname" "$FS:/etc/hostname"
if [ -n "$OLDH" ] && e2cp "$FS:/etc/hosts" "$TMP/hosts" 2>/dev/null; then
  sed "s/$OLDH/$BOARD_HOSTNAME/g" "$TMP/hosts" > "$TMP/hosts.new"
  e2cp "$TMP/hosts.new" "$FS:/etc/hosts"
fi
# relabel the login MOTD board name (display only; BOARD= identifier stays for armbian tooling)
if e2cp "$FS:/etc/armbian-release" "$TMP/arel" 2>/dev/null; then
  sed "s/^BOARD_NAME=.*/BOARD_NAME=\"$BOARD_NAME_LABEL\"/" "$TMP/arel" > "$TMP/arel.new"
  e2cp "$TMP/arel.new" "$FS:/etc/armbian-release"
fi
rm -rf "$TMP"

# --- verify we didn't corrupt the rootfs (e2tools writes ext4 without a kernel) --------
# (homebrew keeps e2fsprogs keg-only, so look in its opt prefix too)
FSCK="$(command -v fsck.ext4 || true)"
for c in /opt/homebrew/opt/e2fsprogs/sbin/fsck.ext4 /usr/local/opt/e2fsprogs/sbin/fsck.ext4; do
  [ -n "$FSCK" ] || { [ -x "$c" ] && FSCK="$c"; }
done
if [ -n "$FSCK" ]; then
  echo "      checking filesystem"
  "$FSCK" -fn "$FS" >/dev/null 2>&1 || {
    echo "FILESYSTEM CORRUPT — refusing to ship this image. Run: $FSCK -fn $FS"; exit 1; }
else
  echo "      (no fsck.ext4 found — filesystem NOT verified; brew install e2fsprogs)"
fi

detach; ATTACHED=""; sync
echo
echo "Done -> $OUT"
echo "Flash it (with progress):"
echo "  macOS:  diskutil unmountDisk /dev/diskN; sudo gdd if=$OUT of=/dev/rdiskN bs=4M conv=fsync status=progress   (brew install coreutils)"
echo "  Linux:  sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo "  ...or Balena Etcher on either OS."
