# H96 Max 3518D — worklog

Dated history, wrong turns included. Board id `h96max-3518d`, from the model name on the underside
label. PCB silkscreen `3518_DG_ZX_V01 20250401`.

## 2026-09-05 — serial, root shell, full small-evidence sweep

**Serial worked first try.** 3-pin header to the right of the board name: TX left, GND centre, RX
right, 1500000 baud, FT232 on `/dev/cu.usbserial-BG00WUDY`. The console is a **root-capable Android
shell**, not just a log — `su` is at `/system/xbin/su`, `ro.build.type=userdebug`,
`ro.debuggable=1`. That is better than `stock/h96max/` ever had and made the whole sweep possible.

macOS cannot set 1.5 Mbaud through `termios`; it needs the `IOSSIOSPEED` ioctl (`0x80085402`).
`stty` fails with `tcsetattr: Invalid argument` and BSD `stty -f` is shadowed by GNU coreutils in
`PATH`. A ~90-line Python helper over `os.open` + `fcntl.ioctl` drove the console for the session.

**Kernel spam had to go first.** The box retries a USB gadget once a second forever —
`UDC core: g1: couldn't find an available UDC or it's busy` — because `dwc3@fe500000` is
`dr_mode = "host"`, so no UDC exists to bind. `echo 1 > /proc/sys/kernel/printk` as root silenced
it.

### What the box is

RK3518, 4× Cortex-A53 (`0xd03`), **running AArch32 throughout** — `CPU: AArch32` in U-Boot, `armv7l`
in Linux, `ro.product.name=rk3518_box_32`. This is a vendor build choice, not silicon:
`stock/h96max/boot.log` shows the identical 32-bit factory stack on a box we already run arm64
Armbian on. BL31 and OP-TEE are aarch64 in both; only U-Boot proper and the kernel are 32-bit, and
`u-boot.itb` replaces both of those anyway.

LPDDR3 2048 MB at 666 MHz final (`ddrconfig:7`, 4-bit PCB, `fwver: v1.11`); `MemTotal 2045284 kB`.
Micron `R1J96N` 16 GB eMMC, 15,758,000,128 B — byte-identical in size to the R69's.

### The one that changes the plan

**There is no microSD slot.** The tree describes `sdmmc: mmc@ffc30000` with the full UHS set and
`vcc-sd`/`vccio_sd` rails are claimed, but nothing is fitted — confirmed against the board. Every
other box here treats "boot an SD instead" as the way back from a bad DTB. That route does not exist
on this one, so **maskrom is the only recovery path** and has to be proven before anything is
written to eMMC.

Checked whether U-Boot could stand in for the missing slot: it cannot, yet. Our
`generic-rk3528_defconfig` build has `# CONFIG_USB is not set`, so `bootflow scan` sees no USB
storage. Adding USB host to our own build would give this box an SD-equivalent, and is now the main
open design question.

### Evidence taken

51 files, 25 MB, into `stock/h96max-3518d/` — see its README for the index and provenance.

Binaries moved as `dd | gzip | base64` in 1 MiB chunks. gzip's CRC32 rejects a corrupted chunk and
the puller re-fetches it automatically; a whole-range `md5sum` on the box confirmed every file.
Sustained 180–310 KB/s depending on how well the range compressed. Nothing needed more than one
attempt.

Two false starts worth recording:

- The first command/response helper matched its own terminal echo, because the end marker appeared
  verbatim in the line being sent. Splitting it in the sent text (`echo "__D""1234""__"`) fixes it —
  the echo shows the quotes, the output does not.
- The Android boot-image v2 header is **packed**: `dtb_size` is at offset 1648, not 1664. Reading it
  at the aligned offset gave `dtb_size=0`. `header_size=1660` is the confirmation that the packed
  layout is right.

**The DTB came off disk, not from the kernel** — `boot` partition + 18407424. The runtime blob is
kept beside it only to diff, and that diff is what proves the provenance: the disk tree says
`rockchip,rk3518` and U-Boot rewrites it to `rockchip,rk3528a`. Taking the runtime tree as factory
would have baked in a compatible the vendor never shipped, plus `serial-number`, a `memory` node,
`local-mac-address`, overscan margins and a `drm_logo` reservation.

That rewrite has a consequence the R69 does not have: `docs/r69/board.md` records that MPP works
there because "the factory tree already says `rockchip,rk3528a`" — that was the _runtime_ tree. Once
our U-Boot replaces the vendor's, nothing rewrites the compatible here, so the SoC-compatible append
is a graft this board actually needs.

### Radio

Same Seekwave SWT6621S as `firmware/h96max/`, so the driver, the DKMS packaging and
`patches/seekwave-swt6621s/` all carry over.

An earlier entry here claimed the firmware revision differed (DRAM 192816 vs 193468). **That was
wrong** — it compared this box's _factory_ blob against the other board's _shipped_ armbian/KICKPI
blob. Factory to factory, DRAM, IRAM and RF calibration are **byte-identical**; only
`SWT6621S_NV_SDIO.bin` differs, in **two bytes** at `0x20` and `0x24`. Both are still carried per
board: matching bytes today are an observation, not a reason to share a file.

No `hci0` — stock Android does not bring Bluetooth up on this build either
(`Could not find android.hardware.bluetooth.IBluetoothHci/default in the VINTF manifest`).

### Vendor storage

Four copies at sector 7168; copy3 (`ver=5`) is live: `LAN_MAC 00:ef:01:1a:be:a0`,
`SN SN26072800001`. No `WIFI_MAC`, no `BT_MAC`. The two older copies hold `be:30:cf:16:4f:80`, which
has the locally-administered bit set and `rk35xx-vendor-storage` rejects. `wlan0` comes up
`fe:fd:fc:c4:f3:27`, random per boot — the `rk35xx-mac-pin` case.

### LEDs

Two, both active low, on gpio4: `work-green` (145, lit at rest) and `work-red` (139). Blinked three
times over serial to confirm they are real and driveable. The factory tree already carries
`retain-state-suspended` and `retain-state-shutdown`, so the LED graft here is only the rename to
`power`/`standby` that the shared hooks expect.

**Both LEDs are on the PCB but faintly visible through the case's ventilation holes** — an earlier
note here said they were invisible and conveyed nothing; inspection on 2026-09-05 corrected that.
They do carry a little signal to a user, but only just, so LED-based feedback is weak rather than
useless. The recovery button is genuinely inaccessible though: PCB-mounted with no external access,
unlike the R69's, which is reachable through the AV jack.

### Still unknown after this session

Which physical port is `xhci` and which is `ehci`; whether the USB-C port carries data at all; the
bundled remote's scancodes (`ir_key6`/`0xfb04` is the likely table); anything needing a TV.

### Diffed the factory tree against the H96 Max's

Four differences in 4640 lines. Both boxes ship the same `rockchip,rk3518-evb1-ddr4-v10` vendor
tree, and the deltas are: the eMMC clock (100 MHz + HS200 there, 50 MHz and no HS200 here), the
hidden button's keycode (`KEY_VOLUMEUP` there, **`KEY_F11`** here despite the same `vol-up-key`
label), and two IR tables (`ir_key6` is a superset here, `ir_key8` is a different remote entirely).

That collapses Phase 3: `upstream/h96max-zx/armbian.patch` is 47 lines and every hunk except
`compatible`/`model` and the `sdmmc` UHS removal lands on a byte-identical region. Details in
`dtb.md`.

Corrected an error from earlier today: `board.md` first recorded the hidden button as `KEY_VOLUMEUP`
because the node is labelled `vol-up-key`. The code is `0x57` = `KEY_F11`.

## 2026-09-05 (later) — loader, device tree and a first image, all offline

Nothing written to the box. Everything below was built and verified on the host.

**The maskrom read/write loader exists.** `./build-rktools.sh` picked the board up from
`firmware/h96max-3518d/factory_idbloader.bin` with no code change — it discovers boards by that file
— and produced `tools/rktools/rk3528_spl_loader-h96max-3518d.bin`: 471374 B, `BOOT` header, RK3528,
carrying 61440 B of this box's own DDR init carved from its idbloader. Selftest PASS. That is the
tool that will do `rl`/`wl` over USB once maskrom is confirmed.

**Grafts.** `upstream/h96max-3518d/armbian.patch`, 41 changed lines against the factory tree — six
fewer than the ZX's 47, which is exactly the `sdmmc` UHS hunk skipped because no card slot is
fitted. The patch was generated by applying the grafts programmatically to the `dtc -P -n` decompile
and diffing, rather than hand-porting the ZX's line offsets.

`BOARD=h96max-3518d STOCK=h96max-3518d SYNC=1 ./upstream/build.sh` passed its own gate:
`18 deletes, 42 node overrides, 8 added nodes` and
**`VERIFIED: native tree is content-identical to the patched tree`**.
`firmware/h96max-3518d/board.dts` + `.dtb` synced from it.

**Board data.** `board-id`, `board-name`, `board.conf`, `payload.list` (11 path refs rewritten, 0
left pointing at `h96max/`), `mac-oui`, `seekwave-modules.conf`, `fetch-seekwave-src.sh`.

A measured correction while assembling the firmware: the two boards' **RF calibration blob
`SWT6621S_SEEKWAVE_R00001.bin` is byte-identical**, only `SWT6621S_NV_SDIO.bin` differs. An earlier
note here claimed both were board-specific; that was written from the differing file _sizes_ of the
factory chip code, not from comparing the calibration files. Both are still carried per board — two
boxes agreeing today is an observation, not a licence to share the file.

**Image built** — `images/Armbian_26.2.1_Rock-2f_trixie_vendor_6.1.115_minimal-h96max-3518d.img`,
from the ROCK 2F 26.2.1 trixie vendor-6.1.115 minimal base. The Seekwave DKMS patches applied
cleanly to the fetched source and the build's `fsck.ext4 -fn` gate passed.

Offline verification, all pass:

| Check                 | Result                                                                                                                                                                 |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| idbloader @ sector 64 | byte-identical to `firmware/h96max-3518d/factory_idbloader.bin`                                                                                                        |
| `u-boot.itb` @ 16384  | byte-identical to `firmware/common/u-boot.itb`                                                                                                                         |
| DTB                   | `/boot/dtb/rockchip/board.dtb`, `/usr/local/share/rk35xx/board.dtb` and `firmware/` all md5 `83bf25c2…`                                                                |
| `armbianEnv.txt`      | `fdtfile=rockchip/board.dtb`, `console=ttyS0,1500000`, earlycon `0xff9f0000`                                                                                           |
| identity dir          | `board-id`, `board-name`, `board.dtb`, `mac-oui`, both loaders present                                                                                                 |
| hostname              | `h96max-3518d`                                                                                                                                                         |
| other boards' names   | only `r69` inside `firmware/common/rk35xx-update` and `rk35xx-kernel-prepare`, which are the shared migration paths every board's image carries — no board data leaked |

**Still not written to the box, and still gated on maskrom.** The image is flashable but there is no
eMMC backup and no proven way back.

### `wl 0` would have wiped vendor storage

Caught while writing the README's maskrom install path, before publishing it. The built image is
**all zeros from sector 7168 to 16383** — precisely where `DVKR` (`LAN_MAC`) and `SSKR` (HDCP/DRM)
live on this box. So `rkdeveloptool wl 0 <image>` destroys them exactly as `armbian-install`'s 10
MiB zeroing does, and on an SD-less box there is no booted OS afterwards to repair it from.

The fix is to splice the window into the image file before writing it, not to repair the chip after:

```sh
dd if=emmc-stock.img of=Armbian_..._-h96max-3518d.img \
   bs=512 skip=7168 seek=7168 count=9216 conv=notrunc
```

Verified on a 16384-sector slice of the real image, with `emmc-head.bin` standing in for the backup:
sector 7168 goes `00000000` → `44564b52` (`DVKR`), all four copies land, the idbloader at sector 64
is untouched and the file size is unchanged. The full-size version needs the real backup, which is
still gated on maskrom.

### The box talks to rkdeveloptool — over USB-C, bus-powered, in Loader mode

Three corrections to what was written earlier today, all from having the cable in hand.

**The OTG port is the USB-C, not the USB-A.** Earlier notes read `dwc3@fe500000` (`u2phy_otg`, USB
3-capable) as the USB-A because that is the usual arrangement on these boxes. It is the other way
round here: USB-C is the OTG/dwc3 port, and the USB-A is the plain `ehci`/`ohci` pair on
`u2phy_host`, USB 2.0 only. Confirmed by the box enumerating on the USB-C.

**It is bus-powered from the host.** No PSU attached; the same cable carries the protocol and runs
the board. That settles for this box the question `docs/r69/board.md` leaves open about whether the
cable alone powers it.

**It came up in `Loader`, not `Maskrom`.**

```
DevNo=1	Vid=0x2207,Pid=0x350c,LocationID=101	Loader
```

`Loader` means the factory U-Boot is serving rockusb itself — DDR is already up, so `rl`/`wl` work
with **no `db` step**. That is convenient for reading and worthless as a rescue, because it needs a
working U-Boot to exist. Forcing true `Maskrom` with the hidden button is still 🟡, and that is the
mode that matters when a flash goes wrong.

Cabling used: USB-C→USB-A female at the box, USB-A male-to-male, USB-A female→USB-C at the Mac —
three adapters, because that is what was on the bench. A USB-C to USB-C data cable should be the
direct equivalent.

**Read path verified two ways before trusting it:**

| Check                  | Result                                                     |
| ---------------------- | ---------------------------------------------------------- |
| `rfi` sector count     | **30777344** — matches the GPT parsed from the serial dump |
| `rid`                  | `45 4D 4D 43 20` = ASCII `EMMC `                           |
| `rl 0 34` vs `gpt.bin` | **md5 identical** to the copy pulled over serial           |

`rfi` also prints `Manufacturer: SAMSUNG`, which is wrong — the eMMC CID says manfid `0x13` and
`R1J96N`, i.e. Micron. The CID is authoritative; `rfi`'s vendor field is a lookup artifact for a
part that answers `EMMC`.

Full-disk `rl 0 30777344` started straight afterwards.

### The Loader-mode backup was worthless — 32 MiB then filler

`rl 0 30777344` ran to `100%`, exited `0`, produced a file of exactly 15,758,000,128 bytes, and was
**99.8% `0xCC`**. Caught only because the dump was cross-checked against the pieces already pulled
over serial:

| Region                | Result                                           |
| --------------------- | ------------------------------------------------ |
| GPT, first 34 sectors | match                                            |
| idbloader @ 64        | match                                            |
| head 0..8191          | match                                            |
| `uboot` @ 16384       | match                                            |
| `trust` @ 24576       | match                                            |
| `dtbo` @ 40960        | match                                            |
| factory DTB @ ~43 MiB | **differ — `cccccccc` where the tree should be** |

Everything that matched lies below 32 MiB. A scan put the boundary at exactly **sector 65536 = 32.00
MiB**; past it the whole 15.7 GB is `0xCC`, and the serial-pulled DTB appears nowhere in the file.

**It is a hard window, not a long-transfer bug.** Targeted 8-sector reads at LBA 65536 (32 MiB),
2084864 (1 GiB, start of `super`), 6803456 (3.3 GiB, start of `userdata`) and 30000000 (14.6 GiB)
all came back `0xCC`, while `rfi` cheerfully advertises 30777344 sectors.

**Not our loader.** `db` was never run — the box was already in `Loader`, so the _vendor_ U-Boot's
rockusb served every one of these reads. Whether `tools/rktools/rk3528_spl_loader-h96max-3518d.bin`
can read the whole device is a separate and still untested question.

The file was deleted rather than kept: a 15.7 GB file named `emmc-full.img` that is 99.8% filler is
worse than no file, because someone will eventually `wl` it back. Nothing was lost — every real byte
in its first 32 MiB is already held, verified, in `stock/h96max-3518d/`.

**Rule going in:** verify a dump against a known range before trusting it, whatever produced it.
`rkdeveloptool` reports success either way.

**Cause identified: `RKUSB_READ_LIMIT_ADDR`.** Not a mystery and not ours — U-Boot's rockusb driver
carries a macro that limits flash dumps to the first 32 MB and returns `0xCC` above it. The same bug
is documented on the PineNote, whose stock U-Boot "can't dump partitions beyond 32 MB (above that
limit all bytes in the dump are just 0xCC)". Our figure is exactly 32 MiB, so this is that.

It also explains why the hidden button gave `Loader` rather than `Maskrom`: the button is an
`adc-keys` input, read by **U-Boot**, which then offers rockusb. The BootROM never sees it. A real
maskrom key is a hardware trick — it shorts the boot media's clock to ground so the BootROM cannot
read a bootloader at all and falls through to maskrom. This board has no such key, only the ADC one.

Consequence: `db` + Rockchip's `usbplug` (which our loader wraps) is the path that bypasses U-Boot
and its cap — but reaching it needs the eMMC clock shorted at power-on, not a button press.

### Backup taken via maskrom — 77%, then the read session died

`rd 3` → `Maskrom` → `db` with the `LDR ` loader → `rl 0 30777344`. Ran at roughly 18 MB/s to **LBA
23874560 (12.22 GB, 77%)**, then collapsed to **16 KB/s** — 320 KB in 20 s.

**Almost certainly thermal.**

| Session start               | Read before degrading   |
| --------------------------- | ----------------------- |
| cold (first run of the day) | ~12 GB at 18 MB/s       |
| warm (after a replug)       | ~3.5 GB at 13-30 MB/s   |
| warm (shortly after)        | ~1 GB, down to 1.7 MB/s |

Each recovery was a replug — which on a bus-powered box is also a power-off and a cool-down. And in
maskrom there is **no thermal management running at all**: no cpufreq, no thermal driver, no OS. The
SoC and eMMC run flat out with nothing to throttle them, which is not true under Android or Armbian.
Sustained multi-GB reads in this mode should be expected to cook the box.

**Practical rule: read in bursts with cooling pauses, or put a fan on it.** Do not expect one 15.7
GB pass to complete. `rd 3` cannot refresh the session — it hangs once usbplug is loaded — so the
only reset is a physical replug.

**It is the session that dies, not one bad region.** Two 1 MiB probes both hung ~70 s and returned 0
bytes: one at the stall sector 23874560, and one at 30700000 — 6.8 M sectors further on. Reads fail
everywhere past the stall, which rules out a localised media defect and points at the usbplug
session, the eMMC controller, or power. The box is **bus-powered over the same USB-C it is read
through**, so a brownout during a sustained 12 GB read is a live suspect; a powered hub is worth
trying on the retry. `life_time 0x01 0x01` and `pre_eol_info 0x01` also say the flash considers
itself healthy, which argues against worn media. Killing the read wedges the USB session
(`Creating Comm Object failed!`); it needs a replug.

**What was captured is enough.** Every partition except `userdata` ends at LBA 6803456 (3.24 GiB),
and the partial reaches 23874559 — so the whole boot chain, vendor and secure storage, `boot`,
`recovery`, `backup`, `cache`, `metadata`, `baseparameter` and `super` are all in, plus 8.7 GB of
`userdata`. Missing: the last **3.53 GB of userdata**, which on a restore would at worst cost a
`/data` wipe.

`backup/h96max-3518d/part1.img`, 12,223,774,720 B, verified against ten references pulled
independently over serial — GPT, idbloader, the 4 MiB head, `uboot`, `trust`, `dtbo`, `vbmeta`,
`misc`, `baseparameter` and the factory DTB at 43 MiB. All ten match.

🟡 Unresolved: whether a fresh session after a replug reads the tail. Try a **powered hub**, and
read the remainder in bounded chunks (`rl <start> <count>`) rather than one 15.7 GB pass, so a stall
costs one chunk instead of the whole run.

### Backup complete and verified end to end

`backup/h96max-3518d/emmc-full.img` — **15,758,000,128 B, all 30,777,344 sectors**.

Assembled from nine reads (one 12.2 GB run that stalled at 77%, then eight chunks), then **re-read
in full a second time and compared chunk by chunk**:

```
=== VERIFIED: whole disk re-read matches the assembled image ===
chunks: 30   sectors covered: 30777344 of 30777344 (100.00%)
gaps: none — contiguous 0 .. 30777344
```

**Zero mismatches.** The verification took three sessions with a replug between each; the two
`READ FAILED` entries in the log are thermal stops, not data faults.

**That settles the thermal question.** Both sectors where a read died — 23874560 and 20971520 — were
re-read cleanly on a later, cooler pass. Two independent failure points, both fine afterwards. The
media is sound; only the session degrades.

Full evidence for the image, all independent of each other:

| Check                              | Result                                                  |
| ---------------------------------- | ------------------------------------------------------- |
| Size                               | exact: 30777344 sectors                                 |
| Backup GPT at the true last sector | `EFI PART`, partition array identical to the primary    |
| Constant-byte scan                 | 11.4 GiB of `0x00` erased flash, **zero `0xCC`**        |
| Structure                          | `boot` = `ANDROID!`, factory DTB at 43 MiB = `d00dfeed` |
| 10 regions vs serial-pulled copies | all match — a different transport entirely              |
| **Whole-disk second read**         | **100% byte-identical**                                 |

## 2026-09-05 (later still) — per-board U-Boot, and the recovery button

Family-wide change, driven from this box: the shared `firmware/common/u-boot.itb` is gone. Each
board now ships `firmware/<board>/uboot.dts` → `firmware/<board>/u-boot.itb`, selected through a new
`BOARD_UBOOT` in `board.conf`.

**Why per board.** Every real rk3528 board in mainline bundles its own tree; `rk3528-generic.dts` is
47 lines. Pulled each box's factory U-Boot control DTB out of its own eMMC backup (the FIT at LBA
16384, ~7.9 kB `d00dfeed` after the 2560-byte FIT header) and kept them as `stock/<board>/uboot.dtb`
/ `.dts`. They differ in exactly one thing — eMMC tuning:

| Board         | speed                 | `max-frequency` | `fixed-emmc-driver-type` |
| ------------- | --------------------- | --------------- | ------------------------ |
| R69           | `mmc-hs200-1_8v`      | 50 MHz          | 1                        |
| H96 Max       | `mmc-hs400-1_8v` + ES | 200 MHz         | 1                        |
| H96 Max 3518D | `mmc-hs400-1_8v` + ES | 200 MHz         | 4                        |

`rk3528-generic.dts` hardcodes hs200, so it was undertuning both H96 Max boards.

**The factory DT could not be ingested whole**, which was the first plan. Decompiled it has no
labels (no `__symbols__`), and mainline v2026.04 honours only `bootph-*` — the `u-boot,dm-spl` /
`u-boot,dm-pre-reloc` tags it carries are dead, so SPL's fdtgrep would have stripped it to nothing.
Mined the facts instead into a tree that includes upstream `rk3528.dtsi`.

