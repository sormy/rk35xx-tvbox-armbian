#!/usr/bin/env bash
# Build TVBian in one container image: Apple `container` on macOS, `podman` on Linux.
#   usage: ./build.sh kernel <kernel/*.conf>  its debs and metapackage
#          ./build.sh uboot <uboot/*.conf>    a U-Boot a board package ships
#          ./build.sh board <board>           tvb-<board>, after its U-Boot
#          ./build.sh firmware <dir>          tvb-firmware-<chip>, from firmware/common/<dir>/
#          ./build.sh keyring                 tvb-archive-keyring
#          ./build.sh debs                    all of the above
#          ./build.sh image <board>           its image, from build/out/debs/
#          ./build.sh images                  every board's image
#          ./build.sh repo [--key <file>]     build/out/debs/ as a signed flat apt repo
#          ./build.sh plan                    each group's version against the published repo
#          ./build.sh assemble [--key <file>] build what the plan calls new, images, repo
#          ./build.sh release [--key <file>]  plan, then assemble: what CI runs, in one go
#          ./build.sh serve                   build/out/ on port 8000
#          ./build.sh publish                 upload a release to GitHub
#   env:   TVB_BUILD_CPUS (all cores), TVB_BUILD_MEMORY (8g), TVB_BUILD_SUITE (Debian stable),
#          TVB_BUILD_REVISION (0~local), TVB_BUILD_CACHE (1; 0: clean), TVB_BUILD_CCACHE_SIZE (5G),
#          TVB_BUILD_CCACHE_DIR (in the work volume; a host directory for CI's cache to keep,
#          slow on macOS, where a bind mount is a file share)
set -euo pipefail
cd "$(dirname "$0")"

WORK=tvb-work   # named volume: a case-sensitive ext4 the kernel tree lives in
CPUS=${TVB_BUILD_CPUS:-$(getconf _NPROCESSORS_ONLN)}
MEMORY=${TVB_BUILD_MEMORY:-8g}   # a -j build without debug info peaks at a few GB
OUT=build/out

install_hint() {
  case "$(uname -s)" in
    Darwin)
      if [ "$(uname -m)" != arm64 ]; then
        echo "macOS needs Apple silicon: Apple container does not run on Intel Macs." >&2
        exit 1
      fi
      cat >&2 <<'EOF'
No container runtime found. Install Apple container:
  brew install container
  container system start
EOF
      ;;
    Linux)
      cat >&2 <<'EOF'
No container runtime found. Install podman:
  sudo apt install podman      # Debian, Ubuntu
  sudo dnf install podman      # Fedora
  sudo pacman -S podman        # Arch
EOF
      ;;
    *) echo "unsupported build host: $(uname -s)" >&2 ;;
  esac
  exit 1
}

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
case "${1:-}" in
  kernel | uboot | board | firmware | keyring | debs | image | images | plan | repo | assemble | release) ;;
  serve) cd "$OUT" && exec python3 -m http.server 8000 ;;
  publish) exec bash release/publish.sh ;;
  *) usage ;;
esac

RT=""
case "$(uname -s)" in
  Darwin) command -v container >/dev/null && RT=container ;;
  Linux)  command -v podman >/dev/null && RT=podman ;;
esac
[ -n "$RT" ] || install_hint
# a host other than arm64 runs the same arm64 image under qemu: every step works, only slower
PLATFORM=
if [ "$RT" = podman ] && [ "$(uname -m)" != aarch64 ]; then
  [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] ||
    { echo "a $(uname -m) host runs the arm64 image under qemu: sudo apt install qemu-user-static" >&2; exit 1; }
  PLATFORM=--platform=linux/arm64
fi

