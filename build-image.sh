#!/usr/bin/env bash
# Build a flash-and-go Armbian image for any board under firmware/. A stock Armbian image is the
# donor of kernel/rootfs/boot plumbing; everything board-specific — the loader pair, the device tree,
# the payload, DKMS sources — is baked in from firmware/<board>/.
#
# Which Armbian image is the board's own BOARD_BASE, and the build refuses any other: the two
# families here want different donors, and the mismatch is silent until the box will not boot.
#
# Usage:  ./build-image.sh  Armbian_<base>.img[.xz]  <board>  [out.img]
#   Run without <board> to list what's available. Default output is "<base>-<board>.img".
#   Needs the patched e2tools (./build-e2tools.sh); every other missing tool is named, with the
#   command that installs it, before anything is written.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/firmware"

boards() {
  for c in "$FW"/*/board.conf; do
    [ -f "$c" ] || continue
    printf '  %-14s base: %s\n' "$(basename "$(dirname "$c")")" "$(sed -n 's/^BOARD_BASE=//p' "$c")"
  done
}
usage() { echo "usage: build-image.sh Armbian_<base>.img[.xz] <board> [out.img]"; echo "boards:"; boards; exit 1; }

BASE="${1:-}"; BOARD="${2:-}"
[ -n "$BASE" ] && [ -n "$BOARD" ] || usage
[ -f "$FW/$BOARD/board.conf" ] || { echo "Unknown board '$BOARD'"; echo "boards:"; boards; exit 1; }
# shellcheck source=/dev/null
. "$FW/$BOARD/board.conf"

if [ -n "${3:-}" ]; then OUT="$3"; else
  base_noext="${BASE%.xz}"; OUT="${base_noext%.img}-$BOARD.img"
fi

# rk35xx: the factory loader pair is overlaid on the base image's raw sectors.
# meson-gxl: the loaders stay in the eMMC, and the image follows the eMMC's layout.
BOARD_FAMILY="${BOARD_FAMILY:-rk35xx}"
DTB="$FW/$BOARD_DTB"
PAYLOAD="$FW/$BOARD_PAYLOAD"
FDT="${BOARD_FDT:-rockchip/board.dtb}"

IDBLOADER="$FW/${BOARD_IDBLOADER:-}"      # -> sector 64
UBOOT="$FW/${BOARD_UBOOT:-}"              # -> sector 16384
IDBLOADER_SEEK=64
UBOOT_PART_END=24575          # the factory uboot partition; the rootfs has to start above it
UBOOT_SEEK=16384
UBOOT_SLOT_SECTORS=4096
UBOOT_COPIES=2                # the uboot partition is two slots; both get the same FIT
# The BootROM scans five idbloader slots 1024 sectors apart. Every copy in a factory blob is
# byte-identical, so each slot gets the first one — the R69's blob only fills two of the five.
IDBLOADER_COPIES=5
IDBLOADER_COPY_SECTORS=1024
FACTORY_WINDOW_SEEK=7168      # DVKR at 7168 and SSKR at 8192, up to the uboot partition
FACTORY_WINDOW_SECTORS=9216
ROOTFS_START_MAX=131072       # 64 MiB: no Armbian layout starts further out, so a larger read is a bad GPT
# meson-gxl: the vendor bootloader owns 0-4 MiB and reserved starts at 36 MiB
UEXT_SEEK=8192                # 4 MiB: u-boot.ext raw, for the eMMC's vendor U-Boot to amlmmc read
UEXT_SECTORS=8192
FAT_SEEK=16384                # 8 MiB up to reserved: the FAT boot partition, in the unpartitioned gap
AML_ENV_BYTES=65536           # the vendor U-Boot's CONFIG_ENV_SIZE: CRC32, then the variables
AML_MPT_SECTORS=8             # the partition table opening reserved; the unit's keys follow at +32
AML_DTB_OFFSET=8192           # reserved +4 MiB: the two 256 KiB device-tree copies
# meson-gxl CONFIG_SYS_TEXT_BASE: where a raw U-Boot proper runs. It relocates itself high before
# boot.scr runs, so the address is free again and the device tree lands there.
AML_UBOOT_ADDR=0x1000000
AML_KERNEL_ADDR=0x11000000
AML_INITRD_ADDR=0x15000000

# first partition's start LBA, read out of the GPT — the window must stop short of it
gpt_first_lba() {
  [ "$(dd if="$1" bs=1 skip=512 count=8 2>/dev/null)" = "EFI PART" ] ||
    { echo "no GPT in $1 — refusing to guess where the rootfs starts" >&2; return 1; }
  local parray
  parray=$(od -An -tu8 -j $((512 + 72)) -N 8 "$1" | tr -d ' ')
  case "$parray" in ''|*[!0-9]*|0) echo "GPT header names no partition array in $1" >&2; return 1 ;; esac
  od -An -tu8 -j $((parray * 512 + 32)) -N 8 "$1" | tr -d ' '
}
# Serial console on ff9f0000, never Armbian's stock ttyS2 (= a data UART on these boards). Boards
# that keep the vendor's fiq-debugger reach the same UART as ttyFIQ0 and set BOARD_SERIALCON.
SERIALCON="${BOARD_SERIALCON:-earlycon=uart8250,mmio32,0xff9f0000 console=ttyS0,1500000}"
# the in-kernel rockchip_pwm_remotectl lacks the shared-IRQ fix: it storms the group IRQ and drops
# IR wake, so our patched module owns the receiver instead
IR_BLACKLIST="${BOARD_IR_BLACKLIST-initcall_blacklist=rk_pwm_driver_init}"
BOARD_CMA="${BOARD_CMA:-256M}"   # the tree reserves 8 MiB, too little for one 4K frame
BOARD_NAME_FILE="$FW/$BOARD/board-name"   # same file the apt hook restores from

# ---- helpers ------------------------------------------------------------------------
fit_magic() { od -An -tx1 -N4 "$1" | tr -d ' \n'; }

# write $1 into $2 slots of $3 sectors from sector $4, each slot cleared first so nothing of what
# was under it survives behind a shorter blob
replicate() {
  local src=$1 copies=$2 sectors=$3 seek=$4 i=0 at
  while [ "$i" -lt "$copies" ]; do
    at=$((seek + i * sectors))
    dd if=/dev/zero of="$OUT" bs=512 seek="$at" count="$sectors" conv=notrunc 2>/dev/null
    dd if="$src"    of="$OUT" bs=512 seek="$at" count="$sectors" conv=notrunc 2>/dev/null
    i=$((i + 1))
  done
}


# start sector and sector count of MBR partition $2 in image $1
mbr_part() {
  local off=$((446 + ($2 - 1) * 16))
  [ "$(od -An -tx2 -j 510 -N 2 "$1" | tr -d ' ')" = aa55 ] ||
    { echo "no MBR in $1 — refusing to guess where the rootfs is" >&2; return 1; }
  # 0xEE is a GPT protective entry: it spans the disk and says nothing about where the rootfs is
  [ "$(od -An -tx1 -j $((off + 4)) -N 1 "$1" | tr -d ' ')" != ee ] ||
    { echo "$1 is GPT-partitioned, and this board is built from an MBR image" >&2; return 1; }
  od -An -tu4 -j $((off + 8)) -N 8 "$1" | tr -s ' ' '\n' | grep -v '^$' | tr '\n' ' '
}

bytes() { local b; for b in "$@"; do printf "$(printf '\\%03o' "$b")"; done; }

# one 16-byte MBR entry: boot flag, type, start, count. The CHS fields are the "use LBA" sentinel,
# which is what every partitioner writes past 8 GB and what the vendor U-Boot reads.
mbr_entry() {
  bytes "$1" 254 255 255 "$2" 254 255 255 \
        $(($3 & 255)) $(($3 >> 8 & 255)) $(($3 >> 16 & 255)) $(($3 >> 24 & 255)) \
        $(($4 & 255)) $(($4 >> 8 & 255)) $(($4 >> 16 & 255)) $(($4 >> 24 & 255))
}

# copy $5 sectors from sector $3 of $1 to sector $4 of $2, in the largest block that divides all
# three — a gigabyte of rootfs moved 512 bytes at a time takes minutes
copy_sectors() {
  local b=2048
  while [ $b -gt 1 ] && { [ $(($3 % b)) -ne 0 ] || [ $(($4 % b)) -ne 0 ] || [ $(($5 % b)) -ne 0 ]; }; do
    b=$((b / 2))
  done
  dd if="$1" of="$2" bs=$((b * 512)) skip=$(($3 / b)) seek=$(($4 / b)) count=$(($5 / b)) \
     conv=notrunc 2>/dev/null
}

# e2tools default to the host's uid/gid inside the image
e2cp() { command e2cp -O 0 -G 0 "$@"; }
e2mkdir() { command e2mkdir -O 0 -G 0 "$@"; }

# ---- preflight: everything checked before the first byte is written -------------------
PAYLOAD_SRCS="$(sed -E 's/^[[:space:]]*#.*//; /^[[:space:]]*$/d' "$PAYLOAD" | awk '{print $2}')"
for f in "$BASE" "$DTB" "$PAYLOAD" "$BOARD_NAME_FILE" "$FW/common/fetch-dkms-src.sh"; do
  [ -f "$f" ] || { echo "Missing: $f"; exit 1; }
done
for s in $PAYLOAD_SRCS; do
  [ -f "$FW/$s" ] || { echo "Missing payload source: firmware/$s"; exit 1; }
done

# need <tool> <brew package> <apt package> <what for>
need() {
  command -v "$1" >/dev/null && return 0
  case "$(uname -s)" in Darwin) echo "Need $1 ($4): brew install $2" ;; *) echo "Need $1 ($4): sudo apt install $3" ;; esac
  exit 1
}