**The recovery button — and the trap that made it worthless.** `CONFIG_ADC` +
`CONFIG_SARADC_ROCKCHIP` are necessary but not sufficient. `rockchip_dnl_key_pressed()` walks the
ADC uclass and does `strncmp(dev->name, "saradc", 6)`; `dev->name` is the DT node name, and upstream
`rk3528.dtsi` calls the node **`adc@ffae0000`**. The match fails, so the ADC is never found. Our
tree `/delete-node/`s it and re-declares it as `saradc@ffae0000`. It also needs `vdd-microvolts` —
the driver returns an error from probe with no `vref-supply` and no explicit value.

Wrong turns worth keeping: assumed `adc-keys` was needed (it is not — the function reads channel 1
itself); assumed the vendor DT's own `u-boot,dm-spl` tags would still work; assumed the build was
byte-reproducible (it is not — U-Boot bakes a build timestamp into the version string; the control
DTB inside is stable, so diff that).

Verified in the artifact, on all three boards: `CONFIG_ADC=y`, `CONFIG_SARADC_ROCKCHIP=y`,
`CONFIG_ROCKCHIP_BOOT_MODE_REG=0xff370200`, node named `saradc@ffae0000` with `status = "okay"`, no
duplicate `adc@` node, `stdout-path` on uart0, per-board eMMC tuning, `sdmmc` disabled on this board
only, and the SPL DTB still carrying eMMC + uart0. All three images rebuilt and their sector 16384
byte-matches the board's own FIT.

🟡 **Not tested on hardware** — this box is still unreachable, which is exactly the failure this
change exists to prevent. `setup_boot_mode()` runs in `board_late_init()`, so the button is only
read once U-Boot proper is up; it does not help if SPL itself dies.

## 2026-09-05 (later still) — the eMMC layout, measured, and two gaps closed

Hashed and non-zero-scanned all three factory backups instead of trusting Armbian's map. Result in
`docs/emmc-layout.md`. What it turned up:

- **The idbloader and the vendor storage sit outside every partition** — the factory GPT's first
  partition starts at 8192, so sectors 0–8191 are unpartitioned. Anything that respects only the
  partition table will destroy both.
- **`trust` (24576–32767) is entirely zero on all three boards.** OP-TEE is inside the U-Boot FIT,
  not in its own partition. (First pass said otherwise; that was an f-string bug — `b'\x00'` written
  as `b'\\x00'` inside an f-string is a literal backslash, so the comparison could never be true.)
- **U-Boot slot B (20480) is a byte-identical copy of slot A**, 4096 sectors on. Confirmed for all
  three.
- **Secure storage data ends at 10239**, not 16383 — the `security` partition is 4 MiB but only 2048
  sectors of it are `SSKR` copies. Our 7168+3072 splice already covered exactly the right span.
- **The R69's factory idbloader blob fills only two of the five BootROM slots**; both H96 Max blobs
  fill all four in-blob slots. Every copy inside a blob is byte-identical.

Two gaps closed in `build-image.sh`:

| Was                                              | Now                                                                     |
| ------------------------------------------------ | ----------------------------------------------------------------------- |
| blob written once at 64, plus a 5th copy at 4160 | all five slots written from the blob's first copy — the R69 gains three |
| slot B empty unless `FACTORY_DUMP=` was given    | slot B always written: ours, or the factory U-Boot with the dump        |

Verified on rebuilt images: all five idbloader slots byte-match the blob on all three boards; slot A
is our FIT everywhere; slot B is our FIT on R69/H96 Max and the factory U-Boot on the 3518D, which
was built with `FACTORY_DUMP=`.

The recipe published in `docs/emmc-layout.md` was run before publishing — note `sgdisk` from brew is
broken on this host (missing `libpopt`), so it says `gdisk -l`.

### Same day, follow-up — restore the whole window, not the regions we know about

Asked whether `trust` (24576–32767) should be copied from the dump too "in case it exists". It is
empty on all three boards, so copying it is a no-op today — but the question generalises, and
cherry-picking regions we happen to have catalogued is the wrong shape. `build-image.sh` now
restores **sector 7168 up to the first partition** in one `dd` when given `FACTORY_DUMP=`, then lays
the idbloader and slot A on top. That covers vendor storage, secure storage, the `security` tail,
both U-Boot slots and `trust`, and it keeps whatever a future board puts in there.

The window's end is read out of the GPT (`gpt_first_lba`, two `od` reads: partition-array LBA from
the header, then entry 0's start) rather than hardcoded to 32768 — with a guard that aborts if a
base image ever places its first partition inside the window. Hardcoding it would have silently
eaten the filesystem the day the base image moved.

Slot B logic follows from the order: with the dump it is left as the factory U-Boot the restore put
there; without one, our FIT is written to it explicitly.

Verified on rebuilt images — 3518D (with dump): 7168–10239, 10240–16383, 20480–24575 and 24576–32767
all byte-match the dump, slot A is ours, five idbloader slots match the blob. R69 and H96 Max (no
dump): slot A and slot B both ours, five slots match, window left empty.

### Same day — what `armbian-install` actually touches, and the migration path fixed to match

Read the merged wipe out of the upstream source rather than our own summary of it (`configng`
`554129a8`, `module_install_engine.sh:301-312`). Both paths stop at sector 20479 — the narrow one
zeroes 0–7167 plus 16384–20479, the wide one zeroes 0–20479 — and the partition plan starts the
first partition at 16 MiB. So **U-Boot slot B and `trust` survive a migration untouched**, and a
migrated box keeps the factory U-Boot in slot B by accident. That is the good configuration: the
stock fallback serves rockusb, ours does not.

`docs/armbian-install.md` contradicted itself and is corrected: its table claimed `16384–32734` was
zeroed while its own quoted snippet zeroed `16384–20479`.

**The two install paths had drifted.** `build-image.sh` writes five idbloader slots; the
`write_uboot_platform` override wrote the 2 MiB blob once, landing four copies on the H96 boards and
two on the R69, and never the fifth. Fixed to write the blob's first copy into all five slots. It
deliberately still does **not** write slot B — leaving the factory U-Boot there is better than
overwriting it with ours.

Tested by sourcing the override and running `write_uboot_platform` against a 32 MiB scratch file:
five slots byte-match the blob, slot A is our FIT, slot B and sectors 0–63 untouched.

README's install instructions rewritten: the "zeroes the first 10 MiB" line was only ever true of
the unfixed installer; the restore recipe now says explicitly **stop at 16383**, because restoring
further would drop the factory U-Boot back onto slot A on top of ours and the box would boot looking
for Android partitions that no longer exist. The post-migration check is now a classifier that
buckets every differing sector and flags anything outside GPT / idbloader / slot A. Run against a
built image and its own dump it reports exactly `453 GPT` and `727356 uboot A` — no idbloader
difference, because the blob we write is that box's own.

### Same day — correction: the survival story was framed backwards

Pushed back on, correctly. I had led with "the installer never writes above sector 20479", which
reads as reassurance. The accurate emphasis is the opposite: **everything below sector 20480 is
destroyed**, and `DVKR`/`SSKR` survive only because of the keep-window patch in `armbian/configng`,
which is recent and absent from most shipped images. Re-framed in `README.md` and
`docs/armbian-install.md` to lead with the destruction and the version dependency; the slot-B
survival is now a secondary note where it belongs.

Re-checked the claim itself before defending it, this time across the whole engine rather than the
one function: the only raw-device operations are `wipefs -aq`, the three `dd` zeroes,
`parted mklabel` and `mkfs` on the new partitions — no `blkdiscard`, no `shred`. So the zeroing
genuinely does stop at 20479 on both paths, but that is a footnote, not the headline.

Added a best-effort pre-flight check to the README —
`grep -rls keep_window /usr/bin/armbian-config /usr/lib /usr/share` — with the caveat not to trust
it; the authoritative test stays the post-migration diff. The string is the one in
`module_install_engine.sh`; configng has no fixed install path for its modules, hence the shotgun
grep.

### Same day — `u-boot.itb` renamed to `uboot.itb`, on disk too

No dash anywhere, matching `uboot.dts`. I had left the artifact alone on the grounds that it is
upstream's own filename and a deployed path; both were reasons to be careful, not reasons not to do
it.

Renamed in the repo **and** at the installed path, so `AGENTS.md`'s "repo filenames mirror the names
installed on disk" still holds rather than gaining an exception:

| Thing                        | Now                                              |
| ---------------------------- | ------------------------------------------------ |
| repo artifact                | `firmware/<board>/uboot.itb`                     |
| `board.conf`                 | `BOARD_UBOOT=<board>/uboot.itb`                  |
| installed path               | `/usr/local/share/rk35xx/uboot.itb`              |
| `write_uboot_platform` reads | `$1/uboot.itb`                                   |
| `rk35xx-update`              | removes the old `$SHARE/u-boot.itb` in `migrate` |

The build tree's own `u-boot.itb` keeps its name — that is U-Boot's output, and `build-uboot.sh`
copies `$O/u-boot.itb` to `firmware/<board>/uboot.itb`.

The removal sits in `migrate()`, which runs immediately before the payload install, so the old name
goes and the new one lands in the same run. Losing it briefly is harmless anyway: that copy is only
read by `armbian-install`'s `write_uboot_platform`, never at boot.

Rebuilt from scratch after deleting the old files — all three FITs emitted under the new name, all
three images carry five idbloader copies and our FIT in slot A, and the r69 image's rootfs holds
`/usr/local/share/rk35xx/uboot.itb` byte-identical to `firmware/r69/uboot.itb` with
`platform_install.sh` pointing at it.

### Same day — stock-first for the U-Boot tree: investigated, and it cannot work

Challenged on why the U-Boot DT does not follow the factory blob the way `board.dts` does. The rule
is right and I had no good reason at the time; the investigation found one, and it is not the one I
had been giving.

Everything I had claimed as an obstacle turned out to be solvable:

- **Labels.** `dtc -P` reconstructs all 38 phandle references as `&{/path}` despite the blob having
  no `__symbols__`, and the output recompiles **byte-identical** to the factory blob. 18 explicit
  `phandle` properties are preserved, which is why the 24 remaining raw values stay valid.
- **Phase tags.** The vendor's 40 tags sit on exactly the right nodes; `u-boot,dm-pre-reloc` →
  `bootph-all`, `u-boot,dm-spl` → `bootph-pre-ram` is a mechanical rename.
- **`rk3528-u-boot.dtsi`.** Irrelevant — `scripts/Makefile.lib` uses the **first** match of
  `<dt>-u-boot.dtsi`, `<soc>-u-boot.dtsi`, …, so a per-board file shadows it, and binman's
  `rockchip-u-boot.dtsi` references only `&binman`/`&fit_template`, both its own.

**The real blocker is the clock-ID space.** The vendor DT and mainline's `rockchip,rk3528-cru.h`
disagree on every ID checked:

| Node              | vendor    | mainline  |
| ----------------- | --------- | --------- |
| uart2 sclk/pclk   | 27 / 192  | 25 / 160  |
| saradc clk/pclk   | 257 / 256 | 195 / 194 |
| eMMC, five clocks | 163–167   | 140–144   |
| sdmmc cclk/hclk   | 408 / 407 | 295 / 296 |

Caught by a sanity check: the stock `serial@ffa00000` asks for clocks `0x1b`/`0xc0`, but mainline's
`SCLK_UART2`/`PCLK_UART2` are 25/160. The vendor's **kernel** DT and **U-Boot** DT agree with each
other — both say `0x101`/`0x100` for saradc — so one vendor ID space serves both.

That is why `board.dts` may be stock-first and this may not: `board.dts` is a vendor tree handed to
a vendor kernel (Armbian rk35xx vendor 6.1 is Rockchip downstream). Our U-Boot is mainline. A
stock-derived tree would resolve every clock to the wrong one, silently — no error, just an eMMC
asking for whatever mainline calls 163–167.

Kept the mainline-based tree with values mined from each board's factory DT, and wrote the reasoning
into `docs/uboot.md` so it is not re-litigated. Retroactively this also explains the `saradc`
rename: it is not an accident of the upstream base, it is the cost of using mainline's binding, and
it is paid once in four lines.

### Same day — correction: stock-first works, and the U-Boot tree is now built that way

The previous entry concluded the clock-ID mismatch made stock-first impossible. **That was wrong.**
The mismatch is real, but it is a translation, not a wall — and the repo's rule stands unqualified:
follow the factory DTB and graft the minimum.

What made it tractable, all measured:

| Obstacle I had claimed           | Reality                                                                         |
| -------------------------------- | ------------------------------------------------------------------------------- |
| no labels in the blob            | `dtc -P` emits `&{/path}`; the output recompiles **byte-identical** to the blob |
| `u-boot,dm-*` tags are dead      | mechanical rename, 40 per board                                                 |
| `rk3528-u-boot.dtsi` won't apply | do not use it — the Makefile takes the **first** dtsi match, so ours shadows it |
| clock IDs disagree               | vendor header names the value, mainline's supplies the new one — 28 cells       |
| reset IDs disagree               | same, plus a spelling rule `SRST_PRESETN_X` → `SRST_P_X` — 11 cells             |

`./build-uboot-dts.sh` now regenerates `firmware/<board>/uboot.dts` from `stock/<board>/uboot.dtb`
in two auditable stages: a mechanical retarget (`upstream/scripts/uboot-renumber.py`, which refuses
to guess and reports what it leaves alone) and a commented `uboot.patch` of 75–86 lines. It gates on
the decompile round-tripping byte-identical, and on the result compiling.

**The saradc rename hack is gone.** The vendor already names the node `saradc@ffae0000`, which is
exactly what `rockchip_dnl_key_pressed()` matches. Basing on upstream created that bug; following
the vendor never had it. That is the rule earning its keep.

Two bugs found on the way, both by checking rather than by the build failing:

- The retarget skipped `mmc@ffc30000` because `-P` had left its `clocks` raw — the property mixes
  two providers with different `#clock-cells`, so the conservative walk bailed. The SD controller
  would have kept vendor numbering silently. Caught only because that line did not move in the diff;
  the "26 cells renumbered" summary looked fine.
- The earlier no-dash rename had renamed `<dt>-u-boot.dtsi` to `-uboot.dtsi`. Upstream's Makefile
  globs for the dashed name, so ours silently stopped being found and the SoC-wide file was used
  instead. Harmless while ours only included that file; fatal the moment it needed to shadow it.

All three boards build (733,696 bytes each) and verify: node named `saradc@ffae0000`, saradc clocks
195/194, eMMC 140–144, `stdout-path` on uart0, eMMC and uart0 both surviving into the SPL tree,
`sdmmc` disabled on the 3518D alone. Images rebuilt, five idbloader slots and slot A confirmed.
Still 🟡 on hardware — the 3518D is unreachable and the H96 Max is not to be flashed.

### Same day — dropped the `compatible` graft from the U-Boot tree

Asked whether `model`/`compatible` are needed at all in the U-Boot control DT, since the kernel gets
its own. Checked:

- **`compatible`: no consumer.** Nothing in `arch/arm/mach-rockchip` matches the root compatible,
  and `OF_BOARD_SETUP`/`OF_SYSTEM_SETUP` are both unset, so the control DT is never fixed up and
  handed on. The graft is now dropped and the tree keeps the vendor's `rockchip,rk3528-evb` — one
  less fabricated string for a future reader to assume matters.
- **`model`: kept.** `common/board_info.c:72` prints it as the banner's `Model:` line. Without the
  graft all three boxes announce themselves as "Rockchip RK3528 Evaluation Board", which is exactly
  wrong when the point of a serial console is telling near-identical boards apart. The comment now
  says that, rather than the vaguer note it replaced.

Patches shrank to 73/73/82 lines. Rebuilt and reverified: correct per-board `model`, vendor
`compatible` intact, five idbloader slots and slot A confirmed in all three images.

### Same day — readable values in the lines we author

The decompiled body is hex because that is what `dtc` emits, but the graft is ours to write. The
added uart0 node and `vdd-microvolts` now read as quantities: `24000000` not `0x16e3600`, `1800000`
not `0x1b7740`, `reg-io-width = <4>`, and the two clock cells split one per line with
`/* SCLK_UART0 */` and `/* PCLK_UART0 */` beside them — the macro names cannot be used in a
decompiled tree, so the comment carries them. Addresses stay hex, which is how addresses read.

Retargeted cells from the mechanical pass stay hex on purpose: they are rewrites of vendor values
sitting among vendor values, and decimal there would only look like a third convention.

Confirmed cosmetic — recompiled and the stored values are unchanged: `0x13`/`0x6b`, `0x16e3600`,
`0x04`, `0x02`, `0x1b7740`. Rebuilt all three FITs and images and reverified.

### Same day — dropped the unused `serial0` alias

Asked why the graft adds `serial0 = "/serial@ff9f0000";`. It was copied from mainline's
`rk3528-generic.dts`, which pairs `serial0 = &uart0` with `stdout-path = "serial0:1500000n8"` — but
our graft writes `stdout-path` as an absolute path, and `serial_check_stdout()` resolves a string
starting with `/` as a path, consulting aliases only otherwise
(`drivers/serial/serial-uclass.c:52`). The fallback beneath it uses `CONFIG_CONS_INDEX`, not
aliases, and only runs if that resolution fails. So nothing read it.

Removed; the `aliases` block is now untouched from stock. Patches down to 66/66/75 lines. Rebuilt
and reverified: `stdout-path` resolves to the uart0 node, which is present in both the control and
SPL trees on all three boards.

### Same day — why the factory `stdout-path` names uart2

Asked why stock points at `serial@ffa00000` when the header is uart0. It is not a disagreement:
**the vendor never routes its console through DT at all.** U-Boot reaches uart0 through a raw
debug-UART path set by build config (`PreSerial: 0, raw, 0xff9f0000`), and the kernel through
`fiq-debugger` with `rockchip,serial-id = <0>`, surfacing as `ttyFIQ0`. Because fiq-debugger owns
uart0, the factory kernel DT leaves the ordinary uart0 node `disabled` — which is why our kernel
graft enables it with the note "fiq-debugger below gives up this same UART".

So the factory U-Boot tree describes no uart0, and its `stdout-path` simply names the only DM serial
node present. That node is **not spare**: uart2 is a data UART, and on the R69 it carries the
AIC8800 Bluetooth HCI with CTS (`upstream/r69-xr821/armbian.patch`, the `bluetooth` child under
`uart2m0_xfer &uart2m0_ctsn`). Repointing a console there would aim it at the modem.

Mainline U-Boot has neither mechanism and drives the console from `stdout-path`, so uart0 must be
spelled out in DT. Both stacks agree on which UART the console is; only the expression differs. The
graft comment now records this, including "do not repoint stdout-path at uart2".

### 2026-09-06 — the `fiq-debugger` graft rests on a misread

Challenged on whether disabling `fiq-debugger` was ever needed, on the grounds that Android runs
`ttyFIQ0` on the same hardware with serial working. Checked, and the challenge is right.

`stock/h96max-3518d/boot.log`, stock Android on stock DTB, `console=ttyFIQ0`:

```
[    0.040007] Registered FIQ tty driver
[    0.085755] fiq_debugger fiq_debugger.0: error -ENXIO: IRQ fiq not found
[    0.086438] fiq_debugger fiq_debugger.0: error -ENXIO: IRQ wakeup not found
[    0.087084] fiq_debugger_probe: could not install nmi irq handler
```

Those three lines were read as breakage. They are not — the vendor sets
`rockchip,irq-mode-enable = <1>` on all three boards because there is no FIQ here, so it runs in IRQ
mode and Android ships with exactly this output while its serial console works. The whole 21k-line
boot log we captured came over it.

`docs/r69/worklog.md` records what was actually being fixed: Armbian's `console=both` appended
`console=ttyS2,1500000` from the rock-2f base, whose debug UART is `ffa00000`, spawning a getty on
the R69's **Bluetooth** UART and eating its HCI replies. That is a `console=` bug. Pointing the
console at `ttyFIQ0` fixes it with no device-tree change; enabling uart0 as `ttyS0` and disabling
the fiq node was one way to get there, and the tree-touching one.

It also fights the base: rock-2f's console _is_ the fiq-debugger, so Armbian ships
`serial-getty@ttyFIQ0`, which then blocked 90 s waiting for a device our DTB had removed and needed
a `migrate()` cleanup.

Kernel portability, which I had offered as the rationale, does not hold either: this overlay is
vendor-kernel-shaped throughout (VPU, Seekwave DKMS, the IR module).

Nor is there a debugger to lose, which I had also claimed. `IRQ fiq not found` and
`could not install nmi irq handler` mean the debugger half never initialises on this hardware; what
remains is `Registered FIQ tty driver`, a plain tty over uart0 in IRQ mode. So neither option has a
functional edge — the graft costs two hunks and buys a conventional tty namespace, and that is the
whole of it.

Docs corrected — the rationale had been recorded circularly as "frees `ff9f0000` for `ttyS0`" in
three places. Graft left in place: reverting changes the console path on daily drivers and needs a
boot on the R69 with serial attached.

### 2026-09-06 — this board drops the console graft; the other two keep it

Acting on the finding above, and only here: the 3518D is the board not yet in service, so it is
where this gets tried.

- `upstream/h96max-3518d/armbian.patch`: both console hunks reverted. uart0 goes back to `disabled`,
  `fiq-debugger` back to `okay` — byte-identical to the factory tree for both nodes. Regenerated
  with `BOARD=h96max-3518d STOCK=h96max-3518d SYNC=1 ./upstream/build.sh`, which passed its own
  gate: `VERIFIED: native tree is content-identical to the patched tree`.
- `build-image.sh`: `SERIALCON` now honours a `BOARD_SERIALCON` override.
- `firmware/h96max-3518d/board.conf`:
  `BOARD_SERIALCON="earlycon=uart8250,mmio32,0xff9f0000 console=ttyFIQ0"`. Baud comes from the
  node's `rockchip,baudrate`; earlycon stays the plain 8250 at the same address, exactly as stock
  Android's cmdline does it.

No unit work needed — systemd's getty-generator reads `/proc/consoles`, so the login prompt follows
the console on its own. `migrate()` still removes the stale `serial-getty@ttyFIQ0` units from the
ttyS0 era; the generator recreates a live one at runtime.

Verified in the built image: `extraargs=… console=ttyFIQ0 …` in `armbianEnv.txt`, and the installed
`board.dtb` has uart0 `disabled` / `fiq-debugger` `okay`. R69 and H96 Max checked untouched — both
still `uart0=okay fiq=disabled`.

🟡 **Untested.** The box has not booted since it went unreachable. If `ttyFIQ0` does not come up the
fallback is the other boards' shape: uart0 `okay`, `fiq-debugger` `disabled`, drop
`BOARD_SERIALCON`.

### 2026-09-06 — swept this board's settings, and moved the graft to live with the board

Three changes to the tree, all this board only:

| Change                       | Why                                                                                                  |
| ---------------------------- | ---------------------------------------------------------------------------------------------------- |
| `model` drops the EVB suffix | it is `H96 Max 3518_DG_ZX_V01`, not "… (Rockchip RK3518 EVB1 DDR4 V10)"                              |
| `gmac0` → `disabled`         | no PHY fitted; `board.md` already recorded the cost — a boot delay and two `-110` errors for nothing |
| `sdmmc` → `disabled`         | no SD slot; the controller binds and claims `vcc-sd`/`vccio_sd` regardless                           |

