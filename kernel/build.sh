#!/bin/bash
# Build one kernel's .debs from a kernel/<family>.conf, inside the build container.
set -euo pipefail
# shellcheck source=/dev/null  # the conf: REPO, FOLLOW, BRANCH or COMMIT, CONFIG, FRAGMENT, PATCHES
. "/repo/$1"
FAMILY=$(basename "$1" .conf)
TREE=/work/$FAMILY/linux
COMMIT=$(bash /repo/kernel/version.sh "$1" | cut -d" " -f1)
echo "  building $COMMIT"

# TVB_BUILD_CACHE=0: a clean-room build, no reused download, no compiler cache
CACHE=${TVB_BUILD_CACHE:-1}
CC=gcc
if [ "$CACHE" = 1 ]; then
  CC="ccache gcc"
  export CCACHE_DIR=/work/ccache CCACHE_MAXSIZE=${TVB_BUILD_CCACHE_SIZE:-5G}
  # the tree is extracted fresh each run: its files are new, their contents are not
  export CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime
fi
LOGS=/out/logs
mkdir -p "$LOGS" /out/debs

step() {  # step <name> <command...>: output into a log; on failure, the log's tail
  local name=$1 start=$SECONDS
  shift
  if "$@" >"$LOGS/$name.log" 2>&1; then
    echo "✓ $name ($((SECONDS - start))s)"
  else
    echo "✗ $name ($((SECONDS - start))s), log: build/out/logs/$name.log"
    tail -50 "$LOGS/$name.log"
    exit 1
  fi
}

rm -rf "$TREE" && mkdir -p "$TREE" && cd "$TREE"
if [ "$REPO" = https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git ]; then
  ver=${COMMIT#v}
  tarball=/repo/build/kernel-tarballs/linux-$ver.tar.xz
  if [ ! -f "$tarball" ]; then
    tarball=/work/cache/linux-$ver.tar.xz
    mkdir -p /work/cache
    [ "$CACHE" = 1 ] && [ -f "$tarball" ] || {
      step download curl -fsSLo "$tarball.part" "https://cdn.kernel.org/pub/linux/kernel/v${ver%%.*}.x/linux-$ver.tar.xz"
      mv "$tarball.part" "$tarball"
    }
  fi
  step extract tar -xJf "$tarball" --strip-components=1
  epoch=$(stat -c %Y Makefile)
else
  # a bare cache keeps every pinned commit fetched, so a rebuild checks out instead of downloading
  git=/work/cache/$FAMILY.git
  [ -d "$git" ] || git init -q --bare "$git"
  [ "$CACHE" = 1 ] && git -C "$git" cat-file -e "$COMMIT^{commit}" 2>/dev/null ||
    step fetch git -C "$git" fetch -q --depth=1 "$REPO" "$COMMIT"
  step checkout sh -c "git -C '$git' archive '$COMMIT' | tar -x"
  epoch=$(git -C "$git" log -1 --format=%ct "$COMMIT")
fi

n=0
for entry in $PATCHES; do
  n=$((n + 1))
  step "patch-$n" patch -p1 --forward --batch -d "${entry%%:*}" -i "/repo/${entry#*:}"
done

cp "/repo/$CONFIG" .config
# shellcheck disable=SC2086  # FRAGMENT lists its files
step merge-config scripts/kconfig/merge_config.sh -m .config $(printf "/repo/%s " $FRAGMENT)
step olddefconfig make CC="$CC" olddefconfig
while read -r want; do  # olddefconfig silently drops what a dependency forbids
  case $want in
    "# CONFIG_"*" is not set") opt=${want#\# } && ! grep -q "^${opt%% *}=" .config ;;
    CONFIG_*) grep -qxF "$want" .config ;;
  esac || { echo "✗ config: '$want' did not survive olddefconfig"; exit 1; }
done < <(cd /repo && cat $FRAGMENT)
echo "✓ config matches the fragment"

# fixed metadata, so modules come out byte-identical on every host
export SOURCE_DATE_EPOCH=$epoch KBUILD_BUILD_USER=tvbian KBUILD_BUILD_HOST=tvbian
KDEB_CHANGELOG_DIST=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$epoch" '+%Y-%m-%d %H:%M:%S UTC')
KDEB_PKGVERSION=$(make -s kernelversion)-${TVB_BUILD_REVISION:-0~local}
export KBUILD_BUILD_TIMESTAMP KDEB_PKGVERSION KDEB_CHANGELOG_DIST
rm -f ../*.deb
# the plain Image: U-Boot's booti takes it as is, not the Image.gz arm64 installs by default
step bindeb-pkg make -j"${TVB_BUILD_CPUS:-$(nproc)}" CC="$CC" KBUILD_IMAGE=arch/arm64/boot/Image bindeb-pkg
rm ../linux-libc-dev_*.deb   # Debian ships it
cp ../*.deb /out/debs/

KREL=$(make -s kernelrelease)
# the out-of-tree drivers this family carries, built against this tree
depends="linux-image-$KREL (= $KDEB_PKGVERSION)"
for m in /repo/modules/*.conf; do
  (. "$m"; for k in $KERNELS; do [ "$k" = "$FAMILY" ] && exit 0; done; exit 1) || continue
  name=$(basename "$m" .conf)
  step "module-$name" bash /repo/modules/build.sh "modules/$name.conf" "$TREE" "$KREL" "$KDEB_PKGVERSION"
  depends="$depends, tvb-$name-modules-$KREL (= $KDEB_PKGVERSION)"
done

# the metapackage installs the family's newest kernel and its drivers; its X-Tvb-Inputs stands
# for the whole set
META=/work/$FAMILY/meta
rm -rf "$META" && mkdir -p "$META/DEBIAN"
cat >"$META/DEBIAN/control" <<CONTROL
Package: linux-image-tvb-$FAMILY
Version: $KDEB_PKGVERSION
Architecture: arm64
Maintainer: TVBian <archive@tvbian.com>
Depends: $depends
Section: kernel
Priority: optional
X-Tvb-Inputs: $(bash /repo/release/inputs.sh kernel "$1" "$COMMIT")
Description: TVBian's $FAMILY kernel
 Depends on the newest $FAMILY kernel TVBian builds.
CONTROL
dpkg-deb --root-owner-group -Zxz -b "$META" "/out/debs/linux-image-tvb-${FAMILY}_${KDEB_PKGVERSION}_arm64.deb" >/dev/null
[ "$CACHE" = 1 ] && ccache --show-stats | grep -E "Hits|Misses|Cache size" | sed "s/^/  ccache: /"
basename -a ../*.deb; ls /out/debs | grep -E "^(tvb-.*-modules-$KREL|linux-image-tvb-$FAMILY)_"