case "$BOARD_FAMILY" in
  rk35xx)
    for f in "$IDBLOADER" "$UBOOT"; do [ -f "$f" ] || { echo "Missing: $f"; exit 1; }; done
    # the BootROM answers an RKNS ID block and nothing else; a truncated FIT does not boot
    [ "$(dd if="$IDBLOADER" bs=4 count=1 2>/dev/null)" = RKNS ] ||
      { echo "$IDBLOADER is not an RKNS ID block"; exit 1; }
    [ "$(wc -c < "$IDBLOADER")" -ge $((IDBLOADER_COPY_SECTORS * 512)) ] ||
      { echo "$IDBLOADER is shorter than the $((IDBLOADER_COPY_SECTORS / 2)) KiB slot it is written into"; exit 1; }
    [ "$(fit_magic "$UBOOT")" = d00dfeed ] || { echo "$UBOOT is not a FIT"; exit 1; }
    [ "$(wc -c < "$UBOOT")" -le $((UBOOT_SLOT_SECTORS * 512)) ] ||
      { echo "$UBOOT is $(wc -c < "$UBOOT") bytes, past the $((UBOOT_SLOT_SECTORS / 2)) KiB U-Boot slot"; exit 1; }
    ;;
  meson-gxl)
    need mkimage u-boot-tools u-boot-tools "the boot scripts"
    need mformat mtools mtools "the FAT boot partition"
    need mcopy mtools mtools "the FAT boot partition"
    need python3 python python3 "the eMMC layout and env"
    : "${BOARD_UBOOT_SRC:?board.conf must say where the base image keeps its U-Boot}"
    : "${BOARD_AML_MMC_DEV:?board.conf must say which amlmmc device is the eMMC}"
    : "${BOARD_AML_EMMC_SECTORS:?board.conf must give the eMMC size in sectors}"
    STOCK="$REPO/stock/$BOARD"
    LAYOUT="$(mktemp -d)"
    python3 "$REPO/scripts/aml-layout.py" "$STOCK/factory-mpt.bin" "$STOCK/factory-multidtb.bin" \
      "$BOARD_AML_EMMC_SECTORS" "$LAYOUT/mpt.bin" "$LAYOUT/dtb.bin"
    read -r ENV_SEEK ENV_SECTORS <<< "$(python3 "$REPO/scripts/aml-mpt.py" "$LAYOUT/mpt.bin" env)"
    read -r RESERVED_SEEK _ <<< "$(python3 "$REPO/scripts/aml-mpt.py" "$LAYOUT/mpt.bin" reserved)"
    FAT_SECTORS=$((RESERVED_SEEK - FAT_SEEK))
    ROOT_SEEK=$((ENV_SEEK + ENV_SECTORS))
    ;;
  *) echo "Unknown BOARD_FAMILY '$BOARD_FAMILY'"; exit 1 ;;
