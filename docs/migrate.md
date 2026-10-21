# Moving a box off the overlay, in place

From Armbian with the overlay (`rk35xx-update`, `payload.list`) to what TVBian's image installs,
without a reflash. ✅ from local debs on a meson-gxl box and two rk35xx boxes, 2026-10-20; ❓ from
the published repo, which does not exist yet.

A board can move once `kernel/` has its `BOARD_KERNEL`. The way back is the backup: Armbian's kernel
goes in step 4.

## 0. Back up

The stock eMMC in `backup/<board>/` is enough for a box with no data of its own: it holds what
cannot be recreated, and the rest rebuilds. A box with data also needs a whole copy of its boot
medium: a stick or SD on another machine, an eMMC by `docs/maskrom.md`.

## 1. Install the packages

```sh
./build.sh debs                                                           # host
scp build/out/debs/linux-image-*.deb build/out/debs/tvb-*.deb <user>@<host>:/tmp/tvb/   # host
sudo apt-get install -y u-boot-menu /tmp/tvb/*.deb                        # box
cat /boot/extlinux/extlinux.conf                                          # box
sudo systemctl reboot                                                     # box
```

Where `sshd` serves no `sftp` subsystem `scp` closes at once; `tar -cf - … | ssh … tar -xf -` copies
the same files. With our `linux-headers` installed, DKMS builds the overlay's modules for our kernel
too and archives ours as "Original modules": `sudo dkms remove <module>/<version> -k <release>`
before the reboot puts ours back.

Before the reboot, `l0` is the `-tvb-<family>` kernel, with an `initrd`,
`fdt /usr/lib/tvb/board.dtb` and the fstab's `root=`. After it, `uname -r` ends in `-tvb-<family>`.

| Family    | Who reads `extlinux.conf`                              |
| --------- | ------------------------------------------------------ |
| meson-gxl | the FAT's `boot.scr`, by `sysboot`: ✅                 |
| rk35xx    | our U-Boot's bootstd, `extlinux` ahead of `script`: ✅ |

## 2. Retire the overlay

The overlay's files the board package supersedes, moved aside, deleted at the sweep. Firmware goes
only where `/usr/lib/firmware/updates/` holds a byte-identical copy.

| Overlay file                                      | Superseded by                  |
| ------------------------------------------------- | ------------------------------ |
| `/lib/firmware/<chip>/…`                          | the same file under `updates/` |
| `/etc/systemd/{logind,system}.conf.d/zz-rk35xx-*` | `/usr/lib/systemd/*.conf.d`    |
| `/etc/udev/{rules,hwdb}.d/*rk35xx*`               | `/usr/lib/udev/{rules,hwdb}.d` |
| `/etc/kernel/*postinst.d/*rk35xx*`                | the package's DTB              |
| `/usr/local/sbin/rk35xx-*`, `rk35xx-*.service`    | the package's units, or none   |
| `/usr/local/share/rk35xx/`                        | nothing                        |
| `/etc/apt/apt.conf.d/99-rk35xx-boardname`         | the package's motd             |

```sh
find /etc /usr/local /usr/lib/systemd /usr/lib/udev -name '*rk35xx*'   # box: before and after
```

On rk35xx `mac-pin` and `vendor-storage` go too: U-Boot reads Ethernet's address from vendor
storage, and the Seekwave driver its chip's efuse, so the Wi-Fi address changes once, back to the
chip's, and DHCP may move the box. The IR driver is in-tree; its DKMS package goes with the Seekwave
one.

## 3. NetworkManager

Armbian's netplan drives networkd and wpa_supplicant; the image runs NetworkManager. On a box with
no Ethernet the switch is the step that can strand it, so a unit reverts it: no default route within
5 minutes of boot, and networkd comes back.

```sh
printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d && sudo chmod +x /usr/sbin/policy-rc.d   # box
sudo apt-get install -y network-manager avahi-daemon zstd cloud-initramfs-growroot && sudo rm /usr/sbin/policy-rc.d   # box
```

`policy-rc.d` keeps NetworkManager from starting mid-install and taking the link. Then, on the box:

- the image's `tvb-wifi.conf` into `/etc/NetworkManager/conf.d/`;
- a keyfile in `/etc/NetworkManager/system-connections/`, mode 0600: the network's SSID, PSK and any
  pinned BSSID, from where the box keeps them;

  | Family    | Wi-Fi credentials                               |
  | --------- | ----------------------------------------------- |
  | meson-gxl | `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` |
  | rk35xx    | `/etc/netplan/*wifis*.yaml`, `access-points`    |

