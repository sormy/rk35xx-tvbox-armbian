# tvb-linux: building it

Opened 2026-10-18. The plan this serves is `docs/todo/tvb-linux.md`: the weekly build, the build
hosts, the caches. Built: `.github/workflows/release.yml` and `./build.sh release`, as
`docs/build.md` gives them. Not yet: the first release (below), the vendor kernels' 7-day soak, the
AIC8800 driver following Radxa's releases, the manual `repin` workflow; `FOLLOW` and `BRANCH`
resolve at build time, and the release notes name what they resolved to.

## First release

The order agreed on 2026-10-22; each step lands before the next starts.

- [x] **Local dry run from empty caches.** ✅ 2026-10-22: 49 min, four kernels 468-766 s each.
      `TVB_BUILD_CACHE=0 ./build.sh release` on the Mac, the `tvb-work` volume and `build/out` wiped
      first: every step CI runs, unsigned.
- [x] **Logs per kernel.** `kernel/build.sh` writes `build/out/logs/<family>/`, so kernels built at
      once never overwrite each other's step logs.
- [x] **A host ccache.** ✅ a warm rebuild of rk35xx-next hit 10127 of 10127, 144 s against 969 s.
      `TVB_BUILD_CCACHE_DIR` mounts a host directory as ccache's, the one cache CI keeps; unset on a
      Mac, where the volume's is twice as fast.
- [x] **Steps CI can call one by one:** plan, one kernel at its planned version, the rest.
      `./build.sh release` still runs them all in order.
- [x] **The workflow split:** `plan`, a kernel job each, then `release`; pull requests build and
      publish nothing. ✅ kernels 30-61 min cold, 4-8 min warm; the release job 7-8 min.
- [x] **Push, then dispatch once.** ✅ `apt` and `2026-10-22` published 2026-10-22, the `apt` URL
      live from then on.
- [x] **The M20 on the live repo.** ✅ `apt update`, then 7 packages from `0~local` to `1`, no
      conflict.
- [x] **The other boxes on the live repo,** ✅ the H313, the 3518D, then the R69.

## Weekly build

A GitHub Actions workflow every Monday, plus a manual trigger, runs the same container a laptop
runs. It resolves what floats, builds, and publishes a release tagged by the run's date,
`2026-10-01`, whose notes name every commit it resolved.

### Triggers

| Signal                                     | Runs                         | Publishes          |
| ------------------------------------------ | ---------------------------- | ------------------ |
| `schedule`, Mondays, off the hour          | resolve, build, publish      | yes                |
| `workflow_dispatch`, or `gh workflow run`  | the same                     | yes                |
| a push to `kernel/`, `patches/`, the build | build at the current pins    | no: early warning  |
| a pull request                             | build at the PR's pins       | no: the PR's check |
| the same `schedule`                        | `testing`, an image a family | never              |

No external cron: the workflow's own `schedule` is the clock, and upstream sends no signal, so the
weekly resolve is the poll. A dropped or urgent week is one `workflow_dispatch`.

### What floats

`docs/sources.md` holds the policy: kernels float, the vendor tip soaked a week; Radxa's driver
follows its releases; the other drivers, U-Boot, firmware and host tools stay pinned.

### Jobs

| Job     | Count        | Does                                                                 |
| ------- | ------------ | -------------------------------------------------------------------- |
| plan    | 1            | each group's version, `new` or `published`, as an artifact           |
| kernel  | one a kernel | that kernel's debs, unless the plan says `published`; as artifacts   |
| release | 1            | firmware, boards, keyring, the guard, every image, the repo, publish |

`release` starts only once every kernel job passed, so a failure publishes nothing. It alone holds
`contents: write`, signs the index once, and publishes: the new debs and the index to `apt`, the
images to one new `YYYY-MM-DD` release. A pull request stops before signing and publishing.

No build infrastructure of ours: GitHub's hosted runners, free for a public repo. Jobs run on
`ubuntu-24.04-arm`, native arm64 with no cross-compile and no `qemu-aarch64`. A second job on
`ubuntu-24.04` cross-compiles one kernel and publishes nothing, so the x86-64 path cannot rot.

| Runner limit | Value         | Against                                                |
| ------------ | ------------- | ------------------------------------------------------ |
| concurrency  | 20 jobs       | six a build, the x86-64 check included; grow by family |
| CPU, RAM     | 4, 16 GB      | ❓ kernel wall time, measured in phase 1               |
| job time     | 6 h           | one kernel per job; ❓ all four images in one          |
| disk         | 14 GB SSD     | **the binding limit**: see below                       |
| between jobs | job artifacts | kernel debs into the release job, kept one day         |

