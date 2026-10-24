# Bringing up a box

| Kind   | When                                    | Sections    |
| ------ | --------------------------------------- | ----------- |
| board  | family and chips in the repo            | 1–8, 11     |
| chip   | a Wi-Fi, BT or other chip has no driver | 1–8, 9, 11  |
| family | the SoC family is new                   | 10, 1–8, 11 |

**The checklist is the doc.** Sections end with ID'd lines; the Test report in
`docs/<board>/board.md` gives each ID its mark and number, or the reason behind a 🟡. 👤 marks a
line that needs the human's hands.

**`docs/<board>/worklog.md`** starts on day one: dated, what was tried, the command, what it showed,
wrong turns included; compressed, no narrative.

A mark is confidence that the line works. Even ✅ is not proof: only months of daily use proves a
board, and a ✅ that fails later turns ❌, as the H96 Max H313's SD UHS did once warm reboots broke
it.

| Mark | Means                                                |
| ---- | ---------------------------------------------------- |
| ✅   | verified here, or a weak check here on a sister's ✅ |
| 🟡   | a weak check passed, nothing against it              |
| ❓   | not checked at all                                   |
| ❌   | tested and broken                                    |
| ➖   | not on this box                                      |

A weak check: the same mechanism ✅ on a similar board, or the nodes probed where nothing can
exercise them. A sister is identical for that block, the same SoC, chip and tree node: the H96 Max
3518D and H313 are sisters for HDMI, the M20 is neither's. A line turning ✅ turns its sisters'
weak-checked 🟡 ✅ in the same pass.

## Rules

- **Bring-up integrates; research digs.** A driver from scratch, or a hard bug such as a Wi-Fi
  latch, goes to `research/<experiment>/`, as `seekwave-tx-latch-bug` did; the board ships with the
  gap marked.
- **Reliability over speed.** A box that reboots and never returns is worse than a slow SD card: the
  H313 runs its SD without UHS. Wake on a remote that is not reliable is disabled, as on the 3518D.
- **macOS and Linux**, arm64 and x86-64, best effort; a platform not tested is named in the PR.
- **One kernel per family**, current and `-next`, one patch set for every board. A board's own
  kernel or patch needs a reason the family's cannot meet, in its `board.md`.
- **A clean `dmesg`.** Every noisy line is a fault or a wrong level, often in an out-of-tree driver;
  judge it by what it says, not its level. The stock `dmesg.txt` is a baseline only if it covers
  early boot.
- **No userspace bring-up**: no MAC-pinning service, no `hciattach`. A small kernel patch, so `hci0`
  and the addresses exist when the driver probes.
- **A lean image**, close to minimal Debian, and no user preference: a `video=` pin for one monitor
  caps every 4K TV. GitHub caps a release file's size.

## Kit

| Item                                   | For                                  |
| -------------------------------------- | ------------------------------------ |
| multimeter, any cheap one              | finding the serial pins              |
| TTL adapter: 1.8/3.3/5 V jumper, FT232 | serial; a CP2102 cannot do 1.5 Mbaud |
| test hooks, or a soldering iron        | holding the serial pads              |
| USB-A male-to-male cable               | the USB service mode                 |
| USB Ethernet adapter, RTL8152/8153     | a network before the board's own     |
| a power switch the host toggles        | power cycles without hands           |
| USB camera                             | the agent watching the screen        |
| TV with CEC and a composite input      | the HDMI and AV checks               |
| PC monitor with speakers and DDC/CI    | the monitor checks                   |
| AV receiver, where there is one        | passthrough, SPDIF                   |
| HDMI female-to-female coupler          | a stick on any monitor               |
| SD card, USB stick                     | booting the image                    |
| SSD in a USB enclosure                 | the USB stress test                  |
| power meter                            | draw at idle, suspended and off      |

## The loop