Both peripherals were documented as absent in `board.md` from the first evidence sweep and left
enabled anyway. `rootdev` is a UUID, so nothing depends on the `mmcblk` numbering that disabling
sdmmc may shift.

**Left alone deliberately: IR.** `board.md` records `ffa90030.pwm` with nine `ir_keyN` tables and no
receiver visible on the PCB, but "microscopic, otherwise I would notice it" is not a measurement.
The payload still ships the `rockchip-pwm-remotectl-rk35xx` DKMS and `armbianEnv` still carries
`initcall_blacklist=rk_pwm_driver_init`. Both are inert if no receiver exists, and removing them
before testing would destroy the ability to test. Settle it with an unpaired remote key while
watching the input device, then prune.

**`armbian.patch` → `firmware/<board>/board.patch`.** The graft is board data — it is the source of
`firmware/<board>/board.dts` — and it was the only hand-edited file in a directory that is otherwise
generated and gitignored. It now sits beside `uboot.patch`, which was placed there for the same
reason. `upstream/<board>/` keeps `header.dts`, which really is an upstreaming artifact.
`upstream/build.sh` reads `firmware/$STOCK/board.patch`; re-ran for the 3518D
(`matches the submission`) and the R69 (`DIFFERS … left alone`, its documented intentional
divergence — no `SYNC=1`, nothing touched).

Verified in the rebuilt image: installed `board.dtb` has the trimmed model, `gmac0`/`sdmmc`
disabled, uart0 `disabled` and `fiq-debugger` `okay` as stock.

### 2026-09-06 — the ttyFIQ0 getty removal had to be gated too

Switching this board's console to `ttyFIQ0` left two places actively deleting the getty for it:

- `build-image.sh` dropped the base's `serial-getty@ttyFIQ0` symlink, on the reasoning that "that
  device cannot exist here (fiq-debugger is off)" — true for the other two boards, false for this
  one now.
- `rk35xx-update`'s `migrate()` removed the same two unit paths on every update.

Both were right when every board disabled the fiq-debugger, and both would have left this board with
a serial console printing kernel messages but no login prompt.

Systemd's getty-generator would probably have covered it from `/proc/consoles`, but "probably" is
not good enough for the login prompt on the board being brought up over serial, and the base ships
that unit deliberately. So both are now conditional: `build-image.sh` keys off `SERIALCON`
containing `ttyFIQ0`, and `rk35xx-update` keys off `/dev/ttyFIQ0` existing on the running box —
which is the honest test, since it reflects what the current DTB actually produced.

Verified by rebuilding both shapes: the 3518D image keeps
`getty.target.wants/serial-getty@ttyFIQ0.service`, the R69 image still drops it.

### 2026-09-06 — first boot of the stock-derived U-Boot: halts at `dram_init()`

Full image written and byte-verified, box reset, and it got most of the way:

```
U-Boot 2026.04 (Sep 06 2026 - 04:47:10 +0000)
Model: H96 Max 3518_DG_ZX_V01
DRAM:  initcall_run_f(): initcall dram_init() failed
### ERROR ### Please RESET the board ###
```

What that proves works: the factory idbloader loads our FIT from slot A and **all five hashes
pass**, BL31 v1.21 runs and reports `RK3518 SoC`, U-Boot proper starts, and the console reaches the
header — so the uart0 graft and the retargeted clocks are right, and the trimmed `model` shows.

**The bug is mine.** `dram_init()` does `uclass_get_device(UCLASS_RAM, 0, ...)`, and the only thing
binding a `UCLASS_RAM` device is `rockchip,rk3528-dmc` (`drivers/ram/rockchip/sdram_rk3528.c`). That
node exists **only** in `rk3528-u-boot.dtsi`, the file we deliberately stopped including, and the
factory tree has no equivalent because vendor U-Boot takes the DRAM size from the TPL instead.

When I dropped that file I checked what _labels_ it patched and confirmed a stock-derived tree has
none of them. I never checked what _nodes_ it uniquely provides. Enumerated properly now: `aliases`
and `chosen` (factory tree has both), `rng@ffc50000` (present), `nvmem@ffce0000` (absent, optional —
OTP, nothing on the boot path), and `dmc` (absent, **required**).

Fixed by emitting the `dmc` node into the generated per-board `-u-boot.dtsi` alongside binman's
include. Verified present in the rebuilt control DT.

**No software route back in**, and each reason is a detail from earlier in this session:

- SPL's slot-B fallback triggers on a **hash** failure, not a hang. Slot A's hashes passed.
- The SARADC download key runs in `board_late_init()`; this dies in `board_init_f`, long before.
- No USB in U-Boot, no prompt, no SD slot.

Recovery is the recovery button at power-on with the case open — proven on this box, it is how the
original backup was taken. Only slot A needs rewriting afterwards; the rest of the image is already
written and verified.

### 2026-09-06 — the recovery was in a blob we already had: `ctrl+b` in the vendor SPL

`strings firmware/<board>/factory_idbloader.bin`:

```
SPL Hotkey: ctrl+%c
ctrl+b: Bootrom download!
```

Rockchip's vendor SPL takes **Ctrl+B on the serial console** and enters BootROM download mode. It
runs from sector 64, before our U-Boot, so it works no matter how broken slot A is. Present in all
three boards' loaders. The window is short — SPL completes in ~85 ms — so the key has to be spammed
while power is applied, not typed at a prompt.

**How this was missed, which is the part worth keeping.** The SPL was treated as a black box that
either boots or does not. The blob was in the repo throughout, and `strings` was run against other
blobs repeatedly the same day to check BL31 versions. When the ADC-button route turned out to be
U-Boot-mediated and therefore dead, the jump was straight to hardware: clock shorts, tented vias,
soldermask scraping, lifting a ferrite on the eMMC rail. The user was sent probing pads beside a
BGA, and one candidate pair measured 1.27 V — the LPDDR3 rail — caught only by insisting on a
measurement first.

The worklog already said the button is an `adc-keys` input read by U-Boot. The right next question
was "then what does the SPL offer?", not "then we need hardware".

**Rule: before proposing physical intervention, exhaust what the code already on the device can
do.** Every stage that runs before the broken one is a candidate, and for the ones we ship as blobs
that means reading them — `strings`, the embedded DT, the printed banners — not assuming.

### 2026-09-06 (later) — antenna on: Wi-Fi and Bluetooth both work

Wi-Fi credentials were copied from the sibling box machine-to-machine
(`ssh art@h96max 'sudo cat …' | ssh art@h96max-3518d 'sudo tee …'`) so the secret never landed in a
terminal here, then `chmod 600`, `root:root`, `netplan apply`.

Associated on 5 GHz immediately: −28 dBm, 80 MHz HE. **No TX latch.** The sibling's 6 Mbit/s pin
(`docs/h96max/wifi-tx-latch.md`) does not reproduce — `iperf3` sustained 237 Mbit/s down and 274
Mbit/s up.

Measuring that needed a detour: the box has a default route out the USB Ethernet adapter, so traffic
addressed to the wlan0 IP would have been answered over the wire and measured the wrong link. A
source-based policy route (`ip rule add from <wlan0 ip> lookup 100`) pinned it, and was removed
afterwards.

Bluetooth needed nothing at all — `hci0` was already `UP RUNNING` on SDIO at BT 5.4, and an LE scan
returned 10+ devices. **The earlier "BT may need work" gap was a tooling artefact:** `hciconfig` and
`iw` are simply not installed in the base image, so the first check returned empty output and read
as broken hardware. `AGENTS.md` already lists `iw` and `bluez` under "on the box" — the box had
never had them installed.

Two smaller things fell out of the same pass:

- `iw` lives in `/sbin`, which is not on a non-login SSH shell's `PATH`. An empty result from `iw`
  over `ssh` means "not found", not "no link".
- The Seekwave `-2` firmware-load errors are **by design** — the driver probes
  `<file>.<compatible>.nvbin` before falling back to the generic blob, which is present and loads.
  Worth writing down because they look exactly like a missing-firmware fault.

### 2026-09-06 (later) — the USB hot-plug reset is a brownout

Confirmed rather than inferred: the RTL8153 adapter that resets the box when hot-plugged **had been
carrying this box's SSH session continuously**, plugged in before power-on. A driver fault would not
care when the cable went in. `pstore` is empty and the boot before the reset lasted ~1 s, so nothing
panicked — the SoC simply lost its rail. `vcc5v0_host`/`vcc5v0_otg` both derive from `vcc5v0_sys`,
which is USB-C bus power, and there is no second input. Not fixable in software.

### 2026-09-06 (later) — payload ownership fixed at both ends

The build-host uid leak (`501:20` → `UNKNOWN:dialout`) is closed. `build-image.sh` already had the
`e2cp`/`e2mkdir` wrappers forcing `-O 0 -G 0` on writes into the image; what was missing was the
repair path for boxes already deployed, now a migrate step in `rk35xx-update`.

The step is deliberately small because most of the work is already done for it: the payload install
that runs immediately after is `install -D` as root, which **re-owns an existing file** — verified
on the box, `501:20` → `0:0`. So the migrate step only has to cover what the payload does not ship:
the DKMS trees under `/usr/src`, the distro files we edit, and the directories we create.

On this box: 163 paths corrected by the migrate step, 5 more by the payload install, 0 left.

One thing not fixed, on purpose: `find / -xdev -nouser` still reports 28 paths. They are **Armbian's
own** build-host leakage in `/var/lib/apt/lists` and the keyring docs, under a different uid than
ours. Not ours to chown, and blanket-fixing them risks `_apt`'s directories.

### 2026-09-06 — IR is dead: no receiver fitted, and the whole path comes out

`evtest /dev/input/ir-remote` produced nothing on any keypress. That device is the right one —
`/dev/input/ir-remote` → `event4` → `ffa90030.pwm`, the module was loaded, and
`initcall_blacklist=rk_pwm_driver_init` was on the command line, so the software side was fully
wired.

**A silent `evtest` is not proof on its own**, and that nearly became a wrong conclusion. The driver
only emits a key event when the received usercode matches one of the nine `ir_keyN` tables; a
receiver picking up an unlisted remote looks exactly like no receiver. The driver has a `code_print`
module parameter that logs `USERCODE=0x…` for any pulse train, matched or not, and that test was
being set up when a better one arrived.

**The better test: the same remote drives the H96 Max box over IR.** A known-good receiver, the same
handset — so the transmitter is fine and the missing half is on this board. No debug parameter
needed.

So the whole IR path is removed here rather than merely unused:

| Layer  | Change                                                                       |
| ------ | ---------------------------------------------------------------------------- |
| tree   | `pwm@ffa90030` → `status = "disabled"`; `remote_support_psci` back to `0x00` |
| DKMS   | `rockchip-pwm-remotectl-rk35xx` no longer staged or installed                |
| kernel | `BOARD_IR_BLACKLIST=""` — no `initcall_blacklist=rk_pwm_driver_init`         |

Disabling the node is what makes the other two safe to drop. The kernel builds
`rockchip_pwm_remotectl` in without the shared-IRQ fix; the blacklist exists only to keep that
built-in copy off a receiver, so our patched module can own it. With the node disabled neither
binds, and leaving it enabled would have cost a shared group-IRQ storm for nothing.

`remote_support_psci = <0x01>` was our graft, added on the assumption IR worked. It is reverted —
there is no receiver to wake the box from.

Regenerated with
`BOARD=h96max-3518d STOCK=h96max-3518d SOC=rk3528 BASE=rk3528-evb1-ddr4-v10.dtsi SYNC=1 ./upstream/build.sh`;
the gate still reports `VERIFIED: native tree is content-identical to the patched tree`. Checked
afterwards that `mmc@ffbf0000` (the eMMC) is still `okay` — the one node a mistake here would have
been expensive on.

**Not yet deployed to the box.** The running 3518D still has the old DTB, the DKMS module and the
blacklist; it needs an image rebuild or a DTB copy plus a reboot.

### 2026-09-06 (later) — the remote works over BLE, and gets stable symlinks

Paired, and both halves work: `Bluetooth remote Keyboard` on `event5` and `Bluetooth remote Mouse`
on `event6` — one HID device pair, `2B54:1600`, BT address `74:cc:23:de:9d:33`.

`event*` numbering is probe-order dependent, so two rules went into the shared
`rk35xx-input-names.rules`:

```
ATTRS{name}=="Bluetooth remote Keyboard" -> /dev/input/bt-remote
ATTRS{name}=="Bluetooth remote Mouse"    -> /dev/input/bt-remote-mouse
```

Verified live rather than assumed: installed the file, `udevadm control --reload`,
`udevadm trigger --subsystem-match=input`, and both symlinks appeared pointing at event5/event6.
They are in the shared file because the same handset ships with all three boards.

`/dev/input/ir-remote` was left alone. It matches `ATTRS{name}=="*.pwm"`, and with `pwm@ffa90030`
disabled no such input device exists, so the rule simply never fires here — a udev rule for an
absent device costs nothing. (It is still present on the running box only because that box has not
yet been redeployed with the new tree.)

### 2026-09-06 (later) — measured the box properly

`fio` and `iperf3` installed; numbers now in `board.md` rather than estimated.

| What                  | Value                                         |
| --------------------- | --------------------------------------------- |
| eMMC sequential read  | 43.3 MB/s                                     |
| eMMC sequential write | 37.1 MB/s                                     |
| eMMC random 4k read   | 2879 IOPS / 11.2 MB/s                         |
| SoC idle              | 48-53 °C, no heatsink                         |
| SoC under eMMC load   | 50 °C — the eMMC is not what heats this board |

**43.3 MB/s confirms the HS 50 MHz cap is real and is the ceiling**, not a driver problem: 50 MHz ×
8 bit ≈ 50 MB/s theoretical. The factory tree's `max-frequency = <50000000>` with no
`mmc-hs200-1_8v`/`mmc-hs400-1_8v` is what sets it, while vendor U-Boot uses HS400 200 MHz for its
own reads — so the silicon can do better.

`lsusb -t` settled the USB question: four root hubs — `xhci` 5000M and `xhci` 480M (the USB-C OTG
controller), `ehci` 480M and `ohci` 12M (the USB-A socket). **USB 3 exists only on USB-C**, so the
gigabit adapter in the USB-A port can never exceed USB 2.

One caveat recorded rather than glossed: the adapter is currently behind an external Fresco Logic
`1d5c:5011` hub, so the "runs indefinitely when present at power-on" observation was made through a
hub. Bare-socket versus behind-a-hub hot-plug has not been isolated.

### 2026-09-06 (later) — two state markers corrected, and one claim narrowed

**IR is ➖, not ❌.** `❌` in this repo means tested and broken; a receiver that was never fitted is
absent hardware, the same as the AV jack. Corrected in `board.md` and the README table.

**Maskrom on the 3518D is 🟡 again, not ✅.** The ✅ was earned while the box still ran the
_factory_ U-Boot, and the route used was `Loader` → `rd 3`. `Loader` only exists because the factory
U-Boot serves rockusb; ours is `# CONFIG_USB is not set` and presents nothing on the bus, so **that
route is gone on a box running our loader**. Maskrom itself is BootROM-level and unaffected, but the
way in is not: what remains is the recovery button (🟡 built, never pressed on our U-Boot) and
`ctrl+b` at the vendor SPL (✅, runs before U-Boot). Marked 🟡 in `board.md`, the README table and
the per-board table in `docs/maskrom.md`.

The general lesson, worth keeping: **a capability measured before we replaced a boot stage is not
evidence about the box after it.** The same trap as marking something verified because a sibling
board does it.

### 2026-09-06 (later) — README trimmed to a reference, maskrom.md owns the USB route

The 52-line "No SD slot: back up and install over USB" section came out of the README, replaced by a
short pointer to `docs/maskrom.md`, which already covered the same ground in more detail.

Before deleting it, the two recipes were diffed rather than assumed equivalent — and they were not.
The README carried the **fuller** factory-window splice (`4160` +12224 sectors, and `20480` +4096,
which keeps the 5th idbloader copy and the factory U-Boot in slot B); `maskrom.md` had only `7168`
+9216. `maskrom.md` was upgraded to the two-range version first, so nothing was lost with the
deletion.

Also repaired three README tables that an earlier scripted edit had collapsed into paragraphs: the
prefix match `"| ---------"` hit every separator row, not just the intended one, and a value
appended before the closing `|` merged into the last cell instead of adding a column. Rebuilt Boxes,
What works and the serial-console table from scratch, then diffed every row against `5cadde2` to
confirm **no R69 or H96 Max value changed**.

### 2026-09-06 (later) — README reduced to pointers, maskrom.md given the sections to point at

`## No SD slot` and `## Recovery` in the README are now two or three lines each that name
`docs/maskrom.md`, instead of restating its content. For those pointers to land somewhere real,
`maskrom.md`'s single `## Restore` was split into **`## Install an Armbian image over USB`** and
**`## Recover from a backup`** — the two things a reader actually arrives wanting, which the old
heading buried in one section.

Board names came out of the README prose in favour of the hardware class: "IR works unpaired, unless
the board has no IR receiver — the stick models do not," rather than naming this box. A reader with
a fourth box should still recognise their situation. Per-board _tables_ keep the names, which is
what they are for.

Two inaccuracies fixed while there: the build example still listed only two board keys, and the
serial-console note still said the H313 case is the fussy one to open without naming it that way.
The H96 Max display name is now **H96 Max H313** (the model name on the back of the case) in every
table and in `docs/h96max/board.md`. `firmware/h96max/board-name` still reads `H96 Max 3518_ZX_V01`
— that is the installed login banner on a deployed box, so it was left alone rather than changed as
a side effect.

Also dropped a README aside on diagnosing dead IR ("usercode missing, or no receiver — try the
handset on another box"). With the Remote section already stating which boards have no receiver, it
was advice nobody needed at that point.

### 2026-09-06 (later) — the serial "header" is not a header

Corrected: they are **three tiny round test points, bare pads with no holes**, beside the board-name
silkscreen — not a 3-pin header, which is what every doc had said since 2026-09-05.

It matters beyond wording. With no hole there is nothing to insert and nothing for a test hook to
grip, so contact is surface-only against a pad barely wider than a probe tip. The README's blanket
"no soldering — use test-hook grabbers" advice is true for the R69's header and the H313's plated
holes and **false here**; it now says so. There is also no square pad to index from, so the
`[square pad] first` column is qualified as "where marked" and this board's row keeps its own
reference instead — TX nearest the HDMI side.

The practical consequence is unchanged and worth repeating: only TX and RX have to land on the pads.
GND is easier taken from the HDMI shell, the mounting holes beside it, or a USB shell.

Recorded separately in `board.md`, because it is a practical cost and not just a description: this
is **the hardest serial connection of the three boards to physically make**. The difficulty is in
holding contact rather than finding the pads — a probe slides off with any movement of the cable or
the board. The "worked first attempt" note from 2026-09-05 was about the _wiring_ being right, and
has been qualified so it cannot be read as "this was easy".

### 2026-09-06 (later) — USB 3: the port is not proven, and it is not the device tree

Question raised: are we missing a graft that would enable USB 3? **No.** Checked end to end:

| Check                          | Result                                              |
| ------------------------------ | --------------------------------------------------- |
| `dwc3` driver                  | bound to `fe500000.dwc3`                            |
| `xhci-hcd`                     | bound (`xhci-hcd.4.auto`)                           |
| combphy                        | bound to `naneng-combphy`                           |
| dwc3 / combphy errors in dmesg | none                                                |
| SuperSpeed root hub (usb2)     | exists, `maxchild` = 1                              |
| `maximum-speed` on dwc3        | **absent** — nothing throttling it                  |
| `phys` on dwc3                 | `<&u2phy_otg &combphy_pu 0x04>`, named `usb3-phy`   |
| `combphy@ffdc0000`             | `status = "okay"`, clocks/resets/`pipe-grf` present |

The only dmesg line that looks like a fault is
`phy-ffdc0000.phy.3: Looking up phy-supply property ... failed`, which is benign — the node declares
no regulator.

**The device is ruled out too.** A Lexar `21c4:0809` came up at 480M in USB-C, but its BOS
descriptor carries
`SuperSpeed USB Device Capability, wSpeedsSupported 0x000c — Device can operate at SuperSpeed (5Gbps)`.
`bcdUSB 2.10` alone would not have shown this: a USB 3 device falling back to a USB 2 path reports
exactly that, so **the BOS descriptor is the discriminator, not `bcdUSB`**.

**The socket→controller map was measured, not assumed.** The same RTL8153 enumerated on bus 003
(`ehci-platform`) in USB-A and on bus 001 (`xhci-hcd`) in USB-C. That kills the theory that USB 3
might really be the USB-A socket: EHCI is pre-USB-3 silicon and caps at 480 Mbps by design, so no
device in USB-A can ever train SuperSpeed — and swapping which port carries power cannot test
anything, because it does not change which controller each socket is wired to.

**An earlier measurement would have been meaningless and was skipped.** Before the hub came out, the
stick, the Ethernet adapter and the hub were all on bus 001 at 480M, because the Fresco Logic
`1d5c:5011` is a **USB 2.0 hub** — it caps everything behind it regardless of the port. Testing a
400 MB/s stick through it would have measured the hub.

What remains is physical and software cannot separate it: a USB 2.0-only cable or C→A adapter (the
likelier — bundled cables and simple adapters usually omit the SuperSpeed pairs), or the PCB not
routing those pairs to the USB-C connector, which is common on sticks where USB-C is intended as
power plus OTG. Next test: USB 3-rated cabling, or a native USB-C device.

### 2026-09-06 (later) — USB 3 settled: not wired, and now grafted out

Two facts closed it, both from the user and both decisive:

- **The USB 3 stick had no cable.** It went straight into the USB-C socket, so the "USB 2.0-only
  cable or adapter" hypothesis — the one I had ranked likeliest — never applied. A SuperSpeed device
  in direct contact with the connector still trained at 480M.
- **The vendor's Chinese documentation does not claim USB 3**, and would if the board had it.

That is positive evidence of absence, which is the bar the other ghosts here had to meet: `gmac0`
prints `phy_poll_reset failed: -110`, `sfc` prints `unrecognized JEDEC id bytes: 00, 00, 00`. Until
those two facts arrived, USB 3 had only "nothing has enumerated", which a bad cable explains equally
well — so the earlier position, _do not graft yet_, was right on the evidence available and wrong on
the evidence that existed.

Grafted:

```
dwc3@fe500000:  + maximum-speed = "high-speed"
                  phys      = <&u2phy_otg>          (was <&u2phy_otg &combphy_pu 0x04>)
                  phy-names = "usb2-phy"            (was "usb2-phy", "usb3-phy")
phy@ffdc0000:     status    = "disabled"            (was "okay")
```

`combphy` could go with it because dwc3's `usb3-phy` was its **only** consumer — checked, and this
board has no PCIe or SATA node either. Verified after regenerating that `mmc@ffbf0000`, `usbdrd`,
`dwc3@fe500000`, `usb@ff100000`, `usb@ff140000` and `usb2-phy@ffdf0000` are all still `okay`, so USB
2 host on both sockets is untouched; only the 5 Gbps root hub goes away. `upstream/build.sh` still
reports `VERIFIED: native tree is content-identical to the patched tree`.

Note this is a **kernel** DT change and has no bearing on maskrom or `Loader`: those are BootROM and
U-Boot, which never read this tree.

### 2026-09-06 (later) — the doc-length check had a blind spot

The sweep I had been using walked `git status --porcelain`, which collapses an untracked _directory_
to a single entry — so every file under the untracked `docs/h96max-3518d/` was silently skipped, and
`board.md` had drifted past 300 lines unnoticed more than once. Replaced with a `find` over every
`.md` in the repo. That also showed the only other over-length docs are third-party (`uboot-build/`,
rkbin, mbedtls) and the pre-existing `research/` tree, none of which our rule covers.

### 2026-09-06 (later) — deployed everything, then ran the validation battery

Deployed the full repo state with `rk35xx-deploy --no-reboot`, kept a rescue copy at
`/usr/local/share/rk35xx/board.dtb.known-good` first (no SD slot, so nothing else would get it
back), then rebooted deliberately. Back in ~20 s on the new tree.

**Two things the deploy could not carry, worth knowing before trusting a test run:**

- `rk35xx-update` deliberately does not rewrite `/boot/armbianEnv.txt`, so
  `initcall_blacklist=rk_pwm_driver_init` stayed on the cmdline even though the board no longer
  wants it. A fresh image would be correct; a deployed box needs the edit by hand.
- The IR DKMS module stayed registered and built, because dropping a file from `payload.list` does
  not remove what a previous payload installed. `dkms remove` plus `rm -rf /usr/src/…` by hand.

#### The USB 3 graft does not do what I claimed

`maximum-speed = "high-speed"`, `phy-names = "usb2-phy"` and `combphy` `disabled` are all present in
the **running** tree — and bus 002 at 5000M is still there. The line comes from the xHCI IP itself:

```
xhci-hcd: hcc params 0x0220fe64 ... new USB bus registered, assigned bus number 2
xhci-hcd: Host supports USB 3.0 SuperSpeed
```

The controller advertises SuperSpeed from its own capability register and registers the root hub
regardless of the device tree. Corrected in `board.md` and `dtb.md`: what the graft actually buys is
the combphy no longer probing or claiming clocks and resets, not a tidier `lsusb -t`.

#### Boot went from 24.9 s to 13.6 s, and the DTB was the smaller half

| Stage                        | kernel | userspace | total       |
| ---------------------------- | ------ | --------- | ----------- |
| before                       | 5.23 s | 19.68 s   | 24.91 s     |
| after the IR/combphy grafts  | 4.21 s | 19.82 s   | 24.03 s     |
| after one line of board data | 4.22 s | 9.39 s    | **13.61 s** |

The grafts bought ~1 s of kernel time. The other 10 s was `rk35xx-mac-pin`, which waits 50 × 0.2 s
for each interface in `mac-oui` and had `end0` listed — on a board with no ethernet PHY and `gmac0`
disabled. Removing that one line took the unit from 12.6 s to 2.0 s. Filed
`docs/todo/rk35xx-mac-pinning.md`: userspace is the wrong layer for this, and U-Boot is the
candidate now that each board builds its own.

#### Validation battery

Ten warm reboots, **10/10 clean** — root on `mmcblk1p1`, `wlan0` with the same IP _and_ MAC,
`BD_ADDR` unchanged, eMMC `boot0` present, boot 13.0–13.7 s every time. No sign of the dwmmc/SDIO
wedge `board-validation.md` warns about on this family.

Thermals with the heatsink **fitted**: 50 °C idle, 66–68 °C after 5 minutes of 4-core `stress-ng`,
**no throttling** — 1416 MHz held throughout, 27 °C clear of the 95 °C trip point.

Storage re-run with the repo's fixed `fio` parameters (the earlier figures used the wrong `iodepth`
and did not compare): 44.0 / 38.8 MB/s sequential, 2917 / 3863 IOPS random 4k.

