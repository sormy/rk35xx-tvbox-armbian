#!/bin/bash
# Fail the release when a path changes package unannounced, inside the build container: apt aborts an
# upgrade on "trying to overwrite" unless the new owner Replaces and Breaks the old. A package it
# Conflicts with, by name or by a virtual it Provides, never shares a box: one board's with another's.
#   guard.sh: every deb in /out/debs against /out/release/Contents.published
set -euo pipefail
REL=/out/release
[ -s "$REL/Contents.published" ] || { echo "✓ nothing published to move from"; exit 0; }

names() { tr ',' '\n' | sed 's/^ *//; s/[ (].*//' | sed '/^$/d'; }
# provides <package>: its published Provides
provides() { awk -v RS= -v p="$1" '$0 ~ "(^|\n)Package: " p "\n"' "$REL/Packages.published" |
  sed -n 's/^Provides: //p' | names; }

# a deb the published index already names moved nothing this run: its move was released before
published=$(sed -n 's|^Filename: \(\./\)\{0,1\}||p' "$REL/Packages.published")
fail=0
for deb in /out/debs/*.deb; do
  grep -qxF "$(basename "$deb")" <<<"$published" && continue
  pkg=$(dpkg-deb -f "$deb" Package)
  conflicts=$(dpkg-deb -f "$deb" Conflicts | names)
  dpkg-deb -c "$deb" | awk '$1 !~ /^d/ { sub(/^\.\//, "", $6); print $6 }' >"$REL/paths"
  # the published owners of this deb's paths, other than itself
  owners=$(awk -v self="$pkg" '
    NR == FNR { mine[$1]; next }
    $1 in mine { n = split($NF, o, ","); for (i = 1; i <= n; i++) { sub(/.*\//, "", o[i]); if (o[i] != self) print o[i] } }
  ' "$REL/paths" "$REL/Contents.published" | sort -u)
  for old in $owners; do
    { echo "$old"; provides "$old"; } | grep -qxF -f - <(echo "$conflicts") && continue
    for field in Replaces Breaks; do
      dpkg-deb -f "$deb" "$field" | names | grep -qx "$old" ||
        { echo "✗ $pkg takes paths from $old, and does not $field it" >&2; fail=1; }
    done
  done
done
rm -f "$REL/paths"
[ "$fail" = 0 ] && echo "✓ no path changes package unannounced"
exit "$fail"
