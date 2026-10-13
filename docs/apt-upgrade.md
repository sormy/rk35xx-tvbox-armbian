# Surviving `apt upgrade`

The overlay's whole premise is that kernel and userspace keep coming from Armbian. Four things
defend that, all installed by the payload. Three are `apt`/kernel hooks, one is a package hold.

| Defends against                           | Mechanism                                         |
| ----------------------------------------- | ------------------------------------------------- |
| DKMS failing on a kernel+headers upgrade  | `/etc/kernel/postinst.d/00-rk35xx-kernel-prepare` |
| a kernel upgrade shipping only stock DTBs | `/etc/kernel/postinst.d/rk35xx-dtb-persist`       |
| `armbian-bsp` resetting the board name    | `/etc/apt/apt.conf.d/99-rk35xx-boardname`         |
| a u-boot package flashing ROCK 2F loaders | `apt-mark hold linux-u-boot-*`, set at first boot |

## DKMS dies without the headers' host tools

On a combined `linux-image` + `linux-headers` upgrade, dpkg configures **`linux-image` first**. Its
postinst fires `/etc/kernel/postinst.d/dkms` while the `linux-headers` postinst — the one that
compiles `scripts/basic/fixdep` and `scripts/mod/modpost` — has not run. The headers _source_ is
already unpacked, so an out-of-tree `make M=… modules` finds the tree but not the tools and dies
with `scripts/basic/fixdep: not found` (exit 127). Every DKMS module fails and the kernel package is
left half-configured.

The hook installs with a `00-` prefix so it sorts **before** the dkms hook, and pre-builds those
tools. It replicates the `linux-headers` postinst steps rather than running `modules_prepare`, which
pulls in `archprepare` and fails on Armbian's stripped headers. It is a no-op once the tools exist —
so on a box where the headers were configured first there is no log at all — and it never fails the
kernel postinst. When it does run it appends to `/var/log/rk35xx-kernel-prepare.log`.

## The DTB is ours, the directory is the kernel's

A kernel upgrade creates `/boot/dtb-<version>/` and populates it with stock DTBs only. `dtb-persist`
copies `/usr/local/share/rk35xx/board.dtb` over the `fdtfile` named in `/boot/armbianEnv.txt`.

Consequence when reverting a bad tree: fix **both** copies. Replacing only
`/boot/dtb-*/rockchip/board.dtb` leaves the identity dir holding the bad one, and the next kernel
upgrade reinstates it.

## Board name and the bootloader

`armbian-bsp` upgrades rewrite `BOARD_NAME` in `/etc/armbian-release`. A dpkg `Post-Invoke` hook
runs `rk35xx-boardname`, which restores it from `/usr/local/share/rk35xx/board-name`. `BOARD` itself
stays `rock-2f` — that is what the base image is, and changing it would break Armbian's own scripts.

The `linux-u-boot-*` package is **held** from first boot — `linux-u-boot-rock-2f-vendor` on every
box here, which all run the same `rock-2f` base. Its postinst flashes ROCK 2F loaders, which this
DRAM cannot run, so removing the hold soft-bricks the box on the next upgrade.

## `/tmp` is a tmpfs, and `armbian-firmware` does not fit in it

A `full-upgrade` that pulls `armbian-firmware` can die part-way with the rootfs almost empty:

```
E: Write error - ~LZMAFILE (28: No space left on device)
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

`df /` is misleading here — on the 3518D it read **11 G free** at the moment of failure. Armbian
mounts `/tmp` as a tmpfs sized from RAM (984 MB on a 2 GB box), and that is what fills while apt
decompresses. The kernel package is then left half-configured (`dpkg -l` shows `iF`).

Recover, and avoid it next time, by putting apt's scratch on real disk:

```sh
sudo mkdir -p /var/tmp/aptwork
sudo TMPDIR=/var/tmp/aptwork dpkg --configure -a          # finish the half-configured package
sudo TMPDIR=/var/tmp/aptwork apt-get -y full-upgrade
```

**A half-configured kernel package is not automatically a broken boot** — check before rebooting. On
the 3518D `/boot` still held a complete set for the running kernel, `Image`/`uInitrd`/`dtb` symlinks
all resolved, and the box rebooted cleanly once `dpkg --configure -a` finished.

## A kernel the DKMS sources were not fetched for

A DKMS package is one source tree, built for every installed kernel. The mainline-derived trees
(mt76, btmtksdio, HDMI, the decoder's `v4l2-h264.c`) come from one kernel version, so headers of
another series build what they can and mt76 fails. Before booting the new kernel, on the box:

```sh
sudo rk35xx-update --kernel <release>    # as uname -r will print it; builds for that kernel alone
```

Modules built for other kernels stay installed. A later plain `rk35xx-update` refetches for the
running kernel.

## After an upgrade

```sh
dkms status                                            # every module installed
cmp "/boot/dtb-$(uname -r)/$(sed -n 's/^fdtfile=//p' /boot/armbianEnv.txt)" \
    /usr/local/share/rk35xx/board.dtb                  # silent = the tree survived
grep BOARD_NAME /etc/armbian-release
apt-mark showhold                                      # linux-u-boot-* still listed
```

✅ All four checked on the R69, 2026-08-20.
