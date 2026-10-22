# tvb-linux: our kernel, our image

Opened 2026-10-18. Phases 1 and 2 run, since 2026-10-20: every box here migrated in place, on the
meson64 or the rk35xx kernel (`docs/migrate.md`); `./build.sh` builds the kernels, the board and
firmware packages, the keyring and the M20's image (`docs/build.md`). What goes into the rootfs is
in `docs/todo/tvb-linux-rootfs.md`.

One command, on Linux or macOS, builds every board's minimal Debian image. An apt repo published
from this repo serves our few packages; Debian's serve the rest, so `apt upgrade` keeps a box
current. Kernels come from their upstreams, kernel.org and Rockchip, pinned; no kernel is forked,
and nothing of Armbian's is needed.

## Contributions break little

A change reaches only what depends on it. The rk35xx kernel carries four small patches over
Rockchip's tree; the M20's carry the Wi-Fi, Bluetooth, HDMI and codec drivers mainline lacks. With
the right base, a box is data.

| Change                      | Lives in                            | Can break               |
| --------------------------- | ----------------------------------- | ----------------------- |
| a new box of a known family | `firmware/<board>/` → `tvb-<board>` | nothing else            |
| a board fix: tree, payload  | that board's directory              | that board              |
| a new chip's firmware       | the board's directory, until shared | that board              |
| a chip firmware update      | `tvb-firmware-<chip>`               | boards with that chip   |
| a shared payload script     | `firmware/common/`                  | every board using it    |
| a kernel patch, config, pin | `kernel/`, `patches/`               | the family: rare, gated |

A board is a directory and a package, and never touches another's. Shared things split by what they
serve: firmware per chip once two boards share it, kernel per family. CI's input-hash skip builds
only what a change moved, so a board-only change builds no kernel.

## One kernel per family

| Family  | Kernel                | Boards           |
| ------- | --------------------- | ---------------- |
| rk35xx  | Rockchip's vendor 6.1 | R69, H313, 3518D |
| meson64 | mainline 6.18         | M20              |

Each family has a `-next` kernel beside it, `kernel/<family>-next.conf`: the family's conf sourced,
the pin moved to the next series, an opt-in metapackage. It is where the next series is made to work
before the family moves, so a move is a pin change. A patch that differs by series keeps a copy per
series, `patches/<topic>/<series>/`, which the `-next` conf substitutes into the family's list; a
config change only one series needs is a second fragment, `kernel/<family>-next.fragment`.

### A kernel is a pin plus patches

`kernel/<family>.conf` is the whole kernel definition, `kernel/<family>.fragment` the settings every
kernel of the family shares:

| Key       | Holds                                             |
| --------- | ------------------------------------------------- |
| `REPO`    | the upstream tree                                 |
| `FOLLOW`  | `longterm`: kernel.org's newest long-term release |
| `BRANCH`  | a branch's tip; `develop-*`, the newest series    |
| `COMMIT`  | a full hash, for a kernel with neither            |
| `CONFIG`  | the kernel's config, kept in `kernel/`            |
| `PATCHES` | `patches/<topic>/` directories, in apply order    |

| Kernel    | `REPO`                                | Resolves to, 2026-10-20 |
| --------- | ------------------------------------- | ----------------------- |
| `rk35xx`  | `rockchip-linux/kernel` `develop-6.1` | `77168c8d5ab8`, 6.1.172 |
| `meson64` | kernel.org stable                     | `v6.18.57`              |

The build fetches the pin, `git am`s the patches, runs `make olddefconfig` on the config and
`make bindeb-pkg`. Each config started as Armbian's for that family and branch, copied once; a bump
re-runs `olddefconfig`, and the diff is reviewed in the commit that moves the pin.

Why no Armbian pin, measured 2026-10-19:

- Armbian `v26.5.1`'s `meson64-6.18` patches do not apply to 6.18.57: its HDMI-audio
  `general-meson-aiu` patch fails under Armbian's own `patch --batch -p1 -N`. A pinned release is no
  tested pairing once the kernel moves.
- Of those 65 patches, about 770 lines touch code a GX box runs; the rest is in-tree `vdec` that
  `meson-codecs` supersedes, and other boards' trees.
