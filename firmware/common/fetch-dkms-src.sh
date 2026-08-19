#!/bin/sh
# Fetch the out-of-tree DKMS driver source from the pinned armbian/linux-rockchip commit into the
# given dir. Makefile and dkms.conf come from payload.list, not from here.
#   usage: fetch-dkms-src.sh <ir-src-dir>
set -e
IRDIR="${1:?usage: fetch-dkms-src.sh <ir-src-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# pinned vendor-kernel commit (the branch moves; the commit doesn't); provenance in docs/
SHA=31cd4f11b5ec31fc361256a04237416f278b62b2
BASE="https://raw.githubusercontent.com/armbian/linux-rockchip/$SHA"

mkdir -p "$IRDIR"

# IR: pristine .c/.h from the pinned commit, then our out-of-tree fixes on the .c
curl -fsSL "$BASE/drivers/input/remotectl/rockchip_pwm_remotectl.c" -o "$IRDIR/rockchip_pwm_remotectl.c"
curl -fsSL "$BASE/drivers/input/remotectl/rockchip_pwm_remotectl.h" -o "$IRDIR/rockchip_pwm_remotectl.h"
patch -p1 -d "$IRDIR" < "$HERE/rockchip-pwm-remotectl-rk35xx/rockchip_pwm_remotectl.patch"
