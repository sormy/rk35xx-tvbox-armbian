# Mortal T1 — board details

Sold as the **"MORTAL T1"** — a no-name RK3518 Android TV box whose label and stock Android both lie
about the hardware. Its SoC reports `rk3528` (RK3518 is a variant in that family), which is what
makes a stock ROCK 2F image the right base.

## Identity — check yours matches before flashing

|               |                                                                                                                                                                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Name          | **"MORTAL Model T1"** (label), stock `ro.product.system.device=rk3518_box_32`, `ro.fota.device=XR822_A52_T1_14`, Android 14, **32-bit**                                                                                                          |
| SoC           | **RK3518** — `rk3518a1`, reports `rk3528`, 4× Cortex-A53 @ 1.42 GHz                                                                                                                                                                              |
| RAM           | **1.5 GB** ✅ measured — `/proc/iomem` single range `00200000-5fffffff` (1536 MiB), `Memory: 1570816K`; SPL caps at 2 GB (`rk3518a1_max_2gbyte_limit`), this unit fits 1.5. Stock runs `ro.config.low_ram=true`. **Label claims 16 GB — false.** |
| Storage       | **8 GB Samsung eMMC** ✅ measured — sysfs `name=H8G4u manfid=0x000090`, `rfi` 7456 MB / 15269888 sectors, GPT disk = 7455 MiB. **Label claims 256 GB — false.**                                                                                  |
| Label MAC     | **`00:1C:79:A1:71:92`** (Rockchip OUI)                                                                                                                                                                                                           |
| Wi-Fi / BT    | **AIC8800D80 SDIO + UART BT** ✅ confirmed — `aicwf_sdio_chipmatch USE AIC8800D80` in dmesg; `wlan0` associates (5 GHz ch36), `hci0` UP RUNNING                                                                                                  |
| Ports         | HDMI · USB-A 3.0 (OTG, flash port) · microSD (TF) · USB-C power · button beside HDMI (inert — no maskrom, no power-off) · **no ethernet**                                                                                                        |
| PCB marking   | `XR8223518K-V1.0`                                                                                                                                                                                                                                |
| Serial header | not yet located — HDMI output works, so serial is a fallback, not a gate                                                                                                                                                                         |

## The masking (why stock Android shows the wrong specs)

Two independent lies, measured from the full eMMC backup (`mortal-t1-eMMC-stock.img`, md5
`6537dc0b8a25c421ec108ae03594acbb`):

1. **The sticker (16 GB / 256 GB)** — physically impossible: DRAM measures 1.5 GB (`/proc/iomem`
   ends at `0x5fffffff`) against an SPL cap of 2 GB, and the eMMC measures 7.45 GB. Android itself
   never claims 16/256 anywhere in the firmware — the fake numbers live in the seller's launcher,
   not the OS.
2. **The identity** — stock Android spoofs `brand=google / model=Google_TV` with a **Pixel 5
   (`redfin`) fingerprint** to pass Google certification/Widevine checks, hiding
   `rk3518_box_32`/`XR822_A52_T1_14`.

Removing the display lie is possible (it's files in `super`); upgrading the hardware is not. Armbian
reports everything honestly — `dmesg` states `Memory: 1570816K` (1.5 GB), measured 2026-09-27.

## Evidence in `stock/mortal-t1/`

| File             | What                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| `board.dtb`      | factory kernel DTB from the eMMC `boot` partition (md5 `7e4cf9b6…`; both copies in `boot.img` identical) |
| `uboot.dtb`      | factory U-Boot control DT from the `uboot` partition (md5 `c252300d…`, embedded twice)                   |
| `gpt.bin`        | GPT header + entries, first 34 sectors                                                                   |
| `partitions.txt` | partition map with measured sizes (disk = 7455 MiB)                                                      |

Full stock image (7.8 GB, verified) in `backup/mortal-t1/mortal-t1-eMMC-stock.img` (gitignored) —
restore with `rkdeveloptool wl 0 <sectors> <img>` after a `db` of `rk3528_spl_loader-mortal-t1.bin`.

## Relation to the R69

The factory kernel DT differs from the R69's by **26 lines** (IR key tables for a different remote,
one `u2phy_otg` status); the factory U-Boot DT by **one** (`max-frequency` 80 vs 50 MHz). This board
therefore reuses the R69's grafts verbatim (only `model`/`compatible` adapted) — see `dtb.md` and
`worklog.md`.