Wi-Fi on both bands, with a trap worth recording: after the reboots the box had **roamed to 2.4
GHz** on the same SSID, and the first "regression" to 68 Mbit/s was that, not the antenna — signal
was still −28 dBm. `wpa_cli roam` back to the 5 GHz BSS restored it. No latch on either band: 185
idle → 191 under 4-core load → 206 after.

#### Two bugs the battery caught

**The BT pairing "lost" after a reboot was not lost.**
`Paired: yes, Bonded: yes, Trusted: no, Connected: no`, and the keys were still on disk. A BLE HID
remote reconnects from its own side, and BlueZ refuses an incoming connection from a
bonded-but-untrusted device with no agent running. `bluetoothctl trust` persists `Trusted=true` and
fixes it permanently. README's pairing recipe already had `trust` in the sequence — pairing by hand
skips it.

**`rk35xx-deploy` left 4612 files owned by the build host.** `sudo tar xzf -` as root restores the
archive's uid/gid, so the repo copy at `/usr/local/share/rk35xx/repo` — which `rk35xx-update` is
then executed from, as root — came out `501:20`. Fixed with `--no-same-owner`. This is the same
defect class as the payload ownership bug fixed earlier today, and the validation criterion added
this morning is what caught it on its first run.

#### Bluetooth cannot wake the box

`hci0`'s parent exposes no `wakeup` attribute, neither SDIO host is wake-capable, and no Seekwave
device appears among the armed wake sources. With no RTC and no IR either, this board has no wake
path at all — except `dw-hdmi-cec`, which **is** armed and might let a TV remote wake it. Recorded
in the todo along with `s2idle` as the other candidate.

### 2026-09-06 (later) — codecs, and s2idle made the default

Built MPP on the box (`rockchip-linux/mpp` @ `0986d01`) and ran the matrix as a normal user.

**The gate passes: `mpp_soc: match chip name: rk3528a`.** That is the payoff for putting `rk3528a`
last in the board `compatible` — without it MPP prints `use default chip info`, every encode dies at
`could not found coding type`, and decode quietly falls back to the CPU.

