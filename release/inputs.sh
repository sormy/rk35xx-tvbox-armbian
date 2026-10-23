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
      # shellcheck disable=SC2086  # FRAGMENT lists its files
      echo "$2" "$CONFIG" $FRAGMENT kernel/build.sh kernel/version.sh modules/build.sh
      sed -n 's/^\. //p' "$2"   # a conf it builds on
      for entry in $PATCHES; do echo "${entry#*:}"; done
      family=$(basename "$2" .conf)
      for m in modules/*.conf; do
        # shellcheck source=/dev/null
        (. "$m"; for k in $KERNELS; do [ "$k" = "$family" ] && exit 0; done; exit 1) || continue
        echo "$m"
        # shellcheck source=/dev/null
        (. "$m"; for entry in ${PATCHES:-}; do echo "${entry#*:}"; done)
      done ;;
    board)
      # shellcheck source=/dev/null
      . "boards/$2/board.conf"
      echo "boards/$2/board.dts" package/board.sh
      [ ! -f "boards/$2/preserve-sectors" ] || echo "boards/$2/preserve-sectors" boards/common/tvb-install
      sed -E 's/#.*//' "boards/$2/package.list" | awk 'NF && $1 != "link" {print "boards/" $2}'
      if [ -n "${BOARD_UBOOT:-}" ]; then
        echo "uboot/$BOARD_UBOOT.conf" uboot/build.sh
        [ ! -f "boards/$2/uboot.dts" ] || echo "boards/$2/uboot.dts"
        # shellcheck source=/dev/null
        (. "uboot/$BOARD_UBOOT.conf"; echo ${PATCHES:-}; [ -z "${SOC:-}" ] || echo "uboot/$SOC-u-boot.dtsi")
      fi
      [ -z "${BOARD_IDBLOADER:-}" ] || echo "boards/$BOARD_IDBLOADER" ;;
    firmware)
      echo "firmware/$2/firmware.conf" "firmware/$2/package.list" package/firmware.sh
      sed -E 's/#.*//' "firmware/$2/package.list" | awk 'NF && $1 != "link" {print "firmware/" $2}' ;;
    keyring) echo keyring/tvb-archive-keyring.gpg package/keyring.sh ;;
  esac
}
# settings <group> <arg>: what a conf sets, sorted, so a comment or a reordering moves nothing
settings() {
  case $1 in
    board) (
      # shellcheck source=/dev/null
      . "boards/$2/board.conf"
      for v in ${!BOARD_@}; do
        if [ "$v" = BOARD_DEPENDS ]; then echo "$v=$(tr ',' ' ' <<<"${!v}" | xargs -n1 | sort | xargs)"; else echo "$v=${!v}"; fi
      done
    ) ;;
  esac
}
tools() {
  case $1 in
    kernel) gcc -dumpfullversion; ld --version | head -1 ;;
    board)
      dtc --version
      # shellcheck source=/dev/null
      (. "boards/$2/board.conf"; [ -z "${BOARD_UBOOT:-}" ] || { gcc -dumpfullversion; ld --version | head -1; }) ;;
  esac
}
# shellcheck disable=SC2046  # one path per word
{ sha256sum $(files "$@" | tr ' ' '\n' | sort -u); echo "${3:-}"; settings "$@"; tools "$@"; } | sha256sum | cut -c1-16
