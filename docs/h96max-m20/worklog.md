# H96 Max M20 — worklog

Dated history, wrong turns included. Board id `h96max-m20`, provisional — the box's own strings say
`S905LTS` on platform `p291`. PCB silkscreen `905_DG_ZX01_V01 2025/09/03`.

## 2026-09-14 — serial, root shell, full small-evidence sweep

**This box is Amlogic, not Rockchip.** The first line out of the ROM is
`GXLX2:BL1:3cfee7:42a5ae;FEAT:ADFD318C:0;…`. The loader pair and the maskrom route do not carry
over; the rest of the overlay does. `docs/todo/h96max-m20-port-path.md` holds the plan.

**Serial pads are on the back of the PCB**, dead centre — three plated through-holes, no header
fitted. `RX` is the square pad:

```
[RX]  GND  TX
```

**Serial is 115200, not 1500000.** Same FT232 on `/dev/cu.usbserial-BG00WUDY` as the RK boxes, but
at a rate macOS `termios` can set directly — the `IOSSIOSPEED` ioctl the 3518D needed for 1.5 Mbaud
is not required here. The console is a **root-capable Android shell**: `/system/xbin/su` works,
`ro.build.type=userdebug`.

**Kernel spam had to go first.** The MediaTek Wi-Fi driver prints an `AIS`/`SCN` state-machine
transition every scan, several lines a second, and it drowned the shell — the first two commands
came back as nothing but `[wlan]` traces. `echo 1 4 1 7 > /proc/sys/kernel/printk` as root fixed it.

**The evidence came over in one stream.** `tar -czf` the collection directory, `base64`, `cat` it to
the console: 310 KB of base64 in about 27 s. gzip's CRC32 gates the archive and the box-side
`md5sum` matched the host file.

A first `md5sum` printed a different digest from the same file, at the same byte count, one command
before the transfer. Re-running it on the box agreed with the host. It was a stale read, not a
corrupt transfer — `gzip -t` and a per-file `md5sum` both pass.

### What the box is

Amlogic GXLX2 on the `p291` reference board, `RevE (2A:E - C5:0)`. 4× Cortex-A53 (`0xd03`), 2 GB
LPDDR3 rank0+1 @ 600 MHz, 15.76 GB SanDisk `DF4016` eMMC, SD slot present and empty.

**The silicon is aarch64; the vendor firmware is not.** BL31 hands off to U-Boot with
`Next image spsr = 0x3c9` — M[4]=0, M[3:0]=0b1001, AArch64 at EL2. The kernel above it is 4.9.113
`armv7l` and `ro.product.cpu.abilist64` is empty, so Android is 32-bit only. That is a BSP choice,
not a limit.

Android reports `ro.build.version.release` as `14`. The base fingerprint underneath it is
`PPR1.180610.011` — Android 9. The build itself is fresh: 2026-06-10.

**No address on this box is fused, and none of them is random.** U-Boot prints
`key[mac_wifi] not programed yet`, yet `mac=62:b4:4d:3b:72:e6` came back identical on all three
boots — the two captured vendor boots and a reboot issued during the sweep. `wlan0`
(`b2:14:26:85:16:d0`) and the bdaddr (`72:76:68:48:3f:07`) survived that reboot unchanged too.

They are derived, not assigned: every first octet has the locally-administered bit set
(`0x62 0xb2 0xb6 0x72`), and the bdaddr carries the chip id in octets 2–3 (`76 68`). A first reading
of "U-Boot invents a random address" was wrong — a random value cannot repeat three times.

`EEPROM_MT7668.bin` is a red herring for the Wi-Fi MAC. Offset 0 is `68 76`, the chip id
little-endian; offset 4 is `00:0c:43:26:60:48`, MediaTek's own OUI. That is the shipped template
default and it is **not** what `wlan0` comes up with, so the driver does not read its address there.

Cheaper than `docs/todo/rk35xx-mac-pinning.md` looked at first: there is no fused address to
recover, but there is also nothing to fight — the values are reproducible.

**Wi-Fi and Bluetooth are one MediaTek MT7668 on SDIO** — vendor `0x37a`, device `0x7668`, SDR50 at
50 MHz, func1 Wi-Fi and func2 Bluetooth. The vendor loads `wlan_mt76x8_sdio.ko` (MediaTek's gen4m
tree) and `btmtksdio.ko`, and pulls `mt7668_patch_e2_hdr.bin` at probe.

USB is 2.0 only on two ports — `amlogic-new-usb3 d0078080.usb3phy: This phy has no usb port`, and
dwc3 is forced to `dr_mode=host`. Ethernet is 10/100 on the SoC's internal PHY `0x01814400`.

### The device tree

`/dev/dtb` gives the whole Amlogic multi-DTB container gzipped. Inflated it is `AML_` v2 with six
entries, matching what U-Boot lists:

| #   | soc     | plat   | vari    |
| --- | ------- | ------ | ------- |
| 0   | `gxlx`  | `p271` | `1g`    |
| 1   | `gxlx`  | `p271` | `1gid0` |
| 2   | `gxlx`  | `p271` | `1gid6` |
| 3   | `gxlx`  | `p271` | `2g`    |
| 4   | `gxlx2` | `p291` | `1g`    |
| 5   | `gxlx2` | `p291` | `2g`    |

U-Boot prints `Find match dtb: 5`, so entry 5 is this box. It is `stock/h96max-m20/board.dtb` and it
round-trips through the patched `dtc`.

The entry table is not the documented v1 layout — each of the three name fields is 16 bytes of
4-byte words stored little-endian, so `gxlx2  ` reads as `xlxg`-` 2` until the words are reversed.

Do **not** take this tree from `/proc/device-tree`: there it reads `model = "Amlogic"` and
`compatible = "amlogic, Gxl"`, with no mention of gxlx2 at all.

### Boot path out of Android

The stock environment already carries the SD hook every Armbian-on-Amlogic image relies on:

```sh
recovery_from_sdcard=if fatload mmc 0 ${loadaddr} aml_autoscript; then autoscr ${loadaddr}; fi;…
```

`recovery_from_udisk` is the same off USB. U-Boot also prints `Enter USB burn` before autoboot, so
the Amlogic USB Burning Tool is a recovery route over OTG, and `Hit any key to stop autoboot` leaves
a 1-second window to the U-Boot shell on serial.

Nothing has been written to the box. No eMMC backup exists yet — the box has no network (`eth0` has
no carrier, `wlan0` is not associated) and 15.76 GB over a 115200 console is not a route.

### The U-Boot prompt, and what it can and cannot do

`Hit any key to stop autoboot` is a 1-second window, so catching it means flooding the line with
carriage returns from the moment `reboot` is issued. The prompt is `gxl_p211_v1#` — the vendor never
renamed it off Amlogic's p211 reference.

99 commands. The ones that matter for moving an image:

| Command                      | Use                                              |
| ---------------------------- | ------------------------------------------------ |
| `update`                     | enter v2 USB burning mode — the host-tool target |
| `usb_burn`, `usb_update`     | the same path under other names                  |
| `sdc_burn`, `sdc_update`     | burn an image sitting on the SD card             |
| `amlmmc`, `store`, `imgread` | read and write eMMC from the prompt              |
| `dhcp`, `tftpboot`, `ping`   | Ethernet works in U-Boot                         |

