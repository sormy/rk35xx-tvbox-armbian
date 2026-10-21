# The bootloader pair

Two blobs at two sectors, from two different origins. Write them **after** the OS image — write them
first and the image's own loader overwrites them.

| Sector | Blob                                     | Origin                                 |
| ------ | ---------------------------------------- | -------------------------------------- |
| 64     | `firmware/<board>/factory_idbloader.bin` | carved from that box's eMMC — **kept** |
| 16384  | `uboot.itb` — see the table below        | built here by `build-uboot.sh`         |

## Which loader each board ships

Per-board U-Boot is built from the box's own factory tree, but **swapping a running bootloader for
one that has never booted is not a free change**, so it is enabled per board rather than
family-wide.

`board.conf` decides: `BOARD_UBOOT=<board>/uboot.itb` ships that board's own FIT. Every board here
has one — a shared FIT built from mainline's `rk3528-generic` tree carries no board DT and no
`CONFIG_ADC`, so the recovery button cannot reach Maskrom from U-Boot on it. Whether a board has
ever booted its own belongs in that board's `board.md`.

**Nothing per-board is kept for a board that has never booted a build of its own** — no graft, no
tree. With no arguments `build-uboot.sh` builds only the boards whose `board.conf` names their own
`uboot.itb`, so it produces no FIT that nothing installs.

To enable a board: write `firmware/<board>/uboot.patch` against that box's
`stock/<board>/uboot.dtb`, run `./build-uboot-dts.sh <board>` and `./build-uboot.sh <board>`, boot
it once with serial attached, confirm the recovery button reaches Maskrom — then commit the graft
and point `BOARD_UBOOT` and the overlay's `payload.list` line at `<board>/uboot.itb`. `tvb-<board>`
installs it as `/usr/lib/tvb/u-boot.bin`.

`build-image.sh` fills all five BootROM idbloader slots (64, 1088, 2112, 3136, 4160) and both U-Boot
slots.

## Why the idbloader stays factory

Nothing from the reserved window may be shipped in a generic image: `DVKR` at 7168 and `SSKR` at
8192 are that unit's MAC, serial and keys.

Its DDR tuning is the only one proven stable on this DRAM die; public rkbin DDR blobs are a lottery.
The failure is a random `Synchronous Abort` whose `far` register holds ASCII text — RAM corruption,
not a code bug. Carve it per board; it is the one bootloader file that is not shared.

A backup recovers only the DDR half, so `build-rktools.sh` builds a maskrom USB loader per board
(that board's DDR init + Rockchip's `usbplug`). Build it natively — USB does not reach a container
on macOS.

> ⚠️ **Our U-Boot still serves nothing on USB.** The vendor U-Boot runs rockusb, so `rkdeveloptool`
> can always reach the box. Ours has `# CONFIG_USB is not set` and `CONFIG_NO_NET=y`, so once it
> runs the only interfaces are serial and the recovery button. Adding USB is not a config flip:
> mainline's `rk3528.dtsi` describes no USB controller at all. `docs/todo/rk35xx-uboot-usb.md` has
> the analysis and what fixing it would buy.

## The tree is the factory tree, retargeted

Same rule as everywhere else here: **follow the factory DTB and graft the minimum.** The U-Boot tree
is built the way `board.dts` is — decompile the box's own blob, then apply a small commented patch.

```sh
./build-uboot-dts.sh            # stock/<board>/uboot.dtb -> firmware/<board>/uboot.dts
```

Two stages, each auditable alone:

1. **Mechanical.** `dtc -P` decompiles the blob — and the result is checked to recompile
   **byte-identical**, so the base really is the board's own. Then
   `upstream/scripts/uboot-renumber.py` retargets it at mainline's bindings.
2. **Judgement.** `firmware/<board>/uboot.patch`, every hunk carrying its reason.

### Why a retarget is needed at all

A clock reference is `<&cru N>`. The phandle picks the controller and survives untouched; `N` is an
index into whichever driver reads it, and the vendor and mainline number the same clocks
differently:

| Node              | vendor    | mainline  |
| ----------------- | --------- | --------- |
| saradc clk/pclk   | 257 / 256 | 195 / 194 |
| eMMC, five clocks | 163–167   | 140–144   |
| sdmmc cclk/hclk   | 408 / 407 | 295 / 296 |

Mainline reads the vendor's 257 as `ACLK_VOP_BIU` and its 163 as `PCLK_UART7`. Nothing errors — the
eMMC just gets clocked against a UART. `board.dts` needs no such pass because a vendor tree meets a
vendor kernel there; our U-Boot is mainline.

