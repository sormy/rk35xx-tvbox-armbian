# tvb-linux: our kernel, our image

Opened 2026-10-18. Planned, not started. What goes into the rootfs is in
`docs/todo/tvb-linux-rootfs.md`.

One command, on Linux or macOS, builds every board's minimal Debian image on two kernel tracks. An
apt repo published from this repo serves our few packages; Debian's serve the rest, so `apt upgrade`
keeps a box current. Armbian is a pinned source for the kernel, nothing else at runtime. No kernel
is forked.

## What it retires

| Today                                  | Why it exists              | After                 |
| -------------------------------------- | -------------------------- | --------------------- |
| `kernel-prepare`, `kernel-dkms-src`    | Armbian's headers, DKMS    | gone                  |
| `dtb-persist`                          | upgrades ship stock DTBs   | DTB in our package    |
| `boardname` hook, `BOARD=rock-2f`      | `armbian-bsp` rewrites it  | gone                  |
| `linux-u-boot-*` hold                  | ROCK 2F loaders soft-brick | no such package       |
| `BOARD_DKMS_FETCH`, `board_stage_dkms` | drivers built on the box   | built with the kernel |
| `BOARD_APT_DEBS` offline staging       | no toolchain on Lepotato   | gone                  |
| `patches/linux-rockchip/` unapplied    | kernel comes from apt      | applied               |
| `platform-install`, its caveats        | Armbian's installer        | `tvb-install`         |
| M20 chain-loading Lepotato's U-Boot    | base image's own build     | our build             |
| first-boot wizard                      | Armbian's first login      | `tvb-firstlogin`      |
| `mac-pin`, `mac-oui`                   | drivers invent addresses   | drivers read them     |

## Two kernel tracks

Every family builds `current`, the kernel a box ships on, and `next`, the one after it. Each is an
Armbian branch, named once here:

| Family    | `current`               | `next`                           |
| --------- | ----------------------- | -------------------------------- |
| rk35xx    | Armbian `vendor`, 6.1   | Armbian `current`, mainline 6.18 |
| meson-gxl | Armbian `current`, 6.18 | Armbian `edge`, 7.0              |

Versions as the pinned release, `v26.5.1`, names them; `main` already has `edge` at 7.1. From `main`
at `4cf081a`, 2026-08-15: Lepotato builds `current,edge`; ROCK 2F `vendor` only, but `nanopi-zero2`
builds RK3528 on `vendor,current,edge`.

A track moves when Armbian's does: `next` becomes `current` once it passes validation on every board
of the family, and the branch after it becomes `next`.

### A kernel is Armbian's kernel, pinned, plus ours

`kernel/<family>-<track>.conf` is the whole kernel definition:

| Key             | Holds                                          |
| --------------- | ---------------------------------------------- |
| `REPO`          | the kernel tree                                |
| `COMMIT`        | a full hash, or a kernel.org tag               |
| `ARMBIAN_BUILD` | an `armbian/build` commit                      |
| `ARMBIAN_PATCH` | its `patch/kernel/<dir>`, and the config       |
| `PATCHES`       | `patches/<topic>/` directories, in apply order |

The build fetches both pins and applies Armbian's directory as its `0000.patching_config.yaml` says:
`*.patch` in name order, `dt/` merged in, the DT Makefile auto-patched. Then ours, with `git am`;
then `make bindeb-pkg` from Armbian's `config/kernel/` config plus our fragment. 🟡 that this
replays Armbian's own kernel build: those are the only steps the yaml files read here ask for.

Nothing of Armbian's is copied into this repo; a bump moves `COMMIT` and `ARMBIAN_BUILD` together.

### Patches

`patches/<topic>/` stays one directory per upstream target, its README naming where the patches go
and their PRs. That is the only copy.

- **In-tree** patches are `git format-patch` against the pinned tree, `-p1` from the kernel root:
  what upstream takes. The driver patches applied today with `-p3` and `-p5` are rebased to that.
- **Per track**, a topic whose patches differ between the two trees keeps one subdirectory per
  kernel series, `patches/<topic>/6.18/`; one that applies to both keeps none.
