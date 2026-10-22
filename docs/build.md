# Building TVBian

`./build.sh` runs every step in one container image, `build-env/Containerfile` on Debian stable.
Outputs land in `build/out/`; the kernel tree and caches in the `tvb-work` volume.

## Hosts

| Host           | Runtime           | State                                         |
| -------------- | ----------------- | --------------------------------------------- |
| macOS arm64    | Apple `container` | ✅ `brew install container`                   |
| Linux arm64    | `podman`          | ❓ `sudo apt install podman`                  |
| Linux x86-64   | `podman`, `qemu`  | ❓ `sudo apt install podman qemu-user-static` |
| GitHub Actions | `podman`, rootful | ✅ `ubuntu-24.04-arm`, `release.yml`          |

Every host builds in the same image, Debian stable on arm64, so each gets the same toolchain; an
arm64 host could build without it, and does not. An x86-64 host runs that arm64 image under `qemu`
(`--platform linux/arm64`): the same steps and outputs, slower for every instruction it emulates.
`binfmt_misc` belongs to the host kernel, so the host's `qemu-user-static` registers `aarch64`. ❓
byte-identical modules from a macOS and a Linux host.

The work volume is a case-sensitive ext4, never a bind mount: macOS's APFS is case-insensitive, and
the kernel has names that differ only by case (`xt_TCPMSS.h`, `xt_tcpmss.h`).

Maskrom, `amlcmd` and writing a card stay on the host: a container on macOS reaches no USB. So do
the tools they need: `./build.sh tool <name>` builds one from `src/tools/<name>/` natively, into
`build/tools/<name>/`, its commands linked in `build/bin/`; `./build.sh tools` builds every one.

| Host         | Beyond the runtime                       |
| ------------ | ---------------------------------------- |
| macOS arm64  | `xz`; host tools from `./build.sh tools` |
| Linux arm64  | a udev rule for maskrom USB              |
| Linux x86-64 | the same                                 |

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
`TVB_BUILD_SUITE=forky` builds against Debian testing.

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
and the images with a signed `SHA256SUMS` to a release named by the day, `.2` for a second. It
uploads the files built, never a rebuild, and refuses a dirty tree or an unpushed commit, so every
release names its commit. One key signs CI's releases and a Mac's alike.

## CI

`.github/workflows/release.yml` splits the same steps into jobs, on `ubuntu-24.04-arm`: native
arm64, GitHub's hosted runners, free for a public repo.

| Job     | Count        | Does                                                        |
| ------- | ------------ | ----------------------------------------------------------- |
| plan    | 1            | each group's version, `new` or `published`, as an artifact  |
| kernel  | one a kernel | that kernel's debs, unless already published; as artifacts  |
| release | 1            | firmware, boards, keyring, the guard, images, repo, publish |

| Trigger                   | Builds                | Publishes |
| ------------------------- | --------------------- | --------- |
| `schedule`, Mondays 03:17 | everything that moved | yes       |
| `workflow_dispatch`       | the same              | yes       |
| a push to a build input   | the same              | no        |
| a pull request            | at the PR's pins      | no        |

The last job starts only once every kernel job passed, so a failure publishes nothing; only it
signs, from the `ARCHIVE_SIGNING_KEY` secret. A dispatch with `clean` builds without ccache.

- **Schedule:** off the hour, where GitHub delays or drops fewest runs. A public repo's schedule is
  disabled after 60 days without a push; a dispatch revives it, and covers a dropped week.
- **Disk:** a runner has 14 GB, the binding limit. The fragment's `CONFIG_DEBUG_INFO_NONE=y` drops
  debug info and BTF, and each job deletes the runner image's preinstalled toolchains.
- **ccache** alone carries over: each kernel job keeps its own through `actions/cache`
  (`TVB_BUILD_CCACHE_DIR`), about 1 GB a kernel against the repo's 10 GB. A pull request reads
  `main`'s and saves only its own; one unused for 7 days is evicted.
- **Unchanged pins** still give a new image: `mmdebstrap` pulls the week's Debian updates.

`docs/sources.md` holds what floats and what is pinned.

## Hosting

Everything is published from this repo, as GitHub releases.

| What        | Where                                                   |
| ----------- | ------------------------------------------------------- |
| apt repo    | release `apt`, rolling, never latest: `.deb`s and index |
| images      | release `YYYY-MM-DD`, every one kept                    |
| checksums   | `SHA256SUMS`, signed, beside the images                 |
| signing key | `keyring/tvb-archive-keyring.gpg`; CI signs from secret |

An image is named `tvbian-<YYYY-MM-DD>-<board>-<codename>.img.xz`, so a downloaded file still says
what it is. Nothing is pruned: a past image can be flashed to bisect, and `apt` keeps every kernel
it published under versioned names, so `apt install linux-image-<kernelrelease>` goes back without a
reflash. ❓ whether GitHub caps assets per release; `apt` gains about 150 kernel debs a year.

