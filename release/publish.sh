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

APT=${TVB_APT_URL:-https://github.com/sormy/tvbian/releases/download/apt}
# indexed <Packages>: the deb files it names
indexed() { sed -n 's|^Filename: \(\./\)\{0,1\}||p' "$1"; }
# assets <names>: delete every .deb asset the names leave out
prune() {
  local asset
  for asset in $(gh release view apt --json assets -q '.assets[].name' | grep '\.deb$'); do
    grep -qxF "$asset" <<<"$1" || gh release delete-asset apt "$asset" --yes
  done
}

# a pre-release, so never the latest: releases/latest and the README's badge name the newest images
gh release view apt >/dev/null 2>&1 ||
  gh release create apt --prerelease --latest=false --title "apt repository" \
    --notes "TVBian's flat apt repository. Install tvb-archive-keyring, or see the README."
# one publisher at a time: CI's concurrency group covers its own runs, not a Mac's beside them
running=$(gh run list --workflow release.yml --status in_progress --json databaseId -q '.[].databaseId')
[ -n "${GITHUB_ACTIONS:-}" ] || [ -z "$running" ] ||
  { echo "✗ a release workflow run is in progress: publish after it" >&2; exit 1; }
# the index this run was planned against must still be the live one: expiry deletes what it omits
live=$(mktemp); trap 'rm -f "$live"' EXIT
curl -fsSL "$APT/Packages" -o "$live" 2>/dev/null || : >"$live"
cmp -s "$live" "$OUT/release/Packages.published" ||
  { echo "✗ $APT/Packages changed since this run's plan: plan again" >&2; exit 1; }
# a deb the live index does not name is a failed run's, maybe with other bytes under the same name
prune "$(indexed "$live")"
# the debs before the index that names them; the plan fetched the published ones, already there
have=$(gh release view apt --json assets -q '.assets[].name')
debs=$(find "$OUT/repo" -name '*.deb' | while read -r d; do grep -qxF "$(basename "$d")" <<<"$have" || echo "$d"; done)
[ -z "$debs" ] || gh release upload apt $debs
gh release upload apt --clobber "$OUT/repo/Packages" "$OUT/repo/Packages.xz" "$OUT/repo/Contents" \
  "$OUT/repo/Release" "$OUT/repo/InRelease" "$OUT/repo/Release.gpg"
# the repo as a box sees it, before any image points boxes at it or any expired deb goes
python3 release/verify.py
# the debs the new index no longer names have expired, release/expire.py says how
names=$(indexed "$OUT/repo/Packages")
[ -n "$names" ] || { echo "✗ the new index names no deb: deleting nothing" >&2; exit 1; }
prune "$names"

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