esac

# patched e2tools only: stock e2rm corrupts an image on delete
E2DIR="$REPO/tools/e2tools"
PATH="$E2DIR:$PATH"
for t in e2cp e2ls e2ln e2mkdir e2rm; do
  [ -x "$E2DIR/$t" ] || { echo "Need patched e2tools ($t). Run: ./build-e2tools.sh"; exit 1; }
done
need curl curl curl "the DKMS source fetch"
need patch gpatch patch "the DKMS source fetch"
need tar gnu-tar tar "the DKMS source fetch"
[ -z "${BOARD_APT_DEBS:-}" ] || need python3 python python3 "offline package staging"
case "$BASE" in *.xz) need xz xz xz-utils "the .xz base image" ;; esac

# ---- 1. base image -> OUT ------------------------------------------------------------
echo "[1/5] Writing base image -> $OUT"
unxz_to() { xz -dc "$BASE" > "$1"; }

if [ "$BOARD_FAMILY" = rk35xx ]; then
  case "$BASE" in *.xz) unxz_to "$OUT" ;; *) cp "$BASE" "$OUT" ;; esac
else
  # The base has one partition, the Armbian rootfs. It moves past env, where the eMMC's layout
  # leaves room; the base's own @AML loader stays behind, since the box boots the one in its eMMC.
  SRC="$BASE"
  case "$BASE" in *.xz) SRC="$OUT.base"; unxz_to "$SRC" ;; esac
  PART="$(mbr_part "$SRC" 1)" || exit 1
  read -r ROOT_START ROOT_COUNT <<< "$PART"
  dd if=/dev/zero of="$OUT" bs=512 count=0 seek=$((ROOT_SEEK + ROOT_COUNT)) 2>/dev/null
  # a disk signature, so root=PARTUUID names this image's partition
  od -An -N4 -tu1 /dev/urandom | { read -r a b c d; bytes "$a" "$b" "$c" "$d"; } |
    dd of="$OUT" bs=1 seek=440 conv=notrunc 2>/dev/null
  { mbr_entry 128 12 "$FAT_SEEK" "$FAT_SECTORS"; mbr_entry 0 131 "$ROOT_SEEK" "$ROOT_COUNT"; } |
    dd of="$OUT" bs=1 seek=446 conv=notrunc 2>/dev/null
  bytes 85 170 | dd of="$OUT" bs=1 seek=510 conv=notrunc 2>/dev/null
  echo "      rootfs $ROOT_COUNT sectors -> @$ROOT_SEEK, behind a $((FAT_SECTORS / 2048)) MiB FAT boot partition"
  copy_sectors "$SRC" "$OUT" "$ROOT_START" "$ROOT_SEEK" "$ROOT_COUNT"
  if [ "$SRC" != "$BASE" ]; then rm -f "$SRC"; fi