- Armbian's `rk-6.1-rkr5.1`, which the boxes ran before TVBian, is Rockchip's snapshot of 2025-01-25
  at 6.1.115 plus 659 commits, 382 of them other boards' trees. Rockchip's `develop-6.1` is at
  6.1.172, and Armbian's newest branch, `rk-6.1-rkr7.2`, is built on its `77168c8d5ab8`.

### Patches

`patches/<topic>/` stays one directory per upstream target, its README naming where the patches go
and their PRs. That is the only copy.

- **In-tree** patches are `git format-patch` against the pinned tree, `-p1` from the kernel root:
  what upstream takes. The driver patches applied today with `-p3` and `-p5` are rebased to that.
- **Per series**, a topic whose patches differ between two series keeps one subdirectory per series,
  `patches/<topic>/6.18/`; one that applies to both keeps none.
- **Out-of-tree drivers** are vendor code with no road upstream short of a rewrite: the Seekwave
  SWT6621S and the AIC8800 today, the meson encoders next. Each is `modules/<name>.conf`, a pin plus
  our patches, built with `make M=` against the kernel just built, into its own
  `tvb-<name>-modules-<kernelrelease>`. What could go upstream, a fix or a port of an in-tree
  driver, is a kernel patch.
- **Adopted from Armbian** where a box needs it: copied as files into `patches/<topic>/`, keeping
  the original `From:`. For meson, `patches/linux-meson/`: GX socinfo through the secure monitor, GX
  suspend and VRTC, the MMC core clocks, HDMI-audio codec selection, the GPIO IRQ fix. The aiu patch
  is rebased for 6.18.57 once, there.
- **One that lands upstream** leaves ours on the bump that pins it in: GX socinfo's first patch is
  already in mainline's tree, so it drops when meson's series moves past it. Those in
  `patches/linux-rockchip/` stay ours: Armbian closed their PRs unmerged, and Rockchip takes no
  outside patches.

### Board trees

A board's tree is never built from the kernel's: it is the box's own factory DTB, `stock/<board>/`,
plus `board.patch`, which brings it to the bindings of the kernel it runs on. The M20 already does
this across a binding change: a vendor 4.9 blob patched to mainline, mainline's p271 tree as the
reference only (`docs/h96max-m20/dtb.md`). A second series would add a patch, never a second base:
🟡 none for a newer mainline on meson, bindings being a kernel ABI; one per board for rk35xx on
mainline, every tree here deriving from the vendor kernel's blob.

A board's tree ships in its own `tvb-<board>` package, not the kernel's: trees change more often
than kernels, 22 commits to `firmware/*/board.*` against 10 to the kernel-side driver patches, and a
fix is then one small package, no kernel rebuild.

- It installs as `/usr/lib/tvb/board.dtb`, generic like the loader beside it: a box holds one board
  package, and the tree's own `model` names the board.
- `/usr/share/u-boot-menu/conf.d/tvb.conf` sets `U_BOOT_FDT` to it, and the kernel command line;
  `u-boot-menu` reads this drop-in after its own `/etc/default/u-boot`, which it owns, and before
  the admin's `/etc/u-boot-menu/conf.d/`. Every kernel's entry gets an explicit `fdt` line, on every
  family; no U-Boot names a DTB.
- The kernel deb is published as `make bindeb-pkg` makes it, its own DTBs inert.
- A tree is tied to its kernel's bindings, vendor or mainline, never to its version, so a family is
  one binding family: `rk35xx` is the vendor kernel, a mainline Rockchip kernel would be its own.
  `tvb-<board>` depends on its family's metapackage, and its tree serves every kernel of it.
- Moving a board to another family is a migration: kernel and tree change together, and the old
  family's kernel goes, unable to boot the new tree.

In the repo a tree stays `firmware/<board>/board.dts`; the directory names the board.

Adding a board stays a directory, and for a family we already have, no kernel build: bring-up
iterates on the tree alone, as `tvb-<board>` on the family's published kernel. A kernel rebuild
comes only with hardware that kernel cannot drive yet, such as a new Wi-Fi chip.

## Images

Every board, minimal: four images a build. Each is a generic base plus a board stamp.

| Stage | Per       | Holds                                               |
| ----- | --------- | --------------------------------------------------- |
| base  | family: 2 | an ext4 rootfs: Debian and the family's kernel      |
| stamp | board: 4  | the disk: layout, loader, the rootfs, `tvb-<board>` |

The base is a filesystem, not a disk, because the disk is what differs:

