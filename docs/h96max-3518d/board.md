# H96 Max 3518D — board details

A stick-form RK3518 box. Sibling to `docs/h96max/`, which is the same SoC and the same radio on a
different PCB (`3518_ZX_V01` there, `3518_DG_ZX_V01` here).

**Runs Armbian since 2026-09-06**, reachable over SSH. Every number below was measured on this unit
**with the heatsink fitted**. Known gaps are listed below; `docs/todo/` holds the open questions.

## Identity — check yours matches before flashing

|               |                                                                                                                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Name          | **H96 Max 3518D** (label), stock `ro.product.model=H96_Max_3518_TS`, Android 14                                                                                                                   |
| SoC           | **RK3518** — OTP reads literal `RK3518`, BL31 prints `RK3518 SoC`, `ro.board.platform=rk3528`                                                                                                     |
| CPU           | 4× Cortex-A53 (`0xd03`), max **1416 MHz** (only 1200/1416 offered)                                                                                                                                |
| RAM           | **LPDDR3 2 GB** @ 666 MHz final, `ddrconfig:7`, 4-bit PCB · `MemTotal 2045284 kB`                                                                                                                 |
| Storage       | **Micron `R1J96N` 16 GB eMMC 5.1** — 15,758,000,128 B · **no SD slot**                                                                                                                            |
| Serial number | `SN26072800001` · vendor-storage `LAN_MAC 00:ef:01:1a:be:a0`                                                                                                                                      |
| Wi-Fi / BT    | **Seekwave SWT6621S** — SDIO Wi-Fi + BT over the same chip                                                                                                                                        |
| Ports         | **Two USB 2.0 ports, no USB 3**: USB-A (host) and USB-C (**OTG — the maskrom/Loader port**, and the intended power input, though USB-A powers it too) · HDMI · **no Ethernet, no SD, no AV jack** |
| Remote        | The same 22-button dual-mode BT/IR unit the R69 and H96 Max ship with, no digit keys — but **no IR receiver is fitted here**, so BLE pairing is mandatory                                         |
| Serial header | 3 tiny round **test points, not a header** — no holes — beside the board-name silkscreen · **TX · GND · RX**, TX nearest the HDMI side · 1500000 baud                                             |
| PCB marking   | `3518_DG_ZX_V01` over `20250401` — match the **first** line; the second is a date code                                                                                                            |

## Test report

Everything actually exercised on this unit. ✅ verified here · 🟡 likely · ❓ never tested · ❌
tested and broken · ➖ not on this board. Nothing is inherited from the sibling.