## Measured — run 2, 2026-09-28

### Boot, memory, watchdog

|                  |                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| Second boot      | 20.650 s (`systemd-analyze`) — the recorded figure                                                       |
| blame            | `rk35xx-bt` 6.2 s, `armbian-ramlog` 3.0 s, `rk35xx-mac-pin` 2.7 s; no wait on end0 or DHCP               |
| Ten warm reboots | 11/11 — root, `.49`, stable MACs, `wlan0` (0 s), `hci0`, input nodes, `/dev/video0`, `fake-hwclock` save |
| SD index         | flips mmcblk0↔mmcblk1 (3 of 11) — identify eMMC by `boot0`/`boot1`, never a remembered number            |
| On disk          | eMMC `mmcblk2` (`boot0`/`boot1`, HS200, 14 stock partitions); root on SD; zram swap 732 MB               |
| RAM              | 1536 MiB total (`free` 1465 MB); `stress-ng --vm --verify` 4 pass / 0 fail                               |
| Watchdog         | `/dev/watchdog` + `watchdog0`, `wdctl` busy (systemd holds); granted 89.5 s = `2^(16+15)` at 24 MHz      |
| RTC              | ➖ absent — no `/dev/rtc*`, no `/sys/class/rtc`, no dmesg line                                           |

### CPU and thermal

|                     |                                                                        |
| ------------------- | ---------------------------------------------------------------------- |
| Frequencies         | `1200000 1416000`; stock-vs-ours `operating-points-v2` diff empty      |
| 300 s 4-core stress | 48.3 → 58.3 °C, no throttle (trips 95/110/120 °C, freq pinned 1416000) |
| Draw                | ❓ no meter at hand — bare board, idle / suspended / off               |

### Storage — fio, fixed parameters (`--direct=1`)

| Medium               | seq 1M QD8 r/w   | rand 4K QD32 r/w |
| -------------------- | ---------------- | ---------------- |
| SD SU16G (HS 50 MHz) | 23.9 / 5.4 MB/s  | 4.0 / 0.60 MB/s  |
| eMMC (from 16 M)     | 87.8 / 37.7 MB/s | 23.4 / 16.9 MB/s |

- eMMC full-disk read: 7.8 GB in one pass, 94.7 s, 82.5 MB/s, no stall.
- SD ceiling is High Speed: raw `dd iflag=direct` 23.7 MB/s — the DT (stock-identical) has no
  `vqmmc-supply`, so no 1.8 V and no UHS/SDR104 (same as h313).
- eMMC fio from offset 16 M overwrote stock `misc` and `super`; `boot` lost `ANDROID!`.
  `uboot`@16384 `d00dfeed`, GPT, boot0/1 intact; `DVKR`@7168 / `SSKR`@8192 still tagged; vendor
  storage `lan` = `00:1c:79:a1:71:92` = the sticker. Restore = `dd` of `mortal-t1-eMMC-stock.img`,
  no maskrom needed.
- The first SD read run was an artifact (time_based reads of a partly-unwritten file zero-fill
  unwritten extents: 143 MB/s). The row is the redo on a fully-written file, caches dropped, 512 M
  working set (the fixed 1 G file would take 190 s to write at 5.4 MB/s).

### Network

|           |                                                                                                                                        |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 5 GHz     | ch36 (5180): TX 11.6–23.2 / RX 8.5–40.3 Mbps across 12 interleaved A/B runs, `tx failed: 0`, no latch                                  |
| 2.4 GHz   | ch4 (2457): 10.7 up / 8.5 down Mbps, 8.8 Mbps under 4-core load, no latch (post-load PHY 103.2 HE-MCS8)                                |
| regdom    | effective `US` (AP Country IE); global `country 98`, `phy#0 (self-managed)` — `iw reg set` never reaches the radio                     |
| wlan0 MAC | `02:1c:79:97:7b:ae`, stable 11/11 — derived (chip permaddr is random per boot, so no eFUSE address exists), absent from every aic blob |
| Bluetooth | `hci0` UP RUNNING `errors:0`; BD `0B:3B:22:AC:88:20` identical across three reboots — the controller's own, never set by us            |
| end0      | ➖ not created — no RJ45 on this PCB, `gmac0` carries a `NOT FITTED` hunk (device tree below); boot log has no gmac/phy lines at all   |

