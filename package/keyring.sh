#!/bin/bash
# Build tvb-archive-keyring, inside the build container: the repo's signing key and its apt source.
set -euo pipefail
VERSION=${TVB_BUILD_REVISION:-0~local}
ROOT=/work/package/keyring
rm -rf "$ROOT" && mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/share/keyrings" "$ROOT/etc/apt/sources.list.d"
cp /repo/keyring/tvb-archive-keyring.gpg "$ROOT/usr/share/keyrings/"
cat >"$ROOT/etc/apt/sources.list.d/tvbian.sources" <<'SOURCES'
Types: deb
URIs: https://github.com/sormy/tvbian/releases/download/apt/
Suites: ./
Signed-By: /usr/share/keyrings/tvb-archive-keyring.gpg
SOURCES
echo /etc/apt/sources.list.d/tvbian.sources >"$ROOT/DEBIAN/conffiles"
cat >"$ROOT/DEBIAN/control" <<CONTROL
Package: tvb-archive-keyring
Version: $VERSION
Architecture: all
Maintainer: TVBian <archive@tvbian.com>
Section: misc
Priority: optional
X-Tvb-Inputs: $(bash /repo/release/inputs.sh keyring)
Description: TVBian archive signing key and apt source
 The key that signs TVBian's apt repository, and the source that names it.
CONTROL
dpkg-deb --root-owner-group -Zxz -b "$ROOT" "/out/debs/tvb-archive-keyring_${VERSION}_all.deb" >/dev/null
echo "✓ tvb-archive-keyring_${VERSION}_all.deb"
