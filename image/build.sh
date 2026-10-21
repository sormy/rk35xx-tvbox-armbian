#!/bin/bash
# Build one board's image, inside the build container, from the debs in /out/debs:
#   build.sh <board>   -> /out/images/tvbian-<date>-<board>-<suite>.img.xz
set -euo pipefail
BOARD=$1
FW=/repo/firmware
# shellcheck source=/dev/null
. "$FW/$BOARD/board.conf"
: "${BOARD_FAMILY:?firmware/$BOARD/board.conf names no BOARD_FAMILY}"
# the disk layouts written so far, below; a board of another family waits for its own
case "$BOARD_FAMILY" in meson-gxl) ;; *) echo "– $BOARD: no image layout for $BOARD_FAMILY yet"; exit 0 ;; esac
SUITE=${TVB_BUILD_SUITE:?}
DATE=${TVB_BUILD_DATE:-$(date -u +%F)}
WORK=/work/image/$BOARD
ROOT=$WORK/root
NAME=tvbian-$DATE-$BOARD-$SUITE
rm -rf "$WORK" && mkdir -p "$WORK" /out/images

newest() {  # the newest /out/debs/<package>_*.deb
  local deb
  deb=$(find /out/debs -name "$1_*.deb" | sort -V | tail -1)
  [ -n "$deb" ] || { echo "✗ no $1 in build/out/debs: build it first" >&2; exit 1; }
  echo "$deb"
}
META=$(newest "linux-image-tvb-$BOARD_KERNEL")
DEBS="$META $(newest "tvb-$BOARD") $(newest tvb-archive-keyring)"
# the kernel and its drivers, as the metapackage names them
for k in $(dpkg-deb -f "$META" Depends | tr "," "\n" | sed 's/^ *//; s/ .*//'); do
  DEBS="$DEBS $(newest "$k")"
done
for f in $(dpkg-deb -f "$(newest "tvb-$BOARD")" Depends | tr "," "\n" | sed -n "s/^ *\(tvb-firmware-[a-z0-9]*\).*/\1/p"); do
  DEBS="$DEBS $(newest "$f")"
done

# ---- the rootfs: Debian minbase, the shared list, our debs, the image's settings ----
PACKAGES=$(sed 's/#.*//' /repo/image/packages.list | tr -s ' \n' ',' | sed 's/^,//; s/,$//')
UUID=$(cat /proc/sys/kernel/random/uuid)
# shellcheck disable=SC2016  # the hooks expand $1, the chroot, when mmdebstrap runs them
mmdebstrap --variant=minbase --mode=root --architectures=arm64 \
  --components=main,non-free-firmware --include="$PACKAGES" \
  --customize-hook='cp -a /repo/image/rootfs/. "$1/"' \
  --customize-hook="echo $BOARD_HOSTNAME >\"\$1/etc/hostname\"" \
  --customize-hook="printf '127.0.0.1\tlocalhost\n127.0.1.1\t$BOARD_HOSTNAME\n' >\"\$1/etc/hosts\"" \
  --customize-hook="echo 'UUID=$UUID / ext4 defaults,noatime,x-systemd.growfs 0 1' >\"\$1/etc/fstab\"" \
  --customize-hook="mkdir -p \"\$1/tmp/tvb\" && cp $DEBS \"\$1/tmp/tvb/\"" \
  --customize-hook='chroot "$1" sh -c "apt-get install -y /tmp/tvb/*.deb && rm -r /tmp/tvb"' \
  --customize-hook='echo root:1234 | chroot "$1" chpasswd && chroot "$1" chage -d 0 root' \
  --customize-hook='rm -f "$1"/etc/ssh/ssh_host_*' \
  --customize-hook='rm -f "$1/etc/update-motd.d/10-uname"; : >"$1/etc/motd"' \
  --customize-hook='chroot "$1" update-initramfs -c -k all 2>/dev/null || chroot "$1" update-initramfs -u -k all' \
  --customize-hook='chroot "$1" u-boot-update' \
  --customize-hook=': >"$1/etc/machine-id"; rm -f "$1/var/lib/dbus/machine-id"' \
  "$SUITE" "$ROOT" \
  "deb http://deb.debian.org/debian $SUITE main non-free-firmware" \
  "deb http://deb.debian.org/debian $SUITE-updates main non-free-firmware" \
  "deb http://security.debian.org/debian-security $SUITE-security main non-free-firmware"