### GPU — surfaceless EGL (`egl-tri`, needs no display)

| Res       | fps | Mpix/s |
| --------- | --- | ------ |
| 1280×720  | 170 | 157    |
| 1920×1080 | 79  | 163    |
| 3840×2160 | 20  | 168    |

Mali-450 via lima, Mesa 25.0.7; `GL_MAX_TEXTURE_SIZE` = 4096.

### Video codec — MPP `14729dd`, run as `twilight`

Gate: `match chip name: rk3528a`, `dec 00f0079c enc 00100180` (+ benign
`confliction found at client_type 3`: kernel vcodec_type `0x3001320a` vs soc info `0x00013202`).

Decode fps — `mpi_dec_test -n 30`, content spot-checked real:

| Codec  | 720p                     | 1080p | 4K       | 8K       |
| ------ | ------------------------ | ----- | -------- | -------- |
| H.264  | 632.9                    | 338.9 | 87.0     | 15.2     |
| HEVC   | 594.4                    | 320.9 | 81.4     | 19.5     |
| VP9    | 640.5                    | 328.5 | 83.6     | 20.1     |
| MJPEG  | 509.7                    | 290.2 | 90.7     | 16.0     |
| VP8    | 130.3                    | 59.6  | ❌ black | ❌ black |
| MPEG-2 | 176.2                    | 83.0  | ❌ hang  | ❌ hang  |
| MPEG-4 | 196.7                    | 93.0  | ❌ hang  | ❌ hang  |
| H.263  | 833.2 (CIF, fixed sizes) |       |          |          |

Encode fps — all decode back rc=0:

| Codec | 720p  | 1080p | 4K   | 8K   |
| ----- | ----- | ----- | ---- | ---- |
| H.264 | 115.5 | 54.9  | 14.4 | 3.60 |
| HEVC  | 125.6 | 60.8  | 15.9 | 3.99 |
| MJPEG | 322.6 | 173.4 | 49.9 | 13.0 |

- VP8 above 1080p is silent corruption: rc=0, 30 frames, fps _faster_ than 1080p (203/77 — the
  tell), `-o` output black after frame 0. MPEG-2/MPEG-4 above 1920×1088 hang: parser loop
  `Warning: unsupport larger than 1920x1088`, zero codec IRQs, `timeout` rc=124, process-local.
- AV1 refused by name: `mpp: unable to create dec av1 for soc rk3528a unsupported`.
- AVS/AVS+/AVS2 decoder create accepted (no AVS-style refusal) — 🟡, no clip exists.
- IRQs per 30-frame run (one per frame): `65 ff740100.rkvdec` = H.264/HEVC/VP9 · `64 ff870000.jpegd`
  = MJPEG · `63 ff7c1000.avsd_plus, ff7c0400.vdpu` shared = VP8/MPEG-2/ MPEG-4/H.263 ·
  `66 ff780000.rkvenc` = encoders.

### Input

| Node                    | Device         | Note                                                    |
| ----------------------- | -------------- | ------------------------------------------------------- |
| `ir-remote`             | event9         | pwm remotectl, IRQ 27 `rk_pwm_irq`                      |
| `adc-keys`              | event8         | reset candidate; the button beside HDMI is inert (user) |
| `cec-remote`            | event1         |                                                         |
| `bt-powerkey`           | event3         |                                                         |
| `hdmi`, `hdmi-sound`    | event0, event2 |                                                         |
| USB digital-X 0513:0318 | event6,7,12,13 | keyboard/mouse/consumer/system; renumbers on replug     |
| BT remote 2B54:1600     | event4,5,10,11 | consumer/mouse/keyboard/vendor; renumbers on reconnect  |
| CEC adapter             | `/dev/cec0`    | `dwhdmi-rockchip` / `dw_hdmi`                           |

### IR keymap — decoded, in the device tree, evdev-verified