**The agent runs unattended**, in a loop such as Claude Code's `/loop`: next line, check, retry or
move on. Riskiest first: SDIO Wi-Fi, the Ethernet PHY, the video codec, anything the tree touched.
The 👤 lines that can wait go to the human as one batch at the end; L1, B3, M5 and a family's F2 and
F3 come first. One action at a time: what to wire, press or look at, and what to report.

**Network first**: an image that boots onto Ethernet or Wi-Fi and takes `ssh`, the USB adapter
standing in (`r8152` is in every family's kernel). Large files go over `ssh`, or `adb` on stock,
never serial. Keep serial attached as long as the pads allow; it is prospective: attach it, then
reproduce.

### Finding TX, RX and GND

The box's TX carries the console out; its RX takes keystrokes in. Reading needs only GND and TX.

1. **GND** reads 0 V against exposed metal: a USB, HDMI or Ethernet shell.
2. **The supply pad** reads highest, 3.3 V or 5 V; TX and RX a few mV below it.
3. **GND and the box's TX first**, to the adapter's RX, which only listens. Try each candidate; the
   one that prints is TX.
4. `tio -b <baud> -L --log-file boot.log /dev/cu.usbserial-*`, then power-cycle: 1500000 on
   Rockchip, 115200 on Amlogic.
5. **The box's RX last**, for a shell. It drives the SoC: set the jumper to the SoC's level first.
   Never the supply pad.

- [ ] **L1** 👤 The stock boot log scrolls

## 1. Backup and a way back

1. Full eMMC image → `backup/<board>-stock.img.xz`, its size `/sys/block/<dev>/size` × 512.
2. The USB service mode, which needs no boot: Rockchip's in `docs/rockchip-maskrom.md`, Amlogic's in
   `docs/amlogic-burning-mode.md`, a new family's from F1. Read back the first sectors and compare.

**The per-unit window** holds the unit's MAC, serial and keys (Rockchip: `DVKR` at sector 7168,
`SSKR` at 8192): in `preserve-sectors`, never written, never shipped. On Rockchip, carve the
idbloader, sector 64 for 4096 sectors, into `factory_idbloader.bin`.

- [ ] **B1** The backup is off the box
- [ ] **B2** Its size matches the eMMC's
- [ ] **B3** 👤 A read over the service mode matches it
- [ ] **B4** `preserve-sectors` covers the per-unit window
- [ ] **B5** On Rockchip, `factory_idbloader.bin` is carved from the backup

## 2. Board identity and components

`BOARD_ID` names one hardware design: the sticker's product name, lowercase with dashes, the brand
too where it owns a domain. **Search it**: if results mix years, PCBs or SoCs, qualify it with a
version or PCB revision, `r69-1` not `r69` (the H96 Max is hundreds of boxes). The silkscreen name
and date go in `BOARD_PCB`. The agent proposes the ID from the sticker, silkscreen and photos; the
human confirms it.

**Find every component**, the heat sink lifted where it comes off. The list decides the kind and
which lines apply.

| Component   | Record                                    |
| ----------- | ----------------------------------------- |
| SoC         | the exact part, from its marking          |
| Wi-Fi/BT    | the chip or module part                   |
| RAM, eMMC   | part, type, size                          |
| ports       | every one, unpopulated ones too           |
| IR receiver | where it is; often behind the front panel |
| LEDs        | each one and its colour                   |
| buttons     | the recovery hole, side buttons           |
| other chips | any MCU, PMIC or Ethernet PHY             |

**`board.md`**, in this order:

| Section       | Holds                                              |
| ------------- | -------------------------------------------------- |
| Identity      | name, PCB, components, photos                      |
| Serial        | the pads outlined in red, pin order, baud, voltage |
| Addresses     | each one and its source                            |
| Test report   | every ID, its mark and number, or a 🟡's reason    |
| Measured      | the numbers, dated, with what was fitted           |
| per component | how each works on this board                       |
| Known gaps    | ❌, ❓ and the trade-offs                          |
| Recovery      | this box's way into the service mode, and back     |