fi

# ---- 2. factory bootloader -----------------------------------------------------------
# rk35xx boots what is on the boot media, so the loader pair is overlaid on its raw sectors.
# meson-gxl boots the loaders in its eMMC; the boot files and reserved's layout go in at the end.
if [ "$BOARD_FAMILY" = rk35xx ]; then
  ROOTFS_START="$(gpt_first_lba "$OUT")"
  [ "$ROOTFS_START" -gt "$UBOOT_PART_END" ] && [ "$ROOTFS_START" -le "$ROOTFS_START_MAX" ] ||
    { echo "First partition at $ROOTFS_START is inside the loader window, or the GPT read is wrong"; exit 1; }

  # FACTORY_DUMP supplies DVKR + SSKR, the per-unit data nothing else can. Full-image path only:
  # armbian-install keeps them itself.
  if [ -n "${FACTORY_DUMP:-}" ]; then
    [ -f "$FACTORY_DUMP" ] || { echo "FACTORY_DUMP not found: $FACTORY_DUMP"; exit 1; }
    # dd stops early and silently on a short file, restoring part of the window - a dump cut off by
    # the Loader's 32 MiB read cap is the way this happens
    [ "$(wc -c < "$FACTORY_DUMP")" -ge $(((FACTORY_WINDOW_SEEK + FACTORY_WINDOW_SECTORS) * 512)) ] ||
      { echo "FACTORY_DUMP is short: it does not reach the end of the vendor window"; exit 1; }
    # catches a dump from a different board *model* - the idbloader is model-generic, so nothing here
    # can tell one unit from another of the same model, and passing the wrong one stamps its MAC and
    # keys into the image. Compare the first slot only: that copy is what we write to all five, so it
    # matches whether the dump came from a factory box or an already-migrated one.
    cmp -s <(dd if="$FACTORY_DUMP" bs=512 skip="$IDBLOADER_SEEK" count="$IDBLOADER_COPY_SECTORS" 2>/dev/null) \
           <(dd if="$IDBLOADER" bs=512 count="$IDBLOADER_COPY_SECTORS" 2>/dev/null) ||
      { echo "FACTORY_DUMP is not from a $BOARD: its idbloader differs from $BOARD_IDBLOADER"; exit 1; }
    echo "      Restoring DVKR + SSKR @${FACTORY_WINDOW_SEEK} from $(basename "$FACTORY_DUMP")"
    dd if="$FACTORY_DUMP" of="$OUT" bs=512 skip="$FACTORY_WINDOW_SEEK" seek="$FACTORY_WINDOW_SEEK" \
       count="$FACTORY_WINDOW_SECTORS" conv=notrunc 2>/dev/null
  fi

  echo "[2/5] Overlaying $BOARD idbloader x${IDBLOADER_COPIES} @${IDBLOADER_SEEK} + uboot.itb x${UBOOT_COPIES} @${UBOOT_SEEK}"
  replicate "$IDBLOADER" "$IDBLOADER_COPIES" "$IDBLOADER_COPY_SECTORS" "$IDBLOADER_SEEK"
  replicate "$UBOOT"     "$UBOOT_COPIES"     "$UBOOT_SLOT_SECTORS"     "$UBOOT_SEEK"