The repo is flat, `Packages.xz`, `Release` and `InRelease` beside the `.deb`s, from
`apt-ftparchive`, signed with `gpg`. apt's `https` method follows `releases/download`'s redirect to
the asset and checks its hash; ✅ in a `debian:trixie` container, 2026-10-18.

```sh
deb [signed-by=/usr/share/keyrings/tvb-archive-keyring.gpg] https://github.com/sormy/tvbian/releases/download/apt ./
```

The key never expires: a box that missed a renewed keyring would fail `apt update` with `EXPKEYSIG`
and could not fetch the fix. Rotation is in `keyring/README.md`.

## Image

`mmdebstrap --variant=minbase` of the suite, plus one list, `image/packages.list`, shared by every
board, and `image/rootfs/`'s files. A board adds packages only through `tvb-<board>`'s `Depends:`;
nothing per image. Every package is Debian's except the `tvb-*` ones, so `apt upgrade` keeps the
whole box current. No desktop, no recommends, no translations.

Each build reads the suite's codename from Debian's `stable` alias, so a new Debian release
publishes the week it lands. A box never moves on its own: its `sources.list` names the codename.

### First boot

- **Login:** `ssh root@<board-key>.local`, password `1234`, expired by `chage -d 0`, so PAM asks for
  a new one before any shell. A drop-in lets `sshd` take a root password. A second box of the same
  board answers as `<board-key>-2.local`.
- **No Ethernet:** a USB Ethernet adapter (`r8152`, `ax88179_178a`, `asix`, `cdc_ether`, `cdc_ncm`
  in the fragment), or HDMI and a keyboard on `tty1`, then `nmtui`.
- **Unique per box:** SSH host keys and `machine-id`, generated at first boot.
- **The rootfs** fills its medium: `x-systemd.growfs`, with a quarter free in the image.
- **`systemd-firstboot`** adds nothing: on a Debian rootfs with `/etc/shadow` present it never asks
  for a root password, and the image presets locale, keymap and timezone.

The rest, a user, the timezone, the locale and Wi-Fi, is `docs/first-login.md`.

### Firmware

The vendor's, from the board's stock image, unless a newer build or one that runs on our driver
replaces it: each file's origin and version is in its package's `README.md`. No Debian firmware
package is a dependency: `firmware-mediatek` is 46 MB for one file, `firmware-misc-nonfree` 13 MB
for two, both older than or identical to the stock builds.

| Blob              | Source                     | Ships in                |
| ----------------- | -------------------------- | ----------------------- |
| Seekwave SWT6621S | H313, 3518D stock          | `tvb-firmware-swt6621s` |
| MT7668            | M20 stock                  | `tvb-firmware-mt7668`   |
| AIC8800D80        | armbian/firmware           | `tvb-firmware-aic8800`  |
| meson vdec, venc  | M20 stock; WAVE420L, newer | `tvb-firmware-amlogic`  |

The meson H.264 file is the factory's newer GXL build and shadows Debian's on any Amlogic box. Three
others are GXLX2's builds of names Debian builds for G12A and GXL: they install to
`updates/meson/gxlx2/`, which no request names, and the M20 links them into `/usr/lib/tvb/firmware`.

### eMMC wear

| Writer      | Where                    | Mechanism                               |
| ----------- | ------------------------ | --------------------------------------- |
| swap        | zram, half of RAM        | `systemd-zram-generator`                |
| the journal | RAM, batched to the eMMC | `tvb-journal-spill`, in `tvb-<board>`   |
| `/tmp`      | tmpfs                    | trixie's default                        |
| `/var/log`  | eMMC: `apt`, `dpkg` only | minbase ships no `rsyslog`              |
| TRIM        | weekly                   | `fstrim.timer`, enabled by `util-linux` |

The journal stays in `/run`, 64 MB, and moves to `/var/log/journal` at three quarters full (a
15-minute check), daily and at shutdown, so `journalctl -b -1` reads the previous boot. An unplug
loses what had not moved yet.

### Taken from Armbian

What `armbian-bsp` does, done by a Debian package where one exists and by ours only where none does.

| Need                      | Armbian                     | TVBian                              |
| ------------------------- | --------------------------- | ----------------------------------- |
| root, `1234`, must change | `armbian-firstlogin`        | `chage -d 0 root`                   |
| rootfs fills the medium   | `armbian-resize-filesystem` | `x-systemd.growfs`                  |
| swap in RAM               | `armbian-zram-config`       | `systemd-zram-generator`            |
| logs in RAM               | `armbian-ramlog`            | `tvb-journal-spill`, journald flush |
| login names the board     | `armbian-motd`              | `update-motd.d`, in `tvb-<board>`   |
| Wi-Fi power-save off      | NM conf                     | the same, with a stable MAC         |
| boot log stays on tty1    | `getty@tty1` drop-in        | the same drop-in                    |
| lean image                | apt conf                    | the same lines                      |

Power-save stays off: every box is mains-powered, so it would only add latency. The console gets the
kernel's boot log until `kernel.printk = 1 4 1 7` applies; after that only emergencies, oopses and
panics, with `dmesg` and the journal keeping the rest.