- [ ] **I1** The ID is searched: every result is this box
- [ ] **I2** The human confirmed the ID
- [ ] **I3** 👤 Photos of both sides of the PCB, the markings readable
- [ ] **I4** 👤 The serial pads outlined on the photo
- [ ] **I5** Every component is in `board.md`, by part
- [ ] **I6** `board.md` has every section above
- [ ] **I7** `BOARD_PCB` is the silkscreen's name and date

## 3. Stock dump

The factory firmware is the board's specification and the only reference once the box is gone. **A
shell first**, serial, `adb` or `ssh`: carved from the image, a dump has no `dmesg` or `getprop`.

`stock/<board>/`:

| File                                                     | What                                  |
| -------------------------------------------------------- | ------------------------------------- |
| `README.md`                                              | how and when; the identity table      |
| the bootloader stages                                    | idbloader or BL2, TEE/trust, U-Boot   |
| `board-runtime.dtb`                                      | the tree after U-Boot edited it       |
| `firmware/`                                              | every chip that runs its own firmware |
| `boot.log`, `dmesg.txt`, `cmdline.txt`                   | the boot, from power-on               |
| `getprop.txt`, `kernel-config.txt`                       | the build                             |
| `cpuinfo.txt`, `meminfo.txt`, `iomem.txt`                | the SoC and its memory                |
| `partitions.txt`, `gpt.bin`, `emmc-identity.txt`         | the eMMC                              |
| `lsmod.txt`                                              | the vendor's drivers                  |
| `gpio.txt`, `pinmux.txt`, `regulators.txt`, `clocks.txt` | the wiring state                      |
| `cpufreq.txt`, `thermal.txt`                             | the factory OPPs and trip points      |
| `input-devices.txt`, `leds.txt`                          | buttons, remote, LEDs                 |

The README's identity table: product properties, build, kernel version, the SoC's own ID,
silkscreen.

**The factory DTBs** go in `boards/<board>/`: `factory_board.dtb`, and `factory_uboot.dtb` where we
build U-Boot from it. Carve them from the image, at the `d00dfeed` magic in the boot partition, the
size in the next four bytes. Never from `/proc/device-tree`: U-Boot has edited it, even the SoC's
`compatible`.

**Kept out of the repo**, `backup/` alone holding them:

- the per-unit window;
- DRM and attestation keys, secure storage;
- Wi-Fi credentials, anything naming the owner;
- a MAC that could be traced to the owner.

**The bases**: vendor or mainline and the version of the kernel and U-Boot, from the boot banner,
`/proc/version` and the binaries' strings. They set the `_DTB_SOURCE` bases in `tools/dtcx/bases/`;
a missing one is written.

- [ ] **D1** `stock/<board>/` has every file above
- [ ] **D2** Its README's identity table is filled
- [ ] **D3** The factory DTBs are carved from the image
- [ ] **D4** Nothing kept out is in the repo
- [ ] **D5** The `_SOURCE` bases are named, with versions

## 4. Bootloader

| Family   | Factory, kept           | Ours                                           |
| -------- | ----------------------- | ---------------------------------------------- |
| Rockchip | the idbloader: DDR init | U-Boot, with `uboot.dts` from the factory tree |
| Amlogic  | U-Boot, and its tree    | mainline U-Boot, chain-loaded, no board tree   |

The factory DDR init is the only one proven on that DRAM; a public blob may corrupt memory.

## 5. Device trees

**Stock first.** Unofficial trees for one-off boxes carry their bring-up's issues: a hint when
something fails, never copied. Only a board mainline or Armbian supports officially is adopted, and
checked against the dump.

1. `./build.sh tool dtc`, then `./build.sh board-dtb <board>` and `uboot-dtb <board>`: the factory
   blobs decompiled by `tools/dtcx/dtcx.py` into names, which map across versions where numbers do
   not.
2. Edit a copy as `board.dts` and diff it into `board.patch` (`uboot.patch` alike): the build
   regenerates `board.dts` from the patch. `board.dtb` is committed; it is what ships.