| Area                       | State | What was done, and what it gave                                                  |
| -------------------------- | :---: | -------------------------------------------------------------------------------- |
| **Storage**                |       |                                                                                  |
| eMMC boot + rootfs         |  ✅   | `/dev/mmcblk1`, 30777344 sectors, ext4 on p1; boots and runs                     |
| eMMC throughput            |  ✅   | numbers above; at the HS 50 MHz ceiling, see caps                                |
| microSD                    |  ➖   | no slot; `sdmmc` disabled in the tree                                            |
| USB mass storage           |  ✅   | Lexar stick on USB-C, 35.1 MB/s — the 480 Mbps ceiling                           |
| **Network**                |       |                                                                                  |
| Ethernet, onboard          |  ➖   | no PHY fitted; `gmac0` disabled                                                  |
| Ethernet, USB adapter      |  ✅   | RTL8153 (`r8152`) — works, but **USB 2.0 speed only** and see the power section  |
| Wi-Fi 5 GHz                |  ✅   | numbers above; no sag under load, no latch                                       |
| Wi-Fi 2.4 GHz              |  ✅   | numbers above; the box roams to it on its own                                    |
| Bluetooth                  |  ✅   | `hci0`, BT 5.4 over SDIO, LE scan finds 10+ devices                              |
| **Input**                  |       |                                                                                  |
| Remote over BLE, keys      |  ✅   | `/dev/input/bt-remote` — must be **trusted**, see quirks                         |
| Remote over BLE, air-mouse |  ✅   | paired and working — `/dev/input/bt-remote-mouse`                                |
| Remote over IR             |  ➖   | **no receiver fitted** — see below                                               |
| Recovery button            |  ✅   | `adc-keys`, reports `KEY_F11` (`0x57`) despite its `vol-up-key` label            |
| **Display and video**      |       |                                                                                  |
| HDMI picture, 1080p        |  ✅   | correct full-screen console on a 4K LG TV at 1920x1080p60                        |
| HDMI EDID and mode list    |  ✅   | 256 B read, LG TV, 40 modes incl. 3840x2160, 4096x2160, 2560x1440                |
| HDMI audio                 |  ✅   | music played through `plughw:0,0`, 48 kHz S16_LE stereo — heard on the TV        |
| HDMI-CEC                   |  ✅   | phys addr 3.0.0.0 from EDID, claimed LA 8 (Playback 2), transmitted to the TV    |
| HDMI 4K60                  |  ✅   | native `3840x2160p60` full-screen — needs the `esmart_lb_mode` graft, see dtb.md |
| HDMI hotplug               |  ✅   | unplug/replug re-detects, same mode restored, no blank screen                    |
| Video playback to screen   |  ✅   | 1080p H.264 and 4K HEVC on screen, hardware decode — rates in the numbers table  |
| GPU                        |  ✅   | Mali-450 under `lima`, GLES 2.0 — `kmscube` and glmark2 both render at 4K        |
| VPU decode / encode        |  ✅   | MPP gate passes (`rk3528a`); the whole matrix bar AVS — numbers above            |
| AV / composite / SPDIF     |  ➖   | no jacks, no connector                                                           |
| **Power and recovery**     |       |                                                                                  |
| Power in, either socket    |  ✅   | the included USB-C↔USB-A cable powers it both ways round                         |
| USB hot-plug               |  ❌   | **browns the box out and resets it** — see the power section                     |
| Hardware watchdog          |  ✅   | `RuntimeWatchdogUSec=1min 20s`, `/dev/watchdog` present                          |
| Serial console             |  ✅   | `ttyFIQ0` at 1500000, root shell                                                 |
| Maskrom over USB           |  ✅   | button via the tiny USB-C hole → `Maskrom` on **our** U-Boot; `db` ok            |
| `wl` write over maskrom    |  ✅   | 64 MiB written, read back identical, original restored and re-verified           |
| Sleep/wake from remote     |  ❌   | fixes exist and are measured, but a later suspend can hang — see below           |
| CPU + thermal              |  ✅   | 5 min 4-core, no throttling, 27 °C below the first trip point                    |
| Memory                     |  ✅   | `stress-ng --vm --verify` clean                                                  |
| MAC / `BD_ADDR`            |  ✅   | both stable across reboot; `LAN_MAC` matches the sticker                         |
| Loaders on disk            |  ✅   | sectors 64 and 16384 md5-match the identity dir                                  |
| File ownership             |  ✅   | `root:root` throughout; no build-host uid left                                   |
| `apt full-upgrade`         |  ✅   | 76 pkgs incl. a kernel — name, hold, dtb-persist and DKMS all survived           |
| LEDs                       |  ✅   | green and red both confirmed by eye; dark while suspended, see suspend section   |

## Measured numbers — 2026-09-06, **heatsink fitted**, antenna fitted

`fio` uses the repo-standard parameters (1 MiB `iodepth=8` sequential, 4 KiB `iodepth=32` random,
`--direct=1`), so these compare against the other boards.

