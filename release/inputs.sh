#!/bin/bash
# Print the X-Tvb-Inputs hash of one package group: what the plan compares with the published deb.
#   inputs.sh kernel <kernel/*.conf> <ref> | board <board> | firmware <dir> | keyring
# Beside the files, the versions of the tools that shape the group's bytes: none for copied files,
# so a build image changed for another step rebuilds nothing it does not touch.
set -euo pipefail
cd /repo
files() {
  case $1 in
    kernel)
      # shellcheck source=/dev/null
      . "$2"
      echo "$2" "$CONFIG" $FRAGMENT kernel/build.sh kernel/version.sh modules/build.sh
      sed -n 's/^\. //p' "$2"   # a conf it builds on
      for entry in $PATCHES; do echo "${entry#*:}"; done
      family=$(basename "$2" .conf)
      for m in modules/*.conf; do
        (. "$m"; for k in $KERNELS; do [ "$k" = "$family" ] && exit 0; done; exit 1) || continue
        echo "$m"
        (. "$m"; for entry in ${PATCHES:-}; do echo "${entry#*:}"; done)
      done ;;
    board)
      # shellcheck source=/dev/null
      . "firmware/$2/board.conf"
      echo "firmware/$2/board.conf" "firmware/$2/board.dts" "firmware/$2/board-name" package/board.sh
      [ ! -f "firmware/$2/preserve-sectors" ] || echo "firmware/$2/preserve-sectors" firmware/common/tvb-install
      ls "firmware/$2/board.tvbian.patch" 2>/dev/null || true
      sed -E 's/#.*//' "firmware/$2/package.list" | awk 'NF && $1 != "link" {print "firmware/" $2}'
      [ -z "${BOARD_UBOOT_BUILD:-}" ] || echo "uboot/$BOARD_UBOOT_BUILD.conf" uboot/build.sh
      [ -z "${BOARD_UBOOT:-}" ] || echo "firmware/$BOARD_UBOOT"
      [ -z "${BOARD_IDBLOADER:-}" ] || echo "firmware/$BOARD_IDBLOADER" ;;
    firmware)
      echo "firmware/common/$2/firmware.conf" "firmware/common/$2/package.list" package/firmware.sh
      sed -E 's/#.*//' "firmware/common/$2/package.list" | awk 'NF && $1 != "link" {print "firmware/" $2}' ;;
    keyring) echo keyring/tvb-archive-keyring.gpg package/keyring.sh ;;
  esac
}
tools() {
  case $1 in
    kernel) gcc -dumpfullversion; ld --version | head -1 ;;
    board)
      dtc --version
      # shellcheck source=/dev/null
      (. "firmware/$2/board.conf"; [ -z "${BOARD_UBOOT_BUILD:-}" ] || { gcc -dumpfullversion; ld --version | head -1; }) ;;
  esac
}
# shellcheck disable=SC2046  # one path per word
{ sha256sum $(files "$@" | tr ' ' '\n' | sort -u); echo "${3:-}"; tools "$@"; } | sha256sum | cut -c1-16