**No `ums` and no `fastboot`**, and no `loady` either, so the vendor U-Boot cannot expose the eMMC
as a block device and cannot take a file over the serial line. Anything bulk has to go through the
USB burning protocol, the SD card, or a booted Linux.

`tftpboot` loads _to_ the box; there is no `tftpput`. So U-Boot alone gives no route for a backup
either — only the USB protocol's `mread`, or `dd` from a Linux booted off SD.

### The loaders, the keys, and a `dd` that lies

`dd bs=1M` **reads nothing** on this box — toybox's `dd` does not take the suffix, and it fails by
returning zero bytes rather than an error. A first magic scan over `bs=1M count=40` reported every
pattern absent; it had read 0 bytes. `bs=1048576` works. Anything scanned with a suffixed block size
here is void, not negative.

`/dev/block/bootloader`, `mmcblk0boot0` and `mmcblk0boot1` all hash to
`9d2f1f376efa55ede5034f8aca120f14` — three identical copies. Only the first 2 MiB of the 4 MiB
partition is non-zero. Pulled as `gzip | base64` over the console, 1.76 MB of base64, md5 verified
against the box.

**Only two unifykey slots are provisioned**, and one of them rewrites an earlier conclusion: `mac`
holds `62:b4:4d:3b:72:e6`, the exact eth0 address. So that address is **stored, not derived** — "the
values must be derived" was right for Wi-Fi and Bluetooth, where `mac_wifi` and `mac_bt` both read
`exist=none`, and wrong for Ethernet. `usid` holds the Android serial.

The other seventeen slots are empty, including every DRM one — `widevinekeybox`,
`PlayReadykeybox25`, `netflix_mgkid`, the HDCP set and both attestation boxes. There is nothing on
this box for a migration to destroy.

`DKVR` and `SSKR` appear nowhere in the bootloader or in the first 16 MiB of `reserved`. That
reserved region is high-entropy — each 4-character string in it occurs exactly twice — which is what
an encrypted key store looks like, and matches the `secure` flag those slots carry.

### The OTG port enumerates, and the button holds it open

The **USB-C port is the OTG one**; the USB-A port is host-only. With the board's button held through
a power-cycle, the Mac saw `1b8e:c003` — Amlogic's own VID and the GX-CHIP product id — for a
measured **8 seconds** (00:16:56 to 00:17:03), after which the box fell through the `update` chain
and booted Android normally.

Without the button the same gadget still appears, but only for the ~700 ms of
`try_auto_burn=update 700 750`. Under Android it never appears at all: `dwc3` is forced to host
(`Configuration mismatch. dr_mode forced to host`), so a poll from a running system always comes
back empty. A first look found nothing for exactly that reason.

`1b8e:c003` is the pair `pyamlboot` defaults to (`idVendor=7054, idProduct=49155`), so the tooling
question is now narrow: the device answers, and what remains is **which protocol** answers. ROM USB
Boot mode and U-Boot's burning mode present the same ids.

## 2026-09-15 — Armbian on the vendor U-Boot

### The stock U-Boot can boot an arm64 kernel off ext4, which settles the base image

Probing the boot commands over USB, with serial catching what only the UART carries:

| Command    | Present | What it printed                                       |
| ---------- | ------- | ----------------------------------------------------- |
| `ext4load` | ✅      | its usage — it can read an ext4 filesystem            |
| `fatload`  | ✅      | its usage                                             |
| `booti`    | ✅      | `Bad Linux ARM64 Image magic!`                        |
| `bootm`    | ✅      | `Wrong Image Format`, then `ee_gate_off` — disconnect |

`booti` complaining about **ARM64** image magic is direct evidence that this U-Boot boots a 64-bit
kernel, where before it was inferred from BL31 handing off at EL2. Android being 32-bit `armv7l` is
a BSP choice and nothing in the bootloader stops an arm64 kernel.

`ext4load` existing is what frees the base image. Official Armbian ships
`Armbian_26.8.1_Lepotato_trixie_current_6.18.44_minimal.img.xz` — Debian 13, kernel 6.18.44, a
supported target where `apt upgrade` still tracks upstream — and it carries no FAT partition, so
`recovery_from_udisk` cannot load an `aml_autoscript` from it as shipped. It does not have to:
`amlcmd` issues U-Boot commands, so `usb start`, `ext4load` and `booti` boot it with the host
attached. The autoscript is only needed for booting unattended, and ophub's fork is demoted to a
throwaway first-boot check and a source of reference trees.

**`bootm` disconnects the gadget** — `optimus_transform.c` calls `dwc_otg_pullup(0)` the moment it
sees the word — so probing it costs the link even when the command then fails. It was known and
probed anyway.

### U-Boot 2015 cannot read a modern Armbian rootfs

`ext4ls usb 0:1 /boot` returns fragments of file contents where a directory listing belongs. The
filesystem explains it — `dumpe2fs` on the official image reports `64bit` and `metadata_csum`, both
newer than this bootloader's ext4 driver.

So the boot files go on **FAT**, which is what `recovery_from_udisk` wants anyway: it does
`fatload usb 0 ${loadaddr} aml_autoscript`. `images/m20-usb-test.img` is built for that — a 512 MiB
FAT32 partition holding `vmlinuz`, `uInitrd`, `meson-gxlx-s905l-p271.dtb` and an `aml_autoscript`,
with the Armbian rootfs moved to partition 2 and left alone. Rooting on `/dev/sda2` sidesteps the
UUID in `armbianEnv.txt`, which U-Boot could not read either.

The same split is what an eMMC install will need, so it is not throwaway work.

### The board has no Ethernet jack

Reported from the hardware: USB-C, USB-A, HDMI, a button and two LEDs, with Wi-Fi and Bluetooth and
**no Ethernet connector**. The SoC MAC block at `c9410000` is real and the driver binds to it — that
is where `eth0` and its stored `mac` unifykey come from — but nothing is routed to a socket, which
is why `eth0` never showed carrier. Wi-Fi is therefore the only route to a network, and the first
boot has no network at all.

❓ Whether an IR receiver is fitted is unconfirmed; the factory tree carries `rc@c8100580` and a
19-key map, but the tree describes the SoC and a reference board, not what is populated here.

### What the vendor U-Boot demands of a device tree before it will boot one

The mainline `meson-gxlx-s905l-p271.dtb` loads fine and `booti` accepts the arm64 kernel, but the
boot dies in U-Boot's own tree fixup. `common/cmd_rsvmem.c` in the Amlogic U-Boot reads and writes
node paths that only the vendor tree has:

```c
"fdt get value env_compatible /reserved-memory/linux,secmon compatible;"
"fdt set /reserved-memory/linux,secmon reg <0x0 %x 0x0 %x>;"
"fdt set /secmon reserve_mem_size <0x%x>;"
"fdt set /reserved-memory/linux,secos status okay;"
```

Mainline calls the same region `secmon@10000000`, so `fdt_path_offset` returns `FDT_ERR_NOTFOUND`,
`[rsvmem] bl31 reserved memory set addr error` prints, and U-Boot takes a synchronous abort
(`esr 0x96000210`, an external abort on a read with `x1 = 0`) and resets.