The blob stores only the integer and no decompiler can recover which symbol produced it, so the
**vendor header is the dictionary** (`upstream/.kernel`, fetched by `upstream/build.sh`) and
mainline's supplies the new value. Resets need a spelling rule too — vendor `SRST_PRESETN_SARADC`,
mainline `SRST_P_SARADC`. Per board: 29 clock cells, 11 reset cells, 40 phase tags
(`u-boot,dm-pre-reloc` → `bootph-all`, `u-boot,dm-spl` → `bootph-pre-ram`).

**A cell that does not map to exactly one value stops the build**, never guessed and never shipped:
a half-retargeted tree carries vendor indices mainline reads as other clocks. `SCMI_*` names are
kept out of the dictionary — they address the `scmi_clk` provider and can never appear in a
`<&cru N>` cell, while collecting them collided with the whole low CRU range. No board here produces
an unmapped cell.

### What the patch grafts

- **model** — U-Boot's banner prints it, and three near-identical boxes are otherwise all "Rockchip
  RK3528 Evaluation Board" on a serial console. The root `compatible` is left as the vendor set it:
  nothing in U-Boot matches on it, and the control DT never reaches the kernel.
- **a uart0 node**, and `stdout-path` moved to it. The factory tree holds exactly one serial node —
  uart2 at `ffa00000`, `status = "okay"` — and points `stdout-path` at it. Mainline resolves that
  and binds it, so left alone the console lands on uart2 and the debug header falls silent once
  pre-relocation `DEBUG_UART` output stops. The header is uart0; the factory tree describes no uart0
  because vendor U-Boot reaches it from code instead (`PreSerial: 0, raw, 0xff9f0000`), and mainline
  has no equivalent.
- **`vdd-microvolts` on saradc** — mainline's driver fails probe with no `vref-supply` and no
  explicit reference; the vendor's defaulted.
- **`sdmmc` disabled, 3518D only** — no SD slot; SPL then falls straight through to eMMC.

