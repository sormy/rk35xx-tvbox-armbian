# Armbian on the H96 Max (the "H313" one) — bring-up worklog

The second box to get the [R69 treatment](../r69/worklog.md): the LEFFOT **H96 Max H313** TV box —
board name **H96 Max**; despite the "H313" in the retail name, the silicon is another **RK3518**.
Same method, new board: keep the factory idbloader, reuse our u-boot, re-derive the device tree from
the box's own dumps.

This file is the **running worklog** — entries in the order they happen, same spirit as
[../r69/worklog.md](../r69/worklog.md) but written _while_ it happens, not after. When the port is
done, this is the raw material for the polished writeup.

---

## The box

|               |                                                                                                                                                                              |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Name          | **H96 Max** (LEFFOT; retail listing "H96 Max H313") — the "H313" is branding, not the Allwinner chip: the SoC reports RK3518. Case plate: `RAM 2GB · ROM 16GB · Input 5V⎓2A` |
| Board         | silkscreen **`3518_ZX_V01 20250818`** — combined RAM+eMMC module, **SWT6621** Wi-Fi/BT module with on-PCB antennas, 5 V barrel power                                         |
| SoC           | **RK3518** — BL31 says `RK3518 SoC`, cpuinfo `SoC: 35181001` (same ID as the R69)                                                                                            |
| RAM / storage | 2 GB LPDDR3-786 (**real 2 GB** — see below) · 16 GB eMMC `R1J96N` (14.7 GiB, `mmcblk0`) · SD card slot                                                                       |
| Wi-Fi / BT    | **Seekwave SV6160LITE** (module **SWT6621S**) — SDIO Wi-Fi, BT muxed over the same SDIO link. _Not_ an AIC8800                                                               |
| Ports         | HDMI · USB 3.0 · USB 2.0 · 10/100 Ethernet · SD slot · AV jack (+ recessed toothpick button) · IR receiver · red/blue LEDs                                                   |
| Remote        | dual-mode: stock Android pairs it over **Bluetooth**, but every button also transmits **IR** — works unpaired (full keymap in the 2026-08-08 remote entry)                   |
| Serial header | 3 plated holes between the SD slot and the LEDs — **square = RX · GND · TX** (pinout confirmed), `0xff9f0000` @ **1500000** baud — **works both directions**                 |
| Bootloader    | factory **DDR `huan.he` v1.11** (`56f70fd2ad`, 25/02/26) · SPL v1.06 · **BL31 v2.3 fwver v1.20** · OP-TEE BL32 v1.06 · vendor U-Boot 2017.09 (Dec 2025)                      |
| Stock         | **Android 14, 32-bit** (`ro.product.device=rk3518_box_32`, abilist `armeabi-v7a` only), kernel 6.1.118 armv7, SELinux permissive                                             |
| Stock DTB     | `Rockchip RK3518 EVB1 DDR4 V10 Board` — the EVB1 family again (and "DDR4" in the name while LPDDR3 is fitted)                                                                |

---

## Bring-up checklist