Patching the tree in memory at the U-Boot prompt fixes that specific error:

```
fdt addr 0x1000000
fdt resize 8192
fdt mknode /reserved-memory linux,secmon
fdt set /reserved-memory/linux,secmon compatible "amlogic, aml_secmon_memory"
fdt set /reserved-memory/linux,secmon reg <0x0 0x10000000 0x0 0x200000>
```

`fdt print` confirms the node, and the `rsvmem` message is gone — but `booti` still aborts at the
same address, so at least one more vendor-only node is missing. The factory tree has a **root-level
`/secmon`** with `compatible = "amlogic, secmon"` and `reserve_mem_size`, which mainline has
nowhere. `linux,secos` is likely not needed: BL31 reports `tee size: 0`, so the bl32 branch is
skipped.

The compatible string decides which branch runs — `shared-dma-pool` takes the CMA path and uses
`size`/`alignment`/`alloc-ranges`, `amlogic, aml_secmon_memory` takes the reserved path and uses
`reg`. The factory tree uses the first.

**The eventual fix is a patch to the mainline tree**, which is board data and belongs in
`firmware/h96max-m20/`, not a local hack. Whether it is worth carrying depends on whether a tree
that satisfies the vendor U-Boot also satisfies mainline Linux.

### The vendor U-Boot cannot place a modern arm64 kernel, and that is the real blocker

With the patched tree the `rsvmem` complaint is gone, so `linux,secmon` and `/secmon` were genuinely
required — but `booti` still aborts, and the kernel's own header says why:

```
text_offset : 0x0
image_size  : 0x2480000
flags       : 0xa        bit 3 set: physical placement is flexible
```

`image_size` is exactly the `x2`/`x3` in the abort, and `x1` — the destination — is **0**. U-Boot
2015.01 predates the flexible-placement flag, so it computes `ram_start + text_offset` = 0 and
memmoves 38 MB there, into the `hwrom@0` no-map region. Hence `esr 0x96000210`, an external abort on
a read, every time and regardless of where the kernel was loaded.

Changing the load address does not help: `x5` tracked `0x11000000` on the attempt that used ophub's
addresses, and the destination was still 0.

**So the boot needs a newer U-Boot, chain-loaded.** That is exactly what ophub's `s905_autoscript`
does before anything else:

```sh
if fatload usb 0 0x1000000 u-boot.ext; then go 0x1000000; fi;
```

Their `u-boot.ext` starts `0a000014`, an arm64 branch — a raw U-Boot proper of about 710 KB, run at
`0x1000000`, the meson-gxl text base. Official Armbian ships a U-Boot for the same family at
`/usr/lib/linux-u-boot-current-lepotato/u-boot.bin`, but that file starts `2b6c9213`: it is the
signed FIP, not a raw image, so it cannot be `go`-ne as it stands. `gxlimg -t fip -e` on it yields
only `bl2.sign`, so getting BL33 out of it needs more work, or U-Boot has to be built from source
for `libretech-cc`.

Everything below that bootloader works: the stock U-Boot reaches `recovery_from_udisk`, runs our
`aml_autoscript`, and loads the patched DTB, a 37 MB kernel and a 25 MB initrd off FAT at 1.9 MiB/s.
Only the final hand-off fails.

### Armbian boots — and patching the stock tree is why the memory is right

Mainline 6.18.44 runs on the box, from official Armbian, on a tree built from
`stock/h96max-m20/board.dtb` plus a twelve-hunk `board.patch`:

```
Linux 6.18.44-current-meson64 aarch64
/proc/device-tree/model -> H96 Max M20
nproc 4      Mem: 1954 MB
EXT4-fs (sda2): resized filesystem to 29986560
lepotato login: root (automatic login)
```

**1954 MB is the argument for the stock base, made concrete.** The board has 2 GB and the factory
tree says so; mainline's `meson-gxlx-s905l-p271.dtb` declares `0x40000000`, and building on that
would have booted this box with half its memory. `model` is the same story: the factory string is
only `"Amlogic"`, and the patch supplies the real name.

Three fixes got from "kernel hangs before console" to a login prompt, each found from the box rather
than guessed:

| Fix                                       | What it unblocked                       |
| ----------------------------------------- | --------------------------------------- |
| syscon wrappers on both clock controllers | every clock consumer; userspace started |
| `chosen`/`stdout-path`, uart clocks       | the kernel console                      |
| USB as `meson-gxl-usb-ctrl` + two phys    | `/dev/sda`, so root could mount         |

`amlogic,gxl-clkc` is a syscon child in mainline — it takes its regmap from the parent — and the
vendor driver mapped the registers itself, so the vendor tree models no syscon at all. Everything on
the SoC deferred behind that one node.

`/sys/bus/usb/devices` being _empty_, read from the initramfs shell, is what identified the USB
problem: the vendor's flat `dwc3` with a `usb-phy` property and `amlogic, amlogic-new-usb2` phys is
claimed by no mainline driver.

### Still deferred

```
d0070000.sdio   wait for supplier /pinctrl@4b0/sdio_all_pins
d0072000.sd     wait for supplier /pinctrl@14/sd_to_ao_uart_pins
d0074000.emmc   wait for supplier /pinctrl@4b0/emmc_conf_pull_done
```

One subsystem — pinctrl — gates all three, and with it Wi-Fi and the eMMC. `gpioleds` still wants a
GPIO controller mainline recognises.

### The box can be power-cycled from the host now

The OTG cable moved to a hub with per-port power switching, and `uhubctl` drives it:
`uhubctl -l 2-1 -p 1 -a cycle` cuts VBUS (`Port 1: 0000 off`) and the box drops off the bus. The
`-a off` form without `-p` does nothing on this hub, which is what made an earlier attempt look like
the hub ignored PPPS.

Booting from USB, with the vendor U-Boot untouched:

| Step               | Why                                                                               |
| ------------------ | --------------------------------------------------------------------------------- |
| warm reboot        | a cold boot runs `try_auto_burn`, and the gadget it starts makes `usb start` hang |
| interrupt autoboot | `usb start 0` then `run recovery_from_udisk`                                      |
| `aml_autoscript`   | chain-loads Armbian's own U-Boot 2024.01 with `go 0x1000000`                      |
| `boot.scr`         | loads kernel, initrd and our tree at 43 MiB/s                                     |

## 2026-09-16 — the board becomes board data

The image had been assembled by hand — `dd` a partition table, `newfs_msdos`, `e2cp` a payload —
which is not reproducible and not how any other board in this repo is built. It is a
`firmware/h96max-m20/` directory now, and `build-image.sh` builds it.

### `u-boot.ext` was in the base image the whole time

The chain-loaded U-Boot did not come from ophub, and it is not the signed FIP at
`/usr/lib/linux-u-boot-current-lepotato/u-boot.bin` that the earlier entry gave up on. It is
`u-boot-dtb.img` in that same directory — a legacy uImage — with its 64-byte header cut off:

