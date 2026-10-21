#!/bin/bash
# Build one U-Boot from a uboot/<target>.conf, inside the build container: /out/uboot/<target>/u-boot.bin
set -euo pipefail
# shellcheck source=/dev/null  # the conf: REPO, TAG, DEFCONFIG, CONFIGS
. "/repo/$1"
TARGET=$(basename "$1" .conf)
TREE=/work/uboot/$TARGET
OUT=/out/uboot/$TARGET

rm -rf "$TREE" && mkdir -p "$TREE" "$OUT" && cd "$TREE"
git init -q && git fetch -q --depth=1 "$REPO" "refs/tags/$TAG" && git checkout -q FETCH_HEAD
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
export SOURCE_DATE_EPOCH
rm -rf .git   # a git checkout suffixes the version: 2026.10+, or -g<hash>
make -s "$DEFCONFIG"
for c in ${CONFIGS:-}; do scripts/config --set-val "${c%%=*}" "${c#*=}"; done
make -s olddefconfig
make -s -j"${TVB_BUILD_CPUS:-$(nproc)}" u-boot.bin
cp u-boot.bin "$OUT/"
echo "✓ $TARGET $TAG: $(stat -c %s "$OUT/u-boot.bin") bytes"