else
  echo "[2/5] Factory bootloader left in eMMC"
fi

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

# every payload path assumes the base's kernel, dtb-<ver> layout and module set
WANT_BASE="${EXPECT_BASE_BOARD:-${BOARD_BASE:?board.conf must set BOARD_BASE}}"
REL="$(mktemp)"
BASE_BOARD=""
e2cp "$FS:/etc/armbian-release" "$REL" 2>/dev/null && BASE_BOARD="$(sed -n 's/^BOARD=//p' "$REL" | tr -d '"' | tr -d '\r')"
rm -f "$REL"
if [ "$BASE_BOARD" != "$WANT_BASE" ]; then
  echo "Base image is BOARD='${BASE_BOARD:-unknown}', but $BOARD is built from '$WANT_BASE'."
  echo "Use the Armbian $WANT_BASE image, or set EXPECT_BASE_BOARD to override."
  exit 1
fi
echo "      base image: $BASE_BOARD"

# ---- 4. install the board device tree + console --------------------------------------
echo "[4/5] Installing $BOARD DTB + console"
VERDIR="$(e2ls "$FS:/boot" | tr -s ' \t' '\n' | grep '^dtb-' | head -1)"
[ -n "$VERDIR" ] || { echo "Could not find /boot/dtb-<ver> in the image"; exit 1; }
KVER="${VERDIR#dtb-}"
e2cp "$DTB" "$FS:/boot/$VERDIR/$FDT"