```
$ dd if=u-boot-dtb.img bs=64 skip=1 | shasum
7ec69cc7b00993dd2054d346c58e4fcb154341f3     # byte-identical to the u-boot.ext that booted
$ strings u-boot.ext | grep ^U-Boot
U-Boot 2024.01_armbian-2024.01-… libretech-cc
```

So no bootloader blob is committed: the build extracts it from the base image, and it tracks
whatever U-Boot that image ships. `BOARD_UBOOT_SRC` in `board.conf` is the path, and the build
checks the `27051956` uImage magic before cutting the header off.

### Two families, one builder

`BOARD_FAMILY` selects the two steps that genuinely differ, and nothing else moved:

| Step            | `rk35xx`                                | `meson-gxl`                            |
| --------------- | --------------------------------------- | -------------------------------------- |
| Partition table | the base's GPT, kept                    | rebuilt as MBR: FAT32 boot, then root  |
| Loaders         | idbloader ×5 @64, `uboot.itb` ×2 @16384 | left in eMMC; a FAT partition is added |
| `armbianEnv`    | `fdtfile`, `console`, `extraargs`       | `fdtfile` only                         |

The rootfs work — DTB, payload, DKMS staging, rebrand, `fsck` — is the same code for both.

`aml_autoscript` and `boot.scr` are generated by `mkimage` from the kernel version read out of the
image, so the paths in them cannot drift from what is installed. The FAT filesystem is built with
`mformat` into a plain file and `dd`-ed in after the image is detached, which keeps the whole build
free of `sudo` and of writing under a live attachment.

### Every board now declares the image it is built from

`BOARD_BASE` per board, checked against `BOARD=` in the base's `/etc/armbian-release`, with
`EXPECT_BASE_BOARD` still overriding it. Three ways a wrong base is caught:

```
$ ./build-image.sh Armbian_..._Rock-2f_...img h96max-m20
  …rkbase.img is GPT-partitioned, and this board is built from an MBR image
$ ./build-image.sh armbian-lepotato-trixie.img h96max-3518d
  no GPT in …-3518d.img — refusing to guess where the rootfs starts
$ EXPECT_BASE_BOARD=lafrite ./build-image.sh armbian-lepotato-trixie.img h96max-m20
  Base image is BOARD='lepotato', but h96max-m20 is built from 'lafrite'.
```

The scheme mismatch is caught before a byte is written. `./build-image.sh` with no arguments now
lists each board beside its base.

**The 3518D image was rebuilt either side of the change**: sectors 0–32767 — GPT, five idbloader
copies, both U-Boot slots, the factory window — byte-identical, and every file in `payload.list`
plus `armbianEnv.txt` byte-identical.

### MT7668 packaged, and one claim retracted

The driver tree is pinned at `70b09b60` with `patches/mt7668/0001-…` adding the `dkms.conf` upstream
does not ship. The tree carries its own firmware, so `board_stage_dkms` installs that too rather
than committing vendor blobs.

An earlier note here said Bluetooth needed only firmware because mainline `btmtksdio` names 0x7668.
Upstream's own `install.sh` says otherwise: it blacklists `btmtksdio` and `btmtk` and builds
`bt_mt7668`, which takes `glResetTrigger` from the Wi-Fi module — the two halves share a reset path
mainline's split does not model. Only the Wi-Fi half is packaged until there is an SDIO bus to test
the other on.

### The staged driver cannot build yet

The Lepotato base ships no kernel headers, so `/usr/src` holds the driver tree and nothing to build
it against — `rk35xx-firstboot` will skip it. With no Ethernet socket and no Wi-Fi, the box cannot
`apt install` them either. Sideloading the `.deb` set or a USB Ethernet dongle are the two ways out;
neither is in the build.

### Why the RK images have a compiler and this one does not

Not a Rockchip-versus-Amlogic difference, and not `minimal` versus anything. Armbian's
`config/boards/rock-2f.conf` carries `enable_extension "radxa-aic8800"`; that installs
`aic8800-usb-dkms`, which depends on `dkms`, which depends on `make | build-essential` and
`dpkg-dev`, so the image must also ship `linux-headers-vendor-rk35xx` to build it at first boot. 348
installed packages against Lepotato's 302, and the 46 extra are that chain.

`lepotato.conf` enables no extension, and no `meson-gxl` board does, so the base was not chosen
wrongly — there is no Amlogic Armbian image with a toolchain to switch to.

### The image's own apt links expire, so the indices are refetched

The base ships a populated `/var/lib/apt/lists`, and every stanza in it carries a pool path and a
SHA256 — which looks like all that offline staging needs. It is not: a Debian pool keeps only
current versions, and the image's index is a snapshot from image-build time.

```
libc6-dev 2.41-12+deb13u3: HTTP Error 404 for .../pool/main/g/glibc/libc6-dev_2.41-12+deb13u3_arm64.deb
```

So `fetch-apt-debs.py` takes only the two things from the image that do not decay — the sources it
trusts, and what is already installed — and fetches the indices itself. `BOARD_APT_DEBS` in
`board.conf` names the wanted packages; the closure lands in `/var/cache/apt/archives`, and
`rk35xx-firstboot` installs it by path so apt resolves among the staged files rather than against
lists that predate them. 48 packages, 75.8 MiB, every one SHA256-checked against its index.

Two traps cost a wrong answer each before the numbers came out right:

| Trap                       | What naive resolution picked     | What apt would pick         |
| -------------------------- | -------------------------------- | --------------------------- |
| backports pinned below 500 | `libelf-dev` 0.195-1~bpo13+1     | `libelf-dev` 0.192-4        |
| same, via a kernel package | `linux-libc-dev` 7.1.3-1~bpo13+1 | `linux-libc-dev` 6.12.107-1 |

And the Armbian one, which is worse because it installs cleanly and only fails later: **an Armbian
kernel package's apt version does not identify the kernel it carries.**
`linux-headers-current-meson64` 26.8.1 is 6.18.43 in the repo, while the image's
`linux-image-current-meson64` 26.8.1 owns `/boot/vmlinuz-6.18.44`. Headers are selected by the
kernel stamped into the pool filename, and a miss is fatal rather than a fallback:

```
linux-headers-current-meson64: no build for kernel 6.18.44; the indices offer 6.12.17, …, 6.18.43
```

26.8.3 is the one carrying 6.18.44, and that is what ships.

### Pinctrl was one word, found by diffing against the mainline board

Comparing the patched tree against the base image's own `meson-gxl-s905x-libretech-cc.dtb`, node by
node and matched on unit address, gave 16 compatible mismatches. Two of them were the whole Wi-Fi
blocker:

```
pinctrl@14    amlogic,meson-gxlx-aobus-pinctrl    -> amlogic,meson-gxl-aobus-pinctrl
pinctrl@4b0   amlogic,meson-gxlx-periphs-pinctrl  -> amlogic,meson-gxl-periphs-pinctrl
```

`pinctrl-meson-gxl.c` matches `gxl`, never `gxlx`. With neither controller bound there were no pin
groups, so `d0070000.sdio`, `d0072000.sd` and `d0074000.emmc` all sat in deferred probe on a
supplier that could never appear, and with no SDIO bus the MT7668 was never enumerated.

