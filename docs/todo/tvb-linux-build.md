# tvb-linux: building it

Opened 2026-10-18. Planned, not started. The plan this serves is `docs/todo/tvb-linux.md`: the
monthly build, the build hosts, the caches.

## Monthly build

A GitHub Actions workflow on the 1st, plus a manual trigger, runs the same container a laptop runs.
It repins first, then builds, then publishes a release tagged by the run's date, `2026-10-01`.

### Triggers

| Signal                                     | Runs                      | Publishes         |
| ------------------------------------------ | ------------------------- | ----------------- |
| `schedule`, the 1st, off the hour          | repin, build, publish     | yes               |
| `workflow_dispatch`, or `gh workflow run`  | the same                  | yes               |
| a push to `kernel/`, `patches/`, the build | build at the current pins | no: early warning |

No external cron: the workflow's own `schedule` is the clock, and upstream sends no signal, so the
repin is the poll. A dropped or urgent month is one `workflow_dispatch`.

### Repin

Each pin moves to the newest released commit upstream:

| Pin             | Moves to                                             | 2026-10-18            |
| --------------- | ---------------------------------------------------- | --------------------- |
| `ARMBIAN_BUILD` | the newest stable tag, `vYY.M.N`, never `-trunk`     | `v26.5.1`             |
| mainline        | the newest kernel.org stable tag of the series named | `v6.18.57`, `v7.0.14` |
| vendor          | the tip of the branch named; it carries no tags      | `372ce582b`           |

"Named" is read from the pinned Armbian release's family config: `KERNEL_MAJOR_MINOR` for a mainline
track, `KERNELBRANCH` for vendor.

- **Within a series only.** A release naming another series, `rk-6.1-rkr6.1` or 7.1 for `edge`, is a
  track move: the repin keeps the old series and opens an issue for a human.
- **Per track.** A track whose new pin does not apply or build keeps last month's, publishes with
  it, and opens an issue naming the patch or error.
- **Committed.** The workflow commits the moved pins to `kernel/*.conf`, so every release names the
  exact commits it was built from.

Out-of-tree driver `SHA=` pins carry no release tags upstream and move only by hand.

### Jobs

| Job    | Count                | Does                                        |
| ------ | -------------------- | ------------------------------------------- |
| kernel | families × tracks: 4 | that kernel's debs, `tvb-modules` with them |
| images | 1                    | four bases, then eight stamps               |

The images job bootstraps the Debian rootfs once, builds the four bases from it, then stamps each
image, compresses it, and deletes the raw image before the next, so one image's 2.2 GB is on disk at
a time. It builds every image, then fails listing those that did not build. It publishes last: the
debs to `apt`, the images to a new `YYYY-MM-DD` release, notes listing the pins that moved. A
failure on `current` publishes nothing; a failed `next` publishes `current` without it.

No build infrastructure of ours: GitHub's hosted runners, free for a public repo. Jobs run on
`ubuntu-24.04-arm`, native arm64 with no cross-compile and no `qemu-aarch64`. A second job on
`ubuntu-24.04` cross-compiles one kernel and publishes nothing, so the x86-64 path cannot rot.

| Runner limit | Value         | Against                                                |
| ------------ | ------------- | ------------------------------------------------------ |
| concurrency  | 20 jobs       | six a build, the x86-64 check included; grow by family |
| CPU, RAM     | 4, 16 GB      | ❓ kernel wall time, measured in phase 1               |
| job time     | 6 h           | one kernel per job; ❓ all eight images in one         |
| disk         | 14 GB SSD     | **the binding limit**: see below                       |
| between jobs | job artifacts | kernel debs into the images job, kept one day          |

Disk: Armbian's configs build DWARF5 debug info and BTF (`CONFIG_DEBUG_INFO_DWARF5=y`,
`CONFIG_DEBUG_INFO_BTF=y`), over 1,873 modules on rk35xx `vendor` and 3,290 on meson64 `current`.
Our fragment sets `CONFIG_DEBUG_INFO_NONE=y`, which drops BTF with it; ❓ whether a tree then fits.
If not, the job first deletes the runner image's preinstalled toolchains. Self-hosted or larger
runners are the fallback only if both fail.

