# Moving a box off the overlay

Before 2026-10-22 TVBian shipped as an overlay on an Armbian image: `rk35xx-update`, `payload.list`,
DKMS drivers. Those images and that tool are gone. Back up first; then move in place, or reinstall.

## In place — Rockchip

Keeps the system as it is. ✅ on three rk35xx boxes from local debs, 2026-10-20; 🟡 from the
published repo, the same packages. Every command runs on the box.

**1. TVBian's packages and files**, then a reboot into its kernel:

```sh
wget https://github.com/sormy/tvbian/releases/download/apt/tvb-archive-keyring_1_all.deb
sudo apt install ./tvb-archive-keyring_1_all.deb && sudo apt update
sudo apt install u-boot-menu tvb-<board> systemd-zram-generator
# the image's own /etc files, zram's among them; not its locale or its root-password login
curl -fsSL https://github.com/sormy/tvbian/archive/refs/heads/main.tar.gz | sudo tar -xz -C / \
  --strip-components=3 --exclude='*/etc/default/locale' --exclude='*/tvb-root-password.conf' \
  tvbian-main/image/rootfs
grep -m1 tvb /boot/extlinux/extlinux.conf && sudo reboot      # then: uname -r ends in -tvb-rk35xx
```

**2. The overlay** — its units, scripts, hooks, rules and keymap, `r69-` in early images and
`rk35xx-` later; a file a package owns is never touched:

```sh
sudo systemctl disable --now $(systemctl list-unit-files 'r69-*' 'rk35xx-*' --no-legend | cut -d' ' -f1)
find /etc /usr/local /usr/lib/systemd /usr/src \( -name '*r69*' -o -name '*rk35xx*' \) -prune |
  while read -r f; do dpkg -S "$f" >/dev/null 2>&1 || sudo rm -rf "$f"; done
# and the ones it named without a prefix
sudo rm -f /etc/udev/hwdb.bin /etc/systemd/system/multi-user.target.d/10-{r69,h96max*}.conf \
  /etc/modules-load.d/{seekwave,aic8800}.conf /etc/systemd/system/serial-getty@ttyFIQ0.service \
  /etc/modprobe.d/blacklist-aic8800-usb.conf
```

**3. Every DKMS module**, packaged or added by hand, while `dkms` still exists:

```sh
for m in $(dkms status | cut -d, -f1 | sort -u); do sudo dkms remove "$m" --all; done
```

**4. Armbian** — its repository, kernel, U-Boot packages, BSP and `base-files`:

```sh
sudo rm /etc/apt/sources.list.d/armbian*.sources && sudo apt-mark unhold $(apt-mark showhold)
sudo apt purge linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx 'linux-u-boot-*' \
  'armbian-bsp-cli-*' armbian-config dkms '*-dkms' && sudo apt autoremove --purge
sudo apt install --allow-downgrades base-files/trixie
```

**5. What they leave** — Armbian's `/boot` files and RAM log, whose logrotate entries still name
`/var/log.hdd`; DKMS's sources, builds and state; the purged kernel's modules; copied firmware:

```sh
sudo rm -f /boot/armbianEnv.txt /boot/boot.scr /boot/boot.cmd /boot/uInitrd* /boot/Image /boot/dtb
sudo rm -rf /etc/armbian* /etc/default/armbian-* /etc/dpkg/origins/armbian /usr/share/keyrings/armbian* \
  /var/lib/apt/lists/*armbian* && sudo apt clean
sudo rm /etc/bluetooth/main.conf && sudo apt install --reinstall -o Dpkg::Options::=--force-confmiss bluez
sudo rm -rf /var/log.hdd && sudo sed -i 's#/var/log\.hdd#/var/log#' /etc/logrotate.d/*
for d in /usr/src/* /lib/modules/* /lib/modules/*/updates/dkms /var/lib/dkms; do
  [ -e "$d" ] && ! dpkg -S "$d" >/dev/null 2>&1 && sudo rm -rf "$d"; done
find /usr/lib/firmware -type f | while read -r f; do dpkg -S "$f" >/dev/null 2>&1 || sudo rm "$f"; done
sudo e2label "$(findmnt -no SOURCE /)" tvbian                 # the label tvb-install expects
```

**6. Check**, after a reboot — each prints `0`:

```sh
find / -xdev \( -iname '*armbian*' -o -name '*r69-*' -o -name 'rk35xx-*' \) | wc -l
dpkg -l | grep -c dkms
systemctl --failed --no-legend | wc -l
```

Networking stays Armbian's; the image's NetworkManager is optional.

## Reinstall — Amlogic, or a clean box

The overlay's Amlogic stick boots through Armbian's `boot.scr`, which never reads TVBian's
`extlinux.conf`, so it takes the image instead.

1. Copy off what is yours: `/home`, `/srv`, any `/etc` file you changed.
2. Write the board's image from the latest release to an SD card or USB stick, as the README gives
   it; an Amlogic box the overlay set up already boots its stick. A box with no card slot takes it
   straight onto the eMMC over USB, `docs/rockchip-maskrom.md`, unit's own sectors restored after.
3. Boot it; `sudo tvb-install` writes the eMMC and keeps the unit's MAC and serial.
4. Put your files back; `docs/first-login.md` covers the user, locale and Wi-Fi.
