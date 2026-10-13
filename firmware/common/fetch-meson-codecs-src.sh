#!/usr/bin/env bash
# Stage one meson-sm1-codecs component as DKMS source, patched for the GXLX2 (S905L3).
# The component follows from the target's package name.
#   usage: fetch-meson-codecs-src.sh <src-dir> [kernel-version]
set -e
DIR="${1:?usage: fetch-meson-codecs-src.sh <src-dir> [kernel-version]}"
KVER="${2:-6.18.44}"   # must match the base image's kernel: v4l2-h264.c comes from its source

case "$(basename "$DIR")" in
  meson-vdec-gxlx2-*)  COMP=vdec;      MOD=meson-vdec;  LOC=/kernel/drivers/staging/media/meson/vdec ;;
  amvenc-avc-gxlx2-*)  COMP=venc-h264; MOD=amvenc_avc;  LOC=/kernel/drivers/media/platform/amlogic ;;
  amvenc-hevc-gxlx2-*) COMP=venc-hevc; MOD=amvenc_hevc; LOC=/kernel/drivers/media/platform/amlogic ;;
  *) echo "fetch-meson-codecs-src.sh: no component for $(basename "$DIR")" >&2; exit 1 ;;
esac

SHA=eb7a44464af1c7793f793698e309abe4e6ad82da   # ray38080289/meson-sm1-codecs
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHES="$REPO/patches/meson-codecs"
CACHE="$REPO/build/kernel-tarballs"   # the same cache fetch-mt76-src.sh keeps
mkdir -p "$CACHE"

NEW="$DIR.new"; WORK="$DIR.work"
trap 'rm -rf "$NEW" "$WORK"' EXIT
rm -rf "$NEW" "$WORK"; mkdir -p "$NEW" "$WORK"

SRC="$CACHE/meson-sm1-codecs-$SHA.tar.gz"
if [ ! -s "$SRC" ]; then
  curl -fsSL -o "$SRC.part" "https://github.com/ray38080289/meson-sm1-codecs/archive/$SHA.tar.gz"
  mv -f "$SRC.part" "$SRC"
fi
tar -xzf "$SRC" -C "$WORK" --strip-components=1
for p in "$PATCHES"/*.patch; do
  patch -p1 -d "$WORK" < "$p"
done
cp -a "$WORK/$COMP/." "$NEW/"
rm -f "$NEW"/*_test.c

if [ "$COMP" = vdec ]; then
  TAR="$CACHE/linux-$KVER.tar.xz"
  if [ ! -s "$TAR" ]; then
    curl -fsSL -o "$TAR.part" "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
    mv -f "$TAR.part" "$TAR"
  fi
  tar -xJf "$TAR" -C "$NEW" --strip-components=4 "linux-$KVER/drivers/media/v4l2-core/v4l2-h264.c"
fi

cat > "$NEW/dkms.conf" <<EOF
PACKAGE_NAME="$(basename "$DIR" | sed 's/-[0-9.]*$//')"
PACKAGE_VERSION="$(basename "$DIR" | sed 's/.*-//')"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build CONFIG_VIDEO_MESON_VDEC=m modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="$MOD"
DEST_MODULE_LOCATION[0]="$LOC"
AUTOINSTALL="yes"
EOF

rm -rf "$DIR"; mv "$NEW" "$DIR"
rm -rf "$WORK"
trap - EXIT