3. One change per test boot.

**Grafts known here.** Start from the closest board's `board.patch`.

| Graft                                       | Needed by                                   |
| ------------------------------------------- | ------------------------------------------- |
| IR `remote_support_psci` → `1`              | the remote waking the box from off          |
| GPU: lima `clocks`, `interrupt-names`       | mainline's lima                             |
| LEDs: labels `power`, `standby`             | the shared LED hooks                        |
| LEDs: `retain-state-shutdown`, `-suspended` | the hooks, not the LED core, own the LEDs   |
| `watchdog` → `okay`                         | systemd's `RuntimeWatchdogSec`              |
| VOP `esmart_lb_mode` → `02`                 | 4K on Rockchip                              |
| `model` → the box's name                    | identity; the factory names the EVB         |
| CEC: mainline's node, `hdmi-phandle`        | `/dev/cec0`                                 |
| DDC: `i2c-gpio`, pins muxed to GPIO         | DDC/CI; unmuxed, the EDID reads empty       |
| SoC or board `compatible`                   | only where a driver or userspace keys on it |

The watchdog cannot be disarmed once opened and counts across a soft reboot: read its clock in
`docs/watchdog.md` before trusting a timeout.

**Trust the PCB over the tree.** A factory tree is often an evaluation board's: it claims hardware
the box lacks, such as an SD slot on a stick with none. Disabling a node needs a positive signal, a
driver error or a probe reading nothing; silence is not absence. No graft without a consumer; a
disabled node is enabled only for an in-SoC block needing no board wiring.

**Power management does not copy 1:1** from vendor to mainline: the M20's factory tree suspends
through Amlogic's `aml_pm`, which mainline lacks, leaving `s2idle` and no wake. Rewrite it, try the
candidates, keep the one that measures best.

- [ ] **T1** Boots the family's kernel
- [ ] **T2** Boots its `-next`
- [ ] **T3** Each disabled node's hunk is marked `NOT FITTED`
- [ ] **T4** Every other hunk says why
- [ ] **T5** After a tree change, the untouched nodes are still `okay`, the eMMC first
- [ ] **T6** `dtb.md` records every change, reverted ones too
- [ ] **T7** The suspend setup is the best-measured candidate, the others in `dtb.md`

## 6. Board data

Copy the closest `boards/<board>/` and change only what the dump says.

