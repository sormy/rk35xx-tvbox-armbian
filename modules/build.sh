#!/bin/bash
# Build one out-of-tree driver against a kernel tree just built, inside the build container:
#   build.sh <modules/*.conf> <kernel tree> <kernelrelease> <version>
#     -> /out/debs/tvb-<name>-modules-<kernelrelease>_<version>_arm64.deb
# A vendor driver with no road upstream is built beside the kernel, not imported into it.
set -euo pipefail
CONF=$1 TREE=$2 KREL=$3 VERSION=$4
# shellcheck source=/dev/null  # REPO, COMMIT, SUBDIRS, PATCHES, MAKE_ARGS
. "/repo/$CONF"
NAME=$(basename "$CONF" .conf)
CACHE=/work/cache/modules/$NAME
# per kernel, so two kernels' builds of one driver never share a tree
SRC=/work/modules/$NAME-$KREL
ROOT=/work/package/modules-$NAME-$KREL

# blob-less: a driver can be one directory of a kernel-sized repository, and archive fetches only
# the blobs under SUBDIRS
[ -d "$CACHE" ] || git init -q --bare "$CACHE"
# by URL, not a stored remote, so a driver that moves to another repository fetches from it
git -C "$CACHE" cat-file -e "$COMMIT^{commit}" 2>/dev/null ||
  git -C "$CACHE" fetch -q --depth=1 --filter=blob:none "$REPO" "$COMMIT"
# shellcheck disable=SC2086  # one path per word
rm -rf "$SRC" && mkdir -p "$SRC" && git -C "$CACHE" archive "$COMMIT" ${SUBDIRS:-} | tar -x -C "$SRC"

for entry in ${PATCHES:-}; do
  patch -s -p1 --forward --batch -d "$SRC/${entry%%:*}" -i "/repo/${entry#*:}"
done

rm -rf "$ROOT" && mkdir -p "$ROOT/DEBIAN"
for dir in ${SUBDIRS:-.}; do
  # shellcheck disable=SC2086  # MAKE_ARGS is a list of assignments
  make -s -C "$TREE" M="$SRC/$dir" -j"${TVB_BUILD_CPUS:-$(nproc)}" ${MAKE_ARGS:-} modules
  find "$SRC/$dir" -name '*.ko' -exec install -D -m 0644 -t "$ROOT/usr/lib/modules/$KREL/updates/tvb-$NAME" {} +
done

# the kernel may already be gone when its drivers are removed: then there is nothing to depmod
for script in postinst postrm; do
  printf '#!/bin/sh\nset -e\n[ ! -d /usr/lib/modules/%s/kernel ] || depmod -a %s\n' "$KREL" "$KREL" >"$ROOT/DEBIAN/$script"
  chmod 0755 "$ROOT/DEBIAN/$script"
done
cat >"$ROOT/DEBIAN/control" <<CONTROL
Package: tvb-$NAME-modules-$KREL
Version: $VERSION
Architecture: arm64
Maintainer: TVBian <archive@tvbian.com>
Depends: linux-image-$KREL (= $VERSION)
Section: kernel
Priority: optional
Description: TVBian's $NAME driver for Linux $KREL
 Built from ${REPO##*/} at ${COMMIT:0:12} against the kernel it depends on.
CONTROL
dpkg-deb --root-owner-group -Zxz -b "$ROOT" "/out/debs/tvb-$NAME-modules-${KREL}_${VERSION}_arm64.deb" >/dev/null
echo "✓ tvb-$NAME-modules-$KREL: $(find "$ROOT" -name '*.ko' | wc -l) modules"
