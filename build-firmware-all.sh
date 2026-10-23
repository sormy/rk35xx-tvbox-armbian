#!/usr/bin/env bash
# Rebuild every board's boards/ artifacts, then say whether any moved.
#
# Run it before pushing: a dirty boards/ afterwards means a board.patch, a uboot.patch or a
# factory blob changed and the shipped artifact had not caught up.
set -euo pipefail

cd "$(dirname "$0")"
./build-firmware.sh

echo
if git diff --quiet -- boards/ && git diff --cached --quiet -- boards/; then
	echo "boards/ is up to date"
else
	echo "boards/ changed — commit these or find out why they drifted:"
	git status --short -- boards/
fi