# Debian's own stable alias names the release, unless TVB_BUILD_SUITE does: forky, for testing
SUITE=${TVB_BUILD_SUITE:-$(curl -fsSL https://deb.debian.org/debian/dists/stable/Release | sed -n 's/^Codename: //p')}
[ -n "$SUITE" ] || { echo "cannot read Debian's stable codename from deb.debian.org" >&2; exit 1; }
# tagged by release and Containerfile hash: either changing rebuilds the image
hash=$(sha256sum build-env/Containerfile 2>/dev/null || shasum -a 256 build-env/Containerfile)
IMAGE=tvb-build-env:$SUITE-${hash:0:12}
if [ "$RT" = container ] && ! container system status >/dev/null 2>&1; then
  echo "Apple container is installed but not running: container system start" >&2
  exit 1
fi

run() {  # run a command inside the image, the repo read-only at /repo
  local rel="" ccache=()
  "$RT" image inspect "$IMAGE" >/dev/null 2>&1 ||
    "$RT" build ${PLATFORM:+"$PLATFORM"} --build-arg SUITE="$SUITE" -t "$IMAGE" -f build-env/Containerfile build-env
  mkdir -p "$OUT"
  [ "$RT" = podman ] && rel=",Z"   # SELinux hosts relabel bind mounts; a no-op elsewhere
  "$RT" volume create "$WORK" >/dev/null 2>&1 || true
  if [ -n "${TVB_BUILD_CCACHE_DIR:-}" ]; then
    mkdir -p "$TVB_BUILD_CCACHE_DIR"
    ccache=(-v "$TVB_BUILD_CCACHE_DIR:/ccache${rel:+:${rel#,}}" -e CCACHE_DIR=/ccache)
  fi
  # Apple container does not forward a signal to the container: stop it by name
  local name=tvb-$$
  trap '"$RT" stop "$name" >/dev/null 2>&1; exit 130' INT TERM
  "$RT" run ${PLATFORM:+"$PLATFORM"} --rm --name "$name" --cpus "$CPUS" --memory "$MEMORY" -e TVB_BUILD_CPUS="$CPUS" -e TVB_BUILD_REVISION="${TVB_BUILD_REVISION:-0~local}" \
    -e TVB_BUILD_CACHE="${TVB_BUILD_CACHE:-1}" -e TVB_BUILD_CCACHE_SIZE="${TVB_BUILD_CCACHE_SIZE:-5G}" \
    -e TVB_BUILD_ENV="$IMAGE" -e TVB_BUILD_SUITE="$SUITE" \
    -v "$WORK:/work" -v "$PWD:/repo:ro$rel" -v "$PWD/$OUT:/out${rel:+:${rel#,}}" ${ccache[@]+"${ccache[@]}"} \
    -w /repo "$IMAGE" "$@" </dev/null
}

# a board builds once kernel/ has its family's kernel
boards() {
  local c
  for c in firmware/*/board.conf; do
    k=$(sed -n 's/^BOARD_KERNEL=//p' "$c")
    [ -n "$k" ] && [ -f "kernel/$k.conf" ] && basename "$(dirname "$c")"
  done
  return 0
}
firmwares() { for c in firmware/common/*/firmware.conf; do [ -f "$c" ] && basename "$(dirname "$c")"; done; return 0; }
uboot_of() { sed -n 's/^BOARD_UBOOT_BUILD=//p' "firmware/$1/board.conf"; }

board() {
  local u
  u=$(uboot_of "$1")
  [ -z "$u" ] || [ -f "$OUT/uboot/$u/u-boot.bin" ] || run bash uboot/build.sh "uboot/$u.conf"
  run bash package/board.sh "$1"
}

case "$1" in
  kernel) run bash kernel/build.sh "${2:?usage: ./build.sh kernel <kernel/*.conf>}" ;;
  uboot) run bash uboot/build.sh "${2:?usage: ./build.sh uboot <uboot/*.conf>}" ;;
  board) board "${2:?usage: ./build.sh board <board>}" ;;
  firmware) run bash package/firmware.sh "${2:?usage: ./build.sh firmware <dir>}" ;;
  keyring) run bash package/keyring.sh ;;
  debs)
    for k in kernel/*.conf; do run bash kernel/build.sh "$k"; done
    for f in $(firmwares); do run bash package/firmware.sh "$f"; done
    for b in $(boards); do board "$b"; done
    run bash package/keyring.sh ;;
  image) run bash image/build.sh "${2:?usage: ./build.sh image <board>}" ;;
  images) for b in $(boards); do run bash image/build.sh "$b"; done ;;
  plan)
    rm -rf "$OUT/debs" "$OUT/images" "$OUT/release"
    run bash release/plan.sh ;;
  repo | assemble | release)
    if [ "${2:-}" = --key ]; then
      cp "${3:?usage: ./build.sh $1 --key <file>}" "$OUT/signing.key"
      trap 'rm -f "$OUT/signing.key"' EXIT
    fi
    [ "$1" != release ] || "$0" plan
    if [ "$1" != repo ]; then
      [ -s "$OUT/release/plan" ] || { echo "✗ no plan in $OUT/release: ./build.sh plan first" >&2; exit 1; }
      while read -r step arg version state; do
        [ "$state" = new ] || continue
        case $step in
          # a kernel built in its own CI job arrives as debs: skip it
          kernel) [ -f "$OUT/debs/linux-image-tvb-$(basename "$arg" .conf)_${version}_arm64.deb" ] ||
            TVB_BUILD_REVISION=${version##*-} run bash kernel/build.sh "$arg" ;;
          board) TVB_BUILD_REVISION=$version board "$arg" ;;
          firmware) TVB_BUILD_REVISION=$version run bash package/firmware.sh "$arg" ;;
          keyring) TVB_BUILD_REVISION=$version run bash package/keyring.sh ;;
        esac
      done <"$OUT/release/plan"
      run bash release/guard.sh
      for b in $(boards); do run bash image/build.sh "$b"; done
    fi
    run bash release/repo.sh ;;
esac