Every component the board has, with the test that would have caught the matching R69 failure (see
the [trap table](../r69/worklog.md#troubleshooting-reference-the-rk3518-traps)). "Works on the desk"
is not a pass — several R69 failures only showed under load, on specific media, or across reboots.

**Boot chain & core**

- [x] Boots to Armbian with our `u-boot.itb` + R69 DTB from the SD — but via the **eMMC's own
      factory idbloader**, whose SPL prefers SD (see the boot2.log worklog entry): the SD's
      sector-64 loader never actually ran
- [ ] True SD boot chain: put **this box's own** `factory_idbloader.bin` (from the eMMC dump) on the
      SD and prove it boots with the eMMC chain out of the picture — the R69 loader currently at the
      SD's sector 64 is untested dead weight; golden rule: never ship another board's sector 64
- [x] RAM: full ~2 GB visible under Armbian — `MemTotal: 2015176 kB` (~1.92 GiB; the R69 caps at
      1.43) — this box's advertised RAM is real
- [x] RAM smoke: `stress-ng --vm --verify` (2 workers, 1 GB, all methods, 60 s) — **passed**; a full
      multi-hour soak remains optional
- [x] Serial console on `ttyS0` under Armbian: **bidirectional serial confirmed working** after a
      wiring recheck (input included); `verbosity=7` verified to stream the full kernel boot log to
      **both** serial and HDMI (image default stays quiet — see the dual-console entry)
- [x] CPU: 4 cores, stress smoke passed, thermal 43 → 54 °C. Factory OPPs are **1.2/1.416 GHz only**
      — the "2016 MHz" seen under the rock-2f DTB was its `rk3528a` table **overclocking** this die;
      1.416 GHz is the spec (and matches the marketing)

**Storage**

- [x] eMMC full backup taken + verified — `backup/h96max/emmc-full.img`, **15,758,000,128 bytes =
      exactly 30,777,344 sectors × 512** (sysfs size), GPT header in place; `boot0`/`boot1` dumped
      too (both all-zeros; RPMB not dumpable, fine). Factory idbloader carved from sector 64 →
      `backup/h96max/factory_idbloader.bin`, banner matches the live boots byte-for-byte
      (`huan.he 25/02/26 v1.11` + `SPL v1.06 #lxh`)
- [x] SD card boots a **UHS-capable** card at a UHS rate — the rootfs runs **SDR104 @ 148.5 MHz /
      1.8 V** under the v2 DTB; the factory `vccio_sd` switch (gpio4.14) works. (The R69's UHS-strip
      is confirmed wrong for this board)
- [ ] SD card: also boots a plain non-UHS card (both classes must pass — the R69 trap's real lesson
      is media diversity)
- [x] eMMC **sustained write** test — **3 GiB written across two passes, CRC32C read-back verified,
      zero errors** (fio, direct I/O, in userdata's free tail; region then restored byte-exact from
      the backup). Perf at HS200/100 MHz: **91.6 MB/s read / 45–48 MB/s write, 3.4k/4k random-4K
      IOPS r/w** — the R69's write-corruption failure class does not reproduce
- [x] eMMC capacity honesty: the write+verify region sits at device offset ~13.6 GB (near the end) —
      patterns held, tail samples match backup: no drop-fake (wrap-fake ruled out only by
      full-surface f3, same low-priority caveat as the R69)
- [ ] SD slot still usable as plain storage when booted from eMMC (open on the R69 too)
- [x] `armbian-install` override ships **this box's** loader pair — migration done 2026-08-09 and
      the loaders on eMMC verified byte-identical to `/usr/local/share/rk35xx/` (issue #6 closed on
      both boards)

**Ethernet (10/100)**

- [x] Links at **100 Mb/s full duplex** — sysfs confirms `speed=100 duplex=full`, and the 16 GB eMMC
      pull sustained **92 Mbit/s (11 MB/s ≈ the 100BASE-TX TCP ceiling) with 0 TX
      errors/drops/collisions**. Driver half proven too: same PHY id `0x00441400`, **`RK630 PHY`
      holds it** (the R69 payload's DKMS built + live-handed-over on first boot)
- [x] Load smoke both directions: TX = the 16 GB pull at 92 Mbit/s, 0 errors; RX = 300 MB inbound at
      **87 Mbit/s goodput** (wire speed for the path). The RX drop counter ticks ~0.5% under load
      without hurting goodput — noted as a curiosity, not a defect
- [x] `end0` MAC stable across reboots: `c4:2a:fe:7e:2f:33` × 3 boots (mac-pin from cpuid works on
      this board); `wlan0` re-check after module autoload lands in the payload

**Wi-Fi (SWT6621S / SV6160LITE)**

- [x] **GPIO-vs-SDIO-data-line audit** — done the hard way: five stray-pin bugs found in the
      rock-2f-based v1 (32k pin, vcc_wifibt, vccio_sd, uart2m0, USB host enable — see the stage-1
      hunt entry); the factory-based v2 has no strays by construction
- [x] SDIO enumerates: **`1FFE:6621` at SDR104 / 198 MHz / 1.8 V** under the v2 (factory-based) DTB
      — driver-ready
- [x] Seekwave driver builds against the vendor headers **clean on the first try** (all three
      modules; GPLv2 throughout) — DKMS packaging + offline-at-boot install still to do
- [x] Firmware from **this box's** vendor partition installed under the generic names — and the
      driver's board-suffix fallback keys off our DTB compatible (`…h96max,rk3518-tvbox.bin` tried
      first): the per-board firmware mechanism comes free
- [x] `wlan0` associates and **auto-reconnects across a warm reboot unattended** (NetworkManager
      managing wlan0 only — `end0` stays with networkd; modules autoload via
      `modules-load.d/seekwave.conf`)
- [x] Wi-Fi smoke: **Wi-Fi 6 negotiated** (HE, 5 GHz ch 40, 540 Mbit/s PHY, signal 100), ping 3.6
      ms, throughput **173 Mbit/s down / 76 Mbit/s up** through SSH encryption — far beyond the
      R69's radio. Long soak optional
- [x] `wlan0` MAC pinned per-unit at boot (`88:00:33:28:fc:8e` from cpuid — stable lease from here
      on); the OUI is R69-flavored — pick a per-board OUI policy in the payload phase

**Bluetooth**

- [x] Transport identified: **the Seekwave SDIO mux** — stock disables `wireless-bluetooth` entirely
      (the `uart2m1` pinctrl is an unused leftover) and runs BT over the SDIO transport
      (`skw_ucom`/`BTREADY` in the boot log). Armbian path: the `skwbt` DKMS module, no `hciattach`.
      (If a UART mode is ever tried: `fuser` the tty first — the R69's lesson)
- [x] BT controller **UP and scanning: 181 device-found events** (`btmgmt find`) — required the
      **K3B chip firmware** (see the BT worklog entry); BD addr `FE:FD:FC:99:08:60` is
      chip-generated — pin per-unit later via `skwbt`'s `bd_addr` module param
- [x] Bundled remote **pairs over BLE** (`18:24:39:1D:3D:E1` "Bluetooth remote") — bonded, trusted,
      auto-connects; four HID nodes incl. a working **air-mouse** and a battery readout. Pairing
      mode = hold left+right until the remote's LED blinks (2026-08-08 BLE entry)
- [x] BT nvbin: the vendor partition ships none — `sv6160lite.nvbin` comes from the driver repo, and
      the NV-download path works (board-suffixed lookup first, then generic)
- [~] _(optional)_ Remote voice/mic button — the **key** works (`KEY_SEARCH` over BLE), but the mic
  audio is **not** exposed: no ALSA capture device, no BlueZ audio transport. It rides the vendor
  `0xfeb3` Android-TV voice GATT service, so it needs custom userspace to decode

**Video / audio / GPU**

- [x] HDMI video out — console visible and stable at 1920×1080p60 (fbcon + `getty@tty1`). Caveat
      found on the way: PC monitors with non-standard-clock native modes need a `video=` pin (see
      the 2026-08-08 HDMI entry); real-TV negotiation still worth a spot check
- [x] HDMI audio **audible** — `speaker-test` front-left, then front-right, then a 440/660 Hz
      two-tone stereo clip via `aplay`, all heard on the display's speakers. Channel mapping correct
- [x] GPU: `lima` binds after graft #5, headless GLES contexts create on real hardware (`eglinfo`:
      `renderer: Mali450`, GBM + Surfaceless, no software fallback) — **and now drawn frames on a
      real display**: `glmark2-es2-drm` renders its textured-cube and cat-model scenes on HDMI
- [ ] AV jack analog audio and composite video — untested on both boards
- [ ] HDMI-CEC — untested on both boards (the `hdmi_cec_key` input node does appear)
- [ ] _(optional, headless use)_ VPU hardware video decode (rkvdec/mpp) — never exercised on the R69
      either; note as untested rather than working

**Input / indicators / sensors**

- [x] IR receiver + bundled remote **fully working, unpaired** — the IRQ-28 conflict reproduced and
      the patched `remotectl` DKMS fixed it; every remote button decodes over IR via the factory
      usercode table (`0xfb04`). Full `evtest` keymap in the 2026-08-08 remote entry
- [x] Toothpick/ADC button works — 10 clean `KEY_VOLUMEUP` press/release pairs captured via `evtest`
      on `adc-keys` (factory node identical to the R69's; a free remappable button, and the
      BootROM's maskrom trigger at power-on)
- [x] LEDs: both diodes independently drivable via sysfs, polarity correct (1 = on) — **`power` =
      blue, `standby` = red** (the factory `work-green` node name lied about green; details in the
      2026-08-08 LED entry)
- [x] LED states across the full power cycle: running = pure blue; "off" = red; **suspend = red**
      too (confirmed by eye) — the shutdown/sleep hooks plus `retain-state-shutdown` /
      `retain-state-suspended` all hold. Early boot shows a dim both-lit state until the kernel
      driver binds (cosmetic)
- [x] Thermal: `tsadc` reports; **60 °C peak** under 5 min of 4-core `stress-ng` (49 °C idle, 56 °C
      after), sustained 1.416 GHz with **no throttling** — first trip point is 95 °C (then 110/120),
      so ~35 °C of headroom (mind the case's thermal-pad orientation on reassembly)

**USB**

- [x] USB 2.0: HID enumerates and **works end to end** — a Logitech Unifying receiver bound as
      keyboard (`event3`, `kbd` handler) + mouse (`event4`); 45 key events and mouse motion captured
      via `evtest`, and typing drives the HDMI console login prompt (headless-free operation proven)
- [~] USB 3.0: port is the `fe500000.dwc3` host, root hub advertises **5000 Mbps**, and HID on that
  port works (12 M full-speed, as any USB 1.1 receiver would) with a clean error log. A real
  SuperSpeed device + throughput measurement is still the missing half
- [ ] _(optional, unbrick path)_ Maskrom/loader mode reachable: toothpick held at power-on + USB
      A-to-A, `rkdeveloptool ld` sees the device — OTG is dead under stock Android (no UDC bound)
      but the BootROM drives the controller directly; untested on the R69 too

**Power**

- [x] Power model confirmed: **no PMIC → BL31 virtual poweroff**, same as the R69 — remote
      `KEY_POWER` shut the box down cleanly and the ATF trace printed `virtual poweroff` ("off"
      still sips power; unplug is the only true off)
- [x] Wake from "off": **the remote's power button wakes the box over IR** — the
      `remote_support_psci = <1>` graft armed the ATF wake (`IRQ_EN: 86` at poweroff; wake trace
      `pwm_key: f708fb04` = the `0xfb04` usercode table). Suspend/WoL wake still open (items below)
- [x] Suspend-to-RAM: deep `mem` works — 2m42s asleep, **IR remote wakes it**, resume clean with
      Wi-Fi still associated (same IP/lease), USB re-enumerated, no reboot. Details + the two benign
      resume warnings in the 2026-08-08 suspend entry
- [x] Warm `reboot` reliable — 2 clean measured cycles plus ~a dozen debug reboots today, all
      recovered without intervention
- [x] Power-key / wake press doesn't double-fire — the IR wake press resumed the box and it **stayed
      up** (no logind `KEY_POWER` re-shutdown, unlike the R69's trap)
- [ ] **Wake-on-LAN** — first attempt was invalid (cable unplugged, magic packets aimed at wlan0's
      MAC); needs a retest with Ethernet linked and `end0`'s `86:33:37:fc:84:74`. Kernel does arm it
      (`stmmac: wakeup enable`, `ethtool wol g` sticks)
- [ ] _(optional)_ Power draw measured idle / load / "off" (the R69's trickle was never quantified)

**System plumbing (R69 regressions that must not return)**

- [x] OTP/nvmem readable: SoC serial `6a97e688…` reads fine (mac-pin already derived and pinned
      `end0` from it), and `rk630phy` bound — which implies its `bgs` calibration cell read too
- [x] Timekeeping: NTP synchronized at boot (`timedatectl`), `fake-hwclock` active — no battery RTC,
      works as designed
- [~] _(optional, 24/7 duty)_ hardware watchdog: silicon + driver are there (`snps,dw-wdt` @
  `ffac0000`, `CONFIG_DW_WATCHDOG=y`) but the factory DTB ships the node
  **`status =     "disabled"`**, so there is no `/dev/watchdog`. Needs a DTB graft **and** a
  `RuntimeWatchdogSec` consumer before it's worth enabling
- [ ] DKMS survives a **combined** kernel image+headers upgrade (`00-*-kernel-prepare` hook)
- [ ] DTB persists across kernel updates (`dtb-persist` hook re-installs into new `/boot/dtb-*`)
- [x] `linux-u-boot-*` package apt-held (`apt-mark showhold` confirms it, on both boards)
- [x] Identity survives upgrades — `BOARD_NAME` still "R69"/"H96 Max" after a 28-package
      `apt full-upgrade` on the R69 (the apt boardname hook re-asserts it)

---

## Worklog

### 2026-08-06 — first contact: full stock boot captured over serial

Wired the debug UART the R69 way (GND/TX/RX, no VCC, 1.5 Mbaud) and captured a complete stock
Android boot: **`stock/h96max/boot.log`** (~21k lines — from the DDR banner through Android fully
up). No shell interaction yet; everything below is read straight out of that capture.

**What matches the R69** — the method should transfer largely as-is:

- **Same SoC** (`35181001`) and **same debug UART** (`0xff9f0000` @ 1.5 M; the kernel console is the
  `fiq-debugger`'s `ttyFIQ0` on it, and the fiq-debugger fails its FIQ/NMI setup here too — expect
  the same uart0 → `ttyS0` console conversion).
- **Same DDR blob family** — `huan.he` fwver v1.11, like the R69's. The factory-idbloader-at-
  sector-64 rule applies unchanged.
- **BL31 fwver v1.20** in the factory chain — RK3518-aware, so our existing `u-boot.itb` (mainline +
  BL31 v1.21) should drop in at sector 16384 without a rebuild.
- **Same eMMC controller** (`ffbf0000.mmc`) and **same Ethernet**: `gmac` @ `ffbd0000`, RMII to the
  **integrated FEPHY** — expect to need the `rk630phy` calibration DKMS again.
- **Same IR receiver** (`pwm3` @ `ffa90030`). On stock the in-kernel `remotectl-pwm` v2.0 binds and
  reports "Controller support pwrkey capture"; on the Armbian vendor kernel expect the R69's IRQ-28
  sharing conflict again → reuse the patched DKMS. The H96 remote's usercode/keymap will differ —
  recon it from the stock DTB.
- **BT UART present**: `ttyS2` @ `ffa00000` registers — but see the Seekwave section; BT may not
  ride it at all.
- **USB layout identical** (xHCI @ `fe500000` with SuperSpeed, EHCI/OHCI @ `ff100000`/`ff140000`),
  and **no usable OTG**: stock adbd loops forever on `UDC core: g1: couldn't find an available UDC`
  — so ADB will again be bootstrapped over the network from the serial shell, not USB.

**What's different:**

- **The RAM is real 2 GB.** TPL banner: `LPDDR3 … CS=2 Row=15+15 Size=2048MB`; the stock kernel sees
  `Memory: 2026652K/2086912K`. Unlike the R69 (2 GB advertised, 1.5 GB real, faked in software),
  this box's full 2 GB reaches the OS — so the TPL's memory banks must cover it all. Verify under
  our u-boot + Armbian before celebrating.
- **Stock Android is 32-bit** — armeabi-only userspace on an armv7 kernel (`highmem` in the memory
  line is the tell), device name `rk3518_box_32`. A cost-cutting build, not a hardware limit: the
  SoC is the same quad-A53, so arm64 Armbian is unaffected.
- **Android 14 / kernel 6.1.118** — newer vendor chain than the R69's (SPL v1.06, vendor U-Boot
  built Dec 2025, OP-TEE present).
- **Wi-Fi/BT is a different chip entirely** — the headline risk, below.

**Wi-Fi/BT — Seekwave SV6160LITE (SWT6621S), the hard part.** From the boot log:

- Vendor driver stack logs as `[SKWBOOT]`/`[SKWSDIO]`/`[SWT6621S]`; chip id **`SV6160LITE`**.
- SDIO on `mmc1` (dwmmc @ `ffc20000`), enumerates as an **SDR104** SDIO card at 198 MHz.
- Firmware it loads: `SWT6621S_DRAM_SDIO.bin`, `SWT6621S_IRAM_SDIO.bin`, `SWT6621S_NV_SDIO.bin`,
  calibration `SWT6621S_SEEKWAVE_R00001.bin` (pull all of these from `/vendor` during recon).
- Control GPIOs from the driver's DT parse: `chipen=106`, `gpio_in=107`, `gpio_out=108` — likely
  gpio3 pins 10/11/12, i.e. nearly the R69's Wi-Fi wiring (REG_ON gpio3.10, host-wake gpio3.11).
  Confirm against the stock DTB.
- **Bluetooth does not use plain UART H4.** The vendor stack binds a BT driver over the _SDIO_ link
  (`skw_sdio_bind_BT_driver`, a `BTREADY` channel, and `skw_ucom` char devices `BTCMD`/`BTDATA`
  bridged to Android's HAL). The R69's `hciattach`-on-ttyS2 recipe will not transfer.
- **No existing Linux driver on our side**: the pinned `armbian/linux-rockchip` commit has no
  seekwave driver (`drivers/net/wireless/` — checked; `rockchip_wlan/` holds only `rkwifi`), and
  there's no Armbian package. The driver will have to come from a vendor SDK source drop and ship as
  a DKMS module like the IR/PHY drivers — finding a buildable, licensable source for the SWT6621S
  stack is the open problem of this port.

**Next steps** (the [HOW-IT-WAS-DONE §"another RK3518 box"](../r69/worklog.md) sequence):

1. Get a **root shell on serial** (unverified that Android 14 still runs a console service — SELinux
   is permissive, which is promising) and bootstrap ADB over the network.
2. **Back up the eMMC first** — full 16 GB dump + carve `factory_idbloader.bin` from sector 64,
   verify the `huan.he` DDR banner in it. Irreplaceable, before anything else.
3. **Recon dumps** into a per-box stock dir (decompiled live DTB, gpio, pinmux, dmesg, sdio uevent,
   firmware list, cmdline, iomem…) — plus the Seekwave firmware blobs and, if present, the vendor
   driver sources/`.ko`s from `/vendor`.
4. Derive the DTB from the vendor rock-2f base (console, PCIe off, gmac, Seekwave SDIO node with the
   real GPIOs, the GPIO-vs-SDIO-data-line audit), assemble a test image, iterate over serial + SSH.
5. Decide the repo shape for a second board — the tree is `r69-`-hardcoded throughout
   (`firmware/payload.list`, service names, `build-image.sh`); parameterize or split per-board
   before the payload work starts.

**Open questions:**

- Does the serial console give a root shell on this Android 14 build? _(same-day answer: **no** —
  next entry.)_
- Where do the Seekwave driver sources live, and under what license? (Vendor SDK dumps of
  `skwifi`/SWT6621S exist for other SoCs' BSPs — need one that builds against Armbian's vendor 6.1.)
- How does BT reach BlueZ with this chip — is there any H4-over-UART mode, or only the vendor SDIO
  mux + userspace bridge?
- Physical recon still pending: LEDs, AV jack, recovery button, SD slot, remote (button count, IR
  usercode), case/serial-header location. _(done same day — next entry.)_

### 2026-08-06 — hands on the board: the serial door is closed here

Case opened, board on the desk, serial wired. The physical recon answers most of entry 1's tail —
and closes the R69's easiest door.

**The hardware.** Silkscreen **`3518_ZX_V01 20250818`**: RK3518 SoC, one combined RAM+eMMC module,
the Wi-Fi/BT is a **SWT6621** module (matching the boot log's SWT6621S firmware) with its **antennas
printed on the PCB** (nothing to unplug or knock loose), 10/100 Ethernet, HDMI, AV jack with the
recessed toothpick button behind it, USB 3.0 + USB 2.0, SD card slot, IR receiver, red + blue LEDs,
5 V barrel power. Case plate: `H96 Max H313 · RAM 2GB · ROM 16GB · Input 5V⎓2A`.

**Serial: three plated holes** between the SD slot and the LEDs — **square = RX, then GND, then TX**
(named from the box's side, so cross to the adapter: box RX ← adapter TX, box TX → adapter RX). No
3V3 pad to avoid this time. The gear, both cheap and both fine at 1.5 Mbaud:

- [Waveshare Industrial USB-to-TTL cable, FT232RNL](https://www.amazon.com/dp/B0CX55K4RG) (~$14) —
  an FT232, per the R69 rule (CH340/FT232 do 1.5 Mbaud; CP2102 tops out short of it).
- [DIYhz test-hook grabbers](https://www.amazon.com/DIYhz-Colors-Grabbers-Electronic-Experiment/dp/B07BCZSNGS)
  (~$10) — they grip the plated holes fine; soldering wires works too, but isn't needed.

The same `tio` invocation as the R69 worked straight away (it produced entry 1's `boot.log`):

```bash
tio -b 1500000 -L --log-file boot.log /dev/cu.usbserial-XXXX
```

**First boot on HDMI: Android 14 comes up and asks to pair the remote** — so the bundled remote
leads with **Bluetooth**. (The R69's remote is likely dual-mode too — its voice button implies a BLE
half that was never dived into; that port simply drives all 22 buttons over IR.) This board still
carries an IR receiver and stock still binds the IR driver, so whether this remote also transmits IR
(e.g. for power-on from cold, the way the R69 wakes) is TBD.

**The bad news: the serial console is output-only.** The R69's console dropped straight into a root
shell; this one echoes nothing back — no login, no shell (an Android 14 build without a console
service). The whole R69 entry path — serial shell → network ADB → dumps — is closed. Revised ways
in, in the order to try:

1. **Android Settings** — it's a full Android 14 with a launcher: unlock Developer options (tap the
   build number) → debugging. Note the boot log's endless adbd
   `UDC … couldn't find an available UDC` loop — USB gadget mode looks broken on this build, so
   **wireless debugging / ADB-over-TCP is the likelier winner** (some of these boxes even ship with
   it already listening — a blind `adb connect <box-ip>:5555` once it's on the LAN costs nothing).
2. **Maskrom + `rkdeveloptool`** — hold the toothpick button while applying power, USB-A-to-A into
   (probably) the USB 2.0 port. Needs no Android cooperation, and one `rkdeveloptool rl` dump of the
   eMMC yields the **backup**, the **factory idbloader**, _and_ the **stock DTB** (carve the boot
   partition for the `d00dfeed` FDT magic, the way the R69's stock DTB was extracted from its eMMC
   dump). Combined with the verbose `boot.log` we already hold, that covers most of the recon a
   shell would have provided.
3. Odd doors last: a preinstalled file-manager / app-store that can sideload an APK (a terminal
   app + local ADB), USB-keyboard tricks in the launcher.

### 2026-08-06 — the better door: just boot the R69 image from SD

Rethink: the safest way in isn't through Android at all. **Flash the existing R69 image to an SD and
boot it.** The probe is zero-risk — the image never writes to eMMC (BootROM prefers SD; first boot
only touches the SD rootfs), so worst case is a hang on serial and you pull the card, factory
Android untouched.

And the payoff is bigger than "safest": the **output-only console was Android's limitation, not the
UART's**. The R69 image runs a `serial-getty` on `ttyS0` — if this boots at all, serial becomes an
interactive **root login** again, Ethernet or not. Ethernet working is the comfort upgrade, not the
prerequisite. Either way, a shell on Armbian dissolves the whole entry problem: the eMMC shows up as
a plain block device, so the **backup**, the **factory idbloader**, the **stock DTB** (carved from
the boot partition), and the **Seekwave firmware + vendor `.ko`s** (mount the Android vendor
partition read-only) can all be pulled from Linux — no ADB, no maskrom.

Why the odds are decent:

- **DDR blob match** — the R69's `factory_idbloader.bin` carries `DDR 56f70fd2ad huan.he … v1.11`,
  the **same version and source hash** as this box's factory banner (only the vendor build dates
  differ: 25/09/03 vs 25/02/26). Same training code, and the banner shows full auto-training — good
  odds it brings up this LPDDR3 too.
- **Our u-boot.itb** is generic rk3528 with BL31 v1.21 — same SoC ID, nothing R69-specific.
- **The DTB peripherals sit at the same addresses** on both boxes (console, eMMC, SD, gmac/FEPHY,
  USB, HDMI, thermal, pwm3) — expected to carry over. Expected broken/wrong: **Wi-Fi/BT** (the DTB
  wires an AIC8800; here the R69 pwrseq's REG_ON on gpio3.10 likely just toggles the Seekwave's
  chipen — harmless, nothing binds), **LEDs** (H96 wiring unknown), **IR keymap** (R69 usercode).
  The aic8800 first-boot fixups run and find no chip — harmless; the IR + `rk630phy` DKMS builds are
  actively wanted here.

What to do: flash `images/…minimal-r69.img` (or rebuild via `build-image.sh`), keep `tio` attached,
power on, and read the serial trace against the trap table — DDR banner → mainline U-Boot banner →
`Starting kernel` → Armbian login on `ttyS0`. If it boots: **dump the eMMC first**, then recon. **Do
not run `armbian-install`** on this box — the R69 image would write the _R69's_ loaders to _this_
box's eMMC; eMMC anything waits until an H96-specific loader pair + DTB exist. If it doesn't boot,
the trace pinpoints the failing stage, and the maskrom door from the previous entry remains.

### 2026-08-06 — it boots: the R69 image comes up with a console and Ethernet

**The R69 image boots on the H96 Max on the first try** — console login works, and `end0` is
present. The R69's factory idbloader trained this box's DRAM, our u-boot + BL31 v1.21 took it from
there, and the R69 DTB is close enough to bring the core up. We're in — no ADB, no maskrom, no
Android cooperation needed.

Immediate next moves, in strict order (the backup outranks everything):

1. **Sanity + identity** on the console: `free -h` (does the full 2 GB arrive, vs the R69's 1.4
   GiB?), `lsblk` (expect SD = `mmcblk0` with the rootfs, eMMC = `mmcblk1`, 14.7 G with
   `boot0`/`boot1` siblings — verify before any `dd`), `ip -br addr` for the `end0` lease, and stash
   `dmesg` from this first boot.
2. **Back up the eMMC over Ethernet** — the SD may be too small to hold it, so pull from the Mac:
   `ssh root@<box-ip> 'dd if=/dev/mmcblk1 bs=4M' > h96-emmc-full.img` (~16 GB at 100 Mb/s ≈ 25 min),
   then verify the byte count against `blockdev --getsize64 /dev/mmcblk1` on the box.
3. **Carve + verify the factory idbloader**:
   `dd if=h96-emmc-full.img of=h96-factory_idbloader.bin bs=512 skip=64 count=4096` — `strings` must
   show the `huan.he … 25/02/26` v1.11 banner.
4. **Recon from the dump + the mounted Android partitions** (read-only): the stock DTB (carve the
   boot partition for the `d00dfeed` FDT magic, as done for the R69), and the Seekwave payload —
   firmware from the vendor partition's `etc/firmware` (`SWT6621S_*`), the vendor `.ko`s from
   `lib/modules` (`modinfo` on them names the driver version — the search key for a source drop).

### 2026-08-06 — desk research: the overused name, and a Seekwave driver already exists

**"H96 Max" is a branding umbrella, not a board.** The same name has shipped over RK3318, RK3328,
RK3528 (H96 Max M1/M2), RK3566, RK3588 (V58), Amlogic S905X3/X4, Allwinner H313/H618 — entirely
different silicon per suffix. And there **is** a distinct, current
"[H96 Max RK3518](https://androidpctv.com/h96-max-rk3518-box/)" model (2025): quad A53 @ 1.42 GHz,
Mali-450, 1/2 GB DDR3, 8/16 GB eMMC, **Wi-Fi 6 with internal antenna, BT 5.4**, 10/100 Ethernet, USB
2.0 + USB 3.0, remote with IR + microphone — matching our board line for line. So our unit is the
LEFFOT **H96 Max H313 is that same RK3518 board under its retail name** — the "H313" suffix is
branding noise, and only the SoC report is identity. No community Armbian port exists for it (the
RK3518 groundwork remains
[juliovendramini/rk3518_armbian](https://github.com/juliovendramini/rk3518_armbian), the R69's
method source).

**The Seekwave problem may already be solved.** The
[retro98boy/seekwave-swt6621s](https://github.com/retro98boy/seekwave-swt6621s) repo (active,
updated 2026-07) is the vendor "lite" BSP stack packaged for **DKMS**, three modules:

- `skw_sdio_lite` — the transport/boot layer (SDIO and USB variants);
- `swt6621s_wifi` — the cfg80211 WLAN driver;
- `skwbt` (`drivers/swtbt4l`) — the **Bluetooth** driver, shipping `sv6160lite.nvbin` — our exact
  chip id.

It targets the **KICKPI K3B** (RK3562 — the same Armbian rockchip **vendor 6.1 kernel family** our
image runs, which is exactly what a clean DKMS build needs), and Armbian has already merged its
firmware upstream: [armbian/firmware PR #134](https://github.com/armbian/firmware/pull/134) adds the
K3B set with board-suffixed names (`SWT6621S_DRAM_SDIO.<board>.bin` …) and a **generic-name fallback
matching exactly the filenames our stock Android loads** (`SWT6621S_DRAM_SDIO.bin`, `_IRAM_`,
`_NV_`, `SWT6621S_SEEKWAVE_R00001.bin`).

To verify when we get there: the repo carries no LICENSE file (check `MODULE_LICENSE` tags before
shipping); the default branch is named `kickpi-k3b-sdio-uart` — Wi-Fi over SDIO with BT possibly
over **UART** rather than the SDIO mux stock Android uses (whatever it is, a real `hci0` is the
goal); and whether it builds against our pinned `rk-6.1-rkr5.1` commit. Our own box's firmware from
the vendor partition stays preferable to the K3B's (calibration data is per-design).

### 2026-08-06 — repo decision: one repo, generic builder, per-board prefix

**No fork.** The two boards share the bulk of the repo — the same `u-boot.itb` (proven by the H96
boot), the payload/update mechanism, the kernel hooks (`kernel-prepare`, `dtb-persist`, the
`platform_install.sh` override), the `rk630phy` + IR DKMS drivers, console/power/LED/MAC-pin
plumbing. Only the DTB, the factory idbloader, the Wi-Fi/BT stack (AIC8800 vs Seekwave), and
identity/branding are per-board. A fork would duplicate the shared layer and let it drift — the
disease `payload.list` exists to prevent.

**Naming rule: the prefix is the board name, by default.** Every board's on-box artifacts (services,
DKMS packages, `/usr/local/share/<prefix>/`, the updater) carry that board's own prefix — `r69-` for
the R69, `h96-` for this box. That makes the deployed R69 fleet need **zero migration** (its prefix
was always the rule, not an exception), keeps names on a box self-describing, and the scripts stay
generic with the prefix as a `board.conf` value. Target shape:

```
build-image.sh <base.img> <board>          # reads boards/<board>/
boards/r69/                board.dtb · factory_idbloader.bin · board.conf · payload.list · stock/
boards/h96-max-rk3518/     (same layout)
firmware/                  shared payload + wifi-aic8800/ · wifi-swt6621s/ fragments
```

**Timing:** decided now, restructured later — first bring the H96 up dirty (parallel DTB + hacked
payload on the live box), and generalize once its real payload shape is known from recon. No
abstraction before the second data point is in hand.

### 2026-08-07 — reading `boot2.log`: whose idbloader actually ran (surprise: the eMMC's)

**`stock/h96max/armbian-first-boot-serial.log`** (captured as `boot2.log`) is the full serial
capture of the Armbian boot — DDR banner to login prompt. Healthy end to end, and it settles a
question we didn't know we had.

**The discovery: the SD's sector-64 idbloader never ran.** The DDR banner in this boot is
`huan.he … 25/02/26-10:00:31` — the **H96's own factory blob** (the R69 loader on the SD stamps
`25/09/03-10:05.55`), and the SPL banner (`2017.09 … #lxh, fwver v1.06`) is byte-identical to the
stock Android boot. The chain that actually ran:

1. **BootROM**: probes SPI NOR (none fitted — `unrecognized JEDEC id bytes: 00, 00, 00`), then boots
   the **eMMC's** idbloader — its TPL trains the DDR (786 MHz, `Size=2048MB`).
2. **The factory vendor SPL prefers SD**: `Trying to boot from MMC2` (that's the SD — the stock log
   shows the same attempt failing `no card present` and falling back to `MMC1`/eMMC). On our SD it
   finds no Android `misc` partition, falls back to a raw FIT at sector `0x4000` = 16384 — **our
   `u-boot.itb`** — verifies its sha256es and jumps in.
3. **Our chain from there**: BL31 v1.21 → mainline U-Boot 2026.04 (`SoC: RK3518A`, **`DRAM: 2 GiB`**
   — the full 2 GB reaches U-Boot, vs the R69's 1.5) → `boot.scr` → kernel → Armbian.

So "SD boots first" on these boxes is (at least here) a property of the **factory SPL's boot order,
not the BootROM's** — the BootROM went to eMMC first. Implications:

- The R69's DDR blob was never actually tested on this DRAM — the box trained on **its own** tuning.
  The golden rule was honored by accident. (Also a nuance to back-port to the R69 docs someday: what
  we attributed to the BootROM was likely its SPL too.)
- Armbian-from-SD currently **depends on the eMMC's factory SPL staying intact** — fine for now, and
  the eject-SD→Android story is unchanged (SPL falls back to eMMC). But eMMC migration later must
  write loaders proven to boot from the BootROM directly, and the SD image should carry this box's
  own idbloader — both already on the checklist.

**Healthy signals**: fsck clean; `serial-getty@ttyS0` up with the first-run **automatic root login
on serial** — the "output-only console" era is officially over; SD reads ~11.5 MiB/s in U-Boot; SSH
starts.

**Expected R69-payload noise on this board** (all harmless, all future generic-builder work):

- `r69-mac-pin` ran ~20 s: its `pin wlan0` waits 10 s for an interface that can't exist here (no
  AIC8800), then pins `end0` — with the **R69's** vendor OUI. Per-board interface list + OUI later.
- `r69-bt` "succeeds" trivially — wrong chip, and bluez isn't installed on the minimal image.
- `r69-firstboot` still building the IR + `rk630phy` DKMS modules at capture end — both wanted on
  this board.
- `serial-getty@ttyFIQ0` waits 90 s and times out (`Dependency failed`) — something orders a getty
  on a `ttyFIQ0` our DTB never creates (no fiq-debugger). Cosmetic; find who asks for it (likely
  Armbian's rk35xx `boot.cmd` console defaults) and drop it.
- Mainline U-Boot noise: `fs uses incompatible features: 00020000` (ext4 casefold — ignored, reads
  fine) and a failed `efi_mgr` bootflow before the script bootflow wins. Benign, same class as on
  the R69.

### 2026-08-07 — in over SSH: backup running, `stock/` split per board, first hardware recon

SSH access is up (`art@r69`, 192.168.1.216 — and `art` is in the `disk` group, so the raw eMMC reads
need no sudo at all). **The full eMMC backup is pulling over Ethernet at wire speed** (~12 MB/s)
into `backup/h96max/emmc-full.img`; the hardware boot partitions came first — `emmc-boot0/1.img`,
both **all zeros** (factory boots from user-area sector 64, like the R69). Incidentally the 16 GB
pull is the checklist's first Ethernet load test.

Meanwhile the repo's stock evidence went per-board: **`stock/` → `stock/r69/` + `stock/h96max/`**
(docs' references updated). `stock/h96max/` now holds the stock Android serial capture (`boot.log`,
moved from the repo root) plus a fresh hardware-identity harvest taken over SSH — see its
`README.md` for per-file provenance. The notable finds:

- **`MemTotal: 2015176 kB`** — the full 2 GB is real and usable under Armbian. ✔ checklist.
- **Ethernet PHY is the same RK630-class FEPHY** (`phy_id 0x00441400`) — and **`RK630 PHY` already
  holds it**: the R69 payload's DKMS built on first boot and did the live handover, unprompted. The
  R69's Ethernet recipe transfers wholesale.
- **cpufreq spans 408–2016 MHz** — the marketing "1.42 GHz" undersold it; currently clocking 2.016
  GHz on the ondemand governor, 48 °C at idle. (Stability under sustained load still on the
  checklist.)
- SoC serial readable (`6a97e688…`, matches the stock boot log) — mac-pin derived + pinned `end0`
  from it. ✔ the OTP/nvmem dependency.
- eMMC identity: `R1J96N`, manfid `0x13`, 30,777,344 sectors — same sector count as the R69's part,
  different vendor; the storage-caps re-derivation still stands.

Still Android-only and pending from the dump: the stock DTB (carve `boot`, p7) and the Seekwave
firmware + vendor `.ko`s (`lpunpack` the `super`, p13 — Android 14 dynamic partitions, a wrinkle the
R69's flat layout didn't have).

**Phase 1 closed the same day.** The dump completed in ~25 min at wire speed:
`backup/h96max/emmc-full.img`, **15,758,000,128 bytes = exactly 30,777,344 × 512** (matches sysfs),
GPT header verified. The **factory idbloader is carved** (`backup/h96max/factory_idbloader.bin`, 2
MB) and its banner matches the live boot captures byte-for-byte — the box's undo button and its
future sector-64 loader are both in hand. Ethernet vindicated along the way: the transfer held **92
Mbit/s with zero TX errors** — 100BASE-TX's practical ceiling (an earlier "half speed" reading was
measurement error) — with only a minor note to re-check RX drops (~0.3% of background chatter) under
a real inbound `iperf3`. Next: carve the stock DTB from `boot` (p7) and `lpunpack` the `super` (p13)
for the Seekwave firmware + vendor modules.

### 2026-08-07 — recon complete: stock DTB + the whole Seekwave payload, out of the dump

All offline, from `emmc-full.img` — no box access needed. Parsed the GPT in Python, carved `dtbo`
(p5), `boot` (p7), `super` (p13), and got everything `stock/h96max/` was still missing:

- **The stock DTB**: `boot` holds two identical FDT copies (`d00dfeed` scan → md5-equal);
  `stock/h96max/board.dtb` + decompiled `board.dts` (4641 lines, `rockchip,rk3518-evb1-ddr4-v10`).
  First reads: the Wi-Fi node is **`compatible = "seekwave,sv6160lite"`**, and `wireless-bluetooth`
  carries **`uart2m1_gpios` — BT rides UART2**, exactly like the R69's AIC8800 and matching the
  driver repo's `sdio-uart` branch name. A standard BlueZ path looks plausible after all.
- **The firmware**: `super` unpacked with `lpunpack` (all images plain ext4, no EROFS wrinkle) →
  `vendor:/etc/firmware` → `stock/h96max/firmware/`: the complete 10-file `SWT6621S_*` set — the 4
  files the stock boot actually loads, plus NV variants and the `.ini` calibration configs.
- **The vendor modules**: `vendor_dlkm:/lib/modules` → `stock/h96max/vendor-modules/`: `skw*.ko` +
  `swt6621s_wifi.ko` (+ `modules.{load,dep,alias,softdep}`). vermagic `6.1.118 … ARMv7` — 32-bit, so
  evidence only — but `version=1.0.0` and the module names match the **retro98boy DKMS exactly**:
  same driver lineage. `modules.load` shows stock ships **both** the full
  (`skw_sdio`+`skw_bootcoms`+`skw`) and **lite** (`skw_sdio_lite`+`swt6621s_wifi`) stacks and lets
  probing pick; the community DKMS builds the lite one.
- Small flag for the driver phase: the DTS names `seekwave_nv_name = "SEEKWAVE_NV_SWT6652.bin"` — a
  file that doesn't exist in the firmware dir; the driver evidently falls back to
  `SWT6621S_NV_SDIO.bin`. Also amusing: the vendor image carries drivers for half the TV-box Wi-Fi
  universe (aic8800, bcmdhd, rtl 8822cs/8852bs…) — BOM insurance; the DTB selects.

With this, `stock/h96max/` is as complete as the R69's evidence dir — richer in places (full serial
boot capture, firmware blobs, vendor modules). What remains Android-only (live gpio/pinmux/full
getprop) is covered well enough by the DTB + boot log. **Recon done; next phase: derive the H96 DTB
from the vendor rock-2f base** — console, storage caps from this DTS, gmac, the Seekwave SDIO node
with the real GPIOs, and the GPIO-vs-SDIO audit.

### 2026-08-07 — stock-vs-stock DTB diff: the definitive per-board delta list

Compared the two boxes' **factory** DTBs head-to-head (`stock/r69/board.dts` ↔
`stock/h96max/board.dts`) — same EVB1 vendor lineage, so after filtering ~230 phandle-renumbering
false positives (a structural comparator, not plain `diff`), what remains is the true hardware
delta. This is the work list for the H96 DTB derivation:

**Must change (vs the R69's Armbian DTB as the base):**

1. **Wi-Fi: replace the node model entirely.** H96 stock **disables** `wireless-wlan` (a stale
   `wifi_chip_type = "ap6275s"` leftover!) and `wireless-bluetooth`; the radio hangs off a dedicated
   **`/seekwcn_boot`** node instead: `compatible = "seekwave,sv6160lite"`, `dma_type = <1>`,
   `seekwave_nv_name`, **chip_en = gpio3.10, host_wake = gpio3.11, chip_wake = gpio3.12** (bank 0xa6
   = gpio@ffb10000; matches the boot-log parse 106/107/108). The factory `sdio_pwrseq` stays (reset
   = gpio3.10 active-low, 200 ms post-power-on). SDIO controller: factory runs
   `max-frequency = 200 MHz` (R69 base: 100) and drops `rockchip,use-v2-tuning`.
2. **Correction to the earlier entry: BT is on the SDIO mux, not UART2.** The `uart2m1-gpios`
   pinctrl exists but nothing enabled references it — stock BT runs through the Seekwave SDIO
   transport (`skw_ucom`/`BTREADY` in the boot log). Port plan: `skwbt` DKMS, no `hciattach`.
3. **SD card: the R69's UHS-strip must NOT be applied — this board has the 1.8 V switch.** Factory
   sdmmc carries full `sd-uhs-sdr12/25/50/104`, `rockchip,default-sample-phase = <90>`, and a real
   **`vccio_sd` `regulator-gpio`** (1.8 ↔ 3.3 V, states table, switch on gpio4.14) plus a
   gpio-switched `vcc_sd` (gpio4.1). Restore all of it — the R69 trap applies in reverse here (its
   DTB would needlessly cap this box's SD at HS50).
4. **IR: full keymap re-derivation.** Primary usercode **`0x4040`** (R69: `0xfb05`) and every
   `ir_key*` table differs. The receiver, driver, and the IRQ-28 sharing situation are unchanged
   (the PWM block regulators are still active) — the patched remotectl DKMS carries over; only the
   keymap is new.
5. **PWM housekeeping:** factory disables `pwm@ffa98000/10/30` (the R69 tree leaves them okay) —
   match factory.
6. **`sai@ffb80000` is enabled** in factory (disabled on the R69) — an audio interface; find what it
   feeds during the audio checklist item.

**Confirmed no-change (factory agrees with the R69 base):**

- **eMMC: identical caps** — `mmc-hs200-1_8v` + `max-frequency = 100 MHz` from the factory, minus
  the bogus enhanced-strobe prop. The R69's hard-won HS200 setting is this box's factory setting.
- **LEDs: same pins, recipe pre-applied** — blue ("work-green") gpio4.17 + red gpio4.11, **both
  active-low, with `retain-state-shutdown/suspended` already in the factory tree**. The R69's entire
  LED battle (polarity fix + retain-state) ships from the factory here.
- `adc-keys` (toothpick), thermal, USB, gmac0 (RMII, integrated FEPHY) — not in the delta; carry
  over as-is. H96 stock has no `gmac1` node and no hardwired `local-mac-address` (mac-pin covers
  it).
- Cosmetics/no-action: root compatible `rk3518` vs `rk3528a`, logo modes, per-die `mbist-vmin`, and
  the memory/serial-number nodes (live-DT artifacts of the R69's dump, not board deltas).

Open question flagged for derivation: the R69's Wi-Fi 32 kHz clock line (gpio3.19) has no
counterpart in `/seekwcn_boot` — verify whether the SWT6621S needs an external 32k at all.

### 2026-08-07 — `firmware/h96max/`: the stage-1 DTB, built on the R69's proven tree

**Base decision:** derive from the **R69's Armbian DTS**, not from vanilla-anything. The R69 tree
_is_ the Radxa vendor base plus every generic fix (console→`ttyS0`, fiq-debugger off, PCIe off, USB3
host, storage sanity) — and it **already boots this box** (boot2.log). Sanitizing the 4,600
Android-ism lines of the stock H96 DTS instead would re-derive all of that blind, with no serial
attached. The stock DTS serves as the **source of truth for values**, never as the base document.

**Staged for testability without serial:**

- **Stage 1** (built now, `firmware/h96max/board.dts` + `.dtb`) — only deltas that can't break the
  rootfs path: identity (`model = "H96 Max RK3518 TV box"`, `h96max,rk3518-tvbox` + kept
  `rockchip,rk3528a`), the **`seekwcn_boot`** node verbatim from factory (chip_en/host_wake/
  chip_wake = `&gpio3` 10/11/12 with factory flags), sdio1 at factory **200 MHz** minus
  `use-v2-tuning`, the AIC `wireless-wlan` node deleted, `wireless-bluetooth` **disabled** (BT is on
  the SDIO mux), and the full factory **9-table IR keymap** (primary usercode `0x4040`). Kept
  deliberately: `remote_support_psci = <1>` (factory says 0; we want wake-on-IR armed, proven with
  our BL31 on the R69) and the R69 sdio_pwrseq (it was already byte-identical to factory: gpio3.10
  active-low, 200 ms). LEDs/eMMC/USB/gmac untouched — factory agrees with the base.
- **Stage 2** (after stage 1 boots + Wi-Fi enumerates) — the SD **UHS restore**: `sd-uhs-*`,
  `default-sample-phase=90`, `vccio_sd` regulator-gpio (gpio4.14) + switched `vcc_sd` (gpio4.1).
  Deferred because it touches the **rootfs device**; isolating it means a hang would have exactly
  one suspect.

Compile: `dtc -@`, usual benign decompile warnings; verified in the **binary** dtb: seekwcn GPIOs
resolve to gpio3's phandle, usercode `0x4040`, 200 MHz, no `wlan-platdata`, BT node disabled.

**Test plan:** install as `/boot/dtb-*/rockchip/board-h96.dtb` + flip `fdtfile` in `armbianEnv.txt`,
reboot, expect SSH back with the new model string and — the stage-1 success criterion — the **SDIO
card enumerating** (`mmc: new … SDIO card`, driver-independent, exactly what stock printed).
Recovery if it doesn't come back: pull the SD, revert the one `fdtfile` line in `armbianEnv.txt` on
the Mac, reinsert — the R69 DTB is untouched on the card.

### 2026-08-07 — stage 1, the hunt: five stray-pin bugs, a dead end, and a pivot that fixed it all

The stage-1 DTB **booted but the Seekwave stayed silent** — no SDIO response at any clock, with
`chip_en` correct, the pwrseq firing, and `clk_32k` running. What followed was the deepest debug of
this port so far, worth recording move by move:

**Round 1 — static hunts, five real bugs, each a GPIO-audit classic** (all found by structural
DTB-vs-DTB comparison and live-state reads, all fixed, none sufficient):

1. **The 32 kHz LPO on the wrong ball, twice over.** The R69 tree muxes `wifi_32k` as gpio3.19 func
   1; a first "fix" moved it to func 3 (matching a `clkm0_32k_out` definition) — but the pin factory
   actually references is **gpio1.19 func 1 = `clkm1_32k_out`**. A grep `-B` context had pointed at
   the wrong of two 32k pin definitions.
2. **`vcc_wifibt` doesn't exist on this board** — the R69 node drives gpio4.4 as a Wi-Fi power
   enable; the H96 powers the module from always-on `vcc_3v3_s3`. Stray drive, removed.
3. **The rock-2f `vccio_sd` regulator drives gpio1.17 high** — two pins from the 32k line, not the
   H96's SD-voltage switch (that's gpio4.14). Stray drive, removed.
4. **`uart2` muxed as `uart2m0` = gpio3.0/3.1/3.3** — module-adjacent pins, actively written by the
   leftover `r69-bt` hciattach. Factory muxes `uart2m1` (gpio1.8/9/11). Switched.
5. **USB host power on the wrong pin** — ours enabled gpio0.1; the H96's `vcc5v0_host` switch is
   gpio4.13 (found in the same sweep; USB-relevant, not Wi-Fi).

**Round 2 — the isolation test that broke the stalemate.** Booting the **factory DTB verbatim**
under our kernel + u-boot enumerated the chip instantly (`SDIO_ID 1FFE:6621`, SDR104/198 MHz) —
proving the environment innocent and our derived tree still wrong somewhere beyond the diffs. Live
A/B state captures (clk_summary, pinmux, gpio, regulators) between the working factory boot and ours
showed the remaining deltas were **a dozen subsystems deep**: audio cards (`bt-sound`, an always-on
6.144 MHz `sai` mclk), i2c topology, LED/OPP/DMC tables for the different die…

**The pivot — and the method lesson of this port:** _"edit the vendor DTB" means the board's own
vendor DTB._ For the R69, the rock-2f tree happened to be near-identical to its board; for the H96
it diverges in a dozen subsystems, and dragging it into factory shape was a war of attrition.
**Stage-1 v2 = the factory H96 tree + exactly four grafts**: `uart0` enabled as the `ttyS0` console
(the R69 recipe), `fiq-debugger` disabled, H96 identity strings, and `remote_support_psci = <1>` for
wake-on-IR. Factory `dwc3` was already host-mode with the full quirk set — the USB graft came free.

**Result — stage 1 and stage 2 both done in one stroke:**

- **Wi-Fi SDIO enumerates: `1FFE:6621` at SDR104 / 198 MHz / 1.8 V** — driver-ready.
- **SD rootfs runs UHS: SDR104 @ 148.5 MHz** — the `vccio_sd` 1.8 V switch works; the planned "stage
  2" UHS restore became moot (vs HS50 under the R69 tree — a real rootfs speed upgrade).
- eMMC at HS200/100 MHz (the proven cap), RAM 1.9 Gi, `serial-getty@ttyS0` active, only
  stock-identical benign errors in dmesg.
- Bonus corrections by construction: factory-correct rk3518 OPP/DMC voltage tables (the rock-2f
  rk3528a tables undervolt this die and its DMC opps overclock this LPDDR3), LED wiring, IR keymap,
  USB host power pin.

Back-port note for the R69: its `wifi_32k` func-1 mux deserves a second look (probably a silent
no-op the AIC never needed), and the five-bug list above is the GPIO-audit cautionary tale in its
most concentrated form. The rock-2f-based v1 attempt is preserved in the session scratch only; its
value — the bugs — lives here. **Next: the Seekwave DKMS build on the box.**

### 2026-08-07 — the Seekwave driver: `wlan0` scanning and `hci0` registered, same evening

With the chip enumerated, the driver phase collapsed into an hour. The box has no internet, so:
cloned [retro98boy/seekwave-swt6621s](https://github.com/retro98boy/seekwave-swt6621s) on the Mac
(licensing checked first: **GPLv2 across all modules**, Seekwave copyright headers intact —
shippable as DKMS like the IR/PHY drivers), pushed it over SSH, and built with the `dkms.conf` flags
against the shipped `linux-headers-6.1.115-vendor-rk35xx`: **all three modules compiled clean on the
first attempt** (`skw_sdio_lite`, `swt6621s_wifi`, `skwbt`).

Firmware: the 10-file `SWT6621S_*` set from this box's own vendor partition into `/lib/firmware`,
plus the repo's `sv6160lite.nvbin` for BT. A nice discovery: the driver requests board-suffixed
firmware first, keyed off the DTB root compatible —
`SWT6621S_SEEKWAVE_R00001.h96max,rk3518-tvbox.bin`, then falls back to the generic name. Our
identity string became the per-board firmware namespace for free.

**Results on `insmod`:**

- `skw_sdio_lite` + `swt6621s_wifi`: chip firmware downloads, `WIFIREADY`, calibration loads, `phy0`
  registers, **`wlan0` scans 32 networks** — the radio is fully alive.
- `skwbt`: **`hci0` registers** over the SDIO transport — with one flag: the CP fires
  `BSPASSERT:hci_tl.c-386` on BT service start and the driver reports a hardware-error recovery
  before `hci0` appears. BT needs a debug pass (NV variant — the `_SHARE`/`_ALONE` split looks
  antenna-config-related — and the start sequence) plus `bluez` before `bluetoothctl` can prove it
  end-to-end.

Still open for this phase: `wlan0` **association** (needs Wi-Fi credentials — deferred), then
packaging everything as the `h96-` DKMS + payload so it builds offline on first boot like the R69's
drivers.

### 2026-08-07 — Bluetooth: a btmon trace, an advertised-but-broken opcode, and newer firmware

Two ghosts and one real bug, all now understood:

**Ghost:** a phantom `hci0 (UART)` kept appearing — the R69 payload's `r69-bt` service
`hciattach`-ing `ttyS2` at every boot. `systemctl disable` didn't stop it because the R69 image
enables its oneshots via a `multi-user.target.d` **`Wants=` drop-in, which `disable` does not
override** — it needs `mask` (or removing the unit). Removed on this box; payload lesson recorded:
per-board service sets, and the drop-in must be per-board too.

**The real bug, caught by `btmon`:** the Seekwave answers ~80 HCI init commands perfectly — a full
BT 5.3 controller (name `SEEKWAVETECH`, LE 2M/Coded PHY, ISO, extended advertising) — then dies at
exactly **`Read Local Supported Codec Capabilities (0x100e)` → `Hardware Error`**: the chip firmware
**asserts (`BSPASSERT:hci_tl.c-386`) on an opcode its own command bitmap advertises**. Classic
advertised-but-broken firmware defect; the kernel is blameless.

**The fix — newer chip firmware, not driver hacks:** swapped in the **KICKPI K3B build of the
chip-code images** (`SWT6621S_DRAM_SDIO/IRAM` from `armbian/firmware`'s `seekwave/` dir — merged
upstream), keeping **this box's own NV + RF calibration**. Result: no assert, BT service boots
(`BTREADY`), and the **nvbin download path activates** (it never ran on the old firmware) — with the
board-suffixed lookup tried first (`sv6160lite.h96max,rk3518-tvbox.nvbin`), chip version `0x5302`
confirmed, controller **UP RUNNING**, `btmgmt find` returning **181 device-found events**. Wi-Fi
re-verified on the new firmware: 31-network scan.

Packaging decision recorded: ship the K3B `DRAM`/`IRAM` as the generic chip-code, this box's
`NV_SDIO` + `SEEKWAVE_R00001` as the board calibration. Remaining BT items: pair the bundled remote
(physical test), pin the BD address per-unit (`bd_addr` param — the BT analog of mac-pin), and the
optional voice path.

### 2026-08-07 — smoke-test sweep: five ticks and one genuine catch

Quick unattended pass over the remaining remotely-testable items (smoke depth, not soaks): RAM
verified-pattern stress **pass**; CPU stress pass with thermal 43 → 54 °C; Ethernet RX smoke at **87
Mbit/s goodput** (both directions now wire-speed); `end0` MAC identical across three boots; NTP +
`fake-hwclock` fine; `linux-u-boot-*` confirmed apt-held.

Two truths surfaced:

- **CPU spec honesty**: factory OPPs are 1.2/1.416 GHz. The 2.016 GHz this box "ran at" under the
  rock-2f DTB was that tree's `rk3528a` table silently **overclocking** the die — one more entry in
  the wrong-base hazard list.
- **GPU regression found**: `lima` doesn't bind against the factory GPU node (vendor Mali clock
  names/`clocks`) — `get bus clk failed`. Needs a rock-2f-style gpu-node graft (DTB graft #5).
  Headless use unaffected.

### 2026-08-07 — Wi-Fi end-to-end: Wi-Fi 6 at 173 Mbit/s, self-assembling after reboot

NetworkManager installed **scoped to wlan0 only** (`unmanaged-devices=*,except:interface-name:wlan0`
— `end0`/SSH stays on networkd), modules autoloading via `modules-load.d`. Credentials entered by
hand on the box (`nmcli --ask` — nothing in logs). Results:

- Association immediate; link negotiates **Wi-Fi 6** (HE, 5 GHz, 540 Mbit/s PHY, signal 100).
- Throughput smoke through SSH: **173 Mbit/s down / 76 Mbit/s up**; ping 3.6 ms.
- **Warm reboot: everything self-assembles** — modules autoload, NM reconnects, and `hci0` (the
  Seekwave, now the only controller) registers. Zero manual steps.
- `r69-mac-pin` picked up `wlan0` on the autoload boot and pinned the cpuid-derived MAC — per-unit
  stable Wi-Fi lease from here on (OUI policy per board is a payload-phase decision).

Radio scorecard: **Wi-Fi associated and fast, Bluetooth scanning** — the "hard part" of this port is
functionally done. What remains is packaging, the hands-on test batch, and the eMMC decisions.

### 2026-08-07 — is MAC pinning even needed here? Mostly no

Challenged the inherited R69 assumption; verified with `ethtool -P`:

- **Wi-Fi: no pin needed** — the Seekwave's permanent MAC (`fe:fd:fc:99:08:5f`) is chip-derived and
  stable across boots _and_ reflashes. The R69's pin exists because the AIC8800 randomizes every
  boot while claiming permanence — a bug this chip doesn't have.
- **BT: no pin needed** — BD addr (permanent+1) equally stable, chip-derived.
- **Ethernet: no pin needed for stability** — systemd's persistent policy yields a stable machine-id
  MAC. cpuid-pinning's only real value is **reflash survival** (machine-id regenerates with a fresh
  image; the SoC serial doesn't), which matters iff you rely on router DHCP reservations across
  reflashes.

Payload decision: **drop wlan0 + BT pinning for the H96; keep at most a one-line `end0` pin** for
reflash-stable reservations. A true per-board difference — the R69 keeps its Wi-Fi pin out of
necessity.

### 2026-08-07 — pinning removed for good: two-reboot observation + OUI registry check

Removed `r69-mac-pin` from the box (unit + `Wants=` drop-in entry) and observed across **two
reboots** — all three addresses identical both times, with the kernel flagging eth and Wi-Fi as
`addr_assign_type 0` (permanent):

| Interface | Address             | Source                                                     |
| --------- | ------------------- | ---------------------------------------------------------- |
| `end0`    | `86:33:37:fc:84:74` | u-boot derives it from the SoC serial — reflash-stable too |
| `wlan0`   | `fe:fd:fc:99:08:5f` | chip-fused (Seekwave efuse)                                |
| BT        | `FE:FD:FC:99:08:60` | chip-fused (Wi-Fi + 1)                                     |

Registry check ([maclookup.app](https://maclookup.app/) API): none of the prefixes are
IEEE-registered — `FE:FD:FC` and `86:33:37` carry the locally-administered bit by construction (the
API flags them `isRand`), which is fine: stable, unique per box, collision-free with real vendors.
The punchline: **the R69 payload's "vendor OUIs" aren't registered either** — `C4:2A:FE` (the stock
Android hardcode it inherited) and `88:00:33` (the AIC's prefix) are both absent from the registry.
Nobody in this ecosystem uses real OUIs.

**Final decision: the H96 payload ships no MAC pinning at all.** u-boot's cpuid-derived eth MAC
already survives reflashes, and the radio addresses are silicon-fused.

### 2026-08-07 — the R69-workaround audit: what the H96 payload gets to drop

Full inventory of R69 "fuckery" vs H96 reality — the payload design in one table.

**Dead on the H96 (drop entirely):**

| R69 workaround                                                                                    | Why it's unnecessary here                                                                        |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| The whole AIC8800 dance (apt-remove usb-dkms war, firmware symlink farm, blacklist, modules-load) | different chip; the Seekwave driver even solves firmware naming properly (board-suffix fallback) |
| `r69-bt` hciattach + ttyS2-getty masking                                                          | BT is SDIO-native via `skwbt` — no UART, no getty war                                            |
| `r69-mac-pin` (whole service)                                                                     | all three MACs silicon/cpuid-stable, reflash-proof (verified, 2 reboots)                         |
| SD UHS strip                                                                                      | actively wrong here — board has the 1.8 V switch, UHS kept                                       |
| eMMC HS200 cap as a fix                                                                           | factory tree already ships exactly that cap                                                      |
| PCIe disable                                                                                      | factory tree has no PCIe node at all                                                             |
| gmac0 enable                                                                                      | factory-enabled                                                                                  |
| USB3 dwc3 host-mode surgery                                                                       | factory already host-mode with the full quirk set                                                |
| Wi-Fi DTB bring-up (sdio node, pwrseq, platdata, 32k, GPIO audit)                                 | factory-correct by construction                                                                  |
| LED polarity + retain-state DTB battle                                                            | factory ships the R69's hard-won ending pre-applied                                              |
| fake-RAM investigation                                                                            | no fake — the 2 GB is real                                                                       |
| **the rock-2f DTB base itself**                                                                   | the meta-workaround; replaced by the factory tree                                                |

**Still needed (same disease, verified where possible):**

- **IR remotectl patched DKMS** — the IRQ-28 `Flags mismatch` probe failure reproduces on the H96
  (seen in today's dmesg, built-in fails `-16`, our DKMS binds after) — only the keymap differs
- **rk630-phy DKMS** — same integrated FEPHY + OTP calibration (bound and working here)
- **u-boot apt-hold**, **`platform_install.sh` override** (with the H96 loader pair),
  **`00-kernel-prepare`** and **dtb-persist** postinst hooks — board-independent hazards
- Console→`ttyS0` conversion, identity/boardname hook, bluez `AutoEnable`
- The core method: factory idbloader @64 + our `u-boot.itb` @16384

**Changed shape:** LED hooks survive but rename (`work-green`/`work-red`); power-key/suspend
drop-ins pending the wake-path investigation (BT-first remote → WoL is a candidate primary wake);
new H96-only pieces: Seekwave DKMS + firmware payload, NM-wifi-only config, and the pending GPU node
graft.

Net effect: the H96 payload is **dramatically smaller** than the R69's — most of the R69's hard-won
machinery existed to fight problems this board's factory tree and saner Wi-Fi chip simply don't
have.

### 2026-08-07 — confidence-gap session: hooks exercised, a landmine defused, Wi-Fi vindicated

Remote-reachable gaps closed in one pass:

- **Landmine found and defused**: the box's `dtb-persist` master copy was still the **R69 DTB** — a
  kernel update would have silently clobbered `board-h96.dtb`. Master replaced, then the hook
  **exercised for real** (re-install → byte-identical md5). `00-kernel-prepare` also runs clean.
  Both hooks: inherited-confidence → tested-on-H96.
- **CPU sustained load**: 5-minute all-core + VM stress — zero throttling (1.416 GHz held), peak 57
  °C. Passive cooling is comfortable.
- **Wi-Fi reliability, properly root-caused**: idle pings from the box showed 16–35% "loss" — but
  inbound pings showed 0%, TCP held 175 Mbit/s, and NM logged zero disconnects. The cause is the
  **bring-up rig's dual-homing** (end0 + wlan0 on one subnet → ARP flux + rp_filter drops), not the
  radio: with `end0` downed (self-reverting experiment), **120/120 pings, 0% loss, 6 ms avg** over
  pure Wi-Fi. Deployment note: single-homed boxes never see this; dual-homed setups need
  `arp_ignore`/`arp_filter` or split subnets. Secondary note: NM powersave adds ~80–300 ms inbound
  wake latency — a payload decision (off for server duty vs on for power).
- **WoL capability confirmed**: `end0` supports `ug` (magic packet included), currently disarmed —
  the wake experiment itself needs a human near the power plug.
- **BT mgmt path**: controller powered and manageable (full settings incl. LE, secure-conn, CIS);
  pairing still needs the physical remote.

### 2026-08-07 — the restructure: `firmware/{common,r69,h96}` + one parameterized builder

The repo grew its second board properly:

- **`firmware/common/`** — byte-shared: `u-boot.itb`, the IR + RK630-PHY DKMS dirs and setup scripts
  (r69-named packages kept intact — both boards run them today), `fetch-dkms-src.sh`, the
  kernel-prepare hook, the power drop-ins.
- **`firmware/r69/`** — everything R69, content intact (only `payload.list` src paths remapped);
  `board.conf` extracted (vars + two hooks) reproducing the old build behavior exactly.
- **`firmware/h96max/`** — the new payload, dramatically smaller per the audit: `h96-firstboot`
  (u-boot hold + three DKMS builds, no AIC dance, no mac-pin, no BT attach),
  `seekwave-swt6621s-setup` + pinned-source fetch (`b1b15016`), the five-file firmware set with a
  provenance README (K3B chip code + this box's calibration), module autoload, NM-wifi-only conf,
  renamed LED hooks, `h96-{dtb-persist,platform-install,boardname,motd}`.
- **`build-image.sh` is now generic**: `build-image.sh <base> [board] [out]`, board specifics
  sourced from `firmware/<board>/board.conf` (r69 stays the default — old invocations unchanged).
  `r69-update`/`build-uboot.sh` re-pathed; all scripts `bash -n` clean; both payload manifests
  verified complete; the Seekwave fetch tested live.
- Doc move: `HOW-IT-WAS-DONE.md` → **`docs/r69/worklog.md`** (references updated repo-wide).

Next: build the H96 image from a clean base and reflash — the from-zero integration test.

### 2026-08-07 — BT needs nothing: no start script, no MOTD, no config

Challenged the inherited assumption that BT needs boot-time help. Verified on the box: bluez 5.82
with a **completely stock `main.conf`** powers `hci0` automatically (`AutoEnable=true` has been the
bluez default since 5.65), and `skwbt` registers the controller at module load — no attach, no
rfkill, no config. The R69's `r69-bt` machinery existed for a UART chip behind a stolen console;
none of that maps here. Dropped from the H96 payload: the bluez block in `h96-firstboot` and the
`h96-motd-bluetooth` hint (a "apt install bluez" line in the README replaces it). The payload
shrinks again.

### 2026-08-07 — near-twin scripts: kept per-board, narratives trimmed

`led-shutdown`, `led-sleep`, `dtb-persist`, `platform-install` exist for both boards differing in
one real detail each (LED sysfs names; the `/usr/local/share/<board>/` path). Decision: **keep them
per-board** rather than absorbing the differences behind self-skipping writes and globs — explicit
beats clever for four ten-line files — but strip the narrative comments down to one-line whys (the
stories live in `docs/`, not in scripts). Applied to both boards' copies.

### 2026-08-07 — naming settles: `rk35xx-` for the mechanism, boards ship data

The insight that ended the naming debate: **scripts fork on kernel-family boundaries, not board
boundaries** — a new rk35xx box should cost a DTB + idbloader, nothing else. Implemented:

- `common/` mechanism is now family-named: `rk35xx-firstboot` (**data-driven** — holds u-boot, then
  builds _every_ staged `/usr/src/*/dkms.conf`, so boards choose drivers by what their payload
  stages, and already-installed packages like Armbian's v4l2loopback are skipped),
  `rk35xx-{dtb-persist,platform-install,boardname,led-shutdown,led-sleep,kernel-prepare}` + the
  power drop-ins. Identity became data: `/usr/local/share/rk35xx/` holds `board-name`, `board.dtb`,
  and the loader pair.
- The H96 DTB got one more graft: LED node names normalized to `power`/`standby`, so
  `/sys/class/leds` means the same thing family-wide and the LED hooks are genuinely shared.
- The H96 payload is now almost pure data: firmware blobs, autoload list, NM conf, DKMS build files,
  board-name — plus family-script references. Its per-chip setup script dissolved into the generic
  firstboot loop.
- R69: **destinations untouched** (deployed boxes unaffected); its manifest now sources the
  family-named common files where content is identical (LED hooks, kernel-prepare, power confs).

### 2026-08-08 — eMMC write path: 3 GiB CRC-verified, then the bytes put back

The user green-lit surgical eMMC testing. Method: the free 2 GiB tail of `userdata` (not actually
zero — f2fs scatters metadata — so the plan upgraded to **restore-from-backup** afterward), fio with
direct I/O and CRC32C verification. Results: sequential **read 91.6 MB/s** (the HS200/100 MHz
ceiling in practice), sequential **write 45–48 MB/s sustained**, random 4K **3.4k/4.0k IOPS**
read/write, and — the number that matters after the R69's HS400ES saga — **3 GiB written across two
passes with zero verify errors**. The region was then restored from `emmc-full.img` over SSH and
md5-verified at three windows including the device tail. Net effect on Android: none. Checklist:
eMMC writes ✔, capacity honesty ✔ (point-test grade).

### 2026-08-08 — SD vs eMMC benchmark: the migration question answered with numbers

Same fio battery as the eMMC session, file-based on the SD rootfs (Samsung `JC1S5` 64 GB at SDR104).
Side by side:

| Metric           | SD (SDR104)  | eMMC (HS200)   | eMMC advantage |
| ---------------- | ------------ | -------------- | -------------- |
| Sequential read  | 70.3 MB/s    | 91.6 MB/s      | +30%           |
| Sequential write | 30.2 MB/s    | 45–48 MB/s     | +55%           |
| Random 4K read   | 3,666 IOPS   | 3,373 IOPS     | wash           |
| Random 4K write  | **623 IOPS** | **3,983 IOPS** | **6.4×**       |

(Methodology skew: SD measured through an ext4 file, eMMC on the raw partition — irrelevant at the
size of the 4K-write gap.) The R69 doc's rule was "migrate only if the eMMC actually beats _your_
SD" — here it does, exactly where a root filesystem lives (apt, journals, databases are random-write
workloads). **Verdict: this box is worth migrating to eMMC** whenever the trade (losing on-device
back-to-stock; the off-device backup covers restore) is acceptable — and the write path +
`armbian-install` override are already proven/shipped.

### 2026-08-08 — catch-up: items that had landed outside the worklog

- **GPU, one level deeper**: headless EGL contexts create on real hardware — `eglinfo` reports
  `renderer: Mali450` on the GBM and Surfaceless platforms (no llvmpipe fallback). Drawn frames
  still pending the HDMI session.
- **`r69-update`/`r69-deploy` audited against the restructure**: functionally unaffected (all
  destinations unchanged, the script travels with the layout). One self-healing edge: an old on-box
  script running `--pull` aborts cleanly at its manifest check, and the already-refreshed clone
  succeeds on rerun. Fixed along the way: a stale error-message path, and `r69-deploy`'s tar
  shipping `uboot-build/` + `backup*/` (now excluded).
- **Doc moves**: `firmware/*/DTB.md` → `docs/r69/dtb.md` + `docs/h96max/dtb.md`; references updated.
- **DTB policy**: cosmetic edits reverted (factory `model` string restored) and the rule codified in
  `docs/h96max/dtb.md` — every DTB edit must have a functional consumer. Display identity lives in
  the payload (`board-name`), the only identity edit in the DTB is the `compatible` prepend that
  keys Seekwave's board-specific firmware lookup.
- **Naming settled**: board name **H96 Max** (LEFFOT) in all configs; the confusing "H313" retail
  suffix lives in docs only.

Repo-rename readiness: GitHub renames redirect old URLs, so deployed `r69-update --pull` survives a
rename; to end the redirect dependency, the updater now re-points its clone's origin at `REPO_URL`
before pulling — after a rename (+ `REPO_URL` bump in the same commit), boxes converge onto the new
URL within two update runs. The old repo name must never be reused.

### 2026-08-08 — rename-readiness executed: redirects verified, sources debranded

The four-point plan: **(1)** git redirect behavior confirmed empirically — `ls-remote`/`clone`/
`pull` all follow GitHub rename redirects (tested on `docker/fig` and
`rust-analyzer/rust-analyzer`), so deployed updaters survive a rename; **(2)** the re-point-origin
one-liner documented in `docs/r69/worklog.md` (with the one-time layout-abort note); **(3)** `r69-`
branding removed from repo _sources_ — `firmware/r69/` files renamed (`firstboot`, `bt`, `mac-pin`,
…), `ir/r69.patch` → `ir/shared-irq.patch`, comment scrubs in the family files — while the manifest
keeps every _destination_ name identical, so images built by the previous and new repo versions are
byte-equivalent; the surviving `-r69` strings are the on-box/DKMS contract (package names, service
dests, `/usr/local/share/r69/`), which byte-identity requires; **(4)** no quick-fix link in the
primary README — the redirect makes it unnecessary.

### 2026-08-08 — the last r69 leaves the H96: neutral DKMS sources, legacy names generated on the fly

The final naming requirement: **an installed H96 must contain no `r69` in any service, package, or
driver name** — while the R69 image keeps every legacy name for its deployed fleet. Done by
inverting the source of truth:

- `common/ir/*` and `common/ethphy/*` are now **neutral** (`rockchip-pwm-remotectl-rk35xx`,
  `rk630-phy-rk35xx`, driver `remotectl-pwm-rk35xx`, patch renamed `shared-irq.patch`); the H96
  payload stages them under rk35xx names, plus a family `modules-load.d/rk35xx.conf` (IR + PHY
  autoload; the R69-style live PHY handover is a first-boot nicety gap, noted).
- The **R69 build generates its legacy names on the fly** — `board_stage_dkms` and `r69-update` both
  sed the fetched driver + build files (`s/rk35xx/r69/g`, driver-name included) into the historical
  `-r69` identities. **Byte-identity proven**: all five generated files diff clean against the
  pre-change originals from git HEAD, so old-repo and new-repo R69 images are equivalent.
- Verified: `grep -c r69 firmware/h96max/payload.list` → **0**. (The live test box still carries
  hand-installed r69-named DKMS from bring-up — the clean reflash erases that.)

Decision, deferred: the repo will be renamed **`rk35xx-tvbox-armbian`** (one-word "tvbox", matching
the DT compatibles). All rename-day prep is in place; execution parked.

Dropped from the payload on second look: `nm-wifi-only.conf`. The image ships no NetworkManager, so
a config for it is opinion, not board data — the wired-stays-networkd / Wi-Fi-via-NM convention (and
the dual-manager footgun it guarded) moves to documentation. For the record, the conf that worked on
the test box: `[keyfile] unmanaged-devices=*,except:interface-name:wlan0` in
`/etc/NetworkManager/conf.d/`, then `sudo nmcli --ask device wifi connect "<SSID>"`.

Correction (2026-08-08): the source-filename debranding inside `firmware/r69/` overshot the request
and is reverted — the principle is **repo filenames mirror the names installed on disk**.
`firmware/r69/` files carry their `r69-` prefixes again (incl. the full
`rockchip-pwm-remotectl-r69-setup` / `rk630-phy-r69-setup` names, now board-local); abstraction
(`rk35xx-`, neutral DKMS sources, on-the-fly legacy generation) applies to `common/` and new boards
only.

### 2026-08-08 — correction: "output-only console" was probably our wiring, not their software

Serial input has never worked on this box — but crucially **not even under Armbian**, where a
`serial-getty` on `ttyS0` was provably listening, and the U-Boot `Hit any key` countdown in our own
capture ran to zero. Input dying identically across three software layers (BootROM-era U-Boot,
Armbian getty, stock Android) points at the **physical RX path**, not a missing Android console
service — the earlier "Android 14 build without a console service" claim is downgraded to
unverified. Prime suspects: test-hook contact on the small plated holes, or the classic TV-box
unpopulated series resistor in the RX path (console talks, you can't talk back).

Diagnosis plan for the next serial session: adapter TX↔RX loopback first; measure both pads vs GND
at idle (UART lines idle **high** ~3.3 V — TX solid; an RX pad at ~0 V/floating indicates a missing
pull/DNP resistor or wrong pad); with the adapter connected its idle TX should drive the RX pad to
3.3 V; and the login-free input test is interrupting the U-Boot autoboot countdown.

### 2026-08-08 — serial resolved: it was the wiring — both directions work

A recheck of the pins settled the serial-input mystery: **the console works in both directions.**
The whole "output-only console" narrative — including the "Android 14 without a console service"
claim — traced back to a wiring/contact issue on the rig, exactly as the diagnosis entry suspected.
Consequences:

- The `ttyS0` Armbian console is fully usable (login incl.) — checklist ticked.
- U-Boot console access (autoboot interrupt) is now available for future boot-level debugging.
- Reopened historical question, optional: stock Android might have offered a root/fiq shell all
  along — testable any time by ejecting the SD (the eMMC Android is intact) if the curiosity ever
  itches. The port no longer needs it.

### 2026-08-08 — toothpick button: works, first hands-on item ticked

`evtest` on the `adc-keys` device (factory node, identical to the R69's — SARADC ch1) captured 10
clean `KEY_VOLUMEUP` press/release pairs. Same story as the R69: nothing in Armbian consumes
`KEY_VOLUMEUP` headless, so it's a **free remappable button** (rebind `linux,code` in the DTB or
handle `event*` in userspace) — and, independently at the firmware level, the BootROM reads it at
power-on for maskrom/recovery.

### 2026-08-08 — bundled remote: full keymap over IR, no pairing — and its power button wakes the box

Stock Android insists the remote "pairs over Bluetooth", so the plan treated it as BT-first. Testing
said otherwise: with the patched `remotectl` DKMS bound (`/dev/input/event8`, the `ffa90030.pwm`
device), **every button on the remote decodes over plain IR, unpaired** — the factory DTB's usercode
table (`0xfb04`) covers the whole layout. BT pairing drops from "primary input, must-do" to an
optional voice-mic-only item.

The full keymap, captured via `evtest` (README-ready):

| Button            | Keycode                                          |
| ----------------- | ------------------------------------------------ |
| Power             | `KEY_POWER`                                      |
| Hamburger (menu)  | `KEY_MENU`                                       |
| Voice (mic)       | `KEY_F14`                                        |
| Cog (settings)    | `KEY_F13`                                        |
| D-pad             | `KEY_UP` / `KEY_DOWN` / `KEY_LEFT` / `KEY_RIGHT` |
| OK (d-pad center) | `KEY_REPLY`                                      |
| Back              | `KEY_BACK`                                       |
| Home              | `KEY_HOME`                                       |
| Backspace         | `KEY_BACKSPACE`                                  |
| Volume +/−        | `KEY_VOLUMEUP` / `KEY_VOLUMEDOWN`                |
| Mute              | `KEY_MUTE`                                       |
| P +/− (channel)   | `KEY_CHANNELUP` / `KEY_CHANNELDOWN`              |
| YT / NF / PV / GP | `KEY_F6` / `KEY_F7` / `KEY_F8` / `KEY_F9`        |
| Mouse             | `KEY_TEXT`                                       |

**Power button pressed → the box powers off**, and the serial trace settles the whole power model in
one shot. The path is exactly the shipped design: logind's `HandlePowerKey=poweroff` (the
`zz-rk35xx-powerkey.conf` default) runs a clean shutdown, then BL31 prints `virtual poweroff` with
the GPIO interrupt-enable masks and `IRQ_EN: 86` — the textbook no-PMIC "off", byte-for-byte the
R69's behavior: the SoC parks in ATF with wake sources armed, "off" still sips power, unplug is the
only true off. The trace looked alarming but is healthy.

**Pressed again, the power button boots the box back up.** Wake trace: `pmu_int_st: 00000001`,
`irq_st: 64-00400000`, `pwm_key: f708fb04` — key `0xf7` under usercode `0xfb04`, i.e. exactly the
power scancode from the factory IR table. That closes the loop on the `remote_support_psci = <1>`
DTB graft (factory shipped 0): ATF-armed IR wake works end to end — off → remote press → full cold
boot (~10–15 s).

One blemish in the shutdown log: `r69-led failed with exit status 2`. Stale mid-bring-up state on
the test box, not a recipe bug — the hand-installed shutdown hook writes the renamed
`power`/`standby` LEDs, but the box was still running a DTB from before the LED-rename graft (LEDs
named `work-green`/`work-red`), so both redirections miss and the shell's redirection-failure status
(2) becomes the hook's exit code. The clean H96 image build + reflash erases it. Hardening
candidate, noted but not applied: end the LED hooks with `exit 0` so absent LED names can never fail
a shutdown/sleep unit.

Still open on the power checklist: suspend-to-RAM (deep `mem`) with IR/WoL resume, and the R69's
double-fire trap — verify the wake press doesn't also reach logind as `KEY_POWER` once the system is
up (a cold boot outlives the press, so the risk is really about suspend resume).

### 2026-08-08 — LEDs hands-on: power = blue, standby = red; full power-cycle choreography verified

Prep first: the test box was still booting an **intermediate hand-migration DTB** — `fdtfile`
pointed at `rockchip/board-h96.dtb` (an Aug 7 build predating the LED rename, LEDs still
`work-green`/`work-red`), which is also why the earlier poweroff logged
`r69-led failed with exit status 2`. Synced the final `firmware/h96max/board.dtb` everywhere it
matters (`/boot`'s `board.dtb`, the stale `board-h96.dtb`, the dtb-persist master), aligned
`fdtfile=rockchip/board.dtb` to the shipped-image contract, and rebooted onto it: `/sys/class/leds/`
now shows `power`/`standby`. (Debug detour for the record: a first fix attempt silently did nothing
because a reboot had emptied `/tmp` under the staged copy and the `&&` chain died on the missing
file — the "revert" was never a revert, just a command that never ran. Second attempt sourced the
on-box persist master instead.)

Hands-on results, all by eye:

- Both diodes **independently drivable** via `sysfs`, polarity correct (`1` = on, `0` = off) — the
  factory `gpio-leds` pins survive the rename graft untouched.
- **Color map: `power` = blue, `standby` = red.** The factory node names (`work-green`/`work-red`)
  were half-wrong — there is no green LED on this box.
- **Power-cycle choreography works end to end**: running = pure blue; remote power press → clean
  shutdown → **red while "off"** (the shutdown hook's writes stick, `retain-state-shutdown` holding
  them through the kernel's device shutdown); remote press again → boot → pure blue once the driver
  binds. The `r69-led` exit-2 error is gone with the matching LED names.
- One cosmetic quirk: **early boot shows both LEDs dimly lit** (slightly blue + slightly red,
  drifting red-ish) until the kernel `gpio-leds` driver probes and `default-state` snaps it to pure
  blue. Expected physics — nothing drives the pins between BootROM and driver bind, so they float
  high-impedance and both LEDs leak. Fixing it would mean driving the pins in u-boot; not worth it.

Remaining LED item: red-in-standby over suspend (`retain-state-suspended` + the sleep hook), folded
into the suspend batch.

### 2026-08-08 — HDMI hands-on: display works; PC-monitor pixel-clock quirk diagnosed

First plug-in was on a **BOE 13.5″-class 3:2 portable monitor** (native 2256×1504), and it looked
broken: no boot log, a "white dotted fence" band across the right ~10% of the screen, the monitor
reporting ~37 Hz. The console was actually there all along (fbcon + `getty@tty1` active on
`/dev/fb0`) — the _mode_ was broken, not the console plumbing.

Diagnosis from `dmesg`: the kernel honored the EDID-preferred 2256×1504@60, which needs a
**non-standard 235.7 MHz pixel clock** — and the vendor clock driver can only synthesize the
standard HDMI TV rates (`set dclk_vop0 to 235700000, get 148500000`, plus
`rockchip_drm_dclk_round_rate: clk_hw … may be NULL` and dw-hdmi's `Rate 235700000 missing`).
Result: 2256×1504 timings driven at the 1080p clock → 60 × (148.5 / 235.7) ≈ **37.8 Hz**, exactly
what the monitor OSD showed, with the starved sync painting the dot fence. `modetest` at
1920×1080-60 got its clock **bit-exact** (`get 148500000`), confirming the theory (the visual blip
was short — `modetest` exits when its stdin closes over non-interactive SSH).

Fix on the test box: append **`video=HDMI-A-1:1920x1080@60`** to `extraargs` in `armbianEnv.txt` →
clean, stable 1080p60 console, login prompt visible, no artifacts.

Decision — **not baked into the image**: TVs (the native habitat of these boxes) negotiate standard
rates (25.2/74.25/148.5/297/594 MHz) and should be unaffected, while a baked-in pin would silently
cap 4K TVs at 1080p. Documented instead as a family-wide known quirk (symptom: garbage/dotted image

- odd refresh on a PC monitor; fix: the one-line `video=` pin). Revisit if a real-TV test ever
  surprises. "The R69 never had this" is expected — the R69 only ever met TVs; same silicon, same
  kernel, same limitation if given this monitor.

Also for the record: five `ddc read failed` EDID re-read warnings during connect — harmless here
(the EDID parsed; identified the panel as BOE model 8577), noted in case a flaky-EDID display ever
needs `drm.edid_firmware`.

### 2026-08-08 — GPU on screen (glmark2 score 41) and HDMI audio, both confirmed by eye and ear

**3D on a real display, finally.** `glmark2-es2-drm` (the DRM/KMS flavor — the plain `glmark2-es2`
package wants X11) ran the full suite straight to HDMI: textured cubes, the cat model, jellyfish,
desktop-effect scenes. **Score: 41** on Mali-450 at 1080p. Representative scenes: `pulsar` 59 FPS,
`conditionals` 60–61, `buffer`/`ideas` ~44, `shadow` 28, `jellyfish` 18, and the heavy ones crawl —
`refract` (the glass bunny) 8 FPS, 5×5-kernel `effect2d` 4 FPS. That profile is exactly right for
this GPU class: fill-rate-bound compositing is fine, heavy per-fragment shader work is not. One
scene is unsupported by the hardware, not broken: `terrain` needs vertex texture fetch and Mali-450
reports `GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS = 0`.

Verdict: **lima is genuinely usable for a desktop/kiosk workload** on this box — good enough for
compositing, UI, and video overlay; not for shader-heavy 3D.

**HDMI audio works, channel mapping correct.** `speaker-test -D plughw:0,0` front-left then
front-right, each heard from the correct side, followed by a synthesized 440 Hz / 660 Hz two-tone
stereo clip through `aplay` — audible and clean. Then a real **MP3 played end to end**
(`mpg123 -a plughw:0,0`), which also exercises decode + rate conversion rather than just raw PCM
tones. The R69's "no ELD" caveat holds here too: absent ELD data doesn't stop audio.

Remaining in this batch: HDMI-CEC (needs a real TV — portable monitors don't speak it) and the AV
jack. VPU decode stays untested-by-choice.

### 2026-08-08 — boot logs on both consoles: what's possible, and what isn't

Question raised while the HDMI was hooked up: can the whole boot log land on serial **and** screen?
Answer: mostly yes, and the image already had the plumbing — what hid it was verbosity, not routing.

`console=display` in `armbianEnv.txt` makes `boot.cmd` emit `console=tty1`, and our `extraargs`
appends `console=ttyS0,1500000`, so **both consoles are registered and kernel printk goes to both**.
The image ships Armbian's `verbosity=1` (= `loglevel=1`, emergencies only), so the screen looked
empty. `verbosity=7` verified live: full kernel boot log on both, ending at a login prompt on each
(`getty@tty1` + `serial-getty@ttyS0` both active).

| Boot stage                      | Serial | HDMI | Why                                                      |
| ------------------------------- | ------ | ---- | -------------------------------------------------------- |
| BootROM / TPL / SPL / U-Boot    | yes    | no   | no video driver in `generic-rk3528_defconfig`            |
| Kernel `earlycon` (first ~1 s)  | yes    | no   | `earlycon=uart8250` is a UART driver by definition       |
| Kernel printk, DRM probe onward | yes    | yes  | both `console=` devices get printk (needs verbosity ≥ 4) |
| systemd unit status             | yes    | no   | userspace writes `/dev/console` = one device (last wins) |
| Login prompt                    | yes    | yes  | separate gettys, not console routing                     |

Two structural limits, both accepted: U-Boot would need `CONFIG_VIDEO` + a VOP/HDMI driver to paint
anything (not worth it), and `/dev/console` is inherently a single device — systemd status could be
moved to HDMI by ordering `console=tty1` last, but that would take it off serial, the channel that
matters when things are broken. **Decision: keep `/dev/console` on serial; leave the image's quiet
`verbosity=1` default.** `verbosity=7` is the documented debug knob (one line in `armbianEnv.txt`,
no rebuild) — proven to work when needed.

### 2026-08-08 — USB HID + HDMI console = the box is usable with no serial cable at all

A Logitech Unifying receiver on the USB 2.0 port enumerated cleanly (`046d:c52b` on the
`ff140000.usb` controller) and `hid-generic` bound all four of its interfaces: keyboard (`event3`,
`kbd` handler), mouse (`event4`, `mouse0`), plus Consumer/System Control. `evtest` captured 45 key
events and mouse motion, and — the part that actually matters — **typing reaches the HDMI console
login prompt**. Together with the working display, that makes this box fully operable as a normal
computer: keyboard + screen, no serial, no SSH.

Still open in this batch: a real SuperSpeed device on the USB 3.0 port with a throughput measurement
(the R69 only ever verified the root hub existed), and the optional maskrom/USB-A-to-A unbrick path.

Port map, established by moving the same receiver between ports:

| Physical port | Controller      | Buses / root-hub speeds                      |
| ------------- | --------------- | -------------------------------------------- |
| USB 2.0       | `ff140000.usb`  | OHCI 12 M (bus 1) + EHCI 480 M (bus 3)       |
| USB 3.0       | `fe500000.dwc3` | xHCI 480 M (bus 2) + xHCI **5000 M** (bus 4) |

Kernel log is clean on both: no resets, no `-71`/`-110` transaction errors, no over-current, and the
only `USB disconnect` is the deliberate unplug. Two boot-time messages are benign and **inherited,
not ours** — `rockchip-usb2phy ffdf0000.usb2-phy: error -ENXIO: IRQ index 0 not found` appears
verbatim in the stock Android dmesg, and `phy-supply … otg-port failed` just means no
software-switched VBUS regulator on the OTG port (consistent with OTG/UDC being unused here).

### 2026-08-08 — thermals: 60 °C peak under full load, 35 °C below the first trip

`stress-ng --cpu 4` for 5 minutes, closed case: **49 °C idle → 60 °C peak → 56 °C shortly after**,
holding the top OPP (1.416 GHz) the whole time with **no throttling events**. Trip points are 95 /
110 / 120 °C, so the box runs with a huge margin — unsurprising given the modest 4×A53 at 1.4 GHz,
but it does confirm the thermal pad landed correctly on reassembly and that a passive TV box case is
enough for sustained CPU work.

### 2026-08-08 — suspend-to-RAM works, IR wakes it, no double-fire; the WoL attempt was invalid

`systemctl suspend` → **`PM: suspend entry (deep)`**, box off the network, LED red in standby; 2m42s
later a press of the remote's power button resumed it. Everything came back intact:

- **Wi-Fi survived** — `wlan0` still associated on the same lease, no reconnect needed.
- **USB re-enumerated** — the Logitech receiver is back with all interfaces bound.
- **No double-fire.** The R69's trap (wake press also reaching logind as `KEY_POWER` → instant
  re-shutdown) does **not** happen here: the box resumed and stayed up.
- Two benign resume warnings, noted so they aren't re-investigated later:
  `xhci-hcd … xHC error in resume, USBSTS 0x411, Reinit` (controller reinitializes itself and the
  device works) and `[SKWSDIO INFO] skw_sdio_suspend_adma_cmd: timeout gpioin value=1` from the
  Seekwave driver (Wi-Fi still resumed fine).

**The Wake-on-LAN test was invalid and must be redone.** `ethtool -s end0 wol g` applied cleanly
(`Wake-on: g`, kernel logged `stmmac: wakeup enable`, and `ffbd0000.ethernet/power/wakeup` shows
enabled), but the magic packets went nowhere useful: the Ethernet cable was **unplugged** (`end0`
`NO-CARRIER`) and the box was on Wi-Fi, so the address I targeted — `fe:fd:fc:99:08:5f`, the one in
the Mac's ARP table — is **wlan0's** MAC, not `end0`'s (`86:33:37:fc:84:74`). Retest needs the cable
in and the correct MAC. (Timeline also rules out an accidental WoL success: the bursts were at ~30 s
and ~60 s into the sleep, the resume happened at 162 s, right when the remote was pressed.)

Also visible in this cycle: `rockchip-suspend not set wakeup-config for mem-ultra` — the factory
DTB's `rockchip-suspend` node is what tells ATF which wake sources to arm for the deepest sleep
state. Worth a look if WoL-from-suspend turns out not to work with the cable in.

### 2026-08-08 — the remote is dual-mode: BLE pairing works, and IR/BLE arbitrate cleanly

Paired the bundled remote over Bluetooth after all (it was parked as optional once IR proved
sufficient). **Pairing mode: hold left + right until the remote's LED blinks** — a steady red glow
comes first, the blink is the pairing state, and the glow ends the moment a host connects.

It advertises as **`18:24:39:1D:3D:E1` "Bluetooth remote"** (BLE, vendor `2b54:1600`) and bonds
cleanly: `Paired: yes / Trusted: yes / Connected: yes`, services GAP/GATT, Device Information,
**Battery**, **HID**, Scan Parameters, plus a vendor `0xfeb3` ("Taobao") service. One procedural
gotcha worth remembering: pairing fails with `org.bluez.Error.AuthenticationFailed` if the agent is
registered in a _different_ `bluetoothctl` invocation than the `pair` command — do
`agent NoInputNoOutput` → `default-agent` → `pair` in **one** session.

The bond registers **four HID input nodes** over uhid, and the split matters:

| Node               | What arrives                                        |
| ------------------ | --------------------------------------------------- |
| `Consumer Control` | every button (192 events captured)                  |
| `Mouse`            | **air-mouse motion** — `REL_X`/`REL_Y` (106 events) |
| `Keyboard`         | idle in practice (capability list only)             |
| `Bluetooth remote` | vendor node, idle                                   |

**BLE keycodes differ from the IR ones** — same buttons, different mapping, so anything binding keys
must handle both: OK is `KEY_SELECT` (IR: `KEY_REPLY`), home is `KEY_HOMEPAGE` (IR: `KEY_HOME`),
d-pad/volume/mute/channel keep their names, and the app row lands on `KEY_GAMES` / `KEY_SEARCH` /
`KEY_UNKNOWN` rather than the IR table's `KEY_F6`–`F9`.

**Arbitration is clean — no double-fire.** A 20 s simultaneous capture on the IR node (`event8`) and
the BLE node (`event9`) while pressing buttons: **50 BLE events, 0 IR events.** The remote
suppresses its IR transmitter while a BLE host is connected and falls back to IR when unpaired or
out of range. That's the ideal outcome: one press is always exactly one event.

Bonus the IR path can't offer: **battery level** (`Battery Percentage: 0x64` = 100%) via the BLE
Battery Service.

**Voice/mic button, answered the same session:** the key itself works (`KEY_SEARCH` over BLE), but
the microphone is **not usable out of the box** — `arecord -l` shows no capture device and BlueZ
exposes no audio transport for the remote. The audio rides that vendor `0xfeb3` GATT service (the
Android-TV voice-search protocol), i.e. a proprietary stream rather than BLE-audio/HFP, so it would
take custom userspace to decode. Closing this as "key yes, mic needs software" rather than leaving
it open research — the same answer almost certainly applies to the R69's voice TODO.

### 2026-08-08 — clean H96 image built and verified offline (pre-flash)

First real exercise of the restructured builder: `./build-image.sh <rock-2f base> h96max`. It
completed with no errors, and every check that can be made without booting passes:

- **Loader region byte-identical** to the repo: idbloader @64 and `u-boot.itb` @16384 both md5-match
  `firmware/h96max/factory_idbloader.bin` and `firmware/common/u-boot.itb`.
- **DTB** in `/boot/dtb-*/rockchip/board.dtb` md5-matches `firmware/h96max/board.dtb`, and
  `armbianEnv.txt` carries `fdtfile=rockchip/board.dtb` + our `ttyS0` console args.
- **Identity**: hostname `h96`, `BOARD_NAME="H96 Max"`, and `/usr/local/share/rk35xx/` holding all
  four files (`board-name`, `board.dtb`, `factory_idbloader.bin`, `u-boot.itb`).
- **The zero-r69 contract holds**: no `r69`-named file anywhere in the image. The installed set is
  `rk35xx-firstboot` / `rk35xx-boardname` in `/usr/local/sbin`, `rk35xx-led` in both
  `system-shutdown` and `system-sleep`, `00-rk35xx-kernel-prepare` + `rk35xx-dtb-persist` in
  `/etc/kernel/postinst.d`, `zz-rk35xx-{powerkey,suspend}.conf`, `99-rk35xx-boardname`, DKMS trees
  `rockchip-pwm-remotectl-rk35xx-1.0` + `rk630-phy-rk35xx-1.0`, and the seekwave tree.

What only a flash can prove (and what the reflash is really for): offline first-boot DKMS builds,
the identity/apt hooks under a real upgrade, `dtb-persist` across a kernel update, and the
`linux-u-boot-*` apt hold.

### 2026-08-08 — what else did the vendor disable? (and a failed experiment that cost the boot)

Question worth asking once the obvious peripherals work: the factory DTB disables a lot of nodes —
is that silicon that doesn't exist, or silicon the vendor didn't use? **Almost always the latter.**
Rockchip's SoC-level `.dtsi` declares every IP block `status = "disabled"` and each board's `.dts`
enables what's wired. We had already proven this ourselves: `uart0` ships disabled, and enabling it
is one of our grafts — the console works on the three pads.

Sorting the factory tree's disabled nodes:

- **Nothing wired on this PCB** (enabling is pointless): `i2c0`–`i2c7`, `spi0`/`spi1`,
  `uart1`/`uart3`–`uart7`, `pwm4`–`pwm7`, `sdio0`, and the audio side (`sai1`, `pdm`,
  `es7243_sound`, `bt_sco`/`bt_sound`, mic array). The controllers exist; the components and pins
  don't.
- **Not useful even though internal**: `hdcp2` (no HDCP userspace on Linux), `mailbox`,
  `hwspinlock`, `secure-otp`, `gpu_bus` (QoS tuning, risk without measurable gain), the disabled
  1.184 GHz OPP (redundant next to 1.2 GHz), and `wireless-wlan`/`wireless-bluetooth` (vendor rfkill
  plumbing the Seekwave driver replaces).
- **Genuinely interesting, no wiring needed**: the **watchdog** and **CPU idle**.

The cpuidle finding was the striking one. The box has **no CPU idle states at all** —
`cpuidle/current_driver` reads `none`, cores only ever spin in WFI, which fits the warm ~49 °C idle
(the board's cooling is one aluminum slab glued across eMMC, RAM **and** the SoC — passive and
mediocre). Cause: the factory tree defines two idle states with **byte-identical parameters**
(`psci-suspend-param = 0x10000`, 120/250 µs latencies), yet `CPU_SLEEP0` (referenced by cpu0/cpu1)
is `disabled` while `CPU_SLEEP1` (cpu2/cpu3) is `okay`. The PSCI cpuidle driver requires valid
states on _every_ CPU, so that single disabled node disables idle **system-wide**.

**The experiment failed: flipping both to `okay` left the box unbootable** (no network, no SSH). The
repo was reverted immediately and verified — the restored `board.dts` recompiles **bit-identical**
to the shipped `board.dtb`, so nothing bricking persists in the tree.

Two mistakes worth naming: **both nodes were changed in one DTB**, so the failure can't be pinned on
either; and the deploy overwrote the on-box `dtb-persist` master as well as `/boot`, so a partial
revert wouldn't have been enough.

Reading the evidence afterwards, the watchdog is the unlikely culprit — enabling it only creates
`/dev/watchdog` with the timer **stopped** (a dw_wdt starts counting when userspace opens and pings
it, and `RuntimeWatchdogSec` is `off`). Cpuidle is the plausible one: flipping that node didn't just
add idle for two cores, it activated CPU idle on this box **for the first time ever**, exercising a
PSCI `CPU_SUSPEND` path our BL31 v1.21 had never run. If that call doesn't return, the box hangs the
moment the scheduler idles — milliseconds into boot, which is what we observed. And the
interpretation flips on one detail: the **R69's factory DTB carries the identical asymmetry**. Two
different boards with the same "one of two identical states disabled" pattern is not copy-paste
sloppiness — it reads as a deliberate BSP kill switch for a feature that doesn't work with
Rockchip's ATF.

Not a dead end, just a bisect away — retry method (one change per DTB, serial attached, known-good
DTB ready for _both_ copies). Serial also discriminates the two failure modes cleanly: a cpuidle
hang stops printing and stays silent, while a watchdog reset loops with the U-Boot banner
reappearing.

### 2026-08-08 — docs restructured per-board, mirroring `firmware/`

`docs/` now uses the same per-board layout as `firmware/` and `stock/`, so a board's code, evidence,
and prose all live under the same name:

| Was                    | Now                      |
| ---------------------- | ------------------------ |
| `HOW-IT-WAS-DONE.md`   | `docs/r69/worklog.md`    |
| `docs/r69_dtb.md`      | `docs/r69/dtb.md`        |
| `docs/h96-max-h313.md` | `docs/h96max/worklog.md` |
| `docs/h96_dtb.md`      | `docs/h96max/dtb.md`     |

References were updated repo-wide (`README.md`, `build-image.sh`'s `docs/<board>/dtb.md` pointer,
`build-uboot.sh`, `TODO.md`, `firmware/r69/r69-mac-pin`, and the docs' own cross-links, which are
now relative — `../r69/worklog.md` from the H96 side). Swept up on the way: two `.md`
double-suffixes left by a rename pass, one historical line mangled into "`r69-worklog.md` →
`r69-worklog.md`" (it was always `HOW-IT-WAS-DONE.md` → the R69 worklog), and stale `stock/h96/` +
`firmware/h96/` paths that predated the `h96max` naming decision.

Same treatment for the eMMC dumps: `backup-r69/` + `backup-h96max/` → **`backup/r69/` +
`backup/h96max/`**, so all four per-board trees now share one layout — `docs/<board>/`,
`firmware/<board>/`, `stock/<board>/`, `backup/<board>/`. The R69 docs' generic
`backup/emmc-full.img` references became board-scoped `backup/r69/emmc-full.img` (they predate there
being a second box), and `.gitignore`'s loose `/backup*` tightened to `/backup/`.

### 2026-08-08 — in-place update generalized: `rk35xx-update` / `rk35xx-deploy`

The R69 had `r69-update` (apply the repo to a running box, no reflash) and `r69-deploy` (push the
repo over SSH and run it); the H96 had nothing, and `r69-update` was hardcoded to R69 in seven
places. Generalized, and the rename groundwork made it small: every board except the R69 shares the
same on-disk names, so the generic updater needs **one** knob.

- **`BOARD_PREFIX` in `board.conf`** (`r69` / `rk35xx`) drives every path the updater touches:
  `/usr/local/share/$P`, `/usr/src/rockchip-pwm-remotectl-$P-1.0`, `/usr/src/rk630-phy-$P-1.0`,
  `/etc/kernel/postinst.d/$P-dtb-persist`, `/usr/local/sbin/$P-boardname`. Service restarts come
  from `BOARD_UPDATE_RESTART` / `BOARD_UPDATE_TRY_RESTART` (the R69's `mac-pin` + `bt`; empty
  elsewhere — the `try-` distinction preserves the ghost-hci0 lesson).
- **The legacy sed became free.** The DKMS sources are rk35xx-named, so rewriting them with
  `s/rk35xx/$P/g` is the R69's legacy rename **and a no-op on every other board** — one code path,
  no special case.
- **DKMS rebuild**: boards shipping per-driver setup scripts (only the R69) go through them,
  preserving exact behavior; others get an inline `dkms remove --all` → `add`/`build`/`install` (the
  H96 has no setup scripts — `rk35xx-firstboot` skips already-installed modules, so it can't be
  reused for updates).
- **Board auto-detection**: a new one-line `board-id` file in the identity dir
  (`/usr/local/share/rk35xx/board-id` = the `firmware/<board>/` key). Falls back to `r69` when only
  the pre-`board-id` layout is present, so the R69 image is unchanged. `--board` overrides.
- **`r69-update` / `r69-deploy` are now 5-line shims** that `exec` the generic ones with
  `--board r69`. The historical path deployed boxes invoke (`/usr/local/share/r69/repo/r69-update`)
  keeps working.

**Regression-tested by rebuilding the R69 image and comparing every payload file against the
pre-restructure build**: loader regions byte-identical, and all 33 payload files functionally
identical — the only remaining textual diffs are whitespace and comments. That closes the last
**functional** R69 delta, the `kernel-prepare` log path: the hook is now self-naming
(`me=$(basename "$0" | sed 's/^00-//')`), which resolves to `/var/log/r69-kernel-prepare.log` on the
R69 — its historical path — and `/var/log/rk35xx-kernel-prepare.log` on the H96.

One upgrade hazard worth knowing: an R69 box running the **old** `r69-update --pull` will replace
that script (86 lines → 5) mid-execution. Small scripts are usually read in one buffer so it should
pass, but if it aborts, just re-run `r69-update` — the shim then completes normally, and the updater
is idempotent.

### 2026-08-08 — serial log convicts cpuidle, clears the watchdog

The serial capture of the failed experiment (`stock/h96max/armbian-cpuidle-hang-serial.log`, 3
boots) settles what the bisect would have shown.

**Boot 1 — good DTB**: a full 37-minute session ending in a clean `systemd-shutdown: Rebooting.`
(the reboot that loaded the test DTB). **Boots 2 and 3 — test DTB**: both die at **~19 s**, in the
MMC/SDHCI init window (boot 2 at `sdhci-pltfm: SDHCI platform and OF driver helper`, boot 3 four
messages later at `mmc_host mmc1: card is non-removable`), **before any card enumerates** — no
`mmcblk0`, no rootfs, no userspace.

The failure mode is a **silent hang**, and that's the whole verdict:

- **No kernel panic, no oops, no reset.** After boot 3 hangs the box just sits there — there is no
  fourth SPL/DDR banner in the capture. The reset between boots 2 and 3 was a manual power cycle
  (full DDR retraining), not an automatic one.
- **The watchdog is exonerated.** `dw_wdt` never prints, never registers, and nothing ever resets
  the box on a timer. A watchdog failure would look like the exact opposite: a _loop_, with the
  U-Boot banner reappearing on a fixed period. (The three `watchdog` hits in the log are the GMAC's
  unrelated "RX Mitigation via HW Watchdog Timer".)
- **CPU idle fits perfectly.** Hanging during MMC probe is the signature: card power-up and
  enumeration are the first place the kernel does substantial sleeping, so the first deep-idle entry
  through PSCI `CPU_SUSPEND` happens right there. The CPU never returns. The slight variance between
  the two boots (18.98 s vs 19.15 s) is the expected race over which core idles first.

**Red herring, worth writing down:** the `------------[ cut here ]------------` /
`WARNING … gpiolib-devres.c:327 devm_gpiod_put` traceback in `stmmac_mdio_reset` looks alarming and
appears right before the hang — but it is present in **all three boots, including the healthy
37-minute one** (only the reporting CPU differs). It is a pre-existing, benign warning in the
Ethernet PHY reset-GPIO path, unrelated to the DTB change and to the hang.

So the retry plan sharpens: **the watchdog can be enabled on its own with reasonable confidence**
(it needs a `RuntimeWatchdogSec` consumer to do anything at all), while `CPU_SLEEP0` needs a
different approach than flipping the status — a shallower `arm,psci-suspend-param`, or a newer BL31,
since the vendor's identical-but-disabled twin now looks like a deliberate kill switch for a PSCI
suspend path this firmware can't return from.

### 2026-08-09 — clean image boots, and the watchdog works (bisected, tested, shipped)

**The from-scratch install passed**, which is the integration test the whole restructure was waiting
on: all three DKMS trees built **offline** on first boot and loaded
(`rockchip_pwm_remotectl_rk35xx`, `rk630phy`, `skw_sdio_lite`/`swt6621s_wifi`/`skwbt`), the IR node
`ffa90030.pwm` came up, `linux-u-boot-rock-2f-vendor` is held, the loader override is in place, and
`find /etc /usr/local /usr/lib/systemd /usr/src -iname '*r69*'` returns **nothing** — the zero-r69
contract holds on a real filesystem, not just in an image. Hostname `h96max`,
`BOARD_NAME="H96 Max"`.

**Watchdog: retested alone, and it works.** One property changed, nothing else, exactly as the
post-mortem prescribed. `/dev/watchdog` + `/dev/watchdog0` appear, the box boots normally, and
`wdctl` reports a Synopsys DesignWare watchdog with a **fixed 44 s timeout** (`SETTIMEOUT`
unsupported, no magic-close — once opened it cannot be disarmed). A deliberate stop-petting test
**hard-reset the box**, so it bites for real. Now shipped on both boards, with
`RuntimeWatchdogSec=30` in `/etc/systemd/system.conf.d/` as the functional consumer; systemd takes
it at boot (`Watchdog running with a hardware timeout of 44s`) and `wdctl` then reports the device
busy because PID 1 holds it. That closes the cpuidle post-mortem's open question: **cpuidle was the
sole cause of the hang, the watchdog was innocent all along.**

Three things this session's testing shook loose, all fixed:

- **`e2rm` corrupts the image.** Deleting the stale `serial-getty@ttyFIQ0` symlink with `e2rm`
  produced a **multiply-claimed block** — `rockchip_pwm_remotectl.c` was handed block 101, already
  owned by filesystem metadata — so the kernel remounted the rootfs read-only and
  `armbian-firstlogin` failed on every write. `fsck` on the previous build passes cleanly, so the
  one added line was the cause. Replaced with a written file: an `/etc` unit carrying
  `ConditionPathExists=/dev/ttyFIQ0` and a no-op `ExecStart`, which outranks the template instance
  the wants-symlink points at and skips instantly instead of waiting 90 s. **`build-image.sh` now
  runs `fsck.ext4 -fn` before finishing and refuses to emit a corrupt image** (it also looks in
  Homebrew's keg-only prefix, and says so out loud when it can't verify).
- **Rebuilding the R69 DTB from its DTS is lossy.** `dtc -@` reproduces the H96 DTB byte-exactly,
  but the R69's shipped DTB was never produced by dtc from its DTS — a rebuild drops `__symbols__`
  labels and reorders properties (16 diff lines). Use **`fdtput`** for single-property edits there.
- **`mmcblk` numbering is not stable.** On this image the eMMC is **`mmcblk2`** and the SD is
  `mmcblk1`; on the previous one the eMMC was `mmcblk1`. Docs now tell you to identify the eMMC by
  its **`boot0`/`boot1` companions**, which SD cards never have, rather than by a remembered number.
- **The updater wasn't installed.** `rk35xx-update` lived only in a deployed checkout, so the
  README's "run it on the box" instruction had nothing to run. It now ships in the payload at
  `/usr/local/sbin/` on both boards (plus the `r69-update` shim on the R69).

### 2026-08-09 — running from eMMC, and the soft-brick guard is proven

`armbian-install` → "Boot from eMMC — System on eMMC" → ext4. Worked first time, and the box now
boots with **no SD card at all**: root is `/dev/mmcblk2p1`, 14.5 GB of the eMMC as a single
partition (the 14 factory Android partitions are gone — `backup/h96max/emmc-full.img` is the only
way back now), 12 GB free, boot in **18 s** (9.9 kernel + 8.2 userspace).

**The issue-#6 guard did its job — first real proof on hardware.** The loaders `armbian-install`
wrote to the eMMC are byte-identical to this board's own pair: idbloader `7c11da6f…` at sector 64
and `u-boot.itb` `c13ca928…` at 16384, both matching `/usr/local/share/rk35xx/`. Without the
`write_uboot_platform` override it would have written the ROCK 2F loaders, whose DDR config this
DRAM die can't run, and the box would boot nothing.

Everything survived the migration intact: hostname `h96max`, all five DKMS modules installed and
loaded, Wi-Fi up on the same lease, and the **watchdog still armed** — DT node `okay`,
`/dev/watchdog` present, `zz-rk35xx-watchdog.conf` carried across, and systemd holding it
(`Using hardware watchdog 'Synopsys DesignWare Watchdog'`, `wdctl` reports the device busy).

Note for anyone reading `armbian-install`'s menu: it does **not** show device names or sizes when
listing targets, only afterwards at the confirmation prompt — and on this image the eMMC is
`mmcblk2` while the SD is `mmcblk1`. Read that confirmation carefully.

### 2026-08-09 — the VPU was never reachable, and the reason was one string

Symptom, found while trying to use the box as a video edge node: **hardware encode fails on
everything**. Every coding type dies at `mpp_enc_hal_init could not found coding type`, and stock
ffmpeg quietly decodes on the four A53s — `-hwaccels` lists no rkmpp, `-c:v h264_v4l2m2m` returns
`-22`, and `/dev/video0..3` are all `uvcvideo`. The vendor kernel doesn't do V4L2 M2M at all: the
VPU is behind `/dev/mpp_service`, the MPP library ABI.

The instinct is to blame the chip or the DTB. Both are innocent. `rkvenc@ff780000` probes, its power
domain is on, its clocks are sane, and IRQ 67 increments once per encoded frame.

**It is `librockchip_mpp` failing to recognise the SoC.** `read_soc_name()` reads the whole of
`/proc/device-tree/compatible` and `check_soc_info()` substring-matches it against a hardcoded table
(`osal/mpp_soc.c`). Our factory tree says `rockchip,rk3518` — and **no MPP release has ever
contained an `rk3518` entry**. So it falls to `mpp_soc_default`, "unknown SoC", which assumes
`vdpu1`/`vdpu2` decoders and `vepu1`/`vepu2` encoders. This silicon has none of those encoders,
hence the error, and its real RKVDEC and JPEG decoders are never touched. There is no env override.

What settles the identity, all of it local evidence:

- our own `rkvdec`/`rkvenc` nodes are `rockchip,rkv-{de,en}coder-rk3528`
- stock Android boots `init.rk3528.rc` and binds an `rk3528-acodec` (`stock/h96max/dmesg.txt`)
- the R69 — same `35181001` SoC ID — has `rockchip,rk3528a` in _its_ factory root compatible, and
  Android there reports `ro.soc.model = RK3528`

So the box is an RK3528 badged RK3518, and the fix is to say so: **append `"rockchip,rk3528a"` to
the root compatible**, last, so every existing `rk3518` match still wins and the kernel merely gains
a fallback it already understands. The rebuilt DTB differs from the old one by that line alone.

The payoff is bigger than our own tooling: **no fork of MPP is needed any more.** Prebuilt rkmpp
stacks — Armbian's `rockchip-multimedia`, `jellyfin-ffmpeg-rockchip`, Kodi builds — go from
"impossible on this box" to "works", without a patch. Before this, the only route was hand-adding an
`rk3518` entry to `mpp_soc.c` and rebuilding the whole stack.

**Measured earlier on this box with that hand-patched MPP** (same table entry the DTB now selects,
so it should reproduce): MJPEG 720p decode in **7 ms** (131 fps), HEVC encode **1080p @ 52 fps**
validated by decoding the output back — and **H.264 encode returns size 0**
(`hal_h264e_vepu540c_status_check enc not done hw_status: 0x00000000`). That last one is an MPP HAL
bug on this encoder revision, not silicon: the same `vepu540c` block does HEVC at 52 fps.

Second gap, same area: `/dev/mpp_service`, `/dev/rga` and `/dev/dma_heap/*` are created root-only
`0600`, so any non-root player dies at `os_allocator_dma_heap_open ... failed` and no group
membership can rescue it. Shipping `firmware/common/rk35xx-vpu.rules` to give them to group `video`
— **verified on the R69** (`udevadm test` names that rule as the one setting `GROUP 44`,
`MODE 0660`), still to be re-checked here.

Two DT defects are real but **factory behaviour, not ours** — stock Android's dmesg prints the same
lines: no `venc-opp-table`, so the encoder runs at a fixed 297 MHz with no devfreq
(`rkvenc_init: failed to add venc devfreq`), and `rkvdec2_init: failed on clk_get clk_core` /
`No core reset resource define`. Nothing has been shown to block on either, so neither was grafted.

Open, and deliberately not guessed at: `rk3528a` vs `rk3528` differ in MPP by exactly one
capability, **VP9 decode**. We claim `rk3528a` because that is what the sibling board's factory tree
claims for this silicon; the format matrix is what will confirm or refute it, and
if VP9 comes back ❌ the correction is that one string.

Untried idea worth recording: a compatible change can probably be tested **without flashing** by
bind-mounting a doctored file over `/proc/device-tree/compatible` inside a private mount namespace
(`unshare -m`) and running MPP there. Not attempted yet — if it works it turns a reflash-and-reboot
cycle into seconds.

### 2026-08-09 — H.264 encode: fixed upstream-side, pending re-test here

The `size 0` H.264 encode failure recorded above is **not** specific to this box and not a HAL
revision limit — it is a plumbing bug in MPP that affects every SoC using `hal_h264e_vepu540c`. The
H.264 path never reads the hardware status register back; it checks the zero it wrote itself, while
the encoder happily completes each frame (the `rkvenc` IRQ fires once per submitted frame). The
H.265 HAL on the same block does read it, which is the whole difference.

Diagnosed and fixed on the R69, since this box was busy: `mpp/` (patch + README), twelve lines,
giving 116 / 55 / 14.4 / 3.6 fps at 720p / 1080p / 4K / 8K there. Expect the same here — the encoder
block is identical — but that stays 🟡 until this box runs it.

Also settled from that R69 session: the open question above — `rk3528a` or `rk3528`? — is answered
**`rk3528a`**. VP9 is the only capability separating the two entries in MPP, and the R69 decodes it
at 635 / 325 / 85 fps (720p / 1080p / 4K) on the same silicon. The graft in `board.dts` stands as
written; no correction needed.

### 2026-08-09 — deployed, rebooted, and the graft proved out

`rk35xx-deploy art@h96max --no-reboot`, then an explicit reboot. The updater reported _"device tree
changed — a reboot is required"_, which is exactly the signal it should give: both copies
(`/usr/local/share/rk35xx/board.dtb` and `/boot/dtb/rockchip/board.dtb`) md5-matched the repo before
the restart.

Back up in **~24 s**, boot 12.8 s (4.1 kernel + 8.7 userspace), no failed units, all five DKMS
modules installed with IR and PHY loaded, `/dev/watchdog` present, Ethernet still on the vendor
`RK630` driver. Nothing regressed.

The line that mattered:

```
chip name: h96max,rk3518-tvbox rockchip,rk3518-evb1-ddr4-v10 rockchip,rk3518 rockchip,rk3528a
match chip name: rk3528a
coding caps: dec 00f0079c enc 00100180
```

Same caps word as the R69. **This board could not do hardware video at all before that string**, and
the entire matrix now runs on it — as `art`, not root, which is the udev rule doing its job. Decode
to 8K on H.264 / HEVC / MJPEG, VP9 at 634 / 327 / 85 fps, and HEVC encode at 4K (15.9) and 8K (4.0)
despite MPP's table claiming a 1080p ceiling. With our patch, H.264 encodes at 115 / 55 / 14.4 / 3.6
fps and `ffprobe` confirms genuine `h264,7680,4320`. Numbers in [board.md](board.md#hardware-video).

Byte-for-byte, the encoder output on both boards is **identical** at every resolution (e.g. 663,470
bytes for 1080p HEVC) — same silicon, deterministic encoder, and a neat cross-check that neither box
is an outlier.

**Consequence for anyone who patched MPP's SoC table to work around this:** the patch is now
redundant — drop it and stay on upstream.

I first wrote here that such a patch would _win_ over `rk3528a` and cost VP9, and that was wrong;
measuring it settled the matter. `check_soc_info()` walks the table in reverse, so the **last**
matching entry wins, and a hand-added `rk3518` entry placed next to the `rk3528` ones sits _before_
`rk3528a` and never matches at all. A box carrying exactly that patch reports
`match chip name: rk3528a`, with the full `0x00f0079c` decode caps — VP9 included. The hazard only
appears if the entry is appended _after_ `rk3528a`. `mpp_debug=0x10` prints which entry matched;
trust that over reasoning about the file.