A rebuild of unchanged pins still changes the image: `mmdebstrap` pulls the month's Debian security
updates. The kernel changes only when a pin moves.

GitHub's own limits on the schedule, from its Actions docs: a `schedule` run can be delayed under
load, worst at the top of the hour, and under enough load dropped; and a public repo's schedules are
disabled after 60 days with no activity. So the cron sits off the hour, and a dropped month is one
manual `workflow_dispatch`. 🟡 the repin commit is a push, which GitHub counts as activity.

Every CI run builds clean: no `actions/cache`, sources fetched from their pins, kernels built
without `ccache`. A release then depends on nothing but the pins and the day's Debian.

❓ download throttling: GitHub documents no limit for `releases/download`, but tightened
unauthenticated limits on other endpoints in 2025. apt fetches anonymously.

## Two release paths

The monthly build and a release from a Mac run the same container and the same steps. They differ in
where the signing key comes from and in who decides to publish.

| Step  | Monthly, in CI           | Manual, from a Mac                        |
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

## Build hosts

Everything but flashing runs in one pinned, multi-arch container, under `docker` on either host or
`podman` on Linux. Maskrom, `amlcmd` and writing the SD stay native: Docker Desktop on macOS passes
no USB through.

| Step                      | arm64 host   | x86-64 host                                   |
| ------------------------- | ------------ | --------------------------------------------- |
| kernel, modules           | native `gcc` | `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-` |
| U-Boot, ATF               | native `gcc` | same `CROSS_COMPILE`                          |
| out-of-tree drivers       | native       | same, through `make M=`                       |
| `.deb`s                   | `dpkg-deb`   | `dpkg-deb`; arch comes from `control`         |
| `mmdebstrap --arch=arm64` | native       | `qemu-user-static` through `binfmt_misc`      |

`binfmt_misc` belongs to the host kernel, not the container: Docker Desktop registers `aarch64`; on
Linux, the host's `qemu-user-static` does. ❓ how much slower the rootfs step runs under emulation.

`docs/build-host.md` is a deliverable of phase 1: per host, the installs, the commands that check
them, and measured disk, RAM and wall time for a cold and a cached build. `./build.sh doctor` runs
the same checks, so the doc and the script cannot disagree.

| Host           | Beyond a Docker engine                                   |
| -------------- | -------------------------------------------------------- |
| macOS arm64    | `xz`; host tools from `./build-rktools.sh`, `amltools`   |
| macOS x86-64   | the same; Docker Desktop's `aarch64` emulation           |
| Linux arm64    | `podman` works too; a udev rule for maskrom USB          |
| Linux x86-64   | the same, plus `qemu-user-static` registered on the host |
| GitHub Actions | nothing; the workflow is the setup                       |

## Cache

Every cache is keyed by its inputs, so a changed input invalidates it without a flush. All live in
container volumes, never bind mounts: macOS's default APFS is case-insensitive, and the kernel has
names that differ only by case (`xt_TCPMSS.h`, `xt_tcpmss.h`).

| Cache         | Volume                   | Key                           | On a key change     |
| ------------- | ------------------------ | ----------------------------- | ------------------- |
| sources       | `tvb-src`                | every pin                     | another entry; kept |
| kernel tree   | `tvb-tree-<fam>-<track>` | `COMMIT` + hash of the series | reset, `git am`     |
| objects       | `tvb-ccache`             | `ccache`'s own                | none needed         |
| `.deb`s       | `tvb-debs`               | package version + input hash  | rebuilt             |
| apt downloads | `tvb-apt`                | file name, as apt keeps it    | none needed         |
| base rootfs   | `tvb-rootfs`             | suite + package list + month  | `mmdebstrap` again  |

The tree reset is `git reset --hard $COMMIT` then `git am`: only files the old or new series touch
change, so `make` stays incremental.

```sh
./build.sh flush tree      # host: re-checkout the kernel trees; ccache keeps the rebuild short
./build.sh flush ccache    # host: compiler objects
./build.sh flush rootfs    # host: base rootfs, next build bootstraps again
./build.sh flush all       # host: every tvb-* volume
```

These caches are for local builds; flushing is for suspected corruption only. CI uses none.
