# Armbian for Amlogic TV boxes

Debian on an Amlogic Android TV box: a stock Armbian image plus a board overlay — device tree,
drivers, boot shim. Nothing is forked, so `apt upgrade` keeps updating kernel and userspace.

**Host: macOS or Linux.** Not Windows.

## Boxes

| Box                                                | Board                                                | Hardware                                                                                                   | Base · install                 |
| -------------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------ |
| <img src="docs/h96max-m20/image1.png" width="260"> | **H96 Max M20**<br>`905_DG_ZX01_V01`<br>`2025/09/03` | SoC S905L3<br>2 GB RAM · 16 GB eMMC<br>USB-C 2.0 (OTG) + USB-A 2.0<br>**no Ethernet** · MT7668S Wi-Fi + BT | [Le Potato][lepo]<br>USB stick |

[lepo]: https://www.armbian.com/lepotato/
[doc]: docs/h96max-m20/board.md

## What works

| Mark | Means                                                                |
| :--: | -------------------------------------------------------------------- |
|  ✅  | tested here — the number behind it is in the [board doc][doc]        |
|  🟡  | likely — a proven mechanism backs it and nothing indicates a problem |
|  ❓  | never tested                                                         |
|  ❌  | broken                                                               |
|  ➖  | not on this board                                                    |

| Hardware                           | H96 Max M20 |
| ---------------------------------- | :---------: |
| **Storage**                        |             |
| USB stick — boot and rootfs        |     ✅      |
| eMMC — read and write              |     ✅      |
| eMMC — boot and rootfs             |     ❓      |
| microSD — boot and rootfs          |     ❓      |
| USB 2.0                            |     ✅      |
| USB 3.0                            |     ➖      |
| **Network**                        |             |
| Ethernet, onboard                  |     ➖      |
| Ethernet, USB adapter              |     ✅      |
| Wi-Fi 2.4 GHz — mainline mt76      |     ✅      |
| Wi-Fi 5 GHz — mainline mt76        |     ✅      |
| Wi-Fi 2.4 GHz — vendor, fallback   |     ✅      |
| Wi-Fi 5 GHz — vendor, fallback     |     ✅      |
| Bluetooth                          |     ✅      |
| **Display and video**              |             |
| HDMI video                         |     ❓      |
| HDMI audio                         |     ❓      |
| GPU — Mali under lima              |     ❌      |
| Video decode and encode            |     ❌      |
| CMA reservation                    |     ❌      |
| **Input and indicators**           |             |
| Bundled remote over IR             |     ❓      |
| Bundled remote over Bluetooth      |     ❓      |
| Front button                       |     ❓      |
| Power LED                          |     ✅      |
| Standby LED                        |     ➖      |
| **Power and recovery**             |             |
| CPU frequency scaling              |     ❌      |
| Thermal zones                      |     ❌      |
| Hardware watchdog                  |     ✅      |
| Serial console                     |     ✅      |
| eMMC backup over USB, burning mode |     ✅      |
| Unbrick from the mask ROM          |     ❓      |

## Build

```bash
./build-e2tools.sh                              # once — stock e2tools corrupts an image on delete
./build-image.sh                                # lists every board and the Armbian image it takes
./build-image.sh Armbian_..._minimal.img.xz <board>
```

## Back up first

**USB-A male-to-male** cable into the OTG port, with a USB-C→USB-A female adapter on each end that
is USB-C. The cable powers the box, so no PSU.

```sh
./build-amltools.sh                              # once -> tools/aml/amlcmd
./tools/aml/amlcmd connect                       # then plug the OTG cable into the box
./tools/aml/amlcmd backup backup/<board>/emmc-full.img
```

A stock box needs no button: `connect` is waiting when its cold boot opens the burning gadget for
700 ms. Once the USB install has cleared `try_auto_burn`, hold the button while plugging in instead.

## Install

One image, three ways. A stick leaves the eMMC untouched: pull it and Android boots. Both eMMC ways
replace Android, and a mistake there is a restore from the backup.

| Way                  | Android | Status |
| -------------------- | :-----: | :----: |
| USB stick            |  kept   |   ✅   |
| USB stick, then eMMC |  gone   |  TODO  |
| Straight to eMMC     |  gone   |   ❓   |

### USB stick

1. Flash it, and plug it into the USB-A port:

```sh
sudo gdd if=Armbian_..._-<board>.img of=/dev/rdiskN bs=4M conv=fsync status=progress; sync  # macOS
sudo dd  if=Armbian_..._-<board>.img of=/dev/sdX    bs=4M conv=fsync status=progress; sync  # Linux
```

2. Point the box at it once, over the OTG cable:

```sh
./tools/aml/amlcmd connect                       # then plug the OTG cable into the box
./tools/aml/amlcmd setenv try_auto_burn
./tools/aml/amlcmd setenv usb_on usb start 0
./tools/aml/amlcmd setenv bootcmd run usb_on recovery_from_udisk storeboot
./tools/aml/amlcmd saveenv
./tools/aml/amlcmd reset
```

The box boots the stick, whose `aml_autoscript` then points `bootcmd` at it for good: every later
power-on boots it with nothing attached. Over a serial console instead, the [board doc][doc] has the
three U-Boot commands that do the same.

```bash
ssh root@<board-hostname>                # Armbian default password for root is 1234
```

Needs a USB adapter or Wi-Fi where no Ethernet is fitted.

### USB stick, then eMMC — TODO

An on-box run of the eMMC installer below, from the booted stick. It is in `TODO.md`.

> `armbian-install` is not this: it zeroes the vendor bootloader and partitions over `reserved`,
> where this unit's keys live.

### Straight to eMMC

Writes the image's own regions over the OTG cable; the bootloader and this unit's keys stay. Takes
the backup, which must be this box's:

```sh
./tools/aml/amlcmd connect                       # hold the button, then plug in the OTG cable
scripts/aml-emmc-install Armbian_..._-<board>.img backup/<board>/emmc-full.img
./tools/aml/amlcmd reset
```

## Update a running box

```bash
./rk35xx-deploy root@<board-hostname>   # push this repo and apply  (--reboot if the DTB changed)
sudo rk35xx-update --pull               # …or on the box, fetching the repo itself
```

## Serial console

For debugging. **3.3 V, 115200 baud** — any 3.3 V USB-TTL adapter does it. Unplug the OTG cable to
get a U-Boot prompt: a stock box with it in goes to burning mode instead.

| Board       | Where                                       | Pads                |
| ----------- | ------------------------------------------- | ------------------- |
| H96 Max M20 | 3 plated holes on the **back**, dead centre | HDMI <- TX GND [RX] |

```bash
tio -b 115200 -L --log-file boot.log /dev/cu.usbserial-XXXX   # macOS: cu.*, not tty.*
tio -b 115200 -L --log-file boot.log /dev/ttyUSB0             # Linux
```

GND, TX and RX only, crossed (box TX → adapter RX). **Never connect 3V3/VCC.** To read the log
without typing, GND and TX are enough — GND off any metal shield on the board does it.

## Recovery

```sh
./tools/aml/amlcmd connect                       # hold the button, then plug in the OTG cable
./tools/aml/amlcmd restore backup/<board>/emmc-full.img
```

## License

Scripts MIT. Vendor blobs keep their own licenses.