`ir_key1` (usercode `fb05`) and `ir_key4` (usercode `fb04`) are byte-identical and between them
cover every button; both carry the table below since 2026-09-29 (`board.patch`). Decoded with
anchored `evtest` rounds — one button per burst, settings gear pressed last as an anchor that
confirms the order held — then inverted through the table and re-verified after deploy (OK →
`KEY_ENTER`, home → `KEY_HOME`, source → `KEY_VIDEO_NEXT`; the {`d2`,`60`} pair was the one
ambiguity and the first guess was right).

| Button      | pair (scancode → keycode) | evdev key             | Kodi 21 default     |
| ----------- | ------------------------- | --------------------- | ------------------- |
| power       | `f7` → `74`               | `KEY_POWER`           | logind              |
| OK          | `bb` → `1c`               | `KEY_ENTER`           | **Select** ✅       |
| back        | `e5` → `0e`               | `KEY_BACKSPACE`       | **Back** ✅         |
| home        | `d2` → `66`               | `KEY_HOME`            | FirstPage           |
| X           | `e4` → `6f`               | `KEY_DELETE`          | Delete (file views) |
| dpad up     | `ba` → `67`               | `KEY_UP`              | **Up** ✅           |
| dpad down   | `b9` → `6c`               | `KEY_DOWN`            | **Down** ✅         |
| dpad left   | `b8` → `69`               | `KEY_LEFT`            | **Left** ✅         |
| dpad right  | `b7` → `6a`               | `KEY_RIGHT`           | **Right** ✅        |
| vol +       | `fd` → `73`               | `KEY_VOLUMEUP`        | volume              |
| vol −       | `fc` → `72`               | `KEY_VOLUMEDOWN`      | volume              |
| mute        | `f6` → `71`               | `KEY_MUTE`            | volume              |
| P +         | `ff` → `192`              | `KEY_CHANNELUP`       | — unbound           |
| P −         | `fe` → `193`              | `KEY_CHANNELDOWN`     | — unbound           |
| settings    | `4d` → `8d`               | `KEY_SETUP`           | — unbound           |
| source      | `60` → `f1`               | `KEY_VIDEO_NEXT`      | — unbound           |
| mouse       | `d0` → `212`              | `KEY_TOUCHPAD_TOGGLE` | — unbound           |
| voice       | `5b` → `d9`               | `KEY_SEARCH`          | — unbound           |
| LIVE TV     | `4a` → `179`              | `KEY_TV`              | — unbound           |
| apps        | `49` → `244`              | `KEY_APPSELECT`       | — unbound           |
| YouTube     | `04` → `94`               | `KEY_PROG1`           | — unbound           |
| Netflix     | `14` → `95`               | `KEY_PROG2`           | — unbound           |
| Prime Video | `4c` → `ca`               | `KEY_PROG3`           | — unbound           |
| Google Play | `4b` → `cb`               | `KEY_PROG4`           | — unbound           |

Icon-sane keycodes everywhere, no two buttons share one. One stock pair (`b5` → `8b` `KEY_MENU`)
never fired in any round and is kept untouched. "Unbound" keys emit correctly (evdev-proven) but
have no default Kodi action — a Kodi keymap can claim them later. Confirmed in Kodi on the Toshiba
the same day: OK selects, the remote drives the UI end-to-end.

### BLE keymap — decoded over the air, hwdb-corrected, evdev-verified

Paired 2026-09-29, `2B54:1600` `18:24:39:34:F7:95`; pairing mode = hold ◀+▶ until the LED blinks.
Anchored rounds on the Consumer Control node (logs `stock/mortal-t1/bt-r*.log`).

