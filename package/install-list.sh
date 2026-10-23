#!/bin/bash
# Install a package.list under a root, inside the build container.
#   install-list.sh <package.list> <source dir> <root>
# A line is "<mode> <src> <dest>", src under the source dir, or "link <target> <dest>" for a symlink;
# a # starts a comment, read as release/inputs.sh reads it.
set -euo pipefail
LIST=$1 SRC=$2 ROOT=$3
sed -E 's/#.*//' "$LIST" | while read -r mode src dest || [ -n "$mode" ]; do
  case "$mode" in
    '') ;;
    link)
      mkdir -p "$(dirname "$ROOT$dest")"
      ln -s "$src" "$ROOT$dest"
      ;;
    *) install -D -m "$mode" "$SRC/$src" "$ROOT$dest" ;;
  esac
done