| Format     | Result                                                         |
| ---------- | -------------------------------------------------------------- |
| H.264      | ✅ encode 54.8 fps @1080p, 405 KB, **decodes back** 30 frames  |
| HEVC       | ✅ encode 60.6 fps @1080p, 663 KB, **decodes back** 30 frames  |
| MJPEG      | ✅ encode 171.8 fps @1080p, 4.7 MB, **decodes back** 30 frames |
| MPEG-2     | ✅ decode 20 frames                                            |
| MPEG-4     | ✅ decode 20 frames                                            |
| H.263      | ✅ decode 20 frames (352×288, the format's fixed sizes)        |
| VP8 / VP9  | 🟡 not the hardware — see below                                |
| AVS / AVS+ | 🟡 no clip; ffmpeg cannot encode them                          |
| AV1        | ➖ `mpp: unable to create dec av1 for soc rk3528a unsupported` |

**VP8/VP9 are a harness limit, recorded as 🟡 rather than ❌.** `mpi_dec_test` does not demux: it
rejects IVF _and_ WebM with `Invalid frame marker / read uncompressed header failed`, and VP8 dies
at `mpp_buf_slot: Assertion src->ver_stride failed` with `size 0` — the same shape `docs/mpp.md`
records for MJPEG needing explicit `-w`/`-h`, which did not help here either. Both clips were
Profile 0 yuv420p, so the content was right. The doc's own examples feed **raw elementary streams**
(`-f h264`) and VP9 has no such format, which is the whole problem. Settling it needs a clip MPP's
test tool accepts, not a driver change — `vdpu382a` handles VP9 and the sibling has it ✅.

**The VPU error cluster in dmesg is benign.** Twelve of the 24 boot errors are
`rkvdec2_init: failed on clk_get clk_core`, `No … reset resource define`,
`mpp_rkvdec2 shared_* is not found!` and `rkvenc … failed to init opp info`. All three boards' trees
carry **byte-identical** rkvdec/rkvenc `clock-names` and `reset-names`, and the H313 has codecs ✅ —
so these cannot be fatal, and `docs/mpp.md` already lists them as "known non-fatal noise, identical
under stock Android".

#### dmesg audit

50 err/warn lines, **none repeated** (only `cacheinfo` once per CPU and the benign board-specific
nvbin probe twice). Beyond the VPU cluster: `fiq_debugger … IRQ fiq not found` ×3 (expected — the
console is `ttyFIQ0` and works), `optee … api uid mismatch` (the factory OP-TEE is not loaded under
our U-Boot), two SCMI protocols not active, `drm-logo`/`drm-cubic-lut` reserved-memory nodes with
size 0, and a gyro SPI driver with no matching device. Nothing needing action.

#### s2idle is now the board default

`BOARD_MEM_SLEEP=s2idle` in `board.conf`, assembled into `extraargs` by `build-image.sh` as
`mem_sleep_default=s2idle`. Per-board deliberately: the R69 and H313 have IR wake and `deep` is
right there, so forcing s2idle on them would cost power for nothing. Verified after reboot —
`/sys/power/mem_sleep: [s2idle] deep`, boot still 13.15 s.

The reason is not power. On a TV box suspend exists to get the screen off, and this board has no
wake source in `deep` at all; s2idle keeps devices powered so BT or HDMI-CEC can signal. Everything
the CEC route needs is already present — `/dev/cec0`, `cec-ctl`, and `dw-hdmi-cec` already armed as
a wake source — so a single sitting with a TV can test both wake paths and the standby message.

### 2026-09-06 (later) — `apt full-upgrade` survived, and found a family-wide trap

Run at the user's direction, with the risk stated: 76 packages pending including
`linux-image-vendor-rk35xx`, on a board with no SD slot and no proven maskrom path on our U-Boot.

**It failed part-way the first time**, and the error is misleading:

```
E: Write error - ~LZMAFILE (28: No space left on device)
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

`df /` read **11 G free** at that moment. The full filesystem was **`/tmp`, a tmpfs sized from RAM**
— 984 MB on this 2 GB box — which `armbian-firmware` overflows while apt decompresses. Recovered
with `TMPDIR=/var/tmp/aptwork dpkg --configure -a` then re-running the upgrade the same way. Written
up in `docs/apt-upgrade.md`, because it is not board-specific: any 2 GB Armbian box will hit it.

**A half-configured kernel package is not automatically a broken boot.** Worth checking rather than
panicking: `/boot` still held a complete set for the running kernel and all three symlinks (`Image`,
`uInitrd`, `dtb`) resolved, so the box was safe to reboot throughout.

**The overlay came through intact**, which is the point of the test:

| Check                                    | Result                                               |
| ---------------------------------------- | ---------------------------------------------------- |
| `BOARD_NAME` / hostname                  | ✅ unchanged                                         |
| `linux-u-boot-rock-2f-vendor`            | ✅ **kept back** — the hold did its job              |
| dtb-persist across a real kernel package | ✅ `/boot/dtb-*/rockchip/board.dtb` still ours       |
| `armbianEnv.txt` (incl. `s2idle`)        | ✅ survived, thanks to `--force-confold`             |
| DKMS (seekwave, aic8800, v4l2loopback)   | ✅ all three still `installed`                       |
| After reboot                             | ✅ 0 failed units, 13.195 s boot, MAC/`BD_ADDR` same |

That closes the last unattended item on the list. Note the first boot after the upgrade took ~90 s
to answer SSH even though `systemd-analyze` still reported 13.2 s — post-upgrade first-boot work,
not a regression.

### 2026-09-06 (later) — VP8/VP9 do decode; I was feeding them wrong

Corrected. The earlier entry called VP8/VP9 a harness limit and marked them 🟡. That was wrong, and
the user was right to push: **`mpi_dec_test` sniffs the container from the file extension.**

The clips were fine all along — Profile 0, yuv420p, valid IVF. Naming them `/tmp/c.vp9` made MPP
read the IVF header as a VP9 frame and print
`Invalid frame marker / read uncompressed header failed`; VP8 died at
`mpp_buf_slot: Assertion src->ver_stride failed` with `size 0`. Copy the same bytes to `clip.ivf`
and both decode immediately. There is no input-container flag to find — `-f` is the _output_ frame
format — so the extension is the only lever, which is what made it look like a dead end.

| Format |          720p |         1080p |
| ------ | ------------: | ------------: |
| VP9    | **707.6** fps | **364.1** fps |
| VP8    | **183.5** fps |  **88.5** fps |

Faster than the R69's recorded 635 / 325 fps for VP9, on the same VPU.

Two lessons, both already cost time once:

- **A second box having a capability ✅ is a reason to keep digging, not to record 🟡.** The repo
  said VP9 worked on the R69 and MPP on _this_ box advertised `coding: VP9 id 10`; both pointed at
  my method rather than the hardware, and I wrote it up as unfillable anyway.
- **The R69's invocation was never written down** — only its fps. That is why this had to be
  rediscovered. `docs/mpp.md` now carries the extension trap explicitly, next to the MJPEG `-w`/`-h`
  one it sits beside in spirit.

Only AVS/AVS+ remain unfilled, and only because ffmpeg cannot encode them.

### 2026-09-06 (later) — the maskrom gate is passed, end to end

**The recovery button is reachable without opening the case** — there is a **tiny hole beside the
USB-C socket**. Every doc here said the button was PCB-only and needed disassembly; that was wrong,
and it changes maskrom from a workshop operation into something a user can do.

Holding it while applying power gives true **`Maskrom`**, not `Loader`, on **our** U-Boot:

```
DevNo=1  Vid=0x2207,Pid=0x350c,LocationID=101  Maskrom
```

That was the ⛔ blocking gate. `rd 3` from `Loader` is gone now ours serves no USB, and it turns out
not to matter — the button reaches `Maskrom` directly.

#### `wl` verified, which is the half that actually matters

Entry alone is not recovery. Full cycle at sector 28000000, a region read back as **64 MiB of
zeros** — no data, no ext4 backup superblock, nothing to lose:

| Step                              | Result                |
| --------------------------------- | --------------------- |
| `db` with our `LDR`-format loader | ✅                    |
| read 64 MiB (the restore copy)    | ✅ all zeros          |
| **`wl` write 64 MiB pattern**     | ✅                    |
| read back vs pattern              | ✅ **byte-identical** |
| **`wl` restore original**         | ✅                    |
| read back vs original             | ✅ **byte-identical** |

So `rl`, `wl` and the loader we ship are all proven together — none of it runs unless `db` accepts
our `boot_merger -r 6 -n` blob.

#### Single-pass reads still do not work, heatsink or not

The experiment was worth running and the answer is no. A single-pass 15.7 GB read died at **68% / 10
GB** with the heatsink fitted, averaging 14.2 MB/s and ending at 0.02 MB/s. Worse, the decay
**carries across transfers**: a 1 GiB read started immediately afterwards stalled at **60%** —
sooner, because the SoC was already hot. Chunked reads with real cooling pauses remain necessary; a
replug is not a cool-down.

#### Two mistakes worth recording

**I killed a stalled transfer and wedged the USB interface.** `docs/maskrom.md` warns that killing
`rkdeveloptool` wedges it, and says to let commands hit their own timeout — "a `timeout` around the
tool is fine, `kill -9` is not". I read that as licence to send SIGTERM. It ignored SIGTERM, the
interface wedged anyway, and the next `db` failed with `Downloading bootloader failed!` until a
physical replug. The instruction to follow was the first half: **wrap it in `timeout` from the
start**. The note now says SIGTERM is no safer than SIGKILL.

**I sized the test at 1 GiB because that is what was asked, without saying it was the wrong size.**
The goal was proving `wl` works, not measuring throughput — 64 MiB proves exactly the same thing in
seconds and never reaches the thermal decay. Two long transfers were burned finding that out.

#### One thing the partition table exposed

`backup/h96max-3518d/emmc-full.img` is the **factory Android** image — its GPT still shows
`security`/`uboot`/`super`/`userdata`. It is not a backup of the running Armbian system. A plan to
"restore the original bytes" from it would have written factory `userdata` into the live rootfs.
Caught before any write, while checking whether an ext4 backup superblock sat in the target range.
**There is still no backup of the current Armbian install.**

### 2026-09-06 (later) — the 4K/8K encode matrix, and H.264 confirmed fixed

The encode row had only been run at 720p/1080p here, while both sibling boards carry a full
720p/1080p/4K/8K table. Same gate, same commands, so the gap was mine and not the board's. All
twelve cells encode **and** decode back; `ffprobe` confirms the 4K/8K bitstreams are genuine
`3840x2160` / `7680x4320`, not downscaled.

| Format |  720p | 1080p |   4K |   8K |
| ------ | ----: | ----: | ---: | ---: |
| H.264  | 114.1 |  54.5 | 14.4 |  3.6 |
| HEVC   | 123.8 |  60.2 | 15.8 |  4.0 |
| MJPEG  | 297.1 | 157.1 | 45.0 | 11.7 |

SoC 38 °C after the run — no throttling. HEVC matches the R69 within noise; MJPEG is ~10% slower,
which is where the three boards already differed.

**H.264 encodes at every resolution the R69 recorded as broken.** That is not a difference between
the boards — it is the toolchain. `docs/mpp.md` had predicted it: older MPP never reads the H.264
status register back, so it sees "not done" and discards a frame the encoder did produce. Fixed in
`rockchip-linux/mpp` `905020444` (2026-08-10); we build `0986d01`, which is after it.

So the "H.264 encode is broken on `vepu540c`" line was never a silicon fact, and the two sibling
docs already carry the numbers plus the `needs MPP >= 905020444` condition. Nothing stale left to
correct — recorded here because the prediction and its confirmation landed a month apart and the
next person to hit an empty H.264 frame should check the MPP commit before the hardware.

### 2026-09-06 (later) — the GPU row closed without a TV, and two stale claims removed

HDMI was plugged into a monitor and **the console rendered** — the first picture this board has put
out. The cable came out again before anything could be captured, and the connector reads
`disconnected` between sittings, so EDID and the mode list still need the next one.

What the boot log holds regardless:
`dwhdmi-rockchip … Detected HDMI TX controller v2.11a with HDCP (inno_dw_hdmi_phy2)`, the VOP2
binding, `rc0` as `dw_hdmi`, an `hdmi_cec_key` input, and ALSA card 0 `rockchiphdmi` — **the only
playback device on the box**, since there is no analog jack. `cec-ctl` reads the adapter without a
link: CEC 2.0, `Transmit` + `Remote Control Support` + `Passthrough`, on DRM connector 369, physical
address `f.f.f.f`. That is enough to move CEC from ❓ to 🟡; the link itself is still untested.

#### GPU render does not need a display, and the packaged tools hide that

The validation checklist said `kmscube` / `glmark2-es2`, and both want a connected connector —
Debian 13 resolves `glmark2-es2` to the **X11** build. That had the whole GPU row parked behind a TV
for no reason.

EGL on the GBM platform with `EGL_KHR_surfaceless_context` renders to an FBO on the render node with
no display, no X and no Wayland. ~100 lines: open `/dev/dri/renderD129`, `gbm_create_device`,
`eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, …)`, context current against `EGL_NO_SURFACE`, draw a
viewport-covering triangle into an RGBA4 renderbuffer, `glReadPixels` the centre pixel. Green means
the GPU really rasterised it; the clear colour is red so a skipped draw is unmistakable.

| Fill              | 720p | 1080p |  4K |
| ----------------- | ---: | ----: | --: |
| full-screen (fps) |  598 |   272 |  70 |

~565 Mpix/s at every size, so it is fill-rate bound and the number is honest. SoC 37.7 °C after —
this barely warms the box. `Mali450`, `OpenGL ES 2.0 Mesa 25.0.7`, `glGetError` clean on both render
nodes (128 and 129 reach the same GPU).

**Two traps, both cost time.** `eglChooseConfig` fails outright if you ask for `EGL_PBUFFER_BIT`:
GBM exposes window configs, so pass no `EGL_SURFACE_TYPE` at all. And the box has no `pkg-config`
and **no sftp subsystem**, so `scp` fails with `subsystem request failed` — pipe the source into
`cat > file` over ssh and link `-lEGL -lGLESv2 -lgbm` by hand.

**The cap that matters more than the fps:** `GL_MAX_TEXTURE_SIZE`, `GL_MAX_RENDERBUFFER_SIZE` and
`GL_MAX_VIEWPORT_DIMS` are all **4096**. 4K fits; 8K does not. The VPU decodes 8K happily, and the
GPU cannot texture or composite it — worth knowing before promising 8K anywhere. GLES 2.0 only, no
GLES 3.

The test program was left out of the repo deliberately — it is throwaway, and
`docs/board-validation.md` now carries the approach and both traps, which is the part worth keeping.

#### Two claims in board.md were wrong

- **`wl` was still listed 🟡 "never attempted here"**, three lines under a blockquote saying `db`,
  `rl` and `wl` all work, and contradicting its own table row. Left over from before the maskrom
  session; now ✅.
- **The suspend row ended `(see the worklog).6 s on the second boot`** — a fragment of the boot-time
  row that an earlier edit had dragged along. Removed.

Both were found by reading the file rather than by any test, which is the argument for reading a doc
end to end after editing it in pieces.

#### And a row had gone missing from the README

Rebuilding the three README tables to add a third column dropped
**`USB bus power for a self-spinning drive`** (🟡 / 🟡) entirely. The check afterwards compared the
values of the rows that were present and reported "zero R69/H96 Max values changed", which was true
and useless — it could not see a row that was no longer there. `docs/board-validation.md` still
lists the check and `docs/r69/board.md` still cites it, so the README had quietly stopped covering
something two other boards are measured against. Restored.

**Comparing rows only catches edits; count them too, or diff the row labels as a set.**

Its 3518D cell was first written ❌ on the strength of the brownout, then corrected to ❓. The power
section rules ❌ out in its own table: _"the same adapter runs **indefinitely** if present at
boot"_. Hot-plug inrush and steady-state bus draw are different questions, and a drive plugged in
before power has never been tried here — so nothing predicted the answer.

**Then removed again, deliberately: spinning drives are not a use case for these boxes.** The row is
gone from the README, the criterion is gone from `docs/board-validation.md`, and the mention is gone
from `docs/r69/board.md`. **Do not restore it** — its absence is now a decision, not the accident
described above. The row-counting lesson still stands on its own.

### 2026-09-06 (later) — traced BT remote wake to two blockers, fixed one in the driver

Question was whether BT wake is possible at all. Traced the whole chain against the vendor kernel
source, the factory Android capture and the live box. It is possible on the host side — that part is
now armed — and the remaining unknown is controller firmware.

#### First, what the box's sleep states actually are

`rockchip-suspend` is not inert: the `rockchip-pm` driver is bound,
`CONFIG_ROCKCHIP_SUSPEND_MODE=y`, and it SMCs the config into ATF, which is the real Rockchip
`rk3528_bl31_v1.21.elf` from `rkbin` — so the vendor SIP interface is live, not a mainline stub.
Decoded against `include/dt-bindings/suspend/rockchip-rk3528.h`: `sleep-mode-config = 0x01` is
`RKPM_SLP_ARMPD` (only the ARM cores drop), and `wakeup-config = 0x11` is
`RKPM_CPU0_WKUP_EN | RKPM_GPIO_WKUP_EN`.

That `0x11` is the **stock `rk3528.dtsi` value** — Rockchip's own mangopi board copies it, and all
three of our boxes carry it byte for byte. It is not board tuning and never was. Because ARMPD keeps
the GIC alive, any `enable_irq_wake()` IRQ can resume the CPU, which is why IR wakes the other two
boards even though `RKPM_PWMIR_WKUP_EN` is not in the mask.

`virtual-poweroff = 1` registers a `SYS_OFF_MODE_POWER_OFF_PREPARE` handler, so `poweroff` never
cuts a rail — it preps regulators for `PM_SUSPEND_MEM`, drops the secondary CPUs and parks via ATF.
**"Off" is a suspend in costume**, which is the whole reason nothing brings the box back.

#### How Android does it, and why that does not help here

The factory capture caught `system_suspend` reading
`/sys/devices/platform/ffa90030.pwm/wakeup/wakeup1` — the PWM-IR block registered as a wakeup source
— and `ffa90030.pwm` appears in Android's input list with `Phys=gpio-keys/remotectl`. IR is the
designed wake path for this family. **No receiver is fitted on this board**, so Android's own remote
could switch this stick off and not on either. The hole is the vendor's, not ours.

#### I had the wake state wrong in two docs

`/sys/kernel/irq/*/wakeup` holds `enabled`/`disabled`, not `0`/`1`. A `grep -l 1` over it returned
nothing and I nearly wrote up "no IRQ is armed for wake". Three are: `debug` (72), `cec-wakeup`
(135), and `skw-gpio-irq` (11, `rockchip_gpio_irq`, edge) — the Seekwave host-wake GPIO. Its 74,876
interrupts are ordinary SDIO traffic, not wake events. So "no wake path" in the todo and "BT wake is
wired but unproven" in board.md were both wrong: the GPIO was armed the whole time.

Same class of mistake twice in one session — `power/wakeup` earlier, this now. **Check what a sysfs
file actually contains before matching on its value.**

#### Blocker 1: the BT driver never set `hdev->wakeup`

`hci_suspend_sync()` disconnects every link on the way down, then:

```c
	if (!hdev->wakeup || !hdev->wakeup(hdev)) {
		hdev->suspend_state = BT_SUSPEND_DISCONNECT;
		return 0;
	}
```

`skw_btdriver.c` sets `open`/`close`/`flush`/`send`/`setup` and nothing else, so that early return
was taken every time: no event filter, no accept list, and a remote that had just been disconnected.
`hci_register_dev()` also only advertises `HCI_CONN_FLAG_REMOTE_WAKEUP` when the callback exists, so
BlueZ could not offer `WakeAllowed` either.

Fixed in `patches/seekwave-swt6621s/0004`: the callback plus `device_init_wakeup()`, gated on
`device_may_wakeup()` of the parent so the sysfs toggle still works, version-gated to 5.16+. Built
and loaded by reloading `skwbt` alone — it is a separate module from `swt6621s_wifi` with refcount
0, so Wi-Fi and the ssh session survived. `power/wakeup` appeared and `btseekwave_wakeup` is in
`kallsyms`.

#### Blocker 2: an IRK with no LL Privacy strips the per-device flag

Kernel-side, not fixed by the patch. `hci_le_add_accept_list_sync()`:

```c
	/* During suspend, only wakeable devices can be in acceptlist */
	if (hdev->suspended && !(params->flags & HCI_CONN_FLAG_REMOTE_WAKEUP)) {
```

and `get_params_flags()` clears that flag when an IRK exists for the address and the controller
cannot resolve RPAs. This one cannot: `le_features[0] = 0xBF`, and `HCI_LE_LL_PRIVACY` is `0x40`. LE
bonding stored an IRK anyway, even though the remote's address is **public** (`AddressType=public`,
OUI `74:CC:23`) and it will never advertise an RPA.

Proved it by clearing IRKs at runtime over the mgmt socket: `supported` went `0x00000000` →
`0x00000001 REMOTE_WAKEUP`, and setting it gave `current 0x00000001`. BlueZ says the same thing from
its side — `device_set_wake_support() Unable to set wake_support without RPA resolution` — and will
never expose `WakeAllowed` on this controller because its gate is adapter-wide. The property is only
a convenience; the accept list tests the kernel flag, which mgmt can set directly.

**A second wrong check**: I first grepped BlueZ's store for the IRK as the unprivileged user, so the
`/var/lib/bluetooth/*/…` glob never expanded against a root-only directory and I reported "no IRK
stored". The kernel's own `identity_resolving_keys` debugfs had it. `sudo` the glob, not just the
command.

#### Where it stands

Host side is armed end to end. What no file can answer is whether the SWT6621S firmware keeps
passive scanning and pulls the host-wake GPIO while the host sleeps — that needs a suspend, and a
failed wake still means pulling power, because `dw_wdt_suspend()` gates the watchdog clock so it
cannot rescue the box. `bt-wake-test` on the box re-arms both flags, writes its evidence to `/root`
rather than the zram `/var/log`, and then suspends.

The runtime arming does **not** survive a reboot — bluetoothd reloads the IRK from its store. If the
test proves out, making it durable means dropping the IRK from that store and setting the mgmt flag
from a unit, which is a design decision worth taking deliberately.

### 2026-09-06 (later) — BT remote wake works ✅

Ran `bt-wake-test`. The box suspended, a keypress on the BLE remote brought it back.

```
==== 2026-09-06T21:38:19 attempt, uptime 4878s ====
-- device flags now:  supported: 0x00000001 REMOTE_WAKEUP  current: 0x00000001 REMOTE_WAKEUP
-- skw-gpio-irq count before: 136629
==== RESUMED at 2026-09-06T21:38:33, uptime 4893s ====
-- skw-gpio-irq count after:  137058
-- suspend_stats: success=1 fail=0
```

`boot_id` unchanged and uptime continuous, so it resumed rather than rebooted.

#### Ruling out the obvious false positive

`skw-gpio-irq` is shared between Wi-Fi and BT, so +429 interrupts across the cycle proves only that
_something_ on that pin fired. The dmesg ordering settles which:

```
[4894.213719] PM: suspend exit
[4896.683675] input: Bluetooth remote Keyboard ... BLUETOOTH HID v0.00     resume +2.5 s
[4897.912319] wlan0 STA -> 74:90:bc:12:33:91, state: NONE -> AUTHING       resume +3.7 s
```

Wi-Fi came back **from `NONE`** — the link was fully torn down through the suspend and re-associated
afterwards, so it was not holding a connection that could have woken anything. The remote's HID
reappeared a second earlier. `cec-wakeup` had 0 interrupts and no TV was attached; the serial IRQ
had nothing plugged into it. BT is the only live thing on that pin, so it is the waker.

Worth writing down because the shared IRQ makes this exactly the kind of result that looks proven
and is not. The ordering is the evidence, not the interrupt count.

#### What this changes

The board had **no wake path at all** — no RTC, no IR receiver — and three docs said so. It now has
one, and it is the only one. The two fixes were the driver's missing `hdev->wakeup` (patch `0004`)
and the IRK that made the kernel strip `REMOTE_WAKEUP`.

#### Not finished: it does not survive a reboot

Only the driver patch is persistent. bluetoothd reloads the IRK from `/var/lib/bluetooth` on every
start, and the mgmt flag is runtime state. A shipped fix needs a unit — BlueZ will not set the flag
itself, because its `WakeAllowed` gate wants adapter-wide RPA resolution this radio cannot do. Left
undone deliberately: dropping the `[IdentityResolvingKey]` stanza edits stored pairing state, and
`0004` already reaches the H313 as well, so both are decisions rather than mechanics.

### 2026-09-06 (later) — BT wake and sleep turn out to be the same switch

Long session, several wrong turns, one genuinely useful discovery that had nothing to do with
Bluetooth. Corrects the earlier "BT remote wake works ✅" entry above.

#### The headline

`0004` (adding `hdev->wakeup`) does make the remote wake the box — `pm_wakeup_irq = 66`, repeatably.
It also **stops the box staying asleep**: ~6–9 s, confirmed by a control run with nobody touching
the remote. These are not two problems. `hci_suspend_sync()` programs the LE accept list _only_ when
the driver supplies `hdev->wakeup`; that accept list is what allows a wake, and the remote's own
reconnect attempt then trips it.

So the stock behaviour — sleeps forever, nothing can wake it — and the patched behaviour — wakes
fine, will not stay down — are the two sides of one switch. The user pointed this out ("suspend
worked before fixes") and it fits the code path exactly; I had been treating them as independent
bugs for most of the session.

#### The discovery that was not Bluetooth

`xhci-hcd` cannot suspend:

```
xhci-hcd xhci-hcd.4.auto: WARN: xHC CMD_RUN timeout
xhci-hcd xhci-hcd.4.auto: PM: dpm_run_callback(): platform_pm_suspend returns -110
PM: Some devices failed to suspend, or early wake event detected
```

`last_failed_dev = xhci-hcd.4.auto`, errno -110; unbinding xhci lets the suspend complete. This
aborts suspends on its own, and **a resume with an empty `pm_wakeup_irq` is this abort, not a wake**
— from outside they look identical, and I spent several runs attributing aborts to BT.

Prime suspect is our own USB3 graft (`dwc3` at `high-speed`, `combphy@ffdc0000` disabled): an xHCI
without its PHY fails exactly like this. Not chased further tonight; it is the first thing to settle
before more suspend work, and it is a real regression if confirmed.

#### Things I measured wrong, and how

- **"The chip is never quiet, ~7 interrupts/s at idle."** Wrong. That was my own ssh session over
  Wi-Fi. With `wlan0` down the SDIO line is **0/s**, link connected or not, and no wakeup source is
  held. I built a whole argument about an inherently chatty chip on my own traffic.
- **Polling the box while testing suspend.** An ssh probe every 3 s is a wake source in its own
  right, since no WoWLAN filter is programmed. Later runs went silent for the whole window instead.
- **`hcitool lescan` is broken here** (`Set scan parameters failed: Input/output error`), so a
  3-minute advertising study returned all zeros and I nearly read that as "the remote never
  advertises". `bluetoothctl scan le` works — it saw 55 devices.
- **`btmgmt` with `</dev/null` silently does nothing.** I "hardened" a script that way and it
  quietly stopped clearing IRKs and setting flags, which then looked like the kernel refusing.
- **Blamed Wi-Fi for a wake that happened with `wlan0` down.** The remote had just been disconnected
  and was re-advertising; a 12 s scan that missed its burst was not evidence of silence.

#### Things tried and reverted

- **`HCI_QUIRK_NO_SUSPEND_NOTIFIER`** (the commented-out line in the driver). Keeps the link up, so
  no reconnect — but then the driver's own polling wakes the box, and one run aborted at freeze in
  0.24 s. Reverted; the box is back to `0004` only.
- **WoWLAN magic-packet.** `iw phy0 wowlan enable magic-packet` is accepted and the firmware ignores
  it. The driver computes the flags and there is a real `skw_suspend()` path, but the vendor's
  `SKW_MIB_SET_SUSPEND_MODE` is behind `CONFIG_SWT6621S_PRESUSPEND_SUPPORT`, undefined in our build.
  Reverted, along with an `rk35xx-wake-sources` unit that should not have been written before the
  hardware question was settled.

#### Where it stands

`0004` stays — it is correct, and it is the only thing that makes a wake path possible at all. But
it is not a win on its own, and the README/board.md claims from earlier in the session have been
corrected from ✅ back to ❌: the box cannot currently both sleep and be woken. The most promising
route is quieting the chip across suspend the way the factory Android did, via the presuspend path.

#### Later the same night — the waker is the controller's own scanning, and it is tunable

`btmon` left running across a suspend settled it: the box woke with `pm_wakeup_irq = 66` and **zero
HCI traffic** at or after the suspend entry. No advertising report, no connection complete, nothing.
So the wake was never a Bluetooth event — it is the controller's passive scanning, which `0004`
switches on for the duration of the suspend by arming the accept list.

The scan parameters are runtime-tunable through mgmt system config, no patch:

| interval / window                               | Stays asleep | Wakes on the remote |
| ----------------------------------------------- | :----------: | :-----------------: |
| `0x0400` / `0x0012` (640 ms / 11.25 ms) default |   ❌ ~5 s    |         ✅          |
| `0x4000` / `0x0004` (10.24 s / 2.5 ms)          | ✅ 2.5 min+  |         ❌          |

First time the box has ever held a suspend — 2.5 minutes untouched, where every previous attempt
died in under 11 s. But at that duty cycle it never hears the remote either, so the box had to be
power-cycled. Both ends of the trade are now measured, which turns this from "suspend is broken"
into a bounded search for the middle.

#### And the LEDs go dark while suspended, which they should not

Both `leds` nodes carry `retain-state-suspended` and the sleep hook sets red-on/blue-off in `pre`,
yet every LED was off during that 2.5-minute suspend. Driving them by hand while awake works
(`power=0 standby=1` lights red, confirmed by eye), so the pin is fine and the sleep state is
dropping it. **A suspended box is visually identical to a powered-off one**, which is worth knowing
before anyone debugs a "dead" box that is merely asleep.

#### And the fault that was ours all along: the USB 3 graft broke suspend

`xhci-hcd` failing `platform_pm_suspend` with -110 turned out to be a regression we introduced.
Evidence, once it was looked for: the R69 and H96 Max H313 both keep `combphy` `okay` and both
suspend; the 3518D was the only board disabling it and the only one that could not suspend. The
factory tree had it `okay` too.

The mechanism is the same fact we had already written down and then failed to apply — `xhci`
advertises SuperSpeed from its own capability register, which no device-tree property retracts. So
`maximum-speed = "high-speed"` plus a disabled `combphy` does not remove the SuperSpeed half, it
leaves it present and unclocked, and it never halts on suspend.

Reverted: `combphy` back to `okay`, `combphy_pu` back in dwc3's `phys`, `maximum-speed` dropped, the
reasoning kept as comments. Patch regenerated against a fresh factory decompile (17 hunks, unchanged
count), rebuilt via `upstream/build.sh` which re-verified the native tree is content-identical,
deployed with the previous `board.dtb` kept at `/root/board.dtb.known-good`, rebooted. USB 3.0 root
hub back on bus 002, zero xhci errors, and a suspend now goes down and **stays** down.

**The trade was bad and should not be repeated.** The graft bought one fewer PHY probe — about a
second of boot — and cost suspend on the only board with no other way to be woken.

**The diagnostic lesson:** an aborted suspend and an instant wake are indistinguishable from
outside; both come back in under a second. `pm_wakeup_irq` empty means abort, a number means a real
wake, and `last_failed_dev` names the culprit. Checking that first would have saved most of a night.

### 2026-09-07 — the suspend handshake was losing a race, and `0005` fixes it

Continues the previous entry. With xhci no longer aborting suspends, the picture finally separated
into three distinct faults instead of one confusing one.

#### Reading the driver instead of guessing

Asked to prove the cause from source before trying anything, which was the right call — my first
hypothesis (no `gpio_chip_wake` in the DT, so the handshake is skipped) was **wrong**: the board
declares `gpio_chip_wake = <gpio1 12>` and the factory tree always did.

The real cause is one line up. `send_host_suspend_indication()` drives `gpio_out` low and waits for
the chip to ack, but only inside `if (gpio_get_value(gpio_in) == 0)`. `gpio_in` is `WL_WAKE_HOST`,
the chip's "I have traffic" line, and the suspend path generates traffic of its own — the Bluetooth
disconnect the core performs, anything still in flight. So the single sample lost a race it should
usually win:

- 200 samples at 100 ms while idle: **hi=23, lo=177** — low 88% of the time
- the driver's own log at all five of our suspends: `gpio_in num 107 the value 1` — high every time

Losing it skipped the handshake, so the chip was never told the host had gone down and kept
asserting the line until the wake-enabled IRQ resumed the box. That also explains the `btmon`
capture with **zero HCI events** across a wake: nothing had happened at the Bluetooth layer at all.

`0005` waits for the line, bounded at 200 ms, and sets `suspend_wake_unlock_enable` in
`skw_sdio_suspend()` — only `skw_sdio_irq_ops(1)` set it before, and the suspend path never reaches
that, so every GPIO IRQ taken while suspended was grabbing a wakelock.

#### It works, and the proof is a log line that never existed before

```
[131.46] send_host_suspend_indication: cp sts:0 in 20 ms
```

That prints from inside the previously-unreachable block. With it: **29 s asleep with Wi-Fi up**,
woken by a keypress, `fail=0`. Before it, the same configuration died in 3.4 s.

#### What is left, stated honestly

With a remote **connected** at suspend it still wakes in 2–3.4 s, and the handshake log line shows
the transport is now doing its job — so this is fault 3, the BT layer, not the SDIO one. Retested on
top of `0005` and still failing: report-only (`connected after: 0`, so the reconnect really is
blocked, yet the accept-listed device still wakes us on its advert), disconnect-immediately-before,
and `NO_SUSPEND_NOTIFIER`.

#### Two experiments wasted, and a rule that came out of it

The advertising-burst duration is the one number that would decide whether a short pre-suspend wait
is viable, and two attempts to measure it produced nothing: the first because report-only had left
the remote already disconnected so there was no burst to observe, the second because `bluetoothctl`
hangs without a tty under `systemd-run` — the identical trap `btmgmt` set earlier, which was already
written down and walked into anyway.

The user's instruction, recorded: **fail fast, hard-cap every run, quote the worst case not the
best.** A 90 s capture and a 5 min sampler were both too long; a 75 s settle was rejected outright
as unshippable for a TV box. Bounds on the burst from suspend timings alone: starts within ~2 s of
the disconnect, over by 29 s.

### 2026-09-07 — 4K HDMI fixed with one byte: `esmart_lb_mode`

First session with a real 4K TV attached. Symptom: at 4K the right of the screen was filler, the
console on the left; 1080p perfect. Reported on the other boards too, on an external monitor.

#### What it was not — every one of these looked plausible

- **Mode selection / EDID.** EDID reads fine (256 B, LG TV, 40 modes). Forcing `3840x2160@60` gave
  the correct mode and still failed.
- **Framebuffer or plane geometry.** At 4K: `fb0 3840,2160`, `stride 15360`, console `480x135` =
  3840 px, plane `Esmart0-win0` at `crtc-pos=3840x2160+0+0`. All correct.
- **Pixel clock.** `set dclk_vop0 to 594000000, get 594000000`.
- **Our DTS graft.** `hdmi`, `vop`, `dmc`, `hdmiphy` are byte-identical to the factory tree.
- **Android's DTBO.** Contains only `reboot_mode`.
- **Bandwidth, DMC, TMDS rate, the HDMI PHY.** Killed by one measurement: **4K30 at 297 MHz — half
  the pixel clock — failed exactly like 4K60.** A fault that ignores refresh rate is a _width_
  limit, not a bandwidth one. That single test invalidated several hours of theorising about
  `failed to get vop bandwidth to dmc rate` and vendor-U-Boot QoS.

#### The cause

`esmart_lb_mode = [03]` on the VOP node = `VOP3_ESMART_2K_2K_2K_2K_MODE`: every Esmart window gets a
2K line buffer. `Esmart0-win0` is the primary plane for vp0, so at 3840 wide it fetched ~2048 pixels
per line and the rest of each line was whatever was in the buffer. `[02]` =
`VOP3_ESMART_4K_2K_2K_MODE` gives Esmart0 a 4K buffer. Boots natively at `3840x2160p60`.

All three boards shipped the same factory `03`, so all three carry the graft now.

The mechanism is documented upstream (Rockchip's shared line-buffer mode) but no published fix for
rk3528 TV boxes exists — plausible, since the fault only shows above ~2048 px and the other rk3528
Armbian projects report HDMI working without stating a resolution.

#### glmark2 was lying, and cost an hour

On-screen GPU testing looked broken: black screen while glmark2 reported 15–32 fps. I twice
explained this away as "expected for a Mali-450 at 4K" — wrong, and the user rightly pushed back
that a slow GPU renders slowly rather than showing black. The real cause: **glmark2-es2-drm does not
honour the connector's `preferred` mode** and selected `4096x2160` (DCI 4K) over `3840x2160`, which
the panel cannot display. Confirmed in its source (`src/native-state-drm.cpp`): it keeps whichever
mode has the greatest `hdisplay * vdisplay` and never looks at `DRM_MODE_TYPE_PREFERRED`, so DCI 4K
wins by 6% on area. It cannot be steered either — the only winsys option is `drm-device=`, and
`--size` sets the render surface, not the scanout mode. `kmscube` honours `preferred` and renders a
clean spinning cube at `3840x2160p60`. That is why the R69 and H96 Max scored glmark2 41 happily —
their displays offer no DCI mode.

#### Closed with the TV attached

HDMI picture ✅ · EDID and mode list ✅ · HDMI audio ✅ (music through `plughw:0,0`, heard) ·
HDMI-CEC ✅ (phys addr 3.0.0.0, claimed LA 8, transmitted to the TV) · on-screen GPU ✅ (kmscube at
4K) · **HDMI 4K60 ✅**.

#### Lessons worth keeping

- **Change one variable and measure.** The 4K30-vs-4K60 test took two minutes and eliminated four
  hypotheses at once. It should have been the first thing tried, not the twentieth.
- **Do not explain a symptom away.** "Expected for this GPU" was an inference presented as a fact,
  twice, and both times it was wrong.
- **Modes are runtime-switchable** (`modetest -M rockchip -s <conn>:<WxH>-<hz>`). Rebooting to
  change a mode wasted a lot of the user's time. Keep the tool's stdin open or it exits instantly.

### 2026-09-07 (later) — the five dead remote buttons have scancodes after all

The five `KEY_UNKNOWN` buttons were recorded as "dead until remapped, scancodes not captured". They
are not dead: `evtest` shows every one of them emitting an `MSC_SCAN` immediately before the key
event, so the raw HID usage does reach userspace and `hwdb` can rename it.

| Scancode                        | HID page       | Was           | Button                  |
| ------------------------------- | -------------- | ------------- | ----------------------- |
| `c0011`                         | consumer 0x011 | `KEY_UNKNOWN` | hamburger               |
| `c0056` `c003b` `c003d` `c003e` | consumer       | `KEY_UNKNOWN` | the four app shortcuts  |
| `700aa`                         | keyboard 0x0aa | `KEY_UNKNOWN` | fires with voice search |
| `c0040`                         | consumer 0x040 | `KEY_MENU`    | backspace               |

All six unmapped usages sit in ranges the HID spec marks reserved, which is exactly why `hid-input`
has nothing to map them to. `700aa` is not a button at all — the voice key sends it _alongside_
`c0221` (AC Search), so every press produced a `KEY_SEARCH` plus a stray `KEY_UNKNOWN`.

**Backspace was reaching userspace as `KEY_MENU`.** The handset sends consumer usage 0x040 (`Menu`)
for it, and `hid-input` translates that faithfully — the whole nav cluster is built on the consumer
Menu usages, D-pad included (`c0042`-`c0045`). That explains the keycode; it does not excuse it. A
button printed ⌫ has to be `KEY_BACKSPACE`, so the keymap renames it. Tracing the usage back through
the HID spec was time spent justifying the wrong keycode instead of fixing it.

Shipped as `firmware/common/rk35xx-bt-remote.hwdb`, family-wide next to the existing
`rk35xx-input-names.rules` — matching on `evdev:input:b0005v2B54p1600*` means a board without this
handset simply never matches.

**The targets came from the R69, not from taste.** The same physical handset drives the R69 over IR,
and that board's IR table — vendor scancodes, already documented — maps hamburger to `KEY_MENU` and
the ⌫ key to `KEY_BACKSPACE`. So the BLE remap is just making one remote behave the same on either
transport, which is a far better argument than picking `KEY_CONTEXT_MENU` because it sounded right
(my first draft did exactly that). The IR table also names the four app shortcuts `KEY_F6` `KEY_F7`
`KEY_F3` `KEY_F8`; they ship as `KEY_PROG1`…`KEY_PROG4` only because the capture did not record
which printed button produced which scancode.

Two things about this image that cost time:

- **There is no `60-keyboard.rules`.** systemd merged it into `60-evdev.rules` years ago; that file
  does the `hwdb --lookup-prefix=evdev:` import and the `IMPORT{builtin}="keyboard"`.
- **`/etc/udev/hwdb.bin` does not exist** on a fresh image — Debian ships only
  `/usr/lib/udev/hwdb.bin`, and `systemd-hwdb-update.service` has `ConditionNeedsUpdate=/etc`, which
  did not fire. Dropping a file into `hwdb.d/` therefore does nothing at all until something runs
  `systemd-hwdb update`. Added to `rk35xx-firstboot` and to `rk35xx-update`.

Verified so far: the file compiles under `--strict`, and
`systemd-hwdb query "evdev:input:b0005v2B54p1600e0000-…"` returns all seven properties. Not yet
verified: the keycodes coming off the handset, because the remote went to sleep and stopped
advertising before the check. `bluetoothctl connect` cannot raise it — a BLE peripheral that is not
advertising cannot be reached, so this one needs a finger on a button.

Also worth recording: **`scp` to this box fails** with `Connection closed` while `ssh` works — no
sftp-server on the image. `ssh host 'cat > /path' < file` is the way to move a file onto it.

### 2026-09-07 (later) — the keymap is remote data, and a silent zero-byte deploy

Two corrections to the entry above.

**Placement.** I first shipped the keymap in `firmware/common/`, then talked myself into moving it
to `firmware/h96max-3518d/` on the grounds that a family-wide copy would make one button produce
different keys over IR and over BLE. That was wrong on both counts. The match key
`evdev:input:b0005v2B54p1600*` carries bus, vendor and product — **model** fields from the handset's
PnP record (`Source=2`, USB-IF; `Vendor=11092` = `0x2B54`, `Product=5632` = `0x1600`). The Bluetooth
address `74:CC:23:DE:9D:33` appears nowhere in a modalias. So the entry identifies the remote, not
the box, and the same handset pairs to any of the three. And the claimed transport conflict does not
exist: against the R69's IR table, hamburger `KEY_MENU` and ⌫ `KEY_BACKSPACE` agree exactly. The one
divergence is the four app shortcuts, `KEY_PROG1`…`4` here versus `KEY_F6` `KEY_F7` `KEY_F3`
`KEY_F8` there — my placeholder, not a property of the transport. It stays in `firmware/common/`.

Caveat worth keeping: `0x2B54` is not in the shipped USB vendor table, so it is an OEM-picked id
that an unrelated remote could in principle reuse. The failure mode is a wrong keymap, not a crash.

**The deploy was empty and nothing said so.** `/etc/udev/hwdb.d/60-rk35xx-bt-remote.hwdb` was **0
bytes** on the box, while `systemd-hwdb query` still returned all seven properties. Both facts were
true: an earlier `ssh box 'cat > /tmp/f' < file` had dropped — this box has closed connections
repeatedly today — and the already-compiled `hwdb.bin` went on answering from the previous good
build. The mapping would have vanished at the next `systemd-hwdb update`, on first boot or from
`rk35xx-update`, long after anyone connected it to this session.

Redeployed with `sudo tee` straight from stdin, no `/tmp` hop, and confirmed by md5 on both ends
(`6cd45ff0ea03fcba72934d2391116d6f`) before recompiling. **Checksum every push to this box.** A
passing `systemd-hwdb query` proves the compiled database, not the file it was built from.

Validation gained a per-transport keymap section as a result, and the procedure moved out to
`docs/remote-keymap.md` — IR and BLE are separate keymaps and each needs its own pass.

### 2026-09-07 (later) — three more keycodes were wrong, and the IR tables disagree

Reviewing the keymap against the printed buttons rather than against what the hardware emitted found
three more faults, all of which I had written up as quirks instead of fixing:

| Button      | Scancode | Was          | Now             | Why the old one was wrong                     |
| ----------- | -------- | ------------ | --------------- | --------------------------------------------- |
| Cog         | `c008f`  | `KEY_GAMES`  | `KEY_SETUP`     | consumer `Media Select Games`; button is ⚙    |
| OK (centre) | `c0041`  | `KEY_SELECT` | `KEY_OK`        | the button is printed OK, and `KEY_OK` exists |
| ⌫           | `c0040`  | `KEY_MENU`   | `KEY_BACKSPACE` | consumer `Menu`; button is ⌫                  |

Nine overrides now. **`KEY_SETTINGS` does not exist** — the kernel offers `KEY_SETUP` (141),
`KEY_CONFIG` (171), `KEY_OPTION` (0x165) and `KEY_CONTEXT_MENU` (0x1b6). Check the name against
`/usr/include/linux/input-event-codes.h` before shipping it; `systemd-hwdb update --strict` is the
backstop but the header is the list.

P +/- needed no change: the handset sends consumer `0x09C`/`0x09D`, _Channel Increment/Decrement_,
and the printed P is Programme. `KEY_CHANNELUP`/`KEY_CHANNELDOWN` is already right.

**The IR tables are the bigger problem.** Comparing the three boards' maps for the same handset,
three buttons get three different keycodes: cog is `KEY_SETUP` on the R69 but `KEY_F13` on the H96
Max; OK is `KEY_ENTER` then `KEY_REPLY`; the app shortcuts are `F6 F7 F3 F8` on one and
`F6 F7 F8 F9` on the other. `KEY_PAGEUP` for a channel rocker and `KEY_HOME` (start of line) for the
TV home key are both wrong on the IR side. So "make BLE match the IR table" is not a usable rule —
the IR tables need their own pass. Written up as `docs/todo/rk35xx-remote-keymaps.md`; deferred
because both those boards work today and only the 3518D was blocked.

### 2026-09-07 (later) — video plays on screen with hardware decode; the copy is the ceiling

The "never exercised" playback row is closed. A YouTube clip decodes on the VPU and reaches the
panel. Full recipe and numbers in `docs/mpp.md`.

**Debian cannot do this out of the box, and the reason is structural.** There is no `/dev/video*`:
the vendor kernel builds `CONFIG_ROCKCHIP_MPP_SERVICE` and `CONFIG_ROCKCHIP_MPP_RKVDEC2`, not
`CONFIG_VIDEO_ROCKCHIP_RKVDEC`, so the decoder speaks the MPP ABI and no V4L2 M2M node exists for
`h264_v4l2m2m` to bind to. Not an RK3518 gap — a deliberate vendor-kernel choice. (MPP also prints
the SoC as `rk3528a` while refusing to create a VP8 encoder for it.) Software decode is not a
fallback worth having: 14 fps for 1080p60 H.264, 6 fps for 4K60 VP9.

`jellyfin-ffmpeg7` solves it in one command — **but take the `trixie` build**. Measured:

| Clip          | Software | HW decode | Decoded + displayed | CPU |
| ------------- | -------- | --------- | ------------------- | --- |
| 1080p60 H.264 | 14 fps   | 157 fps   | ~35 fps             |     |
| 4K60 VP9      | 13 fps   | 44 fps    | 24 fps              | 43% |
| 4K60 HEVC     | —        | 51 fps    | 27 fps              | 48% |

Decode has headroom; `fbdev` does not. Every displayed frame is a 13.6 MB copy into the framebuffer,
which halves the rate and accounts for nearly all the CPU. The 4K HEVC clip was made on the box by
hardware-transcoding the 4K VP9 download with `hevc_rkmpp`.

#### Four traps, each of which produced a confident wrong conclusion

- **The bookworm deb on trixie never starts** (`libvpx.so.7`, `libx265.so.199`). Extracted with
  `dpkg-deb -x` rather than installed, it loads Debian's system `libavcodec` and lists no rkmpp
  decoders. I reported "this build has no rkmpp" twice on that evidence. `ldd | grep "not found"`
  before believing a capability is absent.
- **`sudo` strips `LD_LIBRARY_PATH`.** Every `sudo -E mpv` silently ran software decode while the
  identical command without `sudo` saw the rkmpp decoders. That one cost an hour of comparing
  configurations that differed only in privilege.
- **`mpv --vo=drm` stranded the display.** It exited logging `Failed to restore previous mode` and
  left CRTC 89 with `fb 0` — mode set, nothing scanning out. Writes to `/dev/fb0` then vanished with
  no error from anything. `chvt` and rebinding `vtcon1` did not recover it; a reboot did. The tell
  is `modetest -M rockchip -p` showing `fb 0` on a live CRTC.
- **`modetest` takes DRM master.** Using it to check whether `kmssink` had committed a plane may
  have been disturbing the commit. A human looking at the screen settled in one message what six
  probes could not.

#### GStreamer: decodes, will not display

Built `mppvideodec` from `nyanmisaka/rk-mirrors -b gstreamer-rockchip` (the `JeffyCN` URL is gone —
git prompting for a username is what a 404 looks like). Compiles clean against GStreamer 1.26
despite declaring 1.14, and decoding is confirmed. `kmssink` selects overlay plane 122 on CRTC 89
and then never commits a framebuffer to it: no errors, 4% CPU, console still on screen. Root,
`dma-feature=1`, DMABuf caps, `zpos`, and unbinding `vtcon1` all changed nothing;
`force-modesetting=true` fails to preroll. fbcon holding primary plane 57 all session is the
suspect, and taking fbcon off the display at boot is the untried lever. Recorded in `docs/mpp.md`
rather than as a todo: hardware decode is the board's job and it is proven, so which player reaches
the panel is a userspace choice, not bring-up.

### 2026-09-07 (later) — the keymap is board data after all, and the reasoning that got there was wrong

Earlier today I argued the remote keymap belonged in `firmware/common/`, shipped to all three
boards, because `evdev:input:b0005v2B54p1600*` names a **model** and a board without that handset
never matches. Every board's worklog does record its bundled remote as `2b54:1600`, each measured on
that board, so the match claim was true.

The claim that did not follow is the one that mattered: **the entry matches on the model id but
remaps by scancode.** A shared USB id is not a shared button layout — OEMs reuse ids freely, and
`0x2B54` is not even in the USB vendor table. The map was built from this stick's handset alone. On
the R69 or the H96 Max box it would have applied silently and could have mis-keyed every button,
with nothing in any log to say so.

Moved to `firmware/h96max-3518d/bt-remote.hwdb` and dropped from the other two payload lists. The
`systemd-hwdb update` call in `rk35xx-firstboot` and `rk35xx-update` stays family-level but is now
guarded on `/etc/udev/hwdb.d` being non-empty, so a board shipping no keymap does not build a 13 MB
database for nothing. Both sibling `board.md` files now say the remap exists and is **deliberately
not installed**, with the scancode capture as the precondition.

The general rule, now in `docs/remote-keymap.md`: ship the file from the board directory whose
handset you actually captured, and add a board only after capturing its remote too.

### 2026-09-07 (later) — traced fault 3 through the kernel: the BT stack is not the wake source

Read end to end against `../armbian-rk35xx/kernel` (6.1) and the box's runtime state. The conclusion
overturns where every previous attempt was aimed.

1. `hci_suspend_sync()` (`net/bluetooth/hci_sync.c`) calls `hci_disconnect_all_sync()` **whenever
   `hci_conn_count(hdev) > 0`, before the `hdev->wakeup` check**. A connected remote is always torn
   down on the way into suspend. Nothing about `0004` changes that ordering.
2. It then tries to arm the LE accept list. `hci_le_add_accept_list_sync()` refuses this device:

   ```c
   /* Accept list can not be used with RPAs */
   if (!use_ll_privacy(hdev) &&
       hci_find_irk_by_addr(hdev, &params->addr, params->addr_type))
           return -EINVAL;
   ```

   Both conditions hold here. `use_ll_privacy()` is
   `ll_privacy_capable() && hci_dev_test_flag(HCI_ENABLE_LL_PRIVACY)`, and that second flag is an
   experimental mgmt feature, off by default — the controller _is_ capable (`le_features[0] = 0xbf`,
   bit 6 set), the kernel just is not using it. And an IRK **is** loaded:
   `/sys/kernel/debug/bluetooth/hci0/identity_resolving_keys` shows
   `74:cc:23:de:9d:33 (type 0) aa2cf0d1…`, despite the remote using a **public** address.

3. So `le_accept_list` in debugfs is **empty**. In `hci_passive_scan_sync()` that means
   `hdev->suspended && !filter_policy` with `list_empty(&hdev->le_accept_list)` → `return 0`. **No
   LE scan runs during suspend at all.**
4. Therefore the accept list, the forced `filter_policy = 0x01`, the suspend scan interval and
   `HCI_CONN_FLAG_REMOTE_WAKEUP` are all irrelevant on this box — none of them is in the path. The
   nights spent on scan duty cycle and accept-list membership were spent on a layer that never runs.
5. What is left is the **Seekwave host-wake GPIO**: `irq 66 skw-gpio-irq` is wake-armed, and
   `btseekwave.8.auto` has `power/wakeup: enabled` because `0004` calls `device_init_wakeup()`. The
   chip raises that line whenever it has traffic for the host, and a just-disconnected remote
   hammering reconnects is traffic.

**No Bluetooth kernel parameter can fix this**, because the Bluetooth stack is not participating.
The fix has to stop the traffic being generated, or filter it below the stack.

Two mistakes worth recording, both repeats:

- **`irq 66` is the combo chip's shared line.** I sampled it to time the remote's reconnect burst
  and read a steady 4-16 irq/s for 40 s — that was my own ssh over `wlan0`. The same trap is already
  in this worklog from the earlier session. On a board whose only link is Wi-Fi, that counter cannot
  measure Bluetooth.
- **I suspended the box over ssh to capture an HCI trace, and it did not come back.**
  `docs/board-validation.md` says plainly "Never suspend a box remotely — it is stranded until
  someone presses the remote", and this file already says to retry that test with serial attached.
  Recovery was a power cut, which again destroyed the zram journal that would have explained it.

  **Do not read this as fault 3 changing.** The earlier runs woke — 29 s idle-disconnected, 2-3.4 s
  connected — and this one did not wake at all, but it is not the same box any more. Installed today
  before that suspend: `mpv`, `yt-dlp`, `jellyfin-ffmpeg7`, six gstreamer packages,
  `librockchip_mpp` and `librga` into `/usr/local`, the `gstreamer-rockchip` plugin, and a 13.5 MB
  `/etc/udev/hwdb.bin`. Also run: a series of DRM clients, one of which had already stranded the
  display once, and one of which was found still holding `/dev/dri/card0` after exiting. `btmon` was
  running and writing a btsnoop file across the suspend itself. Two suspects stand out — a **filled
  zram `/var/log`**, which this file already records as a plausible contributor to an earlier stuck
  transition, and a **leftover DRM or HCI holder**. Check both before trusting any new suspend
  timing from this box.

Next step is the delayed-suspend workaround rather than more stack archaeology: on the way down,
disconnect the remote and drop it from auto-connect so the host does not immediately re-establish,
hold with the red LED lit while its reconnect burst expires, then suspend. The settle time is not
yet measured — `irq 66` cannot measure it, and it needs serial, not ssh.

### 2026-09-07 (later) — the reconnect burst is 6 seconds, measured without suspending anything

The number that three previous attempts failed to get. No suspend involved, so no risk of stranding
the box: set `Trusted=false` on the remote so BlueZ would not auto-reconnect, `StartDiscovery` on
the adapter, `Disconnect` the device over D-Bus, then run `btmon` for 70 s and pull out every
timestamp where its address appears.

**Four sightings: t+3.3 s and t+5.9 s. Then nothing for the remaining 64 s.**

So the remote hunts for about six seconds after an unexpected disconnect and then sleeps until a key
is pressed. That is consistent with everything already measured — the 2-3.4 s wake from suspend is
the first of those adverts arriving, and the 29 s hold with an idle remote is the same handset after
the burst has expired. The old bound in the todo ("over by 29 s, certainly by 75 s") was far too
loose, and the fear that a settle wait would have to be tens of seconds was unfounded.

`SETTLE` therefore ships at **10 s** in `firmware/h96max-3518d/suspend-default`. The hook is still
unproven end to end — nothing has actually suspended through it, and that test needs serial.

Two things this cost, both worth remembering:

- **`Trusted=false` makes the remote look dead.** BlueZ will not auto-reconnect an untrusted device,
  so button presses do nothing and `/dev/input/bt-remote` never appears. I left it false between
  attempts and spent a round wondering why "the remote is connected" and the box disagreed. The
  measurement now runs under a shell trap that restores it on any exit.
- **`/dev/input/bt-remote` is not a connection state.** It is a udev symlink that only exists while
  the HID child device is up. Ask BlueZ (`busctl get-property … Connected`) when the question is
  whether the link exists.

Also recovered from this boot: `/var/lib/systemd/pstore/console-ramoops-0` survived, but it is from
the earlier _reboot_ (uptime 4151 s, ending `reboot: Restarting system`), not from the stranding —
that ended in a power cut, and DRAM does not survive one. It is still useful evidence for the
poweroff question: the tail shows `self skw chip power reset !!` / `seekwave power down !!`, so the
Seekwave driver takes the chip down in the `.shutdown()` path that `poweroff` shares.

### 2026-09-07 (later) — the ramoops file is not a crash, but the line inside it matters

Checked properly rather than assumed. `/var/lib/systemd/pstore/` holds one `console-ramoops-0` and
**no `dmesg-ramoops-*` at all** — a panic or oops produces the latter, and there has never been one
on this box. `console-ramoops` is the console backend, which ramoops records continuously by design,
so a file appearing after a warm reboot is normal operation. Its last line is
`reboot: Restarting system`: an orderly shutdown.

What is worth attention is two lines above it:

```
watchdog: watchdog0: watchdog did not stop!
```

`docs/watchdog.md` already describes that signature, but recorded it as observed only on a sibling
RK3518-class box, with 🟢 "not been observed on either box here". It has now been seen **here**,
from an ordinary `systemctl reboot` after a long session — same position, immediately before the
restart. This box came back normally, so the carry-over reset still has not been reproduced on our
hardware, but the precursor is no longer hypothetical on this family. Updated that doc to 🟡.

The two `SKWIFI6621S` lines above it (`skw_cmd_allowed: iface NULL`,
`skw_mgmt_frame_register: del ACTION failed, ret: -5`) are teardown noise on the shutdown path — the
driver being asked to deregister a management frame after the interface is already gone. Cosmetic,
and a candidate for `0003` if it ever needs extending.

### 2026-09-07 (later) — fault 3 fixed in the driver: `0006`, one line the vendor had commented out

The box now suspends and stays asleep with the remote connected, and a keypress wakes it. Three
cycles, `pm_wakeup_irq = 66`, `success 3 / fail 0`.

**The evidence that it is really fixed** is not the wake, it is the HID node count: created **once
for the whole boot** instead of once per suspend cycle. Before `0006` every cycle produced a fresh
`uhid` device (`.000B`, `.000C`, `.000D`, `.000E`) because the kernel tore the link down and it was
rebuilt on resume. Now the link simply survives.

`0006` sets `HCI_QUIRK_NO_SUSPEND_NOTIFIER`. `hci_register_suspend_notifier()` checks it and
registers no PM notifier, so `hci_suspend_sync()` — and with it the unconditional
`hci_disconnect_all_sync()` that sits before the `hdev->wakeup` check — never runs. No disconnect,
no reconnect hunt, nothing for the chip to report on its host-wake GPIO. **The line was already in
the vendor tree, commented out.**

#### Why it took so long, honestly

The whole session attacked the wrong layer. Fault 3 was chased through the LE accept list, the
suspend scan duty cycle, `HCI_CONN_FLAG_REMOTE_WAKEUP`, an IRK strip shipped as a
`bluetooth.service` drop-in, and a resume-time re-suspend absorber. The kernel trace that finally
settled it showed `le_accept_list` empty and `hci_passive_scan_sync()` taking its early return, so
**no LE scan ran during suspend at all** — the Bluetooth stack was never the waker, and every lever
pulled against it was pulling on nothing.

The absorber deserves a note: it worked. The journal shows it catching wake after wake and putting
the box back down. It was still the wrong answer, because it treated a symptom and the wake train
outlasted any sane retry budget.

Two rules out of it:

- **Check whether a layer is executing before tuning it.** One `modetest`-style look at
  `le_accept_list` would have redirected the whole effort on day one.
- **A DKMS driver is shippable here; a kernel patch is not.** `patches/linux-rockchip/README.md`
  says as much, and it makes the driver the _first_ place to look for a fix on this family, not the
  last. The user pointed this out; it should have been obvious from the repo's own layout.

Removed as redundant: `rk35xx-bt-wake` and its drop-in, `rk35xx-resuspend`, `rk35xx-remote-settle`,
`/etc/default/rk35xx-suspend`. With no suspend notifier the accept list is never consulted, so the
IRK does not matter and there is no spurious wake to absorb.

### 2026-09-07 (later) — the ✅ on suspend was premature; a fourth waker

Correcting the entry above. `0006` is right and stays, but "the box stays asleep" was called on
three cycles with a human pressing the remote each time. Left alone it wakes in **6-60 s**.

Ruled out, with evidence rather than reasoning:

- **Not the remote.** `0006` keeps the link — the HID node is created once per boot, not once per
  cycle — so there is no reconnect hunt left to wake anything.
- **Not Wi-Fi.** Suspended with `wlan0 down`: it slept **6.1 s** and still woke on irq 66. Faster,
  not slower, which also kills the theory that beacons were involved.
- **Not a timer.** No RTC, `/sys/class/rtc/rtc0/wakealarm` absent, no `WakeSystem=true` unit
  anywhere. Nothing in systemd can schedule a wake on this box.

What is left is on every single cycle, at suspend entry:

```
[SKWSDIO INFO] skw_sdio_suspend_adma_cmd: timeout gpioin value=1
```

The box goes down with the chip's host-wake GPIO **already asserted**. `0005` waits 200 ms for
`gpio_in` to fall and always times out, so the wake is armed before the system is even suspended.
Resumes are preceded by `skw_sdio2_adma_parser: ch:2 len:17`.

This is precisely what the earlier `NO_SUSPEND_NOTIFIER` attempt hit — "the driver's own polling
wakes the box" — and it was never the reconnect hunt's fault. `0006` removed the hunt and left this
exposed. Sleep went from 2-3 s to 6-60 s, which is progress, not a fix.

The lesson, again and more expensively: **three cycles with a human in the loop is not a control
run.** The measurement that mattered took one command — suspend and leave it alone — and it was not
done before the ✅ went into four documents.

### 2026-09-07 (later) — fault 3 traced to `ADV_DIRECT_IND`, fixed as an opt-in quirk

The box now sleeps for minutes and the remote wakes it. Getting there took three reversals, all of
them mine, and the wrong turns are worth more than the answer.

#### What actually wakes it, in order of discovery

`btmon` across a suspend, with kernel dynamic debug on (309 bluetooth debug points), finally showed
the mechanism:

```
< Disconnect                     2.998
< Set Event Mask                 3.003   restricted, "only the allowed event can wakeup the host"
< LE Set Extended Scan Enable    3.009
@ Controller Suspended           3.011
> LE Extended Advertising Report 6.923   <- the wake
      Legacy PDU Type: ADV_DIRECT_IND (0x0015), Connectable, Directed
      Address: 74:CC:23:DE:9D:33
```

`hci_suspend_sync()` drops every link, and this remote answers ~3 s later with **directed
advertising** to reconnect. Waking on an accept-listed device's advert _is_ the upstream design —
and it cannot be filtered, because a bonded remote sends the same PDU when a key is pressed. The
assumption behind that design, that a HID peripheral disconnected by the host goes quiet, holds for
the mice and keyboards it was written against and not for this handset.

#### The reversals

1. **Shipped `0006` (`HCI_QUIRK_NO_SUSPEND_NOTIFIER`) and called suspend ✅** off three cycles with
   a human pressing the remote each time. It was not fixed — left alone it woke every ~27 s.
2. **Reverted `0006` entirely** after reading how mainstream solves this (ChromeOS-driven:
   disconnect, accept list, sparse suspend scan). The research was right about the design and wrong
   for this board: reverting made it **10× worse**, 2.8 s.
3. **Reinstated it**, this time understanding why. Keeping the link removes the hunt but starts LE
   Ping, so the controller raises Authenticated Payload Timeout Expired every 30 s and this chip
   pulls host-wake to deliver it. `auth_payload_timeout = 0xffff` moves that to 655 s.

#### Shape of the fix

`0002`-`0005` are bug fixes and stay unconditional. `0006` changes core suspend behaviour for every
user of the driver, so it is a **quirk with module parameters, both defaulting off**:

```
options skwbt keep_link_suspended=1 auth_payload_timeout=65535
```

The board opts in through `/etc/modprobe.d/zz-rk35xx-skwbt.conf`; anyone else gets stock behaviour,
and `skwbt.keep_link_suspended=0` overrides on the kernel command line.

#### Hypotheses killed with evidence, so nobody re-walks them

- **`skw_sdio_suspend_adma_cmd: timeout gpioin value=1` means nothing.** It is an unconditional
  `skw_sdio_info()` after `skw_sdio_adma_write()`; "timeout" is in the format string, not in any
  logic. A whole "the handshake fails every cycle" diagnosis was built on that word.
- **Not Wi-Fi (at the time).** A/B of five suspends each way: medians 27.2 s up, 27.3 s down.
- **Not a timer.** No RTC, no `wakealarm`, no `WakeSystem=true` unit.
- **Not the supervision timeout.** The kernel default is a brutal 420 ms
  (`hdev->le_supv_timeout = 0x002a`), which looked like an obvious cause for the
  first-suspend-after-connect failing. It is never used here: BlueZ pre-loads the remote's stored
  parameters, and the link comes up at 11.25 ms interval, latency 69, **timeout 3000 ms**.
- **`CONFIG_SWT6621S_PRESUSPEND_SUPPORT` is Wi-Fi only** — one `#ifdef` in `skw_core.c` setting a
  Wi-Fi MIB. It cannot explain BT wake behaviour.

#### Measurement discipline, learned expensively

- **`ssh` unreachable is not "asleep".** I reported "still asleep after 246 s" from a poller that
  could not connect; the box was awake with its LED on. Only on-box evidence counts.
- **`/tmp` is tmpfs.** A power cut wiped the log I was going to read, and I took the empty file as
  "it never woke". Suspend evidence goes in `/root`.
- **Three cycles with a human in the loop is not a control run.**

#### Still open

The residual waker is unidentified. With the link kept and the ping at 655 s, a cycle still ended at
45.6 s with **zero HID re-creations** — the link survived, so nothing on the BT side disconnected.
Wake was `pm_wakeup_irq = 66`, the GPIO shared with Wi-Fi.

**Correction (2026-09-07): "so it is not Bluetooth" does not follow, and is withdrawn.** irq 66 is
how the BT controller reaches the host too, and an ordinary HCI event needs no disconnect and
re-creates no HID node. It would look exactly like this.

Read against `net/bluetooth/hci_sync.c` rather than from memory, the event masks say this:

- `hci_set_event_mask_sync()` is called **inside** `if (hci_conn_count(hdev))`, so the quirk skips
  it — but it barely narrows anything. Suspended, it clears exactly two bits: Disconnect Complete
  and mode change, "as that would wakeup the host when disconnecting due to suspend". Everything
  else — LE Meta-Event, Encryption Change, Number of Completed Packets — stays enabled either way.
  An earlier note here claiming the quirk leaves the mask wide open _relative to normal suspend_
  overstated it: the gap is two bits, not a floodgate.
- **Event mask page 2 is never touched by the suspend path at all** — `HCI_INIT` sets it once at
  controller init and nothing revisits it. The Authenticated Payload Timeout Expired bit lives there
  (`events[2] |= 0x80`, enabled whenever `lmp_ping_capable() || le_features[0] & HCI_LE_PING`).

That second point is the useful one. **Masking the APTO event beats `auth_payload_timeout=65535`**:
the timeout approach still expires, so it merely moves the ceiling to 655 s, while clearing the bit
means the controller never raises the event and the ceiling goes away. Testable with no rebuild —
`hcitool cmd 0x03 0x63 00 00 00 00 00 00 00 00` writes page 2 all-zero.

Remaining quirk-on wake candidates, to be settled by the `btmon` capture rather than argued:
Disconnect Complete (enabled only because the suspend mask never ran), LE Meta-Event, and the APTO
event above. The earlier Wi-Fi A/B was run while the 27 s ping still dominated, so it proved nothing
about this state and is being redone.

### 2026-09-07 — the dark-LED "fact" was wrong, and it mis-framed the stranding

Owner observation, against two of my write-ups: _"the board never dark on suspend, systemd has a
rule to make it red, it never has both leds off, one of them is on always, during initial boot both
leds on, so both off is surprising state"_.

Checked against the hooks, and it holds — every state this software can produce lights exactly one
LED:

| State                | blue (`power`) | red (`standby`) | Set by                               |
| -------------------- | :------------: | :-------------: | ------------------------------------ |
| Running              |       on       |       off       | `rk35xx-led-sleep post`, DT default  |
| Suspended            |      off       |       on        | `rk35xx-led-sleep pre`               |
| Powered off / halted |      off       |       on        | `rk35xx-led-shutdown`                |
| Early boot           |       on       |       on        | nothing yet — both pins default high |

So the 2026-09-06 entry above — "every LED was off during that 2.5-minute suspend",
`retain-state-suspended` not honoured — is **withdrawn**. Red does hold through `deep`.

#### What that costs the stranding analysis

I had argued: blue never came back, therefore the resume hook never ran, therefore the box entered
suspend and nothing could wake it. **Both halves are invalid.** Blue-off is not evidence of no
resume when red is also off, because no state has both off. Red was lit first, so `pre` did run —
the box then stopped driving the pins altogether.

That is a hang, not a sound sleep. Which also discards the accept-list explanation: an empty accept
list makes a box unwakeable, and an unwakeable box sits there with red on. It does not go dark.

**Cause unknown.** `0006` stays default-off, now for an honest reason: it correlates with a hang
that costs a power cut, not with a suspend that sleeps too well.

#### The lesson, since this is the third one of these

A wrong observation in a doc is worse than no observation. This one sat in `board.md` for a day and
was then _cited as evidence_ in two later analyses, which is how a single bad note becomes three
wrong conclusions. Physical-state claims need a second look before they are written as fact — and
the owner watching the box beats a log I inferred it from.

### 2026-09-07 — >25 min asleep with the quirk, and a doubt about `auth_payload_timeout`

Run: `rmmod skwbt; modprobe skwbt keep_link_suspended=1 auth_payload_timeout=65535`, remote
reconnected and re-trusted, `btmon -w` capturing, then `systemctl suspend`. Script and evidence in
`/root/susp/evwake/` on the box.

**Result: no self-wake. 712 s (11.9 min) under continuous polling**, every probe failing, in a
window that opened _after_ the owner confirmed a **red LED** — so asleep, not hung, and the first
quirk-on run that did not end in a hang. It was asleep for some minutes before that window and
stayed unreachable after it, so the total is larger; 712 s is what was actually observed, and the
larger figure quoted first was my own arithmetic over `sleep` calls, which is not evidence. Shipped
default for comparison: the owner watched it bounce in **3 s**.

#### The number that does not fit

`auth_payload_timeout=65535` is 655 s, or 10.9 min. The box went well past that without waking. If
Authenticated Payload Timeout Expired were being raised, the sleep should have ended there. Two
readings, and the evidence so far does not separate them:

1. The chip never raises the event, and whatever capped the earlier ~27 s runs was something else.
2. The event is real at the 30 s default and the parameter genuinely defers it — but then something
   else should have fired at 655 s, and nothing did.

Either way, **`auth_payload_timeout` is not carrying its weight as documented**, and the fix for it
is probably the wrong shape. Reading `net/bluetooth/hci_sync.c`: the APTO Expired bit lives in event
mask **page 2** (`hci_set_event_mask_page_2_sync`, `events[2] |= 0x80`), page 2 is set once from the
`HCI_INIT` list, and **no suspend path revisits it**. Clearing the bit stops the event being raised
at all, where a longer timeout only defers it. Staged as `/root/susp/aptomask.sh`: quirk on, APTO
left at the kernel default, page 2 zeroed with `hcitool cmd 0x03 0x63 00 00 00 00 00 00 00 00`. If
that sleeps long, `0006` drops a module parameter.

#### Not yet known

Nobody pressed the remote before the box was left sleeping, so **the wake path is unverified for
this run**. A box that sleeps 25 minutes and cannot be woken is worse than one that bounces every 3
s, and the 235 s run is the only evidence the wake works with the quirk on. That press is the next
thing to do.

The box is sleeping in a **hand-loaded** quirk-on configuration — `zz-rk35xx-skwbt.conf` still has
its `options` line commented out, so a power cut or reboot returns it to the safe default.

### 2026-09-07 (later) — it woke on the keypress: 1773 s asleep, link intact

The press that the previous entry was waiting for. Owner: _"board woke up after remote press"_.

| Measure                           | Value                                              |
| --------------------------------- | -------------------------------------------------- |
| Kernel `PM: suspend entry`→`exit` | 1290.343 → 3063.664 = **1773 s (29.6 min)**        |
| Wall clock                        | 21:51:12 → 22:20:47 = 1775 s (independent, agrees) |
| `pm_wakeup_irq`                   | 66                                                 |
| Remote after resume               | `Connected: yes`, `Trusted: yes`                   |
| Connection handle                 | 18, unchanged across the suspend                   |

**The `btmon` trace is the whole argument.** GATT discovery finishes at t = 0.88 s; then the link
carries **nothing whatsoever for 1775 s**; then at t = 1776.036 an `ATT: Handle Value Notification`
on handle 0x002b with data `4100`, followed 83 ms later by `0000`. That is the HID input report and
its release — consumer usage 0x41, which our hwdb maps to `KEY_OK`.

So the wake was **the keypress itself, as ACL data on a link that never dropped**. Not a reconnect
advert (fault 3's mechanism), not an HCI event. This is what the whole exercise was for.

#### Fault 4 now looks misdiagnosed

`auth_payload_timeout=65535` is 655 s. The link was silent for 1775 s and **no Authenticated Payload
Timeout Expired event ever appears in the trace**. Had the timer been running and expiring, the box
would have woken at 10.9 min. Two consequences:

- The parameter is probably inert on this controller, and `0006` may reduce to one knob.
- Whatever capped the earlier ~27 s runs **was not LE Ping**, so that diagnosis needs redoing. The
  ~27 s ≈ 30 s coincidence with the APTO default is what sold it, and a coincidence is all it may
  be.

Next test is therefore the single-variable one — `keep_link_suspended=1` **alone**, nothing else
changed from this run. If it sleeps long, delete `auth_payload_timeout`. Only if it does _not_ is
the page-2 event mask worth reaching for.

#### Also seen, unexplained

`xhci-hcd xhci-hcd.4.auto: xHC error in resume, USBSTS 0x401, Reinit` on the way back up. Self
recovered. Noted because fault 1 was also xhci, and a resume-path USB error on a board whose USB3
graft once broke suspend outright deserves a second look rather than a shrug.

#### Standing

Two quirk-on runs in a row now with no hang, against the single hang on 2026-09-07 earlier. That is
not yet a rate. `0006` stays default-off until it is one.

### 2026-09-07 (later still) — `0006` enabled by default on this board, box resynced

The A/B settled the design, so the board now opts in. `firmware/h96max-3518d/skwbt-options.conf`
carries a live `options` line instead of a commented-out one:

```
options skwbt keep_link_suspended=1 auth_payload_timeout=65535
```

Both values, because the single-variable run proved the timeout is worth 63× (28.3 s without it,
1773 s with). The module parameters still default off, so only this board inherits the behaviour,
and `skwbt.keep_link_suspended=0` on the kernel command line backs it out without editing files.

**Enabled despite the unexplained hang.** One occurrence, not reproduced in the two runs since. The
trade is a rare hang costing a power cut against a box that certainly cannot stay asleep past 3 s.

#### Resync: the box had drifted three files behind the repo

Checksummed all 36 `payload.list` entries against the box. Three differed, all cases of the repo
being ahead — changes made this session that were never deployed:

| File                         | Difference                                                 |
| ---------------------------- | ---------------------------------------------------------- |
| `rk35xx-firstboot`           | guarded `systemd-hwdb update` (udev reads only `hwdb.bin`) |
| `rk35xx-update`              | the same guarded rebuild                                   |
| `powerkey.conf` (this board) | `HandlePowerKeyLongPress` poweroff → **suspend**           |

That last one is the one that mattered: with no IR and no RTC, poweroff is one-way — BLE cannot wake
a box whose controller is down — so a long press was reachable to a state only unplugging recovers.

All three installed and verified by md5 both ends. **36 of 36 payload files now identical**, module
parameters picked up from `modprobe.d` rather than hand-passed, logind reloaded, remote still paired
and trusted.

### 2026-09-08 — the "unreliable" suspend was three different wakers, all now named

`btmon` running across natural use finally caught the wakes. The variability was never random.

**Waker 1 — reconnect advert (~3 s).** Quirk off. `hci_suspend_sync()` disconnects, handset answers
with `ADV_DIRECT_IND`, accept-listed, wakes the host. Fixed by `keep_link_suspended`.

**Waker 2 — Authenticated Payload Timeout, and the timer is exact.** Trace packet:

```
> HCI Event: Authenticated Payload Time.. (0x57) plen 2  [hci0] 1547.880459
        Handle: 18
```

The cycle it ended measured **655.58 s**; `auth_payload_timeout=65535` × 10 ms = **655.35 s**. And
the preceding keypress notification sits at t = 892.47, so the event fired **655.41 s after the last
authenticated payload**. So:

> APTO expires 655 s after the last authenticated payload, and **every keypress refreshes it**.

That is the whole explanation for "wakes on its own after a long wait". It also corrects an earlier
entry here: I wrote that at 0xffff the event "never fires". It fires exactly on schedule — I had
only seen sleeps that ended some other way first, and generalised from that.

Since 0xffff is the spec maximum, the ceiling cannot be raised further. It can only be **removed**,
by masking the event: page 2 carries the bit, `HCI_INIT` sets it once, no suspend path revisits it.
`hcitool cmd 0x03 0x63 00 00 00 00 00 00 00 00`. ❓ Still unverified — the one run that looked
promising (45 min unreachable) ended in a reboot before anyone confirmed asleep-vs-hung.

**Waker 3 — the power key's own release, and this one is caused by the fix.** On a fresh boot, three
suspends lasted 0.5 s, 0.5 s, 8.5 s, and `systemd-logind` logged `Power key pressed short` **four
times**, one of them 0.6 ms after `Suspending console(s)`.

The remote's power button sends a press report and a release report ~106 ms apart (every keypress in
the traces is a `3000`/`0000` pair at that spacing). The press makes logind suspend; because
`keep_link_suspended` holds the link up, **the release is delivered over the live link and wakes the
box straight back**. Without the quirk the link is torn down and the release never lands.

So suspending via the BLE power button is self-defeating in this configuration, and
`HandlePowerKeyLongPress=suspend` has the same exposure. The fix belongs at the input layer, not in
the driver. ❓ Not yet confirmed by trace — needs one power-button suspend captured.

#### Method note

Three separate wakes lost their evidence because `btmon` was started by hand and died at each
reboot. It is now `bt-trace.service` on the box — **a temporary diagnostic, not repo payload, to be
removed**. "Restart the capture manually" is not a method; it silently loses exactly the events you
are trying to catch.

### 2026-09-08 (later) — page-2 mask verified, and waker 4 is Disconnect Complete

Durable capture (`bt-trace.service`, `/var/log/bt-trace/`) plus a `BT_TRACE_ANCHOR` kmsg stamp to
map btmon's relative clock onto dmesg monotonic. That mapping is what made this readable: btmon
`t=0` at dmesg 835.76, so `dmesg = btmon + 835.76`.

#### The page-2 APTO mask works

`hcitool cmd 0x03 0x63 00 00 00 00 00 00 00 00` applied at dmesg 5317.5, then:

| Cycle                       | Duration     |
| --------------------------- | ------------ |
| before the mask, every time | **655 s**    |
| 5337.87 → 8936.27           | **3598.4 s** |

✅ Clearing the Authenticated Payload Timeout Expired bit removes the 655 s ceiling. Since 0xffff is
the spec maximum, masking is the only way past it — `auth_payload_timeout` can only defer.

#### Waker 4: the remote's idle disconnect

What ended the 3598 s sleep, from the trace:

```
> ACL Data RX  #269 [hci0] 4502.938783   ATT: Handle Value Notification  Data[2]: 3000
> ACL Data RX  #270 [hci0] 4503.062547   ATT: Handle Value Notification  Data[2]: 0000
                          ... 3598 s of complete silence ...
> HCI Event: Disconnect Complete (0x05)  #271 [hci0] 8101.337223
        Status: Success (0x00)
        Handle: 18 Address: 74:CC:23:DE:9D:33
        Reason: Connection Timeout (0x08)
```

The remote holds the connection through roughly an hour of inactivity, then stops answering; the
link supervision expires and **the Disconnect Complete event pulls host-wake**. The last traffic
before the gap is the power-key press/release at suspend entry — waker 3 again, in the same trace.

**This is the gap dismissed on 2026-09-07.** That entry read `hci_set_event_mask_sync()`, correctly
found that suspending clears exactly two bits — Disconnect Complete and mode change — and concluded
"the gap is two bits, not a floodgate." Two bits, and one of them is this waker. Upstream states the
reason outright: _"Don't set Disconnect Complete when suspended as that would wakeup the host when
disconnecting due to suspend."_ `HCI_QUIRK_NO_SUSPEND_NOTIFIER` skips that call, so the bit stays
set. The size of a gap says nothing about whether it matters.

#### Four wakers, three understood

| #   | Waker               | Ends sleep at | Status                                |
| --- | ------------------- | ------------- | ------------------------------------- |
| 1   | Reconnect advert    | ~3 s          | fixed by `keep_link_suspended`        |
| 2   | APTO expiry         | 655 s         | ✅ fixed by the page-2 mask, verified |
| 3   | Power-key release   | ~0.5 s        | open — input layer, not the driver    |
| 4   | Disconnect Complete | ~3598 s       | mask staged, untested                 |

Waker 3 is worth restating because it is self-inflicted: the remote's power button sends press then
release ~106 ms apart, the press makes logind suspend, and because the quirk holds the link open the
**release is delivered over the live link and wakes the box immediately**. Suspending from that
button cannot work in this configuration. `HandlePowerKeyLongPress=suspend` has the same exposure.

#### Staged, with a risk worth stating first

`/root/mask-both.sh` applies page 1 `ef ff f3 ff 00 00 00 20` (Disconnect Complete cleared, LE
Meta-Event kept) plus the page-2 clear. Three possible outcomes, and only one is good:

- sleeps long, wakes on a keypress — all four handled;
- sleeps ~1 h then wakes anyway — the reconnect advert gets through, and masking merely hid the
  notification rather than keeping the link alive;
- sleeps and **cannot** be woken — the link is gone and nothing re-establishes it while suspended.
  Same failure shape as the 2026-09-07 stranding, and it costs a power cut.

Masking an event stops the host being told. It does not keep the link up. That distinction decides
which of the three happens, and it is not yet known.

#### Tooling left on the box, to be removed

`bt-trace.service` (+ `/var/log/bt-trace/`), `/root/mask-apto.sh`, `/root/mask-both.sh`. Temporary
diagnostics, not repo payload. Three earlier wakes lost their evidence to a hand-started `btmon`
dying at reboot; a capture that needs remembering is a capture that misses the event.

### 2026-09-09 — masking Disconnect Complete shipped a box that would not wake

Deployed `0006` with both event masks. Result, from the owner: _"sleeps well doesn't wake up, your
last 'fix' for disconnected event ignore likely broke all"_. Correct diagnosis.

**What the trace shows.** The post-deployment boot captured 209 packets across 19.59 h, and the
whole of it is one gap: the controller initialises in the first second — accept list programmed,
passive scan enabled — and then **nothing at all until btmon was restarted 19.6 h later**. No
advertising reports, no connection attempts, awake or asleep. The remote never reached the
controller once. Recovery was a power cut.

#### Why it shipped

The page-2 APTO mask was verified: 3598 s, woken normally. The page-1 Disconnect Complete mask was
verified only as a **manual `hcitool` command applied once while awake and left in place** — one
run, 4422 s, woken by a keypress. In the driver it is applied at `PM_SUSPEND_PREPARE` and restored
at `PM_POST_SUSPEND`. Those are not the same thing, and I shipped them as though they were, bundling
one verified change with one unverified change in a single deployment.

Masking an event stops the host being told about it. It does not keep the wake path alive. The
difference is invisible when the mask is set by hand well before suspend and only appears once the
suspend path itself applies it.

**Reverted.** `0006` now carries the page-2 mask only — the configuration that was actually
measured. Cost: the remote drops its link after ~1 h idle and the resulting event wakes the box,
which then re-suspends. Hourly wake, but wakeable.

#### And I destroyed the evidence for it

`bt-trace.service` ran `btmon -w` without redirecting stdout, and `btmon -w` decodes to stdout as
well as writing the file. The journal filled to 19.2M of its 20M cap and rotated, taking every
`PM: suspend` record from the post-deployment boot with it. The btsnoop survived and carried the
finding above, but the kernel-side record of that failure is gone. Unit fixed with `> /dev/null`.

Two lessons, both cheap to state and expensive to learn: a diagnostic that overwrites the log it is
meant to inform is worse than no diagnostic, and a manual reproduction is evidence about the manual
sequence, not about the code that will replace it.

### 2026-09-09 (later) — the ~1 h wake is the remote's own firmware, and why masking bricked the box

#### Supervision timeout raised, and it changed the mechanism without changing the outcome

The remote's stored connection parameters are aggressive and **persisted by BlueZ**, so every link
starts with them:

```
[ConnectionParameters]  MinInterval=6  MaxInterval=9  Latency=69  Timeout=300
```

Timeout 300 = 3000 ms against a latency of 69 at 11.25 ms — the remote may skip 69 events (788 ms),
so the link tolerates only ~3.8 missed windows. The kernel accepts this: `hci_check_conn_params()`
allows latency up to `(to_multiplier * 4 / max) - 1` = 132, and the spec minimum (1575 ms) is met.
Kernel defaults would be **worse** (`le_supv_timeout = 0x002a`, 420 ms), so clearing the store is
not the answer.

Raised to `Timeout=3200` (32 s) in `/var/lib/bluetooth/<adapter>/<dev>/info`. ✅ It applies — the
trace shows `LE Extended Create Connection … Supervision timeout: 3200` and
`LE Enhanced Connection Complete … 32000 msec` on connections BlueZ makes itself, so it is
persistent, not a one-shot. (An earlier note here saying the edit "did not take" was read off a
connection established before the edit, and is withdrawn.)

❌ **It did not fix the hourly wake.** Slept 3649.7 s, against 3598.3 s with the old 3 s timeout.

But the disconnect reason changed, and that is the finding:

| Supervision timeout | Slept    | Disconnect reason                |
| ------------------- | -------- | -------------------------------- |
| 3000 ms             | 3598.3 s | `Connection Timeout (0x08)`      |
| 32000 ms            | 3649.7 s | `LMP/LL Response Timeout (0x22)` |

A 10× longer supervision timeout only moved the failure to the **fixed 40 s LL response timeout**.
The remote is not being lost to RF margin; after roughly an hour idle it **stops answering
link-layer procedures altogether**. That is handset firmware and no host-side parameter reaches it.
The earlier "scattered timings therefore interference" argument used runs contaminated by the page-1
mask; the two clean numbers are 3598 s and 3650 s, both ≈ 60 min, which is a timer, not noise.

#### Why masking Disconnect Complete produced an unwakeable box

The trace answers it in three adjacent packets:

```
> HCI Event: Disconnect Complete            #1959
< HCI Command: LE Set Extended Scan Params  #1960   Filter policy: Ignore not in accept list
< HCI Command: LE Set Extended Scan Enable  #1962   Extended scan: Enabled
```

**The host re-enables accept-list passive scanning as a direct consequence of the disconnect
event.** While a link is up there is nothing to scan for, so scanning is off. Mask the event and the
host never learns the link died, never re-enables the scan, and every later advertisement from the
remote goes unheard — exactly the 19.6 h capture with zero packets. Masking one half of a two-part
sequence is what shipped the fault, not the masking itself.

So the fix, if the hardware allows it, is to mask the event **and pre-enable accept-list passive
scanning before suspending** — which is what `hci_update_passive_scan_sync()` does in the suspend
path that `HCI_QUIRK_NO_SUSPEND_NOTIFIER` skips. ❓ Untested, and gated on one unknown: whether this
controller can run a passive scan concurrently with an active link. If it cannot, the design is
impossible here and the hourly wake stays.

#### Ruled out: the driver did not break reception

A worry carried for most of the session. An unfiltered `bluetoothctl scan le` found **12 BLE devices
in 15 s**, so the radio and the new driver receive normally. When the remote shows `Connected: no`
for hours it is because the handset is not advertising, nothing else.

### 2026-09-11 — suspend declared unsupported, power key disabled

Finalising the board at a defined readiness level rather than leaving a half-working feature armed.

- `powerkey.conf`: `HandlePowerKey` and `HandlePowerKeyLongPress` both **`ignore`**. Not remapped —
  there is nothing safe to remap to. Poweroff is one-way here (no RTC, no IR, BLE cannot wake a
  powered-down controller) and suspend is the broken thing.
- `skwbt-options.conf`: quirk **disabled**. It worked (3598 s), but one run with it active ended in
  a hang and an unsupported feature should not carry that risk.
- `board.md`: suspend marked ❌ with the two unfixed faults stated plainly.
- `research/seekwave-bt-wake/` holds the full analysis: seven faults, five fixed, two not, plus the
  rejected approaches, what mainstream does, and everything parked with it. Indexed in AGENTS.md as
  `research/<experiment>/`, alongside `seekwave-tx-latch-bug`.

The two unfixed faults are the power-key release arriving after the suspend, and the remote going
silent after ~1 h. Neither is a hard dead end; both need work that was not worth continuing now.

### 2026-09-11 (later) — patches without a consumer parked, and a distinction I had wrong

`research/seekwave-bt-wake/` now holds `0004` and `0006`. `fetch-seekwave-src.sh` globs `*.patch` in
the parent directory only, so a subdirectory is excluded from every build with no code change.
Verified both ways against the pinned source: the shipped three apply cleanly alone, and the parked
pair still applies on top in numeric order.

Shipped: `0002` and `0003`, both Wi-Fi fixes with upstream PRs.

`0005` moved twice. I parked it on the wrong reasoning ("no board validates suspend" — suspend has
always worked; it is BT _wake_ that never did), restored it, then parked it again on the right one:
it was written to stop the chip spuriously waking the box during BT-wake testing. It is a sound fix
for a measured race and would stand upstream unchanged, but nothing ships a configuration that needs
it, and `experimental/` means no consumer rather than no confidence.

That conflation had also reached `board.md`, `powerkey.conf` and the research doc, all of which said
"suspend does not work". Corrected everywhere to **suspend ✅, BT remote wake ❌**. The power key is
still disabled, but for the accurate reason: the box suspends fine and may then have no way back,
because BT is its only wake path.

**Correction:** the analysis was first written to `docs/research/`, a directory invented for it, and
the patches to `patches/seekwave-swt6621s/experimental/`. The repo already had a top-level
`research/<experiment>/` convention — `seekwave-tx-latch-bug` has used it since August. Both
duplicates removed; everything now lives in `research/seekwave-bt-wake/` with the analysis merged
into its `README.md`, matching the existing layout.

### 2026-09-12 — loaders pack natively, and the stall is not thermal

**`rkdeveloptool pack` can build the loader after all.** It only ever emitted old-IDB `BOOT` with
RC4 on because `#define TAG 0x544F4F42` and `hdr->rc4Flag = 1` are hardcoded and the config parser
rejects `[SYSTEM]`/`[FLAG]` outright — the very sections Rockchip's `RKBOOT/RK3528MINIALL.ini` uses
to ask for new-IDB with RC4 off. `patches/rkdeveloptool/0001` teaches it those sections, so
`build-rktools.sh` now packs from Rockchip's own ini and the rkbin `boot_merger` detour is gone,
along with its Linux x86-64 requirement. The patch also fixes an out-of-bounds write: `parseLoader`
indexed `gOpts.loader[]` with the number in `LOADER<n>=` while `[CODE471_OPTION]` decrements it, so
the 1-based keys in Rockchip's own file wrote one past a two-element array.

Verified on this box, loader packed on macOS arm64: `db` succeeded, `rfi` reported 30777344 sectors,
`rl 64 1024` came back byte-identical to `firmware/h96max-3518d/factory_idbloader.bin`. The
`UsbHead`/`FlashHead` entries that `CREATE_IDB=true` adds — the reason the old loader was 471=2 /
loader=3 and 475584 B against the new one's 1/1/2 and 471374 B — are not needed for `db`.

**`usbplug` has no read cap.** A read at 32.2 MiB returns real data with no `0xCC`, and the backup
GPT header reads correctly from the last sector. `RKUSB_READ_LIMIT_ADDR` gates `Loader` only, so a
full dump never has to go through it and patching U-Boot is a convenience, not a prerequisite.

**The ~12.4 GB stall reproduced, and it is not heat.** A full `rl 0 30777344` held **25-27 MB/s flat
for 500 s** and then stopped dead at **12,577,013,760 B (LBA 24564480, 79%)** — no slowdown at any
point. Against 2026-09-06's 18 MB/s to 12.22 GB: the two agree to **3% in bytes** but differ by
**36% in elapsed time**, which is the wrong way round for a thermal cause, and neither run showed
the decay the old note predicted. Not the loader either — 09-06 was already a correct `LDR ` build.
The box is bus-powered through the port it is read over; a brownout is the live suspect and a
powered hub is still untried. `docs/maskrom.md` no longer calls this thermal, and its `sleep 60`
cool-downs are gone — they never had evidence behind them.

**Correction — `rd 3` depends on the session, not on usbplug being resident.** After a transfer that
_completed_ it answers `Reset Device OK` and a fresh `db` follows. After one that _stalled_ both
`rd 3` and `db` hang (exit 124, no output) and only a replug helps. I had briefly recorded the first
half as disproving the old "replug is the only reset" rule; it does not.

**Correction, same day.** "It is not heat" above was too strong. Resuming the tail from LBA 24564480
in a fresh session minutes after that stall died after only **589 MB** — against 12.58 GB when the
box had been sitting idle. Capacity therefore depends on how recently the box was worked, which is
what the earlier thermal note was describing and which this reproduces. What holds from the run
above is narrower: there is no _gradual_ decay and no rate warning inside a session — 25-27 MB/s
flat, then a hard stop — so the mechanism is a trip, not throttling. Heat and a bus-power brownout
both fit "recovers when left alone"; a powered hub would separate them and is still untried.
`docs/maskrom.md` now states the capacity table and marks the mechanism ❓ rather than picking one.

**Second correction.** "No gradual decay, no rate warning" was also too strong, and rests on one
cold session sampled at 60 s. Warm sessions do slide before dying — 18 MB/s to 16 KB/s on 09-06,
13-30 MB/s to 1.7 MB/s on an earlier run. The accurate statement is that decay is a real warning
when it appears, but its absence means nothing: a cold session can hold full rate to the last
second. Both shapes are now in `docs/maskrom.md`.

### 2026-09-12 — minimal BT wake attempt, built around the message nobody was sending

Restored `0004` and `0005` to the shipped set and added two hooks. `0006` deliberately stays parked:
it prevents the suspend-time disconnect, and this design depends on that disconnect happening.

**The insight.** HID-over-GATT mandates a HID Control Point (`0x2A4C`) — the host writes `0x00` for
"entering Suspend", `0x01` for leaving. Across every capture taken in this investigation it is
written **zero times**. BlueZ defines the UUID but puts the trigger behind an opt-in backend (the
reference is a FIFO), because a UPower suspend signal arrives after the connection is already gone.
So the remote has always believed the host was awake — while it hunted to reconnect, while the
controller pinged it, and while it timed out at the hour.

**Shape of the fix.** Let the core disconnect as upstream intends, but tell the remote first:

- `rk35xx-bt-suspend` (`system-sleep`): waits out a held power key, writes `0x00` on `pre`, `0x01`
  on `post`.
- `rk35xx-bt-wake` + `bt-wake.conf`: strips the remote's IRK so the kernel will accept-list it,
  which is what makes the reconnect advert a wake source at all.
- `0004` for the accept list, `0005` so the chip is told the host went down.

If the remote honours the control point this handles all three open faults at once: no reconnect
hunt (fault 3), no link to drop at the hour (fault B), and the key release consumed while awake plus
no open link to deliver it over (fault A).

**Untested, and gated on one unknown.** `research/seekwave-bt-wake/gate-test-hid-control-point.sh`
writes `0x00` while awake and watches whether the remote goes quiet and still wakes on a keypress.
Cheap handsets routinely expose `0x2A4C` and ignore it, so presence proves nothing. If it is
ignored, fault 3 returns and the only known answer is `0006` — the configuration that hung the box.

The power key stays `ignore` until the gate passes.

### 2026-09-12 (later) — the minimal design failed, tested properly

`rk35xx-bt-suspend` deployed and confirmed running (journal shows `0x00` written on `pre`, `0x01` on
`post`, to `service0023/char004c`). Two suspends, both ended at **2.00 s** by

```
LE Extended Advertising Report — ADV_DIRECT_IND (0x0015), 74:CC:23:DE:9D:33
```

so the remote hunts back exactly as it does without the write.

**First attempt at this was weak and the owner caught it:** the hook writes `0x00` and suspends 0.25
s later, so a remote acting lazily would never have had the chance, and "went quiet" was measured on
an already-idle link. Retested awake, no suspend, with a 10 s delay before forcing the disconnect by
hand — still one `ADV_DIRECT_IND`, reconnected within 5 s. The characteristic is present and the
write errors on nothing; the behaviour simply does not change.

**Disconnect reason code, the last cheap idea, also failed.** `0x16` and `0x15` both hunt back. The
asymmetry that motivated it — quiet after its own ~1 h drop, hunting after ours — is still
unexplained.

Also visible in the same capture, and worth keeping: `Authenticated Payload Timeout Expired` fires
every ~31 s **while awake**, so this handset never answers LE Ping at all. That is the same root as
the one-hour drop, observable without suspending.

Power key back to `ignore` on both presses, `0006` stays parked, board.md back to ❌. Three levers
tried, three closed with evidence.

#### A near miss worth recording

The gate test first reported "FAIL: no HID Control Point exposed". That was **my bug**, not the
remote: `bluetoothctl` indents object paths with a tab and the matcher anchored on `^/`. The whole
approach was nearly abandoned on a bad regex, before the raw attribute dump showed `00002a4c`
sitting there. Check the tool before believing the result.

## 2026-09-13 — the media stack probed: V4L2 gate confirmed, the video plane found, gst-rockchip stale

Read-only sweep over ssh. HDMI was unplugged throughout, so nothing here involved a display, and the
KMS half of the chain is still untested. A deep-sleep experiment was running on the box in the same
window; its traces are below, and it changed none of these results.

### The V4L2 request API is off — read off the box, not inferred

`/boot/config-6.1.115-vendor-rk35xx` is a full config, so an absent symbol is genuinely unset.

| symbol                                 | state  |
| -------------------------------------- | ------ |
| `CONFIG_MEDIA_CONTROLLER_REQUEST_API`  | absent |
| `CONFIG_V4L2_H264` · `CONFIG_V4L2_VP9` | absent |
| `CONFIG_VIDEO_ROCKCHIP_VDEC`           | absent |
| `CONFIG_MEDIA_CONTROLLER`              | `y`    |
| `CONFIG_VIDEO_DEV`                     | `y`    |
| `CONFIG_V4L2_MEM2MEM_DEV`              | `y`    |
| `CONFIG_DRM_LIMA`                      | `m`    |

No `/dev/video*` and no `/dev/media*`. `/dev/cec0`, `/dev/mpp_service`, `/dev/dri/card0` (the VOP)
and `/dev/dri/card1` (`ff700000.gpu`) are all present. The infrastructure a stateless decoder wants
is half-built: videodev and m2m arrive with the camera and RGA drivers, the request API and the
codec helpers do not.

### The video plane is DRM plane 266

`modetest -M rockchip -p` lists **14 planes**, which is the arithmetic of the `[02]` graft —
Esmart0, Esmart2 and Esmart3 contribute four areas each (`WIN_FEATURE_MULTI_AREA`), the two Cluster
windows one each: 4+4+4+1+1. Esmart1 is absent, exactly as `vop3_ignore_plane()` says it should be.

| planes         | window        | crtcs   | type    | of note                                      |
| -------------- | ------------- | ------- | ------- | -------------------------------------------- |
| 57,122,138,154 | Esmart0       | vp0     | Primary | the console                                  |
| 73,170,186,202 | Esmart2       | vp0+vp1 | Cursor  |                                              |
| 99,218,234,250 | Esmart3       | vp1     | Primary | vp1 drives nothing on this board             |
| **266**        | Cluster0-win0 | vp0     | Overlay | NV12 NV21 NV16 NV61 NV24 NV42 NV15 NV20 NV30 |
| 282            | Cluster0-win1 | vp0     | Overlay | RGB and packed YUV only — no NV12            |

Plane 266 is the one to hand video: the only vp0 overlay taking both 8-bit and 10-bit semi-planar
YUV, and 10-bit RGB besides. `modetest` printed the `IN_FORMATS` blob empty, so AFBC remains the
kernel's claim rather than a read-back.

### Decode is 110 fps when nothing copies the frame

```sh
/usr/lib/jellyfin-ffmpeg/ffmpeg -nostdin -hwaccel rkmpp -hwaccel_output_format drm_prime \
  -i clip4k.hevc.mp4 -an -f null -
```

480 frames of 3840x2160 HEVC at **110 fps**, speed 1.84x. The same clip through the documented
`scale_rkrga` + `hwdownload` + `fbdev` pipeline reaches the screen at 27. Decode is not close to
being the limit; the copy costs about four fifths of the rate.

### gst-rockchip is 1.14.4 against a 1.26.2 core

`mppvideodec` and `kmssink` are both installed — the whole zero-copy chain, in packages. It does not
run:

```
gst_video_decoder_negotiate_default: assertion 'GST_VIDEO_INFO_WIDTH (&state->info) != 0' failed
```

Identical on 1080p H.264 and 4K HEVC, through `h264parse`/`h265parse` and through `decodebin`, and
with `video/x-raw,format=NV12` forced downstream. MPP itself opens each stream first
(`h264d_api: is_avcC=1`, `h265d: extradata is encoded as hvcC format`), so the failure is in caps
negotiation, not in the decoder.

`libgstrockchipmpp.so` reports **version 1.14.4, source module `gst-rockchip`**, against a
**GStreamer 1.26.2** core — eight years of `GstVideoDecoder` drift. It is owned by no dpkg package.
`kmssink` is core, and current. Rebuilding the plugin against 1.26 is the obvious next move, and
ffmpeg's rkmpp path decoding at 110 fps minutes later on the same box rules out the hardware.

### Wi-Fi does AP, and AP+STA together

`iw phy phy0 info` — supported modes include **AP**, P2P-GO, monitor and IBSS, and the combinations
allow `#{managed} <= 1, #{AP} <= 1, total <= 3, #channels <= 2`. Keyboard-free onboarding has a
mechanism: hold the station link and raise an AP for a phone at the same time. The TDD antenna cost
of doing so is still unmeasured.

`wireguard.ko` ships with the kernel. `kodi` is in apt at `2:21.2+dfsg-4`, not installed.

### The deep-sleep traces, and why they change nothing

`dmesg` shows a decode in flight when a suspend landed:

```
mpp_rkvdec2 ff740100.rkvdec: session 12 task 3552 timeout 0 abort 0 force_dequeue 1
mpp_rkvdec2 ff740100.rkvdec: resetting...  /  reset done
PM: suspend entry (deep)
rkvdec2_link_wait_result:1336: wait task break by signal
```

The VPU reset itself and recovered — ffmpeg decoded 480 frames at 110 fps afterwards. Everything
else measured here is a config file, a driver capability table or a package version, none of which a
suspend cycle touches.

## 2026-09-13 — sleep and wake on the remote, shipped

The board sleeps on the remote's power key and wakes on any key. Measured here: **4075 s** asleep
through the hour-long link teardown that had ended every previous attempt at 3598 s, with the
remote's HID devices enumerated 0.4 s after resume; an earlier **5934 s** run; and nineteen
consecutive short cycles where every wake carried HID data rather than a reconnect advertisement.

The reasoning that unlocked it: deep suspend cannot filter a wake, because the SoC resumes in
hardware before any instruction runs — but it does not have to. The chip pulls host-wake only when
it has something to deliver, so the fix is to stop the controller producing anything that is not
input. The link is held instead of dropped, and the two events that used to end a sleep are masked
at the controller with a core-spec command.

An earlier conclusion in `research/seekwave-bt-wake` said masking "is not the answer" and marked it
confident. That was wrong and expensive. Masking `Disconnect Complete` did leave the box unwakeable
for 19.6 h, but from a side effect with a fixable cause: the host re-enables accept-list scanning
only in response to that same event, so masking it left the controller deaf. Arming the scan before
suspending is all it needed.

Six faults folded into one patch, because the fix is a sequence and any subset still leaves the
board unable to sleep on its remote.

Two things stay open:

- A key event within about half a second of the suspend request still wakes the box — 0.44 s
  measured, a HID report on a healthy link. `settle_ms` waits for the link to fall quiet first,
  which closes the common case, but a report arriving after that wait cannot be ignored.

The suspend-to-idle route explored first is parked in `research/seekwave-bt-wake` as `0008` and
`0009`: the classification works and is proven on hardware, but it destabilised the box, and s2idle
is not a supported path on this vendor kernel.

## 2026-09-14 — parked, and why

The sleep/wake work is not shipped. Everything lives in `research/seekwave-bt-wake/` and nothing is
wired into a build: no patch in `patches/`, no payload entry, `HandlePowerKey` back to `ignore`.

The six faults it addresses all have measured fixes — 27564 s asleep through the hour-long teardown,
woken by a keypress, HID back 0.4 s after resume, nineteen consecutive short cycles on the power
key. The seventh is why it stays parked: a later suspend can reach `Filesystems sync` and never
reach `Freezing user space processes`, leaving the box neither running nor asleep and needing its
power pulled.

That one is not in this driver. With the notifier logging its own entry, `pm: prepare, settling` —
its first statement — never prints on a failing cycle, so the block is ahead of it in
`suspend_prepare()`. It is also not load-dependent as first assumed: one occurrence followed a
resume by a second, another by eighteen idle minutes.

Three causes were named from missing evidence during this work and all three were wrong. `/var/log`
is on zram, so every power cut took the trace with it: catching the backtrace needs a persistent
journal and a watchdog firing `sysrq-w` when a suspend sits in prepare. The box is back on stock
logging, so that goes back up when the work resumes.