| Board-specific    | rk35xx                                | meson64                       |
| ----------------- | ------------------------------------- | ----------------------------- |
| layout            | GPT, rootfs past the loader           | factory partition table       |
| loader            | idbloader at 64, `uboot.itb` at 16384 | none: eMMC's factory one      |
| boot files        | none beyond the base                  | FAT: `boot.scr`, `u-boot.ext` |
| payload, firmware | `tvb-<board>`, into the copy          | same                          |

A stamp is a copy of the base plus seconds of raw writes and one package install, so the board data
stays a directory and the published file stays one `dd` or one `rkdeveloptool wl`.

The DTB is not stamped either: it comes with `tvb-<board>`, and `u-boot-menu` names it in
`extlinux.conf`.

The image installs the metapackage `linux-image-tvb-<family>`, which depends on the family's newest
kernel, as Debian's `linux-image-arm64` does.

## Packages

One generator, `./build.sh debs`, emits every package as a plain Debian `.deb`: the kernel's through
`make bindeb-pkg`, the rest through `dpkg-deb --build` from a `control` and a file list it writes
from `board.conf` and `package.list`.

`<kernelrelease>` is what `uname -r` prints, `6.18.57-tvb-meson64`: `make bindeb-pkg` with
`LOCALVERSION=-tvb-<family>` names the packages and `/lib/modules/` from it, as Debian's kernels are
named.

Versions count builds, as Debian's do: `6.18.57-1`, upstream then our revision, through
`KDEB_PKGVERSION` for the kernel. A rebuild with new inputs is `-2`; a new upstream version starts
again at `-1`; a package with no upstream version counts `1`, `2`, `3`. The next revision comes from
the published index, read with `X-Tvb-Inputs:`. An unpublished local build is `-0~local`, which
sorts below every published one. The date belongs to releases and images, not packages. Each deb
records a hash of its inputs in `X-Tvb-Inputs:`, and the hash is checked before building: a kernel
whose inputs match the published deb is not built at all, and the release reuses that deb. A
kernel's inputs are its pin, its listed patches, its config and fragment, `kernel/build.sh`, and the
build environment's tag, Debian codename plus `Containerfile` hash; not the compiler's point
release, which would rebuild every month for nothing. The date stays out of the binaries:
`KBUILD_BUILD_TIMESTAMP` is the pinned commit's date, `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST` and
`SOURCE_DATE_EPOCH` are fixed, so modules come out byte-identical on every host.

| Package                              | Holds                                                      |
| ------------------------------------ | ---------------------------------------------------------- |
| `linux-image-tvb-<family>`           | metapackage: the family's newest kernel                    |
| `linux-image-<kernelrelease>`        | kernel, in-tree modules                                    |
| `linux-headers-<kernelrelease>`      | for third-party DKMS only                                  |
| `tvb-<name>-modules-<kernelrelease>` | one out-of-tree driver, pulled by the metapackage          |
| `tvb-firmware-<chip>`                | a chip's blobs, once two boards share them                 |
| `tvb-<board>`                        | its payload, DTB, board-specific firmware and loader files |
| `tvb-archive-keyring`                | the `apt` repo's public signing key                        |

About 14 a build:

- 8 kernel: image, headers, modules and metapackage, per family;
- 4 board, one each;
- a `tvb-firmware-<chip>` per shared chip, one today, and `tvb-archive-keyring`.

`bindeb-pkg`'s `linux-libc-dev` is not published; Debian ships it. Unchanged inputs keep their
version, so a release republishes only what moved.

Ours only add: no package replaces, shadows or rebuilds a Debian one, and none ships a file a Debian
package owns. That keeps a box Debian plus a third-party repo, not a derivative. The patched
`gst-plugins-good` in `patches/` therefore goes upstream, never into the repo as a rebuild. Images
are "based on Debian", as Debian's trademark policy allows, never "Debian".

`tvb-<board>` carries the loader as files only, flat in `/usr/lib/tvb/` beside its DTB and named
alike on every board: `u-boot.bin`, the M20's chain-loaded U-Boot or a Rockchip FIT, and
`idbloader.bin` where a board has one. `tvb-install` knows by family where each goes. One board per
package, so no board directory, unlike Debian's many-board `u-boot-rockchip`. Each board package
`Provides:` and `Conflicts:` `tvb-board`, so two boards never install together. Its postinst never
writes a sector: `apt` flashing a loader can soft-brick a box. `tvb-install --uboot` writes it, on
purpose, watched.