Disk: Armbian's configs build DWARF5 debug info and BTF (`CONFIG_DEBUG_INFO_DWARF5=y`,
`CONFIG_DEBUG_INFO_BTF=y`), over 1,873 modules on rk35xx `vendor` and 3,290 on meson64 `current`.
Our fragment sets `CONFIG_DEBUG_INFO_NONE=y`, which drops BTF with it; ❓ whether a tree then fits.
If not, the job first deletes the runner image's preinstalled toolchains. Self-hosted or larger
runners are the fallback only if both fail.

A rebuild of unchanged pins still changes the image: `mmdebstrap` pulls the week's Debian security
updates. The kernel changes only when a pin moves.

GitHub's own limits on the schedule, from its Actions docs: a `schedule` run can be delayed under
load, worst at the top of the hour, and under enough load dropped; and a public repo's schedules are
disabled after 60 days with no activity. So the cron sits off the hour, and a dropped week is one
manual `workflow_dispatch`. Releases commit nothing, so a quiet two months disables the schedule;
any push or dispatch revives it.

Sources and trees are fresh every run, fetched from their pins. `ccache` alone carries over: each
kernel job restores and saves its own through `actions/cache`, about 1 GB a kernel against the
repo's 10 GB. A hit is the object a fresh compile gives, keyed on the command and the preprocessed
source. A pull request reads `main`'s caches and saves only its own. A cache unused for 7 days is
evicted, so a quiet week's run starts cold. `TVB_BUILD_CACHE=0` on a dispatch is the clean room.

❓ download throttling: GitHub documents no limit for `releases/download`, but tightened
unauthenticated limits on other endpoints in 2025. apt fetches anonymously.

## Two release paths

The weekly build and a release from a Mac run the same container and the same steps. They differ in
where the signing key comes from and in who decides to publish.

| Step  | Weekly, in CI            | Manual, from a Mac                        |
| ----- | ------------------------ | ----------------------------------------- |
| build | `./build.sh debs images` | the same                                  |
| sign  | the Actions secret       | a key file, given by path                 |
| test  | ❓ the validation gate   | `./build.sh serve`, then a box on the LAN |
| ship  | `./build.sh publish`     | `./build.sh publish`, after the test      |

The manual test, in order:

```sh
./build.sh debs images --key <private-key-file>     # host
./build.sh serve                                    # host: the signed repo and images, port 8000
echo 'deb [signed-by=/usr/share/keyrings/tvb-archive-keyring.gpg] http://<mac>.local:8000 ./' \
  | sudo tee /etc/apt/sources.list.d/tvb-test.list && sudo apt update && sudo apt upgrade   # box
./build.sh publish                                  # host, once the box passes
```

`publish` uploads the files the box was tested on, never a rebuild. It refuses a dirty tree or an
unpushed commit, so every release, either path, names its commit. A tag CI already holds that day
becomes `YYYY-MM-DD.2`; nothing is overwritten. One key signs both paths, so a box cannot tell them
apart.

## Hosted on GitHub

Everything is published from this repo; no server of ours.

| What        | Where                                                             |
| ----------- | ----------------------------------------------------------------- |
| apt repo    | release `apt`, rolling, never latest: `.deb`s plus index          |
| images      | release `YYYY-MM-DD`: eight `.img.xz`, all kept                   |
| checksums   | `SHA256SUMS`, signed, in the same release                         |
| signing key | public: `keyring/tvb-archive-keyring.gpg`; CI signs from a secret |

An image's name carries what the release tag carries, so a downloaded file still says what it is:
`tvbian-<YYYY-MM-DD>-<board>-<codename>.img.xz`, as `tvbian-2026-11-01-h96max-m20-trixie.img.xz`.

Nothing is pruned, so any past release can be flashed to test against, or to bisect a regression.
Each release's notes list its pins and the diff from the one before: the kernel commits, the patches
added or dropped. The `apt` repo keeps every kernel it ever published; versioned names coexist, so
`apt install linux-image-<kernelrelease>` goes back without a reflash, and removing the newer kernel
makes the older one the default entry.

`apt` gains up to 12 kernel debs a month, about 150 a year. ❓ whether GitHub caps assets per
release; if it does, `apt` moves to one release per year.

The public key needs no release of its own: it is committed, packaged as `tvb-archive-keyring`,
preinstalled in every image, and published in `apt` like any package. A box not flashed from our
image fetches the committed file once, then adds the `deb` line.

`keyring/` holds the key's whole lifecycle, ✅ generated 2026-10-19, fingerprint in its README:

| File                      | Holds                                        |
| ------------------------- | -------------------------------------------- |
| `tvb-archive-keyring.gpg` | the public key, committed                    |
| `README.md`               | fingerprint, loading the CI secret, rotation |

`.gitignore` keeps any private key file in `keyring/` out of git.

The key does not expire: a box that misses a renewed keyring before expiry fails `apt update` with
`EXPKEYSIG` and cannot fetch the fix. A rotation ships both public keys in `tvb-archive-keyring`,
signs `InRelease` with both for a release cycle, then drops the old one. A compromised key means a
reflash or a manual key install; nothing signed by it can be trusted.

