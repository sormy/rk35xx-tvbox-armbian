#!/bin/bash
# Print "<ref> <kernel version>" for a kernel/<family>.conf: the ref it builds today, and the version
# that ref's Makefile carries. A conf names exactly one of:
#   FOLLOW=longterm|stable  kernel.org's newest release of that kind
#   BRANCH=<name>           the tip of that branch of REPO; a glob, such as develop-*, picks the
#                           newest matching <prefix><major>.<minor> by version
#   COMMIT=<sha>            that commit
set -euo pipefail
# shellcheck source=/dev/null
. "/repo/$1"
[ "${FOLLOW:+1}${BRANCH:+1}${COMMIT:+1}" = 1 ] ||
  { echo "✗ $1 must name one of FOLLOW, BRANCH or COMMIT" >&2; exit 1; }
if [ -n "${FOLLOW:-}" ]; then
  # releases.json lists each moniker's releases newest first
  version=$(curl -fsSL https://www.kernel.org/releases.json |
    jq -r --arg m "$FOLLOW" 'first(.releases[] | select(.moniker == $m) | .version) // empty') || version=""
  [ -n "$version" ] || { echo "✗ FOLLOW=$FOLLOW: cannot read kernel.org's releases.json" >&2; exit 1; }
  echo "v$version $version"
  exit
fi
if [ -n "${BRANCH:-}" ]; then
  # a glob takes only <prefix><major>.<minor>, so develop-* never picks develop-4.19-rt104
  COMMIT=$(git ls-remote --heads "$REPO" "$BRANCH" | sed 's#refs/heads/##' |
    awk -v b="$BRANCH" -v g="^${BRANCH%\*}[0-9]+[.][0-9]+$" '$2 == b || (b ~ /[*]$/ && $2 ~ g)' |
    sort -k2V | tail -1 | cut -f1)
  [ -n "$COMMIT" ] || { echo "✗ BRANCH=$BRANCH: not in $REPO" >&2; exit 1; }
fi
# the Makefile alone, without fetching the tree: GitHub serves one file of a commit
repo=${REPO#https://github.com/}
version=$(curl -fsSL "https://raw.githubusercontent.com/${repo%.git}/$COMMIT/Makefile" |
  awk -F' = ' '/^VERSION =/ {v=$2} /^PATCHLEVEL =/ {p=$2} /^SUBLEVEL =/ {s=$2} /^EXTRAVERSION =/ {e=$2}
    END {if (v != "") print v "." p "." s e}') || version=""
[ -n "$version" ] || { echo "✗ $1: cannot read the Makefile of $COMMIT" >&2; exit 1; }
echo "$COMMIT $version"