## Hosted on GitHub

The `apt` repo and every image are GitHub release assets of this repo, signed with the key in
`keyring/`. Layout, signing, retention and the tested `apt` redirect are in
`docs/todo/tvb-linux-build.md`.

## Weekly build

Every Monday, GitHub Actions builds each kernel whose upstream moved, as `docs/sources.md` sets out,
and four images, on GitHub's hosted runners, and publishes a release tagged by date, `2026-10-01`.
The jobs and runner limits are in `docs/todo/tvb-linux-build.md`.

## MAC addresses come from the drivers

Each driver reads its own address at probe, through the kernel series.

## Build hosts

Linux and macOS, arm64 and x86-64, all through one container; the cross-compile path, the
prerequisites doc and the local caches are in `docs/todo/tvb-linux-build.md`.

## Boot flow

The last stage is always a mainline U-Boot, which reads `extlinux.conf` through distro boot; a
family differs only in how it gets there. A factory U-Boot too old for extlinux chain-loads it.

| Family  | Loader reads                          | Written by                     |
| ------- | ------------------------------------- | ------------------------------ |
| rk35xx  | `extlinux.conf`, via `distro_bootcmd` | kernel postinst, `u-boot-menu` |
| meson64 | FAT `boot.scr`, then the same         | image build                    |

✅ rk35xx: our FIT's bootstd reads `extlinux.conf` ahead of `boot.scr`; the console, `cma=` and the
IR blacklist are in `tvb-<board>`'s `u-boot-menu` drop-in.

## Migrating a running box

`docs/migrate.md` moves a Debian-family system on a supported board to TVBian's packages in place,
no reflash. Armbian first: every box here ran it, and all have moved.

1. back up the eMMC, by maskrom or SD;
2. install `tvb-archive-keyring.gpg` and the `deb` line;
3. install `tvb-<board>`, `linux-image-tvb-<family>` and `u-boot-menu`;
4. remove Armbian's kernel and `armbian-bsp-*`, the `rk35xx-*` overlay as `docs/migrate.md` retires
   it, and the `linux-u-boot-*` hold once `tvb-<board>` is in;
5. reboot on serial: `uname -r` ends in `-tvb-<family>`, and validation passes.

Armbian and plain Debian are what it is run on. ❓ Ubuntu: our kernel debs need only `kmod` and
`initramfs-tools`, but nobody has tried.

## tvb-install

It ships in `tvb-<board>`, as `/usr/sbin/tvb-install`, not as a package of its own: what it writes
is the board's, and the board package already carries it. One script for every family,
`firmware/common/tvb-install`: it copies the running system to another disk, USB, eMMC or SD, the
eMMC by default, so eMMC to stick is a backup. `tvb-install [-y] [device]`; `-y` skips the question,
and running from the eMMC needs the device.

An image, or a migrated eMMC, holds the board's whole eMMC layout, the vendor's regions included, so
the running disk is the source, if its rootfs is labelled `tvbian`: its partition table with the
rootfs grown, the rootfs by file under a new UUID, then every sector before it raw, but the unit's
own. A board lists those in `firmware/<board>/preserve-sectors`, one range per line, `first-last`
inclusive, with a `#` note the installer prints, shipped as `/usr/lib/tvb/preserve-sectors`; a board
without it ships no `tvb-install`.

| Family    | Preserved sectors: the unit's own    |
| --------- | ------------------------------------ |
| meson-gxl | `reserved`'s unifykeys: serial, MACs |
| rk35xx    | `DVKR`, `SSKR`: 7168–16383           |

| Must                                            | Source of the rule    |
| ----------------------------------------------- | --------------------- |
| never write sectors 7168–16383 (`DVKR`, `SSKR`) | `docs/emmc-layout.md` |
| write idbloader to all five slots, FIT to both  | `docs/uboot.md`       |
| find the eMMC by `boot0`/`boot1`                | `AGENTS.md`           |
| follow the factory layout on Amlogic            | `docs/emmc-layout.md` |

## Phases

Each phase ships alone and reverts by reinstalling Armbian's kernel.