grep -q "fdt /usr/lib/tvb/board.dtb" "$ROOT/boot/extlinux/extlinux.conf" ||
  { echo "✗ extlinux.conf names no board tree"; exit 1; }

# a quarter free, so first boot has room before it grows to the medium
ROOT_MIB=$(( $(du -sm "$ROOT" | cut -f1) * 5 / 4 + 256 ))
mkfs.ext4 -q -L tvbian -U "$UUID" -d "$ROOT" "$WORK/root.ext4" "${ROOT_MIB}M"
ROOT_COUNT=$((ROOT_MIB * 2048))
echo "✓ rootfs: $ROOT_MIB MiB"

# ---- the disk ----
bytes() { local b; for b in "$@"; do printf "$(printf '\\%03o' "$b")"; done; }
# one 16-byte MBR entry: boot flag, type, start, count; CHS is the "use LBA" sentinel
mbr_entry() {
  bytes "$1" 254 255 255 "$2" 254 255 255 \
    $(($3 & 255)) $(($3 >> 8 & 255)) $(($3 >> 16 & 255)) $(($3 >> 24 & 255)) \
    $(($4 & 255)) $(($4 >> 8 & 255)) $(($4 >> 16 & 255)) $(($4 >> 24 & 255))
}
IMG=$WORK/$NAME.img

case "$BOARD_FAMILY" in
  meson-gxl)
    # The factory U-Boot stays in the eMMC and chain-loads ours; the image keeps the eMMC's layout,
    # so it boots from a stick and writes to the eMMC unchanged.
    UEXT_SEEK=8192 UEXT_SECTORS=8192 FAT_SEEK=16384 AML_MPT_SECTORS=8 AML_DTB_OFFSET=8192
    AML_TUNING_OFFSET=6144 AML_TUNING_BYTES=131072
    UBOOT_ADDR=0x1000000
    STOCK=/repo/stock/$BOARD
    python3 /repo/scripts/aml-layout.py "$STOCK/factory-mpt.bin" "$STOCK/factory-multidtb.bin" \
      "$BOARD_AML_EMMC_SECTORS" "$WORK/mpt.bin" "$WORK/dtb.bin"
    read -r ENV_SEEK ENV_SECTORS <<<"$(python3 /repo/scripts/aml-mpt.py "$WORK/mpt.bin" env)"
    read -r RESERVED_SEEK _ <<<"$(python3 /repo/scripts/aml-mpt.py "$WORK/mpt.bin" reserved)"
    FAT_SECTORS=$((RESERVED_SEEK - FAT_SEEK))
    ROOT_SEEK=$((ENV_SEEK + ENV_SECTORS))

    cp "$ROOT/usr/lib/tvb/u-boot.bin" "$WORK/u-boot.ext"
    [ "$(stat -c %s "$WORK/u-boot.ext")" -le $((UEXT_SECTORS * 512)) ] ||
      { echo "✗ u-boot.ext is past its $((UEXT_SECTORS / 2)) KiB raw slot"; exit 1; }
    # From a stick, the factory U-Boot runs aml_autoscript off the FAT; the first such boot teaches
    # its env to load u-boot.ext by itself, with storeboot, Android, as the fallback.
    cat >"$WORK/aml_autoscript.cmd" <<EOF
echo "== $BOARD: chain-loading TVBian's U-Boot =="
if test "\${tvb_autoboot}" != "1"; then
	setenv try_auto_burn
	setenv bootcmd 'usb start 0; if fatload usb 0 $UBOOT_ADDR u-boot.ext; then go $UBOOT_ADDR; fi; run storeboot'
	setenv tvb_autoboot 1
	saveenv