**The rest of the pinctrl node needed nothing.** The stock groups are already in mainline's shape,
and every group and function name they use is in the GXL pin data verbatim — checked, not assumed:

```
ours:      "emmc_ds"  "sdio_d0".."sdio_d3"  "sdio_clk"  "sdio_cmd"  "sdcard_d0".."sdcard_clk"
mainline:  emmc_clk emmc_cmd emmc_ds emmc_nand_d07 sdcard_clk sdcard_cmd sdcard_d0..d3
           sdio_clk sdio_cmd sdio_d0..d3 sdio_irq
```

The bank `reg` and `reg-names` match as well. Mainline writes them as offsets under a `simple-bus`
with two address cells where the vendor writes absolute addresses, which resolves the same. The one
real absence is `gpio-ranges`, and that governs GPIO-by-pin lookups rather than pin muxing — the
LEDs, not the MMC controllers.

### The other fourteen were wrong too, blocking or not

Calling the rest "non-blocking" was the wrong test. A compatible that matches no driver is simply
untrue about the hardware, and three of these sit on nodes that are `status = "okay"` — live nodes
claiming a driver that never arrives:

```
cpu@0..3     + arm,armv8 (deprecated)      -> arm,cortex-a53 alone
serial@4e0   amlogic, meson-uart           -> amlogic,meson-gx-uart + amlogic,meson-ao-uart
serial@84c0  amlogic, meson-uart   okay    -> amlogic,meson-gx-uart
serial@84dc  serial@8700                   -> same
i2c@8500 @87c0 @87e0  amlogic,meson-gx-i2c -> amlogic,meson-gxbb-i2c
pwm@550      amlogic,gx-ao-pwm             -> amlogic,meson-gxbb-pwm-v2 + amlogic,meson8-pwm-v2
pwm@8550 @86c0  amlogic,gx-ee-pwm  okay    -> same
```

The console was never one of them: it is `uart_AO` at `4c0`, already converted, and the boot log
says `c81004c0.serial: ttyAML0 … is a meson_uart`. The four vendor-spelled UARTs are idle siblings.
After the pass the tree has **no compatible mismatch left** against the mainline board at any shared
unit address.

### Wi-Fi needs one more thing the vendor tree hides in a driver

`cap-sdio-irq` was missing, and the vendor's own caps list asks for `MMC_CAP_SDIO_IRQ`; mainline
reads it from the property, so that is now translated. The larger gap is power:

```
wifi {
        compatible = "amlogic, aml_wifi";
        power_on_pin  = <&gpio 88 0>;
        interrupt_pin = <&gpio 100 0>;
        pinctrl-0 = <&wifi_32k_pins>;   /* mux pwm_e as the chip's 32 kHz clock */
};
```

Mainline has no `aml_wifi`. The equivalent is an `mmc-pwrseq-simple` with `reset-gpios`, plus a
`pwm-clock` feeding it as `ext_clock`, referenced from the SDIO node. It is **not** in this pass:
the vendor's GPIO indices are its own numbering rather than mainline's GXL pin numbers, and driving
the wrong pin is worse than leaving the node out. It has to be derived against a box that can be
reached — which this one currently cannot, its OTG cable being on the hub's unswitched port 1.

## 2026-09-17 — the clock tree was reading zero, and everything downstream of it

### The image teaches the box to boot itself

`aml_autoscript` now rewrites the factory environment on its first run: `try_auto_burn` cleared (it
is what starts the USB gadget that makes `usb start` hang on a cold boot), `bootcmd` set to try the
stick and fall back to `run storeboot`. One button-initiated boot, and every power-on after that
lands in Armbian with no serial at all. Proven by cutting power and only listening:

```
[  OK  ] Started fstrim.timer …          # systemd on the stick, nothing sent to the console
```

The button's own recovery path is `upgrade_sadckey`, a different variable, so Maskrom is untouched.

### Offline package staging works

The reflashed image came up with `gcc`, `make`, `dkms` and matching headers installed from
`/var/cache/apt/archives` with no network — `dpkg -i` where `apt-get install --no-download` had
failed, because apt treats even a local `.deb` path as something it must acquire.

### `default` is the only pinctrl state Linux applies, and the eMMC paid for it twice

The SDIO fix generalised. The eMMC node named its states `emmc_clk_cmd_pins` and `emmc_all_pins`,
and the first one muxes **only clk and cmd** — the eight data lines live in `emmc_conf_pull_up`. So
nothing configured the data pins and reads returned I/O errors at sector 49256 onwards. Naming the
full set `default` cleared them. Its `max-frequency` also asked for 200 MHz, which is HS200/HS400 on
1.8 V signalling this board never switches to; 50 MHz is what a fixed 3.3 V rail supports.

### The real fault: the clock controller had no crystal

Reads stopped erroring and started crawling — 4 MB in 20.9 s, 201 kB/s, on a bus `ios` reported as
50 MHz 8-bit high-speed. The clock summary said why:

```
fixed_pll_dco   rate 0      sys_pll_dco   rate 0      fclk_div2   rate 0
xtal            24000000
```

Every PLL read zero. Not the regmap — that works, and `HHI_MPLL_CNTL` at offset `0x280` reads
`c00006fa`, which decodes to m=250 n=3, exactly the 2 GHz `fixed_pll` should be. The node was
missing its input:

```
clkc: clock-controller@0 {
        compatible = "amlogic,gxl-clkc";
+       clocks = <&xtal>;
+       clock-names = "xtal";
-       reg = <0x00 0x3db>;        /* mainline's has none; the regmap comes from the parent */
```

Without `clocks`, every PLL's parent resolves to nothing and the whole tree recalculates as 0. The
hardware was running the whole time — BL2 programmed it — so what worked, worked because the
bootloader had left it that way.

| Measure         | Before   | After     |
| --------------- | -------- | --------- |
| `fclk_div2`     | 0 Hz     | 1 GHz     |
| eMMC read       | 201 kB/s | 45.0 MB/s |
| eMMC I/O errors | many     | 0         |

`dd if=/dev/mmcblk0 bs=1M count=256 iflag=direct` → 268435456 bytes, 5.96 s, **45.0 MB/s**.

### LEDs: one is fitted, and the other is active low

The factory tree carries a second, disabled node for the same pin as `sys_red`:

```
sysled { status = "disabled"; led_gpio = <&gpio 0x4c 0x00>; led_active_low = <0x01>; };
```

So `gpioleds`' active-high for that pin contradicts the vendor's own data, and driving it "on" drove
it high, which is off. Corrected to active low. Confirmed from the box: driving `power` lights the
**blue** LED and driving `standby` lights nothing, so only the power half is fitted on this unit —
the p291 reference design's second LED is not. Labels are now `power`/`standby`, matching the other
boards and the shared LED hooks.

### Wi-Fi: mainline plus one device id, packaged as DKMS

Not the vendor gen4m tree. `patches/mt76-mt7668/` takes mainline 6.18.44's mt76, adds
`0x037a:0x7608` beside the `0x7603` that `mt7663s` already claims, and builds **only** `sdio.c` and
`sdio_mcu.c` via a `Kbuild` that wins over the tree's own Makefile. The module keeps its mainline
name, so DKMS installs it under `updates/` where depmod prefers it: the stock driver with one id
added, not a second driver beside it. 1.4 MB against the vendor blob's 57 MB.