| Button      | usage   | BLE keycode       | IR keycode            |
| ----------- | ------- | ----------------- | --------------------- |
| power       | `c0030` | `KEY_POWER`       | `KEY_POWER`           |
| OK          | `c0041` | `KEY_SELECT`      | `KEY_ENTER`           |
| back        | `c0224` | `KEY_BACK`        | `KEY_BACKSPACE`       |
| home        | `c0223` | `KEY_HOMEPAGE`    | `KEY_HOME`            |
| X           | `c0040` | `KEY_DELETE`      | `KEY_DELETE`          |
| dpad up     | `c0042` | `KEY_UP`          | `KEY_UP`              |
| dpad down   | `c0043` | `KEY_DOWN`        | `KEY_DOWN`            |
| dpad left   | `c0044` | `KEY_LEFT`        | `KEY_LEFT`            |
| dpad right  | `c0045` | `KEY_RIGHT`       | `KEY_RIGHT`           |
| vol +       | `c00e9` | `KEY_VOLUMEUP`    | `KEY_VOLUMEUP`        |
| vol −       | `c00ea` | `KEY_VOLUMEDOWN`  | `KEY_VOLUMEDOWN`      |
| mute        | `c00e2` | `KEY_MUTE`        | `KEY_MUTE`            |
| P +         | `c009c` | `KEY_CHANNELUP`   | `KEY_CHANNELUP`       |
| P −         | `c009d` | `KEY_CHANNELDOWN` | `KEY_CHANNELDOWN`     |
| settings    | `c008f` | `KEY_SETUP`       | `KEY_SETUP`           |
| source      | `c0029` | `KEY_VIDEO_NEXT`  | `KEY_VIDEO_NEXT`      |
| mouse       | —       | no event          | `KEY_TOUCHPAD_TOGGLE` |
| voice       | `c0221` | `KEY_SEARCH`      | `KEY_SEARCH`          |
| LIVE TV     | `c003f` | `KEY_TV`          | `KEY_TV`              |
| apps        | `c003a` | `KEY_APPSELECT`   | `KEY_APPSELECT`       |
| YouTube     | `c0056` | `KEY_PROG1`       | `KEY_PROG1`           |
| Netflix     | `c003b` | `KEY_PROG2`       | `KEY_PROG2`           |
| Prime Video | `c003d` | `KEY_PROG3`       | `KEY_PROG3`           |
| Google Play | `c003e` | `KEY_PROG4`       | `KEY_PROG4`           |

Nine scancodes — `c0029`, `c003a`, `c003b`, `c003d`, `c003e`, `c003f`, `c0040`, `c0056`, `c008f` —
were `KEY_UNKNOWN`/`KEY_GAMES`/`KEY_MENU` from the raw usages and are remapped by
`firmware/mortal-t1/bt-remote.hwdb`, deployed to `/etc/udev/hwdb.d/60-rk35xx-bt-remote.hwdb`; all
nine were re-read off the handset. Mouse button emits no event over BLE — pointer `REL_*` flows
regardless; `hwdb` cannot fix silence. Voice sends one usage per press; `arecord -l` is empty —
audio rides the `0xfeb3` vendor GATT service and needs a userspace client (out of scope).

Long press per transport: a hold is one down/up pair over BLE (no repeats, same scancode) and one
instantaneous frame over IR (hold duration invisible). Power is the only gesture that diverges — tap
= suspend both ways; ~3 s hold = `Power key pressed long` → reboot over BLE, but over IR the press
reaches logind as instant → short → suspend.

## Validation — `docs/board-validation.md`, run 2

### System

| Check                                              | Mark | Note                                                             |
| -------------------------------------------------- | :--: | ---------------------------------------------------------------- |
| `systemd-analyze` + blame, no absent-hardware wait |  ✅  | no network wait; top `rk35xx-bt` 6.2 s                           |
| Second-boot time                                   |  ✅  | 20.650 s                                                         |
| `dmesg` line by line, repeats accounted            |  ✅  | tolerated lines below                                            |
| hostname / board name                              |  ✅  | `mortal-t1`; `BOARD_NAME=rock-2f` (base), `board-id` `mortal-t1` |
| `dkms status` installed + in `lsmod`               |  ✅  | both modules; v4l2loopback now loaded every boot                 |
| Ten warm reboots, every device                     |  ✅  | 11/11 above                                                      |
| `free` + `stress-ng --vm --verify`                 |  ✅  | 1536 MiB; 4/0                                                    |
| Watchdog device, taken, `wdctl` busy               |  ✅  |                                                                  |
| Granted timeout = largest clock step               |  ✅  | 89.5 s = TOP 15                                                  |
| board.md, worklog, README                          |  ✅  | this pass                                                        |

### CPU, thermal, power