`rk3528-u-boot.dtsi` is deliberately not used: it patches upstream labels a stock-derived tree has
none of, and the phase tags it would add are already present. The per-board `-u-boot.dtsi` the build
writes pulls in `rockchip-u-boot.dtsi` for binman and nothing else — that file references only its
own labels. (It keeps the dash: `-u-boot.dtsi` is the name upstream's Makefile globs for.)

## The recovery button, and why the tree is per board

🟡 **Implemented and verified in the artifact, not yet on hardware.** Holding the recovery button at
boot should make U-Boot set the download flag and reset into Maskrom, with no serial needed. What
makes it work:

| Piece                                     | Where                                                             |
| ----------------------------------------- | ----------------------------------------------------------------- |
| `CONFIG_ADC` + `CONFIG_SARADC_ROCKCHIP`   | `build-uboot.sh` patches them into the generic defconfig          |
| `saradc` node enabled, with a vref        | `firmware/<board>/uboot.dts`                                      |
| `setup_boot_mode()` → `board_late_init()` | mainline, already wired; the flag register defaults to `ff370200` |

**The node has to be named `saradc@ffae0000`.** `rockchip_dnl_key_pressed()` walks the ADC uclass
and matches the first six characters of the device name against `saradc`. Upstream `rk3528.dtsi`
calls it `adc@ffae0000`, which the function cannot see — the factory tree calls it `saradc@ffae0000`
and works untouched. One more thing following the vendor gets for free that a hand-written tree has
to discover the hard way.

The eMMC tuning is per board, so the tree cannot be shared either — speed mode, `max-frequency` and
`fixed-emmc-driver-type` all differ between boxes. Each is measured from that box's factory U-Boot
DT in `stock/<board>/uboot.dts`, inherited automatically by a tree derived from one, and recorded in
that board's `board.md`.

The control DTB lives inside the FIT, so a per-board tree means a per-board `uboot.itb`.

## Why `uboot.itb` is built rather than taken

No third-party prebuilt, every input pinned. **Not byte-reproducible**: U-Boot bakes its build
timestamp into the version string (`U-Boot 2026.04 (Sep 06 2026 - 01:39:10)`), so two builds of the
same tree differ. The control DTB inside is identical — diff that, not the FIT, when checking a
rebuild changed nothing.

| Input  | Pin                                                                                     |
| ------ | --------------------------------------------------------------------------------------- |
| U-Boot | mainline tag `v2026.04`, `generic-rk3528_defconfig` (per-board adds the DT and the ADC) |
| BL31   | `rk3528_bl31_v1.21.elf` from `rkbin`, pinned by commit                                  |
| TPL    | `rk3528_ddr_1056MHz_v1.13.bin` — build input only                                       |

- **BL31 v1.20 is the floor.** RK3518 support landed there; older ATF stops at `Unknown SoC`.
  Armbian's own `linux-u-boot-rock-2f-vendor` builds against `rk3528_bl31_v1.17.elf` — its
  `u-boot-metadata-target-1.sh` says so — which is why that loader cannot boot these boxes.
- **Mainline, not the vendor tree.** Rockchip maintains a downstream fork on an old mainline base,
  and Armbian's `rock-2f-vendor` package is a build of it: `CONFIG_ANDROID_BOOTLOADER=y`,
  `CONFIG_ANDROID_AVB=y`, `CONFIG_CMD_BOOT_ANDROID=y`, and `SPL_FIT_GENERATOR=make_fit_atf.sh`, long
  gone from mainline. Its `bootcmd` runs `boot_android`/`bootrkp`, finds `/boot/boot.scr`, bails and
  falls through to PXE. Mainline's `generic-rk3528` boots through bootstd: Armbian's `boot.scr`,
  TVBian's `extlinux.conf`.
- **Switching to it would not fix the MAC.** It does carry vendor storage
  (`CONFIG_ROCKCHIP_VENDOR_PARTITION=y`, `vendor_storage_init` in the blob), but Armbian's defconfig
  has `# CONFIG_ROCKCHIP_SET_ETHADDR is not set` — the option that would turn `LAN_MAC` into
  `ethaddr`. Reading the store and using it for the MAC are two separate switches.
- **The MAC comes from vendor storage.** `patches/u-boot/0003` reads `LAN_MAC` from `mmc0`'s `DVKR`,
  newest intact copy, into `ethaddr` and `eth1addr`; the `cpuid`-derived address is the fallback.
  The kernel gets it as `local-mac-address` and needs no patch of its own.
- **No OP-TEE.** The FIT carries ATF + U-Boot only. BL31 prints one benign
  `No OPTEE provided … opteed_fast`. Re-add with `TEE=` and `rk3528_bl32_v1.06.bin` if ever needed.
- **`ROCKCHIP_TPL=` never reaches the artifact.** Binman assembles TPL+SPL+FIT as one image; only
  the FIT is extracted and the built idbloader discarded. Reproducibility rests on the U-Boot and
  BL31 pins alone.
- **`rkbin` is pinned to one commit shared with `build-rktools.sh`.** Bump both together.

## Rebuilding

```sh
./build-firmware-all.sh               # every board's tree and FIT, then reports what moved
./build-uboot.sh [<board>…]           # the FIT alone; macOS builds natively, see below

strings -a firmware/<board>/uboot.itb | grep -E 'bl31-v|fdt-rk3528'   # identify a suspect blob
# bl31-v1.21 / fdt-rk3528-<board>

sudo dd if=firmware/<board>/uboot.itb of=/dev/<sd> bs=512 seek=16384 conv=notrunc; sync
```

On macOS the build is native — `build-uboot.sh` names any missing Homebrew formula and stops:

```sh
brew install aarch64-elf-gcc make coreutils openssl@3 swig
```

U-Boot links no libc, so the bare-metal `aarch64-elf-` toolchain is enough; no glibc cross-compiler
and no container. `patches/u-boot/` carries the two fixes its pylibfdt build needs off Linux, and
`binman` gets `pyelftools` from a venv under `uboot-build/`. **A macOS FIT is not byte-identical to
a Linux one** — different compiler, different code — so a board's shipped FIT and the host that
built it belong together.

Each board builds out-of-tree into `uboot-build/out-<board>/`, from a defconfig generated on the
spot out of mainline's `generic-rk3528_defconfig`. Nothing is stored that upstream already ships —
`firmware/<board>/uboot.patch` is the only device-tree source we keep — the `.dts` it produces is a
build artifact — and the build aborts if the generic defconfig stops disabling the ADC in the way
the patch expects.

Smoke-test before trusting it: the factory idbloader at sector 64 stays put, and it must reach a
login over serial.

## What rebuilding cannot fix

**The R69's 1.5 GB ceiling is the factory TPL's, not U-Boot's.** The TPL trains two 1 GB
chip-selects but hands on an `ATAG_DDR_MEM` describing two banks totalling 1.5 GB with nothing above
them. Proven, not assumed: Rockchip's vendor U-Boot sets `CONFIG_BIDRAM=y` — the path that _adds_
any extended-top region the TPL flags — and its `bdinfo` printed those same two banks with
`gd->ram_top_ext_size == 0`. The TPL banner, stock `/proc/iomem` and the stock DTB `/memory` node
all agree.