It binds, and stops at the ownership handshake:

```
mt7663s mmc1:0001:1: Cannot get ownership from device
mt7663s mmc1:0001:1: probe with driver mt7663s failed with error -110
```

and the chip then stops answering SDIO entirely — `mmc1: error -110 whilst initialising SDIO card` —
through warm reboots. ❓ Whether the clock fix changes this is untested: the chip wedged before it
landed, and nothing short of cutting VBUS brings it back. `power_on_pin = <&gpio 88 0>` does not
reset it, and sweeping the rest of the X bank did not either, so like the red LED and the
out-of-range `interrupt_pin = <&gpio 100 0>`, that node looks like reference-design data rather than
this board's wiring.

### Still missing

No `cpufreq` and no thermal zones. Both want nodes the vendor tree models its own way — mainline
gets them through SCPI and a `operating-points-v2` table this tree has neither of.

### Wi-Fi after the clock fix: the bus works, the MCU protocol does not

The clock fix changed the answer. With a real SDIO bus clock the chip enumerates and `mt7663s` binds
cleanly — where before it could not even take ownership:

```
/sys/bus/sdio/devices/  mmc1:0001:1  mmc1:0001:2
phy0                    wlan0  DOWN  <BROADCAST,MULTICAST>
```

So the ownership handshake that failed earlier was starving on a 0 Hz bus, not a chip difference.
The TX/RX workers run. What fails now is one layer up:

```
mt7663s …: Message 00000010 (seq 1) timeout
mt7663s …: Failed to get patch semaphore
mt7663s …: failed to load mediatek/mt7663pr2h_rebb.bin
```

The "not found" line that follows a semaphore timeout is a fallback message, not the fault: the MCU
never answers. `ip link set wlan0 up` returns `EIO`, and `mt7615_eeprom_init` warns because the
efuse reads back invalid, so the MAC is random.

**Mainline asks this chip for MT7663 firmware.** Feeding it the vendor's own MT7668 blobs under the
names it requests — `mt7668_patch_e2_hdr.bin` as `mt7663pr2h.bin`, `WIFI_RAM_CODE_MT7668.bin` as
`mt7663_n9_rebb.bin` — does not help either: the module load hangs and leaves no interface. The two
parts share an SDIO host interface and a Bluetooth driver, but not the MCU download protocol.

Bluetooth sits behind the same wall. `btmtksdio` binds function 2, accepts firmware
(`Firmware already downloaded`) and registers `hci0`, then times out identically:

```
Bluetooth: hci0: Execution of wmt command timed out
Bluetooth: hci0: Failed to send wmt func ctrl (-110)
hci0: … BD Address: 00:00:00:00:00:00 … DOWN
```

which matches the vendor tree's own note that its Bluetooth module takes a symbol from the Wi-Fi
one: the chip's MCU has to be brought up once, by whoever does it first.

So the remaining work is the MCU layer, not the bus and not the device id. `firmware-mediatek` is
staged into the image now so the mt7663 firmware is present offline either way.

### Both drivers tried; mainline is the one to carry

|                | mainline `mt7663s` + one id | vendor gen4m                        |
| -------------- | --------------------------- | ----------------------------------- |
| Size           | 1.4 MB                      | 57 MB                               |
| Builds on 6.18 | unmodified                  | after six compat fixes              |
| Binds the chip | yes — `phy0`, `wlan0`       | `insmod` hangs in module init       |
| Fails at       | patch semaphore, cleanly    | nothing legible; the process wedges |
| Diagnosable    | yes                         | no                                  |

The vendor tree needed `local_clock`'s include, `del_timer_sync` → `timer_delete_sync`,
`MODULE_IMPORT_NS` as a string literal, `tdls_mgmt`'s `link_id`, the removal of `scan_width`, five
`cfg80211_ops` signature shims and DFS master switched off — and then hung on load with two
unkillable `insmod` processes, recoverable only by `sysrq-trigger`. Mainline fails in one line and
leaves the box usable, so that is what the repo carries.

**The delta looks small enough to be worth upstreaming.** Both drivers name the same command:

```
vendor:    INIT_CMD_ID_PATCH_SEMAPHORE_CONTROL = 0x10
mainline:  Message 00000010 (seq 1) timeout      /* MCU_CMD(PATCH_SEM_CONTROL) */
```

So the MCU command set is shared and the difference is below it — the SDIO transport framing, or an
init step the vendor performs first (`wlanAccessRegister` reads TOP_HVR at `0x80021000` before the
semaphore, which mt76 does not). That is a bounded comparison against `mt7615/sdio_mcu.c` and
`mt76_connac_mcu.c`, and if it lands it is a device id plus a small quirk for a chip mainline
already half-supports — `btmtksdio` names MT7668 today.

❓ The chip's state also varies with how it was reset: after a cold power cycle it gets as far as
the patch semaphore, while after warm reboots it returns `query whisr timeout` instead.

## 2026-09-17 — validation pass against `docs/board-validation.md`

Ten warm reboots, checking devices after each rather than just that it came back:

```
reboot 1..10: root=/dev/sda2 emmc=/dev/mmcblk0boot0 wlan0=1 hci0=1 eth0up=1
```

All ten clean. The box also survived losing every USB device at once — it rebooted and came back
with no filesystem errors.

| Measure                     | Result                                  |
| --------------------------- | --------------------------------------- |
| Boot to `graphical.target`  | 16.18 s (6.11 kernel + 10.07 userspace) |
| eMMC seq read / write       | 43.3 / 32.7 MiB/s                       |
| eMMC random 4K read / write | 2711 / 3839 IOPS                        |
| USB stick read / write      | 21.2 / 20.8 MiB/s                       |
| USB throughput (Gb NIC)     | 196 Mbit/s, idle and under 4-core load  |
| `stress-ng` 4×cpu + 2×vm    | 120 s `--verify`, 6 passed, 0 failed    |

The eMMC write figures were taken in the last 128 MiB, outside the factory partitions, then the
region was restored and verified byte-identical. **`mmcblk` numbering moved between boots** — the
eMMC was `mmcblk0` one boot and `mmcblk1` the next, depending on whether SDIO probed first — so
every command here finds it through its `boot0` companion, exactly as `AGENTS.md` says to.

### What the dmesg audit turned up

The spec asks for `dmesg` accounted for line by line, and that is what found the rest of this:

| Line                                   | Cause                                      | Now                       |
| -------------------------------------- | ------------------------------------------ | ------------------------- |
| 24 × `invalid function uart_ao_a_card` | the `sd` node's nine vendor pinctrl states | one `default`; 0 errors   |
| `meson_uart c11084c0.serial … -2`      | vendor's single `clk_uart`                 | three named clocks        |
| `meson-saradc … [mem 0x0-0xc110867f]`  | two-cell `reg` under a one-cell root       | `reg = <0xc1108680 0x38>` |
| `meson-saradc … failed to get clkin`   | vendor's three clock names                 | mainline's four           |