fi
usb start
fatload usb 0 $UBOOT_ADDR u-boot.ext
go $UBOOT_ADDR
EOF
    # distro boot scans the bootable FAT only, so boot.scr hands over to the rootfs's extlinux.conf
    cat >"$WORK/boot.cmd" <<EOF
echo "== $BOARD: TVBian from \${devtype} \${devnum} =="
sysboot \${devtype} \${devnum}:2 any \${scriptaddr} /boot/extlinux/extlinux.conf
EOF
    mkimage -A arm64 -T script -C none -n "$BOARD chainload" -d "$WORK/aml_autoscript.cmd" "$WORK/aml_autoscript" >/dev/null
    mkimage -A arm64 -T script -C none -n "$BOARD boot" -d "$WORK/boot.cmd" "$WORK/boot.scr" >/dev/null
    truncate -s $((FAT_SECTORS * 512)) "$WORK/boot.fat"
    mformat -i "$WORK/boot.fat" -F -T "$FAT_SECTORS" -v TVBIAN ::
    mcopy -i "$WORK/boot.fat" "$WORK/u-boot.ext" "$WORK/aml_autoscript" "$WORK/boot.scr" ::
    # the eMMC's env: the factory one, booting the u-boot.ext beside it; a bare number is hex
    UEXT_COUNT=$((($(stat -c %s "$WORK/u-boot.ext") + 511) / 512))
    python3 /repo/scripts/aml-env.py "$STOCK/factory-env.bin" "$WORK/env.bin" \
      "bootcmd=run linux_boot; run storeboot" \
      "linux_boot=if amlmmc read $BOARD_AML_MMC_DEV $UBOOT_ADDR $(printf 0x%x $UEXT_SEEK) $(printf 0x%x $UEXT_COUNT); then go $UBOOT_ADDR; fi"

    truncate -s $(((ROOT_SEEK + ROOT_COUNT) * 512)) "$IMG"
    { mbr_entry 128 12 "$FAT_SEEK" "$FAT_SECTORS"; mbr_entry 0 131 "$ROOT_SEEK" "$ROOT_COUNT"; } |
      dd of="$IMG" bs=1 seek=446 conv=notrunc status=none
    bytes 85 170 | dd of="$IMG" bs=1 seek=510 conv=notrunc status=none
    dd if="$WORK/boot.fat" of="$IMG" bs=512 seek="$FAT_SEEK" conv=notrunc status=none
    dd if="$WORK/u-boot.ext" of="$IMG" bs=512 seek="$UEXT_SEEK" conv=notrunc status=none
    dd if="$WORK/env.bin" of="$IMG" bs=512 seek="$ENV_SEEK" conv=notrunc status=none
    dd if="$WORK/mpt.bin" of="$IMG" bs=512 seek="$RESERVED_SEEK" count="$AML_MPT_SECTORS" conv=notrunc status=none
    dd if="$WORK/dtb.bin" of="$IMG" bs=512 seek=$((RESERVED_SEEK + AML_DTB_OFFSET)) conv=notrunc status=none
    dd if="$WORK/root.ext4" of="$IMG" bs=1M seek=$((ROOT_SEEK / 2048)) conv=notrunc status=none
    # the rest of the eMMC's layout, so tvb-install copies a whole disk: the factory bootloader past
    # the MBR, and reserved's eMMC tuning pattern
    dd if="$STOCK/bootloader.bin" of="$IMG" bs=512 skip=1 seek=1 count=$((UEXT_SEEK - 1)) conv=notrunc status=none
    python3 -c "import sys; sys.stdout.buffer.write(b'\xaa\x55' * ($AML_TUNING_BYTES // 2))" |
      dd of="$IMG" bs=512 seek=$((RESERVED_SEEK + AML_TUNING_OFFSET)) conv=notrunc status=none
    ;;
esac

xz -T0 -6 -c "$IMG" >"/out/images/$NAME.img.xz"
rm -rf "$WORK"
echo "✓ $NAME.img.xz: $(du -m "/out/images/$NAME.img.xz" | cut -f1) MiB"
