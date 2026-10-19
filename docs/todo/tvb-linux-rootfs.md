# tvb-linux: the rootfs

Opened 2026-10-18. Planned, not started. The image build itself is in `docs/todo/tvb-linux.md`.

Every image is minimal and every package in it is Debian's, except the few `tvb-*` ones, so
`apt upgrade` keeps the whole box current. Armbian contributes nothing at runtime.

## Minimal

`mmdebstrap --variant=minbase` of the suite, plus one list, `rootfs/packages.list`, shared by every
board. A board adds only through its `tvb-<board>` package's `Depends:`, `bluez` where it has
Bluetooth; nothing per image.

| Group       | In the list                                                            |
| ----------- | ---------------------------------------------------------------------- |
| boot        | `systemd-sysv`, `udev`, `kmod`, `initramfs-tools`, `u-boot-menu`       |
| network     | `network-manager`, `wpasupplicant`, `wireless-regdb`, `iw`, `iproute2` |
| naming      | `avahi-daemon`                                                         |
| access      | `openssh-server`, `sudo`                                               |
| apt         | `apt`, `ca-certificates`, `tvb-archive-keyring`                        |
| first run   | `systemd-repart`, `systemd-zram-generator`                             |
| first login | `adduser`, `fzf`, `locales`                                            |

`wpasupplicant` and `wireless-regdb` are only `network-manager`'s Recommends, so the list names
them: without `regulatory.db` the kernel stays on the world domain, short of 5 GHz channels.

No desktop, no recommends, no translations. Anything more is `apt install` on the box.

## First boot: who gets in

Plug in Ethernet, `ssh root@<board-key>.local`, password `1234`, as on Armbian; `avahi-daemon`
answers the name over mDNS, which macOS and Windows resolve natively. A second box of the same board
on the network becomes `<board-key>-2.local`, whichever booted second; `hostnamectl` fixes it for
good. The password ships expired (`chage -d 0 root`), so the first login sets a new one; a drop-in
lets `sshd` take a root password, which Debian's default `prohibit-password` refuses. The window is
first boot to first login, on the owner's network.

A box without Ethernet, like the 3518D, takes either:

- a USB Ethernet adapter, then the same `ssh`;
- an HDMI screen and a USB keyboard: log in on `tty1`, join Wi-Fi with `nmtui`.

Our kernel fragment builds the USB Ethernet drivers as modules: `r8152`, `ax88179_178a`, `asix`,
`cdc_ether`, `cdc_ncm`. Armbian's rk35xx config names `r8152`, `ax88179_178a`, `lan78xx` and
`smsc95xx`, not `asix` or the class drivers; ❓ whether those come by default, so the fragment sets
them. `nmtui` ships in `network-manager`.

No seed file, no extra partition: the image is the same for every owner.

### First login

The expired password makes PAM ask for a new one before any shell, on SSH and on `tty1` alike. Then
root's first interactive login runs `tvb-firstlogin`, from `/etc/profile.d/`, once:

| Step     | Tool                                                                      |
| -------- | ------------------------------------------------------------------------- |
| a user   | `adduser`, added to `sudo`                                                |
| timezone | `timedatectl list-timezones`, filtered by `fzf`                           |
| locale   | `SUPPORTED`'s UTF-8 lines through `fzf`, `locale-gen`                     |
| Wi-Fi    | `nmcli device wifi list` through `fzf`, `nmcli --ask device wifi connect` |

The default stays `C.UTF-8`, and the picker offers UTF-8 locales only.

Every list filters as you type, the fix for Armbian's wizard, whose locale list neither fits a
screen nor searches. Esc skips a step; finishing writes `/var/lib/tvb/firstlogin.done`, and an
interrupted run starts again at the next login. Wi-Fi is offered only where a Wi-Fi device exists.

`systemd-firstboot` adds nothing here. On a Debian rootfs it never asks for a root password: with
`/etc/passwd` and `/etc/shadow` present and root at `*`, `--prompt-root-password` exits 0 silently.
✅ trixie, `systemd` 257.13, 2026-10-18:

```sh
systemd-firstboot --root=/tmp/r --prompt-root-password </dev/null; echo $?   # host container: 0
```

It also runs before `sshd`, prompting only on the last `console=`, our `tty1`. The image presets
locale, keymap and timezone (`C.UTF-8`, `us`, `UTC`), so it has nothing to ask at all.

## Firmware