Fixing the `sd` node's pinctrl brought up a **third MMC host** — the SD controller now probes where
before it sat in deferred probe. The ADC now registers as `iio:device0 meson-gxl-saradc`, which is
what reads this board's button, and `/dev/ttyAML1` appeared beside `ttyAML0`.

Each fix exposes the next node still wearing vendor wiring. Still erroring, and recorded rather than
guessed at: `meson_ee_pwrc` wants the resets and clocks mainline's node carries, `lima` wants its
bus clock, and the CMA reservation fails. None of them is reachable to test — the VPU, GPU and video
path have never been exercised on this box.

### Power control, settled

`uhubctl` reports the hub switching its ports, and the box keeps running with all four off — it is
not plugged into that hub at all. `ioreg` shows the serial adapter at location `0x1100000`, directly
on the Mac, and no devices under either hub. The hub's PPPS works; there is simply nothing on it. So
the box cannot be power-cycled from the host, and the Wi-Fi chip — which only a VBUS cycle recovers
once it wedges — needs a hand on the cable.

### The chip id is a candidate root cause, and the hub is not switchable at all

`is_mt7663()` decides the MCU message format, the EEPROM size and the firmware names, and it is a
bare equality:

```c
static inline bool is_mt7663(struct mt76_dev *dev)
{
        return mt76_chip(dev) == 0x7663;
}
```

with `rev` read from `MT_HW_CHIPID` in the SDIO probe. An MT7668 reports `0x7668`, so every one of
those decisions would quietly take the MT7615 branch on a chip that is an MT7663 sibling. That is
`patches/mt76-mt7668/0003`, and because the test is an inline used by `mt7615-common` and
`mt76-connac-lib` as well, `0002` now builds the whole SDIO path rather than the leaf alone. The
full stack compiles clean and installs over the in-tree modules through `updates/`.

**It is untested.** Adding a `dev_info` of the id never printed: `mt7663s_hw_init()` fails first —
the `query whisr timeout` lines _are_ that failure — and the probe jumps to its error path before
`mdev->rev` is ever assigned. hw_init did succeed once, immediately after a cold power cycle, which
is the only state in which the chip has reached the patch semaphore. Warm reboots do not restore it.

So the test needs a VBUS cycle, and that turns out to be impossible from here. Every port on both
hubs was cut individually:

```
hub 2-1 port 1..4 -> ALIVE      hub 2-2 port 1..4 -> ALIVE
```

The box answers on serial through all eight, so its OTG supply is not on either hub. A cable that
only draws power does not enumerate, so `uhubctl` and `ioreg` cannot tell such a port from an empty
one — which is why an earlier reading of "the hub is empty" was wrong.

### The chip id was right, and it is not the whole story

Cold power cycle, and the print lands:

```
mt7663s mmc2:0001:1: ASIC revision: 76680011 chip=7668
```

So `is_mt7663()` — a bare `mt76_chip(dev) == 0x7663` — was false on this part, and every decision it
gates (MCU message format, EEPROM size, firmware names) took the MT7615 branch. The patch is correct
and necessary. What it buys:

|                   | before                | after                       |
| ----------------- | --------------------- | --------------------------- |
| `mt7663s_hw_init` | `query whisr timeout` | completes                   |
| chip id read      | never reached         | `0x7668`                    |
| probe             | error path            | completes, driver **bound** |
| `phy0` / `wlan0`  | sometimes             | registered every boot       |

What it does not buy is a working radio. The patch-semaphore timeout has moved from probe to
interface-up:

```
12:19:37  ASIC revision: 76680011 chip=7668        /* probe */
12:22:40  Message 00000010 (seq 2) timeout         /* ip link set wlan0 up */
```

`ip link set wlan0 up` returns `EIO` with nothing logged at the netlink level, and the efuse still
reads invalid — `mt7615_eeprom_init` WARNs at `eeprom.c:31`, the EEPROM is zeroed and the MAC is
random. The vendor's calibration lives in its own `EEPROM_MT7668.bin`, which mainline has no reason
to look for.

So the remaining delta is the firmware download itself: MT7668's ROM does not answer the MT7663
patch-semaphore exchange. That is the comparison to make next — the vendor's
`wlanImageSectionDownload` path, which reads TOP_HVR through `wlanAccessRegister` before the
semaphore, against `mt76_connac_mcu_patch_sem_ctrl`. Both drivers agree on the command id, so it is
the framing or a missing wake step rather than a different protocol.

### Auto-boot has a trap: `usb start` resets the box rather than failing

A cold boot came up in a reset loop:

```
XHCI timeout on event type 33... cannot recover.
BUG: failure at ../drivers/usb/host/xhci-ring.c:467/xhci_wait_for_event()!
resetting ...
```

The `bootcmd` the autoscript installs ends in `run storeboot`, so a stick that will not read should
fall back to Android. It never gets there: `usb start` does not return an error, it **resets the
SoC**, so nothing after it in the command list runs and the box loops. `usb reset` at the prompt
does not clear it either, and the state survives a warm reboot.

Recovery, from the U-Boot prompt: `setenv bootcmd 'run storeboot'` then `saveenv`. Anything that
makes the XHCI controller unhappy — and it is unhappy with the hub, stick and Ethernet adapter that
were attached here — turns auto-boot into an unbootable box until someone interrupts it on serial.
❓ Whether a guard is possible from the vendor shell is unknown; no command tried so far probes USB
without risking the reset.

### Power-cycling the chip from the device tree

The tree already expresses it. `mmc-pwrseq-simple` is the mechanism, and the SDIO host references
one:

```
sdio_pwrseq: sdio-pwrseq {
        compatible = "mmc-pwrseq-simple";
        reset-gpios = <&gpio 88 1>;     /* GPIOX_9 */
        clocks = <&wifi32k>;
        post-power-on-delay-ms = <100>;
};
```

The mmc core runs it on `mmc_power_off`/`mmc_power_up`, so unbinding and rebinding `d0070000.sdio`
is already a device-tree-driven chip power cycle — it just has no physical effect here, because
nothing responds to GPIOX_9 and a sweep of the rest of the X bank found no line that drops the card
off the bus.

The other lever is `vmmc-supply`. Ours is a `regulator-fixed` marked `regulator-always-on`, which
the core cannot gate. A `regulator-gpio`, or a fixed regulator with a `gpio` and no `always-on`,
would let `mmc_power_off` cut the rail — but only if a GPIO actually switches it. If the radio sits
on the 3.3 V rail with no enable, which is what the evidence so far suggests, no device tree can
express a power cycle the board does not have.

❓ The negative sweep was run against a chip already wedged. The test worth doing is the positive
one: with the radio working, toggle each candidate and watch for the card to leave the SDIO bus.

### Android proves the radio has a power line, and names the caller

Booted to the factory image, its serial log shows the vendor driver switching the radio on:

```
aml_wifi wifi: [usb_power_control] Set WiFi power on !
aml_wifi wifi: [usb_power_control] Set BT power on !
```

So the `wifi` node's `power_on_pin` is not decoration — Android drives it, twice, for the two
halves. That settles the earlier doubt: there **is** a switchable line, and the reason
`mmc-pwrseq-simple` with `reset-gpios = <&gpio 88 1>` does nothing is that GPIOX_9 is not it. The
vendor's index and mainline's pin numbering agree for the LED at 14, so the offset is not a simple
shift; the mapping has to come from the vendor pinctrl's own pin list rather than by assuming the
two number the same bank the same way.