ENV="$(mktemp)"
e2cp "$FS:/boot/armbianEnv.txt" "$ENV"
grep -v -E '^fdtfile=|^extraargs=|^console=' "$ENV" > "$ENV.new" || true
printf 'fdtfile=%s\n' "$FDT" >> "$ENV.new"          # the dtb-persist hook reads this back
# console=display drops boot.cmd's stray console=ttyS2; ours goes via extraargs. tty1 stays last,
# as boot.cmd puts it for console=both, so /dev/console is HDMI and serial still gets the kernel log.
# meson-gxl never reaches boot.cmd: the boot.scr generated below sets bootargs itself.
if [ "$BOARD_FAMILY" = rk35xx ]; then
  EXTRAARGS="$(printf '%s cma=%s %s console=tty1' "$SERIALCON" "$BOARD_CMA" "$IR_BLACKLIST" | tr -s ' ')"
  printf 'console=display\nextraargs=%s\n' "$EXTRAARGS" >> "$ENV.new"
fi
e2cp "$ENV.new" "$FS:/boot/armbianEnv.txt"
rm -f "$ENV" "$ENV.new"

# ---- 5. firmware payload + drop-ins + DKMS sources + rebrand -------------------------
echo "[5/5] Installing $BOARD payload + DKMS sources + rebrand"
TMP="$(mktemp -d)"

# --- static payload ---
while read -r mode src dest; do
  case "$mode" in ''|\#*) continue ;; esac
  e2mkdir "$FS:$(dirname "$dest")" 2>/dev/null || true
  e2cp -P "$mode" "$FW/$src" "$FS:$dest"
done < "$PAYLOAD"

# --- enable the board's oneshots without a wants/ symlink (e2tools can't symlink) ---
printf '[Unit]\nWants=%s\n' "$BOARD_WANTS" > "$TMP/10-$BOARD_HOSTNAME.conf"
e2mkdir "$FS:/etc/systemd/system/multi-user.target.d" 2>/dev/null || true
e2cp "$TMP/10-$BOARD_HOSTNAME.conf" "$FS:/etc/systemd/system/multi-user.target.d/10-$BOARD_HOSTNAME.conf"

# a board that disables the vendor fiq-debugger never gets /dev/ttyFIQ0, so the base's getty waits
# out a 90 s timeout every boot; one that keeps it needs that unit
case "$SERIALCON" in
  *ttyFIQ0*) echo "      keeping the base's serial-getty@ttyFIQ0 (this board's console)" ;;
  *) for u in /etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service \
            /etc/systemd/system/serial-getty@ttyFIQ0.service; do
       e2rm "$FS:$u" 2>/dev/null || true              # the same pair rk35xx-update removes
     done ;;
esac

# --- packages the base does not ship, downloaded here so first boot needs no network ---
if [ -n "${BOARD_APT_DEBS:-}" ]; then
  echo "      resolving $BOARD_APT_DEBS against the image's own apt state"
  APTTMP="$(mktemp -d)"
  mkdir -p "$APTTMP/sources"
  for f in $(e2ls "$FS:/etc/apt/sources.list.d/" | tr -s ' \t' '\n'); do
    e2cp "$FS:/etc/apt/sources.list.d/$f" "$APTTMP/sources/$f"
  done
  e2cp "$FS:/var/lib/dpkg/status" "$APTTMP/status"
  # cached across builds: a rebuild re-verifies the SHA256s instead of re-downloading 76 MB
  DEBS="$REPO/build/apt-debs/$BOARD"
  python3 "$REPO/scripts/fetch-apt-debs.py" --sources "$APTTMP/sources" --status "$APTTMP/status" \
    --out "$DEBS" --index-cache "$REPO/build/apt-indices" --kernel "${KVER%%-*}" $BOARD_APT_DEBS
  rm -rf "$APTTMP"
  e2mkdir "$FS:/var/cache/apt" 2>/dev/null || true
  e2mkdir "$FS:/var/cache/apt/archives" 2>/dev/null || true
  for deb in "$DEBS"/*.deb; do
    e2cp "$deb" "$FS:/var/cache/apt/archives/$(basename "$deb")"
  done
fi

# --- board hooks: drop-ins, DKMS sources ---
board_image_tweaks "$FS" "$TMP"
DKMSTMP="$(mktemp -d)"
board_stage_dkms "$FS" "$DKMSTMP"
rm -rf "$DKMSTMP"

# --- Bluetooth AutoEnable, only where the base ships bluez ---
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

# ---- rebrand: the base ships its donor board's hostname ------------------------------
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
  sed "s/^BOARD_NAME=.*/BOARD_NAME=\"$(cat "$BOARD_NAME_FILE")\"/" "$TMP/arel" > "$TMP/arel.new"
  e2cp "$TMP/arel.new" "$FS:/etc/armbian-release"