| Check                                         | Mark | Note                                                                 |
| --------------------------------------------- | :--: | -------------------------------------------------------------------- |
| `scaling_available_frequencies` = factory OPP |  ✅  | dtc diff empty                                                       |
| 5 min 4-core stress, no throttling            |  ✅  | 48.3 → 58.3 °C                                                       |
| Draw metered                                  |  ❓  | no meter available                                                   |
| Suspend `deep` + `mem_sleep` bracket          |  ✅  | `s2idle [deep]`                                                      |
| Suspend/resume, stays up                      |  ✅  | IR power both ways, `boot_id` unchanged                              |
| Suspend > watchdog window, same `boot_id`     |  ✅  | 159 s vs 89.5 s window, `boot_id` unchanged (worklog §18)            |
| BLE wake (`hdev->wakeup`)                     |  ❌  | impossible: link drops in sleep, UART never fires; IR only (§18)     |
| Cold-boot time                                |  ✅  | 29.711 s (11.242 kernel + 18.469 userspace); power-on leg unmeasured |
| RTC present, or absence recorded              |  ✅  | absence                                                              |

### Storage

| Check                                             | Mark | Note                                        |
| ------------------------------------------------- | :--: | ------------------------------------------- |
| eMMC fio, fixed parameters                        |  ✅  | table above                                 |
| SD enumerates + fio                               |  ✅  | hotplug insert/remove = physical            |
| Boots eMMC on its own loaders                     |  ❓  | migration = physical                        |
| Migration keeps 7168–16383 identical              |  ❓  | physical                                    |
| `DVKR`/`SSKR` tagged + vendor `LAN_MAC` = sticker |  ✅  | both read back; `00:1c:79:a1:71:92`         |
| Maskrom full-disk read (backup)                   |  ✅  | stock image exists (read path proven)       |
| Maskrom entry at power-on                         |  ❓  | physical — the backup may predate this repo |
| Maskrom `wl` write path                           |  ❓  | physical (pattern write + restore)          |
| `rl` = `factory_idbloader`                        |  ✅  | sector 64 md5 `6a2f0b52…` = identity        |
| Full-disk write (the restore claim)               |  ❓  | physical, destructive — then restore        |
| Throughput recorded                               |  ✅  | table above                                 |

### Ethernet — not on this box

| Check                             | Mark | Note                                                                                                                       |
| --------------------------------- | :--: | -------------------------------------------------------------------------------------------------------------------------- |
| Link, PHY driver, throughput, MAC |  ➖  | no ethernet on this PCB (no RJ45); `gmac` NOT FITTED — wireless-first by design, online LAN specs copied from other boards |
| Wake-on-LAN                       |  ➖  | `phy-is-integrated`, and nothing fitted there to wake                                                                      |

### Wi-Fi

| Check                                | Mark | Note                                              |
| ------------------------------------ | :--: | ------------------------------------------------- |
| Associates 2.4 + 5 GHz               |  ✅  | 2457 today; 5180 every prior test                 |
| Throughput idle + load, regdom named |  ✅  | Network above                                     |
| No latch after load                  |  ✅  | post-load PHY 103.2 HE-MCS8; 5 GHz A/B protocol   |
| MAC stable across reboots            |  ✅  | 11/11                                             |
| Own address, not blob, not shared    |  ✅  | derived (no eFUSE to read), absent from aic blobs |
| Firmware named for its scope         |  ✅  | generic `aic8800{,_fw}`, no board suffix          |
| Scan finds networks with no reg code |  ✅  | 30 found                                          |
| `iw reg set` returns, box answers    |  ✅  | rc=0 + answers; global stays `98` (self-managed)  |

### Bluetooth

| Check                                            | Mark | Note                                     |
| ------------------------------------------------ | :--: | ---------------------------------------- |
| `hci0` up, `errors:0`                            |  ✅  |                                          |
| `btmgmt find` returns devices                    |  ✅  | LE devices found                         |
| BD identical across three reboots, from the part |  ✅  | `0B:3B:22:AC:88:20` ×3 (and ×3 in run 1) |
| Samsung keyboard pairs, HID types                |  ✅  | `v04E8:7021` (worklog §13)               |
| Re-binds after suspend/resume                    |  ✅  | `input17`, typed by eye (worklog §14)    |
| Re-binds after cold power-off                    |  ✅  | unplug → getty, typed (worklog §15)      |
| Bundled remote pairs                             |  ✅  | `2B54:1600` (worklog §17)                |
| A2DP                                             |  ❓  | untested, no speaker                     |

