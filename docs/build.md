# Building TVBian

`./build.sh` runs every step in one container image, `build-env/Containerfile` on Debian stable.
Outputs land in `build/out/`; the kernel tree and caches in the `tvb-work` volume.

## Hosts

| Host           | Runtime           | State                                         |
| -------------- | ----------------- | --------------------------------------------- |
| macOS arm64    | Apple `container` | ✅ `brew install container`                   |
| Linux arm64    | `podman`          | ❓ `sudo apt install podman`                  |
| Linux x86-64   | `podman`, `qemu`  | ❓ `sudo apt install podman qemu-user-static` |
| GitHub Actions | `podman`, rootful | ❓ `ubuntu-24.04-arm`, `release.yml`          |

Every host builds in the same image, Debian stable on arm64, so each gets the same toolchain; an
arm64 host could build without it, and does not. An x86-64 host runs that arm64 image under `qemu`
(`--platform linux/arm64`): the same steps and outputs, slower for every instruction it emulates.

## Steps

```sh
./build.sh kernel kernel/meson64.conf   # host: the kernel, headers, its drivers, the metapackage
./build.sh board h96max-m20             # host: tvb-h96max-m20, after the U-Boot it ships
./build.sh kernel kernel/meson64-next.conf   # host: the same on the next series, opt-in
./build.sh keyring                      # host: tvb-archive-keyring
./build.sh debs                         # host: all of the above, every kernel and board
./build.sh image h96max-m20             # host: build/out/images/, from build/out/debs/
```

`./build.sh` alone lists every step and `TVB_BUILD_*` variable. A kernel's out-of-tree drivers,
`modules/<name>.conf` naming it in `KERNELS`, build in its step into
`tvb-<name>-modules-<kernelrelease>`; the metapackage depends on them. A local build is versioned
`0~local`, below every published one. A board builds once `kernel/` has its `BOARD_KERNEL`.

## Release

```sh
./build.sh release --key <private-key-file>   # host: plan, build what moved, images, signed repo
./build.sh serve                              # host: build/out/ on port 8000
./build.sh publish                            # host: gh, a clean and pushed tree
```

The plan looks up each group's `X-Tvb-Inputs`, from `release/inputs.sh`, in the published
`Packages`: a match is fetched, anything else builds at the next revision, `6.18.57-1` then `-2`, or
`1` then `2`. Plan and notes land in `build/out/release/`. `release` is `plan` then `assemble`;
`assemble` builds what the plan calls new, skipping a kernel whose debs are already in
`build/out/debs/`, then the guard, the images and the repo.

A path that moves between packages needs `Replaces` and `Breaks` on its new owner, versioned below
the old owner's first release without it; `release/guard.sh` fails the release otherwise, against
the published `Contents`. A path renamed within one package needs neither.

Testing the served repo from a box, 🟡 run from a trixie container only:

```sh
src='deb [signed-by=/usr/share/keyrings/tvb-archive-keyring.gpg] http://<mac>.local:8000/repo/ ./'
echo "$src" | sudo tee /etc/apt/sources.list.d/tvb-test.list && sudo apt update   # box
```

`publish` uploads the new debs, then the index, to the rolling `apt` release, never marked latest,
and the images with a signed `SHA256SUMS` to a release named by the day, `.2` for a second.

CI splits the same steps into jobs: `plan`; one runner per new kernel, its debs as an artifact and
its ccache kept by `actions/cache` (`TVB_BUILD_CCACHE_DIR`); then `assemble` on the debs, and
`publish`. Mondays and `workflow_dispatch` publish, signed from the `ARCHIVE_SIGNING_KEY` secret; a
push or a pull request touching a build input builds only. A dispatch with `clean` builds without
ccache.

## Measured

| Apple M-series, 10 CPUs                 | Wall time |
| --------------------------------------- | --------- |
| meson64 kernel, cold, 8 GB              | 16 min    |
| meson64 kernel, cold, 32 GB             | 13 min    |
| meson64 kernel, ccache warm             | 81 s      |
| `release`, ccache warm, image included  | 170 s     |
| `release`, every cache empty, 4 kernels | 49 min    |

❓ a GitHub-hosted arm64 runner: wall time and peak disk, measured on the first run.
