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

# a pre-release, so never the latest: releases/latest and the README's badge name the newest images
gh release view apt >/dev/null 2>&1 ||
  gh release create apt --prerelease --latest=false --title "apt repository" \
    --notes "TVBian's flat apt repository. Install tvb-archive-keyring, or see the README."
# the debs before the index that names them; the plan fetched the published ones, already there
have=$(gh release view apt --json assets -q '.assets[].name')
debs=$(find "$OUT/repo" -name '*.deb' | while read -r d; do grep -qxF "$(basename "$d")" <<<"$have" || echo "$d"; done)
[ -z "$debs" ] || gh release upload apt $debs
gh release upload apt --clobber "$OUT/repo/Packages" "$OUT/repo/Packages.xz" "$OUT/repo/Contents" \
  "$OUT/repo/Release" "$OUT/repo/InRelease" "$OUT/repo/Release.gpg"
# the repo as a box sees it, before any image points boxes at it
python3 release/verify.py

images=$(find "$OUT/images" -name '*.img.xz' 2>/dev/null)
[ -n "$images" ] || { echo "✓ apt published; no images to release"; exit 0; }
day=$(basename "$(echo "$images" | head -1)" | sed -E 's/.*-([0-9]{4}-[0-9]{2}-[0-9]{2})\.img\.xz$/\1/')
tag=$day n=1
while gh release view "$tag" >/dev/null 2>&1 || git ls-remote --exit-code -q origin "refs/tags/$tag"; do
  n=$((n + 1)) tag=$day.$n
done
# the tag by git, at the commit built: the API refuses a new ref on a commit touching workflows
git tag "$tag" HEAD
git push -q origin "$tag"
gh release create "$tag" --verify-tag --title "TVBian $tag" \
  --notes-file "$OUT/release/notes.md" $images "$OUT/images/SHA256SUMS" "$OUT/images/SHA256SUMS.asc"
echo "✓ published apt and $tag"