**Firmware** is per chip, `tvb-firmware-<chip>` from `firmware/<chip>/`: the vendor's from the stock
image, assumed the same on every board. A newer or working build wins, its `README.md` saying which.
A file keeps its stock name, mapped by `package.list` to what the driver asks for; settings variants
(Seekwave's RF NV by antenna) ship in the chip package, and the board picks one with a `link`.
Firmware only one board needs goes in its package, at `/usr/lib/tvb/firmware`, searched first.

- [ ] **P1** The README lists the board
- [ ] **P2** The README's support matrix has it
- [ ] **P3** Every firmware file is in its chip package, or in the board's only where it differs

## 7. Verify the image offline

- [ ] **V1** On Rockchip, the loaders at sectors 64 and 16384 are byte-identical to the board's
- [ ] **V2** `/usr/lib/tvb/board.dtb` is identical to `boards/<board>/board.dtb`

## 8. Validate

### System

Measure the second boot; the first resizes. A boot that grew is the cheapest signal: a unit waiting
on absent hardware, a getty on a missing tty, DHCP on an unplugged port. An MMC controller can fail
its first init after a warm reboot, hence ten. The watchdog's reset keeps ramoops in
`/var/lib/systemd/pstore/`; a power cycle loses it.

- [ ] **S1** Comes up on the network with no serial attached
- [ ] **S2** U-Boot prints on serial
- [ ] **S3** The kernel prints on serial
- [ ] **S4** A login on serial
- [ ] **S5** The boot on HDMI, as early as it gets
- [ ] **S6** `dmesg` accounted for line by line; tolerated lines named in `board.md`
- [ ] **S7** `systemd-analyze blame` explains every second
- [ ] **S8** The second boot is at or under the recorded time
- [ ] **S9** `/usr/lib/tvb/board-{id,name,pcb}` are right
- [ ] **S10** Every `tvb-*-modules` module is loaded
- [ ] **S11** Ten warm reboots, every device working after each
- [ ] **S12** Ten power cycles, every device working after each
- [ ] **S13** `free -m` is the advertised RAM
- [ ] **S14** `stress-ng --vm --verify` is clean
- [ ] **S15** `wdctl` shows the watchdog busy
- [ ] **S16** `journalctl -b | grep "Watchdog running with"` is the largest timeout its clock allows
- [ ] **S17** No userspace service sets an address or attaches a device
- [ ] **S18** The image adds nothing beyond `tvb-base`, the board's packages and their depends

### SoC and codecs

Codecs work as well as on the vendor kernel. At 4K60 DDR bandwidth is the bottleneck, so the
handover to the display must keep up, not only the decoder. Test stale buffers, stream metadata,
setup and teardown, as a normal user: root hides a missing udev rule. Ancient and regional codecs
(RealVideo, AVS) are worth little effort. ffmpeg patches that validate or fix a codec live here.

- [ ] **C1** `scaling_available_frequencies` is the factory OPP table
- [ ] **C2** 5 minutes of 4-core `stress-ng` stays under the trip points, not throttled
- [ ] **C3** Every claimed codec decodes, at 720p, 1080p, 4K and 8K
- [ ] **C4** Every claimed encoder's output decodes back
- [ ] **C5** A real 4K HEVC file plays smooth, the CPU near idle
- [ ] **C6** 4K60 video plays on screen
- [ ] **C7** Decoded frames reach the display with zero copy
- [ ] **C8** Video scales to the display's resolution
- [ ] **C9** Stopping and restarting a stream leaves no stale buffers or warnings

### Display

Anything off is a bug: a missing mode, a wrong rate, a console font too big or too small. Known
here: no 4K on Rockchip without the line-buffer graft; a 2K monitor's native mode pruned until a
kernel patch; the console font set by the kernel config. `kmscube` on screen, its stdin held open
(`sleep 60 | kmscube`); modes switched with `modetest -s`; headless, EGL on GBM and `glReadPixels`.
A picture that drops: swap the cable first.

- [ ] **H1** 👤 1080p at every refresh rate, on a TV
- [ ] **H2** 👤 1440p at every refresh rate, on a TV
- [ ] **H3** 👤 4K at every refresh rate, on a TV
- [ ] **H4** 👤 The same modes on a PC monitor
- [ ] **H5** 👤 Hotplug re-detects, with no blank screen after
- [ ] **H6** 👤 HDMI audio plays, as the default sink
- [ ] **H7** 👤 Multichannel LPCM plays
- [ ] **H8** 👤 AC3 and DTS pass through to a receiver
- [ ] **H9** 👤 HDR switches the TV
- [ ] **H10** `cec-ctl` shows a physical address
- [ ] **H11** 👤 Mute and volume on the TV remote reach the box
- [ ] **H12** `ddcutil getvcp 10` reads a monitor's brightness
- [ ] **H13** `ddcutil setvcp 10` moves it
- [ ] **H14** 👤 SPDIF out on a receiver, or its node probed
- [ ] **H15** 👤 AV out on a composite input, or its node probed
- [ ] **H16** The GPU renders headless
- [ ] **H17** The GPU renders on screen
- [ ] **H18** The console font reads right at the native mode

### Power

Never suspend remotely a box with no RTC and no network wake: nothing brings it back.

- [ ] **W1** 👤 Sleep and wake by each route the box has: wired IR, power button, BLE key
- [ ] **W2** 👤 Off and on by each route the box has
- [ ] **W3** Every wake route kept is reliable; the rest disabled
- [ ] **W4** 👤 Resumed on the remote, it stays up: no logind double-fire
- [ ] **W5** `deep` in `/sys/power/mem_sleep` where the SoC has it
- [ ] **W6** A suspend longer than the watchdog window resumes the same `boot_id`
- [ ] **W7** The RTC keeps time, or its absence is recorded
- [ ] **W8** 👤 Nice to have, where sleep works: draw at idle, suspended and off, on the bare board

### Storage

`fio`, fixed so every board compares, in decimal MB/s:

```sh
fio --name=seq  --filename=<file> --rw=read|write         --bs=1M --size=1G   \
    --direct=1 --ioengine=libaio --iodepth=8  --numjobs=1 --runtime=30 --time_based
fio --name=rand --filename=<file> --rw=randread|randwrite --bs=4k --size=512M \
    --direct=1 --ioengine=libaio --iodepth=32 --numjobs=1 --runtime=30 --time_based
```

A capability measured before a boot stage was replaced says nothing after it: re-measure. The
service mode on our U-Boot is mandatory on a slotless board: replacing the factory U-Boot can remove
the route that reached it.

- [ ] **M1** The eMMC under `fio`
- [ ] **M2** The SD card under `fio`
- [ ] **M3** 👤 SD hotplug, in and out
- [ ] **M4** Every speed mode kept survives warm reboots
- [ ] **M5** 👤 The image boots from an SD card or a USB stick, the eMMC untouched
- [ ] **M6** `tvb-install` puts it on the eMMC
- [ ] **M7** It boots from the eMMC on its own loaders
- [ ] **M8** The per-unit window is byte-identical to the backup
- [ ] **M9** 👤 The service mode enters on our U-Boot
- [ ] **M10** It loads the board's loader
- [ ] **M11** It reports the eMMC's true size
- [ ] **M12** Over it, a full-disk read matches the eMMC
- [ ] **M13** Over it, the backup restored in full boots stock
- [ ] **M14** M6 to M8 pass again after the restore

### Network

`ssh` is no throughput test; use `iperf3`. A slowdown under load is contention; a link that does not
come back is a latch: re-measure at once and after 60 s idle, and record what clears it. Then where
its interrupts land: `smp_affinity`, `rps_cpus`, bus-thread priorities, shipped as board data.

**Addresses, best first**: the printed label, vendor storage its readable copy; the interface chip's
eFUSE; that chip's ID; the SoC's ID, for an interface with none. Random is the bug; a derived one
sets the locally administered bit. U-Boot may hand one to the kernel in the tree, as Rockchip's
Ethernet MAC from vendor storage. A combo chip's BT address is usually its Wi-Fi one plus 1. BLE
wake needs the BT driver to set `hdev->wakeup`, or only IR wakes the box.

- [ ] **N1** Ethernet at every link speed
- [ ] **N2** Ethernet at line rate, idle
- [ ] **N3** Ethernet at line rate under 4-core load
- [ ] **N4** The Ethernet PHY's driver is the vendor's, not Generic
- [ ] **N5** Wi-Fi on every band, the regulatory domain named
- [ ] **N6** Wi-Fi throughput, idle
- [ ] **N7** Wi-Fi throughput under CPU and I/O load
- [ ] **N8** Wi-Fi does not latch
- [ ] **N9** With no region set, a scan finds networks
- [ ] **N10** `iw reg set <country>` returns
- [ ] **N11** BT: `hci0` `UP RUNNING`, `errors:0`
- [ ] **N12** `btmgmt find` lists devices
- [ ] **N13** 👤 The bundled remote pairs
- [ ] **N14** 👤 The pairing survives a reboot
- [ ] **N15** 👤 The remote wakes the box over BLE, where claimed
- [ ] **N16** Every address is stable across reboots and an eMMC migration
- [ ] **N17** Every address is the unit's own
- [ ] **N18** Per-unit firmware (EEPROM, calibration, NVRAM) is named for the board
- [ ] **N19** Any interrupt tuning ships as board data, with its measurement

### USB

- [ ] **U1** `lsusb -t`: no USB 2 hub in the way
- [ ] **U2** USB 3 judged by its BOS capability, not `bcdUSB`
- [ ] **U3** 👤 Every port: an SSD under `fio` and `stress-ng` together, stable
- [ ] **U4** USB 3 at `5000M` on `uas`
- [ ] **U5** USB 2 at `480M`
- [ ] **U6** 👤 Hotplug on every port

### Remote and buttons

IR keys map in the tree, BLE keys through `hwdb`; both end on the canonical keymap in
`docs/remote-keymap.md`, Kodi's. The human presses under `evtest` and says the order; the agent
maps. A silent IR node is ambiguous: no receiver, or no matching usercode table.

- [ ] **R1** 👤 IR: the receiver's IRQ counts in `/proc/interrupts`
- [ ] **R2** 👤 IR produces the canonical keymap
- [ ] **R3** 👤 BLE produces the canonical keymap
- [ ] **R4** 👤 The remote cold-boots the box from off
- [ ] **R5** 👤 Each button registers as input, or does its job at power-on
- [ ] **R6** 👤 The recovery button reaches the service mode

### LEDs

- [ ] **E1** 👤 The on state matches the factory's, by eye
- [ ] **E2** 👤 The off state matches the factory's
- [ ] **E3** 👤 The suspended state matches the factory's

## 9. Chip bring-up

A driver, best first: in-tree, the chip vendor's, another board's vendor SDK; none is research.
Reload a module you are connected through from one detached script, so a drop cannot strand the box.

- [ ] **X1** N5 to N18 pass on the family's kernel
- [ ] **X2** N5 to N18 pass on its `-next`
- [ ] **X3** Any regulatory country can be set
- [ ] **X4** The module loads and unloads cleanly, repeatedly

## 10. Family bring-up

**Sources, best first**: mainline; the SoC vendor's, where mainline lacks what the board needs; an
unofficial newer tree, last, from a maintained place.

A closed or x86-64-only vendor tool is patched open, as `rkdeveloptool` was, or rewritten, as
`amlcmd` was. The defconfig starts from a maintained distribution's, Armbian's or LibreELEC's. A
slotless board installs through the service mode: the M20 boots a stick once `amlcmd` points its
environment there; on Rockchip it is open, our U-Boot having no USB yet.

- [ ] **F1** The service-mode tool is built from source in `tools/`
- [ ] **F2** 👤 It reads a box in full
- [ ] **F3** 👤 It restores the box, which boots stock
- [ ] **F4** `kernel/<kernel>.conf` builds in CI
- [ ] **F5** Its `-next` builds in CI
- [ ] **F6** The bootloader approach (section 4) is built
- [ ] **F7** An install path: an SD card or a USB stick, then `tvb-install`
- [ ] **F8** The image layout and boot files exist
- [ ] **F9** An image comes out of a release run

## 11. Pull request

**One board, one PR**: tree, data, docs and patches, however large. A chip may follow in its own PR,
the board landing with it ❌. A family's service-mode tool may land alone, validated by a full read
and a restore that boots stock; the rest of a family lands with its first board. An AI reviews for
structure and content, not form: a factory-derived tree is not rewritten to look hand-made. CI
builds every PR; a merge ships in the next weekly release. A working board beats upstreamability:
one merged PR beats twenty dying unreviewed. **Kernel patches stay focused**, one fix each in
`patches/<upstream>/` with its status: every board on that kernel takes them.

- [ ] **Q1** No ❓ left: every line ✅, 🟡 with its reason, ➖, or ❌ in Known gaps
- [ ] **Q2** 👤 A few days of daily use with no issue
- [ ] **Q3** CI is green
- [ ] **Q4** Untested platforms are named in the PR
- [ ] **Q5** No board-only kernel or kernel patch, or its reason in `board.md`