Once that pin is known, a device tree can express the power cycle — either as the `reset-gpios` of
the existing pwrseq, or as a `regulator-gpio` for `vmmc-supply`, which would let `mmc_power_off` cut
the rail and give the host a real way to recover a wedged chip.

### The USB bus, not the software

The same boot could not read its USB devices at all:

```
usb 1-1.1: device descriptor read/64, error -110
usb 1-1.1: Device no response
usb 1-1.1: device not accepting address 7, error -62
usb 1-1-port1: attempt power cycle
```

Android fails on it exactly as U-Boot's XHCI did, so the earlier `xhci_wait_for_event()` BUG and the
boot loop are a device or cabling fault rather than anything in the boot chain.

### Where the Wi-Fi work stands, and why it iterates so slowly

With the environment auto-booting USB from cold, the chip probes cleanly — no `whisr` timeouts, no
semaphore failure, `phy0` and `wlan0` registered, and only the efuse WARNing left:

```
WARNING: CPU: 3 at mt7615/eeprom.c:31 mt7615_eeprom_init+0x348/0x4d0 [mt7615_common]
wlan0  DOWN  2a:a2:3f:be:a7:a6
```

`ip link set wlan0 up` still returns `EIO`, and prints **nothing** — so the failure is inside
`mt7615_start()` or the firmware load below it, on a path with no `dev_err`. `dev_dbg` is invisible
too: this kernel has no dynamic debug, and `__mt7663_load_firmware` logs "Firmware is already
download" only at debug level, so it cannot be told from here whether the MT7668 images were used,
skipped, or never reached.

Three things make each attempt expensive:

|                               |                                                              |
| ----------------------------- | ------------------------------------------------------------ |
| A failed `up` taints the chip | every later probe returns `query whisr timeout`              |
| Android taints it too         | `aml_wifi` powers and initialises the radio before we get it |
| `unbind`/`bind` of `mt7663s`  | crashes the box (`mt7663s_remove` oops, reset)               |

So the chip is only clean after a **cold power-on that boots straight to Armbian**, and there is one
experiment per power cycle, which no host-side switch can perform on this wiring.

**Next step, when someone picks this up:** add a `dev_info` to `mt7615_start()` and to the top of
`__mt7663_load_firmware()` reporting which branch is taken and what `MT_TOP_MISC2_FW_N9_RDY` reads.
That turns the silent `EIO` into a fact, and it is the only way to tell whether the firmware
selection added in `patches/mt76-mt7668/0004` is being exercised at all.

### The silent EIO, named at last

With every failure on the MCU init path reported, one `ip link set wlan0 up` says all of it:

```
mt7663s mmc0:0001:1: Message 00000010 (seq 1) timeout
mt7663s mmc0:0001:1: Failed to get patch semaphore
mt7663s mmc0:0001:1: failed to load mediatek/mt7668_patch_e2_hdr.bin
mt7663s mmc0:0001:1: MCU init failed: -11
mt7663s mmc0:0001:1: MCU not running, cannot start
```

Read from the bottom: `mt7615_start()` refuses because `MT76_STATE_MCU_RUNNING` was never set; it
was never set because `mt7663s_init_work()` discarded an `-EAGAIN`; that came from the firmware
load; and the load died on command `0x10`, the patch semaphore.

**Two things are settled by this.** The chip-id selection from `0004` is exercised and correct — the
driver is asking for `mt7668_patch_e2_hdr.bin`, the chip's own image, not an MT7663 one. And the
container is not the problem either, since the file is never reached: the chip does not answer the
semaphore that precedes the download.

So the gap is exactly where the ranked comparison put it — the MCU download sequence, item 2. The
MT7668 ROM does not implement the MT7663 patch-semaphore exchange, though both drivers agree on the
command number. The next thing to try is the step gen4m performs first and mt76 does not:
`wlanAccessRegister` reads TOP_HVR at `0x80021000` before touching the semaphore, which would wake
or identify the ROM. That was item 6 on the list and untestable until now; it is testable now.

The error reporting that produced this is `patches/mt76-mt7668/0005`, and it stands on its own: five
failure paths on a workqueue init, none of them audible on a kernel without dynamic debug.

## 2026-09-20 - the PCB silkscreen, and the part behind the product name

`905_DG_ZX01_V01 2025/09/03`. Same `_DG_ZX_` vendor PCB family the RK3518 boxes carry, with the
Amlogic part number in front and a date code behind. It does not say M20, so the board key stays the
retail name.

**The SoC is an S905L3.** Nine strings in `getprop.txt` say `S905LTS`, which is the vendor's product
name, but `ro.fota.platform` reads `S905L3` and `ro.fota.device` reads `S905L3_9_ZX001` - whose
`ZX001` is the same vendor board family as the silkscreen's `ZX01`. The silicon answers to GXLX2 in
the BL1 banner and in `amlogic-dt-id = gxlx2_p291_2g`, so GXLX2 is the die and S905L3 is the part it
is sold as.

## 2026-09-26 — where the vendor U-Boot keeps its environment

- `gxlimg -t bl3x -d` decrypts `stock/h96max-m20/loader-stages/bl33.enc`; the result is an `LZ4C`
  container whose raw LZ4 block, from 0x80, decompresses to 730520 bytes of
  `U-Boot 2015.01-g7ae3b4f-dirty (Jun 10 2026 - 09:09:02)`.
- A built-in partition table sits at 0x0a4d18, 40-byte entries of name, size, offset and mask:
  `bootloader` 4 MiB, `reserved` 64 MiB, `cache` 0, `env` 8 MiB, then `logo` and `recovery` at 32
  MiB. Every offset is 0: the layout is computed at boot from the sizes and the gaps between them,
  and the device tree's own list, which starts at `logo`, overrides the later sizes.
- So `env` is not at a stored sector: it follows `cache`, whose 1120 MiB on the eMMC comes from
  somewhere other than this table, not found.
- The layout itself is stored: `reserved` (sector 73728, 36 MiB) opens with an `MPT` table - magic
  `MPT`, version `01.00.00`, 20 entries of name, size, absolute offset and mask, and a checksum -
  giving every partition's offset, `env` at 1236 MiB among them. The two gzipped `AML_` multi-DTB
  copies sit at `reserved` +4 MiB and +4 MiB 256 KiB (sectors 81920 and 82432), both identical to
  `factory-multidtb.bin`. Entry 5's `cache` node is 1120 MiB, the size the built-in table leaves at
  0, and BL33 carries "update mbr/partition table by dtb": `env` should move with that size.
- BL33 reads the multi-DTB at MMC init, before `preboot`: `Find match dtb: 5`, `parts: 17`, then
  `mmc env offset: 0x4d400000` - `env`'s offset is computed there, from the tree. Each copy carries
  a checksum U-Boot verifies (`_verify_dtb_checksum()`: `calc 74a83725, store 74a83725`,
  `total valid 2`): not signed, but an edited copy needs a matching checksum. What BL33 does with an
  invalid DTB is not in the log.
