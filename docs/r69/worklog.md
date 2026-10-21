# How the R69 got Armbian — a bring-up journey

The R69 is a $35 RK3518 Android TV box: locked bootloader, no docs, no community port. Here's how it
became a real Armbian machine — told in the order it actually happened, so the next person (or the
next Claude) can walk the same path.

> ### TL;DR — the speedrun 🙂
>
> Cracked the case open. Found a 4-pad serial header by the SD slot, pushed in **three jumper
> wires** (no soldering, no VCC), plugged it into a Mac, and pointed **Claude** at the console. From
> there it basically drove itself: get a root shell → enable ADB → dump the whole eMMC and every
> scrap of recon → swap in a bootloader that actually recognizes an RK3518 → hand the board's device
> tree to the AI to rewrite. The moment SSH came up, the loop got fast — Claude brought the
> peripherals up **one at a time over the network**, with a human acting only as hands: reflash the
> SD, power-cycle, press a remote button. Standing rule: **relentlessly fix every issue, no "good
> enough."** A great many reboots later: a complete little Linux box where **essentially every
> peripheral works** — video, audio, Wi-Fi, Bluetooth, USB 2/3, the LEDs, the 22-button remote and
> its power key — all baked into one reproducible script. (The remote's nice enough to moonlight as
> a [cncjs](https://github.com/cncjs/cncjs) CNC pendant.)

The one idea everything hangs off:

> **Keep the box's factory bootloader, take the OS wholesale from the Radxa ROCK 2F image, and
> override only what's board-specific — U-Boot, a couple of drivers, and the device tree.**

(The device tree here originally started from the ROCK 2F's too. That was a mistake, corrected on
2026-08-09 — it now derives from the box's own factory Android DTB; see the last entry and dtb.md.)

The rest is the **play-by-play** — every step, trap, and dead end, in the order we hit them.

---

## The box

|            |                                                                                                                                                                 |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SoC        | **RK3518A** — reports `SoC: 35181001`, `ro.board.platform=rk3528`. RK3518 is a variant _inside_ the RK3528 family — that single fact drives every choice below. |
| RAM / eMMC | 2 GB / 16 GB (`mmcblk2`, 30777344 sectors)                                                                                                                      |
| Wi-Fi/BT   | **AIC8800D80**, SDIO `C8A1:0082` (`aicwf_sdio` / `aic8800_fdrv`)                                                                                                |
| Debug UART | `0xff9f0000` @ **1500000** baud                                                                                                                                 |
| Bootloader | factory **DDR huan.he v1.11**, **BL31 v1.20**, BL32 v1.06                                                                                                       |
| Stock      | Android 14 (SDK 34), `ro.product.name=R69-1`, SELinux permissive                                                                                                |

**Opening the case:** it pops apart easily with a **plastic opening triangle/pick** (the kind in any
phone-repair kit) — no clips to break. When closing it back up, **orient the backplate correctly so
its thermal pad lands squarely on the Rockchip SoC** — get this wrong and the SoC loses its heatsink
path and will thermal-throttle.

---

## 1. Getting in

The obvious doors were all locked:

- **Developer options** wouldn't unlock — tapping the build number 7× did nothing (this box strips
  it), so no ADB the normal way.
- The box has **only USB-A ports**, so the maskrom route needs a **USB-A male-to-male** cable into a
  real host port. (A plain A-to-C cable into a USB-C Mac won't enumerate: the C end signals "host",
  the box is also a host → role collision. Converting the box's A port to C doesn't help either.)
  There **is** a recovery button in the AV jack — the recessed one, held at power-on, is the
  BootROM's maskrom trigger, verified 2026-08-14 (enumerates as `2207:350c` over A-to-A); see
  board.md. An earlier version of this entry said there wasn't, which made maskrom look far less
  reachable than it is. _(corrected 2026-08-14)_

The door that _did_ open was the **debug UART** — the 3 wires above, on the 4-pad header by the SD
slot: pinout **GND · TX · RX · 3V3** (square pad = GND; wire GND/TX/RX and cross adapter TX↔RX).
**Do not connect VCC/3V3** (the box is self-powered; tying rails can backfeed). Adapter must do 1.5
Mbaud: **CH340/FT232 do; a CP2102 tops out near 1 Mbaud** and prints garbage. Read it with `tio` or
pyserial miniterm (`screen` often can't set 1500000):

```bash
brew install tio
tio -b 1500000 -L --log-file boot.log /dev/cu.usbserial-XXXX   # use cu.*, not tty.*  (-l is list!)
```

Power-cycle and the boot log scrolls. On this box the serial console is a **root shell**
(`su 0 <cmd>` syntax, not `su -c`). From there, bootstrap ADB over the network so you can reuse
normal tooling and pull files quickly:

```sh
setprop service.adb.tcp.port 5555; stop adbd; start adbd     # from the serial root shell
# then from your PC:  adb connect <box-ip>:5555
```

> **Pull binaries over ADB, not serial.** A `base64` of the device tree over the serial line at 1.5
> Mbaud (no flow control) _drops bytes_ and decodes to garbage.
> `adb exec-out 'su 0 cat /sys/firmware/fdt' > board.dtb` is byte-exact.

Not on the network yet? Join Wi-Fi from the Android root shell
(`cmd wifi connect-network "SSID" wpa2 "PASS"`) or plug Ethernet. (The password lands in your serial
log — scrub it after if you care.)

Keep a **wired link** for the bring-up itself: the onboard Ethernet — or a **USB-Ethernet dongle** —
holds SSH steady across the many reboots and is up before Wi-Fi is configured, far less flaky than
leaning on Wi-Fi while you're still bringing the radio up.

## 2. Back up first — the factory bootloader is irreplaceable

> **The public Rockchip DDR blobs are a lottery.** On many boards they fail DDR training or boot
> _marginally_ and silently corrupt RAM. The only config known stable on your exact DRAM die is the
> **factory one, baked into the eMMC at sector 64.**

So before touching anything, dump the whole eMMC and carve out the factory loader:

```sh
adb exec-out 'su 0 dd if=/dev/block/mmcblk2 bs=1M 2>/dev/null' > emmc-full.img
dd if=emmc-full.img of=factory_idbloader.bin bs=512 skip=64 count=4096
strings factory_idbloader.bin | grep -iE 'huan|fwver'   # must show "DDR ... fwver:"
```

`2>/dev/null` on the box matters — some toybox `dd` builds print stats _into_ the captured stream,
tacking a text trailer onto the image. Verify the final size matches `/sys/block/mmcblk2/size × 512`
exactly; adb-over-Wi-Fi can drop mid-stream (Ethernet is steadier for 16 GB). These two files
(`backup/r69/emmc-full.img`, `firmware/factory_idbloader.bin`) are your only undo button.

## 3. Recon — dump what the device tree needs

The whole port is derived from a handful of dumps off the running stock system (`stock/r69/`). The
important ones:

| File                            | What                                                               | Why                                             |
| ------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------- |
| `board.dts`                     | the **live Android** device tree (`/sys/firmware/fdt`, decompiled) | the authoritative source of _this board's_ pins |
| `gpio.txt`, `pinmux.txt`        | claimed GPIOs + pin→function map                                   | finds SDIO data-line conflicts                  |
| `dmesg.txt`                     | boot log                                                           | clocks, regulators, PHY, Wi-Fi probe            |
| `sdio.txt`, `firmware-list.txt` | Wi-Fi chip vendor:device id + firmware it wants                    | drives the Wi-Fi node                           |
| `cmdline.txt`, `iomem.txt`      | console UART address, RAM                                          | earlycon, memory node                           |

Collect them over the serial→ADB bootstrap — this box uses `su 0`, and `adb exec-out` keeps the
binary DTB byte-exact:

```sh
mkdir -p stock/<board> && cd stock/<board>
# the live Android device tree — binary-safe pull, then decompile for the AI
adb exec-out 'su 0 cat /sys/firmware/fdt' > board.dtb
dtc -I dtb -O dts board.dtb > board.dts

adb exec-out 'su 0 cat /sys/kernel/debug/gpio'                  > gpio.txt
adb exec-out 'su 0 cat /sys/kernel/debug/pinctrl/*/pinmux-pins' > pinmux.txt
adb exec-out 'su 0 sh -c "for d in /sys/bus/sdio/devices/*; do cat \$d/uevent; done"' > sdio.txt
adb exec-out 'su 0 ls -R /vendor/etc/firmware /vendor/firmware 2>/dev/null'           > firmware-list.txt
adb exec-out 'su 0 dmesg'                 > dmesg.txt
adb exec-out 'su 0 getprop'               > getprop.txt
adb exec-out 'su 0 lsmod'                 > lsmod.txt
adb exec-out 'su 0 cat /proc/cmdline'     > cmdline.txt
adb exec-out 'su 0 cat /proc/iomem'       > iomem.txt
adb exec-out 'su 0 cat /proc/meminfo'     > meminfo.txt
adb exec-out 'su 0 cat /proc/partitions'  > partitions.txt
adb exec-out 'su 0 cat /proc/cpuinfo'     > cpuinfo.txt
```

These are **runtime** dumps — they only exist on a _booted_ stock system. Once you've flashed
Armbian you can't regenerate them without restoring stock, which is why `stock/r69/` is kept in the
repo as the evidence trail.

## 4. The boot chain — and the "Unknown SoC" detour

> The stock image's U-Boot got far enough to greet us with `Unknown SoC` and quit — it literally
> didn't recognize the chip it was running on. Newer firmware knew the way.

The working chain is three pieces written to a stock Armbian rk35xx image:

```
sector 64       factory idbloader   (tuned DDR + Rockchip SPL)   <- from your backup
sector 16384    u-boot.itb          (BL31 v1.20)
partition 1     Armbian rootfs (/boot inside)
```

The detour: the stock Armbian ROCK 2F image's own U-Boot carries a **BL31 too old for RK3518** — it
boots far enough to print **`Unknown SoC`** and stops. RK3518 support landed in **BL31 v1.20**;
older (v1.17) predates it. Swapping in a v1.20 `u-boot.itb` (from the
[juliovendramini](https://github.com/juliovendramini/rk3518_armbian) prebuilts, or built with
`generic-rk3528_defconfig` + `CONFIG_SYS_MMC_MAX_BLK_COUNT=2048`) fixed it.

> **Assembly must swap BOTH** the idbloader@64 **and** u-boot.itb@16384 — and always _after_ writing
> the OS image, or the image's broken loader wins. We initially swapped only the idbloader, which
> cost us the whole `Unknown SoC` detour.

## 5. The device tree — the one lesson that matters most

The natural plan is: ask the AI to write a clean device tree from the Radxa ROCK 2F mainline
source + the box's pins, compile it with `dtc`, done. **It compiles, the `compatible` strings even
match — and it hangs dead at `Starting kernel`.**

> **A mainline-compiled DTB is incompatible with the Armbian _vendor_ (BSP 6.1) kernel.** The vendor
> kernel needs a _vendor_-structured DTB. The reliable method is to **edit the vendor DTB**, not
> compile a fresh mainline one:
>
> 1. extract `rk3528-rock-2f.dtb` from the stock Armbian image, **decompile** it
>    (`dtc -I dtb -O dts`),
> 2. apply your board's changes to _that_ (string-edit the `.dts`, recompile with `dtc`; flip
>    `status` with `fdtput`),
> 3. you now have `firmware/board.dts` — self-contained, plain-`dtc`-compilable.

In commands — decompile the vendor base, edit, recompile, install:

```sh
# vendor base DTB: in the stock Armbian image (or a booted Armbian) at
#   /boot/dtb/rockchip/rk3528-rock-2f.dtb
dtc -I dtb -O dts  rk3528-rock-2f.dtb         > board.dts   # decompile
#   ...edit board.dts (the changes below)...
dtc -@ -I dts -O dtb -o board.dtb  board.dts     # recompile (-@ keeps __symbols__)

# iterate on the running box — Ethernet keeps SSH across the reboot:
scp board.dtb r69:/boot/dtb-*/rockchip/    # into the kernel's dtb-<ver> dir
ssh r69 reboot
```

(`build-image.sh` ships the finished `firmware/board.dtb`; the above is the loop you use while
_deriving_ it.)

The AI is still what reads the 4000-line Android DT and tells you _which_ nodes and pins to change —
it just feeds edits into the vendor DTB instead of authoring a new tree. The changes it worked out
for the R69:

- **Console** — address-based earlycon for `0xff9f0000` (survives `ttySx` renumbering).
- **PCIe** — `status = "disabled"`. RK3518 has no usable PCIe; the driver throws an external abort
  at boot (`fdtput /pcie@fe4f0000 status disabled`).
- **Ethernet** — enable `gmac0` (it's `disabled` in the rock-2f DTB).
- **Wi-Fi SDIO** — enable `sdio1@ffc20000` (4-bit, non-removable, `cap-sdio-irq`, `sd-uhs-sdr104`) +
  an `mmc-pwrseq` + Rockchip `wlan-platdata`, wired to the R69's **real** GPIOs read from the
  Android DT: REG_ON **gpio3.10**, host-wake **gpio3.11**, 32 kHz **gpio3.19**. (The reference box
  used sdio0/gpio1 — this is where boards differ.)
- **USB 3.0** — switch `dwc3` to host mode, add the USB3 combo-phy, drop the
  `maximum-speed = "high-speed"` cap.

> **The headline trap — audit every active GPIO against the SDIO/eMMC data lines.** On the reference
> box a Radxa status **LED sat on a pin that is an SDIO data line** on the TV box; it silently broke
> 4-bit Wi-Fi writes (firmware download timed out with `-110`). Always cross-check
> `gpio-leds`/regulators/`reset-gpios` against the SDIO data/clk/cmd pins. This is the single most
> valuable thing the AI does in the DT step.

## 6. Wi-Fi — the AIC8800 SDIO saga

Enabling SDIO in the DTB was necessary but not sufficient. The userspace side took three more fixes:

1. **Remove `aic8800-usb-dkms`** (`apt-get remove`, not just blacklist). It ships three USB `.ko`
   that export the **same symbol** as the in-tree SDIO driver — a duplicate- symbol clash. A static
   blacklist isn't enough; the package must go.
2. **Firmware filename mismatch** — the driver opens un-suffixed names (`fw_patch_table.bin`); the
   package ships `*_8800d80_u02.bin`. Symlink un-suffixed → suffixed in
   `/lib/firmware/aic8800/SDIO/aic8800D80/`.
3. **Auto-load** `aic8800_fdrv` at boot.

Result: `wlan0` up, Bluetooth firmware patch loads with it. (A warm `reboot` re-runs the SDIO
`mmc-pwrseq` REG_ON toggle, so the radio re-inits cleanly; the `poweroff`/no-PMIC power story is
§9.)

## 7. Bluetooth — a two-day red herring that was a serial console all along

> Two days spent proving the Bluetooth chip was dead. It wasn't. A login prompt was quietly typing
> `r69 login:` _into the chip_ and eating its replies — and the fix was a single line. The journey's
> lowest point and its sharpest lesson. 🤦

The AIC8800's Bluetooth rides UART2 (`/dev/ttyS2`) at 1.5 Mbaud; `aicbsp` loads its BT patch over
SDIO at boot. So `hciattach … any flow` _should_ just work — but `hci0` came up **dead**:
`RX bytes:0`, `BD 00:00:00:00:00:00`, every HCI command timing out. We chased it deep: removed the
UART's `dmas`, dropped the SDIO clock 150→100 MHz, compared MCR/MSR/baud registers
raw-vs-line-discipline (byte-identical), proved with internal UART loopback that the kernel's TX
physically reached the wire, even built a userspace H4↔`/dev/vhci` bridge to sidestep the kernel
line discipline entirely. The bridge got _further_ (read the chip's real address, 41 HCI events) but
still flaked — and crucially, a **raw** read/write to `/dev/ttyS2` answered HCI Reset perfectly
every time. The chip was fine. Something else was on the wire.

It was a **login console.** Armbian's `armbianEnv.txt` `console=both` makes `boot.cmd` append
`console=ttyS2,1500000` to the kernel command line — and on this board ttyS2 is the _Bluetooth_
UART, not the debug one (the real debug console is `ff9f0000`/`ttyFIQ0`). systemd dutifully spawns a
**`serial-getty@ttyS2`** that opens the port, prints a login banner _into the BT chip_, and eats the
chip's HCI replies. Worse, it **respawns** after every `fuser -k`, so it corrupted tests mid-run and
looked like a "chip that degrades." (A second self-own: `pkill -f r69-bt-bridge` matched our own SSH
command line and kept killing our session — including before `systemctl reboot` could run, which is
why "reboots weren't working.")

The fix is one line of intent — **free ttyS2** — and then everything is stock BlueZ:

```sh
systemctl mask --now serial-getty@ttyS2.service      # stop the console stealing the UART
hciattach -s 1500000 /dev/ttyS2 any 1500000 flow nosleep
```

`bluetoothctl scan on` immediately found a real nearby BLE device. The `r69-bt` service does exactly
this on every boot (plus an rfkill unblock), and `AutoEnable=true` in `/etc/bluetooth/main.conf`
powers `hci0` on. No custom bridge, no vendor `hciattach`, no firmware download — the AIC8800 BT is
a plain HCI H4 controller. The lesson: when a UART peripheral "never answers," first check that
nothing else owns the tty (`fuser /dev/ttyS2`).

**The real fix is upstream of all that: point the serial console at the right UART.** The getty only
landed on the BT UART because `armbianEnv`'s `console=both` makes `boot.cmd` hardcode
`console=ttyS2,1500000` — inherited from the rock-2f base, whose debug UART _is_ ffa00000. On the
R69 the debug UART is **ff9f0000** (where the serial header actually is). ff9f0000 = uart0, but the
vendor DTB leaves uart0 `disabled` and hands its pins to a `rockchip,fiq-debugger` (which exposes it
as `ttyFIQ0`, and here even fails its FIQ/NMI setup). So we **enable uart0 as a normal `ttyS0`**
(status okay + its `uart0m0_xfer` pins) and **disable the fiq-debugger**, then set
`console=display` + `console=ttyS0,1500000` in `armbianEnv`. Now the kernel console is on the
correct UART: ttyS2 is never a console, no getty spawns on it (so the `r69-bt` mask is just
belt-and-suspenders), and `verbosity=7` in `armbianEnv` streams full kernel boot logs to serial
(it's left at the quiet default of 1; raise it when debugging). One UART number can't be renamed —
the 8250 driver owns the `ttySN` namespace from the DT `serialN` aliases — but with the console on
`ttyS0` the hierarchy is unambiguous: `ttyS0` = console, `ttyS2` = the data UART Bluetooth uses.

## 8. Everything else

> After the boot chain, the device tree, and the Bluetooth saga, the rest was a victory lap — flip
> the right DTB node, check it over SSH, move on.

Brought up by enabling the right vendor-DTB nodes and verifying on the running box over SSH:
**HDMI** video + audio, **analog AV** audio, **GPU** (Mali-450 via the open `lima` driver), **USB
2.0** (HID enumerates), **IR** receiver (input device `ffa90030.pwm`; `rc0` is HDMI-CEC, not IR),
**eMMC + SD**, **USB 3.0**, **CPU thermal**. RAM is **~1.5 GB, not 2 GB** — the stock "2 GB" is
Android misreporting it, not a bug (see below). The **front LED**, the **IR remote + power button**,
and the `rock-2f`→R69 **identity rename** are all done now; the `fd650` front-panel display is
**N/A** (the R69 has none). The remote/power/LED story is §9.

---

## 9. The remote, the power button, and the standby LED

The bundled remote drives the box over **infrared** — a Rockchip PWM-capture receiver on `pwm3`
(`ffa90030`) decodes all 22 keys. The **voice** and **mouse-mode** buttons press as plain keys over
IR; their real functions ride the remote's **BLE** side, which was later verified here — pairing
brings up an air-mouse node and a battery reading (see board.md). Voice _audio_ stays out of scope:
it rides the proprietary Android-TV `0xfeb3` GATT service, established on the H96 Max.

### IR: a shared-IRQ fix shipped as an out-of-tree module

The in-kernel `remotectl-pwm` never bound. It requested the PWM-block IRQ (28, GIC85) **without
`IRQF_SHARED`**, but the `rockchip-pwm` voltage regulators (pwm1/pwm2, always-on) already held that
same IRQ _with_ it:

```
genirq: Flags mismatch irq 28. 00004004 (rk_pwm_irq) vs. 00004084 (rockchip-pwm)
remotectl-pwm ffa90030.pwm: cannot claim IRQ 28 ... -16
```

The built-in uses `platform_driver_probe()`, which **self-unregisters on a failed probe**, so `pwm3`
is left unbound — meaning a patched **out-of-tree** copy can claim it with no kernel rebuild.

**Source provenance** — we don't vendor the driver wholesale; we **author a patch on a pinned
upstream commit**. The pristine source is the BSP the running kernel is built from:

- repo / branch: **`armbian/linux-rockchip`**, branch **`rk-6.1-rkr5.1`**
- pinned commit: **`31cd4f11b5ec31fc361256a04237416f278b62b2`** (the branch moves; the commit
  doesn't)
- files: `drivers/input/remotectl/rockchip_pwm_remotectl.c` (patched) + `.h` (pristine)

**The patch** (`firmware/ir/r69.patch`, three changes — `diff`-verified to be _only_ these, no
upstream drift):

1. **Share the IRQ** — `IRQF_NO_SUSPEND` → `IRQF_NO_SUSPEND | IRQF_SHARED` on the `rk_pwm_irq`
   request (its `dev_id` is already `ddata`, non-NULL, which `IRQF_SHARED` requires).
2. **Drop a non-exported symbol** so it links OOT — `irq_to_desc()` (not exported to modules) →
   exported `irq_get_irq_data()` + `irqd_to_hwirq()` (`struct irq_desc *desc` →
   `struct irq_data *irqd`, three call sites).
3. **Rename the driver** — `.name "remotectl-pwm"` → `"remotectl-pwm-r69"`, so it doesn't collide
   with the built-in's reserved name (DT matching is by `compatible`, so the rename is cosmetic).

> Why swap `irq_to_desc` instead of stubbing it: that path feeds `rk_pwm_sip_wakeup_init()`, which
> arms the IR IRQ + power-key scancode with ATF as a **wake source** — that's what lets the remote
> power the box back on. Stubbing it would have killed wake-on-IR.

**Packaging** — built + loaded on **first boot**, survives kernel updates (DKMS). `firmware/ir/`
holds only `r69.patch` + `Makefile` + `dkms.conf` — _not_ a copy of the driver. At **image-build**
time (`build-image.sh`, on the network-connected build host) it fetches the pinned commit, applies
`r69.patch`, and stages the result as the image's DKMS source at
`/usr/src/rockchip-pwm-remotectl-r69-1.0/`. On the **box**, the single `r69-firstboot` service runs
**`rockchip-pwm-remotectl-r69-setup`** once (`dkms add/build/install` + `modules-load.d`) — offline,
since the image ships kernel headers. **Not opt-in**: the remote — and the power button, the only
way to wake from `poweroff` — must work out of the box; the setup script is also runnable by hand.
DKMS package: `rockchip-pwm-remotectl-r69/1.0`; the built module is `rockchip_pwm_remotectl_r69`.

**Surviving combined image+headers kernel upgrades.** When a kernel `apt upgrade` bumps both
`linux-image` and `linux-headers`, dpkg configures the _image_ first — firing its `dkms` postinst
hook before the _headers_ postinst has compiled the kernel's host build tools
(`scripts/basic/fixdep`, `scripts/mod/modpost`). The headers _source_ is already unpacked but the
_tools_ aren't built yet, so every out-of-tree `make` dies with `scripts/basic/fixdep: not found`
(exit 127), failing all DKMS modules and leaving the kernel package half-configured. The fix is a
tiny postinst.d hook, `firmware/r69-kernel-prepare`, staged to
`/etc/kernel/postinst.d/00-r69-kernel-prepare` — the `00-` prefix makes `run-parts` execute it
**before** `dkms`. It replicates the headers postinst's own steps
(`make ARCH=arm64 olddefconfig scripts` + `M=scripts/mod` — _not_ `modules_prepare`, which pulls in
`archprepare` and fails on Armbian's stripped headers) to compile those tools first, so DKMS builds
on the first pass. No-op once the tools exist.

### The power key — a configurable button: power-off _or_ real suspend-to-RAM

`KEY_POWER` → logind. We set **`remote_support_psci = <1>`** on `pwm3` so ATF arms the IR as a wake
source — the remote then wakes the box from either of two modes, selected by `HandlePowerKey`:

**`poweroff` (default).** No PMIC, so `poweroff` can't cut power — `rockchip,virtual-poweroff` parks
the SoC still-powered. The remote powers it back **on**, but as a full **cold boot** (BootROM →
u-boot → kernel, ~10–15 s, RAM not preserved). A clean-shutdown soft button. Reliable, low-power
off.

**`suspend` — genuine suspend-to-RAM**, and it _does_ work here (this took real digging). The chain:

- Armbian ships with the suspend verb **disabled** (`AllowSuspend=no`) — re-enabled by
  `zz-r69-suspend.conf` (`AllowSuspend=yes`, `SuspendState=mem`). Use **deep `mem`, not `s2idle`**:
  s2idle is a kernel-only idle that never engages ATF, so the IR (armed in ATF) can't wake it; `mem`
  goes through PSCI `SYSTEM_SUSPEND`, which the **RK3528 BL31 v1.21 supports** (its changelog adds
  suspend + GPIO/USB/HDMI wake).
- The BL31 serial trace was the key: the SoC enters deep sleep (DDR self-refresh) and the resume
  cause is printed (`CPU0 interrupt wakeup`, `IRQ_PED: <gic>`). That's how we saw what was waking
  it.
- **Two red herrings cleared:** (1) the **AIC8800 WiFi** appeared to wedge resume — but with it left
  loaded it actually resumes _fine_ (the live SSH session and a running `watch` survived the
  suspend); (2) early tests "auto-woke" only because an **active network/SSH session** kept
  interrupting — idle, it holds deep sleep indefinitely and **only the remote wakes it**.
- **The real bug was the power key doing double duty:** the IR press both wakes the SoC (ATF) _and_
  is decoded by the resumed kernel as `KEY_POWER`. Under `HandlePowerKey=poweroff` that meant the
  wake-press immediately _powered the box off_ (wake → shutdown in one press). Switching to
  `HandlePowerKey=suspend` makes it a clean toggle: press to sleep, press to wake.
- Resume is **instant** (RAM + WiFi intact), and `mem` keeps the GPIO4 rail alive so the **red
  standby LED holds** (blue stays lit in sleep until the `led-sleep` hook flips it to red).

Both modes are preconfigured; `zz-r69-powerkey.conf` just picks the default (`poweroff`). See the
README "Power button" section for the one-line switch.

### The red standby LED — making "off" show an indicator like stock

Stock Android lights the **red** LED while "off". The fix turned out to be a cheap DTB + hook combo
— _not_ a firmware swap — found by reading the **stock DTB pulled straight from the eMMC dump**:
parse the GPT in `backup/r69/emmc-full.img` for partition offsets, `dd` out the `boot` partition,
scan for the FDT magic (`d00dfeed`), carve and decompile with `dtc`.

The stock DTB (`rockchip,rk3518-evb1`) had both LEDs carrying **`rockchip,invert-on-shutdown`** — a
Rockchip-BSP `leds-gpio` property that flips the LED at shutdown. But the Armbian vendor kernel's
`leds-gpio.c` (same `rk-6.1-rkr5.1` branch) **doesn't implement it** — it only knows the mainline
**`retain-state-shutdown`**, and its `gpio_led_shutdown()` otherwise **forces every LED off**.
_That_ — not the rail dying — is why "off" had always been dark.

The working recipe (`board.dtb` + two hooks):

- DTB: **`retain-state-shutdown`** + **`retain-state-suspended`** on both LED nodes → the kernel and
  the LED core stop blanking them at shutdown / suspend.
- **system-shutdown hook** (`/usr/lib/systemd/system-shutdown/r69-led`) sets **red on, blue off**
  right before the park; with `retain-state-shutdown` that survives into the parked "off" — the
  no-PMIC rail stays powered, so a driven pin holds (verified: red stays lit when off).
- matching **system-sleep hook** (`/usr/lib/systemd/system-sleep/r69-led`, `pre`/`post`) for the
  suspend path (paired with `retain-state-suspended`), for whenever suspend becomes wake-able.

This also resolved an earlier dead-end. In **suspend** (s2idle/`mem`) the GPIO4 rail really does
drop the LED; but in **poweroff/park** the rail holds — the darkness there was purely the kernel's
shutdown-blanking, which `retain-state-shutdown` cures.

Net behaviour is a clean **3-state** indicator over a power cycle:

| state                            | LED                                                                                           |
| -------------------------------- | --------------------------------------------------------------------------------------------- |
| **off / standby** (parked)       | **red**                                                                                       |
| **booting** (~10–15 s cold boot) | **dark** — the SoC reset clears the GPIOs, and `leds-gpio` re-drives them only when it probes |
| **running**                      | **blue**                                                                                      |

The only un-lit window is that middle cold-boot gap; filling it would mean driving an LED from
**u-boot** early in the boot (we build our own u-boot, so it's doable) — a future nicety, not a bug.

---

## Storage — the ROCK 2F DTB over-drives the SD and eMMC

Two bus-mode traps surfaced once the image ran on more units (other SD cards, a different eMMC
part). Same root cause both times: the ROCK 2F device tree specs faster signaling than the R69 board
can hold, and the fix is to **match your own factory Android DTB** (`stock/r69/board.dts`, pulled
off the box) rather than trust the ROCK 2F defaults.

### SD card: no 1.8 V switch → drop UHS

The `sdmmc` node inherited `sd-uhs-sdr12/25/50/104` + a GPIO-switched `vqmmc-supply` from the ROCK
2F. The R69's SD IO rail has **no 1.8 V switch** (`vcc_sd` is a fixed always-on 3.3 V regulator),
and the factory DTB declares neither property. With a UHS-capable card the kernel negotiated a UHS
mode and toggled a GPIO that switches nothing: the card entered 1.8 V signaling while the host pads
stayed at 3.3 V, and since the regulator can't power-cycle the card back, every retry ended in
`Card stuck being busy!` at 187.5 kHz — the rootfs never mounted and first boot never ran. It failed
**only on UHS-capable cards**, which is why the same image booted or hung depending on the SD. Fix:
strip `sd-uhs-*` + `vqmmc-supply`, matching the factory (3.3 V high-speed, 50 MHz). The Wi-Fi `sdio`
node keeps _its_ `sd-uhs-sdr104` — different controller, legitimate.

### eMMC: HS400ES writes corrupt → cap at HS200/100 MHz

The `sdhci` node inherited `mmc-hs400-1_8v` + `mmc-hs400-enhanced-strobe` and `max-frequency` = 200
MHz from the ROCK 2F. The R69's eMMC _accepts_ HS400ES and **reads** are clean — but sustained
**writes** fail with I/O errors, breaking `armbian-install` and any eMMC write workload. The
asymmetry is the tell: in HS400 the reads are latched off the **data strobe the eMMC returns** (the
device supplies the timing, so they're robust — a read benchmark shows a happy ~290 MB/s), but the
writes are latched off the **host's own 200 MHz DDR launch clock**, which the board's eMMC signal
integrity can't hold. Your factory Android independently caps this part at **HS200 / 100 MHz** — so
match it: `mmc-hs200-1_8v` and `max-frequency` = 100 MHz. (The factory tree also carries a bogus
`mmc-hs200-enhanced-strobe` — enhanced strobe is HS400-only and no kernel parses that name — so it
is _not_ copied.)

> **It's one link mode — you can't keep the fast reads.** HS400ES reads and writes are the same
> negotiated mode; the read robustness comes from the returned strobe, not a mode you can select per
> direction. Making writes reliable means dropping the whole link to HS200, which takes the read
> speed with it (**~290 MB/s HS400ES → ~100 MB/s HS200/100 MHz**). Still faster than the SD, and the
> eMMC is the root device after `armbian-install`, so write integrity wins.

### `armbian-install`: the stock bootloader write soft-bricks the box

Migrating to eMMC with an unmodified `armbian-install` left a box bootless
([#6](https://github.com/sormy/rk35xx-tvbox-armbian/issues/6)) — while a whole-image `dd` of the
same image to eMMC booted fine. That split pins it on the bootloader: the rootfs copy is fine, but
`armbian-install` then calls the u-boot package's `write_uboot_platform`
(`/usr/lib/u-boot/platform_install.sh`), which dd's the **generic ROCK-2F blobs** to sectors 64 +
16384 of the target — and sector 64 is the idbloader, where the whole bring-up established that only
the **factory** DDR init brings this DRAM die up.

The fix is structural, not procedural. The firmware payload ships an R69 **override** of
`platform_install.sh` (`firmware/r69/r69-platform-install`) plus the loader pair at
`/usr/local/share/r69/`, so _every_ `write_uboot_platform` caller — `armbian-install`,
`armbian-config`, a manual `source` — writes the factory idbloader @ 64 + our `u-boot.itb` @ 16384:
the same loaders at the same offsets `build-image.sh` puts on the SD (and that the README's earlier
manual-restore `dd`s wrote — the override just removes the chance to skip them). The stock file
can't reappear: `r69-firstboot` already apt-holds `linux-u-boot-*` for exactly this class of hazard.

---

## Ethernet — the integrated PHY needs its calibration driver

Ethernet is 100 Mb/s by design (no gigabit PHY on the board — the MAC drives an **integrated
RK630-class FEPHY** over RMII, `phy-mode = "rmii"`, MDIO address 2, PHY ID `0x00441400`). But the
FEPHY needs its **per-die OTP calibration** (TX level + bandgap) applied by the vendor `rk630phy`
driver; the DT already wires the `"bgs"` nvmem cell it reads. The stock Armbian kernel ships
`CONFIG_RK630_PHY` **off**, so the uncalibrated **Generic PHY** binds instead — and on units whose
analog silicon doesn't train 100BASE-TX uncalibrated, autonegotiation degrades to **10 Mb/s** (with
a garbled link-partner readout to match).

Shipped exactly like the IR driver — an out-of-tree DKMS module from pinned upstream source, no
kernel rebuild:

- **Source** — `drivers/net/phy/rk630phy.c`, **unmodified**, from the same pinned
  `armbian/linux-rockchip` commit (`31cd4f11…`) as the IR driver. `build-image.sh` fetches it and
  stages it as DKMS source at `/usr/src/rk630-phy-r69-1.0/`; `firmware/ethphy/` holds only the
  `Makefile` + `dkms.conf` (not a copy of the driver).
- **First boot** — `r69-firstboot` runs **`rk630-phy-r69-setup`** once (`dkms add/build/install`,
  offline — the image ships headers), enables early autoload (`modules-load.d`, ahead of
  networking), and does a **live Generic-PHY → RK630-PHY handover**: on `ifdown` the kernel releases
  the generic driver, so a bare `bind` + `ifup` completes the switch with no reboot. It steps aside
  if a future kernel ships `rk630phy` built-in or in-tree.

Result: `end0` links at **100 Mb/s full duplex** with the calibrated driver holding the PHY (check:
`readlink /sys/class/net/end0/phydev/driver` → `RK630 PHY`). DKMS rebuilds it on kernel updates.
DKMS package `rk630-phy-r69/1.0`; module `rk630phy`.

---

## RAM: 1.5 GB is the ceiling, not 2 GB

The box carries 2 GB of DRAM physically — the TPL trains two 1 GB chip-selects (`CS=2`, each
`Row=15 Col=10 Bk=8 BW=32`). But only **~1.5 GB ever reaches an OS**, and that's a hard limit of the
boot chain, not a u-boot bug we can patch.

The factory TPL hands the next stage an `ATAG_DDR_MEM` tag describing exactly two banks:

```
0x00200000 + 0x08200000   (ends 0x08400000,  ~130 MB)
0x08C00000 + 0x57400000   (ends 0x60000000, ~1396 MB)   →  1.5 GB, no bank above it
```

That's all there is, and we proved it. The Rockchip _vendor_ u-boot we first built has
`CONFIG_BIDRAM=y` — the path (`lib/bidram.c`) that _adds_ any "extended-top" region the TPL flags.
Booted on the box and stopped at the prompt, its `bdinfo` printed exactly those two banks and
nothing else (`gd->ram_top_ext_size == 0`). Every bootloader-level source agrees: the TPL banner
(`Size=1536MB`), stock `/proc/iomem`, the stock DTB `/memory` node, and the factory u-boot's own
bank fixup all say 1.5 GB.

The lone dissenter — stock Android's `/proc/meminfo` (`MemTotal: 2047704` ≈ 2 GB) — is a **software
lie, not evidence.** It _exceeds_ stock's own `/proc/iomem` (1.5 GB of System RAM), which is
physically impossible: a kernel can't manage more pages than it has memory regions.

That impossibility is the fingerprint of the well-documented **fake-RAM scam** on cheap Android
boxes — the ROM is patched to _report_ the advertised 2 GB no matter what's actually fitted
(RK3528/RK3518 boxes are named offenders). So there's no 0.5 GB to reclaim by rebuilding u-boot;
Armbian's honest kernel reports the truth: `MemTotal: 1500116 kB` (**1.43 GiB usable**), which for a
headless Linux box is ample anyway (a server-class workload runs comfortably in well under 1 GB).

_Why_ it's an odd ~1.5 GB is almost certainly **binning**: DRAM dies come in powers of two (1, 2, 4
GB) — nobody fabs a 1.5 GB die — so 1.5 GB usable points to a 2 GB part with ~0.5 GB fused off as a
partial-good (binned) die. That's strong inference, not read off the die markings, but it's hard to
explain otherwise — and a tidy reason the box is so cheap. (The package is a combined Samsung
RAM+eMMC part, eMMC half `manfid 0x15`.)

## Building our own u-boot

We still build our own `u-boot.itb` — not for RAM, but to **own the bootloader**: no third-party
prebuilt, every input pinned so the build is reproducible. `build-uboot.sh` builds **mainline
U-Boot** (pinned tag `v2026.04`) + Rockchip's **ATF blob** (BL31 v1.21, from `rkbin` pinned by
commit), keeping the factory idbloader so only `u-boot.itb` @ sector 16384 changes:

```sh
./build-uboot.sh            # builds straight into firmware/common/u-boot.itb (scratch in uboot-build/)
```

- **Mainline, not the vendor tree.** The vendor (`next-dev`) tree is Android-flavored — its
  `bootcmd` runs `boot_android`/`bootrkp` and never boots Armbian (it found `/boot/boot.scr`, ran
  it, bailed, then fell through to PXE). Mainline's `generic-rk3528` boots Armbian cleanly via
  `distro_bootcmd`. Since the vendor tree buys nothing on RAM, mainline wins on simplicity.
- **No OP-TEE.** The FIT carries ATF + u-boot only; Armbian doesn't use OP-TEE. BL31 prints one
  benign `No OPTEE provided ... opteed_fast` line and boots normally. (Re-add via `TEE=` + the
  pinned `rk3528_bl32_v1.06.bin` if you ever need a TEE.)
- **`ROCKCHIP_TPL=` is only a binman build input** — mainline assembles its rockchip image
  (TPL+SPL+FIT) as one blob and emits the FIT as a byproduct, which is all we extract; the built
  idbloader is discarded. The TPL choice can't affect the FIT (ATF + u-boot), so the build stays
  reproducible on the u-boot + BL31 pins alone.

On macOS there's no native Linux, so `build-uboot-finch.sh` runs the build in a **native arm64 Linux
container** via [Finch](https://github.com/runfinch/finch) (lighter than Docker Desktop; the same
`finch run` would work with `docker`):

```sh
brew install finch          # once (the VM auto-starts on first run)
./build-uboot-finch.sh      # wraps build-uboot.sh in a debian:bookworm container -> firmware/common/u-boot.itb
```

Both write `firmware/common/u-boot.itb` directly. Smoke-test before trusting it — the factory
idbloader @ sector 64 stays put:

```sh
sudo dd if=firmware/common/u-boot.itb of=/dev/<sd> bs=512 seek=16384 conv=notrunc; sync
```

It must reach an Armbian login over serial; `free -h` shows ~1.43 GiB (the 1.5 GB ceiling).

---

## Quirks that matter — the cheat sheet

The quick-reference version of the journey above — the distilled, non-obvious things it takes to get
an R69 (or a similar RK3518 box) running well.

**Boot chain**

- Keep the **factory idbloader @ sector 64** — its DDR tuning is the only one stable on this DRAM
  die; the public blobs are a lottery.
- Use a **BL31 v1.20** `u-boot.itb` @ sector 16384 — older BL31 prints `Unknown SoC` on RK3518.
- Write **both** loaders _after_ the OS image, or the image's broken loader wins.

**Device tree**

- Edit the **vendor** rock-2f DTB, not a fresh mainline compile — mainline hangs at
  `Starting kernel` against the vendor kernel.
- **Disable PCIe** (`status = "disabled"`) — RK3518 has no usable PCIe; the driver aborts at boot.
- Compile with `dtc -@` (keep `__symbols__`).
- **Audit GPIOs vs SDIO data lines** — a stray LED/regulator on an SDIO data pin silently breaks
  Wi-Fi.

**Wi-Fi (AIC8800D80)**

- `apt remove aic8800-usb-dkms` — its USB `.ko` duplicate-symbol-clash with the in-tree SDIO driver;
  a blacklist is **not** enough.
- Symlink firmware to the un-suffixed names the driver opens (`*_8800d80_u02.bin` →
  `fw_patch.bin`…).
- The SDIO clock is **driver-forced to 150 MHz** (`aicbsp`) — DTB `max-frequency` is a no-op.

**USB / Ethernet**

- USB 3.0: `dwc3` → `dr_mode = "host"`, add the usb3 combo-phy, drop `maximum-speed = "high-speed"`.
- Ethernet is **100 Mb/s by design** (integrated RK630 FEPHY / RMII, no gigabit PHY) — and needs the
  **`rk630phy` DKMS driver** (auto-built first boot) for its OTP calibration, or the uncalibrated
  Generic PHY drops some units to 10 Mb/s.
- The Ethernet MAC looks random because it **is** — and it is not what the label says. U-Boot
  generates it with `net_random_ethaddr()` when it finds no `LAN_MAC` in vendor storage **on the
  medium it booted**, so an SD-booted box never sees the assigned address sitting in the eMMC store.
  It is stable per card, not per box. (`MACAddressPolicy=persistent` is inert here — systemd skips a
  device that claims a permanent address. This entry used to credit it; that was wrong.) Corrected
  2026-08-13; see armbian-r69.md.

**Power — there is no PMIC**

- `poweroff` **doesn't cut power** — it's a _virtual deep-sleep_ (`rockchip,virtual-poweroff`), so
  the box stays parked-but-powered. **Unplug to fully power off.**

**Storage — match the factory, not the ROCK 2F DTB**

- **SD**: no 1.8 V switch on the rail — strip `sd-uhs-*` + `vqmmc-supply`, or UHS cards hang at boot
  (`Card stuck being busy`). 3.3 V high-speed only.
- **eMMC**: HS400ES **writes** corrupt (reads are strobe-timed and fine) — cap at `mmc-hs200-1_8v` /
  100 MHz to match the factory. One link mode, so it costs read speed (~290 → ~100 MB/s).

**Host tooling**

- **macOS**: pull binaries with `adb exec-out`, not over serial (1.5 Mbaud base64 drops bytes);
  e2tools into the image's ext4 via the **buffered** block node (`/dev/diskNs1`), not raw
  `/dev/rdiskNs1`.
- **Linux**: `chown` the loop rootfs partition to your user and run e2tools **without** `sudo` — as
  root with a user-owned `/tmp` scratch, e2cp's copy-out hits `Permission denied` on some hosts.
- `e2ln -s` is stubbed on both, so enable a unit via a `multi-user.target.d/*.conf` `Wants=`
  drop-in, not a `wants/` symlink.

---

## Troubleshooting reference (the RK3518 traps)

| Symptom                                                                                               | Real cause                                                                                                                                                  | Fix                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SoC not recognized` / `Unknown SoC` in U-Boot                                                        | BL31 v1.17 predates RK3518                                                                                                                                  | rk3528 **BL31 v1.20+** `u-boot.itb`                                                                                                                                                     |
| Random `Synchronous Abort` whose `far` is ASCII text                                                  | marginal **public DDR blob** corrupting RAM                                                                                                                 | use the **factory idbloader** (sector 64)                                                                                                                                               |
| `mmc fail to send stop cmd` loading kernel                                                            | one oversized multi-block read                                                                                                                              | `CONFIG_SYS_MMC_MAX_BLK_COUNT=2048`                                                                                                                                                     |
| Hang at `Starting kernel`                                                                             | mainline-compiled DTB vs **vendor** kernel                                                                                                                  | **edit the vendor DTB**, don't compile mainline                                                                                                                                         |
| External abort referencing `pcie`/`rk_pcie`                                                           | no usable PCIe                                                                                                                                              | `status = "disabled"` on the PCIe node                                                                                                                                                  |
| Wi-Fi `Exec format error` / duplicate symbol                                                          | `*-usb-dkms` clashes with in-tree SDIO driver                                                                                                               | `apt remove` the USB DKMS + `depmod -a`                                                                                                                                                 |
| Wi-Fi enumerates, reads IDs, firmware TX `-110`                                                       | a GPIO (LED) steals an **SDIO data line**                                                                                                                   | remove/repoint the offending `gpio-leds`                                                                                                                                                |
| `*.bin file failed to open`                                                                           | driver wants un-suffixed firmware names                                                                                                                     | symlink un-suffixed → `*_<chip>_uXX.bin`                                                                                                                                                |
| DKMS modules fail on a kernel `apt upgrade` (`scripts/basic/fixdep: not found`, apt left half-broken) | dpkg configures **linux-image before linux-headers**, so the dkms hook runs before the headers postinst compiles the kernel host tools (`fixdep`/`modpost`) | `00-r69-kernel-prepare` postinst.d hook (sorts before `dkms`) pre-builds them; one-time recovery on an already-broken box: `dkms autoinstall -k $(uname -r)` then `dpkg --configure -a` |
| SD card hangs at boot (`Card stuck being busy!`), rootfs never mounts — only with **some** cards      | ROCK 2F `sd-uhs-*` + `vqmmc-supply`, but the R69 SD rail has no 1.8 V switch                                                                                | strip `sd-uhs-*` + `vqmmc-supply` (match factory: 3.3 V high-speed)                                                                                                                     |
| eMMC reads fine but **writes** fail with I/O errors (`armbian-install` breaks)                        | ROCK 2F runs HS400ES @ 200 MHz; writes are host-clock-timed and the board can't hold it                                                                     | `mmc-hs200-1_8v` + `max-frequency` 100 MHz (match factory)                                                                                                                              |
| `armbian-install` to eMMC → box boots nothing                                                         | stock `write_uboot_platform` flashed ROCK-2F loaders to sectors 64 + 16384                                                                                  | R69 `platform_install.sh` override (in the firmware payload) writes the factory idbloader + our `u-boot.itb`; already bricked → rewrite the loaders (README "Back to stock")            |
| Ethernet links at **10 Mb/s** with a garbled link partner                                             | uncalibrated Generic PHY bound — `CONFIG_RK630_PHY` off, FEPHY OTP calibration not applied                                                                  | build `rk630phy` as DKMS (auto on first boot)                                                                                                                                           |

---

## Doing this on another RK3518 box

The method generalizes; only the device tree is board-specific.

1. **Get in** — try ADB; if Developer options is locked, use the **debug UART** (3 wires, 3.3 V, 1.5
   Mbaud) for a root shell, then bootstrap ADB over the network. Maskrom + `rkdeveloptool` is the
   fallback when there's no serial (needs a USB-A-to-A cable into a real host, box in a cold-boot
   maskrom via a recovery pinhole/AV-jack button).
2. **Back up** the whole eMMC and carve `factory_idbloader.bin` (sector 64). Verify the DDR banner.
   This is irreplaceable.
3. **Recon** — dump the live Android `board.dts` + `gpio`/`pinmux`/`dmesg`/`sdio`/
   `firmware-list`/`cmdline`.
4. **Device tree** — give an AI (capable coding model, large context) the **Radxa ROCK 2F** DTB as
   the base and your stock dumps as the pin source. Ask it to identify the changes (console
   earlycon, disable PCIe, enable gmac0, enable the SDIO Wi-Fi controller with the chip's real
   REG_ON/host-wake/32 k GPIOs and a `wlan-platdata` node) **and to run the GPIO-vs-SDIO-data-line
   conflict audit**. Apply those edits to the **decompiled vendor DTB**, recompile with `dtc`.
5. **Assemble** — stock Armbian rk35xx image + factory idbloader@64 + BL31-v1.20 u-boot.itb@16384 +
   your DTB. (`build-image.sh` is exactly this, parameterized for the R69 — adapt the `firmware/`
   for your box.)
6. **Debug loop** — boot, capture serial + `dmesg`, hand them back to the AI against the trap table
   above, get the _minimal_ DT/config change, recompile, reboot, repeat until `ip -br link` shows
   your interfaces up.

---

## Credits

The original RK3518 bring-up — the DDR/idbloader lottery, the AIC8800 SDIO work, the SDIO-data-line
trap, and the "edit the vendor DTB" method — was worked out by
**[juliovendramini/rk3518_armbian](https://github.com/juliovendramini/rk3518_armbian)** (with AI
assistance for the device tree). This repo applies that method to one box, the R69. RK3518 support
lives inside Rockchip's **rk3528** rkbin; the device-tree base is the mainline Linux **Radxa ROCK
2F** (GPL-2.0+/MIT).

## If this repo ever gets renamed

GitHub redirects old clone/pull URLs after a rename, so a deployed `r69-update --pull` keeps working
(verified against decade-old renames). If you ever want to stop depending on the redirect, or it
breaks, one line re-points a box's clone:

```sh
sudo git -C /usr/local/share/r69/repo remote set-url origin https://github.com/sormy/<new-name>
```

Note: right after a repo layout change, the first `--pull` run may abort at a manifest check (the
old script meets the new tree) — the pull has already succeeded, so simply run
`sudo /usr/local/share/r69/repo/r69-update` again.

### 2026-08-09 — changes that reached the R69 from the second board's bring-up

Porting to the H96 Max turned the repo into a two-board builder, and several of its findings apply
here. Everything below is already in the R69 image; **`r69-update` picks it all up** on a deployed
box.

- **Hardware watchdog, enabled.** `snps,dw-wdt` @ `ffac0000` was `disabled` in the factory tree on
  both boards — vendor policy, not missing silicon. Now `okay`, with `RuntimeWatchdogSec=30` in
  `/etc/systemd/system.conf.d/zz-r69-watchdog.conf` as the consumer, so a hard hang reboots the box
  instead of leaving it dead. Proven on the H96 Max (a deliberate stop-petting test hard-reset it);
  the R69 now runs it too — `/dev/watchdog` present and systemd holding it. Timeout is fixed at 44
  s.
- **Edit this DTB with `fdtput`, not a dtc rebuild.** Recompiling `board.dts` here is **not**
  byte-faithful — the shipped `board.dtb` was never produced by dtc from it, so a rebuild drops
  `__symbols__` labels and reorders properties (16 diff lines). The H96's tree round-trips cleanly;
  this one doesn't. Single-property edits: `fdtput -t s board.dtb <node> status okay`.
- **The 90-second boot stall is gone.** The ROCK 2F base enables a getty on `ttyFIQ0` (its console
  is the vendor fiq-debugger). We disable that node to free `ff9f0000` for `ttyS0`, so the device
  never appears and systemd waited out the full device timeout on every boot. The image now ships an
  `/etc` unit with `ConditionPathExists=/dev/ttyFIQ0` that skips instantly. Serial login is
  unaffected — the getty generator spawns `serial-getty@ttyS0` from `console=ttyS0`.
- **`r69-update` is now installed on the box** at `/usr/local/sbin/`, alongside the generic
  `rk35xx-update` it delegates to. It previously existed only inside a deployed checkout, so the
  documented "run it on the box" instruction had nothing to run.
- **`kernel-prepare` names its own log.** The hook is shared with the other board now, so it derives
  the path from its own filename — still `/var/log/r69-kernel-prepare.log` here.
- **Do not delete files from an image with `e2rm`.** It produced a multiply-claimed block (a staged
  file was handed a block owned by filesystem metadata), which the kernel catches at boot by
  remounting the rootfs read-only. `build-image.sh` now runs `fsck.ext4 -fn` and refuses to emit a
  corrupt image.
- **`mmcblk` numbering is not stable** across images or boots. Identify the eMMC by its
  `boot0`/`boot1` companions, never by a remembered number — the recovery snippets in board.md do
  this now.

The R69's own contract is unchanged: it keeps every `r69-` name on disk, and the restructure was
regression-tested by rebuilding its image and diffing all 33 payload files against a pre-refactor
build — functionally identical, differing only in comments and whitespace.

### 2026-08-09 — rebased onto the box's own factory DTB, then migrated to eMMC

The R69's device tree was the last thing still derived from the Radxa ROCK 2F. Rebasing it onto
`stock/r69/board.dts` — the box's own Android tree — took the same six grafts the H96 Max needs, and
nothing else (see dtb.md). What it fixed, all of it for free:

- **CPU was overclocked 42%.** The ROCK 2F table offered OPPs to **2016 MHz** against this die's
  rated **1416 MHz**, and drove a `vdd-cpu` regulator on i2c1 that this board doesn't physically
  have — so the higher steps ran without the voltage the table assumed. Now 1200/1416 only.
- **Wi-Fi 32 kHz clock on the wrong pin** (`gpio3.19` instead of `clkm1-32k-out` on `gpio1.19`), and
  **USB 5V host enable on the wrong pin** (`gpio0.1` instead of `gpio4.13`) — the same stray-pin
  class that cost the H96 its first evening. Both worked by luck: the rails default on.
- A stray `pcie@fe4f0000` + `vcc3v3_pcie20` disappeared (RK3518 has no usable PCIe), `vcc_sd` and
  `vcc5v0_otg` gained the GPIO control the ROCK 2F tree lacked, and the eMMC HS200 cap we used to
  graft is simply what the factory already specifies.

**Regression-checked before deploying**, node by node: every subsystem enabled in both trees, and
the things that would fail silently are byte-identical — all eight IR usercodes (incl. `0xfb05`, so
the keymap is untouched), `adc-keys`, thermal trips, the PHY, and the Wi-Fi reset/host-wake pins.
Verified live afterwards: boots in 20 s, Wi-Fi and RK630 PHY up, watchdog armed, LEDs correct, IR
driver bound, lima probed, `cpuinfo_max_freq` = 1416000.

Unlike its predecessor, **this tree round-trips through `dtc -@`**, so `fdtput` is no longer needed
for edits here.

**Then eMMC.** `armbian-install` → "Boot from eMMC — System on eMMC" → ext4, first try. Root is now
`/dev/mmcblk2p1` (14.5 GB), no SD, boot 17 s. The loaders it wrote are byte-identical to this
board's own pair (`0c0add65…` idbloader, `c13ca928…` u-boot) — the issue-#6 override proven on a
second board, and pleasingly the eMMC's factory idbloader was already that same image.

MAC pinning still earns its keep: the AIC8800 reported a fresh permanent MAC this boot
(`88:00:33:xx:xx:xx`) while the interface runs the pinned `88:00:33:xx:xx:xx`, and both pinned
addresses are **identical to the ones recorded months ago** — they survived a DTB rebase and a full
migration because they derive from the SoC cpuid, not from storage.

**eMMC measured** (identical `fio` runs on both boards): sequential **91.6 MB/s read · 74.6 MB/s
write**, random 4K **4,542 read / 4,620 write IOPS**. Reads match the H96 Max exactly — that's the
HS200/100 MHz bus ceiling — but this Samsung part is **70% faster on sequential writes and ~50% on
random-4K reads** than the H96's Micron. The impression that R69 writes were slow came from
`armbian-install`'s small-file, sync-heavy copy, not the hardware.

**Bluetooth remote verified too**: it pairs as `Bluetooth remote` (battery reported), giving
Consumer Control + air-mouse nodes — and it is **the same BLE HID model as the H96's**
(`usb:v2B54p1600`) despite the two answering to different IR usercodes. Pairing needs one
`bluetoothctl` session with `default-agent` and a scan running; `--agent` alone or a separate `pair`
invocation fails with `AuthenticationFailed`.

### 2026-08-09 — video codec bring-up: this board was already right

Codec testing became a first-class check after the H96 Max turned out to have been unable to reach
its VPU at all (that board's worklog has the story). The R69 is the control case, and it needed **no
device-tree work**: its factory root compatible already carries `rockchip,rk3528a`, which is exactly
what `librockchip_mpp` substring-matches, so the library has always identified this SoC correctly
here.

What it did _not_ have is usable permissions. `/dev/mpp_service` (subsystem `mpp_class`), `/dev/rga`
and all three `/dev/dma_heap/*` nodes are created **root-only `0600`**, so no unprivileged player
can touch the VPU no matter which groups it is in — and nothing in Armbian's shipped rules covers
them (`90-chromium-video.rules` only handles mainline V4L2 M2M nodes, which this vendor kernel
doesn't create).

`firmware/common/rk35xx-vpu.rules` fixes that, and it is **verified here**: after installing it,
`udevadm trigger` flipped all five nodes to `root:video 0660`, and `udevadm test` names line 3 of
that file as the rule setting `GROUP 44` / `MODE 0660` on `mpp_service`. Note the two subsystems —
`mpp_class` for `mpp_service`, `misc` for `rga` — if you re-trigger by hand, match both or you'll
think the rule half-failed.

Getting to a matrix meant a toolchain: a bare Armbian has `git` and `gcc` but **no `g++`**, which
MPP's cmake needs. `apt install build-essential ffmpeg` plus cmake, and one trap worth the ink —
**build MPP out of tree.** Point cmake's output at `mpp/build/` (the obvious guess) and you delete
MPP's own `build/cmake/merge_objects.cmake`, after which every configure fails on
`Unknown CMake command "merge_objects"` with the cause already erased. Use `~/mpp-build`.

### 2026-08-09 — the matrix, measured

All runs on the R69, 30 frames, **as `art` — not root** (which is the point of the udev rule), MPP
built from `rockchip-linux/mpp` at `develop`. Detection first: `match chip name: rk3528a`, decode
caps `0x00f0079c`, encode caps `0x00100180`.

**Decode — fps, every format the SoC claims:**

| Format |        720p | 1080p |   4K |   8K |
| ------ | ----------: | ----: | ---: | ---: |
| H.264  |       324.3 | 148.9 | 37.3 |  8.1 |
| HEVC   |       602.8 | 319.3 | 84.8 | 20.0 |
| MJPEG  |       530.9 | 296.8 | 88.9 | 23.7 |
| VP9    |       635.1 | 324.9 | 84.8 |    — |
| MPEG-2 |       177.0 |  83.0 |    — |    — |
| MPEG-4 |       198.7 |  93.5 |    — |    — |
| VP8    |       128.2 |  59.3 |    — |    — |
| H.263  | 801.8 (CIF) |       |      |      |

**Encode — fps:**

| Format |  720p | 1080p |   4K |   8K |
| ------ | ----: | ----: | ---: | ---: |
| HEVC   | 126.3 |  61.0 | 15.9 |  4.0 |
| MJPEG  | 329.3 | 173.3 | 49.9 | 12.9 |
| H.264  |     — |     — |    — |    — |

Four things came out of this that no datasheet would have told us:

**1. VP9 decodes — so `rk3528a` is the right name.** 635/325/85 fps at 720p/1080p/4K. VP9 is the
_only_ capability separating MPP's `rk3528a` entry from its `rk3528` one, so this is the evidence
that the H96 Max's DTB graft should say `rk3528a`, and it is no longer a judgement call.

**2. 8K decode is real**, and not marginal: HEVC 20 fps, MJPEG 23.7, H.264 8.1. MPP's `vdpu382a`
struct sets `cap_8k = 1` and the silicon backs it. Nobody advertises this box as an 8K decoder.

**3. MPP's own capability table understates the encoder.** It marks `vepu540c` `cap_4k = 0`, i.e.
1080p only — yet HEVC encoded at 4K (15.9 fps) and **8K (4.0 fps)**, and `ffprobe` on the box
confirms the bitstreams really are `hevc,3840,2160` and `hevc,7680,4320`, not downscaled. MJPEG
encodes 4K at 49.9 fps. Treat "1080p encoder" as a floor, not a ceiling.

**4. H.264 encode is broken here too** — `size 0` at every resolution, exactly as on the H96 Max, so
it is an MPP HAL bug on `vepu540c` and not a board or DTB fault. HEVC on the same block is fine.

Two harness traps, both costing a confusing hour: **MJPEG decode needs explicit `-w`/`-h`** or the
frame buffer sizes to 0 and it dies at `mpp_buffer_get ... size 0` / `ret -2` — nothing to do with
the hardware. And a **VP9 profile-1 clip** (what `ffmpeg` gives you if the source isn't `yuv420p`)
prints `Profile 1 is not yet supported` and then **spins forever** instead of exiting — always run
these under `timeout`.

AV1 is refused precisely as it should be: `unable to create dec av1 for soc rk3528a unsupported`.
Note the tool's own banner lists AV1 and VP8 _encode_ regardless — that list is the library's
compiled-in set, not this SoC's; the `mpp_debug=0x10` caps line is the honest one. AVS/AVS+/AVS2 are
claimed by the caps but stay untested: no encoder exists to make a sample clip.

### 2026-08-09 — the H.264 encoder was never broken; MPP just never looked

The `size 0` failure looked like a dead H.264 path in the encoder, and the first instinct — mine
included — was to write it off as a silicon or HAL-revision limitation and tell people to use HEVC.
The interrupt counter said otherwise: across a 10-frame H.264 run the `rkvenc` IRQ incremented
**exactly ten times**, the same as a working HEVC run. Hardware that never encodes doesn't raise a
completion interrupt per frame. So the frames existed and something upstream of them was lying.

Diffing the two HALs on the same `vepu540c` block found it in a couple of minutes:

- `hal_h264e_vepu540c_status_check()` tests `regs_set->reg_ctl.common.int_sta.enc_done_sta`
- but the H.264 HAL's only `MPP_DEV_REG_RD` covers `reg_st` at `VEPU540C_STATUS_OFFSET`; the control
  block containing `int_sta` is **write-only** in that path
- so the "hardware status" it checks is the zero MPP itself wrote — `hw_status: 0x00000000`, every
  time, on every SoC using this HAL
- `hal_h265e_vepu540c` reads that word explicitly from `VEPU540C_REG_BASE_HW_STATUS` (0x2c) before
  checking it, which is the entire reason HEVC works and H.264 doesn't

Twelve lines — one extra `MPP_DEV_REG_RD` mirroring the H.265 path — and H.264 encodes at every
resolution: **116.3 / 55.0 / 14.4 / 3.6 fps** at 720p / 1080p / 4K / 8K, `ffprobe` confirming real
`h264,1920,1080` and `h264,7680,4320` bitstreams, the hardware decoder reading them back at 280 fps,
and HEVC unchanged at 60.9 fps. Patch kept at `mpp/` (patch + README).

This is an upstream bug, not an rk3518 quirk: any SoC whose H.264 encoding goes through
`hal_h264e_vepu540c` (RK3528, RK3562 and relatives) should be hitting it. Nothing in
`rockchip-linux/mpp` `develop` fixes it as of today, `nyanmisaka/mpp` carries the same code, and no
issue described it. Reported as #965 and fixed by Rockchip internally the next day — see the
2026-08-10 entry below.

**The lesson worth keeping:** "the vendor's own library says the hardware didn't finish" is not
evidence that the hardware didn't finish. `/proc/interrupts` is, and it costs one line to check.

### 2026-08-09 — deployed and rebooted

`rk35xx-deploy art@cnc --no-reboot` (this box answers to `cnc` now), then an explicit reboot. The
updater correctly reported _"device tree unchanged — no reboot needed"_: the R69's DTB is untouched
by the codec work, since its factory tree already names the SoC `rockchip,rk3528a`.

Back in ~24 s, boot 17.3 s, no failed units, DKMS modules installed and loaded, `/dev/watchdog`
present, Ethernet PHY still `RK630`. The VPU nodes come up `root:video 0660` **from the udev rule
now, on a cold boot** — not from the hand-install used during testing — which is the thing that
needed proving.

### 2026-08-10 — the H.264 fix is Rockchip's problem now

Reported upstream as [rockchip-linux/mpp#965](https://github.com/rockchip-linux/mpp/issues/965) with
the reproduction, the interrupt evidence and the diff. Answered the same day: _"We've confirmed and
fixed the issue internally — it will be synced to the GitHub repo with the next upstream update."_

So the bug is real, acknowledged, and fixed at the source rather than only in our tree. Worth noting
how that project works, for whoever reports the next one: every commit carries a `Change-Id`, so
GitHub is a mirror of an internal Gerrit. Three of forty-nine pull requests have ever been merged —
yet patches _do_ get taken, replayed internally and the PR closed with thanks. **File an issue with
the diff inline**; the reproduction is the part they can't reconstruct, and it does not depend on a
workflow they don't use.

Once the sync lands, `mpp/h264e-vepu540c-status.patch` can be deleted from this repo.

### 2026-08-11 — suspend measured, and it changes what the power button should do

`Suspend-to-RAM ✅` had been resting on "it drops off the network and wakes again", which a shallow
freeze does too. Measured properly now, with a power meter on the box and the kernel log alongside:

| State            | Power         | Back to usable |
| ---------------- | ------------- | -------------- |
| idle, after boot | **1.5 W**     | —              |
| suspended        | **0.7–0.8 W** | instant        |
| "off" (poweroff) | **0.8–0.9 W** | 17.5 s         |

and the kernel confirms which state it reached:

```
PM: suspend entry (deep)
PM: suspend exit
```

`deep`, not `s2idle` — `/sys/power/mem_sleep` reports `s2idle [deep]`, so `systemctl suspend` takes
the real suspend-to-RAM path. Resume comes back clean through `rk_gmac_resume`, `aicwf_sdio_resume`
and an xHCI reinit.

**Halving is the floor here, not a disappointment.** These boxes have no PMIC — the DT says
`rockchip,virtual-poweroff = <0x01>` — so the SoC parks and DDR self-refreshes, but the 5 V rails,
the Ethernet PHY and the Wi-Fi module stay powered because nothing can cut them. A board with a PMIC
would go well under 0.3 W; 0.75 W is what this hardware can do.

**The user-visible half is the more interesting result.** Waking from suspend lights the blue LED
_immediately_; a cold boot takes **17.5 s** (4.2 s kernel + 13.3 s userspace) before the box is
usable. For something that lives under a TV and gets switched on and off daily, that is the whole
difference between an appliance and a computer.

**"Off" costs more than sleep.** That was not the expected result, and it is the finding that
matters. Suspend walks every driver's `.suspend()` and parks the SoC with DDR in self-refresh;
`virtual-poweroff` halts, drivers get `.shutdown()` — which typically does much less — and nothing
puts DDR into a retention state because nobody cares about the contents. So "off" ends up parked
with more still running than when asleep. The ranges are adjacent, so the safe claim is that
powering off buys **nothing** over suspending; the likely claim is that it is slightly worse. Both
states show red-on/blue-off, so the LEDs are not the difference.

Which reopens a decision recorded earlier as settled. `zz-r69-powerkey.conf` ships
`HandlePowerKey=poweroff`, and that is systemd's own default — so the file looked like it was
asserting nothing and a candidate for deletion. On this hardware the better default is arguably
`suspend`: instant resume, 0.75 W while asleep, IR wake already working, and "off" is a fiction
anyway since the SoC never loses power. The drop-in then stops being redundant and becomes the one
line that states board policy. Left as `poweroff` for now — changing a shipped default deserves its
own decision, not a footnote to a measurement.

**Testing note for whoever does this next:** the R69 has no RTC (`/sys/class/rtc/` is empty) and its
`end0` was down, so there is no `rtcwake` and no Wake-on-LAN. Suspending it strands the box until
someone presses the remote. Do not suspend this board remotely unless a human is in front of it.

### 2026-08-11 — the MPP fix is upstream

`rockchip-linux/mpp` commit **`905020444`**, _"fix[hal_h264e]: Read back int_sta on vepu540c"_,
dated 2026-08-10 — one day after [issue #965](https://github.com/rockchip-linux/mpp/issues/965) was
filed. The code is ours verbatim (they dropped only the comment), and the commit is authored to
Artem Butusov, committed by Herman Chen.

So `mpp/h264e-vepu540c-status.patch` is deleted from this repo: any checkout at or after that commit
needs nothing from us, and older ones can cherry-pick a public commit. The board docs now say "needs
MPP >= `905020444`" instead of describing a local patch.

Worth remembering how that went, because it is repeatable: the report led with `/proc/interrupts`
showing one IRQ per submitted frame while MPP claimed "not done". That is what turned "this TV box
can't encode H.264" into a located bug in their code, and it took a day.

### 2026-08-13 — the wandering IP, and why the kernel was never at fault

The box kept landing on a different address after every reboot, and eventually stopped answering to
`r69-xr821` at all. Two separate things, and the SD card settled both — read on the Mac with
`debugfs`, no box required.

**The address moves because the Wi-Fi MAC does.** Four boots in one `/var/log/syslog`, four leases:

| boot | `wlan0`             | lease         |
| ---- | ------------------- | ------------- |
| 1    | `88:00:33:77:71:03` | 192.168.1.225 |
| 2    | `88:00:33:77:8d:e8` | 192.168.1.226 |
| 3    | `88:00:33:77:4f:9a` | 192.168.1.227 |
| 4    | `88:00:33:77:6d:3f` | 192.168.1.228 |

`CONFIG_WIFI_GENERATE_RANDOM_MAC_ADDR` was supposed to have fixed this, and it is set. It does
nothing here. The symbol only gates `get_wifi_addr_vendor()` inside `net/rfkill/rfkill-wlan.c`,
which a driver has to opt into by calling `rockchip_wifi_mac_addr()` — and `aic8800_sdio` never
does. Its call site is real but sits behind `CONFIG_USE_CUSTOMER_MAC`, hard-coded `n` in the
driver's own Makefile, and `CONFIG_PLATFORM_ROCKCHIP`, which nothing in this kernel defines. Not one
`rfkill-wlan` line appears in a boot log; that grep is what proved it rather than argued it.

So the address comes from `rwnx_send_get_macaddr_req()` — the firmware — and with no MAC in efuse it
answers with the vendor base plus two random octets. The tell was in the source all along:
`dflt_mac[] = { 0x88, 0x00, 0x33, 0x77, 0x10, 0x99 }` in `rwnx_main.c`, first four octets identical
to every address above.

The fix is `wireless-aic8800-persistent-mac.patch`: call `rockchip_wifi_mac_addr()` from the in-tree
path, gated on `CONFIG_RFKILL_RK` (which is what actually builds it, and is already `=y`), leaving
the firmware request as the fallback so a board without vendor storage doesn't fall through to one
fixed address shared by every box. Vendor storage works here — U-Boot used the same store to persist
`LAN_MAC`, which is exactly why `end0` has been stable all along while `wlan0` was not.

Compile-verified in the Armbian build; **not yet confirmed on hardware**, which needs three boots
reading `/sys/class/net/wlan0/address`.

**The box going offline was not a crash.** Worth writing down because the first instinct was to
suspect the new kernel. The evidence says otherwise, in order:

- `/var/lib/systemd/pstore/console-ramoops-0` ends `reboot: Restarting system` — the previous boot
  shut down cleanly, no panic, no watchdog bite.
- The last boot's log carries only the noise this board always prints (HDMI EDID reads, absent
  regulator lookups, `rkvdec2_init: failed on clk_get`), nothing new.
- The persistent journal names the trigger outright:
  `sudo[2006]: art : COMMAND=/usr/bin/systemctl reboot` at 02:50:06, followed by an orderly shutdown
  — `armbian-ramlog` synced, journald flushed.
- And then nothing. No journal entry, no syslog line, no fresh pstore archive. The SD records no
  successful boot after that reboot.

Which leaves the one question the card cannot answer: whether the box failed to come back, hung
before userspace got far enough to write anything, or simply booted from eMMC instead. Serial would
have said, and this is the second time that has been the answer — it is a **prospective**
instrument, and attaching it after the fact shows nothing.

**Same day, second pass — stop storing it, derive it.** The first fix made the driver call
`rockchip_wifi_mac_addr()`, which generates once and persists to vendor storage. Two objections
killed that design, both correct.

The first: the whole thing rests on `rk_vendor_write()` landing, and `emmc_vendor_write()` **ignores
the return value of the eMMC transfer** — a write that never reached the card still reports success
and logs nothing. The store itself is healthy (four copies at sector 7168 all validate, the version
counter walks 2→3→4→5 across them, 64376 bytes free), but a correctness argument that ends in "and
the write probably worked" is not one.

The second: `eth_random_addr()` mints a locally-administered `02:…`, throwing away the vendor OUI
the chip would otherwise present.

Both vanish if the address is **derived** rather than stored. `rockchip-cpuinfo` already reads the
16-byte `otp_id: id@a` cell on `otp@ffce0000` and folds it into `system_serial_high`/`_low`, both
`EXPORT_SYMBOL`ed from `arch/arm64/kernel/cpuinfo.c` — this box has been printing
`Serial : e7b0656439babdb6` every boot all along. So when the firmware answers with its own default
base (the tell that efuse holds nothing), keep the OUI and take the tail from there. Per-die, stable
by construction, identical from SD and from eMMC, nothing written anywhere.

Two config consequences: `ROCKCHIP_CPUINFO` moves from `=m` to `=y`, because two modules racing to
probe is not a contract; and `WIFI_GENERATE_RANDOM_MAC_ADDR` is dropped, since it would win over the
derivation and hand back the `02:…` random address instead.

The lesson for the next board is in AGENTS.md: prefer efuse, then the SoC OTP id, and only then a
store that has to be written.

**Same day, third pass — the randomness was ours, not the firmware's.** The derivation shipped and
the address kept moving. Right kernel, matching `srcversion`, no DKMS copy, `rockchip-cpuinfo` at
6.76 s against Wi-Fi at 23 s, serial reported, and the shipped `.ko` disassembled to exactly the
code written. All true, none of it the answer.

Raising `aicwf_dbg_level` (it defaults to `LOGERROR`, which is why the line had never appeared)
settled it:

```
[   22.866458] AICWFDBG(LOGINFO)	get macaddr: 00:00:00:00:00:00
```

The firmware returns **zeros**, not its default base, so `memcmp(mac_addr_efuse, dflt_mac, 4)` could
never match. The driver falls through to `dflt_mac[]`, whose last two bytes `get_random_bytes()`
filled ~250 lines earlier. Seeding `dflt_mac[]` from the OTP id instead covers every fallback path;
three cold boots now give `88:00:33:65:64:b6` and one lease.

Two wrong root causes in a row, both from reading source and reasoning forwards. Instrument the
decision point first — and check whether a silent driver is merely gagged.

**Bluetooth, for contrast:** stable `BD_ADDR` `0B:3B:22:AC:88:20` on the same chip. Not burned in
either — `0x0B` has the I/G bit set, and the bytes are in none of the AIC firmware blobs. What is
burned in is RF trim (`PWROFST`, `DRVIBIT`, `USRDATA`, `SDIOCFG`, `USBVIDPID` — no MAC region). BT
cannot operate without an address so its firmware derives one; Wi-Fi can take a host-supplied MAC,
so nobody bothered. Whether two units collide is untested. If it bites:
`HCI_QUIRK_USE_BDADDR_PROPERTY` and `local-bd-address` on the serdev node (`hci_sync.c`).

### 2026-08-14 — power measured bare, and sleep wins

Three states on the Armbian build, meter on the DC input, **no HDMI and no USB attached**:

| State            | Power         | Back to usable |
| ---------------- | ------------- | -------------- |
| idle, after boot | **1.1–1.2 W** | —              |
| suspended        | **0.3 W**     | instant        |
| off (poweroff)   | **0.4–0.5 W** | ~17 s          |

The 2026-08-11 set (1.5 / 0.7–0.8 / 0.8–0.9 W) was taken with a USB device plugged in and probably
HDMI, so the two are not comparable and the drop is not a property of the build.

**This reverses the earlier conclusion.** That entry said "off costs about the same as sleep, or
more", and made `HandlePowerKey=suspend` merely defensible. Measured bare, suspend is the cheapest
state _and_ the fastest to return from: 0.3 W and instant, against 0.4–0.5 W and a 17 s cold boot.
The shape makes sense — suspend runs every driver's `.suspend()` and parks DDR in self-refresh via
PSCI, while `rockchip,virtual-poweroff` halts with the rails up and drivers only get `.shutdown()`.

**On dropping rails ourselves, the standards answer is one-sided.** Eight rails are
`regulator-always-on` in the factory tree — `dc_12v`, `vcc5v0_sys`, `vcc5v0_host`, `vdd_cpu`,
`vdd_0v9_s3`, `vdd_1v8_s3`, `vcc_3v3_s3`, `vcc_ddr_s3` — and the USB host 5V (`vcc5v0_host`,
gpio4.13) carries `regulator-always-on` verbatim from `stock/r69/board.dts`, so stock Android leaves
USB powered in "off" too. HDMI has no switchable rail at all: no HDMI supply reference exists in the
tree.

- **Suspend has a standard mechanism** — `regulator-state-mem { regulator-off-in-suspend; }`, used
  by 130 Rockchip boards in-tree. Our tree has **none**. It is the correct place to drop a rail.
- **Poweroff has none.** The regulator bindings define suspend states only; there is no
  shutdown-state property. Cutting a rail at poweroff means a driver `.shutdown()` or a userspace
  hook — the split across layers AGENTS.md forbids.

Which lands on the honest recommendation: do not fight `virtual-poweroff` on a PMIC-less board.
Prefer the state the hardware is good at. Open decision: whether to ship `HandlePowerKey=suspend`,
given the plan had dropped that drop-in as "asserts systemd's own default" — it no longer does, and
the measurement is the reason to reconsider.

### 2026-08-14 — the power key's long press works, but only over BLE

`HandlePowerKey=suspend` was easy once the power numbers were in. The force-off half took a detour
worth recording, because the answer was in the remote, not in the config.

Holding the key over **IR** never reached systemd's long press. `evtest` on the IR node explains it:
however long the button is held, the release arrives about 2 s in, so logind runs the short action.
The driver has no cap of its own — its timer is re-armed 130 ms after each NEC repeat frame — so it
is the repeats that stop. And the threshold is not adjustable: `logind.conf` exposes the
`*LongPress=` actions but no duration, systemd hardcoding 5 s in `logind-button.c`.

Two dead ends were considered and dropped. Patching the driver cannot make a remote transmit longer.
Remapping a labelled button to `KEY_RESTART` and setting `HandleRebootKey=poweroff` does work — the
key table lives in the DTB, and the driver never reports `MSC_SCAN`, so udev's keymap has nothing to
remap — but a button printed "Google Play" that silently powers the box off is worse than no button.

**Pairing over BLE settles it.** The remote is one mode at a time: connected over BLE it stops
transmitting IR entirely. Its `Bluetooth remote Consumer Control` node (the only BLE node declaring
`KEY_POWER`; the other two are the air-mouse and a keyless vendor node) is plain HID, so the key
holds until released and the 5 s long press fires normally.

So the shipped policy is `HandlePowerKey=suspend` + `HandlePowerKeyLongPress=poweroff`: tap sleeps,
hold powers off, and the hold half is live only while the remote is paired. `systemctl poweroff`
works either way.

**The two directions use different radios.** Bluetooth is dead in suspend and in "off", so only the
IR receiver is armed as an ATF wake source: waking is always IR. The remote handles the switch
itself — BLE while connected, IR once the link is gone, which is precisely when the box is asleep.
So a paired remote both powers the box off (long press over BLE) and wakes it (IR), with no bond to
remove. The only practical consequence is line of sight: waking needs the remote pointed at the box.

### 2026-08-14 — Wake-on-LAN: the PHY is inside the SoC, so it cannot work

`ethtool` advertises `Supports Wake-on: ug`, which is what sent this down a two-hour path. Arming it
was straightforward and entirely ineffective: `ethtool -s end0 wol g`,
`/sys/class/net/end0/device/power/wakeup` reading `enabled`, and `stmmac: wakeup enable` logged at
suspend — then ten magic packets, unicast and broadcast, on ports 9/7/0, with the box sitting in
`PM: suspend entry (deep)`. No wake, twice.

The `dmesg` line that looked like the answer was
`rockchip-suspend not set wakeup-config for mem-lite`. The RK3528 header does define
`RKPM_GMAC_WKUP_EN` (BIT 8), and the factory tree ships `rockchip,wakeup-config = <0x11>` —
`RKPM_CPU0_WKUP_EN | RKPM_GPIO_WKUP_EN` — so GMAC wake genuinely was not routed to the power
controller. Setting `0x111` and rebuilding changed nothing, and the graft was reverted: a graft
needs a functional consumer.

The real reason is one property in the PHY node. WoL needs the **PHY** alive while the MAC sleeps,
since the PHY is what sees the magic packet and raises the PMT interrupt. Ours is
`phy-is-integrated` — an in-SoC FEPHY (`ethernet-phy-id0044.1400`) with no `phy-supply` to hold up —
so deep suspend takes it down with the rest of the die. The MAC node was never the problem: it
already carries `interrupt-names = "macirq", "eth_wake_irq"`, the PMT interrupt that the RK3288 WoL
series had to add.

Two pieces of corroboration. Across the 80 Rockchip boards in this BSP, the wake sources actually
enabled are GPIO (76), CPU0 (27), USB (25), cluster and PWM — `RKPM_GMAC_WKUP_EN` is used by
**none**. And the platforms where Rockchip WoL is documented working (RK3288, RK3568 guides) all
drive **external** PHYs with their own regulator, which is exactly the thing this board lacks.

So `board.md`'s existing warning stands, now with a mechanism rather than an observation: no RTC, no
WoL, and a suspended box is stranded until someone presses the remote.

### 2026-08-14 — the way back, proven before it was needed

The DDR gate (does a stock rkbin blob train this DRAM?) is the last untested thing in the port, and
testing it means putting an unproven loader where the working one lives. That is only a sane
experiment if the recovery path is known good, so it was proven first.

`build-rktools.sh` builds `rkdeveloptool` into `tools/` (gitignored) from a pinned upstream commit.
Two things it has to get right on macOS: Homebrew keeps `libusb` off the default search path, so
`PKG_CONFIG_PATH` needs pointing at it; and upstream compiles `-Werror` while using C++ VLAs, which
clang refuses — allowed with `-Wno-error=vla-cxx-extension` rather than dropping `-Werror`
wholesale. It builds **natively on purpose**: USB devices do not pass through to containers on
macOS, so a containerised binary would compile and never reach the box.

With the box held in maskrom by the AV-jack button:

```
DevNo=1	Vid=0x2207,Pid=0x350c,LocationID=101	Maskrom
```

`rci` returns "Read Chip Info failed!", which is correct rather than broken — the read/write verbs
need a USB loader running, sent with `db`; bare maskrom only answers enumeration.

Worth noting what this corrected: the original recon entry claimed there was **no** reset button in
the AV jack, which made maskrom look like it needed luck. There is one, it works, and the whole
recovery chain — trigger, enumeration, host tool — is now verified rather than assumed. That is now
a "Done means" criterion in AGENTS.md: untested recovery is not recovery.

### 2026-08-17 — the submission tree wired ethernet to the PHY, and the gate was built not to see it

Chasing a Wi-Fi latch, the DTB regeneration looked like the culprit. It was not: every reference in
the SDIO node resolves (`mmc-pwrseq` → `/sdio-pwrseq`, `pinctrl-0` → the three `sdio1` groups), and
an early claim that they dangled came from `find` not following the `/proc/device-tree` symlink. A
control lookup on a known-good phandle killed that theory. What the search did turn up was a real
defect one layer over, in the upstreaming tooling.

`snps,axi-config`, `snps,mtl-rx-config` and `snps,mtl-tx-config` reach the controller's own
`stmmac-axi-config` / `rx-queues-config` / `tx-queues-config` subnodes by bare phandle. dtcx's
property table did not list them, so they decompiled as numbers, and `gen-overrides.py` copied the
numbers into the include-based tree — which allocates its own phandles:

| property                     | factory tree             | submission tree |
| ---------------------------- | ------------------------ | --------------- |
| `gmac0` `snps,axi-config`    | `gmac0_stmmac_axi_setup` | `spdifm0_pins`  |
| `gmac0` `snps,mtl-rx-config` | `gmac0_mtl_rx_setup`     | `rmii0_phy`     |
| `gmac0` `snps,mtl-tx-config` | `gmac0_mtl_tx_setup`     | `macphy_bgs`    |
| `gmac1` `snps,axi-config`    | `gmac1_stmmac_axi_setup` | `sdio1_bus4`    |
| `gmac1` `snps,mtl-rx-config` | `gmac1_mtl_rx_setup`     | `sdio1_cmd`     |
| `gmac1` `snps,mtl-tx-config` | `gmac1_mtl_tx_setup`     | `sdio1_clk`     |

stmmac resolves those, finds no queue subnodes and fails `-EINVAL`.

The gate said `VERIFIED` throughout, because it stripped every `phandle = <` line before diffing.
That drops the definitions, which is where the two trees disagree, and keeps the literals, which are
the same text in both. The one class of error it had to catch was the one class it filtered out.

The deployed blob was never affected: `firmware/r69/board.dtb` carries the factory numbering, where
`0x71` is the queue-config node. Only the include-based submission was wrong — which is what PR 528
shipped.

Auditing the rest of the table against `rk3528.dtsi` found the mirror-image error.
`rockchip,taskqueue-node` and `rockchip,resetgroup-node` are MPP **indices** (`<0>` … `<4>`), not
phandles; listing them made dtcx invent `&cru`, `&cpu0`, `&gic` from the index value. Neither
direction shows up in a round trip — the value recompiles to the same number in the same tree — so
`make test` passed the whole time. Every other vendor entry checked out.

Fixed: dtcx patch 0001 no longer claims the two index properties, new patch 0005 adds the three
stmmac ones, `scripts/check-refs.py` fails the build if a name seen as `<&label>` anywhere also
appears as a bare cell list, and `scripts/remap-phandles.py` translates the native tree's phandle
values onto the patched tree's by node path so the diff compares every line including them. Both
trees come out identical that way, 0 nodes unmatched — they differ only in the order nodes are
written. Both boards' `&gmac0` overrides disappeared entirely once the properties compared equal to
the reference dtsi. `board.dtb` is byte-identical before and after; only the source text changed.

### 2026-08-17 — the annotated submission file, and the comments that were never true

Rechecking every per-block comment in `armbian-native-annotated.dts` against the reference dtsi and
the factory tree:

| comment                                        | what the block does                                                                           |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------- |
| serial comes from a different OTP cell         | appends a fourth cell, `cpu-code1`; the serial is `otp_id` and is untouched                   |
| the OTP cell /cpuinfo reads for the SoC serial | the same cell, the same error                                                                 |
| no vendor boot logo (×2)                       | `logo,kernel` and `logo,uboot` still set; `logo,mode` goes center → fullscreen                |
| no vendor boot logo, nothing to reserve        | `drm-logo@0` untouched; the block adds an 8 MB CMA pool                                       |
| mainline lima expects bus/core                 | real, but it lives in `armbian.patch`; this block only repoints `mali-supply` at the one rail |
| one voltage bin, not the reference spread (×5) | true for three; `opp-1416000000` keeps six bins and gpu `opp-800000000` seven                 |

The rest restated the code — `unwired`, `enabled in the factory tree`, `Wi-Fi pins as routed here`.

The cause is structural, not carelessness. Those overrides describe the **vendor's** board, and the
vendor shipped a blob with no reasons in it. A rule asking for one comment per block asks for
reasons that do not exist, so they got invented — and an invented reason reads exactly like a
checked one.

The file was the other half of it: a hand-maintained copy of generated output, kept only to hold
those comments. Deleted. `build.sh` now emits `armbian-native.dts` as `header.dts` plus the
generated overrides and compiles that, so the submission has no second copy to drift from. Per-board
source is `armbian.patch` and `header.dts`, nothing else.

The deliberate departures from the factory tree are knowable — they are the patch — so they moved
into `header.dts`, one line each, checked against it. The commit message points there instead of
repeating the list.

Corrected while checking: the commit message claimed the trees share 581 nodes. Measured 580, from
598 in the reference and 593 here.

### 2026-08-17 — the broken submission was what the box actually booted

This box runs the upstreamable Armbian from SD, so its tree comes from `linux-dtb-vendor-rk35xx`,
built from the submitted DTS — not from `firmware/`. Decompiling the blob it was booting:

```
snps,axi-config   = <&spdifm0_pins>
snps,mtl-rx-config = <&rmii0_phy>
snps,mtl-tx-config = <&macphy_bgs>
```

and in the kernel log:

```
rk_gmac-dwmac ffbd0000.ethernet: Not all RX queues were configured
rk_gmac-dwmac: probe of ffbd0000.ethernet failed with error -22
```

So the phandle defect was never theoretical and never in `firmware/` — it shipped, and this box had
no ethernet because of it. The overlay tree was fine throughout, which is why the fault looked
invisible from the repo.

Installed the rebuilt `upstream/r69-xr821/armbian-native.dtb` (md5 `01ce4a99`) over the packaged
one, keeping the original beside it as `.known-good`, and rebooted. After:

| check        | result                                                          |
| ------------ | --------------------------------------------------------------- |
| stmmac probe | ✅ clean, no `-22`                                              |
| `end0`       | ✅ present, `PHY [stmmac-0:02] driver [RK630 PHY]`              |
| Bluetooth    | ✅ `hci0`, UART                                                 |
| LEDs         | ✅ `power`, `standby`                                           |
| VPU          | ✅ `/dev/mpp_service`, `/dev/rga`, `renderD128/129`             |
| IR           | ✅ `rc0`                                                        |
| link traffic | 🟡 no cable attached — probe and PHY bind verified, not traffic |

Two caveats. The DTB is package-owned, so an `apt` upgrade of `linux-dtb-vendor-rk35xx` puts the
broken one back until PR 528 lands. And `/proc/device-tree/compatible` shows two entries where the
source has four — u-boot rewrites the tree it hands Linux, which is exactly why the factory blob is
carved from eMMC and never read off a running box.

### 2026-08-20 — the R69 has been on 5 GHz all along; `board.md` said it never had

Correction to a claim that had been sitting in `board.md`'s known gaps: "**Wi-Fi 5 GHz** association
(only 2.4 GHz has ever linked here)". False. `cnc` (this board, `board-id` = `r69`) is associated on
5 GHz and has been for the two days of its current uptime:

```
bssid=<redacted-bssid>          wifi_generation=6
freq=5200                        key_mgmt=SAE   pmf=1
ssid=<redacted-ssid>                   wpa_state=COMPLETED
```

Channel 40, Wi-Fi 6, WPA3-SAE, −51 dBm (`/proc/net/wireless`), driver `aicwf_sdio`. The PHY rate was
not captured — `iw` is not installed on that box and the AIC driver exposes no `/proc` node for it,
so only the association is recorded, not throughput.

**How the wrong claim survived.** It was never measured either way; the 2.4 GHz figure in the
measured table was real, and "only 2.4 GHz has ever linked here" was written as the complement of it
rather than as an observation. A negative claim about hardware needs its own evidence — absence of a
measurement is not a measurement of absence. The README's `Wi-Fi 5 GHz ✅` for this board had been
right; a sweep "corrected" it to 🟡 to match the board doc, propagating the error rather than
catching it. Sweeps should reconcile a doc against the box, not against another doc.

Incidental confirmation while reading `wpa_cli status`: `address=8a:00:33:fc:16:a0` against the
chip's own `p2p_device_address=88:00:33:77:4e:51`. `wlan0` is the derived address, from the
`wlan0 8a:00:33` line in `firmware/r69/mac-oui` — that prefix already carries the
locally-administered bit, and `rk35xx-mac-pin` sets it again regardless. The unpinned p2p address
shows the AIC's raw `88:00:33`, which is not a registered OUI.

### 2026-08-20 — documentation verified against the running box, two corrections

Queried `cnc` read-only and checked every claim in `board.md` and `board-validation.md` that a live
box can settle. Confirmed as documented:

| Claim                            | Box                                                                |
| -------------------------------- | ------------------------------------------------------------------ |
| stable input paths               | `ir-remote → event5`, `adc-keys → event4`                          |
| watchdog armed by systemd        | `Using hardware watchdog 'Synopsys DesignWare Watchdog'`           |
| vendor PHY bound                 | `RK630 PHY`, not Generic                                           |
| `end0` on the label address      | `c4:2a:fe:10:51:77`, matching `rk35xx-vendor-storage lan`          |
| modules-load                     | `rockchip_pwm_remotectl_rk35xx` + `rk630phy`, both in `lsmod`      |
| VPU nodes reachable unprivileged | `/dev/mpp_service` and `/dev/rga` both `660 video`                 |
| factory OPP table                | `scaling_available_frequencies` = `1200000 1416000`                |
| deep sleep                       | `s2idle [deep]`                                                    |
| the 1.5 GB ceiling               | `free -m` total 1465                                               |
| runs from eMMC                   | root `/dev/mmcblk2p1`, the disk with `boot0`/`boot1`               |
| boot time                        | 16.4 s (4.07 kernel + 12.33 userspace) against a documented ~17 s  |
| identity + banner                | `BOARD_NAME="R69 XR821_V1.1"`                                      |
| `grep -c rfkill-wlan` on the log | `0`, the documented answer meaning vendor storage is not consulted |

**Two corrections.**

`board.md` said "Two entries under `/sys/class/leds/`". There are three — `power`, `standby` and
`mmc2::`. The third is registered by the eMMC host at `ffbf0000.mmc` and appears nowhere in our tree
(`grep -c mmc2` on the shipped `board.dtb` is 0); it drives no physical LED. The docs now name the
two board LEDs rather than counting the directory.

`board-validation.md` said "the AIC8800 exposes `bustx_thread_prio` and `busrx_thread_prio`" without
saying where. They are real but live under `/sys/module/aic8800_fdrv/parameters/` — not
`aicwf_sdio`, which is the bus driver name `wlan0` reports and is not a loaded module at all. The
loaded pair is `aic8800_fdrv` + `aic8800_bsp`.

`end0` reads `speed -1`, `duplex unknown` — no cable on this box, which lives on 5 GHz. Not a
regression; the 100FD figure in `board.md` was measured with a cable attached.

### 2026-08-21 — the watchdog timeout was never fixed at 44 s; we shipped half the window

`rk35xx-watchdog.conf` had claimed since it was written that "the hardware timeout is fixed at 44 s
and cannot be changed", and shipped `RuntimeWatchdogSec=30` to sit under it. Both wrong. Traced from
a sibling RK3518-class box's watchdog write-up, then confirmed against this board.

dw-wdt steps are `2^(16 + TOP) / clk`. `clk_summary` on the R69:

```
tclk_wdt_ns   1  1  0  24000000  ...  ffac0000.watchdog  tclk
```

24 MHz, so `2^30/24e6` = 44.7 s (TOP 14) and `2^31/24e6` = **89.5 s** (TOP 15). Two useful steps,
not one, and we were on the lower.

**Why it matters, and it is not cosmetic.** The watchdog cannot be stopped once armed and keeps
counting across a soft reboot, so `shutdown + boot` has to finish inside what is left of the window.
On the sibling box that budget ran out: ramoops caught `watchdog: watchdog0: watchdog did not stop!`
immediately before `reboot: Restarting system`, the next boot was reset at 15.91 s monotonic, and it
stayed dark six hours until power was pulled. Not reproduced here — 🟡, same SoC and same block.

Fixed the payload to `RuntimeWatchdogSec=80` and applied it to `cnc` in place (`install` the drop-in

- `systemctl daemon-reexec`, no reboot):

```
Watchdog running with a hardware timeout of 1min 29s.
```

Afterwards: 0 failed units, `cncjs` active, uptime unbroken at 2 d 12 h. The H96 Max carries the
same config and gets it on the next deploy; it was not touched.

Also worth knowing: `RebootWatchdogUSec=10min`, systemd's default shutdown window, is unreachable —
the driver clamps to 89 s, so systemd believes it has ~7× the protection the hardware can give.

**How the wrong claim survived.** It was written into a payload comment, then copied into
`board-bringup.md` during a docs sweep because the comment was treated as the source of truth. One
`clk_summary` read would have settled it at any point. A hardware constant in a comment is a claim
like any other and needs its arithmetic shown.

### 2026-08-21 — the watchdog does not fire on resume; whether it counts in sleep is still open

Two questions were being conflated. Separated and answered what the evidence covers.

✅ **It does not fire on wake.** This box suspended and resumed with the watchdog armed, and never
reset:

```
Aug 18 19:54:31  Watchdog running with a hardware timeout of 44s
Aug 18 20:49:24  PM: suspend entry (deep)
Aug 18 20:49:28  PM: suspend exit
```

Still one boot in `journalctl --list-boots`, `boot_id` unchanged, `uptime -s` still 19:54:38 three
days on. The resume path runs identically whatever the sleep length, so a 4 s sleep exercises it
completely — the duration only decides whether the counter expires _during_ sleep, which is a
different question.

The driver makes that ordering deliberate. `dw_wdt_resume()` restores `TIMEOUT_RANGE` first — it
carries TOPINIT, so enabling loads the full window instead of a hardware default — then restores
`CONTROL` to re-enable, then `dw_wdt_ping()`s. The counter starts from the top at resume with the
whole window left for the rest of the resume and systemd's first ping. Proven at 44 s; the margin at
89 s is strictly larger.

🟡 **Whether it counts through sleep is still unproven.** `dw_wdt_suspend()` gates both
`tclk_wdt_ns` and `pclk`, which should stop the counter, and that gating is load-bearing because
userspace is frozen and systemd cannot ping. But 4.2 s is the longest suspend ever recorded with the
watchdog armed, well under even the 44 s step. The 2m42s H96 Max suspend that looks like proof is
dated 2026-08-08, one day before the watchdog shipped.

Test recorded in `watchdog.md`: sleep 2 min, watch from the host, and note it needs hands at the box
— there is no RTC, so a correctly-behaving watchdog leaves the box asleep until someone presses the
remote. Success is what strands it.

### 2026-08-21, later — correction: the 4 s suspend proves nothing about the watchdog

The entry above claimed ✅ "it does not fire on wake" on the strength of the 2026-08-18 suspend,
reasoning that the resume path runs identically however long the box slept. The code path does. The
**counter's remaining value does not**, and that is the variable that decides.

At 44 s systemd pinged every 22 s, so at suspend entry the counter held 22–44 s. After 4.2 s of
sleep it held ~18–40 s **whether or not the clock was gated** — nowhere near expiry either way, so
nothing could have fired. The run is equally consistent with both hypotheses and discriminates
neither.

The two questions are also one experiment, not two. If the clock is not gated the counter expires
around 89 s into sleep; whether that surfaces as a reset _during_ sleep or as one landing on the
wake path depends on whether the reset is masked while the SoC is in deep suspend. Only a sleep
longer than the window produces either.

Downgraded to 🟡 in `watchdog.md`, merged back into a single question with a three-outcome table
that tells the two failure shapes apart.

### 2026-08-21, evening — settled: the watchdog is gated in sleep, and does not misfire on wake

Ran the test properly this time. Watchdog armed at 89 s, box idle (cncjs holding `/dev/ttyUSB0` but
no job streaming, load 0.04, no sleep inhibitors). Suspend scheduled through a transient
`systemd-run --on-active=20` unit so the SSH session was gone first — an active session interferes
with _entering_ suspend, per the 2026-08-17 entry.

```
18:46:16.818  PM: suspend entry (deep)
18:55:02.966  PM: suspend exit          -> 526.1 s, 5.9x the 89.5 s window
```

- `boot_id` **unchanged** — `196099eb-194c-4204-b58e-a8430f16fba9` before and after.
- `uptime -s` still 2026-08-18 19:54:38; one boot in `journalctl --list-boots`.
- Polled from the host every 2 s throughout: unreachable from 18:46:19 until the remote press, so it
  never self-reset and rebooted.
- After resume systemd still owns `/dev/watchdog0` (`wdctl` reports it busy) at
  `RuntimeWatchdogUSec=1min 20s` — resume re-arms rather than silently dropping protection.
- 0 failed units, `cncjs` active.

That closes both halves at once. The counter cannot advance with `tclk_wdt_ns` gated, and
`dw_wdt_resume()` restoring `TIMEOUT_RANGE` (with TOPINIT) before re-enabling `CONTROL` and then
pinging means the wake path starts from a full window. **Suspend costs nothing from the budget; only
a soft reboot carries it forward.**

Incidental: `xhci-hcd xhci-hcd.4.auto: xHC error in resume, USBSTS 0x401, Reinit` on resume here too
— the same benign warning already recorded on the H96 Max (0x411 there). The controller
reinitialises and USB works.

Still 🟡 on the H96 Max, which was not touched.

### 2026-08-21 — why U-Boot hands over the wrong MAC: we build mainline, which has no vendor storage

Chased the `36:c8:c4:28:e4:08` on `end0`. The standing explanation — U-Boot read the vendor store on
its _boot device_, found no `LAN_MAC` on the SD and invented one — does not hold: this box boots
from eMMC, whose store has `LAN_MAC = c4:2a:fe:10:51:77`, and it still handed the kernel `36:…`.

The real cause is our own build. Vendor storage is a Rockchip downstream driver and we ship
**mainline** U-Boot, so there is nothing to read `LAN_MAC` with:

```
strings -a firmware/common/u-boot.itb | grep -iE 'vendor.?storage|LAN_MAC|rockchip_set_ethaddr'
-> only the generic "ethaddr" variable name
```

What sets it is `rockchip_setup_macaddr()` in `arch/arm/mach-rockchip/board.c`: SHA256 of the OTP
`cpuid#`, first six bytes, `mac_addr[0] &= 0xfe` then `|= 0x02`. `0x36` has the multicast bit clear
and the LA bit set, exactly that masking. `CONFIG_HASH`, `CONFIG_SHA256` and `CONFIG_ROCKCHIP_OTP`
are all `y`, so the path is live.

**It is deterministic, not random.** `net_random_ethaddr()` exists only as an `eth-uclass.c`
fallback for a device with no valid address, and is never reached because `ethaddr` is set first.
Three docs claimed U-Boot "invents one with `net_random_ethaddr()`" and writes it back to vendor
storage — that is Rockchip's _vendor_ U-Boot, not what we ship. Corrected in `board-validation.md`,
`armbian-install.md` and `upstream.md`.

Consequence for `armbian-install.md` in particular: after a wipe our U-Boot cannot recreate `DVKR`
at all, so the old "a fresh store holding a random MAC already exists before userspace runs" is
wrong here — there is simply no store until the window is restored from the dump.

**Two routes would let U-Boot get it right, neither free.** `rockchip_setup_macaddr()` returns early
`if (env_get("ethaddr"))`, so a pre-set `ethaddr` wins — but `CONFIG_ENV_IS_NOWHERE=y`, there is no
persisted environment to put it in, and adding `CONFIG_ENV_IS_IN_MMC` means finding space in the
reserved window. Otherwise we carry a vendor-storage patch on mainline. Left alone for now:
`rk35xx-mac-pin` already lands the label address, and the address U-Boot picks meanwhile is stable,
so nothing churns between boots.

### 2026-08-21 — Rockchip's own U-Boot would not fix the MAC either

Checked whether switching to the vendor tree solves `end0`. It does not, and the evidence is already
on the box: Armbian's `linux-u-boot-rock-2f-vendor` (the package we hold) ships its own defconfig
and build metadata under `/usr/lib/linux-u-boot-vendor-rock-2f/`.

It is unmistakably the downstream fork — `CONFIG_ANDROID_BOOTLOADER=y`, `CONFIG_ANDROID_AVB=y`,
`CONFIG_CMD_BOOT_ANDROID=y`, and
`CONFIG_SPL_FIT_GENERATOR="arch/arm/mach-rockchip/make_fit_atf.sh"`, a mechanism long gone from
mainline.

Two things settle it:

- `CONFIG_ROCKCHIP_VENDOR_PARTITION=y` and `vendor_storage_init` in its `u-boot.itb`, so it **can**
  read the store — but `# CONFIG_ROCKCHIP_SET_ETHADDR is not set`, so it never turns `LAN_MAC` into
  `ethaddr`. Reading the store and using it for the MAC are separate switches, and Armbian enables
  only the first.
- `UBOOT_TARGET_MAKE='BL31=…/rk3528_bl31_v1.17.elf …'` — this is the direct evidence for the
  long-standing "the stock ROCK 2F loader is too old" claim, which until now named no version. v1.17
  predates RK3518, hence `Unknown SoC`.

So the vendor tree costs us `distro_bootcmd` and a working BL31, and buys nothing on the MAC.
`docs/uboot.md` now names v1.17 with its source instead of hedging.

### 2026-08-25 — the A-to-A cable cannot power the box, so the recovery order stands

Question raised on the README's maskrom steps: should the sequence be hold-button-then-plug-USB,
with the cable powering the box, rather than hold-button-then-apply-power?

No — and the tree settles it. `vcc5v0_otg` on both boards is a `regulator-fixed` with
`vin-supply = <&vcc5v0_sys>` behind a GPIO enable (gpio4.18 on the R69, gpio4.12 on the H96 Max).
VBUS on the OTG connector is therefore **sourced by the box from its own 5 V rail, through a switch
the box controls** — an output, not an input. Host VBUS arriving on that pin meets the output of a
load switch whose input is the board rail, so the cable carries data only and the box still needs
its PSU. (`vcc5v0_host` is the same shape but `regulator-boot-on` + `regulator-always-on`.)

Searching around confirms this is board-dependent in general — some Rockchip devices do run off the
A-to-A, others need the supply as well — so it was worth checking rather than copying a generic
recipe.

The worklog never recorded which power source the 2026-08-14 proving run used, only "held at
power-on" and the `2207:350c` enumeration. The hardware answers it regardless. README now states the
cable is not a power source and gives the order explicitly, so the step does not get "corrected"
into something that cannot work.

### 2026-09-05 — this board's U-Boot is now its own build

> **Held back on 2026-09-06 — this board is still on the shared loader.** What follows is what was
> built, not what ships. See the 2026-09-06 entry below.

Family-wide change made during the H96 Max 3518D bring-up; `docs/uboot.md` has the detail and
`docs/h96max-3518d/worklog.md` the reasoning. `firmware/r69/uboot.dts` → `firmware/r69/uboot.itb`
was built and wired through `BOARD_UBOOT` in `board.conf`. The installed path also changed, from
`u-boot.itb` to `uboot.itb` — that half did stick, and `rk35xx-update` drops the stale name.

What it buys here: `CONFIG_ADC` + a correctly-named `saradc` node should make the recovery button
drop U-Boot into Maskrom. The eMMC speed mode is unchanged — `rk3528-generic.dts` already used
`mmc-hs200-1_8v`, which is right for this board; what is new is the factory DT's explicit
`max-frequency = <50000000>` and `fixed-emmc-driver-type = <1>`, neither of which generic set. 🟡
Untested on this box — the image was rebuilt and verified offline only, and **nothing was flashed
here**.

### 2026-09-06 — held on the shared loader

The per-board U-Boot built yesterday is **not shipped on this board**. `BOARD_UBOOT` points back at
`firmware/common/uboot.itb` — byte-identical (`c13ca928…`) to what this box boots today.

Reason: it would have swapped a known-good, running bootloader for one that had never been booted on
this hardware. The same class of change bricked the H96 Max 3518D twice during its bring-up — first
a missing `dmc` node (`dram_init()` fails), then a missing `otp` node (`misc_init_r()` fails), both
from dropping what `rk3528-u-boot.dtsi` had been supplying. That box has no SD slot and needed
`ctrl+b` at the vendor SPL to come back.

What stays: `firmware/r69/uboot.dts` and `uboot.patch` remain in the repo as the reviewed source,
and `./build-uboot.sh r69` still builds it on demand. What changed is only which loader ships.
`build-uboot.sh` with no arguments now builds just the boards whose `board.conf` names their own
`uboot.itb`, so no unused FIT is produced.

**To enable it here**: flash on the R69 first with serial attached, confirm it boots and that the
recovery button reaches Maskrom, then set `BOARD_UBOOT=r69/uboot.itb` and the `payload.list` line.

### 2026-09-12 — the hold is lifted, `mode-maskrom` added, FIT built on the host

The 2026-09-06 entry no longer describes the repo. `BOARD_UBOOT=r69/uboot.itb`, and
`firmware/common/uboot.itb` is deleted — no board can fall back to a shared loader, because there is
none. What made the swap worth it was the recovery button, dead three ways over on the generic
build; `docs/uboot.md` carries the detail.

`board.patch` now declares `mode-maskrom = <0xef08a53c>` in the `syscon-reboot-mode` node, so
`reboot maskrom` reaches Maskrom over SSH with no button and no serial. The value is not part of the
`0x5242c3xx` REBOOT_FLAG family and nothing in U-Boot proper acts on it — the factory SPL reads it
and hands back to the BootROM. Ours is discarded on every build, so no U-Boot SPL runs on this box
at all.

`uboot.itb` is rebuilt by the native macOS toolchain, replacing the container build. Only the
`u-boot` image changed; the three ATF blobs and the device tree are byte-identical to what the
container produced. ❓ Neither the FIT nor `mode-maskrom` has been booted here — both were verified
on the H96 Max, and this box was offline for the change.

### 2026-10-20 — TVBian, migrated in place

- No backup, by choice. The box's only network is the AIC8800, out of tree on our kernel, so the
  first boot was meant as a one-shot back to Armbian; the unit failed on a missing
  `/etc/u-boot-menu/conf.d/` and the menu stayed on ours. Wi-Fi came up anyway, −34 dBm HE-MCS 11.
- DKMS built the overlay's `rockchip-pwm-remotectl-rk35xx` for 6.1.172, where it would shadow the
  built-in driver; removed for our kernel before the boot.
- Bluetooth through serdev: `hci0` on UART, `serial0-0` bound, no `rk35xx-bt`, no `hciattach`.
- Without `mac-pin`, `wlan0` took the driver's `88:00:33:65:64:b6` from the SoC's OTP id and DHCP
  moved the box from `.235` to `.231`. avahi came up as `cnc-2.local`, a conflict with its own stale
  record; a restart took `cnc.local` back, and the next boot claimed it cleanly.
- `tvb-r69`'s AIC8800 files sit at paths `armbian-firmware` also owns under `/lib`; they survived
  its purge, `dpkg --verify tvb-r69` clean. `aic8800-firmware`, in no repo any more, went with it.
- Our U-Boot with `0003` in both slots, the old pair in `backup/`: `eth0` `c4:2a:fe:10:51:77`, the
  label address, where the old U-Boot had handed up `36:c8:c4:28:e4:08`. Boot 16.4 s (4.7 + 11.7),
  reboot to SSH 32 s, nothing failed, `cncjs` and `cncjs-pendant` running, hostname `cnc` kept.
- The AIC8800's efuse has MAC fields, contrary to 2026-08-13, and both are empty: in RF-test mode
  (`aic8800_bsp testmode=1`, `fmacfw_rf.bin` linked to our `lmacfw_rf.bin`, one boot) `GET_MAC_ADDR`
  and `GET_BT_MAC_ADDR` answered `00 00 00 00 00 00`, no timeout. The BT firmware derives
  `0B:3B:22:AC:88:20` itself. A throwaway driver build reached them: 6.1 hands `SIOCDEVPRIVATE` only
  to `.ndo_siocdevprivate`, which the driver lacks, and nothing sent `GET_BT_MAC_ADDR`. In normal
  mode the request times out and crashes the command queue; a module reload leaves the SDIO card
  unpowered (`-123`), so test mode takes a boot. Not shipped: diagnostics only.
