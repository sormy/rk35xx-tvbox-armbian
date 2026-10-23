# TVBian for Amlogic TV boxes

[![Latest release](https://img.shields.io/github/v/release/sormy/tvbian?label=release&sort=date)](https://github.com/sormy/tvbian/releases/latest)
[![Released](https://img.shields.io/github/release-date/sormy/tvbian?label=released)](https://github.com/sormy/tvbian/releases/latest)
[![Weekly build](https://github.com/sormy/tvbian/actions/workflows/release.yml/badge.svg)](https://github.com/sormy/tvbian/actions/workflows/release.yml)

Debian on an Amlogic Android TV box: mainline Linux, our drivers, a weekly signed image. The box
came with Android and a promise of updates; one of those two was real. Rockchip boxes are in
[README.md](README.md).

**Host: macOS or Linux.** Not Windows.

## Boxes

| Box                                                | Board                                                | Hardware                                                                                                   | Install   |
| -------------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | --------- |
| <img src="docs/h96max-m20/image1.png" width="260"> | **H96 Max M20**<br>`905_DG_ZX01_V01`<br>`2025/09/03` | SoC S905L3<br>2 GB RAM · 16 GB eMMC<br>USB-C 2.0 (OTG) + USB-A 2.0<br>**no Ethernet** · MT7668S Wi-Fi + BT | USB stick |

[doc]: docs/h96max-m20/board.md

## What works

| Mark | Means                                                                |
| :--: | -------------------------------------------------------------------- |
|  ✅  | tested here — the number behind it is in the [board doc][doc]        |
|  🟡  | likely — a proven mechanism backs it and nothing indicates a problem |
|  ❓  | never tested                                                         |
|  ❌  | broken                                                               |
|  ➖  | not on this board                                                    |

| Hardware                                  |   H96 Max M20   |
| ----------------------------------------- | :-------------: |
| **Storage**                               |                 |
| USB stick — boot and rootfs               |       ✅        |
| eMMC — boot and rootfs                    |       ✅        |
| microSD — boot and rootfs                 |       ➖        |
| USB 2.0                                   |       ✅        |
| USB 3.0                                   |       ➖        |
| **Network**                               |                 |
| Ethernet, onboard                         |       ➖        |
| Ethernet, USB adapter                     |       ✅        |
| Wi-Fi 2.4 GHz — mainline mt76             |       ✅        |
| Wi-Fi 5 GHz — mainline mt76               |       ✅        |
| Wi-Fi, another access point — mt76        |       ✅        |
| Bluetooth                                 |       ✅        |
| **Display and video**                     |                 |
| HDMI video, the panel's native mode       |       ✅        |
| HDMI audio                                |       ✅        |
| GPU — Mali under lima                     |       ✅        |
| Video decode — H.264, HEVC, VP9 to 4K     |       ✅        |
| Video decode — MPEG-1/2 to 1080p          |       ✅        |
| Video decode — MPEG-4, MJPEG to 1080p     |       ✅        |
| Video decode — VC-1 to 1080p              |       ✅        |
| Video decode — AVS, Real                  | not implemented |
| Video encode — H.264 to 1080p, HEVC to 4K |       ✅        |
| CMA reservation                           |       ✅        |
| **Input and indicators**                  |                 |
| Bundled remote over IR                    |       ➖        |
| Bundled remote over Bluetooth             |       ✅        |
| Reset button                              |       ➖        |
| Power LED                                 |       ✅        |
| Standby LED                               |       ➖        |
| **Power and recovery**                    |                 |
| CPU frequency scaling                     |       ✅        |
| Thermal zones                             |       ✅        |
| Hardware watchdog                         |       ✅        |
| Suspend, woken by the BT remote           |       ❌        |
| Serial console                            |       ✅        |
| eMMC backup over USB, burning mode        |       ✅        |
| Unbrick from the mask ROM                 |       ❓        |

AVS and RealVideo are not implemented. If you have RealVideo files to watch, you have other
problems.

## Get an image

Every box's image is on the [latest release](https://github.com/sormy/tvbian/releases/latest), with
signed checksums. Build it yourself instead with `./build.sh`: [docs/build.md](docs/build.md).

## Back up first

**USB-A male-to-male** cable into the OTG port, with a USB-C→USB-A female adapter on each end that
is USB-C. The cable powers the box, so no PSU.

```sh
./build.sh tool amlcmd    # once -> build/bin/amlcmd
build/bin/amlcmd connect  # then plug the OTG cable into the box
build/bin/amlcmd backup emmc-stock.img
xz -T0 -c emmc-stock.img > backup/<board>-stock.img.xz && rm emmc-stock.img
```

A stock box needs no button. If `connect` waits forever, hold the button, plug in, then release it.

## Install

1. Flash the image to a stick, and plug it into the USB-A port:

```sh
xz -dc tvbian-<board>-trixie-<date>.img.xz | sudo dd of=/dev/rdiskN bs=4m status=progress; sync   # macOS
xz -dc tvbian-<board>-trixie-<date>.img.xz | sudo dd of=/dev/sdX bs=4M status=progress; sync      # Linux
```

2. Point the box at it once, over the OTG cable:

```sh
build/bin/amlcmd connect  # then plug the OTG cable into the box
build/bin/amlcmd setenv try_auto_burn
build/bin/amlcmd setenv usb_on usb start 0
build/bin/amlcmd setenv bootcmd run usb_on recovery_from_udisk storeboot
build/bin/amlcmd saveenv
build/bin/amlcmd reset
```

Once is enough: every later power-on boots the stick. Pull it and Android boots, none the wiser.

3. Log in: `ssh root@<board-key>.local`, password `1234`, expired, so pick a new one. A user, the
   timezone, the locale and Wi-Fi: [docs/first-login.md](docs/first-login.md). No Ethernet is
   fitted, so a USB adapter or the HDMI console gets you to Wi-Fi first.

4. Optionally, move to the eMMC. **This replaces Android.** From the booted stick:

```sh
sudo tvb-install
sudo poweroff                                    # pull the stick; it boots from eMMC
```

## Update a running box

```bash
sudo apt update && sudo apt upgrade
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

GND, TX and RX only, crossed (box TX → adapter RX). **Never connect 3V3/VCC.**

## Recovery

```sh
xz -dc backup/<board>-stock.img.xz > emmc-stock.img
build/bin/amlcmd connect  # hold the button (may not be needed); plug in OTG
build/bin/amlcmd restore emmc-stock.img
```

Android comes back exactly as it was, its updates still pending. More, including the mask ROM:
`docs/amlogic-burning-mode.md`.

## License

Scripts MIT. Vendor blobs keep their own licenses.