Taken from the first place that carries the blob, in this order, so as much as possible updates
through Debian:

1. a Debian `firmware-*` package — `apt` keeps it current;
2. `armbian/firmware`, pinned to a commit, only for a blob Debian lacks;
3. this repo, for a blob nobody publishes, or one we patched.

| Blob              | Today                          | Candidate                           |
| ----------------- | ------------------------------ | ----------------------------------- |
| Seekwave SWT6621S | `firmware/common/seekwave-fw/` | this repo                           |
| MT7668 Wi-Fi, BT  | `firmware/h96max-m20/mt7668/`  | ❓ `firmware-mediatek`, else ours   |
| AIC8800D80        | Armbian's image                | ❓ Debian, else `armbian/firmware`  |
| meson vdec, venc  | `firmware/h96max-m20/meson/`   | ❓ Debian's `firmware-*`, else ours |

Phase 1 of the image build settles each ❓ with `dpkg -S` against the blob's path in a trixie
container. What remains ours ships as `tvb-firmware`.

## eMMC wear

Logs and swap stay in RAM; the eMMC sees package installs and user data.

| Writer      | Where                      | Mechanism                   |
| ----------- | -------------------------- | --------------------------- |
| swap        | zram, half of RAM          | `systemd-zram-generator`    |
| the journal | `/run/log/journal`, capped | journald `Storage=volatile` |
| `/tmp`      | tmpfs                      | trixie's default            |
| `/var/log`  | eMMC: `apt`, `dpkg` only   | minbase ships no `rsyslog`  |

`Storage=volatile` loses the previous boot's journal; serial covers a boot that dies. Armbian's
`armbian-ramlog` keeps it, by putting `/var/log` on a 50 MB zram and `rsync`ing it to disk daily and
at shutdown — a script of ours for logs a minimal image barely writes.

Measured per board in `board.md`, before and after: sectors written over an idle day, and the eMMC's
own life estimate.

```sh
awk '{print $7}' /sys/block/mmcblkN/stat                  # box: sectors written since boot
sudo mmc extcsd read /dev/mmcblkN | grep -iE 'LIFE|EOL'    # box: mmc-utils, wear estimate
```

## Taken from Armbian

What an image needs that `armbian-bsp` does today, from `packages/bsp/common/` in `armbian/build`. A
Debian package does it where one exists; ours only where none does.

| Need                      | Armbian                     | tvb-linux                            |
| ------------------------- | --------------------------- | ------------------------------------ |
| root, `1234`, must change | `armbian-firstlogin`        | `chage -d 0 root`                    |
| unique SSH host keys      | `armbian-firstrun`          | `ssh-keygen -A` at first boot        |
| unique `machine-id`       | `armbian-firstrun`          | empty in the image                   |
| rootfs fills the medium   | `armbian-resize-filesystem` | `systemd-repart`, `x-systemd.growfs` |
| swap in RAM               | `armbian-zram-config`       | `systemd-zram-generator`             |
| logs in RAM               | `armbian-ramlog`            | journald `Storage=volatile`          |
| login names the board     | `armbian-motd`              | `update-motd.d`, in `tvb-<board>`    |
| Wi-Fi power-save off      | NM conf, `iw` udev rule     | the same two files                   |
| stable Wi-Fi MAC          | NM conf                     | the same file                        |
| boot log stays on tty1    | `getty@tty1` drop-in        | the same drop-in                     |
| lean image                | apt conf                    | the same two lines                   |

Wi-Fi power-save stays off: it saves battery, and every box here is mains-powered, so it would only
add latency. The login banner adds IP and temperature, as `armbian-motd` does.

Not taken: `armbian-hardware-optimize` (no case for RK3528 or GXL), `armbian-led-state` (ours),
`armbian-firstlogin` and autologin (an expired password does the forcing), the `uInitrd` hook
(extlinux reads a plain initrd), `armbian-add-overlay` (whole DTBs), `armbianmonitor` and `ddbr`
(serial and maskrom backup cover them), the Realtek, Chromium and AXP udev rules (no such hardware),
`armbian-config`.

The `/tmp` tmpfs that breaks a large `apt full-upgrade` in `docs/apt-upgrade.md` is Debian trixie's
own default, so it comes along regardless.

## Decide

- A keymap step for a USB keyboard on `tty1`: `console-setup` and one more `fzf` list, or US only?
- Debian `trixie`, or `forky` for a newer Mesa?
