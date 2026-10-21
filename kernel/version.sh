#!/bin/bash
# Print the upstream ref a kernel/<family>.conf builds: its COMMIT, or what FOLLOW resolves to today:
# longterm, kernel.org's newest long-term release; stable, its newest stable one.
set -euo pipefail
# shellcheck source=/dev/null
. "/repo/$1"
[ -n "${FOLLOW:-}" ] && [ -n "${COMMIT:-}" ] && { echo "✗ $1 sets both FOLLOW and COMMIT: one or the other" >&2; exit 1; }
if [ -n "${FOLLOW:-}" ]; then
  # releases.json lists each moniker's releases newest first
  newest=$(curl -fsSL https://www.kernel.org/releases.json | FOLLOW=$FOLLOW python3 -c 'import json, os, sys
print(next(r["version"] for r in json.load(sys.stdin)["releases"] if r["moniker"] == os.environ["FOLLOW"]))') ||
    newest=""
  [ -n "$newest" ] || { echo "✗ FOLLOW=$FOLLOW: cannot read kernel.org's releases.json" >&2; exit 1; }
  COMMIT=v$newest
fi
[ -n "${COMMIT:-}" ] || { echo "✗ $1 names neither FOLLOW nor COMMIT" >&2; exit 1; }
echo "$COMMIT"
