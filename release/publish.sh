#!/bin/bash
# Upload what ./build.sh release built, on the host, with gh: the new debs and the index to the
# rolling `apt` release, the images to a new release named by the day.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/out
command -v gh >/dev/null || { echo "✗ publish needs gh: brew install gh, or apt install gh" >&2; exit 1; }
[ -f "$OUT/repo/InRelease" ] || { echo "✗ no signed repo in $OUT/repo: ./build.sh release --key <file> first" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "✗ the tree is dirty: a release names its commit" >&2; exit 1; }
git fetch -q origin
git merge-base --is-ancestor HEAD "origin/$(git rev-parse --abbrev-ref HEAD)" ||
  { echo "✗ HEAD is not pushed: a release names a commit others can see" >&2; exit 1; }

gh release view apt >/dev/null 2>&1 ||
  gh release create apt --prerelease --title "apt repository" \
    --notes "TVBian's flat apt repository. Install tvb-archive-keyring, or see the README."
# the debs before the index that names them
debs=$(find "$OUT/repo" -name '*.deb')
[ -z "$debs" ] || gh release upload apt $debs
gh release upload apt --clobber "$OUT/repo/Packages" "$OUT/repo/Packages.xz" \
  "$OUT/repo/Release" "$OUT/repo/InRelease" "$OUT/repo/Release.gpg"

images=$(find "$OUT/images" -name '*.img.xz' 2>/dev/null)
[ -n "$images" ] || { echo "✓ apt published; no images to release"; exit 0; }
day=$(basename "$(echo "$images" | head -1)" | cut -d- -f2-4)
tag=$day n=1
while gh release view "$tag" >/dev/null 2>&1; do n=$((n + 1)) tag=$day.$n; done
gh release create "$tag" --target "$(git rev-parse HEAD)" --title "TVBian $tag" \
  --notes-file "$OUT/release/notes.md" $images "$OUT/images/SHA256SUMS" "$OUT/images/SHA256SUMS.asc"
echo "✓ published apt and $tag"