fi
rm -rf "$TMP"

# ---- boot media (meson-gxl): the FAT, u-boot.ext raw, the eMMC env -------------------
# From a stick, the eMMC's U-Boot runs recovery_from_udisk, which fatloads aml_autoscript from the
# FAT; from the eMMC, the env's linux_boot reads u-boot.ext raw. Either way the base image's own
# U-Boot runs next, because U-Boot 2015 computes a modern arm64 kernel's load address as 0 and
# aborts on the memmove. Its distro boot finds boot.scr on whichever device carries it.
FATIMG=""
if [ "$BOARD_FAMILY" = meson-gxl ]; then
  echo "      staging the FAT boot files"
  BOOTTMP="$(mktemp -d)"
  e2cp "$FS:$BOARD_UBOOT_SRC" "$BOOTTMP/u-boot.img"
  # a legacy uImage; go(1) wants the bare arm64 image behind its 64-byte header
  [ "$(od -An -tx4 -N4 "$BOOTTMP/u-boot.img" | tr -d ' ')" = 56190527 ] ||
    { echo "$BOARD_UBOOT_SRC is not a legacy uImage"; exit 1; }
  dd if="$BOOTTMP/u-boot.img" bs=64 skip=1 of="$BOOTTMP/u-boot.ext" 2>/dev/null

  # A first boot from serial teaches the env to boot this stick by itself. try_auto_burn goes: its
  # cold-boot USB gadget makes `usb start` hang. storeboot stays the fallback, so pulling the stick
  # boots Android as before.
  cat > "$BOOTTMP/aml_autoscript.cmd" <<EOF
echo "== $BOARD: chain-loading the Armbian U-Boot =="
if test "\${armbian_autoboot}" != "1"; then
	echo "== $BOARD: teaching bootcmd to find this stick by itself =="
	setenv try_auto_burn
	setenv bootcmd 'usb start 0; if fatload usb 0 $AML_UBOOT_ADDR u-boot.ext; then go $AML_UBOOT_ADDR; fi; run storeboot'
	setenv armbian_autoboot 1
	saveenv
fi
usb start
fatload usb 0 $AML_UBOOT_ADDR u-boot.ext
go $AML_UBOOT_ADDR
EOF
  cat > "$BOOTTMP/boot.cmd" <<EOF
