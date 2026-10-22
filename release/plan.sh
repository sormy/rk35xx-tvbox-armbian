#!/bin/bash
# Decide each package group's version against the published apt index, inside the build container.
#   plan.sh -> /out/release/plan: "<step> <argument> <version> new|published", one group a line
# A group whose X-Tvb-Inputs matches a published deb is not rebuilt: its debs are fetched instead.
set -euo pipefail
cd /repo
APT=${TVB_APT_URL:-https://github.com/sormy/tvbian/releases/download/apt}
REL=/out/release
mkdir -p "$REL" /out/debs
rm -f "$REL/plan"
curl -fsSL "$APT/Packages" -o "$REL/Packages.published" 2>/dev/null || : >"$REL/Packages.published"
curl -fsSL "$APT/Contents" -o "$REL/Contents.published" 2>/dev/null || : >"$REL/Contents.published"

field() {  # field <package> <name> [inputs]: that field of the package's stanza, by inputs if given
  awk -v RS= -v p="$1" -v f="$2" -v i="${3:-}" '
    $0 ~ "(^|\n)Package: " p "\n" && (i == "" || $0 ~ "\nX-Tvb-Inputs: " i "(\n|$)") {
      n = split($0, l, "\n"); for (k = 1; k <= n; k++) if (index(l[k], f ": ") == 1) print substr(l[k], length(f) + 3)
    }' "$REL/Packages.published"
}
fetch() {  # fetch <package> <version>: its published deb, into /out/debs
  local file
  file=$(awk -v RS= -v p="$1" -v v="$2" '$0 ~ "(^|\n)Package: " p "\n" && $0 ~ "\nVersion: " v "\n"' \
    "$REL/Packages.published" | sed -n 's|^Filename: \(\./\)\{0,1\}||p')
  curl -fsSL "$APT/$file" -o "/out/debs/$file"
}
# plan <step> <argument> <package> <inputs> <upstream>: the next version counts revisions per upstream
plan() {
  local had next
  had=$(field "$3" Version "$4" | head -1)
  if [ -n "$had" ]; then
    echo "$1 $2 $had published" >>"$REL/plan"
    fetch "$3" "$had"
    if [ "$1" = kernel ]; then
      for dep in $(field "$3" Depends "$4" | head -1 | tr ',' '\n' | sed 's/^ *//; s/ .*//'); do
        fetch "$dep" "$had"
        # the headers, which nothing depends on, are as much the kernel's
        case $dep in linux-image-*) fetch "linux-headers-${dep#linux-image-}" "$had" ;; esac
      done
    fi
    return
  fi
  next=$(field "$3" Version | sed -n "s/^${5:+$5-}\([0-9]*\)$/\1/p" | sort -n | tail -1)
  echo "$1 $2 ${5:+$5-}$((${next:-0} + 1)) new" >>"$REL/plan"
}

for conf in kernel/*.conf; do
  ref=$(bash kernel/version.sh "$conf")
  plan kernel "$conf" "linux-image-tvb-$(basename "$conf" .conf)" \
    "$(bash release/inputs.sh kernel "$conf" "${ref% *}")" "${ref#* }"
done
for c in firmware/*/board.conf; do
  b=$(basename "$(dirname "$c")")
  k=$(sed -n 's/^BOARD_KERNEL=//p' "$c")
  [ -n "$k" ] && [ -f "kernel/$k.conf" ] || continue
  plan board "$b" "tvb-$b" "$(bash release/inputs.sh board "$b")"
done
for c in firmware/common/*/firmware.conf; do
  d=$(basename "$(dirname "$c")")
  plan firmware "$d" "tvb-firmware-$(sed -n 's/^FIRMWARE_CHIP=//p' "$c")" "$(bash release/inputs.sh firmware "$d")"
done
plan keyring - tvb-archive-keyring "$(bash release/inputs.sh keyring)"
cat "$REL/plan"