### Display

| Check                        | Mark | Note                                                     |
| ---------------------------- | :--: | -------------------------------------------------------- |
| GPU renders, fps recorded    |  ✅  | 157/163/168 Mpix/s                                       |
| `cec-ctl` finds the adapter  |  ✅  | `/dev/cec0`                                              |
| EDID parses, hotplug re-read |  ✅  | Sharp, Prism+, Toshiba; replug re-reads                  |
| 1080p drives the panel       |  ✅  | Sharp, Toshiba                                           |
| 4K60 drives the panel        |  ✅  | Prism+: `Update mode to 3840x2160p60`                    |
| 1440p/2K class               |  ❓  | no panel advertising it here yet                         |
| PC monitor                   |  ❓  | physical                                                 |
| HDMI audio + default sink    |  ✅  | card 0 `rockchiphdmi` only; heard in Kodi on the Toshiba |
| CEC traffic                  |  ❌  | no ACK (Sharp, Prism+); `Tx, Not Acknowledged (4)`       |
| kmscube on screen            |  ✅  | 50.002 fps                                               |
| Kodi 21.2 GBM on screen      |  ✅  | DRM master, `GL_RENDERER = Mali450`                      |
| Kodi hwdec                   |  ❌  | vaapi/mediacodec only; libva `-1`                        |
| AV jack                      |  ➖  | not fitted                                               |

Kodi: `kodi --standalone` as root; no autostart, no unit. No hwdec exists on this box — Debian's
build carries no rkmpp/v4l2 backend, so every player decodes in software.

### Video codec

| Check               | Mark | Note                              |
| ------------------- | :--: | --------------------------------- |
| MPP names the SoC   |  ✅  | `rk3528a`                         |
| Matrix filled, fps  |  ✅  | tables above                      |
| AV1 absent          |  ✅  | refusal recorded                  |
| AVS · AVS+          |  🟡  | create accepted, no clip          |
| Real 4K HEVC smooth |  ✅  | mpv 90 s @4K60, 1 drop; SW decode |

### USB

| Check                      | Mark | Note                                          |
| -------------------------- | :--: | --------------------------------------------- |
| `lsusb -t` before bench    |  ✅  | xhci 480M + 5000M, ehci 480M, ohci 12M        |
| USB 2 enumerates at 480M   |  ✅  | dongle, reader, SSD, SanDisk                  |
| USB 2 throughput, fio read |  ✅  | SanDisk seq 16.0, rand 4K 2.2 MB/s            |
| Reader path write / read   |  ✅  | 5.4 / 5.5–5.6 MB/s — card-limited             |
| Card-via-reader integrity  |  ✅  | 512 M PASS; run-1 points at slot/host path    |
| USB 3 BOS `SuperSpeed`     |  ✅  | SanDisk: FS + HS + SS 5 Gbps, in socket       |
| USB 3 negotiates 5000M     |  ✅  | JMicron straight in socket; SanDisk fell back |
| `uas` bound, not BOT       |  ✅  | JMicron `152d:a583`, protocol 62              |
| USB 3 throughput, fio read |  ✅  | seq 343, rand 4K 44.1 MB/s @5000M             |
| Hotplug each device        |  ✅  | SSD / reader / SanDisk / JMicron; renumbers   |
| Every port exercised       |  ✅  | one USB-A 3.0 (port list); all devices in it  |

### IR, buttons, LEDs, keymap

| Check                     | Mark | Note                                                                    |
| ------------------------- | :--: | ----------------------------------------------------------------------- |
| Input nodes exist         |  ✅  | Input table                                                             |
| IR IRQ counts on press    |  ✅  | IRQ 27, pass 1: 63368 → 76561                                           |
| Button beside HDMI        |  ❌  | inert: 1×, 2× @1–2 s, 3rd held 10 s — never maskrom, never powers off   |
| Power-on remote cold-boot |  ➖  | self-boots on wall power; IR dead unplugged, no button (user-confirmed) |
| Long press in each mode   |  ✅  | gesture differs per transport (worklog §17)                             |
| LED polarity by eye       |  ✅  | suspend: red, running: blue; poweroff: red → dark                       |
| IR keymap, per transport  |  ✅  | IR: table above, evdev-verified                                         |
| BLE keymap, per transport |  ✅  | BLE: table above, hwdb-verified (worklog §17)                           |
| IR-extender jack          |  ➖  | none on the port list                                                   |

