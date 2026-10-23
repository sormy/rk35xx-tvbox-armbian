#!/bin/bash
# Build tvb-base, inside the build container: what every box gets, from base/package.list.
#   base.sh   -> /out/debs/tvb-base_<revision>_all.deb
set -euo pipefail
BASE=/repo/base
VERSION=${TVB_BUILD_REVISION:-0~local}
ROOT=/work/package/base
rm -rf "$ROOT" && mkdir -p "$ROOT/DEBIAN"
bash /repo/package/install-list.sh "$BASE/package.list" "$BASE" "$ROOT"
# under /etc, the owner's edits survive an upgrade
(cd "$ROOT" && find etc -type f | sed 's|^|/|' | sort) >"$ROOT/DEBIAN/conffiles"

cat >"$ROOT/DEBIAN/postinst" <<'SCRIPT'
#!/bin/sh
set -e
# the units this package enables by its .wants links: a running box sees them now
[ ! -d /run/systemd/system ] || systemctl daemon-reload
SCRIPT
chmod 0755 "$ROOT/DEBIAN/postinst"

cat >"$ROOT/DEBIAN/control" <<CONTROL
Package: tvb-base
Version: $VERSION
Architecture: all
Maintainer: TVBian <archive@tvbian.com>
Depends: systemd-zram-generator
Section: admin
Priority: optional
X-Tvb-Inputs: $(bash /repo/release/inputs.sh base)
Description: TVBian's settings for every box
 The watchdog, the journal in RAM, swap in RAM, the console, Wi-Fi, apt and the remote's keymap.
CONTROL
dpkg-deb --root-owner-group -Zxz -b "$ROOT" "/out/debs/tvb-base_${VERSION}_all.deb" >/dev/null
echo "✓ tvb-base_${VERSION}_all.deb"