The apt repo is flat — `Packages.xz`, `Release`, `InRelease` beside the `.deb`s, written by
`apt-ftparchive` and signed with `gpg`:

```sh
deb [signed-by=/usr/share/keyrings/tvb-archive-keyring.gpg] https://github.com/sormy/tvbian/releases/download/apt ./
```

✅ apt's `https` method follows the `releases/download` redirect, measured 2026-10-18 in a
`debian:trixie` container; a missing asset is a plain `404`:

```sh
/usr/lib/apt/apt-helper download-file https://github.com/cli/cli/releases/download/v2.60.0/gh_2.60.0_linux_arm64.deb /tmp/gh.deb
```

✅ a signed flat repo whose `.deb` exists only as a GitHub release asset, 2026-10-18 in a
`debian:trixie` container: `apt-get update` verified `InRelease` through `signed-by=`, and
`apt-get install` followed a 302 to the asset, checked its hash and installed it.

🟡 the index fetched through the redirect too, by the same method as the asset.

Fallback: the index and the `.deb`s on GitHub Pages, kept to the current and previous kernel.

Size: GitHub caps a release asset at 2 GiB and caps neither a release's total nor its bandwidth. The
Armbian-based images built here are 360–390 MB as `.img.xz`, so a release is about 3 GB.

## Build hosts

Lightweight runtimes only; no Docker Desktop.

| Host                 | Runs the steps in                                   |
| -------------------- | --------------------------------------------------- |
| macOS, Apple silicon | Apple `container`, a lightweight VM per container   |
| Linux, Debian trixie | the host itself, `./build.sh --native`; or `podman` |
| other Linux          | `podman`, or `docker` where the host already has it |
| GitHub Actions       | the runner's preinstalled `podman`                  |

All run the same `build-env/Containerfile`; `./build.sh` uses the first runtime it finds, and
`doctor` checks a native host's packages and compiler version first. The container is the release
path: it pins the toolchain, and with it byte-identical modules on every host. Maskrom, `amlcmd` and
writing the SD stay native: a container on macOS reaches no USB.

| Step                      | arm64 host   | x86-64 host                                   |
| ------------------------- | ------------ | --------------------------------------------- |
| kernel, modules           | native `gcc` | `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-` |
| U-Boot, ATF               | native `gcc` | same `CROSS_COMPILE`                          |
| out-of-tree drivers       | native       | same, through `make M=`                       |
| `.deb`s                   | `dpkg-deb`   | `dpkg-deb`; arch comes from `control`         |
| `mmdebstrap --arch=arm64` | native       | `qemu-user-static` through `binfmt_misc`      |

`binfmt_misc` belongs to the host kernel, not the container: on Linux, the host's `qemu-user-static`
registers `aarch64`. ❓ how much slower the rootfs step runs under emulation.

`docs/build-host.md` is a deliverable of phase 1: per host, the installs, the commands that check
them, and measured disk, RAM and wall time for a cold and a cached build. `./build.sh doctor` runs
the same checks, so the doc and the script cannot disagree.

| Host           | Beyond the runtime                                       |
| -------------- | -------------------------------------------------------- |
| macOS arm64    | `xz`; host tools from `./build-rktools.sh`, `amltools`   |
| Linux arm64    | a udev rule for maskrom USB                              |
| Linux x86-64   | the same, plus `qemu-user-static` registered on the host |
| GitHub Actions | nothing; the workflow is the setup                       |

## Cache

Every cache is keyed by its inputs, so a changed input invalidates it without a flush. All live in
container volumes, never bind mounts: macOS's default APFS is case-insensitive, and the kernel has
names that differ only by case (`xt_TCPMSS.h`, `xt_tcpmss.h`).

| Cache         | Volume              | Key                           | On a key change     |
| ------------- | ------------------- | ----------------------------- | ------------------- |
| sources       | `tvb-src`           | every pin                     | another entry; kept |
| kernel tree   | `tvb-tree-<kernel>` | `COMMIT` + hash of the series | reset, `git am`     |
| objects       | `tvb-ccache`        | `ccache`'s own                | none needed         |
| `.deb`s       | `tvb-debs`          | package version + input hash  | rebuilt             |
| apt downloads | `tvb-apt`           | file name, as apt keeps it    | none needed         |
| base rootfs   | `tvb-rootfs`        | suite + package list + month  | `mmdebstrap` again  |

The tree reset is `git reset --hard $COMMIT` then `git am`: only files the old or new series touch
change, so `make` stays incremental.

```sh
./build.sh flush tree      # host: re-checkout the kernel trees; ccache keeps the rebuild short
./build.sh flush ccache    # host: compiler objects
./build.sh flush rootfs    # host: base rootfs, next build bootstraps again
./build.sh flush all       # host: every tvb-* volume
```

These caches are for local builds; flushing is for suspected corruption only. CI uses none.