- **Out-of-tree drivers** (`seekwave-swt6621s`, `meson-codecs`) keep their own pin and patches. They
  are built with `make M=` against the kernel just built.
- **One that lands upstream** leaves ours on the bump that pins it in. The five in
  `patches/linux-rockchip/` are PRs #523–527 against `armbian/linux-rockchip`.

### Board trees per track

A board's tree is never built from the kernel's: it is the box's own factory DTB, `stock/<board>/`,
plus `board.patch`, which brings it to the bindings of the kernel it runs on. The M20 already does
this across a binding change: a vendor 4.9 blob patched to mainline, mainline's p271 tree as the
reference only (`docs/h96max-m20/dtb.md`). A track adds a patch, never a second base.

| Family    | `current`                    | `next`                                 |
| --------- | ---------------------------- | -------------------------------------- |
| rk35xx    | `board.patch`: vendor 6.1    | `board-next.patch`: to mainline, new   |
| meson-gxl | `board.patch`: mainline 6.18 | 🟡 the same; bindings are a kernel ABI |

Meson's mark is unmeasured, not doubted: the M20 has booted 6.18 only. Its 2026-10-12 worklog entry
built every module for Armbian's 7.2.8 `edge-meson64` without booting it. Booting that kernel with
our `board.dtb`, watched on serial, settles it before phase 5.

❓ what mainline RK3528 drives on these boxes: HDMI, the VPU, the SDIO Wi-Fi.

`build-board-dts.sh` takes the track and applies that track's patch to the same factory blob.

Adding a board stays a directory.

## Images

Every board, both tracks, minimal: four boards, eight images a build. Each is a generic base plus a
board stamp, the split `build-image.sh` already makes with Armbian's image as the base.

| Stage | Per               | Holds                                                |
| ----- | ----------------- | ---------------------------------------------------- |
| base  | family × track: 4 | an ext4 rootfs: Debian, that track's kernel and DTBs |
| stamp | board × track: 8  | the disk: layout, loader, the rootfs, `tvb-<board>`  |

The base is a filesystem, not a disk, because the disk is what differs:

| Board-specific    | rk35xx                                | meson-gxl                     |
| ----------------- | ------------------------------------- | ----------------------------- |
| layout            | GPT, rootfs past the loader           | factory partition table       |
| loader            | idbloader at 64, `uboot.itb` at 16384 | none: eMMC's factory one      |
| boot files        | none beyond the base                  | FAT: `boot.scr`, `u-boot.ext` |
| payload, firmware | `tvb-<board>`, into the copy          | same                          |

A stamp is a copy of the base plus seconds of raw writes and one package install, so the board data
stays a directory and the published file stays one `dd` or one `rkdeveloptool wl`.

The DTB is not stamped: each board's U-Boot sets `fdtfile` from `CONFIG_DEFAULT_FDT_FILE`, and
extlinux names the DTB directory, not a file. 🟡 mainline U-Boot's own mechanism, untried on our
build.

A box stays on its track: the image installs the metapackage `linux-image-tvb-<family>-<track>`,
which depends on that track's newest kernel, as Debian's `linux-image-arm64` does. Moving a box to
the other track is `apt install` of the other metapackage.

### Switching tracks

The DTB travels with the kernel: each track's kernel package ships the board DTBs built for that
track, and its extlinux entry names its own DTB directory. So the switch never pairs a kernel with a
tree patched for the other one.

| Switch                   | DTB                | What else breaks             |
| ------------------------ | ------------------ | ---------------------------- |
| meson, mainline→mainline | same `board.patch` | 🟡 nothing                   |
| rk35xx, vendor→mainline  | `board-next.patch` | vendor-only userspace, below |

Vendor-only on rk35xx: MPP's `/dev/mpp_service`, the `rockchip_pwm_remotectl` IR driver, and the
payload's vendor module names (`rk630phy`, `aic8800_fdrv`). ❓ whether the AIC8800 and Seekwave
drivers build against mainline. `tvb-<board>` carries per-track variants where they differ.

The newest kernel is the default entry, so installing 6.18 on a 6.1 box boots 6.18 next. Back is the
extlinux menu on serial, or `apt` from an SD boot.

The `next` image's bar is lower until its track becomes `current`: it boots and reaches SSH. Each
board's `board.md` carries the per-feature marks for both tracks.