- the fallback unit: a loop on `ip route | grep -q ^default`, else put the old config back, disable
  NetworkManager, reboot;
- netplan's YAML moved aside, so its generator writes neither networkd's config nor its own
  `netplan-wpa-<if>` supplicant; a hand-written `.network`, the M20's `25-wlan0.network`, goes with
  `wpa_supplicant@<if>` disabled;
- `NetworkManager` and `avahi-daemon` enabled; reboot.

## 4. Remove Armbian

```sh
sudo rm /etc/apt/sources.list.d/armbian*.sources && sudo apt-mark unhold $(apt-mark showhold)   # box
dkms status                                                               # box: whose each module is
sudo dkms remove <module>/<version> --all && sudo rm -rf /usr/src/<module>-<version>   # box: the overlay's
sudo apt-get purge -y linux-{image,dtb,headers}-<branch>-<family> 'linux-u-boot-*' \
  'armbian-bsp-cli-*' armbian-config armbian-firmware dkms netplan.io rsyslog fake-hwclock \
  console-setup console-setup-linux keyboard-configuration                # box
sudo apt-get update && sudo apt-get install -y --allow-downgrades -o Dpkg::Options::=--force-confnew base-files=<debian version>   # box
sudo apt-get autoremove --purge -y                                        # box
```

`<branch>-<family>` is Armbian's, `vendor-rk35xx` or `current-meson64`, never a glob:
`linux-image-*-<family>` matches TVBian's `linux-image-<release>-tvb-<family>` too. A DKMS module
the overlay did not install stays, and `dkms` with it.

Before `armbian-firmware` goes, every blob the box loads needs another owner: `dpkg -S` on its
`/usr/lib/firmware/` path names Debian's package or ours. Every box's known here does.

What the purge leaves goes by hand:

| Where                | What                                                                |
| -------------------- | ------------------------------------------------------------------- |
| `/boot`              | everything but our kernel's four files and `extlinux/`              |
| `/etc`               | `armbian*`, `default/armbian-*`, `netplan/`, `dpkg/origins/armbian` |
| `/etc/systemd`       | Armbian's drop-ins; the `systemd-firstboot` mask; `journald.conf`   |
| `/var`               | `log/armbian-*`, `log.hdd`, `lib/apt/lists/*armbian*`, the markers  |
| `/usr/src`           | the overlay's DKMS sources                                          |
| `/usr/share`         | `keyrings/armbian*`                                                 |
| `/etc/update-motd.d` | all but `10-tvbian`; `/etc/motd` emptied                            |

Armbian edits `journald.conf`, a conffile Debian's package never changed, so a reinstall keeps the
edit: Debian's comes out of `apt-get download systemd` with `dpkg-deb --fsys-tarfile`.

Then `systemd-resolved` goes: purge it, delete `/etc/resolv.conf` and restart NetworkManager, which
writes its own. The image's files replace Armbian's: fstab's options, and the journald, zram, getty,
apt and sshd drop-ins under `image/rootfs/`, with `systemd-zram-generator`. The hostname becomes the
board's `BOARD_HOSTNAME`, as the image's is: `sudo hostnamectl hostname <board>`, and the router's
DNS learns it from the next DHCP lease.

On the M20's FAT, `boot.scr` and `aml_autoscript` are the image's, and `u-boot.ext` is
`/usr/lib/tvb/u-boot.bin`, the old one kept beside it until
`/proc/device-tree/chosen/u-boot,version` names the new one. On a Rockchip box the FIT goes into
both of the eMMC's slots, the eMMC found by its `boot0`:

```sh
for s in 16384 20480; do sudo dd if=/usr/lib/tvb/u-boot.bin of=/dev/<emmc> bs=512 seek=$s conv=fsync; done   # box
```

## 5. Sweep

After a reboot with nothing failed, the network up and the board's hardware checked: the fallback
unit, networkd's mask, the old supplicant and networkd config, and the moved-aside overlay go.

```sh
find / -xdev \( -iname '*armbian*' -o -iname '*rk35xx*' \) | wc -l      # box: 0
systemctl --failed --no-legend | wc -l                                   # box: 0
```
