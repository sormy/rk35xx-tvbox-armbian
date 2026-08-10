# H96 Max — board details

Everything specific to the **H96 Max** box (retail name "H96 Max H313" — the H313 is branding, the
silicon is RK3518). General install/update instructions are in the [README](../../README.md); the
bring-up story is in [worklog.md](worklog.md) and the device-tree changes in [dtb.md](dtb.md).

<img src="board.jpg" alt="H96 Max PCB, serial header bottom-right" width="360">

## Identity — check yours matches before flashing

|               |                                                                                                 |
| ------------- | ----------------------------------------------------------------------------------------------- |
| Name          | **H96 Max** (LEFFOT; listed as "H96 Max H313"). Case plate: `RAM 2GB · ROM 16GB · Input 5V⎓2A`  |
| Board         | silkscreen **`3518_ZX_V01 20250818`** — combined RAM+eMMC module, on-PCB Wi-Fi/BT antennas      |
| SoC           | **RK3518** — `SoC: 35181001` (same ID as the R69)                                               |
| RAM / storage | 2 GB LPDDR3 (**a real 2 GB**) · 16 GB Micron eMMC `R1J96N` (14.7 GiB) · SD card slot            |
| Wi-Fi / BT    | **Seekwave SV6160LITE** (module **SWT6621S**) — SDIO Wi-Fi 6, BT muxed over the same SDIO link  |
| Ports         | HDMI · USB 3.0 · USB 2.0 · 10/100 Ethernet · SD slot · AV jack · IR receiver · toothpick button |
| Remote        | **dual-mode** — works over IR unpaired, and pairs over BLE for air-mouse + battery              |
| Stock         | Android 14, 32-bit, kernel 6.1.118                                                              |

Unlike the R69, all 2 GB of RAM is usable here.

## Measured on our unit

Not a spec — one box, one kernel. A sanity baseline: if yours lands in the same ballpark, nothing is
wrong.

| What              | Result                                                           |
| ----------------- | ---------------------------------------------------------------- |
| Ethernet          | **87 Mbit/s goodput** — wire speed for 100FD, both directions    |
| Wi-Fi (5 GHz, ax) | **173 Mbit/s down / 76 Mbit/s up**, 3.6 ms ping (through SSH)    |
| eMMC sequential   | **91.6 MB/s read · 44.0 MB/s write** (read is the HS200 ceiling) |
| eMMC random 4K    | **3,016 read / 3,783 write IOPS**                                |
| GPU               | **glmark2 41** at 1080p (lima, Mali-450)                         |
| Thermals          | 49 °C idle · **60 °C peak** after 5 min 4-core load (95 °C trip) |
| Boot (from eMMC)  | **~12 s** to login (4 s kernel + 8 s userspace)                  |