echo "== $BOARD: booting Armbian from \${devtype} \${devnum} =="
part uuid \${devtype} \${devnum}:2 rootuuid
setenv bootargs "root=PARTUUID=\${rootuuid} rootwait rw $SERIALCON net.ifnames=0"
ext4load \${devtype} \${devnum}:2 $AML_KERNEL_ADDR /boot/vmlinuz-$KVER
ext4load \${devtype} \${devnum}:2 $AML_INITRD_ADDR /boot/uInitrd-$KVER
ext4load \${devtype} \${devnum}:2 $AML_UBOOT_ADDR /boot/dtb-$KVER/$FDT
booti $AML_KERNEL_ADDR $AML_INITRD_ADDR $AML_UBOOT_ADDR
EOF
  mkimage -A arm64 -T script -C none -n "$BOARD chainload" \
          -d "$BOOTTMP/aml_autoscript.cmd" "$BOOTTMP/aml_autoscript" >/dev/null
  mkimage -A arm64 -T script -C none -n "$BOARD boot" \
          -d "$BOOTTMP/boot.cmd" "$BOOTTMP/boot.scr" >/dev/null

  FATIMG="$BOOTTMP/boot.fat"
  dd if=/dev/zero of="$FATIMG" bs=512 count=0 seek="$FAT_SECTORS" 2>/dev/null
  mformat -i "$FATIMG" -F -T "$FAT_SECTORS" -v ARMBIAN ::
  mcopy -i "$FATIMG" "$BOOTTMP/u-boot.ext" "$BOOTTMP/aml_autoscript" "$BOOTTMP/boot.scr" ::
  [ "$(wc -c < "$BOOTTMP/u-boot.ext")" -le $((UEXT_SECTORS * 512)) ] ||
    { echo "u-boot.ext is past its $((UEXT_SECTORS / 2)) KiB raw slot"; exit 1; }

  # the eMMC's env: the factory one, booting this image's u-boot.ext, the burning gadget left on.
  # U-Boot parses a bare number as hex, so every sector goes in as 0x.
  UEXT_COUNT=$(( ($(wc -c < "$BOOTTMP/u-boot.ext") + 511) / 512 ))
  python3 "$REPO/scripts/aml-env.py" "$STOCK/factory-env.bin" "$BOOTTMP/env.bin" \
    "bootcmd=run linux_boot; run storeboot" \
    "linux_boot=if amlmmc read $BOARD_AML_MMC_DEV $AML_UBOOT_ADDR $(printf 0x%x "$UEXT_SEEK") $(printf 0x%x "$UEXT_COUNT"); then go $AML_UBOOT_ADDR; fi"
fi

# --- verify we didn't corrupt the rootfs (e2tools writes ext4 without a kernel) --------
# (homebrew keeps e2fsprogs keg-only, so look in its opt prefix too)
FSCK="$(command -v fsck.ext4 || true)"
if [ -z "$FSCK" ]; then
  for c in /opt/homebrew/opt/e2fsprogs/sbin/fsck.ext4 /usr/local/opt/e2fsprogs/sbin/fsck.ext4; do
    if [ -x "$c" ]; then FSCK="$c"; break; fi
  done
fi
if [ -n "$FSCK" ]; then
  echo "      checking filesystem"
  "$FSCK" -fn "$FS" >/dev/null 2>&1 || {
    echo "FILESYSTEM CORRUPT — refusing to ship this image. Run: $FSCK -fn $FS"; exit 1; }
else
  echo "      (no fsck.ext4 found — filesystem NOT verified; brew install e2fsprogs / apt install e2fsprogs)"
fi

detach; ATTACHED=""; sync

# the image is only detached now: writing under an attachment races the host's own cache
if [ -n "$FATIMG" ]; then
  echo "      writing the FAT boot partition @$FAT_SEEK, u-boot.ext @$UEXT_SEEK, env @$ENV_SEEK"
  dd if="$FATIMG" of="$OUT" bs=1048576 seek=$((FAT_SEEK / 2048)) conv=notrunc 2>/dev/null
  dd if="$BOOTTMP/u-boot.ext" of="$OUT" bs=512 seek="$UEXT_SEEK" conv=notrunc 2>/dev/null
  dd if="$BOOTTMP/env.bin" of="$OUT" bs=512 seek="$ENV_SEEK" conv=notrunc 2>/dev/null
  echo "      writing the partition table @$RESERVED_SEEK, device trees @$((RESERVED_SEEK + AML_DTB_OFFSET))"
  dd if="$LAYOUT/mpt.bin" of="$OUT" bs=512 seek="$RESERVED_SEEK" count="$AML_MPT_SECTORS" conv=notrunc 2>/dev/null
  dd if="$LAYOUT/dtb.bin" of="$OUT" bs=512 seek=$((RESERVED_SEEK + AML_DTB_OFFSET)) conv=notrunc 2>/dev/null
  rm -rf "$LAYOUT"
  rm -rf "$BOOTTMP"
fi

echo
echo "Done -> $OUT"
echo "Flash it (with progress):"
echo "  macOS:  diskutil unmountDisk /dev/diskN; sudo gdd if=$OUT of=/dev/rdiskN bs=4M conv=fsync status=progress   (brew install coreutils)"
echo "  Linux:  sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo "  ...or Balena Etcher on either OS."