## Packages

One generator, `./build.sh debs`, emits every package as a plain Debian `.deb`: the kernel's through
`make bindeb-pkg`, the rest through `dpkg-deb --build` from a `control` and a file list it writes
from `board.conf` and `payload.list`.

| Package                            | Holds                                     |
| ---------------------------------- | ----------------------------------------- |
| `linux-image-tvb-<family>-<track>` | metapackage: that track's newest kernel   |
| `linux-image-<ver>-tvb-<family>`   | kernel, in-tree modules, the track's DTBs |
| `linux-headers-<ver>-tvb-<family>` | for third-party DKMS only                 |
| `tvb-modules-<ver>-<family>`       | the out-of-tree drivers                   |
| `tvb-uboot-<board>`                | `uboot.itb`, idbloader; never flashed     |
| `tvb-firmware`                     | blobs no Debian package carries           |
| `tvb-<board>`                      | that board's `payload.list`, generated    |
| `tvb-archive-keyring`              | the `apt` repo's public signing key       |

26 a build:

- 16 kernel: image, headers, modules and metapackage, per family × track;
- 8 board: U-Boot and payload, one each; one loader boots both tracks;
- `tvb-firmware` and `tvb-archive-keyring`.

`bindeb-pkg`'s `linux-libc-dev` is not published; Debian ships it. Unchanged inputs keep their
version, so a release republishes only what moved.

Ours only add: no package replaces, shadows or rebuilds a Debian one, and none ships a file a Debian
package owns. That keeps a box Debian plus a third-party repo, not a derivative. The patched
`gst-plugins-good` in `patches/` therefore goes upstream, never into the repo as a rebuild. Images
are "based on Debian", as Debian's trademark policy allows, never "Debian".

`tvb-uboot-<board>` installs files only, as Debian's `u-boot-rockchip` does. Its postinst never
writes a sector: `apt` flashing a loader is the soft-brick `docs/apt-upgrade.md` defends against.
`tvb-install --uboot` writes it, on purpose, watched.

## Hosted on GitHub

Everything is published from this repo; no server of ours.

| What        | Where                                                              |
| ----------- | ------------------------------------------------------------------ |
| apt repo    | release `apt`, rolling, a pre-release: `.deb`s plus index          |
| images      | release `YYYY-MM-DD`: eight `tvb-<board>-<track>.img.xz`, all kept |
| checksums   | `SHA256SUMS`, signed, in the same release                          |
| signing key | public: `keyring/tvb-archive-keyring.gpg`; CI signs from a secret  |

Nothing is pruned, so any past release can be flashed to test against, or to bisect a regression.
Each release's notes list its pins and the diff from the one before: the kernel commits, the Armbian
release, the patches added or dropped. The `apt` repo keeps every kernel it ever published;
versioned names coexist, so `apt install linux-image-<ver>-tvb-<family>` goes back without a
reflash, and removing the newer kernel makes the older one the default entry.

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
deb [signed-by=/usr/share/keyrings/tvb-archive-keyring.gpg] https://github.com/<gh-repo>/releases/download/apt ./
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

## Monthly build

On the 1st, GitHub Actions repins every kernel to the newest released upstream commit within its
series, builds four kernels and eight images from scratch on GitHub's hosted runners, and publishes
a release tagged by date, `2026-10-01`. The repin rules, jobs and runner limits are in
`docs/todo/tvb-linux-build.md`.

## MAC addresses come from the drivers

`mac-pin` goes. Each driver reads its own address at probe, through the kernel series; which patch
covers which interface, and the one-time change to derived addresses, is in
`docs/todo/rk35xx-mac-pinning.md`.

## Build hosts

Linux and macOS, arm64 and x86-64, all through one container; the cross-compile path, the
prerequisites doc and the local caches are in `docs/todo/tvb-linux-build.md`.

## Boot flow

| Family    | Loader reads                          | Written by                     |
| --------- | ------------------------------------- | ------------------------------ |
| rk35xx    | `extlinux.conf`, via `distro_bootcmd` | kernel postinst, `u-boot-menu` |
| meson-gxl | FAT `boot.scr`, then the same         | image build                    |