The eMMC's real win over a good SD card is **random 4K writes — ~6× faster** (3,783 vs 623 IOPS),
which is what makes the box feel quicker after migrating; sequential gains are milder. The R69's
Samsung part is quicker still on writes — see its [board doc](../r69/board.md#measured-on-our-unit).

## Hardware video

The RK3528-class VPU via `/dev/mpp_service` — **8K decode and 8K HEVC encode**, well past what the
box is sold as. Blocks, tools and the test behind each cell: [AGENTS.md](../../AGENTS.md#video-codec--every-format-both-directions).

**This board needed a device-tree graft to get here.** Its factory tree named the SoC only
`rockchip,rk3518`, a name no MPP release contains, so the library fell back to "unknown SoC" and the
entire VPU was unreachable — every encode died at `could not found coding type` and decode never
left the A53s. With `"rockchip,rk3528a"` appended ([dtb.md](dtb.md)) MPP identifies it:
`match chip name: rk3528a`, dec caps `0x00f0079c`, enc `0x00100180`.

**Decode ✅ — fps, measured here, 30-frame runs as a normal user:**

| Format |        720p | 1080p |   4K |   8K |
| ------ | ----------: | ----: | ---: | ---: |
| H.264  |       329.5 | 152.8 | 39.7 |  9.6 |
| HEVC   |       605.8 | 326.1 | 85.3 | 20.7 |
| MJPEG  |       521.7 | 292.0 | 91.1 | 23.6 |
| VP9    |       634.2 | 326.7 | 84.8 |   ➖ |
| MPEG-2 |       175.4 |  82.8 |   ➖ |   ➖ |
| MPEG-4 |       197.3 |  93.5 |   ➖ |   ➖ |
| VP8    |       129.6 |  59.7 |   ➖ |   ➖ |
| H.263  | 831.1 (CIF) |    ➖ |   ➖ |   ➖ |

**Encode ✅ — fps:**

| Format         |  720p | 1080p |   4K |   8K | Verdict                                  |
| -------------- | ----: | ----: | ---: | ---: | ---------------------------------------- |
| HEVC           | 125.9 |  60.6 | 15.9 |  4.0 | 4K/8K output confirmed real by `ffprobe` |
| MJPEG          | 323.2 | 172.0 | 49.3 | 12.7 |                                          |
| H.264, stock   |    ❌ |    ❌ |   ❌ |   ❌ | size 0 — an **upstream MPP bug**         |
| H.264, patched | 115.3 |  54.9 | 14.4 |  3.6 | [12-line fix](../../mpp/README.md)       |

Not present, and proven rather than assumed: **AV1** is refused with
`unable to create dec av1 for soc rk3528a unsupported`. **AVS / AVS+ / AVS2** are claimed by the
capability word but stay 🟡 — no encoder exists to make a sample clip.

> Two things here contradict MPP's own capability table, which marks this encoder `cap_4k = 0` and
> the decoder 4K: **8K decodes** on all three main codecs, and **HEVC encodes at 4K and 8K**, with
> `ffprobe` confirming genuine `7680x4320` bitstreams rather than downscaled ones.

The R69 measures within noise of every number above — same silicon, and a useful cross-check that
neither box is an outlier ([R69 board doc](../r69/board.md#hardware-video)).

## Names on disk

This board uses the family-neutral **`rk35xx-`** naming (only the R69 keeps legacy `r69-` names):

| Thing             | Path                                                                   |
| ----------------- | ---------------------------------------------------------------------- |
| Identity dir      | `/usr/local/share/rk35xx/` (incl. `board-id` = `h96max`)               |
| First-boot setup  | `/usr/local/sbin/rk35xx-firstboot`                                     |
| Power-key drop-in | `/etc/systemd/logind.conf.d/zz-rk35xx-powerkey.conf`                   |
| Update in place   | `/usr/local/sbin/rk35xx-update` (or `rk35xx-deploy` from your machine) |
| Watchdog config   | `/etc/systemd/system.conf.d/zz-rk35xx-watchdog.conf`                   |

## LEDs

Two entries under `/sys/class/leds/`: **`power`** (blue) and **`standby`** (red) — running is blue,
"off" and suspend are red. Both are independently controllable:

```sh
echo 1 > /sys/class/leds/power/brightness           # on (0 = off)
echo heartbeat > /sys/class/leds/standby/trigger    # pulse (none = back to manual)
```

Early boot briefly shows both LEDs dimly lit, until the kernel driver takes the pins — cosmetic.

## Remote

**Over IR, with no pairing at all** — every button works out of the box (input device
`ffa90030.pwm`, usually `/dev/input/event8`; confirm with `evtest`), scancodes from
`rockchip,usercode = <0xfb04>` in `firmware/h96max/board.dts`:

| Button            | Key event                                        |
| ----------------- | ------------------------------------------------ |
| Power             | `KEY_POWER`                                      |
| Hamburger (menu)  | `KEY_MENU`                                       |
| Voice (mic)       | `KEY_F14`                                        |
| Cog (settings)    | `KEY_F13`                                        |
| D-pad             | `KEY_UP` / `KEY_DOWN` / `KEY_LEFT` / `KEY_RIGHT` |
| OK (center)       | `KEY_REPLY`                                      |
| Back              | `KEY_BACK`                                       |
| Home              | `KEY_HOME`                                       |
| Backspace         | `KEY_BACKSPACE`                                  |
| Volume +/−        | `KEY_VOLUMEUP` / `KEY_VOLUMEDOWN`                |
| Mute              | `KEY_MUTE`                                       |
| P +/− (channel)   | `KEY_CHANNELUP` / `KEY_CHANNELDOWN`              |
| YT / NF / PV / GP | `KEY_F6` / `KEY_F7` / `KEY_F8` / `KEY_F9`        |
| Mouse             | `KEY_TEXT`                                       |

> **Baseline, not a spec.** This is _our_ unit's mapping. These boxes vary between production runs —
> the R69's remote answers to a different usercode (`0xfb05`) with different codes for OK and the
> app row. Check yours with `evtest` (method in the [README](../../README.md#remote)).

**Over Bluetooth** (optional) it adds the **air-mouse** and a battery reading. Pairing mode is
**left + right held until the LED blinks** — a steady glow comes first, the blink is pairing mode,
and the glow ends once a host connects. Use the one-session recipe in the
[README](../../README.md#remote); `pair` from a separate invocation fails with
`AuthenticationFailed`, and so does `--agent` alone.

### Picking it out of a crowded scan

If the `Bluetooth remote` name doesn't show, these narrow it down:

- **Scan before and after** entering pairing mode — the entry that _appears_ is the remote. Never
  guesses wrong.
- **LE Public address.** Phones, watches and earbuds nearly all use rotating LE _Random_ addresses,
  so a public one stands out. `sudo btmgmt find` prints the type; `bluetoothctl` doesn't.
- **Strongest RSSI** with the remote held against the box (−30 dBm range vs −70/−90 across a room),
  and once found, HID `0x1812` + Battery `0x180f` services — nothing else in a living room
  advertises HID.

While BLE-connected the remote stops transmitting IR (so buttons never double-fire), and it falls
back to IR when unpaired — which is also why the power button can still wake the box from "off",
where Bluetooth is dead. BLE keycodes differ from the IR ones (OK is `KEY_SELECT`, home is
`KEY_HOMEPAGE`), so anything binding keys should handle both.

The **voice mic** is out of scope rather than broken. The BLE link is up and the button reports
(`KEY_SEARCH`); the audio just rides the proprietary Android-TV voice GATT service (`0xfeb3`) rather
than standard BLE audio, so it surfaces neither an ALSA capture device nor a BlueZ transport.
Capturing and acting on that stream is an application's job — a userspace client for the protocol —
not something an image builder can ship.

## Watchdog

The SoC watchdog (`snps,dw-wdt`) is enabled in `board.dtb` and armed by systemd
(`RuntimeWatchdogSec=30`), so a hard hang reboots the box instead of leaving it dead. Verified here:
a deliberate stop-petting test hard-reset it.

The hardware timeout is **fixed at 44 s** — `SETTIMEOUT` is unsupported and there is no magic-close,
so once something opens `/dev/watchdog` it cannot be disarmed short of a reset. To turn it off, set
`RuntimeWatchdogSec=off` in the drop-in above and `systemctl daemon-reexec`.

## Toothpick button

The recessed button behind the AV jack is an `adc-keys` input — `KEY_VOLUMEUP` on its own event
node, free to remap. Held at power-on it is also the BootROM's maskrom trigger.

## HDMI on a PC monitor

TVs are fine. **PC monitors whose native mode needs a non-standard pixel clock** (e.g. 2256×1504)
show a garbled image with a dotted band and an odd refresh rate — the vendor clock driver can only
synthesize standard HDMI rates. Pin a standard mode:

```sh
# append to extraargs in /boot/armbianEnv.txt, then reboot
video=HDMI-A-1:1920x1080@60
```

This is deliberately **not** baked into the image: it would cap 4K TVs at 1080p.

## Recovery

Loader pair for this board, if you ever need to rewrite it by hand. **Find the eMMC first** —
`mmcblk` numbering shifts between images, and the eMMC is the disk with `boot0`/`boot1` companions:

```sh
EMMC=/dev/$(ls -d /sys/block/mmcblk*boot0 | head -1 | sed 's|.*/||;s|boot0||')
echo $EMMC    # sanity-check: ~16 GB, NOT your SD
```

```sh
sudo dd if=firmware/h96max/factory_idbloader.bin of=$EMMC seek=64    conv=notrunc
sudo dd if=firmware/common/u-boot.itb            of=$EMMC seek=16384 conv=notrunc; sync
```
