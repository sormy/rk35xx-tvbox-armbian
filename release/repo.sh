#!/bin/bash
# Assemble the flat apt repo, inside the build container: the published index, plus this run's new
# debs, signed with /out/signing.key when there is one.
#   repo.sh -> /out/repo: the new debs, Packages, Packages.xz, Release, InRelease, Release.gpg
#              /out/images/SHA256SUMS, signed the same way
set -euo pipefail
REL=/out/release
REPO=/out/repo
rm -rf "$REPO" && mkdir -p "$REPO"

# the new groups' debs; without a plan, a local build, every deb is new
new() {
  local step arg version state
  if [ ! -f "$REL/plan" ]; then find /out/debs -name '*.deb'; return; fi
  while read -r step arg version state; do
    [ "$state" = new ] || continue
    case $step in
      kernel) find /out/debs -name "*_${version}_arm64.deb" ;;
      board) echo "/out/debs/tvb-${arg}_${version}_arm64.deb" ;;
      firmware) echo "/out/debs/tvb-firmware-$(sed -n 's/^FIRMWARE_CHIP=//p' "/repo/firmware/common/$arg/firmware.conf")_${version}_all.deb" ;;
      keyring) echo "/out/debs/tvb-archive-keyring_${version}_all.deb" ;;
    esac
  done <"$REL/plan"
}
new | sort -u | xargs -r cp -t "$REPO"

cd "$REPO"
{
  [ ! -s "$REL/Packages.published" ] || { cat "$REL/Packages.published"; echo; }
  apt-ftparchive packages .
} | cat -s >Packages
xz -k Packages
apt-ftparchive -o APT::FTPArchive::Release::Origin=TVBian -o APT::FTPArchive::Release::Label=TVBian \
  release . >Release

IMAGES=""
if ls /out/images/*.img.xz >/dev/null 2>&1; then
  IMAGES=/out/images
  (cd "$IMAGES" && sha256sum ./*.img.xz | sed 's| \./| |' >SHA256SUMS)
fi

if [ -f /out/signing.key ]; then
  export GNUPGHOME=/work/gnupg
  rm -rf "$GNUPGHOME" && mkdir -m 0700 "$GNUPGHOME"
  gpg -q --batch --import /out/signing.key
  gpg -q --batch --yes --clearsign -o InRelease Release
  gpg -q --batch --yes -abs -o Release.gpg Release
  [ -z "$IMAGES" ] || gpg -q --batch --yes -abs -o "$IMAGES/SHA256SUMS.asc" "$IMAGES/SHA256SUMS"
  echo "✓ signed"
else
  echo "  unsigned: no key given"
fi
echo "✓ repo: $(grep -c '^Package:' Packages) packages, $(find . -name '*.deb' | wc -l) new"