### Device tree

| Check                               | Mark | Note                                                                                                             |
| ----------------------------------- | :--: | ---------------------------------------------------------------------------------------------------------------- |
| No node claims absent hardware      |  ✅  | `gmac0` + `rmii0_phy` carry the `NOT FITTED` hunk; live DT `status = "disabled"`, zero gmac/phy lines in `dmesg` |
| Ghosts disabled, `NOT FITTED` hunks |  ✅  | `board.patch` hunk for `gmac0` (no RJ45 on this PCB); rebuilt + deployed 2026-09-29                              |
| Every hunk carries its rationale    |  ✅  | all commented                                                                                                    |
| `upstream/build.sh` VERIFIED        |  ➖  | no `upstream/mortal-t1/`                                                                                         |
| Untouched nodes re-checked          |  ✅  | `build-board-dts.sh mortal-t1` regen byte-identical; eMMC enumerates 11/11                                       |

### Overlay mode

| Check                              | Mark | Note                                                                 |
| ---------------------------------- | :--: | -------------------------------------------------------------------- |
| Installed files root:root          |  ✅  | uid/gid 1000 outside `/home`: empty                                  |
| Identity dir populated             |  ✅  | `mortal-t1` / `MORTAL T1 XR8223518K-V1.0`, `board.dtb`, both loaders |
| No foreign board names             |  ✅  | r69 / h313 / 3518d globs empty                                       |
| Loaders on disk = identity         |  ✅  | sector 64 `6a2f0b52…`, sector 16384 `227ea087…`                      |
| Survives `apt full-upgrade`        |  ❓  | dropped by decision — no upgrade this run                            |
| Both update paths                  |  ✅  | deploy full pass; `--pull` fixed + retested                          |
| DKMS rmmod + modprobe back         |  ✅  | both return; `ir-remote`/`video0` recreated                          |
| Payload udev `SYMLINK` fires       |  ✅  | `ir-target=event9` every boot                                        |
| dtb-persist across a kernel update |  ❓  | hook present + current match; update leg needs an upgrade            |

### Tolerated dmesg lines

| Line                                                                 | Per boot | Why                                            |
| -------------------------------------------------------------------- | :------: | ---------------------------------------------- |
| `Cannot find any crtc or sizes`                                      |    2     | before the first mode is set                   |
| `Looking up …-supply failed` / `could not add device link … -ENOENT` |   many   | optional supplies absent in the stock tree     |
| `optee … -22`, `scmi protocol 17/22 not active`, `DMI not present`   |  1 each  | not fitted / unused                            |
| `rkvdec2 clk_get … failed`, `rkvenc devfreq`, `vop2 opp info`        |  1 each  | optional clks/devfreq; codecs measured working |
| `[BT_RFKILL] clk_get failed`, `usb2phy IRQ index 0 not found`        |  1 each  | optional; BT and USB work                      |
| `bpf-restrict-fs: Failed to link`                                    |    1     | BPF LSM not in this kernel                     |
| `vop2 … primary plane phy id: INVALID[-1]`                           |   bind   | planes attach later; display works             |

Nothing else repeats at any level; systemd's per-target "skipped" notices repeat by design.

### Open

- Console garble (❓): tty1 substitutes CP437-ish glyphs, tty2 clean; probe recipe `worklog.md` §7.
- `h96max-3518d/board.md` "AVS2 357 fps" has no worklog provenance — flagged, not inherited here.
- `board.patch` ships `mode-maskrom` (`reboot maskrom` to BootROM, no button) — untested; it would
  strand the box until a physical power cycle.

### Needs the human — one trip

- TV input leftovers: a 1440p/2K panel, a PC monitor, a CEC menu check on a set that exposes one.
- Maskrom: the button beside HDMI is inert (no maskrom, no power-off in any pattern) — the only
  entry left is `reboot maskrom` (DT hunk, untested): flash USB on a host first, power cycle to
  recover; optional `wl` pattern test.
- eMMC migration + full-disk write + restore (`dd` of the stock image); the device name it confirms.
- SD insert/remove deferred: the only slot holds the boot card.