1. **The meson64 kernel debs on the M20's Armbian image**, the first TVBian box. Install beside
   Armbian's kernel, Armbian's held; the chain-loaded Lepotato U-Boot stays. Done when:
   - it boots with no DKMS package installed, and `docs/board-validation.md` passes;
   - mt76, btmtksdio, `meson-dw-hdmi` and `meson-codecs` are in-tree patches;
   - it boots from `extlinux.conf`, rewritten by `u-boot-menu`'s kernel hook on every install: no
     Armbian `/boot` links, no `uInitrd`. Checked first, since it is 🟡: that the chain-loaded
     Lepotato U-Boot scans `extlinux.conf` before `boot.scr`, as mainline distro boot does;
   - every module the box loads today is in the package, and the config differs from Armbian's
     `current-meson64` only where our fragment says;
   - macOS on Apple silicon and Linux on arm64 and x86-64 all build it, with byte-identical modules;
   - `docs/build-host.md` exists, indexed in `AGENTS.md`, each host's section run from scratch;
   - a GitHub-hosted arm64 runner builds it, with its peak disk and wall time recorded.
2. **The rk35xx kernel** on one Rockchip box: the criteria above, its drivers (IR, Seekwave) in
   place of the M20's.
3. **apt repo, and migrating a running box.** Done when:
   - a box takes a kernel update through `apt upgrade` alone, verifying `InRelease` from `apt`;
   - `docs/migrate.md` exists, indexed in `AGENTS.md`, and the deployed M20 was migrated by
     following it as written.
4. **Images.** Done when every board boots its image from SD, or maskrom where there is no slot, and
   passes validation.
5. **tvb-install.** Done when SD → eMMC keeps `DVKR`/`SSKR` byte-identical on every board.
6. **Weekly build.** Done when one scheduled run publishes debs and four images under its date, and
   a forced failure publishes nothing.
7. **One entry point.** Fold the root `build-*.sh` that survive into `src/tools/`, per
   `docs/todo/repo-layout.md`. Done when `./build.sh` is the only build entry at the root.

## Costs and risks

| Risk                          | Shows as             | Answer                             |
| ----------------------------- | -------------------- | ---------------------------------- |
| a patch stops applying        | CI fails, loudly     | the kernel keeps its pin; an issue |
| a patch applies, but is wrong | the box misbehaves   | validation script, on hardware     |
| an out-of-tree driver's API   | CI fails on a series | human work, with the series move   |
| an untested vendor tip        | the box misbehaves   | validation script, on hardware     |
| kernel security updates       | upstream advisories  | the weekly build follows them      |
| deployed boxes                | old layout           | `docs/migrate.md`, in place        |

The loud rows are rarer than they look: the mt76 and btmtksdio patches applied unchanged from 6.18
to 7.2.8 and built (M20 worklog, 2026-10-12). What failed there was DKMS building 6.18's sources
against 7.2.8's headers, a mismatch in-tree drivers cannot have.

The quiet rows cost most. The only check that sees them is `docs/board-validation.md` as a script,
run on one box per family; until then a moved pin is a risk the release takes unseen.

## Name

**TVBian**: repo `tvbian`, domain `tvbian.com` (registered 2026-10-18), packages under `tvb-`.
Settled before the first `apt` release, since every box's `sources.list` carries the repo URL.
Described as "based on Debian", never as Debian, which is what Debian's trademark policy asks.

## Decide

One-way doors first: each is copied onto every installed box, so each is settled before the first
`apt` release. The URL is not one: the keyring package owns the apt source file too, so a package
update can move the repo, and hosting stays changeable without a domain or redirect service of ours.
The same package can rewrite the source's format and rename the key, so those are two-way as well.

- The eMMC layout `tvb-install` writes, by phase 5: offsets, filesystem, the M20's FAT; changing it
  later means a reflash.

Two-way:

- The apt source's format: deb822 `/etc/apt/sources.list.d/tvbian.sources`, as trixie's own
  `debian.sources`, or a one-line `.list`?
- The keyring's name, which every source's `signed-by=` names: `tvb-archive-keyring`, or
  `tvbian-archive-keyring` after `debian-archive-keyring`?
- BTF: dropped with debug info to fit the runner, or kept for BPF tools at the cost of disk?
- A kernel that moved: publish only after the validation script passes on one box of that family, or
  automatically?

## Done means

Phase 7 shipped, and the README's "Nothing is forked" and `AGENTS.md`'s "What this repo is" say what
the repo builds.