🟡 rk35xx: `docs/uboot.md` says mainline's `distro_bootcmd` boots the image; `extlinux` is not yet
tried on our FIT. Console, `cma=` and the IR blacklist move to the extlinux `append` line.

## tvb-install

Replaces `armbian-install`, `platform-install` and `scripts/aml-emmc-install`.

| Must                                            | Source of the rule        |
| ----------------------------------------------- | ------------------------- |
| never write sectors 7168–16383 (`DVKR`, `SSKR`) | `docs/armbian-install.md` |
| write idbloader to all five slots, FIT to both  | `docs/uboot.md`           |
| find the eMMC by `boot0`/`boot1`                | `AGENTS.md`               |
| follow the factory layout on Amlogic            | `docs/emmc-layout.md`     |

## Phases

Each phase ships alone and reverts by reinstalling Armbian's kernel.

1. **rk35xx `current` kernel debs on the Armbian image.** Install on one box beside Armbian's
   kernel, Armbian's held. Done when:
   - it boots with no DKMS package installed, and `docs/board-validation.md` passes;
   - its config and module list match Armbian's package built from the same two pins;
   - Linux and macOS, arm64 and x86-64 all build it, with byte-identical modules;
   - `docs/build-host.md` exists, indexed in `AGENTS.md`, each host's section run from scratch.
   - a GitHub-hosted arm64 runner builds it, with its peak disk and wall time recorded.
2. **meson-gxl `current`**, same criteria, on the M20.
3. **apt repo.** Done when a box takes a kernel update through `apt upgrade` alone, verifying
   `InRelease` from the `apt` release.
4. **Images, `current`.** Done when every board boots its image from SD, or maskrom where there is
   no slot, and passes validation.
5. **`next` on both families.** Done when every board's `next` image boots and reaches SSH.
6. **tvb-install.** Done when SD → eMMC keeps `DVKR`/`SSKR` byte-identical on every board.
7. **Monthly build.** Done when one scheduled run repins, publishes debs and eight images under its
   date, and a forced failure on `current` publishes nothing.
8. **Delete** every row of "What it retires". Done when `grep -ri armbian firmware/ scripts/` finds
   only history.

## Costs and risks

| Risk                          | Shows as                | Answer                              |
| ----------------------------- | ----------------------- | ----------------------------------- |
| a patch stops applying        | CI fails, loudly        | track keeps its pin; an issue       |
| an Armbian patch stops        | CI fails, loudly        | wait for Armbian; not ours to fix   |
| a patch applies, but is wrong | the box misbehaves      | validation script, on hardware      |
| an out-of-tree driver's API   | CI fails on a series    | human work, with the track move     |
| an untested vendor commit     | nothing, until it bites | ❓ pin what Armbian's release built |
| kernel security updates       | upstream advisories     | the monthly repin brings them       |
| deployed boxes                | old layout              | reflash, or a one-way `tvb-update`  |

The loud rows are rarer than they look: the mt76 and btmtksdio patches applied unchanged from 6.18
to 7.2.8 and built (M20 worklog, 2026-10-12). What failed there was DKMS building 6.18's sources
against 7.2.8's headers, a mismatch in-tree drivers cannot have.

The quiet rows cost most. The only check that sees them is `docs/board-validation.md` as a script,
run on one box per family; until then a moved `current` pin is a risk the release takes unseen.

## Name

**TVBian**: repo `tvbian`, domain `tvbian.com` (registered 2026-10-18), packages under `tvb-`.
Settled before the first `apt` release, since every box's `sources.list` carries the repo URL.
Described as "based on Debian", never as Debian, which is what Debian's trademark policy asks.

## Decide

- The `tvb-` rename in `docs/todo/tvb-namespace.md` before phase 3, so packages ship the final
  names?
- BTF: dropped with debug info to fit the runner, or kept for BPF tools at the cost of disk?
- Deployed boxes: migrate in place, or reflash only?
- A repin that moved `current`: publish only after the validation script passes on one box of that
  family, or automatically like `next`?

## Done means

Phase 8 shipped, and the README's "Nothing is forked" and `AGENTS.md`'s "What this repo is" say what
the repo builds.
