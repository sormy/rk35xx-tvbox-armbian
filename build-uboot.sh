#!/usr/bin/env bash
# Build each board's uboot.itb into firmware/<board>/, from pinned mainline U-Boot + ATF.
# The control DT lives inside the FIT, so a per-board tree means a per-board FIT.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BUILD="$REPO/uboot-build"                         # scratch (gitignored): the clones + one tree per board
FW="$REPO/firmware"
PATCHES="$REPO/patches/u-boot"

# --- pinned dependencies (bump deliberately, never float) ---
UBOOT_REPO="https://github.com/u-boot/u-boot.git"
UBOOT_TAG="v2026.04"                              # mainline release; boots Armbian via distro_bootcmd
RKBIN_REPO="https://github.com/rockchip-linux/rkbin.git"
RKBIN_SHA="ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4"
BL31="bin/rk35/rk3528_bl31_v1.21.elf"            # ATF (EL3 secure monitor); recognizes RK3518
TPL="bin/rk35/rk3528_ddr_1056MHz_v1.13.bin"      # mainline binman needs a TPL to assemble its image; the FIT we extract is TPL-independent
BASE_DEFCONFIG="generic-rk3528_defconfig"        # ours is this, plus the board DT and the ADC

# Default to the boards whose board.conf installs a FIT of their own. Naming a board explicitly
# still builds it — that is how a per-board loader gets tried before it is wired up.
boards() {
  for c in "$FW"/*/board.conf; do
    b=$(basename "$(dirname "$c")")
    grep -qE "^BOARD_UBOOT=\"?$b/uboot\.itb\"?[[:space:]]*(#.*)?\$" "$c" && echo "$b"
  done
  return 0   # the last board need not be one of them, and set -e would take that as failure
}
BOARDS="${*:-$(boards)}"
[ -n "$BOARDS" ] ||
  { echo "no board ships its own uboot.itb — name a board"; exit 1; }

MAKE=make
if [ "$(uname -s)" = Darwin ]; then
  command -v brew >/dev/null || { echo "Homebrew needed — https://brew.sh"; exit 1; }
  missing=
  for f in aarch64-elf-gcc make coreutils openssl@3 swig; do
    brew list --versions "$f" >/dev/null 2>&1 || missing="$missing $f"
  done
  [ -z "$missing" ] || { echo "Missing build tools — run: brew install$missing"; exit 1; }

  # Kbuild wants make 4.x and nproc; macOS ships make 3.81 and neither
  PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"
  MAKE=gmake
  : "${CROSS_COMPILE:=aarch64-elf-}"   # bare metal: U-Boot links no libc, so no glibc toolchain
  # openssl is keg-only, and the host tools reach <openssl/evp.h> from objects pkg-config never sees
  SSL="$(brew --prefix openssl@3)"
  export PKG_CONFIG_PATH="$SSL/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export HOSTCFLAGS="-I$SSL/include${HOSTCFLAGS:+ $HOSTCFLAGS}"
  export HOSTLDFLAGS="-L$SSL/lib${HOSTLDFLAGS:+ $HOSTLDFLAGS}"
  # binman imports pyelftools, and pylibfdt's setup.py imports setuptools, which a venv no longer
  # ships by default; keep both off the system python
  VENV="$BUILD/hostvenv"
  mkdir -p "$BUILD"
  [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
  "$VENV/bin/python" -c 'import elftools, setuptools' 2>/dev/null ||
    "$VENV/bin/pip" -q install pyelftools setuptools
  PATH="$VENV/bin:$PATH"
else
  # native gcc on arm64, cross prefix otherwise
  if [ "$(uname -m)" = aarch64 ] && ! command -v aarch64-linux-gnu-gcc >/dev/null; then
    : "${CROSS_COMPILE:=}"; else : "${CROSS_COMPILE:=aarch64-linux-gnu-}"; fi
fi
export PATH CROSS_COMPILE ARCH=arm64
command -v "${CROSS_COMPILE}gcc" >/dev/null || { echo "Missing ${CROSS_COMPILE}gcc toolchain"; exit 1; }

for b in $BOARDS; do
  [ -f "$FW/$b/uboot.dts" ] ||
    { echo "No firmware/$b/uboot.dts — generate it first: ./build-uboot-dts.sh $b"; exit 1; }
done

mkdir -p "$BUILD"; cd "$BUILD"

# rkbin pinned to an exact commit (GitHub serves a bare SHA via fetch)
if [ ! -e "rkbin/$BL31" ]; then
  rm -rf rkbin && mkdir rkbin && ( cd rkbin
    git init -q
    git fetch -q --depth 1 "$RKBIN_REPO" "$RKBIN_SHA" && git checkout -q FETCH_HEAD )
fi

# mainline u-boot pinned to a release tag
[ -d u-boot ] || git clone -q --depth 1 -b "$UBOOT_TAG" "$UBOOT_REPO" u-boot
# the clone is reused across runs, so a bumped tag would otherwise rebuild the previous tree
[ "$(git -C u-boot describe --tags --exact-match 2>/dev/null)" = "$UBOOT_TAG" ] ||
  { echo "uboot-build/u-boot is not at $UBOOT_TAG - remove it and re-run"; exit 1; }

# U-Boot's pylibfdt build assumes Linux and a swig older than 4.3; these make it build on macOS
git -C u-boot checkout --quiet --force   # a rebuild must not stack patches on the last run's
git -C u-boot clean -qfd
for p in "$PATCHES"/*.patch; do
  echo "  PATCH $(basename "$p")"
  git -C u-boot apply "$p" || { echo "patch did not apply — u-boot $UBOOT_TAG may have moved"; exit 1; }
done

cd u-boot
# each board builds out-of-tree, and Kbuild refuses that while in-tree artifacts remain
[ -e .config ] && $MAKE mrproper >/dev/null

for BOARD in $BOARDS; do
  # The FIT embeds a timestamp: pin it to the source it is built from, or a pre-push check cannot
  # tell drift from noise.
  SRC="$FW/$BOARD/uboot.dts"
  SOURCE_DATE_EPOCH=$(git -C "$REPO" log -1 --format=%ct -- "$SRC" 2>/dev/null || true)
  if [ -z "$SOURCE_DATE_EPOCH" ]; then
    # An uncommitted tree has no commit date. mtime holds this checkout steady, but nobody else can
    # reproduce it, and committing the tree moves the stamp — rebuild once more after that commit.
    echo "   $BOARD/uboot.dts is uncommitted: stamping from mtime, rebuild once it is committed"
    # stat differs between GNU and BSD
    SOURCE_DATE_EPOCH=$(stat -c %Y "$SRC" 2>/dev/null || stat -f %m "$SRC" 2>/dev/null || echo 0)
  fi
  export SOURCE_DATE_EPOCH

  DT="rk3528-$BOARD"
  cp "$FW/$BOARD/uboot.dts" "arch/arm/dts/$DT.dts"
  # "-u-boot.dtsi" is the name upstream's Makefile globs for, so it keeps the dash. Binman only:
  # rk3528-u-boot.dtsi patches upstream labels a stock-derived tree has none of, and the phase tags
  # it would add are already in ours, translated from the vendor's.
  # binman, plus the one node rk3528-u-boot.dtsi uniquely provides: dram_init() needs a UCLASS_RAM
  # device and only the dmc node binds one. The factory tree has none - vendor U-Boot takes the DRAM
  # size from the TPL instead - so without this U-Boot halts at "initcall dram_init() failed".
  cat > "arch/arm/dts/$DT-u-boot.dtsi" <<'DTSI'
#include "rockchip-u-boot.dtsi"

/ {
	dmc {
		compatible = "rockchip,rk3528-dmc";
		bootph-all;
	};

	/* misc_init_r() -> rockchip_cpuid_from_efuse() needs this; the factory tree has only the
	 * vendor's secure-otp@ffcd0000, which mainline has no driver for */
	nvmem@ffce0000 {
		compatible = "rockchip,rk3528-otp";
		reg = <0x0 0xffce0000 0x0 0x4000>;
		bootph-some-ram;
	};
};
DTSI

  # the generic defconfig, retargeted at our tree and with the SARADC turned on: the recovery
  # button is read through it, and mainline ships the symbol off
  sed -e "s|\"rk3528-generic\"|\"$DT\"|" \
      -e "s|rockchip/rk3528-generic.dtb|rockchip/$DT.dtb|" \
      -e "s|^# CONFIG_ADC is not set\$|CONFIG_ADC=y\nCONFIG_SARADC_ROCKCHIP=y|" \
      "configs/$BASE_DEFCONFIG" > "configs/$BOARD-rk3528_defconfig"
  grep -q '^CONFIG_ADC=y' "configs/$BOARD-rk3528_defconfig" ||
    { echo "$BASE_DEFCONFIG no longer disables ADC the way we patch it — fix the sed"; exit 1; }

  O="$BUILD/out-$BOARD"
  $MAKE O="$O" "$BOARD-rk3528_defconfig" >/dev/null
  grep -q '^CONFIG_SARADC_ROCKCHIP=y' "$O/.config" ||
    { echo "SARADC dropped by Kconfig for $BOARD"; exit 1; }
  # the DT sed is the load-bearing one: unguarded, an upstream rename ships a board FIT built
  # against rk3528-generic — generic eMMC timing, and adc@ instead of saradc@ so the button dies
  grep -q "^CONFIG_DEFAULT_DEVICE_TREE=\"$DT\"" "$O/.config" ||
    { echo "$BASE_DEFCONFIG no longer names its DT the way we patch it — fix the sed"; exit 1; }
  $MAKE O="$O" -j"$(nproc)" BL31="$BUILD/rkbin/$BL31" ROCKCHIP_TPL="$BUILD/rkbin/$TPL"  # binman emits u-boot.itb (FIT: ATF + u-boot)
  cp "$O/u-boot.itb" "$FW/$BOARD/uboot.itb"                                          # ship only this FIT; the built idbloader is discarded
  # the clone is pinned and reused, so take the generated inputs back out: a renamed or dropped
  # board would otherwise leave a stale defconfig and DTS that a later run could build against
  rm -f "configs/$BOARD-rk3528_defconfig" "arch/arm/dts/rk3528-$BOARD.dts" \
        "arch/arm/dts/rk3528-$BOARD-u-boot.dtsi"
  echo "-> firmware/$BOARD/uboot.itb ($(wc -c < "$FW/$BOARD/uboot.itb") bytes)"
done

echo "mainline U-Boot $UBOOT_TAG — baked into each image by build-image.sh."
