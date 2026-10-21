#!/bin/bash
# Fail the release when a path changes package unannounced, inside the build container: apt aborts an
# upgrade on "trying to overwrite" unless the new owner Replaces and Breaks the old.
#   guard.sh: every deb in /out/debs against /out/release/Contents.published
set -euo pipefail
REL=/out/release
[ -s "$REL/Contents.published" ] || { echo "✓ nothing published to move from"; exit 0; }

fail=0
for deb in /out/debs/*.deb; do
  pkg=$(dpkg-deb -f "$deb" Package)
  dpkg-deb -c "$deb" | awk '$1 !~ /^d/ { sub(/^\.\//, "", $6); print $6 }' >"$REL/paths"
  # the published owners of this deb's paths, other than itself
  owners=$(awk -v self="$pkg" '
    NR == FNR { mine[$1]; next }
    $1 in mine { n = split($NF, o, ","); for (i = 1; i <= n; i++) { sub(/.*\//, "", o[i]); if (o[i] != self) print o[i] } }
  ' "$REL/paths" "$REL/Contents.published" | sort -u)
  for old in $owners; do
    for field in Replaces Breaks; do
      dpkg-deb -f "$deb" "$field" | tr ',' '\n' | sed 's/^ *//; s/[ (].*//' | grep -qx "$old" ||
        { echo "✗ $pkg takes paths from $old, and does not $field it" >&2; fail=1; }
    done
  done
done
rm -f "$REL/paths"
[ "$fail" = 0 ] && echo "✓ no path changes package unannounced"
exit "$fail"
