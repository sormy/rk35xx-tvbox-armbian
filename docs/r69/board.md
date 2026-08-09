# R69 — board details

Everything specific to the **R69** box. General install/update instructions are in the
[README](../../README.md); the bring-up story is in [worklog.md](worklog.md) and the device-tree
changes in [dtb.md](dtb.md).

<img src="image1.jpg" alt="The R69 RK3518 Android TV box" width="320">

## Identity — check yours matches before flashing

|               |                                                                                                |
| ------------- | ---------------------------------------------------------------------------------------------- |
| Name          | **"R69"** (stock `ro.product.name=R69-1`), Android 14                                          |
| Sold as       | [amazon.com/dp/B0GK8P5YFT](https://www.amazon.com/dp/B0GK8P5YFT) — ~$35 complete with PSU      |
| SoC           | **RK3518A** — `SoC: 35181001`, reports `rk3528` (RK3518 is a variant in the RK3528 family)     |
| RAM / storage | 2 GB DRAM (**~1.5 GB usable** — boot-chain ceiling) · 16 GB Samsung eMMC 5.x (HS200) · microSD |
| Runs from     | eMMC since 2026-08-09 (`mmcblk2p1`); factory Android overwritten — backup in `backup/r69/`     |
| Wi-Fi / BT    | **AIC8800D80** — SDIO Wi-Fi + UART Bluetooth                                                   |
| Ports         | HDMI · USB 2.0 · USB 3.0 · 10/100 Ethernet · microSD · AV jack · IR-extender jack              |
| Remote        | bundled 22-button remote — **dual-mode**: IR unpaired, BLE when paired                         |
| Serial header | 4 pads by the SD slot, **1500000** baud (board silkscreen `XR821_V1.1`)                        |

The sticker says 2 GB and it really is 2 GB of chips, but the factory TPL only hands 1.5 GB to the
OS and that ceiling isn't fixable from here — the full account is in [worklog.md](worklog.md).

## Measured on our unit

Not a spec — one box, one kernel. Unmeasured rows say so.

| What            | Result                                                                       |
| --------------- | ---------------------------------------------------------------------------- |
| Ethernet        | **100 Mb/s full duplex** — the hardware ceiling (no gigabit PHY)             |
| eMMC sequential | **91.6 MB/s read · 74.6 MB/s write** (read is the HS200/100 MHz ceiling)     |
| eMMC random 4K  | **4,542 read / 4,620 write IOPS**                                            |
| SD card read    | **23.4 MB/s** (the card in this box, not a board limit)                      |
| CPU thermals    | 44 °C idle · **58 °C** after 5 min 4-core load, no throttling (95 °C trip)   |
| Boot to login   | **~17 s** from eMMC (~20 s from SD)                                          |
| Wi-Fi           | 2.4 GHz link here (HE, 143/129 Mbit/s PHY); goodput not benchmarked properly |
| GPU             | lima binds (Mali-450); no display attached, so unrendered                    |

The eMMC is deliberately capped at **HS200/100 MHz**: HS400ES read ~290 MB/s but sustained writes
corrupted data, and the factory runs it at HS200 for the same reason. Speed traded for integrity.

Its Samsung part is the faster of the two boxes by a wide margin on everything the bus doesn't cap —
**70% quicker sequential writes and ~50% more random-4K read IOPS** than the H96 Max's Micron
(measured with identical `fio` runs). Reads match exactly, because there both boards sit on the 100
MHz ceiling.

## Names on disk

The R69 shipped before the family naming existed, so **its installed files keep the `r69-` prefix**
for backward compatibility (every other board uses `rk35xx-`):

| Thing              | Path                                                          |
| ------------------ | ------------------------------------------------------------- |
| Identity dir       | `/usr/local/share/r69/`                                       |
| First-boot setup   | `/usr/local/sbin/r69-firstboot`                               |
| IR driver rebuild  | `/usr/local/sbin/rockchip-pwm-remotectl-r69-setup`            |
| PHY driver rebuild | `/usr/local/sbin/rk630-phy-r69-setup`                         |
| Power-key drop-in  | `/etc/systemd/logind.conf.d/zz-r69-powerkey.conf`             |
| Update in place    | `/usr/local/sbin/r69-update` (thin alias for `rk35xx-update`) |
| Watchdog config    | `/etc/systemd/system.conf.d/zz-r69-watchdog.conf`             |

## Front LED

Two entries under `/sys/class/leds/`: **`power`** (blue) and **`standby`** (red).

```sh
echo 1 > /sys/class/leds/power/brightness           # on (0 = off)
echo heartbeat > /sys/class/leds/standby/trigger    # pulse (none = back to manual)
```

## IR remote

Built and loaded automatically on first boot. The remote appears as input device **`ffa90030.pwm`**
(usually `/dev/input/event4` — confirm with `evtest`), scancodes from `rockchip,usercode = <0xfb05>`
in `firmware/r69/board.dts`.

> **Baseline, not a spec.** This is the mapping of _our_ unit. These boxes vary between production
> runs — the H96 Max's remote already answers to a different usercode (`0xfb04`) with different
> codes for OK and the app row. Check yours with `evtest` (method in the
> [README](../../README.md#remote)).

| Button                    | Key event                                        |
| ------------------------- | ------------------------------------------------ |
| Power                     | `KEY_POWER`                                      |
| OK (center)               | `KEY_ENTER`                                      |
| Up / Down / Left / Right  | `KEY_UP` / `KEY_DOWN` / `KEY_LEFT` / `KEY_RIGHT` |
| Back                      | `KEY_BACK`                                       |
| Home                      | `KEY_HOME`                                       |
| Delete                    | `KEY_BACKSPACE`                                  |
| Hamburger (menu)          | `KEY_MENU`                                       |
| Cog (settings)            | `KEY_SETUP`                                      |
| Voice                     | `KEY_HELP`                                       |
| Mouse                     | `KEY_TEXT`                                       |
| Volume up / down          | `KEY_VOLUMEUP` / `KEY_VOLUMEDOWN`                |
| Mute                      | `KEY_MUTE`                                       |
| Page up / down            | `KEY_PAGEUP` / `KEY_PAGEDOWN`                    |
| YouTube / Netflix         | `KEY_F6` / `KEY_F7`                              |
| Prime Video / Google Play | `KEY_F3` / `KEY_F8`                              |

Rebuild the driver by hand (e.g. after a kernel change), or test keys:

```sh
rockchip-pwm-remotectl-r69-setup   # DKMS rebuild + load; survives kernel updates
evtest /dev/input/event4           # apt install evtest
```

The **voice** and **mouse** buttons emit plain key events; their special functions (voice capture,
on-screen cursor) are not wired up over IR.

**The remote is dual-mode — BLE pairing verified.** Hold **left + right** until its LED blinks, then
follow the one-session recipe in the [README](../../README.md#remote). It bonds as
**`Bluetooth remote`** and reports a battery level (97% here).

Notably it is **the same BLE HID model as the H96 Max's remote** — both `usb:v2B54p1600` — even
though the two answer to different IR usercodes (`0xfb05` here, `0xfb04` there). Pairing creates
`Bluetooth remote Consumer Control` (buttons), `Bluetooth remote Mouse` (the air-mouse) and a vendor
node; BLE keycodes differ from the IR ones, so expect the H96's
[BLE mapping](../h96max/board.md#remote) rather than the IR table above. Spotting it in a crowded
scan: [here](../h96max/board.md#picking-it-out-of-a-crowded-scan).

## Watchdog

The SoC watchdog (`snps,dw-wdt`) is enabled in `board.dtb` and armed by systemd
(`RuntimeWatchdogSec=30`), so a hard hang reboots the box. The hardware timeout is **fixed at 44 s**
(no `SETTIMEOUT`, no magic-close — once opened it can't be disarmed short of a reset). Disable with
`RuntimeWatchdogSec=off` in the drop-in above, then `systemctl daemon-reexec`.

Verified on both boards: `/dev/watchdog` appears, systemd takes it at boot (journal:
`Using hardware watchdog`), and on the H96 Max a deliberate stop-petting test hard-reset the box.

## Toothpick button

The recessed button behind the AV jack is an `adc-keys` input — Linux sees `KEY_VOLUMEUP` on
`/dev/input/event3`, so it's a free button to remap. It is also the BootROM's maskrom trigger when
held at power-on.

## Bluetooth

`minimal` base images ship no `bluez`, and first boot never downloads anything. Install it once and
re-run the setup (it configures and starts BT, installs nothing):

```sh
sudo apt install bluez
sudo /usr/local/sbin/r69-firstboot
```

## Ethernet PHY

The integrated RK630 PHY needs its vendor driver for OTP calibration — without it some units drop to
10 Mb/s. It builds and loads automatically on first boot. To rebuild or check:

```sh
rk630-phy-r69-setup                          # DKMS rebuild + load
readlink /sys/class/net/end0/phydev/driver   # want "RK630 PHY", not "Generic PHY"
```

## Known gaps

Still open:

- **Back-to-stock is unverified.** `backup/r69/emmc-full.img` (15,758,000,128 B) is the only route
  back to Android now that the eMMC is overwritten, and restoring it has never been tested — either
  `dd` to the eMMC node from an SD rescue boot, or maskrom + `rkdeveloptool wl 0`. Identify the eMMC
  by its `boot0`/`boot1` companions, not a remembered number.
- **The BT controller's public address can't be pinned per unit.** It boots a stable public BD addr
  (persistent across reboots — it does not churn the way Wi-Fi did), but `btmgmt public-addr`
  returns `0x0c Not Supported`: no `set_bdaddr` for the generic H4 driver, and no known AIC vendor
  Write-BD_ADDR command. A per-unit static **LE** address via `btmgmt static-addr` does work. Only
  matters if you run several R69s on one network.
- **A dark window during cold boot** (cosmetic). The power cycle reads off → red, booting → dark,
  running → blue; the SoC reset clears the GPIOs and `leds-gpio` only re-drives blue when it probes
  ~10–15 s in. Filling it would mean driving an LED from U-Boot, which we do build ourselves.

## Recovery

Loader pair for this board, if you ever need to rewrite it by hand. **Find the eMMC first** —
`mmcblk` numbering shifts between images, and the eMMC is the disk with `boot0`/`boot1` companions:

```sh
EMMC=/dev/$(ls -d /sys/block/mmcblk*boot0 | head -1 | sed 's|.*/||;s|boot0||')
echo $EMMC    # sanity-check: ~16 GB, NOT your SD
```

```sh
sudo dd if=firmware/r69/factory_idbloader.bin of=$EMMC seek=64    conv=notrunc
sudo dd if=firmware/common/u-boot.itb         of=$EMMC seek=16384 conv=notrunc; sync
```

> **Images built before August 2026 soft-brick on `armbian-install`**
> ([#6](https://github.com/sormy/rk35xx-tvbox-armbian/issues/6)) — stock `armbian-install` writes
> the generic ROCK 2F loaders, which lack this box's DDR tuning. Current images override
> `write_uboot_platform` so every bootloader write uses the R69 pair. On an older image, run
> `r69-update` **before** migrating.