| What                     | Value                                                                      |
| ------------------------ | -------------------------------------------------------------------------- |
| Boot                     | **13.6 s** — 4.2 s kernel + 9.4 s userspace, second boot                   |
| eMMC sequential          | **44.0 MB/s** read · **38.8 MB/s** write                                   |
| eMMC random 4k           | **2917 IOPS** read (11.4 MB/s) · **3863 IOPS** write (15.1 MB/s)           |
| USB 2 stick, seq read    | **35.1 MB/s** — at the 480 Mbps ceiling                                    |
| Wi-Fi 5 GHz throughput   | **185** Mbit/s idle · **191** under 4-core load · **206** after            |
| Wi-Fi 5 GHz link         | 80 MHz HE, −29 dBm, PHY **600.4 / 600.4** Mbit/s                           |
| Wi-Fi 2.4 GHz throughput | **68–72** Mbit/s, PHY 129.0 / 143.3, −28 dBm                               |
| Bluetooth                | BT 5.4 (HCI/LMP `0xd`), SDIO, `UP RUNNING`                                 |
| SoC temperature          | **50 °C** idle · **66–68 °C** at 5 min 4-core, no throttling               |
| Thermal headroom         | first trip point is **95 °C** — 27 °C clear at full load                   |
| CPU throughput           | `stress-ng` 69,481 bogo-ops, 231.4/s                                       |
| Memory                   | `stress-ng --vm --verify` clean; 1967 MB total, 983 MB swap                |
| Rootfs                   | 14.9 GB on `/dev/mmcblk1p1`                                                |
| Codec encode             | 720p/1080p/4K/**8K** — H.264 114/54.5/14.4/3.6, HEVC 124/60/15.8/4.0 fps   |
| Codec decode             | VP9 **707/364** · VP8 **183/88** · AVS2 **357** fps · MPEG-2/4, H.263 ✅   |
| GPU fill, offscreen      | **565 Mpix/s** — 598 fps @720p, 272 @1080p, 70 @4K (full-screen fill)      |
| GPU, glmark2 on screen   | **~20** at 3840x2160 (23 scenes, 3-57 fps) — Mali-450, rendered on a 4K TV |
| Video decode, 1080p H264 | **157 fps** hardware (14 fps software) — `h264_rkmpp`                      |
| Video decode, 4K HEVC    | **51 fps** hardware; **70 fps** via `mpi_dec_test`                         |
| 4K HEVC on screen        | **27 fps** at 48% CPU — the `fbdev` blit, not decode, is the limit         |
| Power, idle              | **<0.5 W** bare board (5 V, 0-0.1 A) · **0.5-1.5 W** with HDMI attached    |

**The glmark2 score is not comparable across boards.** ~20 here is at **3840x2160**; the R69's 41 is
at 2048x1152 and the H96 Max's 41 at 1080p — 4K is four times the pixels of 1080p, and this GPU is
fill-rate bound (565 Mpix/s measured, near-identical at every resolution). Same silicon, different
workload. Compare the offscreen Mpix/s figure instead.

**No latch on either band** — no sag under 4-core load, immediate recovery after. The sibling's 6
Mbit/s TX latch (`docs/h96max/wifi-tx-latch.md`) does not reproduce; retest after a driver bump.

**It roams bands** — check `iw dev wlan0 link` before trusting a throughput figure.

**MAC and `BD_ADDR` are stable across reboots** — `wlan0 fe:fd:fc:d8:87:b9`,
`BD_ADDR FE:FD:FC:C4:F3:28`, both derived (vendor storage holds `lan` and `sn` only). Vendor storage
`LAN_MAC 00:ef:01:1a:be:a0` matches the sticker.

## Caps and limits — the things that bound performance

**eMMC is capped at HS 50 MHz by the factory tree, and the measurement matches.** `DEVICE_TYPE 0x57`
advertises HS400 and HS200, but `sdhci` carries `max-frequency = <50000000>` and no
`mmc-hs200-1_8v`/`mmc-hs400-1_8v`, so Linux negotiates plain HS 8-bit. 50 MHz × 8 bit ≈ 50 MB/s
theoretical, and 43.3 MB/s read is right at it — this is the ceiling, not a driver problem. Vendor
U-Boot uses HS400 200 MHz for its own reads, so the silicon can do more. Raising it is a post
bring-up tuning question, and the R69's HS400 corruption is the reason to be careful.

**No USB 3 — both ports are USB 2.0.** Two independent lines of evidence: a SuperSpeed device
plugged **straight into the USB-C socket** — no cable, no adapter in the path — still trained at
480M, and the vendor's own documentation does not claim USB 3, which it would if the board had it.
The SuperSpeed pairs are not routed to the connector.

**The tree does not say so, deliberately.** Grafting it out (`maximum-speed = "high-speed"`, no
`usb3-phy`, `combphy@ffdc0000` `disabled`) was tried and **reverted on 2026-09-06 because it broke
suspend**: the 5 Gbps root hub survives the graft — `xhci` advertises SuperSpeed from its own
capability register, which no device-tree property retracts — so removing the phy leaves that half
present but unclocked, and it never halts. `platform_pm_suspend` then times out with **-110** and
aborts every suspend. The graft bought about a second of boot time; it cost suspend on the only
board with no other way to be woken. `docs/h96max-3518d/dtb.md` has the detail.

**The GPU is GLES 2.0 only, and everything about it stops at 4096 px.** `lima` drives `arm,mali-450`
and reports `GL_MAX_TEXTURE_SIZE`, `GL_MAX_RENDERBUFFER_SIZE` and `GL_MAX_VIEWPORT_DIMS` all at
**4096**. 4K (3840×2160) fits with nothing to spare; **8K does not**, so the 8K the VPU decodes can
be written to a file but not textured, scaled or composited by the GPU. There is no GLES 3 path — a
player that requires one will not run.

**Only 1200 and 1416 MHz are offered** by cpufreq, and `ondemand` sits at 1416 MHz. There is no
higher OPP to unlock.

**Wi-Fi and Bluetooth share one antenna and coexist by TDD** — the radio firmware is the vendor's
`_SHARE` variant. ❓ The cost is unmeasured: quote a Wi-Fi number here only with the Bluetooth state
stated alongside it.

## Power — the regulation is weak, and a hot-plug browns the box out ❌

**One 5 V rail, and either socket can feed it.** There is no barrel jack: `vcc5v0_host` and
`vcc5v0_otg` both derive from `vcc5v0_sys`, so the SoC and both USB ports share one rail with no
headroom. But the supply need not arrive on USB-C — ✅ the **included USB-C ↔ USB-A cable powers the
stick either way round**: USB-A charger into the USB-C socket, or USB-C charger into the USB-A one.

**USB-C is the intended power input, but USB-A works just as well** — and feeding through USB-A is
the better arrangement, because USB-C is **the only OTG port, the one `Maskrom` and `Loader` come up
on** (`Vid=0x2207,Pid=0x350c`). Spending it on power wastes the only socket that can do that.

The rail's margin is thin enough that a peripheral's inrush drops the SoC. **Plugging a USB Ethernet
adapter (RTL8153) into the USB-A port resets the box, repeatably.**

It is a power fault, not a driver fault, and the evidence separates the two:

| Observation                                               | Rules out                         |
| --------------------------------------------------------- | --------------------------------- |
| `pstore` empty; no panic, oops or watchdog bite           | a crash — nothing got to log      |
| the boot before the reset lasted ~1 s                     | a shutdown path                   |
| the same adapter runs **indefinitely** if present at boot | the driver and the adapter itself |

**Workaround:** plug peripherals in before applying power, or feed the box from a supply that can
carry the inrush. Nothing in software fixes it.

🟡 Two things remain unisolated: whether powering through USB-A cures it (it removes the common case
by occupying that socket, but the rail is shared either way), and whether a bare hot-plug differs
from one behind a hub — the "runs indefinitely" observation was made through a Fresco Logic hub.

## IR — no receiver is fitted ➖

Settled 2026-09-06. `evtest` on `/dev/input/ir-remote` saw nothing on any keypress, and **the same
remote drives the H313 over IR** — a known-good receiver rules the transmitter out, so the missing
half is this board. (A silent `evtest` alone would not prove it: it also looks like a receiver whose
usercode matches none of the nine `ir_keyN` tables. The worklog has the full reasoning.)

**The remote still works here, over BLE.** Paired, it is two HID devices (`2B54:1600`), both
symlinked by `60-rk35xx-input-names.rules`:

| Device                      | Symlink                      | Half          | State |
| --------------------------- | ---------------------------- | ------------- | :---: |
| `Bluetooth remote Keyboard` | `/dev/input/bt-remote`       | the keys      |  ✅   |
| `Bluetooth remote Mouse`    | `/dev/input/bt-remote-mouse` | the air-mouse |  ✅   |

What is lost is narrower than "no remote": nothing works **until** it is paired. ✅ Remote wake from
suspend does work, over BLE — see the suspend section. `/dev/input/ir-remote` never appears: the
rule matches `*.pwm`.

**The remote still transmits IR, and on this board that only ever reaches other equipment.** It is
dual-mode: while BLE-connected it stays quiet, but once the link drops it falls back to IR, so the
**first press after a disconnect does both** — it fires IR _and_ triggers the BLE reconnect. With no
receiver fitted here, the box cannot see that IR; anything in front of it can. Observed 2026-09-07:
a TV in the room acts on at least **power** and **OK**, so waking the box can also switch the TV
off.

With the BT wake patches parked the BLE link is dropped at suspend as upstream intends, so a
sleep/wake cycle disconnects the remote and the first press afterwards fires IR as well as
reconnecting over BLE.

### BLE remote keymap

Scancodes read with `evtest /dev/input/bt-remote`, 2026-09-07; they are the raw HID usages the
handset sends (`c…` consumer page, `7…` keyboard page). The remote must be paired and trusted first.

| Button                  | Scancode                        | Keycode                                                 |
| ----------------------- | ------------------------------- | ------------------------------------------------------- |
| D-pad                   | `c0042` `c0043` `c0044` `c0045` | `KEY_UP` `KEY_DOWN` `KEY_LEFT` `KEY_RIGHT`              |
| OK (centre)             | `c0041`                         | `KEY_OK` ✅ remapped, was `KEY_SELECT`                  |
| Back                    | `c0224`                         | `KEY_BACK`                                              |
| Home                    | `c0223`                         | `KEY_HOMEPAGE`                                          |
| Voice search            | `c0221`                         | `KEY_SEARCH` — native, not remapped                     |
| ↳ same press also sends | `700aa`                         | nothing ✅ suppressed; was a stray `KEY_UNKNOWN`        |
| Cog                     | `c008f`                         | `KEY_SETUP` ✅ remapped, was `KEY_GAMES`                |
| Mute                    | `c00e2`                         | `KEY_MUTE`                                              |
| Vol +/-                 | `c00e9` / `c00ea`               | `KEY_VOLUMEUP` / `KEY_VOLUMEDOWN`                       |
| P +/-                   | `c009c` / `c009d`               | `KEY_CHANNELUP` / `KEY_CHANNELDOWN`                     |
| Power                   | `c0030`                         | `KEY_POWER` — logind takes it to suspend                |
| Backspace               | `c0040`                         | `KEY_BACKSPACE` ✅ remapped, was `KEY_MENU`             |
| Hamburger               | `c0011`                         | `KEY_MENU` ✅ remapped, was `KEY_UNKNOWN`               |
| App shortcuts, in order | `c0056` `c003b` `c003d` `c003e` | `KEY_PROG1`…`KEY_PROG4` ✅ remapped, were `KEY_UNKNOWN` |
| Mouse button            | ➖                              | not a key — toggles air-mouse mode                      |

Six usages arrive with no kernel mapping: the hamburger, the four app shortcuts, and a second usage
the voice key sends alongside `KEY_SEARCH`. `firmware/h96max-3518d/bt-remote.hwdb` renames those,
plus three the kernel maps to the wrong key — backspace, the cog and the centre button — nine
overrides in all. It keys on the handset model, not the board, so any box this remote is paired to
gets the same map. ✅ verified on the handset 2026-09-07: all nine properties reach the device and
the remapped buttons report the new keycodes. `docs/remote-keymap.md` has the procedure.

The app shortcuts are **YouTube · Netflix · Prime Video · Google Play**, in that order, so
`KEY_PROG1` is YouTube. `KEY_PROG*` is what Linux defines for programmable app keys; the two IR
tables for this same handset name them `KEY_F6 F7 F3 F8` (R69) and `KEY_F6 F7 F8 F9` (H96 Max), and
disagreeing with each other they are not a convention worth copying.

The D-pad sends the consumer _Menu Up/Down/Left/Right_ usages rather than keyboard arrows — it still
arrives as `KEY_UP`…`KEY_RIGHT`, so nothing needs fixing, but bind by keycode rather than by what
the icon implies about the wire format.

**The whole IR path is removed**: `pwm@ffa90030` `disabled`, no `rockchip-pwm-remotectl-rk35xx` DKMS
module, and no `initcall_blacklist=rk_pwm_driver_init` on the kernel command line — with no node to
bind, neither the unpatched built-in driver nor our patched one runs.

## Quirks

Things that surprise you once and then cost you an hour if you forgot them.

- **The bundled remote works — on the _other_ box, without pairing.** This stick's handset drives
  the **H96 Max box** over IR perfectly. The transmitter was never the problem; this board has no IR
  receiver. Here the same handset works fine once paired over BLE, just not before.
- **Bluetooth works under Armbian but never did under the factory Android.** The stock build was
  missing `android.hardware.bluetooth.IBluetoothHci`. Do not use "it did not work on Android" as
  evidence about this hardware.
- **The serial console is `ttyFIQ0`, not `ttyS0`.** `serial@ff9f0000` is `disabled` in the tree and
  the vendor fiq-debugger owns that UART instead — the only board here that does this, and the
  reason `BOARD_SERIALCON` exists.
- **`card0-TV-1` always reads `connected`.** TVE has no detect line, so that status is meaningless;
  there is no AV jack on this board at all.
- **Either USB socket can power the box.** The included USB-C↔USB-A cable works in both directions,
  so 5 V can go into USB-A and leave USB-C — the only OTG port, the one maskrom uses — free.
- **The `-2` Seekwave firmware errors in `dmesg` are normal.** The driver probes a board-specific
  `<file>.<compatible>.nvbin` first, then falls back to the generic `sv6160lite.nvbin`, which loads.
- **The BT address is derived, not burned in.** `FE:FD:FC:C4:F3:28` — vendor storage has `lan` and
  `sn` but no `bt`/`wifi`, so the driver falls back to the `fe:fd:fc` prefix.
- **`iw` lives in `/sbin`**, which is not on a non-login SSH shell's `PATH`. Empty output from `iw`
  over `ssh` means "not found", not "no link".
- **`dkms` is in `/usr/sbin`, same trap.** `dkms status` over `ssh` prints `command not found`,
  which reads like "no modules registered". Use `sudo dkms status`.

## Peripherals — the board, then the tree

**Start from the board.** The factory tree is Rockchip's **EVB1 DDR4 V10** reference, so on this
stick most of the I/O it declares does not exist: treat every `status = "okay"` as the reference
design's claim, not this PCB's.

Physically present (inspection 2026-09-05, and `board.jpg`): USB-C, USB-A, HDMI, the Seekwave chip
and its u.FL antenna, a recovery button reachable through a **tiny hole beside the USB-C socket**,
no disassembly needed, SoC/RAM/eMMC under an aluminium heatsink, two LEDs faintly visible through
the vents. Absent: **no Ethernet, no microSD, no AV/composite, no SPDIF, no analog audio, no IR
receiver.** Unpopulated footprints may exist, so a node matching nothing visible only means this
unit has nothing wired to it.

**Nine blocks the tree claims and this PCB lacks**, all now `disabled` and marked `NOT FITTED` in
`board.patch` — `dtb.md` carries the per-node rationale: `gmac0` (no PHY —
`RK630 PHY stmmac-0:02: phy_poll_reset failed: -110`), `sfc` (no flash — SPL reads
`unrecognized JEDEC id bytes: 00, 00, 00`), `sdmmc` (no slot; the controller binds and claims
`vcc-sd`/`vccio_sd` regardless), `tve` (no AV jack — and `card0-TV-1` always reads `connected`
because TVE has no detect line), `spdif` and `acodec` with their sound cards, `pwm@ffa90030` (no IR
receiver), and the USB 3 phy. Two more are noise rather than nodes: `es7243e` ×3 on i2c6 never
probes — zero mentions in a 660 KB dmesg — and `wifi_chip_type` still names `ap6275s`, a Broadcom
part this box does not have.

## Factory boot chain

| Stage  | What                                                |
| ------ | --------------------------------------------------- |
| DDR    | `56f70fd2ad`, `fwver: v1.11`, LPDDR3 → 666 MHz      |
| SPL    | U-Boot SPL 2017.09-250331-dirty, aarch64            |
| BL31   | v2.3-912, `fwver: v1.20` — prints `RK3518 SoC`      |
| OP-TEE | 3.13.0-891, `fwver: v1.06`, aarch64                 |
| U-Boot | 2017.09-250331-dirty — **AArch32** (`SPSR = 0x1d3`) |
| Kernel | 6.1.118 `#147`, **armv7l**                          |

The 32-bit half is a vendor choice, not silicon: `uboot.itb` replaces U-Boot and the kernel is
Armbian's, so both 32-bit stages go away.

## Serial console

The only view of U-Boot and early boot; under stock Android it is a **root shell**, not just a log.

> **Physically the hardest serial connection of the three boards.** The pads are very small, and the
> difficulty is entirely in _holding_ contact, not in finding them — a probe slides off with any
> movement of the cable or the board. Allow real time for it, work with the box wedged so nothing
> can shift, and solder a short flying lead if it will be on the bench for more than one session.

- **Location**: three **tiny round test points** beside the board-name silkscreen
  (`3518_DG_ZX_V01`). They are bare pads — **no holes, no header** — so there is nothing to insert
  or hook into; contact is surface-only, against a pad barely wider than a probe tip.
- **Pinout**: **TX · GND · RX**, with **TX nearest the HDMI-jack side**. That reference needs no
  assumption about which way up the board is held.
- **1500000 baud**, 3.3 V. A CP2102 cannot do 1.5 Mbaud — use an FT232 or CH340.
- Wire **GND, TX and RX only, crossed** (board TX → adapter RX). Never connect 3V3: the box is
  self-powered and tying rails can backfeed.
- **GND need not come from the pads at all** — the HDMI shell, the mounting holes beside it, or the
  USB shells all work, and all are far easier to hold than a test point. Confirm with a meter, and
  do not assume the heatsink is grounded. That leaves only TX and RX to land on the pads themselves.

Worked first attempt on 2026-09-05 — that refers to the **wiring** being right, no TX/RX swap
needed; it says nothing about how fiddly the contact was.

> **A board photo is still missing**, which `docs/board-bringup.md` asks for and both `docs/r69/`
> and `docs/h96max/` have. The pinout above is unambiguous without one, but nothing else is
> illustrated.

## Recovery — read this before writing anything

**There is no SD slot, so there is no SD rescue.** On every other board a bad DTB is undone by
booting an SD and copying a known-good blob back. Not here: maskrom over USB is the only way back,
and it must be proven working _before_ the first write. Modes, entry, the 32 MiB `Loader` read cap
and the restore commands are all in `docs/maskrom.md`; what is board-specific:

> ✅ **The gate is passed, 2026-09-06.** The recovery button — reachable through the tiny hole
> beside the USB-C socket, no disassembly — gives true `Maskrom` on **our** U-Boot, and `db`, `rl`
> and `wl` all work there. That is entry _and_ restore proven, which is what makes this box safe to
> write to. (`rd 3` from `Loader` is gone, since ours serves no USB; it is not needed.)

- ✅ Answers `rkdeveloptool` on **USB-C**, as `Vid=0x2207,Pid=0x350c`, **bus-powered from the
  host**. Both ends are USB-C here, so it is the two-adapter case: an A male-to-male cable with a
  C-male→A-female adapter at the box and another at the host.
- ✅ **Maskrom works** with an `LDR `-format loader (new IDB, RC4 off) from `boot_merger -r 6 -n`.
- ✅ **eMMC backup taken and verified** — `backup/h96max-3518d/emmc-full.img`, 15,758,000,128 B,
  re-read in full and 100% byte-identical. Three sessions with a replug between, because the box
  overheats in maskrom with no OS to throttle it.
- ✅ `wl` (writing) proven — 64 MiB pattern written, read back identical, original restored.
- ⚠️ **It overheats in maskrom** — no cpufreq, no thermal driver, no OS. **A heatsink does not fix
  it**: a single-pass 15.7 GB read died at 68% / 10 GB _with_ one fitted, averaging 14.2 MB/s and
  ending at 0.02 MB/s. The decay carries across transfers in a session, so a read started right
  after stalls sooner. A full dump takes ~6 minutes against the 50 MHz eMMC cap.

| Route                         | Here                                                            |
| ----------------------------- | --------------------------------------------------------------- |
| OTG connector                 | ✅ USB-C, bus-powered by the host                               |
| Recovery button → `Maskrom`   | ✅ tiny hole beside the USB-C socket, held as power is applied  |
| `ctrl+b` at the vendor SPL    | ✅ the rescue that survives a dead U-Boot                       |
| `rd 3` (`Loader` → `Maskrom`) | ✅ stock U-Boot only — ours serves no USB, and it is not needed |
| `rl` while in `Loader`        | ❌ real data to 32 MiB then filler, while printing `100%`       |
| `db` in `Maskrom`             | ✅ with the `LDR `-format loader                                |
| `rl` / `wl` after `db`        | ✅ full 15.7 GB verified                                        |

## Known gaps

- **Weak power regulation** — hot-plugging a USB device resets the box; no software fix.
- **Wi-Fi firmware is carried per board**, though this box's factory DRAM, IRAM and RF calibration
  are byte-identical to the other H96 Max's — only the NV differs, by two bytes.
- **Hardware decode is proven; smooth 4K display is a userspace problem.** 4K HEVC decodes at 51 fps
  but displays at 27 fps / 48% CPU because `fbdev` copies every frame. A zero-copy player is out of
  scope for this repo.
- **AV1 has no hardware decode** ➖. Software `dav1d` gives 40.6 fps at 1080p with all four cores
  pegged, so 1080p60 or 4K AV1 is out of reach. Pin players to VP9, which YouTube serves to anything
  not advertising AV1.
- **`ddc read failed` ×15 at every boot.** EDID still parses — 256 B, 40 modes — and everything
  works, so it is cosmetic. Inherited from the factory tree, not from our graft.
- **AVS1/AVS+ decode never confirmed** ❓. FFmpeg's FATE `cavs.mpg`, demuxed to an elementary
  stream, makes MPP spin — endless `loop again`, no frame — under both `vdpu2` codings. Either the
  stream is unclean or the legacy path does not really do AVS1 here. AVS2, the one that appears in
  modern content, works at 357 fps.
- **DCI 4K (4096x2160) skipped deliberately** ➖. The panel-native `3840x2160p60` works; DCI is a
  cinema mode nothing here needs, and `docs/hdmi-edid-override.md` covers banning it if a client
  picks it by area.

## Suspend ✅ · sleep and wake on the remote ❌

**Suspend works.** It enters `deep`, resumes with the same `boot_id`, and survives longer than the
watchdog window — `dw_wdt_suspend()` gates the counter clock, so sleep costs nothing from it.

**The remote cannot be relied on to sleep or wake it, so the power key is `ignore` on both
presses.** BT is the only path — no RTC, no `wakealarm`, no IR receiver.

Six of the seven faults behind that have working fixes, measured: the board has slept 27564 s
through the hour-long link teardown that used to end every sleep at 3598 s, and woken on a keypress
with the remote's HID devices back 0.4 s later. What is not solved is stability — a later suspend
can hang before the Bluetooth driver's PM notifier is even entered, and the box then needs its power
pulled.

`research/seekwave-bt-wake` carries the patch, the measurements and the open failure. Nothing from
it is wired into a build.

**Every software state lights exactly one LED, and that makes the LEDs a diagnostic.**

| State                | blue (`power`) | red (`standby`) | Held by                              |
| -------------------- | :------------: | :-------------: | ------------------------------------ |
| Running              |       on       |       off       | DT `default-state`; `-sleep post`    |
| Suspended            |      off       |       on        | `rk35xx-led-sleep pre` + DT property |
| Powered off / halted |      off       |       on        | `rk35xx-led-shutdown` + DT property  |
| Early boot           |       on       |       on        | pins high until the LED driver binds |

Red **does** hold through `deep` suspend. A 2026-09-06 note claiming every LED goes dark is
withdrawn: it is contradicted by sustained observation, and both LEDs carry `retain-state-suspended`
and `retain-state-shutdown` in the live tree (`/proc/device-tree/gpio-leds/{power,standby}/`,
re-checked 2026-09-07). Correcting it matters — believing a sleeping box looked dark is what made an
unexplained dark box look normal.

> The hooks install as `rk35xx-led` in **both** `/lib/systemd/system-sleep/` and
> `/lib/systemd/system-shutdown/`; the repo names them `rk35xx-led-sleep` and `rk35xx-led-shutdown`.
> The directory, not the filename, picks which one runs.

> ⚠️ **Both LEDs off is not a state this software can produce.** It means the SoC stopped driving
> the pins — a hang or an unclean reset, not suspend and not poweroff. Nothing self-recovers: a hang
> _while suspended_ is invisible to the watchdog, whose counter clock `dw_wdt_suspend()` has gated.
> Recovery is a power cut.
